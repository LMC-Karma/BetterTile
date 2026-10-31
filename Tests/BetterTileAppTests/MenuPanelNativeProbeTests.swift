import AppKit
import BetterTileCore
import SwiftUI
import Testing
@testable import BetterTileApp
@testable import BetterTileMacOS

/// Opt-in, offscreen evidence for public native-control alternatives. Native backdrop optics
/// are not available to cacheDisplay; these captures must never substitute for live contrast.
@Suite(.appTestApplication, .serialized, .settingsUI) @MainActor struct MenuPanelNativeProbeTests {
    nonisolated private static let directory = ProcessInfo.processInfo.environment["BT_MENU_NATIVE_PROBE_DIR"]

    @Test(.enabled(if: directory != nil, "Requires an explicit offscreen native-control probe directory."))
    func nativeSegmentStylesInRealGlass() throws {
        let folder = URL(fileURLWithPath: try #require(Self.directory))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let previous = NSApp.appearance
        defer { NSApp.appearance = previous }
        for dark in [false, true] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for (name, style): (String, NSSegmentedControl.Style) in [
                ("separated", .separated), ("capsule", .capsule), ("texturedRounded", .texturedRounded)
            ] {
                let control = NSSegmentedControl()
                control.segmentCount = 3
                control.segmentDistribution = .fillEqually
                control.selectedSegment = 0
                for (i, mode) in LayoutMode.availableModes.enumerated() {
                    control.setLabel(mode.title, forSegment: i)
                    control.setImage(LayoutGlyph.mode(mode).templateImage(canvasSize: LayoutModePicker.glyphSize,
                        trailingPadding: LayoutModePicker.imageTrailingPadding), forSegment: i)
                    control.setImageScaling(.scaleNone, forSegment: i)
                }
                control.segmentStyle = .automatic
                let originalHeight = control.fittingSize.height
                control.segmentStyle = style
                let naturalHeight = control.fittingSize.height
                control.frame = NSRect(x: 24, y: 24, width: 284, height: originalHeight)
                let content = NSView(frame: NSRect(x: 0, y: 0, width: 332, height: originalHeight + 48))
                content.addSubview(control)
                let glass = PopupGlassHost(content: content, appearance: OverlayAppearance(strength: 0))
                glass.frame = content.frame
                glass.backing.displayOptions = { (false, false) }
                let window = OffscreenTestWindow(contentRect: NSRect(x: 12000, y: 0, width: 332, height: content.frame.height),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSApp.appearance
                window.contentView = glass
                defer { window.close() }
                glass.layoutSubtreeIfNeeded()
                let image = GlassPopupScene.capture(glass, includingGlass: true)
                let file = "native-\(dark ? "dark" : "light")-\(name).png"
                try #require(image.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(file))
                print("NATIVE_SEGMENT_PROBE style=\(name) dark=\(dark) width=\(control.frame.width) originalHeight=\(originalHeight) naturalHeight=\(naturalHeight) glyphCanvas=\(LayoutModePicker.glyphSize) imagePadding=\(LayoutModePicker.imageTrailingPadding) plate=\(glass.backing.plateOpacity) windowVisible=\(window.isVisible)")
                #expect(!window.isVisible)
            }
        }
    }
}
