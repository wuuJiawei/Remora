import AppKit
import Foundation
import RemoraCore

public struct TerminalSelection: Equatable {
    // Buffer-space coordinates (absolute row across scrollback + visible lines).
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

public final class TerminalView: NSView, @preconcurrency NSTextInputClient {
    public var onInput: (@Sendable (Data) -> Void)?
    public var onFocus: (() -> Void)?
    public var onResize: ((Int, Int) -> Void)?
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
            parser.onKittyKeyboardQuery = { [weak self] flags in
                // Format: ESC [ ? <flags> u
                let response = "\u{001B}[?\(flags)u"
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
    private var markedText: NSAttributedString = .init(string: "")
    private var focusReportingEnabled = false
    private var bracketedPasteEnabled = false

    private let flushScheduleLock = NSLock()
    nonisolated(unsafe) private var flushScheduled = false

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
        }
    }

    public override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        guard accepted else { return false }
        onFocus?()
        if focusReportingEnabled {
            onInput?(Data("\u{001B}[I".utf8))
        }
        return true
    }

    public override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        guard accepted else { return false }
        if focusReportingEnabled {
            onInput?(Data("\u{001B}[O".utf8))
        }
        return true
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

        if let legacyControl = inputMapper.mapLegacyControl(event: event) {
            scrollToBottom()
            onInput?(legacyControl)
            return
        }

        if let input = inputMapper.mapKittyKeyDown(event: event) {
            scrollToBottom()
            onInput?(input)
            return
        }

        if shouldSendRawControlInput(event) {
            guard let input = inputMapper.map(event: event) else {
                super.keyDown(with: event)
                return
            }
            scrollToBottom()
            onInput?(input)
            return
        }

        scrollToBottom()
        interpretKeyEvents([event])
    }

    public override func keyUp(with event: NSEvent) {
        if let input = inputMapper.mapKeyUp(event: event) {
            onInput?(input)
            return
        }
        super.keyUp(with: event)
    }

    public func paste(_ sender: Any?) {
        scrollToBottom()
        guard let value = NSPasteboard.general.string(forType: .string) else { return }
        if bracketedPasteEnabled {
            let wrapped = "\u{001B}[200~" + value + "\u{001B}[201~"
            onInput?(Data(wrapped.utf8))
            return
        }
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

        screenBuffer.setViewportOffset(scrollbackOffset)
        let point = convert(event.locationInWindow, from: nil)
        let location = bufferCellLocation(from: point)

        if event.clickCount >= 2 {
            selectWord(atBufferRow: location.row, column: location.column)
            needsDisplay = true
            return
        }

        selection = TerminalSelection(
            startRow: location.row,
            startColumn: location.column,
            endRow: location.row,
            endColumn: location.column
        )
        needsDisplay = true
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
        screenBuffer.setViewportOffset(scrollbackOffset)
        let point = convert(event.locationInWindow, from: nil)
        let location = bufferCellLocation(from: point)
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
            guard let self else { return }
            guard self.markFlushScheduled() else { return }
            DispatchQueue.main.async {
                defer {
                    self.clearFlushScheduled()
                }
                self.flushFrame()
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
        inputMapper.kittyKeyboardFlags = parser.kittyKeyboardFlags
        focusReportingEnabled = parser.focusReportingEnabled
        bracketedPasteEnabled = parser.bracketedPasteEnabled
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
        flushPendingInputBeforeResize()

        let drawableWidth = max(bounds.width - renderer.horizontalInset * 2, renderer.cellWidth)
        let columns = max(Int(drawableWidth / renderer.cellWidth), 1)
        let rows = max(Int(bounds.height / renderer.lineHeight), 1)
        guard columns != screenBuffer.columns || rows != screenBuffer.rows else { return }
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

    private func flushPendingInputBeforeResize() {
        let pending = ringBuffer.drainAll()
        guard !pending.isEmpty else { return }

        parser.parse(pending, into: screenBuffer)
        inputMapper.applicationCursorKeysEnabled = parser.applicationCursorKeysEnabled
        inputMapper.kittyKeyboardFlags = parser.kittyKeyboardFlags
        focusReportingEnabled = parser.focusReportingEnabled
        bracketedPasteEnabled = parser.bracketedPasteEnabled
        dirtyRows.formUnion(screenBuffer.consumeDirtyRows())
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
        screenBuffer.setViewportOffset(scrollbackOffset)
        let ordered = orderedSelection(selection)
        let totalLineCount = screenBuffer.totalBufferLineCount()
        guard totalLineCount > 0 else { return }

        let minRow = min(max(0, ordered.startRow), totalLineCount - 1)
        let maxRow = min(max(0, ordered.endRow), totalLineCount - 1)
        guard minRow <= maxRow else { return }

        let viewportStart = screenBuffer.viewportStartBufferRow()
        let viewportEnd = viewportStart + screenBuffer.rows - 1
        let visibleStart = max(minRow, viewportStart)
        let visibleEnd = min(maxRow, viewportEnd)
        guard visibleStart <= visibleEnd else { return }

        context.setFillColor(NSColor.systemBlue.withAlphaComponent(0.25).cgColor)
        for bufferRow in visibleStart ... visibleEnd {
            let row = bufferRow - viewportStart
            let rowStartCol = (bufferRow == minRow) ? ordered.startColumn : 0
            let rowEndCol = (bufferRow == maxRow) ? ordered.endColumn : screenBuffer.columns - 1
            let clampedMinCol = max(0, min(rowStartCol, screenBuffer.columns - 1))
            let clampedMaxCol = max(0, min(rowEndCol, screenBuffer.columns - 1))
            guard clampedMinCol <= clampedMaxCol else { continue }

            let rect = CGRect(
                x: renderer.horizontalInset + CGFloat(clampedMinCol) * renderer.cellWidth,
                y: bounds.height - CGFloat(row + 1) * renderer.lineHeight,
                width: CGFloat(clampedMaxCol - clampedMinCol + 1) * renderer.cellWidth,
                height: renderer.lineHeight
            )
            context.fill(rect)
        }
    }

    private func viewportCellLocation(from point: CGPoint) -> (row: Int, column: Int) {
        let contentX = max(point.x - renderer.horizontalInset, 0)
        let col = max(Int(contentX / renderer.cellWidth), 0)
        let row = max(Int((bounds.height - point.y) / renderer.lineHeight), 0)
        return (min(row, screenBuffer.rows - 1), min(col, screenBuffer.columns - 1))
    }

    private func bufferCellLocation(from point: CGPoint) -> (row: Int, column: Int) {
        let viewportLocation = viewportCellLocation(from: point)
        let bufferRow = screenBuffer.bufferRow(forViewportRow: viewportLocation.row)
        let normalizedColumn = normalizedColumn(atBufferRow: bufferRow, column: viewportLocation.column)
        return (bufferRow, normalizedColumn)
    }

    private func normalizedColumn(atBufferRow row: Int, column: Int) -> Int {
        let line = screenBuffer.line(atBufferRow: row)
        guard line.count > 0 else { return 0 }

        var normalized = min(max(0, column), line.count - 1)
        while normalized > 0, line[normalized].displayWidth == 0 {
            normalized -= 1
        }
        return normalized
    }

    private func orderedSelection(_ selection: TerminalSelection) -> TerminalSelection {
        if selection.startRow < selection.endRow {
            return selection
        }
        if selection.startRow > selection.endRow {
            return TerminalSelection(
                startRow: selection.endRow,
                startColumn: selection.endColumn,
                endRow: selection.startRow,
                endColumn: selection.startColumn
            )
        }
        if selection.startColumn <= selection.endColumn {
            return selection
        }
        return TerminalSelection(
            startRow: selection.endRow,
            startColumn: selection.endColumn,
            endRow: selection.startRow,
            endColumn: selection.startColumn
        )
    }

    private enum WordClass {
        case whitespace
        case word
        case symbol
    }

    private func selectWord(atBufferRow row: Int, column: Int) {
        let line = screenBuffer.line(atBufferRow: row)
        guard line.count > 0 else { return }

        let seedColumn = normalizedColumn(atBufferRow: row, column: column)
        let seedClass = wordClass(in: line, at: seedColumn)
        var start = seedColumn
        var end = seedColumn

        while start > 0, wordClass(in: line, at: start - 1) == seedClass {
            start -= 1
        }
        while end + 1 < line.count, wordClass(in: line, at: end + 1) == seedClass {
            end += 1
        }

        selection = TerminalSelection(
            startRow: row,
            startColumn: start,
            endRow: row,
            endColumn: end
        )
    }

    private func wordClass(in line: TerminalLine, at column: Int) -> WordClass {
        guard column >= 0, column < line.count else { return .whitespace }

        var targetColumn = column
        while targetColumn > 0, line[targetColumn].displayWidth == 0 {
            targetColumn -= 1
        }

        let character = line[targetColumn].character
        if character.isWhitespace {
            return .whitespace
        }
        return isWordCharacter(character) ? .word : .symbol
    }

    private func isWordCharacter(_ character: Character) -> Bool {
        let underscore = CharacterSet(charactersIn: "_")
        for scalar in character.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || underscore.contains(scalar) {
                continue
            }
            return false
        }
        return true
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
        guard screenBuffer.columns > 0 else {
            self.selection = nil
            return
        }

        let totalLineCount = screenBuffer.totalBufferLineCount()
        guard totalLineCount > 0 else {
            self.selection = nil
            return
        }

        let maxRow = totalLineCount - 1
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
        guard screenBuffer.columns > 0 else { return nil }
        let totalLineCount = screenBuffer.totalBufferLineCount()
        guard totalLineCount > 0 else { return nil }

        let ordered = orderedSelection(selection)
        let minRow = min(max(ordered.startRow, 0), totalLineCount - 1)
        let maxRow = min(max(ordered.endRow, 0), totalLineCount - 1)
        guard minRow <= maxRow else { return nil }

        var rows: [String] = []
        rows.reserveCapacity(maxRow - minRow + 1)

        for row in minRow ... maxRow {
            let line = screenBuffer.line(atBufferRow: row)
            guard line.count > 0 else { continue }

            let startCol = row == minRow ? ordered.startColumn : 0
            let endCol = row == maxRow ? ordered.endColumn : (line.count - 1)
            let clampedStartCol = min(max(0, startCol), line.count - 1)
            let clampedEndCol = min(max(0, endCol), line.count - 1)
            guard clampedStartCol <= clampedEndCol else { continue }

            let characters = (clampedStartCol ... clampedEndCol)
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

    nonisolated private func markFlushScheduled() -> Bool {
        flushScheduleLock.lock()
        defer { flushScheduleLock.unlock() }
        if flushScheduled {
            return false
        }
        flushScheduled = true
        return true
    }

    nonisolated private func clearFlushScheduled() {
        flushScheduleLock.lock()
        flushScheduled = false
        flushScheduleLock.unlock()
    }

    private func shouldSendRawControlInput(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.control, .option, .shift, .command])
        if modifiers.contains(.command) {
            return false
        }
        return modifiers.contains(.control)
    }

    private func sendInputString(_ value: String) {
        guard !value.isEmpty else { return }
        onInput?(Data(value.utf8))
    }

    private func plainString(from value: Any) -> String {
        if let string = value as? String {
            return string
        }
        if let attributed = value as? NSAttributedString {
            return attributed.string
        }
        return String(describing: value)
    }

    // MARK: - NSTextInputClient

    public func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    public func markedRange() -> NSRange {
        hasMarkedText() ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0)
    }

    public func selectedRange() -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let attributed = string as? NSAttributedString {
            markedText = attributed
        } else if let plain = string as? String {
            markedText = NSAttributedString(string: plain)
        } else {
            markedText = NSAttributedString(string: String(describing: string))
        }
    }

    public func unmarkText() {
        markedText = NSAttributedString(string: "")
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    public func insertText(_ string: Any, replacementRange: NSRange) {
        markedText = NSAttributedString(string: "")
        sendInputString(plainString(from: string))
    }

    public override func insertText(_ insertString: Any) {
        insertText(insertString, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    public override func doCommand(by selector: Selector) {
        if let input = inputMapper.map(command: selector) {
            onInput?(input)
            return
        }
        super.doCommand(by: selector)
    }

    public func characterIndex(for point: NSPoint) -> Int {
        NSNotFound
    }

    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = NSRange(location: NSNotFound, length: 0)
        let caretRect = CGRect(
            x: renderer.horizontalInset + CGFloat(screenBuffer.cursorColumn) * renderer.cellWidth,
            y: bounds.height - CGFloat(screenBuffer.cursorRow + 1) * renderer.lineHeight,
            width: renderer.cellWidth,
            height: renderer.lineHeight
        )
        let rectInWindow = convert(caretRect, to: nil)
        guard let window else { return .zero }
        return window.convertToScreen(rectInWindow)
    }
}
