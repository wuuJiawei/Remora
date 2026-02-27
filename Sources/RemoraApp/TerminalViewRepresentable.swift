import SwiftUI
import RemoraTerminal

struct TerminalViewRepresentable: NSViewRepresentable {
    @ObservedObject var runtime: TerminalRuntime
    var onFocus: () -> Void = {}

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(rows: 30, columns: 120)
        view.onFocus = onFocus
        runtime.attach(view: view)
        return view
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        nsView.onFocus = onFocus
        runtime.attach(view: nsView)
    }
}
