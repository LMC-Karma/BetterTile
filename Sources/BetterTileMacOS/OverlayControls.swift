// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma

import AppKit
import SwiftUI

// Buttons and links for non-activating overlay windows (Tabbed panes, the request panel,
// the chooser). These windows are rarely key, so emphasis never depends on key state:
// stock macOS buttons would draw grey there. Settings and the Add panels keep stock buttons.

extension PopupGlass {
    /// Keep the accent hue, with enough shade for white text at 4.6:1 (the 4.5:1 floor plus margin).
    /// Selected rows and primary overlay buttons share this helper.
    public static func accentShade(for accent: NSColor) -> NSColor {
        let accent = accent.usingColorSpace(.sRGB) ?? .systemBlue
        func luminance(_ scale: Double) -> Double {
            let rgb = [accent.redComponent, accent.greenComponent, accent.blueComponent].map { value in
                let v = value * scale
                return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]
        }
        let ceiling = 1.05 / 4.6 - 0.05
        var low = 0.0, high = 1.0
        if luminance(1) <= ceiling { low = 1 }
        else {
            for _ in 0..<16 {
                let middle = (low + high) / 2
                if luminance(middle) <= ceiling { low = middle } else { high = middle }
            }
        }
        return NSColor(srgbRed: accent.redComponent * low, green: accent.greenComponent * low,
                       blue: accent.blueComponent * low, alpha: 1)
    }

    /// The accent, shaded for white text. Resolves with the drawing appearance.
    public static var accentShadeColor: NSColor {
        NSColor(name: nil) { appearance in
            var color: NSColor!
            appearance.performAsCurrentDrawingAppearance { color = accentShade(for: .controlAccentColor) }
            return color
        }
    }
}

public enum OverlayButtonKind: Sendable { case primary, secondary }

/// SettingsSpacing, SettingsRadius and SettingsFont.body by value. MacOS cannot import the app layer.
public enum OverlayButtonMetrics {
    public static let height: CGFloat = 24
    public static let radius = PopupGlass.controlRadius
    public static let horizontalPadding: CGFloat = 10
    public static let spacing: CGFloat = 8
    public static let fontSize: CGFloat = 13
    public static let fontWeight = NSFont.Weight.medium
    /// Black, not white: a white overlay lightens the fill and drops white text to about 4.1:1.
    public static let hoverBlackOpacity = 0.08
    public static let pressedBlackOpacity = 0.16
    public static let disabledOpacity = 0.4
}

/// SwiftUI style with the same look as `OverlayButton`. Apply `fixedSize()` to a label that
/// must never truncate. The style never reads key or active state.
public struct OverlayButtonStyle: ButtonStyle {
    public let kind: OverlayButtonKind
    public init(_ kind: OverlayButtonKind) { self.kind = kind }

    public func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, kind: kind)
    }

    private struct StyledLabel: View {
        let configuration: Configuration
        let kind: OverlayButtonKind
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: OverlayButtonMetrics.radius, style: .continuous)
            configuration.label
                .font(.system(size: OverlayButtonMetrics.fontSize, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(kind == .primary ? Color.white : Color(nsColor: .labelColor))
                .padding(.horizontal, OverlayButtonMetrics.horizontalPadding)
                .frame(height: OverlayButtonMetrics.height)
                .background {
                    switch kind {
                    case .primary: shape.fill(Color(nsColor: PopupGlass.accentShadeColor))
                    case .secondary: shape.fill(.fill.secondary)
                    }
                }
                .overlay {
                    if configuration.isPressed { shape.fill(Color.black.opacity(OverlayButtonMetrics.pressedBlackOpacity)) }
                    else if hovering && isEnabled { shape.fill(Color.black.opacity(OverlayButtonMetrics.hoverBlackOpacity)) }
                }
                .opacity(isEnabled ? 1 : OverlayButtonMetrics.disabledOpacity)
                .contentShape(shape)
                .onHover { hovering = $0 }
        }
    }
}

/// Buttons side by side when they fit, stacked when the row is too narrow. Give each button
/// `fixedSize()` so the row measures its natural width and nothing truncates.
public struct OverlayButtonRow<Content: View>: View {
    private let content: Content
    public init(@ViewBuilder _ content: () -> Content) { self.content = content() }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: OverlayButtonMetrics.spacing) { content }
            VStack(spacing: OverlayButtonMetrics.spacing) { content }
        }
    }
}

/// Inline link: underlined, opaque label colour, never accent. The cursor is a pointing hand;
/// hover does not change the colour. Keep the call site's font.
public struct PopupLinkStyle: ButtonStyle {
    public let color: Color
    public init(color: Color = Color(nsColor: .labelColor)) { self.color = color }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .underline()
            .foregroundStyle(color)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
            .pointerStyle(.link)
    }
}

/// AppKit twin of `OverlayButtonStyle`. It draws itself and looks the same in a key or a
/// background window.
@MainActor public final class OverlayButton: NSButton {
    public let kind: OverlayButtonKind
    private(set) var isHovered = false

    public init(title: String, kind: OverlayButtonKind, target: AnyObject? = nil, action: Selector? = nil) {
        self.kind = kind
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        setButtonType(.momentaryPushIn)
        focusRingType = .exterior
        font = Self.titleFont
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { nil }

    static var titleFont: NSFont { .systemFont(ofSize: OverlayButtonMetrics.fontSize, weight: OverlayButtonMetrics.fontWeight) }

    /// Natural size: the title on one line plus padding. Never narrower, so it never truncates.
    public override var intrinsicContentSize: NSSize {
        let width = (title as NSString).size(withAttributes: [.font: Self.titleFont]).width
        return NSSize(width: ceil(width) + 2 * OverlayButtonMetrics.horizontalPadding, height: OverlayButtonMetrics.height)
    }

    public override var title: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    public override var isEnabled: Bool { didSet { needsDisplay = true } }
    public override var isHighlighted: Bool { didSet { needsDisplay = true } }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
                                       owner: self, userInfo: nil))
    }
    public override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    public override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// Whether the system Full Keyboard Access setting is on. Tests replace it.
    var fullKeyboardAccess: () -> Bool = { NSApp.isFullKeyboardAccessEnabled }

    /// Like a stock button, the button takes keyboard focus only when Full Keyboard Access is on.
    /// A key pane (Show Tab Bar) and the chooser can then reach it with Tab.
    public override var acceptsFirstResponder: Bool { isEnabled && fullKeyboardAccess() }

    public override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: OverlayButtonMetrics.radius, yRadius: OverlayButtonMetrics.radius).fill()
    }
    public override var focusRingMaskBounds: NSRect { bounds }

    /// Colours for the current drawing appearance. Nothing here reads key state.
    struct Palette {
        var fill: NSColor
        var title: NSColor
        var overlay: NSColor?
    }

    func palette(pressed: Bool? = nil, hovered: Bool? = nil) -> Palette {
        let pressed = pressed ?? isHighlighted
        let hovered = hovered ?? isHovered
        let fill: NSColor = kind == .primary ? PopupGlass.accentShadeColor : .secondarySystemFill
        let overlay: NSColor? = pressed ? NSColor.black.withAlphaComponent(OverlayButtonMetrics.pressedBlackOpacity)
            : (hovered && isEnabled ? NSColor.black.withAlphaComponent(OverlayButtonMetrics.hoverBlackOpacity) : nil)
        return Palette(fill: fill, title: kind == .primary ? .white : .labelColor, overlay: overlay)
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        defer { context.restoreGraphicsState() }
        if !isEnabled { context.cgContext.setAlpha(OverlayButtonMetrics.disabledOpacity) }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let colors = palette()
            let path = NSBezierPath(roundedRect: bounds, xRadius: OverlayButtonMetrics.radius, yRadius: OverlayButtonMetrics.radius)
            colors.fill.setFill()
            path.fill()
            if let overlay = colors.overlay { overlay.setFill(); path.fill() }
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byClipping
            let attributes: [NSAttributedString.Key: Any] = [
                .font: Self.titleFont, .foregroundColor: colors.title, .paragraphStyle: paragraph,
            ]
            let size = (title as NSString).size(withAttributes: attributes)
            (title as NSString).draw(in: NSRect(x: 0, y: (bounds.height - size.height) / 2, width: bounds.width, height: size.height),
                                     withAttributes: attributes)
        }
    }
}
