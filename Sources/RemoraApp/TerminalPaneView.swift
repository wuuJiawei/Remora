import SwiftUI

struct TerminalPaneView: View {
    @ObservedObject var pane: TerminalPaneModel
    var isFocused: Bool
    var onSelect: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)

                Text(pane.runtime.connectionState)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .foregroundStyle(VisualStyle.textPrimary)

                Spacer()

                Image(systemName: isFocused ? "cursorarrow.motionlines" : "cursorarrow")
                    .font(.caption)
                    .foregroundStyle(VisualStyle.textSecondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(VisualStyle.rightPanelBackground)

            Divider()
                .overlay(VisualStyle.borderSoft)

            TerminalViewRepresentable(runtime: pane.runtime)
                .background(VisualStyle.terminalBackground)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(VisualStyle.rightPanelBackground)
        .overlay(
            Rectangle()
                .stroke(isFocused ? VisualStyle.borderStrong : VisualStyle.borderSoft, lineWidth: isFocused ? 2 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .animation(.spring(response: 0.24, dampingFraction: 0.85), value: isFocused)
        .animation(.easeInOut(duration: 0.18), value: pane.runtime.connectionState)
    }

    private var statusColor: Color {
        if pane.runtime.connectionState.hasPrefix("Connected") {
            return .green
        }
        if pane.runtime.connectionState.hasPrefix("Failed") {
            return .red
        }
        if pane.runtime.connectionState == "Connecting" {
            return .orange
        }
        return .secondary
    }
}
