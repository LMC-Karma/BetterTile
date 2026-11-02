import AppKit
import BetterTileCore
import SwiftUI
import Testing
@testable import BetterTileApp
@testable import BetterTileMacOS

// Reads pixels of real native glass, which the macOS 26 runner cannot capture. On CI the shade and contrast stay
// covered by MenuPanelModePickerTests.selectedModeUsesShadedAccentWithContrastInEveryPointerState.
@MainActor @Suite(.liveDesktop, .appTestApplication, .serialized, .settingsUI) struct MenuPanelGlassPixelTests {
    @Test(arguments: LayoutMode.availableModes)
    func selectedFillStaysOpaqueInNativeDarkGlassOverWhite(mode: LayoutMode) throws {
        _ = NSApplication.shared
        let previous = NSApp.appearance
        let appearance = try #require(NSAppearance(named: .darkAqua))
        NSApp.appearance = appearance
        defer { NSApp.appearance = previous }
        let host = NSHostingView(rootView: MenuPanelModePicker(selection: .constant(mode))
            .frame(width: 284, height: 24).padding(24))
        host.frame = NSRect(x: 0, y: 0, width: 332, height: 72)
        let glass = PopupGlassHost(content: host, appearance: .init(strength: 0))
        glass.frame = host.frame
        glass.backing.displayOptions = { (false, false) }
        glass.backing.refreshAppearance()
        let root = NSView(frame: host.frame)
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.white.cgColor
        root.addSubview(glass)
        let reference = OverlayButton(title: "Primary", kind: .primary)
        reference.frame = NSRect(x: 24, y: 0, width: 100, height: 24)
        host.addSubview(reference)
        let window = OffscreenTestWindow(contentRect: NSRect(x: 12000, y: 0, width: 332, height: 72),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.colorSpace = .sRGB
        window.contentView = root
        defer { window.close() }
        turnNativeRunLoop(each: 0.02, layout: root, display: true)
        func find(_ view: NSView) -> MenuPanelModeControl? {
            if let control = view as? MenuPanelModeControl { return control }
            return view.subviews.lazy.compactMap(find).first
        }
        let button = try #require(find(host)?.buttons.first { $0.mode == mode })
        #expect(glass.backing.showsGlass && glass.backing.plateOpacity == 0.35)
        #expect(button.isDescendant(of: try #require(glass.backing.glass.contentView)))
        #expect(!button.allowsVibrancy && !reference.allowsVibrancy)
        var shade: NSColor!
        appearance.performAsCurrentDrawingAppearance { shade = PopupGlass.accentShadeColor.usingColorSpace(.sRGB) }
        func luminance(_ rgb: [Double]) -> Double {
            let linear = rgb.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
        }
        // The same picker and reference button outside native glass, over the same white backdrop, drawn the same way.
        // Its pixels show what the content draws, independent of whether this system can capture glass contents.
        let plainHost = NSHostingView(rootView: MenuPanelModePicker(selection: .constant(mode))
            .frame(width: 284, height: 24).padding(24))
        plainHost.frame = host.frame
        let plainRoot = NSView(frame: host.frame)
        plainRoot.wantsLayer = true
        plainRoot.layer?.backgroundColor = NSColor.white.cgColor
        plainRoot.addSubview(plainHost)
        let plainReference = OverlayButton(title: "Primary", kind: .primary)
        plainReference.frame = reference.frame
        plainHost.addSubview(plainReference)
        let plainWindow = OffscreenTestWindow(contentRect: NSRect(x: 12000, y: 200, width: 332, height: 72),
            styleMask: [.borderless], backing: .buffered, defer: false)
        plainWindow.isReleasedWhenClosed = false
        plainWindow.appearance = appearance
        plainWindow.colorSpace = .sRGB
        plainWindow.contentView = plainRoot
        defer { plainWindow.close() }
        turnNativeRunLoop(each: 0.02, layout: plainRoot, display: true)
        let plainButton = try #require(find(plainHost)?.buttons.first { $0.mode == mode })

        struct Measurement: CustomStringConvertible {
            var fill: [Double], delta: Double, primary: [Double]?, whiteInk: Double, ratio: Double, range: Double
            var description: String {
                "fill=\(fill) error=\(delta) primary=\(primary.map { "\($0)" } ?? "-") ink=\(whiteInk) contrast=\(ratio) range=\(range)"
            }
        }
        // Renders `scene` offscreen, composited against the prescribed white backdrop, and reads the known sRGB buffer
        // directly: colorAt returns calibrated RGB, and converting those samples again would change the measured shade.
        func measure(_ scene: NSView, area: NSView, button: MenuPanelModeButton, reference: OverlayButton,
                     pressed: Bool, write name: String?) throws -> Measurement {
            let cg = try #require(CGContext(data: nil, width: 664, height: 144, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            cg.setFillColor(NSColor.white.cgColor)
            cg.fill(CGRect(x: 0, y: 0, width: 664, height: 144))
            cg.scaleBy(x: 2, y: 2)
            let graphics = NSGraphicsContext(cgContext: cg, flipped: false)
            appearance.performAsCurrentDrawingAppearance { scene.displayIgnoringOpacity(scene.bounds, in: graphics) }
            let bytes = try #require(cg.data).assumingMemoryBound(to: UInt8.self)
            func pixel(_ x: Int, _ y: Int) -> [Double] {
                let i = y * cg.bytesPerRow + x * 4
                return (0..<4).map { Double(bytes[i + $0]) / 255 }
            }
            func at(_ point: NSPoint) -> [Double] {
                pixel(Int(point.x * 2), Int((scene.bounds.height - point.y) * 2))
            }
            // The luminance range over `area`: 1 when every sampled pixel has the same luminance.
            let areaRect = area.convert(area.bounds, to: scene)
            var lowest = 1.0, highest = 0.0
            for y in stride(from: Int((scene.bounds.height - areaRect.maxY) * 2), to: Int((scene.bounds.height - areaRect.minY) * 2), by: 2) {
                for x in stride(from: Int(areaRect.minX * 2), to: Int(areaRect.maxX * 2), by: 2) {
                    let value = luminance(Array(pixel(x, y).prefix(3)))
                    lowest = min(lowest, value)
                    highest = max(highest, value)
                }
            }
            let fillRect = button.convert(button.fillRect, to: scene)
            let fill = at(NSPoint(x: fillRect.minX + 5, y: fillRect.midY))
            let expected = [shade.redComponent, shade.greenComponent, shade.blueComponent]
                .map { $0 * (pressed ? 1 - OverlayButtonMetrics.pressedBlackOpacity : 1) }
            let delta = zip(fill.prefix(3), expected).map { abs($0 - $1) }.max()!
            let primary = pressed ? nil : at(NSPoint(x: reference.convert(reference.bounds, to: scene).minX + 5,
                                                     y: reference.convert(reference.bounds, to: scene).midY))
            let text = button.convert(button.contentRects().title, to: scene)
            var whiteInk = 0.0
            for y in Int((scene.bounds.height - text.maxY) * 2)..<Int((scene.bounds.height - text.minY) * 2) {
                for x in Int(text.minX * 2)..<Int(text.maxX * 2) {
                    whiteInk = max(whiteInk, luminance(Array(pixel(x, y).prefix(3))))
                }
            }
            let ratio = (whiteInk + 0.05) / (luminance(Array(fill.prefix(3))) + 0.05)
            if let name, let directory = ProcessInfo.processInfo.environment["BT_PANEL_PIXEL_DIR"] {
                let folder = URL(fileURLWithPath: directory)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let bitmap = NSBitmapImageRep(cgImage: try #require(cg.makeImage()))
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(name))
            }
            return Measurement(fill: fill, delta: delta, primary: primary, whiteInk: whiteInk, ratio: ratio,
                               range: (highest + 0.05) / (lowest + 0.05))
        }
        func strictChecks(_ m: Measurement, _ surface: String) {
            #expect(m.delta <= 2.0 / 255 && m.fill[3] == 1, "\(surface): \(m)")
            if let primary = m.primary {
                #expect(zip(m.fill, primary).allSatisfy { abs($0 - $1) <= 1.0 / 255 }, "\(surface): \(m)")
            }
            #expect(m.whiteInk >= 0.98, "\(surface): \(m)")
            #expect(m.ratio >= 4.5, "\(surface): rendered selected text contrast \(m.ratio):1")
        }

        for pressed in [false, true] {
            button.isHighlighted = pressed
            plainButton.isHighlighted = pressed
            root.displayIfNeeded()
            plainRoot.displayIfNeeded()
            let state = "\(mode)-\(pressed ? "pressed" : "rest")"
            // Keep the real NSGlassEffectView attached. Like the wheel's native-glass
            // regression, render offscreen and composite against the prescribed backdrop.
            let inGlass = try measure(root, area: glass, button: button, reference: reference, pressed: pressed,
                                      write: "selected-\(state)-dark-white.png")
            let plain = try measure(plainRoot, area: plainHost, button: plainButton, reference: plainReference,
                                    pressed: pressed, write: "selected-\(state)-dark-white-plain.png")
            // The content outside glass must always pass: a fill or contrast fault in the panel itself is never hidden.
            strictChecks(plain, "outside glass")
            // Some systems cannot draw native glass contents into an image: the glass area of the capture is then one
            // flat colour (no fill, title or reference button). Only then are the in-glass checks a known issue.
            let captureIsBlind = inGlass.range < 1.01
            print("PANEL_GLASS mode=\(mode) pressed=\(pressed) blind=\(captureIsBlind) glass: \(inGlass) | outside glass: \(plain)")
            if captureIsBlind {
                withKnownIssue("macOS cannot capture native glass contents into an image on this machine: the glass area of the capture is one flat colour") {
                    strictChecks(inGlass, "in glass")
                }
            } else {
                strictChecks(inGlass, "in glass")
            }
        }
        #expect(!window.isVisible && !window.isKeyWindow, Comment(rawValue: keyWindowDiagnostics(window)))
    }
}
