import AppKit
import BetterTileCore

/// Shared decorative glass. Controls stay in sibling views so glass never
/// changes hit testing. Strength changes the plate over native glass; AppKit
/// owns the blur itself.
@MainActor
class OverlayGlassView: NSView {
    let glass = NSGlassEffectView()
    private let plate = NSView()
    private let highlight = CAGradientLayer()
    var highlightsTop = false { didSet { refreshAppearance() } }
    var overlayAppearance = OverlayAppearance() { didSet { refreshAppearance() } }
    var cornerRadius: CGFloat = 10 { didSet { updateGeometry() } }
    var tint: NSColor? { didSet { refreshAppearance() } }
    var solidColor: NSColor? { didSet { refreshAppearance() } }
    var isLight = false { didSet { refreshAppearance() } }
    var frostFloor: Double = 0 { didSet { refreshAppearance() } }
    var displayOptions: () -> (reduceTransparency: Bool, increaseContrast: Bool) = {
        (NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
         NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
    }
    private(set) var plateOpacity = 0.0
    var showsGlass: Bool { !glass.isHidden }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        plate.wantsLayer = true
        highlight.startPoint = CGPoint(x: 0.5, y: 1)
        highlight.endPoint = CGPoint(x: 0.5, y: 0)
        plate.layer?.addSublayer(highlight)
        for view in [glass, plate] {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            view.setAccessibilityElement(false)
            addSubview(view)
        }
        setAccessibilityElement(false)
        refreshAppearance()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(refreshAppearance),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
    }

    required init?(coder: NSCoder) { nil }

    convenience init(content: NSView, appearance: OverlayAppearance, cornerRadius: CGFloat = 11) {
        self.init(frame: .zero)
        self.cornerRadius = cornerRadius
        overlayAppearance = appearance
        tint = .controlAccentColor
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() { refreshAppearance() }
    override func layout() {
        super.layout()
        highlight.frame = plate.bounds.insetBy(dx: 1, dy: 1)
        highlight.cornerRadius = max(0, cornerRadius - 1)
    }

    private func updateGeometry() {
        glass.cornerRadius = cornerRadius
        plate.layer?.cornerRadius = cornerRadius
        plate.layer?.cornerCurve = .continuous
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
    }

    @objc func refreshAppearance() {
        let options = displayOptions()
        let solid = !overlayAppearance.useLiquidGlass || options.reduceTransparency || options.increaseContrast
        let strength = overlayAppearance.strength.isFinite ? min(1, max(0, overlayAppearance.strength)) : 0.5
        glass.isHidden = solid
        glass.style = isLight || strength < 0.35 ? .clear : .regular
        glass.tintColor = tint?.withAlphaComponent(0.10 + strength * 0.12)
        plateOpacity = solid ? 1 : (frostFloor > 0
            ? frostFloor + strength * (1 - frostFloor) * 0.75
            : (isLight ? 0.03 : 0.08) + strength * (isLight ? 0.18 : 0.44))
        effectiveAppearance.performAsCurrentDrawingAppearance {
            plate.layer?.backgroundColor = (solid ? (solidColor ?? .windowBackgroundColor) : .windowBackgroundColor).withAlphaComponent(plateOpacity).cgColor
            plate.layer?.borderWidth = options.increaseContrast ? 1.5 : 0.7
            plate.layer?.borderColor = (tint ?? .separatorColor).withAlphaComponent(options.increaseContrast ? 1 : 0.45).cgColor
            highlight.isHidden = !highlightsTop || solid
            highlight.colors = [NSColor.white.withAlphaComponent(0.28).cgColor, NSColor.white.withAlphaComponent(0.02).cgColor]
        }
        updateGeometry()
    }
}
