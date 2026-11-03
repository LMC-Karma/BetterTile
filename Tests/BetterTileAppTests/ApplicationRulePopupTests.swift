import AppKit
import SwiftUI
import Testing
import Vision
@testable import BetterTileApp
@testable import BetterTileMacOS

// These tests require a real key window; run only while the Mac is unattended.
// Add only reviewed real-key or activation cases; keep all other tests in default suites and update NativeLaneMembership.
@MainActor @Suite(.enabled(if: NativeFocusTestLane.isEnabled, "Requires an unattended Mac; set BETTERTILE_NATIVE_FOCUS_TESTS=1"), .nativeFocus, .appTestApplication, .serialized, .settingsUI) struct NativeFocusApplicationRulePopupTests {
    @Test(arguments: [false, true], [false, true])
    func suggestedBadgeInRealStepTwoKeepsOpaqueShadeAndWhiteText(dark: Bool, solid: Bool) async throws {
        _ = NSApplication.shared
        let previous = NSApp.appearance
        let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
        NSApp.appearance = appearance
        defer { NSApp.appearance = previous }
        let harness = LivePanelHarness(addRule: true)
        defer { harness.close() }
        try await harness.open()
        try harness.key("a", code: 0)
        try await panelReady(harness.host) { harness.readiness?.highlight == "Results:test.alpha" }
        try harness.key("\r", code: 36)
        try await panelReady(harness.host) { panelViews(harness.host, NSSearchField.self).isEmpty }
        #expect(harness.controller.panel.defaultButtonCell?.title == "Add Rule")
        #expect(harness.selected == nil)
        let root = harness.controller.glass
        harness.controller.panel.appearance = appearance
        root.backing.displayOptions = { (solid, false) }
        root.backing.refreshAppearance()
        turnNativeRunLoop(each: 0.02, layout: root, display: true)
        #expect(root.backing.showsGlass == !solid)
        let width = Int(root.bounds.width * 2), height = Int(root.bounds.height * 2)
        let cg = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        cg.setFillColor(NSColor.white.cgColor)
        cg.fill(CGRect(x: 0, y: 0, width: width, height: height))
        cg.scaleBy(x: 2, y: 2)
        let graphics = NSGraphicsContext(cgContext: cg, flipped: false)
        appearance.performAsCurrentDrawingAppearance { root.displayIgnoringOpacity(root.bounds, in: graphics) }
        let image = try #require(cg.makeImage())
        // Locate the actual word in the complete sheet, without a standalone badge fixture,
        // production marker, hard-coded row position or live Accessibility query.
        let word = try #require(try await performSnapshotRecognition {
            let request = try snapshotTextRequest(languageCorrection: false)
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            guard let text = request.results?.compactMap({ $0.topCandidates(1).first })
                .first(where: { $0.string.range(of: "Suggested", options: .caseInsensitive) != nil }),
                let range = text.string.range(of: "Suggested", options: .caseInsensitive) else { return nil as CGRect? }
            return try text.boundingBox(for: range)?.boundingBox
        })
        let rect = CGRect(x: word.minX * Double(width), y: (1 - word.maxY) * Double(height),
                          width: word.width * Double(width), height: word.height * Double(height))
        let bytes = try #require(cg.data).assumingMemoryBound(to: UInt8.self)
        func pixel(_ x: Int, _ y: Int) -> [Double] {
            let i = y * cg.bytesPerRow + x * 4
            return (0..<4).map { Double(bytes[i + $0]) / 255 }
        }
        func luminance(_ rgb: [Double]) -> Double {
            let c = rgb.prefix(3).map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return c[0] * 0.2126 + c[1] * 0.7152 + c[2] * 0.0722
        }
        // OCR can include part of the adjacent title. The capsule's flat fill is
        // the dominant colour behind the word; a single edge sample is unreliable.
        var histogram: [UInt32: Int] = [:]
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                let i = y * cg.bytesPerRow + x * 4
                let rgba = UInt32(bytes[i]) << 24 | UInt32(bytes[i + 1]) << 16
                    | UInt32(bytes[i + 2]) << 8 | UInt32(bytes[i + 3])
                histogram[rgba, default: 0] += 1
            }
        }
        let dominant = try #require(histogram.max { $0.value < $1.value }).key
        let fill = [24, 16, 8, 0].map { Double((dominant >> $0) & 255) / 255 }
        var shade: NSColor!
        appearance.performAsCurrentDrawingAppearance { shade = PopupGlass.accentShadeColor.usingColorSpace(.sRGB) }
        let expected = [shade.redComponent, shade.greenComponent, shade.blueComponent]
        let error = zip(fill.prefix(3), expected).map { abs($0 - $1) }.max()!
        #expect(error <= 2.0 / 255 && fill[3] == 1, "Actual capsule fill must equal opaque accentShade: \(fill)")
        var whiteInk = 0.0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX + rect.width * 0.15)..<Int(rect.maxX - rect.width * 0.15) {
                whiteInk = max(whiteInk, luminance(pixel(x, y)))
            }
        }
        #expect(whiteInk >= 0.98, "Suggested text must resolve to white")
        let ratio = (whiteInk + 0.05) / (luminance(fill) + 0.05)
        #expect(ratio >= 4.5, "Suggested text contrast: \(ratio):1")
        print("POPUP_SUGGESTED_REAL_STEP_TWO dark=\(dark) solid=\(solid) word=\(rect) fill=\(fill) error=\(error) contrast=\(ratio)")
        if let directory = ProcessInfo.processInfo.environment["BT_PANEL_PIXEL_DIR"] {
            let folder = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let bitmap = NSBitmapImageRep(cgImage: image)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: folder.appendingPathComponent("step-two-\(dark ? "dark" : "light")-\(solid ? "solid" : "glass").png"))
        }
        #expect(!NSScreen.screens.contains { $0.frame.intersects(harness.controller.panel.frame) })
    }
}
