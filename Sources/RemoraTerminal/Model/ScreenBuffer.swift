import Foundation

public struct CursorState: Sendable {
    public var row: Int
    public var column: Int
    public var attributes: TerminalAttributes

    public init(row: Int, column: Int, attributes: TerminalAttributes) {
        self.row = row
        self.column = column
        self.attributes = attributes
    }
}

public final class ScreenBuffer {
    public private(set) var rows: Int
    public private(set) var columns: Int

    public private(set) var cursorRow: Int = 0
    public private(set) var cursorColumn: Int = 0
    public private(set) var activeAttributes: TerminalAttributes = .default
    public private(set) var isCursorVisible: Bool = true
    public private(set) var isSynchronizedUpdate: Bool = false

    public let scrollback: ScrollbackStore
    private var lines: [TerminalLine]
    private var dirtyRows: Set<Int> = []
    private var viewportOffset: Int = 0
    private var scrollRegionTop: Int = 0
    private var scrollRegionBottom: Int
    private var wrapPending: Bool = false

    // Alternate screen buffer support
    private var alternateLines: [TerminalLine]?
    private var savedMainState: (
        lines: [TerminalLine],
        cursorRow: Int,
        cursorColumn: Int,
        attributes: TerminalAttributes,
        viewportOffset: Int,
        scrollRegionTop: Int,
        scrollRegionBottom: Int
    )?
    private var savedCursor: CursorState?
    public private(set) var isAlternateBuffer: Bool = false

    public init(rows: Int, columns: Int, scrollbackSegmentSize: Int = 1024) {
        self.rows = max(1, rows)
        self.columns = max(1, columns)
        self.scrollback = ScrollbackStore(segmentSize: scrollbackSegmentSize)
        self.lines = Array(repeating: TerminalLine(columns: max(1, columns)), count: max(1, rows))
        self.scrollRegionBottom = max(1, rows) - 1
    }

    public func line(at row: Int) -> TerminalLine {
        guard row >= 0, row < lines.count else {
            return TerminalLine(columns: columns, attributes: .default)
        }

        guard viewportOffset > 0 else {
            return lines[row]
        }

        let window = viewportWindowLines()
        let paddingRows = max(0, rows - window.count)
        if row < paddingRows {
            return TerminalLine(columns: columns, attributes: .default)
        }

        let index = row - paddingRows
        guard index >= 0, index < window.count else {
            return TerminalLine(columns: columns, attributes: .default)
        }
        return window[index]
    }

    public func validRowRange() -> Range<Int> {
        0 ..< rows
    }

    public func consumeDirtyRows() -> Set<Int> {
        defer { dirtyRows.removeAll(keepingCapacity: true) }
        return dirtyRows
    }

    public func resize(rows newRows: Int, columns newColumns: Int) {
        let targetRows = max(1, newRows)
        let targetColumns = max(1, newColumns)

        if targetRows == rows, targetColumns == columns { return }

        if targetRows < lines.count {
            let overflowCount = lines.count - targetRows
            for idx in 0 ..< overflowCount {
                scrollback.append(lines[idx])
            }
            lines.removeFirst(overflowCount)
            cursorRow = max(0, cursorRow - overflowCount)
        } else if targetRows > lines.count {
            let extra = targetRows - lines.count
            lines.append(contentsOf: Array(repeating: TerminalLine(columns: targetColumns, attributes: activeAttributes), count: extra))
        }

        for idx in lines.indices {
            lines[idx].resize(columns: targetColumns, fill: activeAttributes)
        }

        rows = targetRows
        columns = targetColumns
        cursorRow = min(cursorRow, rows - 1)
        cursorColumn = min(cursorColumn, columns - 1)
        wrapPending = false
        resetScrollingRegion()
        clampViewportOffset()
        markAllDirty()
    }

    public func applySGR(parameters: [Int]) {
        if parameters.isEmpty {
            activeAttributes = .default
            return
        }

        var index = 0
        while index < parameters.count {
            let code = parameters[index]
            switch code {
            case 0:
                activeAttributes = .default
            case 1:
                activeAttributes.bold = true
            case 2:
                activeAttributes.dim = true
            case 3:
                activeAttributes.italic = true
            case 4:
                activeAttributes.underline = true
            case 7:
                activeAttributes.inverse = true
            case 22:
                activeAttributes.bold = false
                activeAttributes.dim = false
            case 23:
                activeAttributes.italic = false
            case 24:
                activeAttributes.underline = false
            case 27:
                activeAttributes.inverse = false
            case 30 ... 37:
                activeAttributes.foreground = .indexed(UInt8(code - 30))
            case 39:
                activeAttributes.foreground = .default
            case 40 ... 47:
                activeAttributes.background = .indexed(UInt8(code - 40))
            case 49:
                activeAttributes.background = .default
            case 90 ... 97:
                activeAttributes.foreground = .indexed(UInt8(code - 90 + 8))
            case 100 ... 107:
                activeAttributes.background = .indexed(UInt8(code - 100 + 8))
            case 38, 48:
                index = applyExtendedColor(code: code, parameters: parameters, index: index)
            default:
                break
            }
            index += 1
        }
    }

    public func moveCursor(row: Int? = nil, column: Int? = nil) {
        if let row {
            cursorRow = min(max(0, row), rows - 1)
        }
        if let column {
            cursorColumn = min(max(0, column), columns - 1)
        }
        wrapPending = false
    }

    public func moveCursor(deltaRow: Int = 0, deltaColumn: Int = 0) {
        moveCursor(row: cursorRow + deltaRow, column: cursorColumn + deltaColumn)
    }

    public func put(character: Character) {
        if wrapPending {
            lineFeed()
            carriageReturn()
            wrapPending = false
        }

        let characterWidth = UnicodeCellWidth.width(of: character)
        if characterWidth == 0 {
            appendCombiningCharacter(character)
            return
        }

        if cursorRow >= rows { cursorRow = rows - 1 }
        if cursorColumn >= columns { cursorColumn = columns - 1 }

        if characterWidth == 2, columns > 1 {
            putDoubleWidthCharacter(character)
        } else {
            putSingleWidthCharacter(character)
        }
    }

    private func putSingleWidthCharacter(_ character: Character) {
        let row = cursorRow
        let col = cursorColumn
        clearWideArtifacts(row: row, column: col)

        lines[row][col] = TerminalCell(
            character: character,
            attributes: activeAttributes,
            displayWidth: 1
        )
        markDirty(row: row)

        if col == columns - 1 {
            cursorColumn = col
            wrapPending = true
        } else {
            cursorColumn = col + 1
            wrapPending = false
        }
    }

    private func putDoubleWidthCharacter(_ character: Character) {
        if cursorColumn + 2 > columns {
            lineFeed()
            carriageReturn()
        }

        let row = cursorRow
        let col = min(cursorColumn, columns - 2)
        clearWideArtifacts(row: row, column: col)
        clearWideArtifacts(row: row, column: col + 1)

        lines[row][col] = TerminalCell(
            character: character,
            attributes: activeAttributes,
            displayWidth: 2
        )
        lines[row][col + 1] = TerminalCell(
            character: " ",
            attributes: activeAttributes,
            displayWidth: 0
        )
        markDirty(row: row)

        if col + 1 == columns - 1 {
            cursorColumn = columns - 1
            wrapPending = true
        } else {
            cursorColumn = col + 2
            wrapPending = false
        }
    }

    private func appendCombiningCharacter(_ character: Character) {
        guard let column = combiningTargetColumn() else { return }
        var targetCell = lines[cursorRow][column]
        let combinedText = String(targetCell.character) + String(character)
        if let combinedCharacter = combinedText.first {
            targetCell.character = combinedCharacter
            lines[cursorRow][column] = targetCell
            markDirty(row: cursorRow)
        }
    }

    private func combiningTargetColumn() -> Int? {
        guard cursorColumn > 0 else { return nil }
        var target = cursorColumn - 1
        if lines[cursorRow][target].displayWidth == 0 {
            guard target > 0 else { return nil }
            target -= 1
        }
        return target
    }

    public func lineFeed() {
        wrapPending = false
        if cursorRow == scrollRegionBottom {
            scrollUp(lines: 1)
            return
        }
        cursorRow = min(rows - 1, cursorRow + 1)
        markDirty(row: cursorRow)
    }

    public func reverseIndex() {
        wrapPending = false
        if cursorRow == scrollRegionTop {
            scrollDown(lines: 1)
            return
        }
        cursorRow = max(0, cursorRow - 1)
        markDirty(row: cursorRow)
    }

    public func carriageReturn() {
        cursorColumn = 0
        wrapPending = false
    }

    public func backspace() {
        wrapPending = false
        cursorColumn = max(0, cursorColumn - 1)
    }

    public func horizontalTab(tabWidth: Int = 8) {
        wrapPending = false
        let width = max(1, tabWidth)
        let nextStop = ((cursorColumn / width) + 1) * width
        if nextStop >= columns {
            lineFeed()
            carriageReturn()
            return
        }
        cursorColumn = nextStop
    }

    public func clearScreen(mode: Int = 0) {
        wrapPending = false
        switch mode {
        case 0:
            // Clear from cursor to end of screen
            for col in cursorColumn..<columns {
                lines[cursorRow][col] = TerminalCell(character: " ", attributes: activeAttributes)
            }
            for row in (cursorRow + 1)..<rows {
                lines[row] = TerminalLine(columns: columns, attributes: activeAttributes)
            }
        case 1:
            // Clear from start to cursor
            for row in 0..<cursorRow {
                lines[row] = TerminalLine(columns: columns, attributes: activeAttributes)
            }
            for col in 0...cursorColumn {
                lines[cursorRow][col] = TerminalCell(character: " ", attributes: activeAttributes)
            }
        case 2:
            // Clear entire screen
            lines = Array(repeating: TerminalLine(columns: columns, attributes: activeAttributes), count: rows)
        default:
            return
        }
        markAllDirty()
    }

    public func clearLine(mode: Int) {
        wrapPending = false
        let lineIndex = cursorRow
        switch mode {
        case 0:
            for col in cursorColumn ..< columns {
                lines[lineIndex][col] = TerminalCell(character: " ", attributes: activeAttributes)
            }
        case 1:
            for col in 0 ... cursorColumn {
                lines[lineIndex][col] = TerminalCell(character: " ", attributes: activeAttributes)
            }
        case 2:
            lines[lineIndex] = TerminalLine(columns: columns, attributes: activeAttributes)
        default:
            return
        }
        markDirty(row: lineIndex)
    }

    public func markAllDirty() {
        dirtyRows = Set(0 ..< rows)
    }

    public func setCursorVisible(_ visible: Bool) {
        guard isCursorVisible != visible else { return }
        isCursorVisible = visible
        markDirty(row: cursorRow)
    }

    public func beginSynchronizedUpdate() {
        isSynchronizedUpdate = true
    }

    public func endSynchronizedUpdate() {
        guard isSynchronizedUpdate else { return }
        isSynchronizedUpdate = false
        markAllDirty()
    }

    public func setScrollingRegion(top: Int, bottom: Int) {
        let clampedTop = min(max(0, top), rows - 1)
        let clampedBottom = min(max(clampedTop, bottom), rows - 1)
        scrollRegionTop = clampedTop
        scrollRegionBottom = clampedBottom
        wrapPending = false
        moveCursor(row: 0, column: 0)
    }

    public func resetScrollingRegion() {
        scrollRegionTop = 0
        scrollRegionBottom = rows - 1
        wrapPending = false
    }

    public func scrollUp(lines count: Int = 1) {
        let requested = max(1, count)
        let regionHeight = scrollRegionBottom - scrollRegionTop + 1
        guard regionHeight > 0 else { return }
        let iterations = min(requested, regionHeight)
        let isFullScreenRegion = scrollRegionTop == 0 && scrollRegionBottom == rows - 1

        for _ in 0 ..< iterations {
            let removedLine = lines.remove(at: scrollRegionTop)
            lines.insert(
                TerminalLine(columns: columns, attributes: .default),
                at: scrollRegionBottom
            )
            if isFullScreenRegion {
                scrollback.append(removedLine)
                clampViewportOffset()
            }
        }
        markAllDirty()
    }

    public func scrollDown(lines count: Int = 1) {
        let requested = max(1, count)
        let regionHeight = scrollRegionBottom - scrollRegionTop + 1
        guard regionHeight > 0 else { return }
        let iterations = min(requested, regionHeight)

        for _ in 0 ..< iterations {
            lines.remove(at: scrollRegionBottom)
            lines.insert(
                TerminalLine(columns: columns, attributes: .default),
                at: scrollRegionTop
            )
        }
        markAllDirty()
    }

    public func maxViewportOffset() -> Int {
        let totalLineCount = scrollback.lineCount() + lines.count
        return max(0, totalLineCount - rows)
    }

    public func setViewportOffset(_ offset: Int) {
        viewportOffset = min(max(0, offset), maxViewportOffset())
    }

    public func currentViewportOffset() -> Int {
        viewportOffset
    }

    private func markDirty(row: Int) {
        guard row >= 0, row < rows else { return }
        dirtyRows.insert(row)
    }

    private func clearWideArtifacts(row: Int, column: Int) {
        guard row >= 0, row < rows, column >= 0, column < columns else { return }
        var touched = false

        if column > 0, lines[row][column].displayWidth == 0 {
            lines[row][column - 1] = TerminalCell(
                character: " ",
                attributes: .default,
                displayWidth: 1
            )
            touched = true
        }

        if lines[row][column].displayWidth == 2, column + 1 < columns {
            lines[row][column + 1] = TerminalCell(
                character: " ",
                attributes: .default,
                displayWidth: 1
            )
            touched = true
        }

        if touched {
            lines[row][column] = TerminalCell(
                character: " ",
                attributes: .default,
                displayWidth: 1
            )
        }
    }

    private func clampViewportOffset() {
        viewportOffset = min(max(0, viewportOffset), maxViewportOffset())
    }

    private func applyExtendedColor(code: Int, parameters: [Int], index: Int) -> Int {
        guard index + 1 < parameters.count else { return index }

        let targetIsForeground = code == 38
        let colorMode = parameters[index + 1]
        switch colorMode {
        case 5:
            guard index + 2 < parameters.count else { return index + 1 }
            let colorIndex = Self.clampColorComponent(parameters[index + 2])
            let color: TerminalColor = .indexed(UInt8(colorIndex))
            if targetIsForeground {
                activeAttributes.foreground = color
            } else {
                activeAttributes.background = color
            }
            return index + 2
        case 2:
            guard index + 4 < parameters.count else { return index + 1 }
            let red = UInt8(Self.clampColorComponent(parameters[index + 2]))
            let green = UInt8(Self.clampColorComponent(parameters[index + 3]))
            let blue = UInt8(Self.clampColorComponent(parameters[index + 4]))
            let color: TerminalColor = .trueColor(red, green, blue)
            if targetIsForeground {
                activeAttributes.foreground = color
            } else {
                activeAttributes.background = color
            }
            return index + 4
        default:
            return index + 1
        }
    }

    private static func clampColorComponent(_ value: Int) -> Int {
        min(max(0, value), 255)
    }

    private func viewportWindowLines() -> [TerminalLine] {
        let combined = scrollback.allLines() + lines
        guard !combined.isEmpty else { return [] }

        let clampedOffset = min(max(0, viewportOffset), maxViewportOffset())
        let endExclusive = max(0, combined.count - clampedOffset)
        let start = max(0, endExclusive - rows)
        guard start < endExclusive else { return [] }
        return Array(combined[start ..< endExclusive])
    }

    // MARK: - Alternate Screen Buffer

    public func enterAlternateBuffer() {
        guard !isAlternateBuffer else { return }
        
        // Save main buffer state
        savedMainState = (
            lines: lines,
            cursorRow: cursorRow,
            cursorColumn: cursorColumn,
            attributes: activeAttributes,
            viewportOffset: viewportOffset,
            scrollRegionTop: scrollRegionTop,
            scrollRegionBottom: scrollRegionBottom
        )
        
        // Switch to alternate buffer (blank screen)
        alternateLines = nil
        lines = Array(repeating: TerminalLine(columns: columns, attributes: .default), count: rows)
        cursorRow = 0
        cursorColumn = 0
        activeAttributes = .default
        viewportOffset = 0
        wrapPending = false
        resetScrollingRegion()
        isAlternateBuffer = true
        
        markAllDirty()
    }

    public func leaveAlternateBuffer() {
        guard isAlternateBuffer else { return }
        
        // Discard alternate buffer content
        alternateLines = nil
        
        // Restore main buffer state
        if let saved = savedMainState {
            lines = saved.lines
            cursorRow = saved.cursorRow
            cursorColumn = saved.cursorColumn
            activeAttributes = saved.attributes
            viewportOffset = saved.viewportOffset
            scrollRegionTop = saved.scrollRegionTop
            scrollRegionBottom = saved.scrollRegionBottom
            wrapPending = false
            savedMainState = nil
        }
        
        isAlternateBuffer = false
        markAllDirty()
    }

    // MARK: - Cursor Save/Restore (DECSC/DECRC)

    public func saveCursor() {
        savedCursor = CursorState(row: cursorRow, column: cursorColumn, attributes: activeAttributes)
    }

    public func restoreCursor() {
        guard let saved = savedCursor else { return }
        cursorRow = saved.row
        cursorColumn = saved.column
        activeAttributes = saved.attributes
        wrapPending = false
        savedCursor = nil
        markAllDirty()
    }
}
