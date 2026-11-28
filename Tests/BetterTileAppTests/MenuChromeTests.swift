import AppKit
import BetterTileCore
import SwiftUI
import Testing
@testable import BetterTileApp

/// The menu panel's raised surfaces: colour tokens, the controls plate, action tiles and the
/// Settings and Quit row.
@MainActor @Suite(.appTestApplication, .serialized) struct MenuChromeTests {
    @Test(arguments: [false, true], [false, true])
    func borderTokenIsBlackOrWhiteAtElevenOrTwentyFourPercent(dark: Bool, increased: Bool) throws {
        let scheme: ColorScheme = dark ? .dark : .light
        let actual = try swatch(MenuChromePalette.cardBorder(for: scheme, increasedContrast: increased), dark: dark)
        let expected = try swatch((dark ? Color.white : Color.black).opacity(increased ? 0.24 : 0.11), dark: dark)
        #expect(actual == expected)
        // The other contrast level must not render the same, or the token ignores contrast.
        let other = try swatch(MenuChromePalette.cardBorder(for: scheme, increasedContrast: !increased), dark: dark)
        #expect(other != actual)
    }

    @Test(arguments: [false, true])
    func raisedSurfaceIsTranslucentWhiteInLightAndTheFourthFillInDark(dark: Bool) throws {
        let actual = try swatch(MenuChromePalette.raisedSurface(for: dark ? .dark : .light), dark: dark)
        let expected = try dark ? swatch(.fill.quaternary, dark: true) : swatch(Color.white.opacity(0.52), dark: false)
        #expect(actual == expected)
    }

    /// The hairline must stay visible over the opaque window background in every combination.
    /// Measured edge-to-background differences (0–255 brightness) are pinned as floors.
    @Test(arguments: [false, true], [false, true])
    func plateAndTileBordersStandOutFromTheWindowBackground(dark: Bool, increased: Bool) throws {
        let plate = try edgeContrast(dark: dark, increased: increased) {
            Color.clear.frame(width: 120, height: 40)
                .chromePlate(colorScheme: dark ? .dark : .light, highContrast: increased)
        }
        let tile = try edgeContrast(dark: dark, increased: increased) {
            MenuPanelActionButton(action: .leftHalf, shortcut: nil) {}
                .frame(width: MenuPanelMetrics.tileWidth)
        }
        let floor: Double = increased ? 0.06 : 0.025
        #expect(plate >= floor, "Plate edge contrast \(plate) (dark \(dark), increased \(increased))")
        #expect(tile >= floor, "Tile edge contrast \(tile) (dark \(dark), increased \(increased))")
    }

    @Test(arguments: [false, true])
    func aDisabledTileIsTheEnabledTileAtHalfOpacity(dark: Bool) throws {
        func tile(enabled: Bool) -> some View {
            MenuPanelActionButton(action: .leftHalf, shortcut: nil, isEnabled: enabled) {}
                .frame(width: MenuPanelMetrics.tileWidth)
        }
        let disabled = try bitmap(dark: dark) { tile(enabled: false) }
        let halfEnabled = try bitmap(dark: dark) { tile(enabled: true).opacity(0.5) }
        let enabled = try bitmap(dark: dark) { tile(enabled: true) }
        #expect(maximumChannelDifference(disabled, halfEnabled) <= 1)
        #expect(maximumChannelDifference(disabled, enabled) > 10)
    }

    @Test func tileAndZoneFeedbackAnimatesOnlyWithoutReduceMotion() {
        #expect(ChromeButtonFeedback.hoverAnimation(reduceMotion: true) == nil)
        #expect(ChromeButtonFeedback.pressAnimation(reduceMotion: true) == nil)
        #expect(ChromeButtonFeedback.hoverAnimation(reduceMotion: false) == .easeOut(duration: 0.18))
        #expect(ChromeButtonFeedback.pressAnimation(reduceMotion: false) == .easeOut(duration: 0.12))
        #expect(ChromeButtonFeedback.tint(pressed: true, hovered: true) == Color.accentColor.opacity(0.2))
        #expect(ChromeButtonFeedback.tint(pressed: true, hovered: false) == Color.accentColor.opacity(0.2))
        #expect(ChromeButtonFeedback.tint(pressed: false, hovered: true) == Color.accentColor.opacity(0.08))
        #expect(ChromeButtonFeedback.tint(pressed: false, hovered: false) == .clear)
    }

    @Test func theSettingsAndQuitRowIsInertInThePreview() throws {
        let model = makeModel(system: FakeAppWindowSystem())
        defer { model.shutdown() }
        let preview = try HostedPanel(MenuPanelContent(model: model, isEditing: true) {
            EmptyView()
        } notice: { EmptyView() })
        defer { preview.close() }
        #expect(preview.button(labelled: "Settings") == nil)
        #expect(preview.button(labelled: "Quit") == nil)
    }

    @Test func theSettingsAndQuitButtonsEachRunTheirCallbackOnce() throws {
        let model = makeModel(system: FakeAppWindowSystem())
        defer { model.shutdown() }
        var settings = 0
        var quits = 0
        let panel = try HostedPanel(MenuPanelContent(
            model: model, openSetup: {}, openSettings: { settings += 1 }, quit: { quits += 1 }
        ) { EmptyView() } notice: { EmptyView() })
        defer { panel.close() }
        #expect(AXProbe.press(try #require(panel.button(labelled: "Settings"))))
        #expect(settings == 1 && quits == 0)
        #expect(AXProbe.press(try #require(panel.button(labelled: "Quit"))))
        #expect(settings == 1 && quits == 1)
    }

    @Test func theSettingsAndQuitFacesShareTheContentWidth() throws {
        let model = makeModel(system: FakeAppWindowSystem())
        defer { model.shutdown() }
        let panel = try HostedPanel(MenuPanelContent(model: model, openSetup: {}, openSettings: {}, quit: {}) {
            EmptyView()
        } notice: { EmptyView() })
        defer { panel.close() }
        let settings = AXProbe.frame(try #require(panel.button(labelled: "Settings")))
        let quit = AXProbe.frame(try #require(panel.button(labelled: "Quit")))
        let content = MenuPanelMetrics.width - 2 * MenuPanelMetrics.padding
        // The two faces split the row after the 7 pt gap; when that leaves an odd width, layout rounds
        // one face up by a point, so the widths may differ by at most 1 pt. The span check below still
        // pins the pair to the full content width.
        #expect(abs(settings.width - quit.width) <= 1)
        #expect(abs(quit.minX - settings.maxX - 7) < 0.5)
        #expect(abs(settings.height - 28) < 0.5 && abs(quit.height - 28) < 0.5)
        #expect(abs(quit.maxX - settings.minX - content) < 0.5, "Faces span \(quit.maxX - settings.minX) pt")
        let panelFrame = panel.window.convertToScreen(panel.view.convert(panel.view.bounds, to: nil))
        // The 28 pt faces sit centred in a 30 pt row, 1 pt above the bottom padding.
        #expect(abs(settings.minY - panelFrame.minY - MenuPanelMetrics.padding - 1) < 0.5)
    }

    // MARK: Rendering helpers

    private func appearance(dark: Bool) throws -> NSAppearance {
        try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
    }

    private func swatch(_ style: some ShapeStyle, dark: Bool) throws -> Data {
        let renderer = ImageRenderer(content: Rectangle().fill(style).frame(width: 24, height: 24)
            .environment(\.colorScheme, dark ? .dark : .light))
        let image = try #require(renderer.cgImage)
        return try #require(NSBitmapImageRep(cgImage: image).tiffRepresentation)
    }

    private func bitmap(dark: Bool, increased: Bool = false, @ViewBuilder _ content: () -> some View) throws -> NSBitmapImageRep {
        _ = NSApplication.shared
        let previous = NSApp.appearance
        let appearance = try appearance(dark: dark)
        NSApp.appearance = appearance
        defer { NSApp.appearance = previous }
        let view = content()
            .padding(6)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\._colorSchemeContrast, increased ? .increased : .standard)
        var result: NSBitmapImageRep?
        appearance.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            result = renderer.cgImage.map(NSBitmapImageRep.init(cgImage:))
        }
        return try #require(result)
    }

    /// Brightness difference between the shape's left edge, halfway down, and the background beside it.
    private func edgeContrast(dark: Bool, increased: Bool, @ViewBuilder _ content: () -> some View) throws -> Double {
        let image = try bitmap(dark: dark, increased: increased, content)
        let y = image.pixelsHigh / 2
        let background = try brightness(image, x: 4, y: y)
        let edge = try brightness(image, x: 12, y: y) // 6 pt padding at 2x: the first edge pixel.
        return abs(edge - background)
    }

    private func brightness(_ image: NSBitmapImageRep, x: Int, y: Int) throws -> Double {
        try #require(image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)).brightnessComponent
    }

    private func maximumChannelDifference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return .max }
        var worst = 0
        for y in 0 ..< a.pixelsHigh {
            for x in 0 ..< a.pixelsWide {
                var left = [Int](repeating: 0, count: 4)
                var right = [Int](repeating: 0, count: 4)
                a.getPixel(&left, atX: x, y: y)
                b.getPixel(&right, atX: x, y: y)
                for channel in 0 ..< min(a.samplesPerPixel, 4) {
                    worst = max(worst, abs(left[channel] - right[channel]))
                }
            }
        }
        return worst
    }
}

/// `MenuPanelContent` in an offscreen window, for accessibility and geometry reads.
@MainActor private struct HostedPanel {
    let view: NSHostingView<AnyView>
    let window: NSWindow

    init(_ content: some View) throws {
        _ = NSApplication.shared
        view = NSHostingView(rootView: AnyView(content
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.accessibilityEnabled, true)))
        let size = view.fittingSize
        view.frame = NSRect(origin: .zero, size: size)
        window = OffscreenTestWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        turnNativeRunLoop(layout: view)
    }

    func close() { window.close() }

    func button(labelled title: String) -> NSObject? {
        AXProbe.all(under: view).first {
            AXProbe.role($0) == NSAccessibility.Role.button.rawValue && AXProbe.label($0) == title
        }
    }
}

/// SwiftUI's accessibility nodes answer the informal accessibility methods without conforming to
/// `NSAccessibilityProtocol` in Swift, so tests call those methods by selector.
@MainActor enum AXProbe {
    static func children(of object: NSObject) -> [NSObject] {
        [#selector(NSAccessibilityProtocol.accessibilityChildren),
         #selector(NSAccessibilityProtocol.accessibilityChildrenInNavigationOrder)].flatMap { selector -> [NSObject] in
            guard object.responds(to: selector) else { return [] }
            return object.perform(selector)?.takeUnretainedValue() as? [NSObject] ?? []
        }
    }

    static func all(under root: NSObject) -> [NSObject] {
        var seen: Set<ObjectIdentifier> = []
        func collect(_ object: NSObject) -> [NSObject] {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return [] }
            return [object] + children(of: object).flatMap(collect)
        }
        return collect(root)
    }

    static func string(_ object: NSObject, _ selector: Selector) -> String? {
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }

    static func label(_ object: NSObject) -> String { string(object, #selector(NSAccessibilityProtocol.accessibilityLabel)) ?? "" }
    static func role(_ object: NSObject) -> String? { string(object, #selector(NSAccessibilityProtocol.accessibilityRole)) }

    static func frame(_ object: NSObject) -> NSRect {
        let selector = NSSelectorFromString("accessibilityFrame")
        guard object.responds(to: selector) else { return .zero }
        typealias Call = @convention(c) (NSObject, Selector) -> NSRect
        return unsafeBitCast(object.method(for: selector), to: Call.self)(object, selector)
    }

    @discardableResult static func press(_ object: NSObject) -> Bool {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard object.responds(to: selector) else { return false }
        typealias Call = @convention(c) (NSObject, Selector) -> Bool
        return unsafeBitCast(object.method(for: selector), to: Call.self)(object, selector)
    }
}
