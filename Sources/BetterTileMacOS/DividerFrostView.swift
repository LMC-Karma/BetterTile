import AppKit

/// How a divider handle draws. Without Liquid Glass the handle is frosted grey.
/// Reduce Transparency and Increase Contrast make it opaque.
enum DividerHandleSurface: Equatable {
    case glass, frost, opaque

    init(liquidGlass: Bool, reduceTransparency: Bool, increaseContrast: Bool) {
        self = reduceTransparency || increaseContrast ? .opaque : liquidGlass ? .glass : .frost
    }
}

/// A HUD blur clipped to the handle outline, under a translucent grip tint and
/// a light rim. A transparent overlay window blurs the desktop behind it; an
/// opaque window, such as Settings, blurs its own content.
@MainActor
final class DividerFrostView: NSView {
    private let material = NSVisualEffectView()
    private let rim = NSView()
    private let tint = CAShapeLayer()
    private var maskKey: (path: CGPath, size: CGSize)?
    private(set) var fillColor: NSColor?

    override init(frame: CGRect) {
        super.init(frame: frame)
        material.material = .hudWindow
        material.state = .active
        rim.wantsLayer = true
        rim.layer?.addSublayer(tint)
        for view in [material, rim] {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            view.setAccessibilityElement(false)
            addSubview(view)
        }
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var blendingMode: NSVisualEffectView.BlendingMode { material.blendingMode }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        material.blendingMode = window?.isOpaque == false ? .behindWindow : .withinWindow
    }

    /// Call inside the caller's disabled-action transaction.
    func update(outline: CGPath, color: NSColor, progress: Double, scale: CGFloat) {
        if maskKey?.path != outline || maskKey?.size != bounds.size {
            maskKey = (outline, bounds.size)
            material.maskImage = NSImage(size: bounds.size, flipped: false) { _ in
                NSColor.black.setFill()
                NSBezierPath(cgPath: outline).fill()
                return true
            }
        }
        fillColor = color
        tint.frame = rim.bounds
        tint.path = outline
        tint.fillColor = color.cgColor
        tint.strokeColor = NSColor.white.withAlphaComponent(0.25 + 0.3 * progress).cgColor
        tint.lineWidth = 0.5 + 0.5 * progress
        tint.contentsScale = scale
    }
}
