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
    static let inputFieldBackground = Color(nsColor: .textBackgroundColor)
    static let settingsPaneBackground = Color(nsColor: .underPageBackgroundColor)
    static let settingsSurfaceBackground = Color(nsColor: .controlBackgroundColor)
    static let settingsSelectedTabBackground = Color(nsColor: .selectedContentBackgroundColor).opacity(0.24)
    static let chipBackground = Color(nsColor: .separatorColor).opacity(0.22)
    static let mutedSurfaceBackground = Color(nsColor: .quaternaryLabelColor).opacity(0.14)
    static let elevatedSurfaceBackground = Color(nsColor: .controlBackgroundColor).opacity(0.78)
    static let metricTrackBackground = Color(nsColor: .separatorColor).opacity(0.34)
    static let overlayBackground = Color(nsColor: .controlBackgroundColor).opacity(0.92)

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
    var showsShadow: Bool

    func body(content: Content) -> some View {
        let base = content
            .background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(border, lineWidth: 1)
            )

        if showsShadow {
            base.shadow(color: VisualStyle.shadowColor, radius: 10, x: 0, y: 4)
        } else {
            base
        }
    }
}

extension View {
    func glassCard(
        radius: CGFloat = VisualStyle.cardRadius,
        fill: Color = VisualStyle.rightPanelBackground,
        border: Color = VisualStyle.borderNormal,
        showsShadow: Bool = true
    ) -> some View {
        modifier(GlassCardModifier(radius: radius, fill: fill, border: border, showsShadow: showsShadow))
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
