import AppKit
import SwiftUI
import Testing
@testable import RemoraApp

@Suite(.serialized)
@MainActor
struct SidebarMenuIconButtonTests {
    @Test
    func hidesMenuIndicatorInLightAndDarkAppearances() {
        assertSingleQuestionMarkRendering(for: .aqua)
        assertSingleQuestionMarkRendering(for: .darkAqua)
    }

    private func assertSingleQuestionMarkRendering(for appearanceName: NSAppearance.Name) {
        let host = NSHostingView(
            rootView: SidebarMenuIconButton(systemImage: "questionmark.circle") {
                Button("Action") {}
            }
        )
        host.appearance = NSAppearance(named: appearanceName)
        host.frame = NSRect(x: 0, y: 0, width: 120, height: 60)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        let allSubviews = recursiveSubviews(in: host)
        let popupButtons = allSubviews.compactMap { $0 as? NSButton }
        #expect(!popupButtons.isEmpty, "Expected a popup button for the sidebar help menu in \(appearanceName.rawValue).")

        let indicatorViews = allSubviews.filter { String(describing: type(of: $0)) == "NSPopUpIndicatorView" }
        #expect(indicatorViews.isEmpty, "Sidebar help menu should not render an extra popup indicator in \(appearanceName.rawValue).")

        let imageViews = allSubviews.filter { String(describing: type(of: $0)) == "NSButtonImageView" }
        #expect(imageViews.count == 1, "Sidebar help menu should render exactly one icon in \(appearanceName.rawValue).")

        if let popupButton = popupButtons.first {
            #expect(popupButton.frame.width <= 26.5, "Sidebar help menu button should stay compact after hiding the menu indicator in \(appearanceName.rawValue).")
            #expect(popupButton.image != nil, "Sidebar help menu button should still render the question mark icon in \(appearanceName.rawValue).")
        }
    }

    private func recursiveSubviews(in root: NSView) -> [NSView] {
        root.subviews + root.subviews.flatMap { recursiveSubviews(in: $0) }
    }
}
