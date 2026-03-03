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
    /// Callback when user double-clicks on a line: (text, clickColumnIndex)
    public var onDoubleClick: ((String, Int) -> Void)?
    /// Callback for terminal query responses (DSR, DA, etc) - injects response back to PTY
    public var onTerminalQueryResponse: ((Data) -> Void)? {
        didSet {
            // Wire up parser callbacks when this is set
            parser.onDSR = { [weak self] row, col in
                // Format: ESC [ row ; col R
                let response = "\u{001B}[\(row);\(col)R"
                self?.onTerminalQueryResponse?(Data(response.utf8))
            }
            parser.onDA = { [weak self] in
                // Format: ESC [ ? 1 ; 2 c (VT100 with advanced video)
                let response = "\u{001B}[?1;2c"
                self?.onTerminalQueryResponse?(Data(response.utf8))
            }
        }
    }
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
    private var scrollbackOffset = 0

    // Double-click tracking
    private var lastClickTime: TimeInterval = 0
    private var lastClickRow: Int = -1
    private let doubleClickInterval: TimeInterval = 0.3

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
        screenBuffer.setViewportOffset(scrollbackOffset)
        renderer.draw(screen: screenBuffer, in: context, bounds: bounds, dirtyRows: [])
        if scrollbackOffset == 0 {
            drawCursor(in: context)
        }
        drawSelection(in: context)
        updateAccessibilitySnapshot()

        dirtyRows.removeAll(keepingCapacity: true)
    }

    public override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" {
            copy(nil)
            return
        }

        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "v" {
            paste(nil)
            return
        }

        guard let input = inputMapper.map(event: event) else {
            super.keyDown(with: event)
            return
        }
        scrollToBottom()
        onInput?(input)
    }

    public func paste(_ sender: Any?) {
        scrollToBottom()
        guard let value = NSPasteboard.general.string(forType: .string) else { return }
        onInput?(Data(value.utf8))
    }

    @objc
    public func copy(_ sender: Any?) {
        screenBuffer.setViewportOffset(scrollbackOffset)
        guard let selectedText = selectedText(), !selectedText.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(selectedText, forType: .string)
    }

    public override func mouseDown(with event: NSEvent) {
        onFocus?()
        window?.makeFirstResponder(self)
        
        let point = convert(event.locationInWindow, from: nil)
        let location = cellLocation(from: point)
        
        // Check for double-click
        let now = Date().timeIntervalSince1970
        let isDoubleClick = (now - lastClickTime) < doubleClickInterval 
                            && location.row == lastClickRow
        
        lastClickTime = now
        lastClickRow = location.row
        
        if isDoubleClick {
            // Double-click: extract text from the clicked line and trigger callback
            let lineText = extractTextFromLine(at: location.row)
            if !lineText.isEmpty {
                onDoubleClick?(lineText, location.column)
            }
            return
        }
        
        // Single click: start selection
        selection = TerminalSelection(
            startRow: location.row,
            startColumn: location.column,
            endRow: location.row,
            endColumn: location.column
        )
        needsDisplay = true
    }
    
    /// Extract plain text from a screen line
    private func extractTextFromLine(at row: Int) -> String {
        let line = screenBuffer.line(at: row)
        var text = ""
        for i in 0..<line.count {
            if line[i].displayWidth == 0 {
                continue
            }
            text.append(line[i].character)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public override func scrollWheel(with event: NSEvent) {
        let deltaY = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY * 10
        guard deltaY != 0 else { return }

        let step = max(Int(abs(deltaY) / 8), 1)
        let maxOffset = screenBuffer.maxViewportOffset()
        if deltaY > 0 {
            scrollbackOffset = min(maxOffset, scrollbackOffset + step)
        } else {
            scrollbackOffset = max(0, scrollbackOffset - step)
        }
        screenBuffer.setViewportOffset(scrollbackOffset)
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
        inputMapper.applicationCursorKeysEnabled = parser.applicationCursorKeysEnabled
        let maxOffset = screenBuffer.maxViewportOffset()
        if scrollbackOffset > maxOffset {
            scrollbackOffset = maxOffset
        }
        screenBuffer.setViewportOffset(scrollbackOffset)
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

        if isDisplayActive, !dirtyRows.isEmpty, !screenBuffer.isSynchronizedUpdate {
            needsDisplay = true
        }
    }

    private func resizeBufferToBounds() {
        guard bounds.width > 0, bounds.height > 0 else { return }

        let drawableWidth = max(bounds.width - renderer.horizontalInset * 2, renderer.cellWidth)
        let columns = max(Int(drawableWidth / renderer.cellWidth), 1)
        let rows = max(Int(bounds.height / renderer.lineHeight), 1)
        screenBuffer.resize(rows: rows, columns: columns)
        let maxOffset = screenBuffer.maxViewportOffset()
        if scrollbackOffset > maxOffset {
            scrollbackOffset = maxOffset
        }
        screenBuffer.setViewportOffset(scrollbackOffset)
        onResize?(columns, rows)
        sanitizeDirtyRows()
        clampSelectionIfNeeded()
        dirtyRows.formUnion(screenBuffer.consumeDirtyRows())
        updateAccessibilitySnapshot()
        needsDisplay = true
    }

    private func drawCursor(in context: CGContext) {
        guard screenBuffer.isCursorVisible else { return }
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
            var text = String(line.cells.filter { $0.displayWidth != 0 }.map(\.character))
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

    private func selectedText() -> String? {
        guard let selection else { return nil }
        guard screenBuffer.rows > 0, screenBuffer.columns > 0 else { return nil }

        let minRow = max(0, min(selection.startRow, selection.endRow))
        let maxRow = min(screenBuffer.rows - 1, max(selection.startRow, selection.endRow))
        let minCol = max(0, min(selection.startColumn, selection.endColumn))
        let maxCol = min(screenBuffer.columns - 1, max(selection.startColumn, selection.endColumn))

        guard minRow <= maxRow, minCol <= maxCol else { return nil }

        var rows: [String] = []
        rows.reserveCapacity(maxRow - minRow + 1)

        for row in minRow ... maxRow {
            let line = screenBuffer.line(at: row)
            let startCol = row == minRow ? minCol : 0
            let endCol = row == maxRow ? maxCol : screenBuffer.columns - 1
            guard startCol <= endCol else { continue }

            let characters = (startCol ... endCol)
                .compactMap { line[$0].displayWidth == 0 ? nil : line[$0].character }
            var text = String(characters)
            while text.last == " " {
                text.removeLast()
            }
            rows.append(text)
        }

        return rows.joined(separator: "\n")
    }

    private func scrollToBottom() {
        guard scrollbackOffset != 0 else { return }
        scrollbackOffset = 0
        screenBuffer.setViewportOffset(0)
        needsDisplay = true
    }
}
