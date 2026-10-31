// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma

import AppKit
import BetterTileCore
import BetterTileMacOS
import SwiftUI

// Design tokens and shared building blocks for the Settings window.
// Shared Settings window style values.

/// Corner radii. Nested shapes are concentric: inner radius = outer radius - padding.
/// Draw every rounded shape with `.continuous` corners through `RoundedRectangle.settings(_:)`.
enum SettingsRadius {
    /// The Settings window.
    static let window: CGFloat = 16
    /// Group, card, sheet, popover, menu, and a notice at the top of a page.
    static let panel: CGFloat = 12
    /// The inset sidebar panel: the window radius minus its 6 pt inset.
    static let sidebar: CGFloat = window - SettingsMetrics.sidebarInset
    /// Preview stage, picture-choice thumbnail, and a notice inside a group.
    static let inner: CGFloat = 8
    /// Button, pop-up, field, segmented control, and stepper.
    static let control: CGFloat = 6
    /// Sidebar icon tile, pane tile in a miniature preview, keycap, and activation band.
    static let mini: CGFloat = OverlayCornerRadius.mini
    // Pills (switch, count badge, status pill, divider grip) use `Capsule`.
}

/// Spacing on a 4 pt grid. The names follow the steps in `_shared.css`.
enum SettingsSpacing {
    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16
    static let s5: CGFloat = 20
    static let s6: CGFloat = 24
    static let s8: CGFloat = 32
}

enum SettingsMetrics {
    static let rowMinHeight: CGFloat = 36
    static let sidebarWidth: CGFloat = 196
    static let sidebarInset: CGFloat = 6
    static let sidebarTile: CGFloat = 20
}

/// Type roles. Sizes are the SF Pro sizes used by macOS settings.
enum SettingsFont {
    /// Page title.
    static let title = Font.system(size: 22, weight: .semibold)
    /// Section header and emphasized row label.
    static let headline = Font.system(size: 13, weight: .semibold)
    /// Row label, value, and button.
    static let body = Font.system(size: 13)
    /// Caption and help text under a row or group.
    static let caption = Font.system(size: 11)
    /// Small uppercase label in a status card.
    static let overline = Font.system(size: 10, weight: .semibold)
    /// Status value or detail title: the large value in a status card, or the title of a detail pane.
    static let statusValue = Font.system(size: 15, weight: .semibold)
}

/// Settings colors. System colors are used where macOS has one, so Increase Contrast and the
/// user's accent color apply. The rest use fixed design values, with stronger high-contrast variants.
enum SettingsColor {
    static let group = Color(light: srgb(0xFFFFFF), dark: srgb(0xFFFFFF, 0.045))
    static let groupBorder = Color(
        light: srgb(0x000000, 0.06), dark: srgb(0xFFFFFF, 0.07),
        highContrastLight: srgb(0x000000, 0.35), highContrastDark: srgb(0xFFFFFF, 0.4)
    )
    /// Control fill, tile fill, and picture-choice thumbnail background.
    static let fill = Color(nsColor: .tertiarySystemFill)
    static let fillStrong = Color(nsColor: .secondarySystemFill)
    static let separator = Color(nsColor: .separatorColor)
    static let controlBackground = Color(light: srgb(0xFFFFFF), dark: srgb(0xFFFFFF, 0.1))
    static let controlBorder = Color(
        light: srgb(0x000000, 0.12), dark: srgb(0xFFFFFF, 0.1),
        highContrastLight: srgb(0x000000, 0.45), highContrastDark: srgb(0xFFFFFF, 0.45)
    )

    // Tile and status colors.
    static let blue = Color(nsColor: .systemBlue)
    static let green = Color(nsColor: .systemGreen)
    static let orange = Color(nsColor: .systemOrange)
    static let red = Color(nsColor: .systemRed)
    static let purple = Color(nsColor: .systemPurple)
    static let teal = Color(nsColor: .systemTeal)
    static let pink = Color(nsColor: .systemPink)
    static let indigo = Color(nsColor: .systemIndigo)
    static let gray = Color(nsColor: .systemGray)
    static let yellow = Color(nsColor: .systemYellow)

    /// The tinted accent background of an information notice. It follows the user's accent color.
    static let accentSoft = Color(nsColor: NSColor(name: nil) { appearance in
        NSColor.controlAccentColor.withAlphaComponent(appearance.isDark ? 0.2 : 0.12)
    })

    private static func srgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

private extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

    var isHighContrast: Bool {
        let match = bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
        return match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua
    }
}

private extension Color {
    init(light: NSColor, dark: NSColor, highContrastLight: NSColor? = nil, highContrastDark: NSColor? = nil) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            if appearance.isHighContrast {
                appearance.isDark ? highContrastDark ?? dark : highContrastLight ?? light
            } else {
                appearance.isDark ? dark : light
            }
        })
    }
}

extension Shape where Self == RoundedRectangle {
    /// A rounded rectangle with continuous corners, the only corner style in Settings.
    static func settings(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}

extension EnvironmentValues {
    /// True for content inside a `SettingsGroup`. A nested notice uses the inner radius.
    @Entry var settingsInsideGroup = false
}

// MARK: - Page structure

/// The title and subtitle at the top of a settings page.
struct SettingsPageHeader: View {
    let title: String
    let subtitle: String

    init(title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
    }

    init(destination: SettingsDestination) {
        self.init(title: destination.rawValue, subtitle: destination.subtitle)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(SettingsFont.title)
            Text(subtitle)
                .font(SettingsFont.body)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// An inset group: an optional header, rows separated by inset hairlines, and an optional footer.
struct SettingsGroup<Content: View, Footer: View>: View {
    private let title: String?
    private let aside: String?
    private let content: Content
    private let footer: Footer

    init(
        _ title: String? = nil,
        aside: String? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.title = title
        self.aside = aside
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsSpacing.s2) {
            if let title {
                HStack(alignment: .firstTextBaseline, spacing: SettingsSpacing.s2) {
                    Text(title)
                        .font(SettingsFont.headline)
                        .accessibilityAddTraits(.isHeader)
                    if let aside {
                        Spacer(minLength: SettingsSpacing.s2)
                        Text(aside)
                            .font(SettingsFont.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, SettingsSpacing.s1)
            }
            VStack(alignment: .leading, spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        VStack(alignment: .leading, spacing: 0) {
                            if index > 0 { SettingsSeparator() }
                            row
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.settingsInsideGroup, true)
            .background(SettingsColor.group, in: .settings(SettingsRadius.panel))
            .clipShape(.settings(SettingsRadius.panel))
            .overlay(RoundedRectangle.settings(SettingsRadius.panel).strokeBorder(SettingsColor.groupBorder, lineWidth: 0.5))
            footer
        }
    }
}

extension SettingsGroup where Footer == EmptyView {
    init(_ title: String? = nil, aside: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, aside: aside, content: content) { EmptyView() }
    }
}

/// The hairline between two rows, inset 12 pt from the leading edge.
struct SettingsSeparator: View {
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(SettingsColor.separator)
            .frame(height: 1 / max(displayScale, 1))
            .padding(.leading, SettingsSpacing.s3)
            .accessibilityHidden(true)
    }
}

/// A label with an optional caption on the left and one control on the right.
/// VoiceOver names the control with the row title (the control's title element) and reads the caption as its hint.
/// A button keeps its own label.
struct SettingsRow<Control: View>: View {
    private let title: String
    private let caption: String?
    private let control: Control
    @Namespace private var accessibilityNamespace

    init(_ title: String, caption: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.caption = caption
        self.control = control()
    }

    var body: some View {
        HStack(spacing: SettingsSpacing.s3) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(SettingsFont.body)
                    .accessibilityLabeledPair(role: .label, id: "title", in: accessibilityNamespace)
                if let caption {
                    Text(caption)
                        .font(SettingsFont.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
                .accessibilityLabeledPair(role: .content, id: "title", in: accessibilityNamespace)
                .accessibilityHint(caption.map { Text($0) } ?? Text(verbatim: ""))
        }
        .padding(.vertical, 6)
        .padding(.horizontal, SettingsSpacing.s3)
        .frame(minHeight: SettingsMetrics.rowMinHeight)
        .accessibilityElement(children: .contain)
    }
}

/// Help text under a row or group. It is always left aligned.
struct HelpText: View {
    private let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(SettingsFont.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SettingsSpacing.s3)
    }
}

/// The row under a group: help text on the left, Reset to Default on the right.
struct GroupFooter: View {
    private let help: String?
    private let isAtDefault: Bool
    private let reset: (() -> Void)?

    /// - Parameters:
    ///   - help: Text under the group. Nil shows only the button.
    ///   - isAtDefault: Disables Reset to Default when the group already has its default values.
    ///   - reset: Nil hides the button.
    init(help: String? = nil, isAtDefault: Bool = false, reset: (() -> Void)? = nil) {
        self.help = help
        self.isAtDefault = isAtDefault
        self.reset = reset
    }

    var body: some View {
        HStack(alignment: .top, spacing: SettingsSpacing.s3) {
            if let help {
                HelpText(help)
            } else {
                Spacer(minLength: 0)
            }
            if let reset {
                Button("Reset to Default", action: reset)
                    .disabled(isAtDefault)
                    .fixedSize()
                    .padding(.trailing, SettingsSpacing.s1)
            }
        }
    }
}

// MARK: - Choices and values

/// One choice in a set of picture choices. Picture choices replace sliders for a few discrete values.
/// The title, an optional detail line, and an optional badge sit left aligned under the thumbnail.
struct PictureChoice<Thumbnail: View>: View {
    /// Columns for a grid of picture choices: at least 96 pt wide, 12 pt apart.
    static var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 96), spacing: SettingsSpacing.s3, alignment: .top)]
    }

    private let title: String
    private let detail: String?
    private let badge: String?
    private let isSelected: Bool
    private let thumbnailHeight: CGFloat?
    private let accessory: AnyView?
    private let action: () -> Void
    private let thumbnail: Thumbnail

    /// - Parameters:
    ///   - detail: A second line, for example "Thin · 4 pt" or "3 pt · 48 pt".
    ///   - badge: A short pill after the title, for example "Today".
    ///   - thumbnailHeight: A fixed picture height. Nil keeps the 16:10 picture.
    ///   - accessory: Extra badges after the title. They move under it when the line is too narrow.
    init(
        _ title: String,
        detail: String? = nil,
        badge: String? = nil,
        isSelected: Bool,
        thumbnailHeight: CGFloat? = nil,
        accessory: AnyView? = nil,
        action: @escaping () -> Void,
        @ViewBuilder thumbnail: () -> Thumbnail
    ) {
        self.title = title
        self.detail = detail
        self.badge = badge
        self.isSelected = isSelected
        self.thumbnailHeight = thumbnailHeight
        self.accessory = accessory
        self.action = action
        self.thumbnail = thumbnail()
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Color.clear
                    .modifier(ThumbnailSize(height: thumbnailHeight))
                    .overlay { thumbnail }
                    .background(SettingsColor.fill)
                    .clipShape(.settings(SettingsRadius.inner))
                    .overlay {
                        RoundedRectangle.settings(SettingsRadius.inner)
                            .strokeBorder(SettingsColor.groupBorder, lineWidth: 0.5)
                    }
                    .overlay {
                        // The ring follows the thumbnail outline with a 2 pt gap: radius 8 + 4 = 12.
                        if isSelected {
                            RoundedRectangle.settings(SettingsRadius.inner + 4)
                                .strokeBorder(Color.accentColor, lineWidth: 2)
                                .padding(-4)
                        }
                    }
                VStack(alignment: .leading, spacing: 1) {
                    // The badge moves under the title when both do not fit on one line.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: SettingsSpacing.s1) { titleText; badgeView; accessory }
                        VStack(alignment: .leading, spacing: 2) {
                            titleText
                            if badge != nil || accessory != nil {
                                HStack(spacing: SettingsSpacing.s1) { badgeView; accessory }
                            }
                        }
                    }
                    if let detail {
                        Text(detail)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(SettingsFont.caption)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue([detail, badge].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var titleText: some View {
        Text(title)
            .fontWeight(isSelected ? .semibold : .regular)
            .foregroundStyle(isSelected ? .primary : .secondary)
            .fixedSize()
    }

    @ViewBuilder private var badgeView: some View {
        if let badge {
            SettingsPill(badge)
        }
    }
}

/// The picture area of a `PictureChoice`: 16:10, or a fixed height at the full column width.
private struct ThumbnailSize: ViewModifier {
    let height: CGFloat?

    func body(content: Content) -> some View {
        if let height {
            content.frame(maxWidth: .infinity).frame(height: height)
        } else {
            content.aspectRatio(16 / 10, contentMode: .fit)
        }
    }
}

/// A small status pill: switch-sized corners, caption text.
struct SettingsPill: View {
    private let text: String
    private let tint: Color?

    /// - Parameter tint: Nil draws a neutral pill.
    init(_ text: String, tint: Color? = nil) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(SettingsFont.caption.weight(.medium))
            .foregroundStyle(tint ?? .secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(tint.map { $0.opacity(0.16) } ?? SettingsColor.fill, in: Capsule())
            .fixedSize()
    }
}

/// A row with a number field and a stepper. Typed and stepped values stay inside `range`.
struct StepperRow: View {
    private let title: String
    private let caption: String?
    @Binding private var value: Double
    private let range: ClosedRange<Double>
    private let step: Double
    private let unit: String
    private let fractionDigits: Int

    init(
        _ title: String,
        caption: String? = nil,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double = 1,
        unit: String = "",
        fractionDigits: Int = 0
    ) {
        self.title = title
        self.caption = caption
        _value = value
        self.range = range
        self.step = step
        self.unit = unit
        self.fractionDigits = fractionDigits
    }

    static func clamped(_ value: Double, to range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return range.lowerBound }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// The value as VoiceOver reads it, with the unit spelled out: "5 points".
    static func spokenValue(_ value: Double, unit: String, fractionDigits: Int = 0) -> String {
        let number = value.formatted(.number.precision(.fractionLength(0 ... fractionDigits)))
        let word: String = switch unit {
        case "": ""
        case "pt": value == 1 ? "point" : "points"
        case "s": value == 1 ? "second" : "seconds"
        case "%": "percent"
        default: unit
        }
        return word.isEmpty ? number : "\(number) \(word)"
    }

    private var clampedValue: Binding<Double> {
        Binding(
            get: { value },
            set: { value = Self.clamped($0, to: range) }
        )
    }

    var body: some View {
        let spoken = Self.spokenValue(value, unit: unit, fractionDigits: fractionDigits)
        SettingsRow(title, caption: caption) {
            HStack(spacing: 6) {
                HStack(spacing: 2) {
                    TextField(
                        title,
                        value: clampedValue,
                        format: .number.precision(.fractionLength(0 ... fractionDigits))
                    )
                    .textFieldStyle(.plain)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    if !unit.isEmpty {
                        Text(unit)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
                .font(SettingsFont.body)
                .padding(.horizontal, 6)
                .frame(minWidth: 44, idealWidth: 64, maxWidth: 72, minHeight: 22)
                .fixedSize(horizontal: true, vertical: false)
                .background(SettingsColor.controlBackground, in: .settings(SettingsRadius.control))
                .overlay(RoundedRectangle.settings(SettingsRadius.control).strokeBorder(SettingsColor.controlBorder, lineWidth: 0.5))
                Stepper(title, value: clampedValue, in: range, step: step)
                    .labelsHidden()
            }
            // The field and stepper are AppKit cells that ignore SwiftUI labels. VoiceOver gets one adjustable
            // element instead: "Pane gap, 5 points". Keyboard focus still reaches the field for typing.
            .accessibilityRepresentation {
                Slider(value: clampedValue, in: range, step: step) { Text(title) }
                    .accessibilityValue(spoken)
            }
        }
    }
}

// MARK: - Status

/// A tinted message with one main action and an optional plain secondary action, such as Dismiss.
/// Standalone it uses the panel radius; inside a group, the inner radius.
struct NoticeBanner: View {
    enum Kind {
        case info
        case warning
        case problem

        var symbol: String {
            switch self {
            case .info: "info.circle.fill"
            case .warning, .problem: "exclamationmark.triangle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .info: .accentColor
            case .warning: SettingsColor.orange
            case .problem: SettingsColor.red
            }
        }

        var background: Color {
            switch self {
            case .info: SettingsColor.accentSoft
            case .warning: SettingsColor.orange.opacity(0.14)
            case .problem: SettingsColor.red.opacity(0.12)
            }
        }
    }

    struct Action {
        let title: String
        /// The one primary button in a view. Use it only when the notice is the main task.
        var isPrimary = false
        let perform: () -> Void
    }

    /// The corner radius: panel (12) on its own, inner (8) inside a `SettingsGroup`.
    static func cornerRadius(insideGroup: Bool) -> CGFloat {
        insideGroup ? SettingsRadius.inner : SettingsRadius.panel
    }

    private let kind: Kind
    private let title: String
    private let message: String?
    private let action: Action?
    private let secondaryAction: Action?
    @Environment(\.settingsInsideGroup) private var insideGroup

    /// - Parameter secondaryAction: A plain button before the main action, for example "Dismiss" or "Not now".
    ///   Its `isPrimary` is ignored.
    init(_ kind: Kind, title: String, message: String? = nil, action: Action? = nil, secondaryAction: Action? = nil) {
        self.kind = kind
        self.title = title
        self.message = message
        self.action = action
        self.secondaryAction = secondaryAction
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: kind.symbol)
                .font(.system(size: 14))
                .foregroundStyle(kind.tint)
                .frame(width: 16, height: 16)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SettingsFont.headline)
                if let message {
                    Text(message)
                        .font(SettingsFont.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if action != nil || secondaryAction != nil {
                HStack(spacing: SettingsSpacing.s2) {
                    if let secondaryAction {
                        Button(secondaryAction.title, action: secondaryAction.perform)
                            .buttonStyle(.borderless)
                    }
                    if let action {
                        if action.isPrimary {
                            Button(action.title, action: action.perform)
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button(action.title, action: action.perform)
                        }
                    }
                }
                .fixedSize()
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, SettingsSpacing.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(kind.background, in: .settings(Self.cornerRadius(insideGroup: insideGroup)))
        .accessibilityElement(children: .contain)
    }
}

/// A summary card: an uppercase label with an icon, a large value, and a caption of up to two lines.
/// Four cards fit in one row from about 900 pt; at narrower widths use a 2 × 2 grid.
struct StatusCard: View {
    /// An SF Symbol, or a layout or mode icon.
    private enum Icon {
        case symbol(String)
        case glyph(LayoutGlyph)
    }

    private let title: String
    private let icon: Icon
    private let value: String
    private let caption: String?
    private let tint: Color
    private let valueTint: Color?

    init(
        _ title: String,
        systemImage: String,
        value: String,
        caption: String? = nil,
        tint: Color,
        valueTint: Color? = nil
    ) {
        self.title = title
        self.icon = .symbol(systemImage)
        self.value = value
        self.caption = caption
        self.tint = tint
        self.valueTint = valueTint
    }

    /// A card whose icon is a layout or mode icon. It is drawn beside the 10 pt overline, at
    /// 1.265 times that symbol size.
    init(
        _ title: String,
        glyph: LayoutGlyph,
        value: String,
        caption: String? = nil,
        tint: Color,
        valueTint: Color? = nil
    ) {
        self.title = title
        self.icon = .glyph(glyph)
        self.value = value
        self.caption = caption
        self.tint = tint
        self.valueTint = valueTint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsSpacing.s1) {
            HStack(spacing: 5) {
                switch icon {
                case let .symbol(name):
                    Image(systemName: name)
                        .font(.system(size: 10, weight: .semibold))
                        .accessibilityHidden(true)
                case let .glyph(glyph):
                    LayoutGlyphView(glyph, size: CGFloat(LayoutGlyph.canvasSize(besideSymbolSize: 10)))
                }
                Text(title.uppercased())
                    .tracking(0.4)
            }
            .font(SettingsFont.overline)
            .foregroundStyle(tint)
            Text(value)
                .font(SettingsFont.statusValue)
                .foregroundStyle(valueTint ?? .primary)
            if let caption {
                Text(caption)
                    .font(SettingsFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(SettingsSpacing.s3)
        .background(SettingsColor.group, in: .settings(SettingsRadius.panel))
        .overlay(RoundedRectangle.settings(SettingsRadius.panel).strokeBorder(SettingsColor.groupBorder, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Sidebar

/// The 20 pt colored icon tile beside a sidebar item.
struct SidebarTile: View {
    enum Icon: Equatable {
        case symbol(String)
        case layoutGlyph(LayoutGlyph)
        case wheel
    }

    let icon: Icon
    let color: Color
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        glyph
            .foregroundStyle(.white)
            .frame(width: 13, height: 13)
            .frame(width: SettingsMetrics.sidebarTile, height: SettingsMetrics.sidebarTile)
            .background(color, in: .settings(SettingsRadius.mini))
            .accessibilityHidden(true)
    }

    @ViewBuilder private var glyph: some View {
        switch icon {
        case let .symbol(name):
            Image(nsImage: SidebarGlyphImages.image(name: name, scale: displayScale))
                .renderingMode(.template)
        case let .layoutGlyph(glyph):
            SidebarLayoutGlyph(glyph: glyph)
                .frame(width: 20, height: 20)
        case .wheel:
            SidebarWheelGlyph()
                .frame(width: 20, height: 20)
        }
    }
}

/// SF Symbol alignment boxes contain font bearings. Rasterize once at a fixed
/// point size and centre the visible ink, independently of a Label's font metrics.
@MainActor private enum SidebarGlyphImages {
    private struct Key: Hashable {
        let name: String
        let scale: CGFloat
        var glyph: LayoutGlyph? = nil
    }
    private static var images: [Key: NSImage] = [:]

    static func image(name: String, scale: CGFloat) -> NSImage {
        let key = Key(name: name, scale: scale)
        if let image = images[key] { return image }
        let image = makeImage(name: name, scale: scale)
        images[key] = image
        return image
    }

    static func image(glyph: LayoutGlyph, scale: CGFloat) -> NSImage {
        let key = Key(name: "", scale: scale, glyph: glyph)
        if let image = images[key] { return image }
        let canvas = Int(20 * scale)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: canvas, pixelsHigh: canvas, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return NSImage() }
        let drawing = glyph.drawing(canvasSize: 15, weight: .semibold, displayScale: scale)
        let points = drawing.paths.flatMap { $0 }.compactMap { command -> CGPoint? in
            switch command {
            case let .move(x, y), let .line(x, y), let .arc(_, x, y): CGPoint(x: x, y: y)
            case .close: nil
            }
        }
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return NSImage() }
        let x = ((10 - (minX + maxX) / 2) * scale).rounded() / scale
        let y = ((10 - (minY + maxY) / 2) * scale).rounded() / scale
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        graphics.cgContext.scaleBy(x: scale, y: scale)
        // Give stroke the same explicit display scale as drawing, so its
        // existing pixel-snapping rule also stays correct at 2x.
        glyph.stroke(in: graphics.cgContext, origin: CGPoint(x: x, y: 20 - 15 - y),
                     canvasSize: 15, weight: .semibold, color: NSColor.white.cgColor, flipped: false)
        NSGraphicsContext.restoreGraphicsState()
        guard let rendered = bitmap.cgImage else { return NSImage() }
        let result = NSImage(cgImage: rendered, size: CGSize(width: 20, height: 20))
        result.isTemplate = true
        images[key] = result
        return result
    }

    private static func makeImage(name: String, scale: CGFloat) -> NSImage {
        let canvas = Int(20 * scale)
        // Keep the user's reference gear. The other symbols use the audit's
        // fixed 10.5 pt medium weight, without scaling their strokes.
        let configuration = name == "gearshape"
            ? NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            : NSImage.SymbolConfiguration(pointSize: 10.5, weight: .medium)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return NSImage() }
        func render(origin: CGPoint) -> NSBitmapImageRep? {
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: canvas, pixelsHigh: canvas, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            graphics.cgContext.scaleBy(x: scale, y: scale)
            symbol.draw(in: CGRect(origin: origin, size: symbol.size))
            NSGraphicsContext.restoreGraphicsState()
            return bitmap
        }
        let initialOrigin = CGPoint(x: (((20 - symbol.size.width) / 2) * scale).rounded() / scale,
                                    y: (((20 - symbol.size.height) / 2) * scale).rounded() / scale)
        guard let probe = render(origin: initialOrigin) else { return NSImage() }
        var left = canvas, top = canvas, right = 0, bottom = 0
        for y in 0..<canvas {
            for x in 0..<canvas where (probe.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.25 {
                left = min(left, x); right = max(right, x)
                top = min(top, y); bottom = max(bottom, y)
            }
        }
        guard right >= left, bottom >= top else { return NSImage() }
        // Translate the vector symbol by whole device pixels only. An odd ink
        // width can retain half a pixel of residual; keep its native sharpness.
        let correction = CGPoint(x: (CGFloat(canvas - left - right - 1) / 2).rounded(.toNearestOrEven) / scale,
                                 y: (CGFloat(top + bottom + 1 - canvas) / 2).rounded(.toNearestOrEven) / scale)
        guard let final = render(origin: CGPoint(x: initialOrigin.x + correction.x,
                                                y: initialOrigin.y + correction.y))?.cgImage else { return NSImage() }
        let result = NSImage(cgImage: final, size: CGSize(width: 20, height: 20))
        result.isTemplate = true
        return result
    }

}

/// The existing 15 pt drawing, centred from its snapped source bounds.
private struct SidebarLayoutGlyph: View {
    let glyph: LayoutGlyph
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Image(nsImage: SidebarGlyphImages.image(glyph: glyph, scale: displayScale))
            .renderingMode(.template)
    }
}

/// The D′ Hub dot sidebar mark, isolated so it can change independently.
struct SidebarWheelGlyph: View {
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Canvas { context, size in
            let canvas: CGFloat = 13
            let unit = canvas / 24
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = 9.25 * unit
            var outline = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                width: radius * 2, height: radius * 2))
            for spoke in 0..<8 {
                let angle = (22.5 + Double(spoke) * 45) * .pi / 180
                outline.move(to: CGPoint(x: center.x + cos(angle) * 5 * unit,
                                         y: center.y + sin(angle) * 5 * unit))
                outline.addLine(to: CGPoint(x: center.x + cos(angle) * 9.25 * unit,
                                           y: center.y + sin(angle) * 9.25 * unit))
            }
            let stroke = LayoutGlyph.strokeWidth(canvasSize: Double(canvas), weight: .semibold,
                                                 displayScale: Double(displayScale))
            context.stroke(outline, with: .foreground,
                           style: StrokeStyle(lineWidth: stroke, lineCap: .round, lineJoin: .round))
            let hub = 1.5 * unit
            context.fill(Path(ellipseIn: CGRect(x: center.x - hub, y: center.y - hub,
                                                width: hub * 2, height: hub * 2)), with: .foreground)
        }
    }
}
