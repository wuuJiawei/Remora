import AppKit
import SwiftUI

@MainActor
enum ViewScreenAnchorRegistry {
    static let transferQueueTarget = "transfer-queue-target"

    private static let registry = NSMapTable<NSString, NSView>(keyOptions: .strongMemory, valueOptions: .weakMemory)

    static func register(view: NSView, for key: String) {
        registry.setObject(view, forKey: key as NSString)
    }

    static func unregister(view: NSView, for key: String) {
        guard let current = registry.object(forKey: key as NSString), current === view else { return }
        registry.removeObject(forKey: key as NSString)
    }

    static func view(for key: String) -> NSView? {
        guard let view = registry.object(forKey: key as NSString), view.window != nil else {
            registry.removeObject(forKey: key as NSString)
            return nil
        }
        return view
    }

    static func screenRect(for key: String) -> CGRect? {
        guard let view = view(for: key) else { return nil }
        return CrossWindowFlyAnimator.screenRect(for: view)
    }

    static func screenPoint(for key: String) -> CGPoint? {
        screenRect(for: key)?.center
    }
}

struct ViewScreenAnchorBridge: NSViewRepresentable {
    let key: String

    func makeNSView(context: Context) -> AnchorRegistrationView {
        let view = AnchorRegistrationView()
        view.anchorKey = key
        ViewScreenAnchorRegistry.register(view: view, for: key)
        return view
    }

    func updateNSView(_ nsView: AnchorRegistrationView, context: Context) {
        nsView.anchorKey = key
        ViewScreenAnchorRegistry.register(view: nsView, for: key)
    }

    static func dismantleNSView(_ nsView: AnchorRegistrationView, coordinator: ()) {
        guard let key = nsView.anchorKey else { return }
        ViewScreenAnchorRegistry.unregister(view: nsView, for: key)
    }
}

final class AnchorRegistrationView: NSView {
    var anchorKey: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isHidden: Bool {
        get { true }
        set { }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let anchorKey {
            ViewScreenAnchorRegistry.register(view: self, for: anchorKey)
        }
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}
