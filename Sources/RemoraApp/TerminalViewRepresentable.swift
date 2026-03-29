import SwiftUI
import RemoraTerminal

@MainActor
struct TerminalViewRepresentable: NSViewRepresentable {
    let pane: TerminalPaneModel
    @ObservedObject var runtime: TerminalRuntime
    var onFocus: () -> Void = {}
    private var actionLabels: TerminalActionLabels {
        TerminalActionLabels(
            copy: tr("Copy"),
            paste: tr("Paste"),
            selectAll: tr("Select All"),
            clearScreen: tr("Clear Screen")
        )
    }

    func makeNSView(context: Context) -> TerminalView {
        let view = pane.terminalView
        configure(view)
        return view
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: TerminalView) {
        view.onFocus = onFocus
        view.onClearScreen = {
            runtime.clearScreen()
        }
        view.onResize = { columns, rows in
            runtime.resize(columns: columns, rows: rows)
        }
        view.actionLabels = actionLabels
        runtime.attach(view: view)
    }
}
