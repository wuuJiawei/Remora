import AppKit
import Foundation
@preconcurrency import SwiftTerm

public final class TerminalView: SwiftTerm.TerminalView, @preconcurrency SwiftTerm.TerminalViewDelegate {
    public var onInput: (@Sendable (Data) -> Void)?
    public var onFocus: (() -> Void)?
    public var onResize: ((Int, Int) -> Void)?

    public init(rows: Int = 30, columns: Int = 120) {
        super.init(frame: .zero)
        configure(rows: rows, columns: columns)
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure(rows: 30, columns: 120)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
            self.onFocus?()
        }
    }

    public func feed(data: Data) {
        feed(byteArray: ArraySlice(data))
    }

    private func configure(rows: Int, columns: Int) {
        terminalDelegate = self
        allowMouseReporting = true
        optionAsMetaKey = true
        notifyUpdateChanges = true
        resize(cols: columns, rows: rows)
        frame = getOptimalFrameSize()
    }

    public func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
        onResize?(newCols, newRows)
    }

    public func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}

    public func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}

    public func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
        onInput?(Data(data))
    }

    public func scrolled(source: SwiftTerm.TerminalView, position: Double) {}

    public func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String : String]) {
        guard let url = URL(string: link) else { return }
        NSWorkspace.shared.open(url)
    }

    public func bell(source: SwiftTerm.TerminalView) {}

    public func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
        guard let value = String(data: content, encoding: .utf8) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    public func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}

    public func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
}
