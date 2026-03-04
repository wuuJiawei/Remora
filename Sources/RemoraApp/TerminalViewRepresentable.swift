import SwiftUI
import RemoraTerminal

struct TerminalViewRepresentable: NSViewRepresentable {
    @ObservedObject var runtime: TerminalRuntime
    var onFocus: () -> Void = {}

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(rows: 30, columns: 120)
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
