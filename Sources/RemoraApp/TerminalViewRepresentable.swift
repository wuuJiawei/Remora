import SwiftUI
import RemoraTerminal

@MainActor
struct TerminalViewRepresentable: NSViewRepresentable {
    let pane: TerminalPaneModel
    @ObservedObject var runtime: TerminalRuntime
    var onFocus: () -> Void = {}

    func makeNSView(context: Context) -> TerminalView {
        let view = pane.terminalView
        view.onFocus = onFocus
        view.onResize = { columns, rows in
            runtime.resize(columns: columns, rows: rows)
        }
        runtime.attach(view: view)
        return view
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        nsView.onFocus = onFocus
        nsView.onResize = { columns, rows in
            runtime.resize(columns: columns, rows: rows)
        }
        runtime.attach(view: nsView)
    }
}
