import Foundation

public final class ScreenBuffer {
    public private(set) var rows: Int
    public private(set) var columns: Int

    public private(set) var cursorRow: Int = 0
    public private(set) var cursorColumn: Int = 0
    public private(set) var activeAttributes: TerminalAttributes = .default

    public let scrollback: ScrollbackStore
    private var lines: [TerminalLine]
    private var dirtyRows: Set<Int> = []
    private var viewportOffset: Int = 0

    public init(rows: Int, columns: Int, scrollbackSegmentSize: Int = 1024) {
        self.rows = max(1, rows)
        self.columns = max(1, columns)
        self.scrollback = ScrollbackStore(segmentSize: scrollbackSegmentSize)
        self.lines = Array(repeating: TerminalLine(columns: max(1, columns)), count: max(1, rows))
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
        clampViewportOffset()
        markAllDirty()
    }

    public func applySGR(parameters: [Int]) {
        if parameters.isEmpty {
            activeAttributes = .default
            return
        }

        for code in parameters {
            switch code {
            case 0:
                activeAttributes = .default
            case 1:
                activeAttributes.bold = true
            case 4:
                activeAttributes.underline = true
            case 22:
                activeAttributes.bold = false
            case 24:
                activeAttributes.underline = false
            case 30 ... 37:
                activeAttributes.foreground = .indexed(UInt8(code - 30))
            case 39:
                activeAttributes.foreground = .default
            case 40 ... 47:
                activeAttributes.background = .indexed(UInt8(code - 40))
            case 49:
                activeAttributes.background = .default
            default:
                continue
            }
        }
    }

    public func moveCursor(row: Int? = nil, column: Int? = nil) {
        if let row {
            cursorRow = min(max(0, row), rows - 1)
        }
        if let column {
            cursorColumn = min(max(0, column), columns - 1)
        }
    }

    public func moveCursor(deltaRow: Int = 0, deltaColumn: Int = 0) {
        moveCursor(row: cursorRow + deltaRow, column: cursorColumn + deltaColumn)
    }

    public func put(character: Character) {
        if cursorRow >= rows { cursorRow = rows - 1 }
        if cursorColumn >= columns {
            lineFeed()
            carriageReturn()
        }

        lines[cursorRow][cursorColumn] = TerminalCell(character: character, attributes: activeAttributes)
        markDirty(row: cursorRow)
        cursorColumn += 1

        if cursorColumn >= columns {
            lineFeed()
            carriageReturn()
        }
    }

    public func lineFeed() {
        if cursorRow == rows - 1 {
            scrollback.append(lines[0])
            lines.removeFirst()
            lines.append(TerminalLine(columns: columns, attributes: activeAttributes))
            clampViewportOffset()
            markAllDirty()
        } else {
            cursorRow += 1
            markDirty(row: cursorRow)
        }
    }

    public func carriageReturn() {
        cursorColumn = 0
    }

    public func backspace() {
        cursorColumn = max(0, cursorColumn - 1)
        lines[cursorRow][cursorColumn] = TerminalCell(character: " ", attributes: activeAttributes)
        markDirty(row: cursorRow)
    }

    public func horizontalTab(tabWidth: Int = 8) {
        let width = max(1, tabWidth)
        let nextStop = ((cursorColumn / width) + 1) * width
        if nextStop >= columns {
            lineFeed()
            carriageReturn()
            return
        }
        cursorColumn = nextStop
    }

    public func clearScreen() {
        lines = Array(repeating: TerminalLine(columns: columns, attributes: .default), count: rows)
        cursorRow = 0
        cursorColumn = 0
        activeAttributes = .default
        viewportOffset = 0
        markAllDirty()
    }

    public func clearLine(mode: Int) {
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

    private func clampViewportOffset() {
        viewportOffset = min(max(0, viewportOffset), maxViewportOffset())
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
}
