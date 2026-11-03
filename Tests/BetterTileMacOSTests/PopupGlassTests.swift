import AppKit
import BetterTileCore
import Testing
@testable import BetterTileMacOS

@MainActor private func popupGlass(dark: Bool, options: (Bool, Bool) = (false, false),
                                   appearance: OverlayAppearance = OverlayAppearance()) -> OverlayGlassView {
    let view = OverlayGlassView(frame: NSRect(x: 0, y: 0, width: 320, height: 420))
    view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    view.displayOptions = { options }
    view.overlayAppearance = appearance
    view.isPopup = true
    return view
}

/// Popup frosting keeps its shared floor; ordinary Tabbed glass has no popup floor.
@Test(.macOSTestApplication, arguments: [false, true]) @MainActor
func popupGlassUsesTheSharedFloorWithoutChangingTabbedGlass(dark: Bool) throws {
    var plates: [Double] = []
    for strength in [0.0, 0.25, 0.5, 0.75, 1.0] {
        let appearance = OverlayAppearance(strength: strength)
        let view = popupGlass(dark: dark, appearance: appearance)
        view.isLight = true // An empty pane's clear glass does not apply under a request panel.
        #expect(view.showsGlass)
        #expect(view.glass.style == .regular)
        // The drawn plate, not only the stored value.
        let drawn = try #require(view.subviews.first { $0 !== view.glass }?.layer?.backgroundColor?.alpha)
        #expect(abs(Double(drawn) - view.plateOpacity) < 0.001)
        let tabbed = OverlayGlassView(frame: view.frame)
        tabbed.displayOptions = { (false, false) }
        tabbed.overlayAppearance = appearance
        #expect(view.plateOpacity == max(dark ? 0.35 : 0.20, tabbed.plateOpacity))
        #expect(tabbed.plateOpacity == appearance.glassBackingOpacity)
        plates.append(view.plateOpacity)
    }
    #expect(plates.first == (dark ? 0.35 : 0.20)) // Every popup keeps the shared floor at Clear.
    #expect(zip(plates, plates.dropFirst()).allSatisfy { $0 <= $1 })
    #expect(plates.last == (dark ? 0.35 : 0.22))
    #expect(plates.last! < 1) // The backdrop keeps showing through in either appearance.
}

@Test(.macOSTestApplication, arguments: [(true, false), (false, true)]) @MainActor
func popupGlassFallsBackToTheOpaqueSystemSurface(options: (Bool, Bool)) {
    for dark in [false, true] {
        let view = popupGlass(dark: dark, options: options)
        #expect(!view.showsGlass)
        #expect(view.plateOpacity == 1)
    }
    let off = popupGlass(dark: true, appearance: OverlayAppearance(useLiquidGlass: false))
    #expect(!off.showsGlass)
    #expect(off.plateOpacity == 1)
}

enum PopupTextRole: String, CaseIterable, CustomTestStringConvertible {
    case primary, secondary, placeholder
    var testDescription: String { rawValue }
    var color: NSColor {
        switch self {
        case .primary: .labelColor
        case .secondary: PopupGlass.secondaryLabelColor
        case .placeholder: PopupGlass.placeholderTextColor
        }
    }
}

/// A window or wallpaper behind the popup, as the glass would blur it to a flat colour.
struct PopupBackdrop: CustomTestStringConvertible, Sendable {
    let name: String, red: Double, green: Double, blue: Double
    var testDescription: String { name }
    static let white = Self(name: "white window", red: 1, green: 1, blue: 1)
    static let lightGrey = Self(name: "light grey window", red: 0.9, green: 0.9, blue: 0.9)
    static let yellow = Self(name: "bright yellow window", red: 1, green: 0.8, blue: 0)
    static let darkWallpaper = Self(name: "dark wallpaper", red: 0.16, green: 0.14, blue: 0.24)
    static let darkWindow = Self(name: "dark window", red: 0.12, green: 0.12, blue: 0.12)
    static let black = Self(name: "black terminal", red: 0, green: 0, blue: 0)
}

/// WCAG contrast of `role` text over the plate at `plate` opacity on `backdrop`, in sRGB. The model leaves
/// out the native glass's own frost and tint, which AppKit cannot draw offscreen.
@MainActor func popupContrast(_ role: PopupTextRole, dark: Bool, plate: Double, backdrop: PopupBackdrop) throws -> Double {
    let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
    var surface = 0.0, label = (value: 0.0, alpha: 0.0)
    appearance.performAsCurrentDrawingAppearance {
        surface = NSColor.windowBackgroundColor.usingColorSpace(.sRGB)!.redComponent
        let text = role.color.usingColorSpace(.sRGB)!
        label = (text.redComponent, text.alphaComponent)
    }
    func luminance(_ rgb: [Double]) -> Double {
        let linear = rgb.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }
    let background = [backdrop.red, backdrop.green, backdrop.blue].map { plate * surface + (1 - plate) * $0 }
    let text = background.map { label.alpha * label.value + (1 - label.alpha) * $0 }
    let (a, b) = (luminance(text), luminance(background))
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
}

/// On the backdrops a popup usually covers, windows and wallpaper in its own appearance, every text
/// role keeps 4.5:1 at every Glass transparency stop, from the plate alone. The opposite case (a light
/// popup over a black terminal, a dark popup over a white page) relies on the native glass's adaptive
/// frost, which this model cannot measure.
@Test(.macOSTestApplication, arguments: PopupTextRole.allCases, [false, true]) @MainActor
func popupTextKeepsFourAndAHalfToOneOnTypicalBackdrops(role: PopupTextRole, dark: Bool) throws {
    let backdrops: [PopupBackdrop] = dark ? [.darkWallpaper, .darkWindow, .black] : [.white, .lightGrey, .yellow]
    for strength in [0.0, 0.5, 1.0] {
        let plate = popupGlass(dark: dark, appearance: OverlayAppearance(strength: strength)).plateOpacity
        for backdrop in backdrops {
            let ratio = try popupContrast(role, dark: dark, plate: plate, backdrop: backdrop)
            #expect(ratio >= 4.5, "\(role) \(dark ? "dark" : "light") over \(backdrop.name), plate \(plate): \(ratio):1")
        }
    }
}

/// Reduce Transparency, Increase Contrast and glass off: the opaque surface carries every role on any backdrop.
@Test(.macOSTestApplication, arguments: PopupTextRole.allCases, [false, true]) @MainActor
func popupTextKeepsFourAndAHalfToOneOnTheOpaqueFallback(role: PopupTextRole, dark: Bool) throws {
    let plate = popupGlass(dark: dark, options: (true, false)).plateOpacity
    #expect(plate == 1)
    let ratio = try popupContrast(role, dark: dark, plate: plate, backdrop: dark ? .white : .black)
    #expect(ratio >= 4.5, "\(role) \(dark ? "dark" : "light"): \(ratio):1")
}

/// Popup placeholders and secondary text stay stronger than the system secondary role.
@Test(.macOSTestApplication, arguments: [false, true]) @MainActor
func popupTextRolesAreStrongerThanTheSystemSecondaryRole(dark: Bool) throws {
    let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
    var alphas = (label: 0.0, system: 0.0, secondary: 0.0, placeholder: 0.0)
    appearance.performAsCurrentDrawingAppearance {
        alphas = (NSColor.labelColor.alphaComponent, NSColor.secondaryLabelColor.alphaComponent,
                  PopupGlass.secondaryLabelColor.usingColorSpace(.sRGB)!.alphaComponent,
                  PopupGlass.placeholderTextColor.usingColorSpace(.sRGB)!.alphaComponent)
    }
    #expect(alphas.secondary == alphas.label)
    #expect(alphas.placeholder == 1 && alphas.placeholder > alphas.system)
}






@Test(.macOSTestApplication, arguments: [false, true])
func popupPlateUsesCompiledAppearanceFloorAtClearDefaultAndFrosted(dark: Bool) throws {
    #expect(PopupGlass.minimumPlateOpacity == 0.20)
    #expect(PopupGlass.minimumDarkPlateOpacity == 0.35)
    let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
    for (strength, plate) in [(0.0, 0.0), (0.5, 0.11), (1.0, 0.22)] {
        #expect(PopupGlass.plateOpacity(OverlayAppearance(strength: strength),
            appAppearance: appearance, arguments: []) == max(dark ? 0.35 : 0.20, plate))
    }
}


@Test(.macOSTestApplication, arguments: [false, true])
func popupDarkFloorUsesLaunchArgumentsAndAppAppearance(dark: Bool) throws {
    let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
    #expect(PopupGlass.minimumDarkPlateOpacity == 0.35)
    for (strength, slider) in [(0.0, 0.0), (0.5, 0.11), (1.0, 0.22)] {
        for (value, floor) in [("0.20", 0.20), ("0.25", 0.25), ("0.30", 0.30),
                               ("0.35", 0.35), ("0.40", 0.40), ("0.47", 0.47), ("0.60", 0.60)] {
#if DEBUG
            let expected = max(dark ? floor : 0.20, slider)
#else
            let expected = max(dark ? 0.35 : 0.20, slider)
#endif
            #expect(PopupGlass.plateOpacity(.init(strength: strength), appAppearance: appearance,
                arguments: ["BetterTile", "-BetterTilePopupDarkPlateFloor", value]) == expected)
        }
    }
}

@Test(.macOSTestApplication) func popupDarkFloorClampsAndRejectsInvalidLaunchArguments() throws {
    let dark = try #require(NSAppearance(named: .darkAqua))
    for (arguments, floor): ([String], Double) in [
        ([], 0.35), (["-BetterTilePopupDarkPlateFloor"], 0.35),
        (["-BetterTilePopupDarkPlateFloor", "-0.1"], 0.20),
        (["-BetterTilePopupDarkPlateFloor", "0.19"], 0.20),
        (["-BetterTilePopupDarkPlateFloor", "0.61"], 0.60),
        (["-BetterTilePopupDarkPlateFloor", "1"], 0.60),
        (["-BetterTilePopupDarkPlateFloor", "nan"], 0.35),
        (["-BetterTilePopupDarkPlateFloor", "inf"], 0.35),
        (["-BetterTilePopupDarkPlateFloor", "0.4junk"], 0.35),
        (["-BetterTilePopupDarkPlateFloor", ""], 0.35),
        (["-BetterTileMenuPanelPlateFloor", "0.60"], 0.35),
        (["-BetterTilePopupPlateFloor", "0.60"], 0.35)
    ] {
#if DEBUG
        let expected = floor
#else
        let expected = 0.35
#endif
        #expect(PopupGlass.plateOpacity(.init(strength: 0), appAppearance: dark, arguments: arguments) == expected)
    }
}


@Test(.macOSTestApplication, arguments: [false, true]) @MainActor
func popupFloorFollowsInheritedAppAppearanceAndExcludesTabbedSurfaces(dark: Bool) throws {
    _ = NSApplication.shared
    let previous = NSApp.appearance
    NSApp.appearance = NSAppearance(named: dark ? .aqua : .darkAqua)
    defer { NSApp.appearance = previous }
    let host = PopupGlassHost(content: NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 420)))
    let appAppearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
    host.appearance = appAppearance
    let view = host.backing
    view.popupLaunchArguments = { ["BetterTile", "-BetterTilePopupDarkPlateFloor", "0.47"] }
    view.displayOptions = { (false, false) }
    view.overlayAppearance = .init(strength: 0)
#if DEBUG
    let expected = dark ? 0.47 : 0.20
#else
    let expected = dark ? 0.35 : 0.20
#endif
    #expect(view.plateOpacity == expected)
    #expect(abs(Double(try #require(view.plate.layer?.backgroundColor?.alpha)) - expected) < 0.001)
    // A Tabbed pane or bar uses the slider only, even with the same launch arguments.
    view.isPopup = false
    #expect(view.plateOpacity == 0)
    view.isCurtain = true
    #expect(view.plateOpacity == 0.14)
    view.isCurtain = false
    view.isPopup = true
    #expect(view.plateOpacity == expected)
    // The next effective appearance must also update the actual plate, without recreating the popup.
    host.appearance = NSAppearance(named: dark ? .aqua : .darkAqua)
    view.refreshAppearance()
#if DEBUG
    #expect(view.plateOpacity == (dark ? 0.20 : 0.47))
#else
    #expect(view.plateOpacity == (dark ? 0.20 : 0.35))
#endif
}
