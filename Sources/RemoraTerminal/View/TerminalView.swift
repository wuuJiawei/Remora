import AppKit
import Foundation
import RemoraCore

public struct TerminalSelection: Equatable {
    public var startRow: Int
    public var startColumn: Int
    public var endRow: Int
    public var endColumn: Int

    public init(startRow: Int, startColumn: Int, endRow: Int, endColumn: Int) {
        self.startRow = startRow
        self.startColumn = startColumn
        self.endRow = endRow
        self.endColumn = endColumn
    }
}

public final class TerminalView: NSView {
    public var onInput: (@Sendable (Data) -> Void)?
    public var onFocus: (() -> Void)?
    public var onResize: ((Int, Int) -> Void)?
    public var isDisplayActive: Bool = true {
        didSet {
            guard isDisplayActive else { return }
            if !dirtyRows.isEmpty {
                needsDisplay = true
            }
        }
    }

    private let screenBuffer: ScreenBuffer
    private let parser = ANSIParser()
    private let ringBuffer = RingByteBuffer(capacity: 2 << 20)
    private let renderer = CoreTextTerminalRenderer()
    private let inputMapper = TerminalInputMapper()
    private let metrics = PerformanceMetrics()

    private var frameScheduler: FrameScheduler?
    private var dirtyRows: Set<Int> = []
    private var selection: TerminalSelection?
    private var flushSequence: UInt64 = 0
    private var accessibilityTextSnapshot = ""

    public init(rows: Int = 30, columns: Int = 120) {
        self.screenBuffer = ScreenBuffer(rows: rows, columns: columns)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.isOpaque = true
        configureAccessibility()
        setupScheduler()
        scheduleWelcomeText()
        updateAccessibilitySnapshot()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override var acceptsFirstResponder: Bool {
        true
    }

    public override func isAccessibilityElement() -> Bool {
        true
    }

    public override func accessibilityRole() -> NSAccessibility.Role? {
        .textArea
    }

    public override func accessibilityLabel() -> String? {
        "Terminal"
    }

    public override func accessibilityIdentifier() -> String {
        "terminal-view"
    }

    public override func accessibilityValue() -> Any? {
        accessibilityTextSnapshot
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
            self.onFocus?()
        }
    }

    deinit {
        frameScheduler?.stop()
    }

    public func feed(data: Data) {
        _ = ringBuffer.write(data)
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        renderer.draw(screen: screenBuffer, in: context, bounds: bounds, dirtyRows: [])
        drawCursor(in: context)
        drawSelection(in: context)
        updateAccessibilitySnapshot()

        dirtyRows.removeAll(keepingCapacity: true)
    }

    public override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "v" {
            paste(nil)
            return
        }

        guard let input = inputMapper.map(event: event) else {
            super.keyDown(with: event)
            return
        }
        onInput?(input)
    }

    public func paste(_ sender: Any?) {
        guard let value = NSPasteboard.general.string(forType: .string) else { return }
        onInput?(Data(value.utf8))
    }

    public override func mouseDown(with event: NSEvent) {
        onFocus?()
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let location = cellLocation(from: point)
        selection = TerminalSelection(
            startRow: location.row,
            startColumn: location.column,
            endRow: location.row,
            endColumn: location.column
        )
        needsDisplay = true
    }

    public override func mouseDragged(with event: NSEvent) {
        guard var current = selection else { return }
        let point = convert(event.locationInWindow, from: nil)
        let location = cellLocation(from: point)
        current.endRow = location.row
        current.endColumn = location.column
        selection = current
        needsDisplay = true
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        resizeBufferToBounds()
    }

    private func setupScheduler() {
        frameScheduler = FrameScheduler(frameIntervalMS: 16) { [weak self] in
            DispatchQueue.main.async {
                self?.flushFrame()
            }
        }
        frameScheduler?.start()
    }

    private func scheduleWelcomeText() {
        let banner = "\u{001B}[32mRemora TerminalView ready\u{001B}[0m\r\n"
        feed(data: Data(banner.utf8))
    }

    private func flushFrame() {
        let start = ContinuousClock.now
        let chunk = ringBuffer.read(maxBytes: 64 * 1024)
        guard !chunk.isEmpty else { return }

        parser.parse(chunk, into: screenBuffer)
        let changedRows = screenBuffer.consumeDirtyRows()
        if !changedRows.isEmpty {
            dirtyRows.formUnion(changedRows)
            updateAccessibilitySnapshot()
        }

        let elapsed = start.duration(to: .now)
        flushSequence += 1
        let milliseconds = Self.durationToMilliseconds(elapsed)

        Task {
            await metrics.record(
                PerformanceSample(
                    frameDurationMS: milliseconds,
                    inputLatencyMS: 0,
                    bytesPerSecond: Double(chunk.count) * 60
                )
            )

            if flushSequence % 120 == 0 {
                await metrics.logSummary()
            }
        }

        if isDisplayActive, !dirtyRows.isEmpty {
            needsDisplay = true
        }
    }

    private func resizeBufferToBounds() {
        guard bounds.width > 0, bounds.height > 0 else { return }

        let drawableWidth = max(bounds.width - renderer.horizontalInset * 2, renderer.cellWidth)
        let columns = max(Int(drawableWidth / renderer.cellWidth), 1)
        let rows = max(Int(bounds.height / renderer.lineHeight), 1)
        screenBuffer.resize(rows: rows, columns: columns)
        onResize?(columns, rows)
        sanitizeDirtyRows()
        clampSelectionIfNeeded()
        dirtyRows.formUnion(screenBuffer.consumeDirtyRows())
        updateAccessibilitySnapshot()
        needsDisplay = true
    }

    private func drawCursor(in context: CGContext) {
        let cursorRect = CGRect(
            x: renderer.horizontalInset + CGFloat(screenBuffer.cursorColumn) * renderer.cellWidth,
            y: bounds.height - CGFloat(screenBuffer.cursorRow + 1) * renderer.lineHeight,
            width: renderer.cellWidth,
            height: renderer.lineHeight
        )
        context.setFillColor(NSColor.white.withAlphaComponent(0.3).cgColor)
        context.fill(cursorRect)
    }

    private func drawSelection(in context: CGContext) {
        guard let selection else { return }
        guard screenBuffer.rows > 0, screenBuffer.columns > 0 else { return }

        let minRow = min(selection.startRow, selection.endRow)
        let maxRow = max(selection.startRow, selection.endRow)
        let minCol = min(selection.startColumn, selection.endColumn)
        let maxCol = max(selection.startColumn, selection.endColumn)

        let clampedMinRow = max(0, min(minRow, screenBuffer.rows - 1))
        let clampedMaxRow = max(0, min(maxRow, screenBuffer.rows - 1))
        let clampedMinCol = max(0, min(minCol, screenBuffer.columns - 1))
        let clampedMaxCol = max(0, min(maxCol, screenBuffer.columns - 1))

        context.setFillColor(NSColor.systemBlue.withAlphaComponent(0.25).cgColor)
        for row in clampedMinRow ... clampedMaxRow {
            let rect = CGRect(
                x: renderer.horizontalInset + CGFloat(clampedMinCol) * renderer.cellWidth,
                y: bounds.height - CGFloat(row + 1) * renderer.lineHeight,
                width: CGFloat(clampedMaxCol - clampedMinCol + 1) * renderer.cellWidth,
                height: renderer.lineHeight
            )
            context.fill(rect)
        }
    }

    private func cellLocation(from point: CGPoint) -> (row: Int, column: Int) {
        let contentX = max(point.x - renderer.horizontalInset, 0)
        let col = max(Int(contentX / renderer.cellWidth), 0)
        let row = max(Int((bounds.height - point.y) / renderer.lineHeight), 0)
        return (min(row, screenBuffer.rows - 1), min(col, screenBuffer.columns - 1))
    }

    private static func durationToMilliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private func sanitizeDirtyRows() {
        let validRows = Set(screenBuffer.validRowRange())
        dirtyRows = dirtyRows.intersection(validRows)
    }

    private func clampSelectionIfNeeded() {
        guard var selection else { return }
        guard screenBuffer.rows > 0, screenBuffer.columns > 0 else {
            self.selection = nil
            return
        }

        let maxRow = screenBuffer.rows - 1
        let maxCol = screenBuffer.columns - 1

        selection.startRow = min(max(selection.startRow, 0), maxRow)
        selection.endRow = min(max(selection.endRow, 0), maxRow)
        selection.startColumn = min(max(selection.startColumn, 0), maxCol)
        selection.endColumn = min(max(selection.endColumn, 0), maxCol)
        self.selection = selection
    }

    private func configureAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.textArea)
        setAccessibilityLabel("Terminal")
        setAccessibilityIdentifier("terminal-view")
        setAccessibilityHelp("")
    }

    private func updateAccessibilitySnapshot() {
        let startRow = max(0, screenBuffer.rows - 20)
        var rows: [String] = []
        rows.reserveCapacity(screenBuffer.rows - startRow)

        for row in startRow ..< screenBuffer.rows {
            let line = screenBuffer.line(at: row)
            var text = String(line.cells.map(\.character))
            while text.last == " " {
                text.removeLast()
            }
            if !text.isEmpty {
                rows.append(text)
            }
        }

        let snapshot = rows.joined(separator: "\n")
        guard snapshot != accessibilityTextSnapshot else { return }

        accessibilityTextSnapshot = snapshot
        setAccessibilityHelp(snapshot)
        NSAccessibility.post(element: self, notification: .valueChanged)
    }
}
