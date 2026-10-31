import AppKit
import BetterTileCore
import SwiftUI
import Testing
@testable import BetterTileApp
@testable import BetterTileMacOS

@MainActor @Suite(.appTestApplication, .serialized, .settingsUI) struct MenuPanelGlassPixelTests {
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
        for pressed in [false, true] {
            button.isHighlighted = pressed
            root.displayIfNeeded()
            // Keep the real NSGlassEffectView attached. Like the wheel's native-glass
            // regression, render offscreen and composite against the prescribed backdrop.
            let cg = try #require(CGContext(data: nil, width: 664, height: 144, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            cg.setFillColor(NSColor.white.cgColor)
            cg.fill(CGRect(x: 0, y: 0, width: 664, height: 144))
            cg.scaleBy(x: 2, y: 2)
            let graphics = NSGraphicsContext(cgContext: cg, flipped: false)
            appearance.performAsCurrentDrawingAppearance { root.displayIgnoringOpacity(root.bounds, in: graphics) }
            let bytes = try #require(cg.data).assumingMemoryBound(to: UInt8.self)
            // Read the known sRGB buffer directly. colorAt returns calibrated RGB;
            // converting those samples again would change the measured shade.
            func pixel(_ x: Int, _ y: Int) -> [Double] {
                let i = y * cg.bytesPerRow + x * 4
                return (0..<4).map { Double(bytes[i + $0]) / 255 }
            }
            func at(_ point: NSPoint) -> [Double] {
                pixel(Int(point.x * 2), Int((root.bounds.height - point.y) * 2))
            }
            let fillRect = button.convert(button.fillRect, to: root)
            let fill = at(NSPoint(x: fillRect.minX + 5, y: fillRect.midY))
            let expected = [shade.redComponent, shade.greenComponent, shade.blueComponent]
                .map { $0 * (pressed ? 1 - OverlayButtonMetrics.pressedBlackOpacity : 1) }
            let delta = zip(fill.prefix(3), expected).map { abs($0 - $1) }.max()!
            #expect(delta <= 2.0 / 255 && fill[3] == 1)
            if !pressed {
                let r = reference.convert(reference.bounds, to: root)
                let primary = at(NSPoint(x: r.minX + 5, y: r.midY))
                #expect(zip(fill, primary).allSatisfy { abs($0 - $1) <= 1.0 / 255 })
            }
            let text = button.convert(button.contentRects().title, to: root)
            var whiteInk = 0.0
            for y in Int((root.bounds.height - text.maxY) * 2)..<Int((root.bounds.height - text.minY) * 2) {
                for x in Int(text.minX * 2)..<Int(text.maxX * 2) {
                    whiteInk = max(whiteInk, luminance(Array(pixel(x, y).prefix(3))))
                }
            }
            #expect(whiteInk >= 0.98)
            let ratio = (whiteInk + 0.05) / (luminance(Array(fill.prefix(3))) + 0.05)
            #expect(ratio >= 4.5, "Rendered selected text contrast: \(ratio):1")
            print("PANEL_GLASS mode=\(mode) pressed=\(pressed) fill=\(fill) error=\(delta) contrast=\(ratio)")
            if let directory = ProcessInfo.processInfo.environment["BT_PANEL_PIXEL_DIR"] {
                let folder = URL(fileURLWithPath: directory)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let bitmap = NSBitmapImageRep(cgImage: try #require(cg.makeImage()))
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: folder.appendingPathComponent("selected-\(mode)-\(pressed ? "pressed" : "rest")-dark-white.png"))
            }
        }
        #expect(!window.isVisible && !window.isKeyWindow, Comment(rawValue: keyWindowDiagnostics(window)))
    }
}
