import AppKit
import BetterTileCore
import SwiftUI
import Testing
@testable import BetterTileMacOS

/// Opt in to WindowServer captures of this test's own opaque synthetic window.
/// Off-screen bitmap caching cannot verify the native glass compositor.
@Test(.enabled(if: ProcessInfo.processInfo.environment["BETTERTILE_NATIVE_GLASS_PREVIEW_DIR"] != nil,
               "Requires an explicit native glass preview output directory."))
@MainActor func nativeGlassCompositorPreviews() async throws {
    _ = NSApplication.shared
    let directory = try #require(ProcessInfo.processInfo.environment["BETTERTILE_NATIVE_GLASS_PREVIEW_DIR"])
    let panel = NSPanel(contentRect: NSRect(x: 80, y: 100, width: 960, height: 620),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.level = .floating
    panel.isOpaque = true
    defer { panel.close() }
    for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        for strength in [0.0, 1.0] {
            let appearance = OverlayAppearance(strength: strength)
            panel.appearance = NSAppearance(named: appearanceName)
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 620))
            root.wantsLayer = true
            let backdrop = CAGradientLayer()
            backdrop.frame = root.bounds
            backdrop.colors = [NSColor.systemBlue.cgColor, NSColor.systemPurple.cgColor, NSColor.systemOrange.cgColor]
            backdrop.startPoint = .zero
            backdrop.endPoint = CGPoint(x: 1, y: 1)
            root.layer?.addSublayer(backdrop)
            panel.contentView = root
            for y in stride(from: 30, to: 580, by: 50) {
                let label = NSTextField(labelWithString: "SYNTHETIC WINDOW CONTENT     0123456789     SYNTHETIC WINDOW CONTENT")
                label.font = .monospacedSystemFont(ofSize: 20, weight: .bold)
                label.textColor = .white
                label.frame = NSRect(x: 24, y: y, width: 900, height: 30)
                root.addSubview(label)
            }
            let curtain = TabbedCurtainView(frame: NSRect(x: 20, y: 40, width: 920, height: 360))
            curtain.excludedStrips = [NSRect(x: 0, y: 0, width: 920, height: 34)]
            root.addSubview(curtain)
            let strip = TabbedPaneView(frame: NSRect(x: 20, y: 366, width: 920, height: 34))
            var pane = TabbedPane()
            pane.tabs = (0..<3).map { WindowID(rawValue: "preview-\($0)") }
            pane.selected = pane.tabs[0]
            strip.pane = pane
            strip.titles = ["Notes", "Browser", "Editor"]
            strip.icons = ["note.text", "globe", "chevron.left.forwardslash.chevron.right"].map { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
            strip.active = true
            strip.overlayAppearance = appearance
            root.addSubview(strip)
            let grip = DividerHandleView(frame: NSRect(x: 35, y: 430, width: 160, height: 150),
                                         mode: .junction(center: CGPoint(x: 80, y: 75),
                                                         resting: [.left: 36, .right: 36, .up: 36, .down: 36],
                                                         active: [.left: 55, .right: 55, .up: 55, .down: 55]), thickness: 10)
            grip.overlayAppearance = appearance
            root.addSubview(grip)
            let wheel = NSHostingView(rootView: LayoutWheelView(configuration: .init(), overlayAppearance: appearance))
            wheel.frame = NSRect(x: 630, y: 400, width: 260, height: 210)
            root.addSubview(wheel)
            root.layoutSubtreeIfNeeded()
            panel.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(250))
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l", String(panel.windowNumber),
                                 "\(directory)/native-\(name)-\(Int(strength)).png"]
            try capture.run()
            capture.waitUntilExit()
            #expect(capture.terminationStatus == 0)
        }
    }
}

@Test @MainActor func sharedGlassKeepsNativeMaterialVisibleAcrossTheSlider() {
    let view = OverlayGlassView()
    view.displayOptions = { (false, false) }
    for strength in [0.0, 0.34, 0.35, 0.5, 1.0] {
        view.overlayAppearance.strength = strength
        #expect(view.glass.style == .regular)
        #expect(view.plateOpacity <= 0.22)
    }
}

@Test(arguments: [false, true], [(false, false), (true, false), (false, true)]) @MainActor
func sharedGlassHonorsToggleAndAccessibility(enabled: Bool, options: (Bool, Bool)) {
    let view = OverlayGlassView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
    view.displayOptions = { options }
    view.overlayAppearance = .init(useLiquidGlass: enabled)
    #expect(view.showsGlass == (enabled && !options.0 && !options.1))
    if !view.showsGlass { #expect(view.plateOpacity == 1) }
    #expect(view.hitTest(NSPoint(x: 10, y: 10)) == nil)
}

@Test @MainActor func glassStrengthKeepsEmptyPanesLight() {
    let ordinary = OverlayGlassView()
    let empty = OverlayGlassView()
    empty.isLight = true
    for view in [ordinary, empty] { view.displayOptions = { (false, false) } }
    var previous = -1.0
    for strength in [0.0, 0.5, 1.0] {
        for view in [ordinary, empty] { view.overlayAppearance.strength = strength }
        #expect(ordinary.plateOpacity > previous)
        #expect(empty.plateOpacity <= ordinary.plateOpacity)
        #expect(empty.glass.style == .clear)
        previous = ordinary.plateOpacity
    }
}

@Test @MainActor func glassDividerKeepsHitOwnershipAndMinimumWidth() throws {
    let view = DividerHandleView(frame: NSRect(x: 0, y: 0, width: 40, height: 100),
                                 mode: .vertical(restingLength: 50, activeLength: 80), thickness: 2)
    #expect(view.renderedThickness == 6)
    #expect(view.hitTest(NSPoint(x: 20, y: 50)) === view)
    view.overlayAppearance.useLiquidGlass = false
    #expect(!view.showsGlass)
    #expect(view.renderedThickness == 2)
    view.setLimit(DragLimit(width: true, height: false, blockedTowardPositive: true))
    #expect(view.limit.width)
}

@Test(arguments: [false, true]) @MainActor
func glassDividerLaysOutStraightAndJunctionCapsules(active: Bool) throws {
    let cases: [(DividerHandleMode, [NSRect])] = [
        (.vertical(restingLength: 60, activeLength: 100),
         [active ? NSRect(x: 37, y: 10, width: 6, height: 100)
                 : NSRect(x: 37, y: 30, width: 6, height: 60)]),
        (.horizontal(restingLength: 40, activeLength: 60),
         [active ? NSRect(x: 10, y: 57, width: 60, height: 6)
                 : NSRect(x: 20, y: 57, width: 40, height: 6)]),
        (.junction(center: CGPoint(x: 40, y: 60),
                   resting: [.left: 20, .right: 20, .up: 30],
                   active: [.left: 30, .right: 30, .up: 50]),
         active ? [NSRect(x: 7, y: 57, width: 66, height: 6),
                   NSRect(x: 37, y: 57, width: 6, height: 56)]
                : [NSRect(x: 17, y: 57, width: 46, height: 6),
                   NSRect(x: 37, y: 57, width: 6, height: 36)]),
        (.junction(center: CGPoint(x: 40, y: 60),
                   resting: [.left: 20, .right: 20, .up: 30, .down: 30],
                   active: [.left: 30, .right: 30, .up: 50, .down: 50]),
         active ? [NSRect(x: 7, y: 57, width: 66, height: 6),
                   NSRect(x: 37, y: 7, width: 6, height: 106)]
                : [NSRect(x: 17, y: 57, width: 46, height: 6),
                   NSRect(x: 37, y: 27, width: 6, height: 66)]),
    ]
    for (mode, expected) in cases {
        let view = DividerHandleView(frame: NSRect(x: 0, y: 0, width: 80, height: 120),
                                     mode: mode, thickness: 2)
        view.setActive(active, animated: false)
        view.layoutSubtreeIfNeeded()
        let container = try #require(view.subviews.first as? NSGlassEffectContainerView)
        let surfaces = try #require(container.contentView).subviews.filter { !$0.isHidden }
        #expect(surfaces.map(\.frame) == expected)
        #expect(surfaces.allSatisfy { ($0 as? OverlayGlassView)?.cornerRadius == 3 })
    }
    let thick = DividerHandleView(frame: NSRect(x: 0, y: 0, width: 80, height: 120),
                                  mode: .horizontal(restingLength: 40, activeLength: 60), thickness: 12)
    thick.setActive(active, animated: false)
    thick.layoutSubtreeIfNeeded()
    let container = try #require(thick.subviews.first as? NSGlassEffectContainerView)
    let surface = try #require(container.contentView?.subviews.first as? OverlayGlassView)
    #expect(surface.frame == (active ? NSRect(x: 10, y: 54, width: 60, height: 12)
                                    : NSRect(x: 20, y: 54, width: 40, height: 12)))
    #expect(surface.cornerRadius == 6)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["BETTERTILE_TAB_PREVIEW_DIR"] != nil,
               "Requires an explicit glass preview output directory."))
@MainActor func sharedGlassAppearancePreviews() throws {
    let directory = try #require(ProcessInfo.processInfo.environment["BETTERTILE_TAB_PREVIEW_DIR"])
    _ = NSApplication.shared
    for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        let appearance = try #require(NSAppearance(named: appearanceName))
        let image = NSImage(size: NSSize(width: 960, height: 460))
        appearance.performAsCurrentDrawingAppearance {
            image.lockFocus()
            defer { image.unlockFocus() }
            NSColor.windowBackgroundColor.setFill()
            NSRect(x: 0, y: 0, width: 960, height: 460).fill()
            let outputContext = NSGraphicsContext.current
            for (index, style) in [OverlayAppearance(strength: 0), .init(strength: 1), .init(useLiquidGlass: false)].enumerated() {
                let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 420))
                root.appearance = appearance
                let panel = NSPanel(contentRect: NSRect(x: 12000, y: 0, width: 300, height: 420),
                                    styleMask: [.borderless], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false
                panel.appearance = appearance
                panel.contentView = root
                let label = NSTextField(labelWithString: ["Clear", "Frosted", "Glass off"][index])
                label.frame = NSRect(x: 12, y: 390, width: 276, height: 24)
                root.addSubview(label)
                let pane = TabbedPaneView(frame: NSRect(x: 12, y: 170, width: 276, height: 210))
                pane.overlayAppearance = style
                pane.pane = TabbedPane()
                pane.active = true
                root.addSubview(pane)
                let grip = DividerHandleView(frame: NSRect(x: 60, y: 0, width: 180, height: 160),
                                             mode: .junction(center: CGPoint(x: 90, y: 80),
                                                             resting: [.left: 28, .right: 28, .up: 28, .down: 28],
                                                             active: [.left: 60, .right: 60, .up: 60, .down: 60]), thickness: 10)
                grip.overlayAppearance = style
                grip.setActive(true, animated: false)
                root.addSubview(grip)
                root.layoutSubtreeIfNeeded()
                guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { continue }
                root.cacheDisplay(in: root.bounds, to: bitmap)
                let rendered = NSImage(size: root.bounds.size)
                rendered.addRepresentation(bitmap)
                panel.close()
                NSGraphicsContext.current = outputContext
                rendered.draw(in: NSRect(x: 12 + index * 320, y: 20, width: 300, height: 420),
                              from: .zero, operation: .sourceOver, fraction: 1)
            }
        }
        let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        try bitmap.representation(using: .png, properties: [:])?.write(
            to: URL(fileURLWithPath: directory).appendingPathComponent("shared-glass-\(name).png"))
    }
}
