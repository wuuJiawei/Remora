import AppKit
import QuartzCore

@MainActor
final class CrossWindowFlyAnimator {
    struct Options {
        var duration: TimeInterval
        var controlPointYOffset: CGFloat
        var startScale: CGFloat
        var endScale: CGFloat
        var fadeOut: Bool
        var rotate: Bool
        var iconSize: CGSize
        var overlayPadding: CGFloat
        var targetBounceScale: CGFloat
        var targetHighlightColor: NSColor
        var targetHighlightDuration: TimeInterval

        static let `default` = Options(
            duration: 0.72,
            controlPointYOffset: 120,
            startScale: 1.0,
            endScale: 0.58,
            fadeOut: true,
            rotate: true,
            iconSize: NSSize(width: 22, height: 22),
            overlayPadding: 72,
            targetBounceScale: 1.08,
            targetHighlightColor: .controlAccentColor,
            targetHighlightDuration: 0.22
        )
    }

    static func animate(
        image: NSImage,
        from sourceView: NSView,
        to targetView: NSView?,
        fallbackTargetScreenPoint: CGPoint?,
        options: Options = .default,
        completion: (() -> Void)? = nil
    ) {
        guard let startRect = screenRect(for: sourceView) else {
            pulseSourceView(sourceView)
            completion?()
            return
        }

        let targetRect = targetView.flatMap(screenRect(for:))
        let resolvedEndRect: CGRect
        if let targetRect {
            resolvedEndRect = targetRect
        } else if let fallbackTargetScreenPoint {
            resolvedEndRect = CGRect(origin: fallbackTargetScreenPoint, size: .zero)
        } else {
            pulseSourceView(sourceView)
            completion?()
            return
        }

        animate(
            image: image,
            fromScreenRect: startRect,
            toScreenRect: resolvedEndRect,
            targetViewForFeedback: targetRect == nil ? nil : targetView,
            options: options,
            completion: completion
        )
    }

    static func animate(
        image: NSImage,
        fromScreenRect startRect: CGRect,
        toScreenRect endRect: CGRect,
        options: Options = .default,
        completion: (() -> Void)? = nil
    ) {
        animate(
            image: image,
            fromScreenRect: startRect,
            toScreenRect: endRect,
            targetViewForFeedback: nil,
            options: options,
            completion: completion
        )
    }

    static func screenRect(for view: NSView) -> CGRect? {
        guard let window = view.window,
              window.isVisible,
              window.occlusionState.contains(.visible),
              view.isHidden == false,
              view.alphaValue > 0.001
        else {
            return nil
        }

        let localRect = view.convert(view.bounds, to: nil)
        let screenRect = window.convertToScreen(localRect)
        guard screenRect.isNull == false, screenRect.isEmpty == false else {
            return nil
        }
        return screenRect
    }

    static func screenRect(for rect: CGRect, in view: NSView) -> CGRect? {
        guard let window = view.window,
              window.isVisible,
              window.occlusionState.contains(.visible),
              view.isHidden == false,
              view.alphaValue > 0.001
        else {
            return nil
        }

        let localRect = view.convert(rect, to: nil)
        let screenRect = window.convertToScreen(localRect)
        guard screenRect.isNull == false, screenRect.isEmpty == false else {
            return nil
        }
        return screenRect
    }

    static func screenPoint(for view: NSView) -> CGPoint? {
        screenRect(for: view)?.center
    }

    static func bounceAndHighlight(targetView: NSView, options: Options = .default) {
        guard targetView.window != nil, targetView.isHidden == false else { return }
        targetView.wantsLayer = true
        guard let layer = targetView.layer else { return }

        let originalBorderWidth = layer.borderWidth
        let originalBorderColor = layer.borderColor
        let originalShadowOpacity = layer.shadowOpacity
        let originalShadowRadius = layer.shadowRadius
        let originalShadowOffset = layer.shadowOffset
        let originalShadowColor = layer.shadowColor
        let originalTransform = layer.transform

        let highlightColor = options.targetHighlightColor.cgColor
        layer.borderColor = highlightColor
        layer.borderWidth = max(originalBorderWidth, 1.0)
        layer.shadowColor = highlightColor
        layer.shadowOpacity = 0.22
        layer.shadowRadius = 10
        layer.shadowOffset = .zero

        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [1.0, options.targetBounceScale, 0.985, 1.0]
        scale.keyTimes = [0, 0.42, 0.72, 1.0]
        scale.duration = 0.38
        scale.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeOut),
        ]

        let border = CABasicAnimation(keyPath: "borderWidth")
        border.fromValue = layer.borderWidth
        border.toValue = originalBorderWidth
        border.duration = options.targetHighlightDuration
        border.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let shadow = CABasicAnimation(keyPath: "shadowOpacity")
        shadow.fromValue = 0.22
        shadow.toValue = originalShadowOpacity
        shadow.duration = options.targetHighlightDuration
        shadow.timingFunction = CAMediaTimingFunction(name: .easeOut)

        CATransaction.begin()
        CATransaction.setCompletionBlock {
            layer.borderWidth = originalBorderWidth
            layer.borderColor = originalBorderColor
            layer.shadowOpacity = originalShadowOpacity
            layer.shadowRadius = originalShadowRadius
            layer.shadowOffset = originalShadowOffset
            layer.shadowColor = originalShadowColor
            layer.transform = originalTransform
        }
        layer.add(scale, forKey: "remora.target.bounce")
        layer.add(border, forKey: "remora.target.border")
        layer.add(shadow, forKey: "remora.target.shadow")
        CATransaction.commit()
    }

    static func pulseSourceView(_ view: NSView) {
        guard view.window != nil, view.isHidden == false else { return }
        view.wantsLayer = true
        guard let layer = view.layer else { return }

        let pulse = CAKeyframeAnimation(keyPath: "transform.scale")
        pulse.values = [1.0, 0.94, 1.02, 1.0]
        pulse.keyTimes = [0, 0.35, 0.7, 1.0]
        pulse.duration = 0.24
        pulse.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeOut),
        ]
        layer.add(pulse, forKey: "remora.source.pulse")
    }

    private static func animate(
        image: NSImage,
        fromScreenRect startRect: CGRect,
        toScreenRect endRect: CGRect,
        targetViewForFeedback: NSView?,
        options: Options,
        completion: (() -> Void)?
    ) {
        let overlayWindow = OverlayWindowFactory.makeWindow(
            covering: overlayFrame(for: startRect, endRect: endRect, padding: options.overlayPadding)
        )
        guard let contentView = overlayWindow.contentView as? OverlayContentView else {
            completion?()
            return
        }

        contentView.wantsLayer = true

        let startPoint = contentView.convertFromScreen(startRect.center)
        let endPoint = contentView.convertFromScreen(endRect.center)
        let iconRect = CGRect(
            origin: CGPoint(
                x: startPoint.x - (options.iconSize.width / 2),
                y: startPoint.y - (options.iconSize.height / 2)
            ),
            size: options.iconSize
        )

        let iconLayer = CALayer()
        iconLayer.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        iconLayer.contentsGravity = .resizeAspect
        iconLayer.frame = iconRect
        iconLayer.opacity = 1
        iconLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        contentView.layer?.addSublayer(iconLayer)

        overlayWindow.orderFrontRegardless()

        let positionAnimation = CAKeyframeAnimation(keyPath: "position")
        positionAnimation.path = flightPath(from: startPoint, to: endPoint, controlPointYOffset: options.controlPointYOffset)
        positionAnimation.calculationMode = .paced
        if options.rotate {
            positionAnimation.rotationMode = .rotateAuto
        }
        positionAnimation.duration = options.duration
        positionAnimation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        let scaleAnimation = CABasicAnimation(keyPath: "transform.scale")
        scaleAnimation.fromValue = options.startScale
        scaleAnimation.toValue = options.endScale
        scaleAnimation.duration = options.duration
        scaleAnimation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        let opacityAnimation = CABasicAnimation(keyPath: "opacity")
        opacityAnimation.fromValue = 1.0
        opacityAnimation.toValue = options.fadeOut ? 0.18 : 1.0
        opacityAnimation.duration = options.duration
        opacityAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let group = CAAnimationGroup()
        group.animations = [
            positionAnimation,
            scaleAnimation,
            opacityAnimation,
        ] + (options.rotate ? [rotationAnimation(duration: options.duration)] : [])
        group.duration = options.duration
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false

        CATransaction.begin()
        CATransaction.setCompletionBlock {
            iconLayer.removeAllAnimations()
            iconLayer.removeFromSuperlayer()
            overlayWindow.orderOut(nil)
            OverlayWindowFactory.destroy(window: overlayWindow)

            if let targetViewForFeedback,
               targetViewForFeedback.window != nil,
               targetViewForFeedback.isHidden == false,
               screenRect(for: targetViewForFeedback) != nil
            {
                bounceAndHighlight(targetView: targetViewForFeedback, options: options)
            }

            completion?()
        }

        let finalScale = CATransform3DMakeScale(options.endScale, options.endScale, 1)
        iconLayer.position = endPoint
        iconLayer.transform = finalScale
        if options.fadeOut {
            iconLayer.opacity = 0.18
        }
        iconLayer.add(group, forKey: "remora.cross-window-fly")
        CATransaction.commit()
    }

    private static func overlayFrame(for startRect: CGRect, endRect: CGRect, padding: CGFloat) -> CGRect {
        let union = startRect.union(endRect)
        let padded = union.insetBy(dx: -padding, dy: -padding)

        return padded
    }

    private static func flightPath(from startPoint: CGPoint, to endPoint: CGPoint, controlPointYOffset: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: startPoint)

        let deltaX = endPoint.x - startPoint.x
        let deltaY = endPoint.y - startPoint.y
        let midpoint = CGPoint(x: startPoint.x + (deltaX * 0.5), y: startPoint.y + (deltaY * 0.5))
        let travel = max(abs(deltaX), abs(deltaY))
        let arcHeight = max(48, min(controlPointYOffset + (travel * 0.12), 220))
        let controlPoint1 = CGPoint(
            x: startPoint.x + (deltaX * 0.18),
            y: max(startPoint.y, endPoint.y) + arcHeight
        )
        let controlPoint2 = CGPoint(
            x: midpoint.x + (deltaX * 0.16),
            y: max(startPoint.y, endPoint.y) + (arcHeight * 0.72)
        )

        path.addCurve(to: endPoint, control1: controlPoint1, control2: controlPoint2)
        return path
    }

    private static func rotationAnimation(duration: TimeInterval) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = 0
        animation.toValue = CGFloat.pi / 10
        animation.autoreverses = true
        animation.duration = duration * 0.42
        animation.repeatCount = 1
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return animation
    }

}

@MainActor
private enum OverlayWindowFactory {
    private static var windows: [ObjectIdentifier: NSWindow] = [:]

    static func makeWindow(covering screenFrame: CGRect) -> NSWindow {
        let window = OverlayAnimationWindow(
            contentRect: screenFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false

        let contentView = OverlayContentView(frame: CGRect(origin: .zero, size: screenFrame.size))
        contentView.wantsLayer = true
        contentView.layer?.masksToBounds = false
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView = contentView

        windows[ObjectIdentifier(window)] = window
        return window
    }

    static func destroy(window: NSWindow) {
        let identifier = ObjectIdentifier(window)
        window.contentView = nil
        windows.removeValue(forKey: identifier)
    }
}

private final class OverlayAnimationWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class OverlayContentView: NSView {
    override var isFlipped: Bool { false }

    func convertFromScreen(_ point: CGPoint) -> CGPoint {
        guard let window else { return point }
        let windowPoint = window.convertPoint(fromScreen: point)
        return convert(windowPoint, from: nil)
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}
