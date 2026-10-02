import AppKit
import BetterTileCore
import SwiftUI

extension OverlayAppearance {
    /// Additional frosting only. The system owns the native material and optics.
    public var glassBackingOpacity: Double {
        (strength.isFinite ? min(1, max(0, strength)) : 0.5) * 0.22
    }
}

/// Used over the system popover material as well as our custom glass surfaces.
public struct GlassBacking: View {
    private let appearance: OverlayAppearance
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    public init(_ appearance: OverlayAppearance) { self.appearance = appearance }

    public var body: some View {
        Color(nsColor: .windowBackgroundColor).opacity(
            !appearance.useLiquidGlass || reduceTransparency || contrast == .increased
                ? 1 : appearance.glassBackingOpacity
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

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
        glass.isHidden = solid
        glass.style = isLight ? .clear : .regular
        glass.tintColor = tint?.withAlphaComponent(0.06)
        plateOpacity = solid ? 1 : overlayAppearance.glassBackingOpacity * (isLight ? 0.5 : 1)
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
