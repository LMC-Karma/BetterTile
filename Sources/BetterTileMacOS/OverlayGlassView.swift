import AppKit
import BetterTileCore
import SwiftUI

/// Shared minimum radius for miniature tiles and chips in overlays and Settings.
public enum OverlayCornerRadius {
    public static let mini: CGFloat = 4
}

extension OverlayAppearance {
    /// Additional frosting only. The system owns the native material and optics.
    public var glassBackingOpacity: Double {
        (strength.isFinite ? min(1, max(0, strength)) : 0.5) * 0.22
    }
}

/// One surface for popups and choosers: the regular Tabbed glass,
/// its Glass transparency frosting, a lit rim, and the Settings radius family. The Settings picker
/// panel adds the soft window shadow. Glass off, Reduce Transparency and Increase Contrast
/// select the opaque system surface instead.
///
/// The backdrop stays visible, so legibility comes from the text: popup text uses the
/// primary label colour in every role, and size and weight carry the hierarchy.
public enum PopupGlass {
    // SettingsRadius.panel, .inner and .control by value. MacOS cannot import the app layer.
    public static let panelRadius: CGFloat = 12
    public static let innerRadius: CGFloat = 8
    public static let controlRadius: CGFloat = 6

    /// Shared popup floors. Light stays fixed while Dark can be calibrated for bright backdrops.
    public static let minimumPlateOpacity = 0.20
    public static let minimumDarkPlateOpacity = 0.35

    public static func plateOpacity(_ appearance: OverlayAppearance, appAppearance: NSAppearance,
                                    arguments: [String] = ProcessInfo.processInfo.arguments) -> Double {
        let dark = appAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        var floor = dark ? minimumDarkPlateOpacity : minimumPlateOpacity
#if DEBUG
        // Launch arguments only: saved defaults must never change a later run's material.
        if dark, let index = arguments.lastIndex(of: "-BetterTilePopupDarkPlateFloor"),
           arguments.indices.contains(index + 1), let value = Double(arguments[index + 1]), value.isFinite {
            // Calibration bounds stay independent of the compiled Dark floor.
            floor = min(0.60, max(0.20, value))
        }
#endif
        return max(floor, appearance.glassBackingOpacity)
    }

    /// Secondary text on popup glass. The system's secondary colour is too faint over a moving backdrop.
    public static var secondaryLabelColor: NSColor { .labelColor }
    // Keep SwiftUI's semantic foreground role. Converting NSColor to Color here
    // fixes a colour before the native glass can adapt the foreground.
    public static var secondaryText: HierarchicalShapeStyle { .primary }

    /// Full label opacity keeps placeholders legible over mismatched glass backdrops.
    public static let placeholderAlpha = 1.0
    public static var placeholderTextColor: NSColor {
        // Keep the semantic label colour so native glass can adapt its foreground.
        NSColor.labelColor.withAlphaComponent(placeholderAlpha)
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

/// Shared glass. Decorative instances pass through input. Content-bearing popup
/// instances put controls in the native contentView for foreground adaptation.
/// Strength changes only the frost plate; AppKit owns the blur.
@MainActor
class OverlayGlassView: NSView {
    let glass = NSGlassEffectView()
    let plate: NSView = OverlayDecorationView()
    private(set) var popupContent: NSView?
    private let foreground = PopupGlassContentView()
    private var contentFillsBounds = true
    private let highlight = CAGradientLayer()
    var showsBorder = true { didSet { refreshAppearance() } }
    var highlightsTop = false { didSet { refreshAppearance() } }
    var overlayAppearance = OverlayAppearance() { didSet { refreshAppearance() } }
    var cornerRadius: CGFloat = 10 { didSet { updateGeometry() } }
    var tint: NSColor? { didSet { refreshAppearance() } }
    var solidColor: NSColor? { didSet { refreshAppearance() } }
    var isLight = false { didSet { refreshAppearance() } }
    /// The shared Tabbed backdrop keeps a frost floor even at Clear, without
    /// adding an outline around its work-area-sized surface.
    var isCurtain = false { didSet { refreshAppearance() } }
    /// Popups carry text over any window, so they keep
    /// regular glass and a lit rim.
    var isPopup = false { didSet { refreshAppearance() } }
    // Injectable process input for offscreen tests; all popup hosts share the same calculation.
    var popupLaunchArguments: () -> [String] = { ProcessInfo.processInfo.arguments }
    private let rim = CAGradientLayer()
    private let rimShape = CAShapeLayer()
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
        // A one-point light stroke inside the outline, brightest at the top.
        rim.startPoint = CGPoint(x: 0.5, y: 1)
        rim.endPoint = CGPoint(x: 0.5, y: 0)
        rimShape.fillColor = nil
        rimShape.strokeColor = NSColor.black.cgColor
        rimShape.lineWidth = 1
        rim.mask = rimShape
        plate.layer?.addSublayer(rim)
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
    /// A popup's controls remain reachable; decorative plates and rims never catch clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        popupContent == nil ? nil : super.hitTest(point)
    }

    func setPopupContent(_ content: NSView?, fillsBounds: Bool = true) {
        guard popupContent !== content else { return }
        popupContent?.removeFromSuperview()
        popupContent = content
        contentFillsBounds = fillsBounds
        if let content {
            foreground.addSubview(content)
        }
        refreshAppearance()
    }

    private func updateContentHost(solid: Bool) {
        guard let content = popupContent else {
            glass.contentView = nil
            foreground.removeFromSuperview()
            if plate.superview !== self { addSubview(plate) }
            plate.frame = bounds
            return
        }
        let window = self.window
        let responder = window?.firstResponder
        let editorOwner = (responder as? NSTextView)?.delegate as? NSView
        let moving = solid ? foreground.superview !== self : glass.contentView !== foreground
        // The native view is hidden for opaque fallback, so move the same host above
        // the fallback plate. Keep controls, state and the responder alive in both paths.
        if solid {
            if foreground.superview !== self {
                glass.contentView = nil
                foreground.translatesAutoresizingMaskIntoConstraints = true
                addSubview(foreground)
            }
        } else if glass.contentView !== foreground {
            foreground.removeFromSuperview()
            glass.contentView = foreground
        }
        foreground.frame = bounds
        foreground.autoresizingMask = [.width, .height]
        if plate.superview !== foreground { foreground.addSubview(plate, positioned: .below, relativeTo: nil) }
        plate.frame = foreground.bounds
        if contentFillsBounds {
            content.frame = foreground.bounds
            content.autoresizingMask = [.width, .height]
        }
        if moving, let window, let responder {
            window.makeFirstResponder(editorOwner ?? responder)
        }
    }
    override func viewDidChangeEffectiveAppearance() { refreshAppearance() }
    override func layout() {
        super.layout()
        updateContentHost(solid: !showsGlass)
        highlight.frame = plate.bounds.insetBy(dx: 1, dy: 1)
        highlight.cornerRadius = max(0, cornerRadius - 1)
        updateRimPath()
    }

    private func updateRimPath() {
        rim.frame = plate.bounds
        rimShape.frame = rim.bounds
        let inset = rim.bounds.insetBy(dx: 1.5, dy: 1.5)
        let radius = max(0, min(cornerRadius - 1.5, inset.width / 2, inset.height / 2))
        rimShape.path = inset.isEmpty ? nil : CGPath(roundedRect: inset, cornerWidth: radius, cornerHeight: radius, transform: nil)
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
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if !solid { glass.isHidden = false }
        glass.style = isLight && !isCurtain && !isPopup ? .clear : .regular
        glass.tintColor = tint?.withAlphaComponent(0.06)
        plateOpacity = solid ? 1 : isPopup ? PopupGlass.plateOpacity(overlayAppearance, appAppearance: effectiveAppearance, arguments: popupLaunchArguments())
            : (isCurtain ? 0.14 + overlayAppearance.glassBackingOpacity
            : overlayAppearance.glassBackingOpacity * (isLight ? 0.5 : 1))
        effectiveAppearance.performAsCurrentDrawingAppearance {
            plate.layer?.backgroundColor = (solid ? (solidColor ?? .windowBackgroundColor) : .windowBackgroundColor).withAlphaComponent(plateOpacity).cgColor
            plate.layer?.borderWidth = isCurtain || !showsBorder ? 0
                : (isPopup && solid ? 1 : (options.increaseContrast ? 1.5 : 0.7))
            plate.layer?.borderColor = (tint ?? .separatorColor)
                .withAlphaComponent(options.increaseContrast ? 1 : (isPopup ? 0.12 : 0.45)).cgColor
            highlight.isHidden = !highlightsTop || solid
            highlight.colors = [NSColor.white.withAlphaComponent(0.28).cgColor, NSColor.white.withAlphaComponent(0.02).cgColor]
            rim.isHidden = !isPopup || solid || !showsBorder
            rim.colors = [NSColor.white.withAlphaComponent(dark ? 0.5 : 0.9).cgColor,
                          NSColor.white.withAlphaComponent(dark ? 0.12 : 0.35).cgColor]
        }
        updateContentHost(solid: solid)
        glass.isHidden = solid
        updateGeometry()
        updateRimPath()
    }
}

@MainActor private final class OverlayDecorationView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor private final class PopupGlassContentView: NSView {
    override var isFlipped: Bool { true }
}

/// A content-bearing popup surface shared with application-level Settings panels.
@MainActor public final class PopupGlassHost: NSView {
    let backing = OverlayGlassView()
    public var overlayAppearance: OverlayAppearance {
        get { backing.overlayAppearance }
        set { backing.overlayAppearance = newValue }
    }

    public init(content: NSView, appearance: OverlayAppearance = OverlayAppearance()) {
        super.init(frame: content.frame)
        wantsLayer = true
        layer?.cornerRadius = PopupGlass.panelRadius
        layer?.masksToBounds = true
        backing.frame = bounds
        backing.autoresizingMask = [.width, .height]
        backing.cornerRadius = PopupGlass.panelRadius
        backing.isPopup = true
        backing.overlayAppearance = appearance
        addSubview(backing)
        backing.setPopupContent(content)
    }
    public required init?(coder: NSCoder) { nil }
}
