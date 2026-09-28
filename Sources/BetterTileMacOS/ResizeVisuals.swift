import AppKit
import BetterTileCore

/// The one straight-handle and cursor language shared by Native, Bento, and
/// Tabbed dividers. Junction handles keep their own drawing.
@MainActor
enum ResizeHandleStyle {
    enum Baseline {
        /// Always-visible handles, such as Tabbed dividers, stay quiet at rest.
        case rest
        /// Handles that appear only near the pointer start from the hover look.
        case hover
    }

    /// The capsule's cross-axis width. `thickness` is the Divider width setting.
    static func capsuleWidth(thickness: CGFloat, progress: Double) -> CGFloat {
        let resting = max(3, thickness * 0.5)
        let active = max(4, thickness * 0.6)
        return resting + (active - resting) * CGFloat(progress)
    }

    /// Draws the capsule in the current graphics context. `progress` runs
    /// from the baseline look (0) to the active accent look (1). A limited
    /// handle uses orange: a neighbor has reached its minimum size.
    static func drawCapsule(_ rect: CGRect, progress: Double, baseline: Baseline, limited: Bool = false) {
        guard rect.width > 0, rect.height > 0 else { return }
        let radius = min(rect.width, rect.height) / 2
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        let workspace = NSWorkspace.shared
        let isDark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let base: NSColor = switch baseline {
        case .rest: isDark ? NSColor(white: 0.78, alpha: 0.7) : NSColor(white: 0.3, alpha: 0.55)
        case .hover: isDark ? NSColor(white: 0.92, alpha: 0.92) : NSColor(white: 0.18, alpha: 0.8)
        }
        let accent: NSColor = limited ? .systemOrange : .controlAccentColor
        let fill = base.blended(withFraction: progress, of: accent) ?? accent
        let glow = NSColor.black.withAlphaComponent(0.28)
            .blended(withFraction: progress, of: accent.withAlphaComponent(0.55)) ?? accent

        NSGraphicsContext.saveGraphicsState()
        if !workspace.accessibilityDisplayShouldReduceTransparency {
            let shadow = NSShadow()
            shadow.shadowColor = glow
            shadow.shadowBlurRadius = 4 + 6 * progress
            shadow.shadowOffset = NSSize(width: 0, height: -1 + progress)
            shadow.set()
        }
        fill.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        if progress > 0 {
            NSColor.white.withAlphaComponent(0.45 * progress).setStroke()
            let rim = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
            rim.lineWidth = 1
            rim.stroke()
        }
        if workspace.accessibilityDisplayShouldIncreaseContrast {
            NSColor.labelColor.withAlphaComponent(0.6).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    /// macOS 15 divider cursors. A vertical divider moves along x.
    static func cursor(verticalDivider: Bool) -> NSCursor {
        verticalDivider ? .columnResize : .rowResize
    }

    /// Junctions move two dividers at once, like a window corner.
    static var junctionCursor: NSCursor {
        .frameResize(position: .bottomRight, directions: .all)
    }
}

/// One refined ghost frame: a frosted, lightly tinted region with a thin
/// accent border and a caption platter sized to the space available.
@MainActor
final class GhostPreviewView: NSView {
    enum CaptionLevel: Equatable {
        case full, iconAndSize, size, stacked, widthOnly
    }

    private let region = NSVisualEffectView()
    private let tint = NSView()
    private let platterShadow = NSView()
    private let platter = NSVisualEffectView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")
    private let secondLabel = NSTextField(labelWithString: "")
    private let limitLabel = NSTextField(labelWithString: "")
    private(set) var captionLevel = CaptionLevel.full
    private(set) var isLimited = false
    private var size = BTSize(width: 0, height: 0)
    private var limitText: String?

    init(frame: CGRect, snapshot: WindowSnapshot?) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false

        region.material = .popover
        region.blendingMode = .behindWindow
        region.state = .active
        region.wantsLayer = true
        region.layer?.cornerRadius = 12
        region.layer?.cornerCurve = .continuous
        region.layer?.masksToBounds = true
        region.frame = bounds
        region.autoresizingMask = [.width, .height]
        addSubview(region)

        tint.wantsLayer = true
        tint.layer?.cornerRadius = 12
        tint.layer?.cornerCurve = .continuous
        tint.frame = bounds
        tint.autoresizingMask = [.width, .height]
        addSubview(tint)

        platterShadow.wantsLayer = true
        platterShadow.layer?.shadowOpacity = 1
        platterShadow.layer?.shadowOffset = CGSize(width: 0, height: -4)
        platterShadow.layer?.shadowRadius = 14
        addSubview(platterShadow)

        platter.material = .popover
        platter.blendingMode = .withinWindow
        platter.state = .active
        platter.wantsLayer = true
        platter.layer?.cornerCurve = .continuous
        platter.layer?.masksToBounds = true
        platter.layer?.borderWidth = 0.5
        platterShadow.addSubview(platter)

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        for label in [sizeLabel, secondLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            label.lineBreakMode = .byClipping
        }
        iconView.imageScaling = .scaleProportionallyUpOrDown
        limitLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        limitLabel.textColor = .systemOrange
        limitLabel.lineBreakMode = .byTruncatingTail
        for view in [iconView, titleLabel, sizeLabel, secondLabel, limitLabel] as [NSView] {
            platter.addSubview(view)
        }
        setAccessibilityElement(false)
        update(snapshot: snapshot, size: BTSize(width: frame.width, height: frame.height))
    }

    required init?(coder: NSCoder) { nil }

    func update(snapshot: WindowSnapshot?, size: BTSize, limited: Bool = false) {
        let title = snapshot?.title.isEmpty == false ? snapshot!.title : snapshot?.bundleIdentifier ?? "Window"
        if titleLabel.stringValue != title { titleLabel.stringValue = title }
        if iconView.image == nil, let pid = snapshot?.processIdentifier {
            iconView.image = NSRunningApplication(processIdentifier: pid)?.icon
        }
        self.size = size
        isLimited = limited
        limitText = nil
        if limited, let constraints = snapshot?.constraints {
            let atWidth = size.width <= constraints.minimumSize.width + 0.5
            let atHeight = size.height <= constraints.minimumSize.height + 0.5
            limitText = atWidth ? "Minimum width" : atHeight ? "Minimum height" : "Minimum size"
        }
        updateColors()
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let accent: NSColor = isLimited ? .systemOrange : .controlAccentColor
            let workspace = NSWorkspace.shared
            tint.layer?.backgroundColor = accent.withAlphaComponent(isDark ? 0.16 : 0.12).cgColor
            layer?.borderWidth = workspace.accessibilityDisplayShouldIncreaseContrast ? 2 : 1.25
            layer?.borderColor = accent.withAlphaComponent(0.85).cgColor
            platter.layer?.borderColor = NSColor.separatorColor.cgColor
            platterShadow.layer?.shadowColor = NSColor.black.withAlphaComponent(isDark ? 0.45 : 0.16).cgColor
            let sizeColor: NSColor = isLimited ? .systemOrange : .secondaryLabelColor
            sizeLabel.textColor = sizeColor
            secondLabel.textColor = captionLevel == .stacked ? .tertiaryLabelColor : sizeColor
        }
    }

    override func layout() {
        super.layout()
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        let sizeText = "\(width) × \(height)"
        let available = bounds.width - 20
        let singleSize = measure("\(width) × \(height)", font: sizeLabel.font!)
        let stackedWidth = max(measure("\(width)", font: sizeLabel.font!), measure("\(height)", font: sizeLabel.font!))
        let hasIcon = iconView.image != nil
        let level: CaptionLevel = if available >= 170, bounds.height >= 70 {
            .full
        } else if hasIcon, available >= 12 + 22 + 8 + singleSize + 12, bounds.height >= 44 {
            .iconAndSize
        } else if available >= singleSize + 16 {
            .size
        } else if available >= stackedWidth + 14, bounds.height >= 44 {
            .stacked
        } else {
            .widthOnly
        }
        captionLevel = level
        updateColors()

        iconView.isHidden = level != .full && level != .iconAndSize
        titleLabel.isHidden = level != .full
        secondLabel.isHidden = level != .stacked
        // Only the full caption has room to name the limit; smaller ones
        // rely on the orange frame and size.
        limitLabel.isHidden = level != .full || limitText == nil
        limitLabel.stringValue = limitText ?? ""
        let platterFrame: CGRect
        switch level {
        case .full:
            sizeLabel.stringValue = sizeText
            let extra: CGFloat = limitText == nil ? 0 : 15
            let content = max(
                measure(titleLabel.stringValue, font: titleLabel.font!),
                measure(sizeText, font: sizeLabel.font!),
                limitText.map { measure($0, font: limitLabel.font!) } ?? 0
            )
            let iconSpace: CGFloat = hasIcon ? 42 : 0
            let platterWidth = min(available, min(300, 12 + iconSpace + content + 14))
            let platterHeight = 52 + extra
            platterFrame = CGRect(x: bounds.midX - platterWidth / 2, y: bounds.midY - platterHeight / 2, width: platterWidth, height: platterHeight)
            iconView.frame = CGRect(x: 12, y: (platterHeight - 32) / 2, width: 32, height: 32)
            let textX = 12 + iconSpace, textWidth = platterWidth - textX - 12
            titleLabel.frame = CGRect(x: textX, y: 26 + extra, width: textWidth, height: 18)
            sizeLabel.frame = CGRect(x: textX, y: 8 + extra, width: textWidth, height: 16)
            limitLabel.frame = CGRect(x: textX, y: 7, width: textWidth, height: 15)
        case .iconAndSize:
            sizeLabel.stringValue = "\(width) × \(height)"
            sizeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            let platterWidth = min(available, 12 + 22 + 8 + singleSize + 12)
            platterFrame = CGRect(x: bounds.midX - platterWidth / 2, y: bounds.midY - 17, width: platterWidth, height: 34)
            iconView.frame = CGRect(x: 10, y: 6, width: 22, height: 22)
            sizeLabel.frame = CGRect(x: 40, y: 8, width: platterWidth - 44, height: 16)
        case .size:
            sizeLabel.stringValue = "\(width) × \(height)"
            let platterWidth = singleSize + 16
            platterFrame = CGRect(x: bounds.midX - platterWidth / 2, y: bounds.midY - 12, width: platterWidth, height: 24)
            sizeLabel.frame = CGRect(x: 8, y: 4, width: platterWidth - 12, height: 16)
        case .stacked:
            sizeLabel.stringValue = "\(width)"
            secondLabel.stringValue = "\(height)"
            let platterWidth = stackedWidth + 14
            platterFrame = CGRect(x: bounds.midX - platterWidth / 2, y: bounds.midY - 19, width: platterWidth, height: 38)
            sizeLabel.alignment = .center
            secondLabel.alignment = .center
            sizeLabel.frame = CGRect(x: 0, y: 19, width: platterWidth, height: 16)
            secondLabel.frame = CGRect(x: 0, y: 3, width: platterWidth, height: 16)
        case .widthOnly:
            sizeLabel.stringValue = "\(width)"
            let platterWidth = min(max(8, available), measure("\(width)", font: sizeLabel.font!) + 10)
            platterFrame = CGRect(x: bounds.midX - platterWidth / 2, y: bounds.midY - 11, width: platterWidth, height: 22)
            sizeLabel.alignment = .center
            sizeLabel.frame = CGRect(x: 0, y: 3, width: platterWidth, height: 16)
        }
        if level != .stacked, level != .widthOnly { sizeLabel.alignment = .left }
        platterShadow.frame = platterFrame
        platter.frame = platterShadow.bounds
        let radius = platterFrame.height >= 34 ? min(12, platterFrame.width / 2) : platterFrame.height / 2
        platter.layer?.cornerRadius = radius
        platterShadow.layer?.shadowPath = CGPath(
            roundedRect: platterShadow.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil
        )
    }

    private func measure(_ text: String, font: NSFont) -> CGFloat {
        // Text fields inset their content slightly beyond the glyph width.
        ceil((text as NSString).size(withAttributes: [.font: font]).width) + 5
    }
}
