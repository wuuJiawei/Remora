import SwiftUI

struct TerminalPaneView: View {
    @ObservedObject var pane: TerminalPaneModel
    var isFocused: Bool
    var onSelect: () -> Void
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 8) {
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
            .glassCard(
                radius: VisualStyle.smallRadius,
                fill: VisualStyle.rightPanelBackground,
                border: isFocused ? VisualStyle.borderStrong : VisualStyle.borderSoft
            )

            TerminalViewRepresentable(runtime: pane.runtime)
                .background(VisualStyle.terminalBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isFocused ? VisualStyle.borderStrong : VisualStyle.borderSoft, lineWidth: isFocused ? 2 : 1)
        )
        .padding(8)
        .contentShape(Rectangle())
        .scaleEffect(isHovering && !isFocused ? 1.004 : 1.0)
        .shadow(color: Color.black.opacity(isFocused ? 0.10 : 0.05), radius: isFocused ? 8 : 4, x: 0, y: 2)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.16)) {
                isHovering = hovering
            }
        }
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
