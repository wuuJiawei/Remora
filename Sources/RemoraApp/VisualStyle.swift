import AppKit
import SwiftUI

enum VisualStyle {
    static let pagePadding: CGFloat = 14
    static let panelSpacing: CGFloat = 12
    static let cardRadius: CGFloat = 14
    static let smallRadius: CGFloat = 10

    static let leftSidebarBackground = Color(nsColor: .controlBackgroundColor)
    static let leftInteractiveBackground = Color(nsColor: .selectedContentBackgroundColor).opacity(0.2)
    static let leftHoverBackground = Color(nsColor: .selectedContentBackgroundColor).opacity(0.14)
    static let leftSelectedBackground = Color(nsColor: .selectedContentBackgroundColor).opacity(0.28)
    static let rightPanelBackground = Color(nsColor: .textBackgroundColor)
    static let terminalBackground = Color.black

    static let textPrimary = Color(nsColor: .labelColor)
    static let textSecondary = Color(nsColor: .secondaryLabelColor)
    static let textTertiary = Color(nsColor: .tertiaryLabelColor)

    static let borderStrong = Color(nsColor: .separatorColor).opacity(0.9)
    static let borderNormal = Color(nsColor: .separatorColor).opacity(0.7)
    static let borderSoft = Color(nsColor: .separatorColor).opacity(0.45)

    static let shadowColor = Color.black.opacity(0.12)
}

private struct GlassCardModifier: ViewModifier {
    var radius: CGFloat
    var fill: Color
    var border: Color

    func body(content: Content) -> some View {
        content
            .background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(border, lineWidth: 1)
            )
            .shadow(color: VisualStyle.shadowColor, radius: 10, x: 0, y: 4)
    }
}

extension View {
    func glassCard(
        radius: CGFloat = VisualStyle.cardRadius,
        fill: Color = VisualStyle.rightPanelBackground,
        border: Color = VisualStyle.borderNormal
    ) -> some View {
        modifier(GlassCardModifier(radius: radius, fill: fill, border: border))
    }

    func panelTitleStyle() -> some View {
        self
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(VisualStyle.textPrimary)
    }

    func monoMetaStyle() -> some View {
        self
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(VisualStyle.textSecondary)
    }
}
