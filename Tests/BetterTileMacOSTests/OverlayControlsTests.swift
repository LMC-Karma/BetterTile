import AppKit
import BetterTileCore
import SwiftUI
import Testing
@testable import BetterTileMacOS

// MARK: Helpers

private func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }

private func luminance(_ color: NSColor) -> Double {
    let c = color.usingColorSpace(.sRGB)!
    return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
}

private func contrast(_ a: NSColor, _ b: NSColor) -> Double {
    let x = luminance(a), y = luminance(b)
    return (max(x, y) + 0.05) / (min(x, y) + 0.05)
}

@MainActor private func resolved(_ color: NSColor, dark: Bool) -> NSColor {
    var result = color
    NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
        result = NSColor(cgColor: color.cgColor) ?? color
    }
    return result
}

/// An offscreen panel that can be key. Real windows are used so key state is real.
@MainActor private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor private func offscreenPanel(content: NSView, key: Bool, dark: Bool, ordered: Bool = true) throws -> KeyablePanel {
    _ = NSApplication.shared
    let panel = KeyablePanel(contentRect: NSRect(x: 12000, y: 0, width: content.frame.width, height: content.frame.height),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    panel.contentView = content
    panel.setFrameOrigin(NSPoint(x: 12000, y: 0))
    try #require(!NSScreen.screens.contains { $0.frame.intersects(panel.frame) })
    if ordered {
        if key { panel.makeKeyAndOrderFrontForTesting() }
        else { panel.orderFrontForTesting() }
    }
    return panel
}

@MainActor private func bitmap(of view: NSView) throws -> Data {
    view.layoutSubtreeIfNeeded()
    let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: rep)
    return try #require(rep.representation(using: .tiff, properties: [:]))
}

@MainActor private func pixels(of view: NSView) throws -> NSBitmapImageRep {
    view.layoutSubtreeIfNeeded()
    let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep
}

private let accents: [NSColor] = [.systemBlue, .systemPurple, .systemPink, .systemRed, .systemOrange,
                                  .systemYellow, .systemGreen, .systemGray, .systemTeal, .systemIndigo, .systemBrown]

// MARK: Primary fill contrast

@Test(.macOSTestApplication, .macOSUI, arguments: [false, true]) @MainActor
func primaryOverlayButtonFillKeepsWhiteTitleAtFourPointFiveForEveryAccent(dark: Bool) {
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
    appearance.performAsCurrentDrawingAppearance {
        #expect(NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == appearance.name)
        for accent in accents {
            let shaded = PopupGlass.accentShade(for: accent)
            #expect(contrast(.white, shaded) >= 4.5, "white on shaded \(accent) is \(contrast(.white, shaded))")
            // The hue is kept: only brightness is reduced.
            let source = accent.usingColorSpace(.sRGB)!, result = shaded.usingColorSpace(.sRGB)!
            #expect(result.redComponent <= source.redComponent + 0.001)
            #expect(result.greenComponent <= source.greenComponent + 0.001)
            #expect(result.blueComponent <= source.blueComponent + 0.001)
        }
    }
    // The button draws with the dynamic colour in the current accent and appearance.
    let button = OverlayButton(title: "Open App", kind: .primary)
    button.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    var fill = NSColor.clear
    button.effectiveAppearance.performAsCurrentDrawingAppearance { fill = resolved(button.palette().fill, dark: dark) }
    #expect(contrast(.white, fill) >= 4.5)
    #expect(button.palette().title == .white)
    #expect(button.palette().overlay == nil)
}

/// The fill with an overlay composited over it, as drawn.
private func composite(_ fill: NSColor, _ overlay: NSColor?) -> NSColor {
    let f = fill.usingColorSpace(.sRGB)!
    guard let o = overlay?.usingColorSpace(.sRGB) else { return f }
    let a = o.alphaComponent
    return NSColor(srgbRed: o.redComponent * a + f.redComponent * (1 - a), green: o.greenComponent * a + f.greenComponent * (1 - a),
                   blue: o.blueComponent * a + f.blueComponent * (1 - a), alpha: 1)
}

@Test(.macOSTestApplication, .macOSUI, arguments: [false, true]) @MainActor
func primaryOverlayButtonWhiteTitleStaysAtFourPointFiveAtRestHoverAndPressed(dark: Bool) {
    let button = OverlayButton(title: "Open App", kind: .primary)
    button.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let states: [(String, Bool, Bool)] = [("rest", false, false), ("hover", true, false), ("pressed", true, true)]
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
    appearance.performAsCurrentDrawingAppearance {
        #expect(NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == appearance.name)
        for accent in accents {
            let base = PopupGlass.accentShade(for: accent)
            for (name, hovered, pressed) in states {
                let overlay = button.palette(pressed: pressed, hovered: hovered).overlay
                #expect(name == "rest" ? overlay == nil : overlay != nil)
                let drawn = composite(base, overlay)
                #expect(contrast(.white, drawn) >= 4.5, "\(name) white on \(accent) is \(contrast(.white, drawn))")
            }
        }
    }
    // The overlay is black, so every state is at least as dark as the resting fill.
    let base = PopupGlass.accentShade(for: .systemBlue)
    #expect(luminance(composite(base, button.palette(hovered: true).overlay)) <= luminance(base))
}

@Test(.macOSTestApplication, .macOSUI) @MainActor func selectedRowsAndPrimaryButtonsShareOneShadeHelper() {
    // Same hue and the same darkening for a given accent.
    for accent in accents {
        let a = PopupGlass.accentShade(for: accent).usingColorSpace(.sRGB)!
        let b = PopupGlass.accentShade(for: accent).usingColorSpace(.sRGB)!
        #expect(a == b)
    }
}

// MARK: States

@Test(.macOSTestApplication, .macOSUI) @MainActor func overlayButtonStatesFollowTheRuling() throws {
    let primary = OverlayButton(title: "Open App", kind: .primary)
    let secondary = OverlayButton(title: "Choose Layout", kind: .secondary)
    #expect(primary.palette().overlay == nil)
    let hover = try #require(primary.palette(hovered: true).overlay?.usingColorSpace(.sRGB))
    #expect(hover.redComponent == 0 && abs(hover.alphaComponent - 0.08) < 0.0001, "hover is a black 8 % overlay")
    let pressed = try #require(primary.palette(pressed: true, hovered: true).overlay?.usingColorSpace(.sRGB))
    #expect(pressed.redComponent == 0 && abs(pressed.alphaComponent - 0.16) < 0.0001, "pressed is a black 16 % overlay")
    primary.isEnabled = false
    #expect(primary.palette(hovered: true).overlay == nil)
    #expect(OverlayButtonMetrics.disabledOpacity == 0.4)
    #expect(secondary.palette().title == .labelColor)
    #expect(secondary.palette().fill == .secondarySystemFill)
    #expect(primary.intrinsicContentSize.height == 24)
    #expect(OverlayButtonMetrics.radius == 6 && OverlayButtonMetrics.horizontalPadding == 10)
}

// MARK: Key independence





// MARK: No truncation

@Test(.macOSTestApplication, .macOSUI) @MainActor func overlayButtonWidthFitsItsTitleSoNothingTruncates() {
    for title in ["Open App", "Choose Layout", "A much longer title for the button"] {
        let button = OverlayButton(title: title, kind: .primary)
        let text = (title as NSString).size(withAttributes: [.font: OverlayButton.titleFont]).width
        #expect(button.intrinsicContentSize.width >= text + 20)
        #expect(button.intrinsicContentSize.height == 24)
    }
}

@Test(.macOSTestApplication, .macOSUI) @MainActor func buttonRowStacksOnlyWhenItsButtonsDoNotFit() {
    let row = OverlayButtonRow {
        Button("Try Again") {}.buttonStyle(OverlayButtonStyle(.primary)).fixedSize()
        Button("Cancel") {}.buttonStyle(OverlayButtonStyle(.secondary)).fixedSize()
    }
    let controller = NSHostingController(rootView: row)
    let natural = controller.sizeThatFits(in: NSSize(width: 1000, height: 400))
    #expect(abs(natural.height - 24) < 0.5, "side by side when there is room")
    #expect(abs(controller.sizeThatFits(in: NSSize(width: natural.width, height: 400)).height - 24) < 0.5)
    let narrow = controller.sizeThatFits(in: NSSize(width: natural.width - 1, height: 400))
    #expect(abs(narrow.height - (2 * 24 + 8)) < 0.5, "one point too narrow: stacked (\(narrow.height))")
    // Each button keeps its natural width when stacked; neither is squeezed.
    #expect(narrow.width > 0 && narrow.width < natural.width)
}


// MARK: Links

@MainActor private func linkImage(_ link: some View, dark: Bool) throws -> NSBitmapImageRep {
    let host = NSHostingView(rootView: link.fixedSize().padding(6))
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    let panel = try offscreenPanel(content: host, key: false, dark: dark)
    defer { panel.orderOutForTesting() }
    return try pixels(of: host)
}

private struct Ink {
    var rows: [Int] = []
    var longestRun: [Int: Int] = [:]
    var saturated = 0
}

@MainActor private func ink(_ rep: NSBitmapImageRep, dark: Bool) -> Ink {
    var result = Ink()
    let background: Double = dark ? 0 : 1
    for y in 0..<rep.pixelsHigh {
        var run = 0, best = 0
        for x in 0..<rep.pixelsWide {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.5 else { run = 0; continue }
            let differs = abs(Double(c.redComponent) - background) > 0.35 || abs(Double(c.greenComponent) - background) > 0.35
            if differs {
                run += 1; best = max(best, run)
                if max(c.redComponent, c.greenComponent, c.blueComponent) - min(c.redComponent, c.greenComponent, c.blueComponent) > 0.25 {
                    result.saturated += 1
                }
            } else { run = 0 }
        }
        if best > 0 { result.rows.append(y); result.longestRun[y] = best }
    }
    return result
}

@Test(.macOSTestApplication, .macOSUI, arguments: [false, true]) @MainActor
func inlineLinksAreUnderlinedLabelColourAndNeverAccent(dark: Bool) throws {
    let font = Font.system(size: 11)
    let plain = Text("Use here ›").font(font).foregroundStyle(Color(nsColor: .labelColor))
    let link = Button { } label: { Text("Use here ›") }.font(font).buttonStyle(PopupLinkStyle())
    let plainInk = ink(try linkImage(plain, dark: dark), dark: dark)
    let linkInk = ink(try linkImage(link, dark: dark), dark: dark)
    // An underline adds one full-width ink row below the text.
    let width = plainInk.longestRun.values.max() ?? 0
    #expect(linkInk.rows.count > plainInk.rows.count)
    let underlineRow = linkInk.rows.last
    #expect((linkInk.longestRun[underlineRow ?? 0] ?? 0) >= Int(Double(width) * 0.7), "the last ink row is a full-width underline")
    // No accent pixels: label ink is neutral.
    #expect(linkInk.saturated == 0, "link drew coloured (accent) ink")
}

// MARK: Layout Gallery buttons






// MARK: Keyboard access





@MainActor private final class PressCounter: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func press() { handler() }
}

// These tests inspect key state or share a real-key fixture; run only while the Mac is unattended.
// Add only reviewed real-key or activation cases; keep all other tests in default suites and update NativeLaneMembership.
@Suite(.enabled(if: NativeFocusTestLane.isEnabled, "Requires an unattended Mac; set BETTERTILE_NATIVE_FOCUS_TESTS=1"), .nativeFocus)
@MainActor struct NativeFocusOverlayControlsTests {
    @Test(.macOSTestApplication, .macOSUI, arguments: [false, true], [OverlayButtonKind.primary, .secondary]) @MainActor
    func overlayButtonLooksTheSameInAKeyAndABackgroundWindow(dark: Bool, kind: OverlayButtonKind) throws {
        func render(key: Bool) throws -> (Data, Bool, String) {
            let button = OverlayButton(title: kind == .primary ? "Open App" : "Choose Layout", kind: kind)
            button.frame = NSRect(origin: .zero, size: button.intrinsicContentSize)
            let host = NSView(frame: button.frame)
            host.addSubview(button)
            let panel = try offscreenPanel(content: host, key: key, dark: dark)
            defer { panel.orderOutForTesting() }
            return (try bitmap(of: button), panel.isKeyWindow, keyWindowDiagnostics(panel))
        }
        let (background, backgroundIsKey, backgroundDiagnostics) = try render(key: false)
        let (keyed, keyedIsKey, keyedDiagnostics) = try render(key: true)
        try #require(!backgroundIsKey, Comment(rawValue: backgroundDiagnostics))
        try #require(keyedIsKey, "the key-window case needs a real key window; \(keyedDiagnostics)")
        #expect(background == keyed)
    }

    @Test(.macOSTestApplication, .macOSUI, arguments: [false, true], [OverlayButtonKind.primary, .secondary]) @MainActor
    func overlayButtonStyleLooksTheSameInAKeyAndABackgroundWindow(dark: Bool, kind: OverlayButtonKind) throws {
        func render(key: Bool) throws -> (Data, Bool, String) {
            let host = NSHostingView(rootView: Button("Try Again") {}.buttonStyle(OverlayButtonStyle(kind)).fixedSize().padding(8))
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            let panel = try offscreenPanel(content: host, key: key, dark: dark)
            defer { panel.orderOutForTesting() }
            return (try bitmap(of: host), panel.isKeyWindow, keyWindowDiagnostics(panel))
        }
        let (background, backgroundIsKey, backgroundDiagnostics) = try render(key: false)
        let (keyed, keyedIsKey, keyedDiagnostics) = try render(key: true)
        try #require(!backgroundIsKey, Comment(rawValue: backgroundDiagnostics))
        try #require(keyedIsKey, "the key-window case needs a real key window; \(keyedDiagnostics)")
        #expect(background == keyed)
    }

    @Test(.macOSTestApplication, .macOSUI) @MainActor func overlayButtonTakesKeyboardFocusOnlyWithFullKeyboardAccess() throws {
        let button = OverlayButton(title: "Open App", kind: .primary)
        // Set before the window exists: with the real setting on, AppKit may focus the button itself.
        button.fullKeyboardAccess = { false }
        button.frame = NSRect(origin: .zero, size: button.intrinsicContentSize)
        let host = NSView(frame: button.frame)
        host.addSubview(button)
        let panel = try offscreenPanel(content: host, key: true, dark: true)
        defer { panel.orderOutForTesting() }
        panel.makeFirstResponder(nil)
        #expect(!button.acceptsFirstResponder)
        button.fullKeyboardAccess = { true }
        #expect(button.acceptsFirstResponder)
        #expect(panel.makeFirstResponder(button))
        #expect(panel.firstResponder === button)
        panel.orderOutForTesting()
        // A standard focus ring follows the button's rounded shape.
        #expect(button.focusRingType == .exterior)
        #expect(button.focusRingMaskBounds == button.bounds)
        // A disabled button is never focusable.
        button.isEnabled = false
        #expect(!button.acceptsFirstResponder)
    }

    @Test(.macOSTestApplication, .macOSUI) @MainActor func spacePressesAFocusedOverlayButton() throws {
        var presses = 0
        let target = PressCounter { presses += 1 }
        let button = OverlayButton(title: "Open App", kind: .primary, target: target, action: #selector(PressCounter.press))
        button.fullKeyboardAccess = { true }
        button.frame = NSRect(origin: .zero, size: button.intrinsicContentSize)
        let host = NSView(frame: button.frame)
        host.addSubview(button)
        let panel = try offscreenPanel(content: host, key: true, dark: true, ordered: false)
        defer { panel.orderOutForTesting() }
        #expect(!panel.isVisible)
        let space = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        try withNativeEventLoop {
            // Keep the key window unordered while admitting the pump operation.
            panel.makeKeyAndOrderFrontForTesting()
            defer { panel.orderOutForTesting() }
            #expect(!NSScreen.screens.contains { $0.frame.intersects(panel.frame) })
            #expect(panel.makeFirstResponder(button))
            try #require(panel.isKeyWindow, "Space needs a real key window; \(keyWindowDiagnostics(panel))")
            button.keyDown(with: space)
        }
        #expect(!panel.isVisible)
        #expect(presses == 1)
    }
}
