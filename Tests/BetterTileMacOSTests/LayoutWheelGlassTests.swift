import AppKit
import SwiftUI
import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

@MainActor @Suite(.macOSTestApplication, .serialized) struct LayoutWheelGlassTests {
    private func revealed(_ sector: LayoutWheelSector = .top) -> LayoutWheelSceneInput {
        var fan = LayoutWheelFanState()
        let angle = sector.drawnCenterAngle.radians
        let point = BTPoint(x: cos(angle) * 124, y: sin(angle) * 124)
        fan.update(vector: point, at: 0, geometry: LayoutWheelMetrics.grouped.fanGeometry)
        fan.update(vector: point, at: 0.2, geometry: LayoutWheelMetrics.grouped.fanGeometry)
        return .init(configuration: .init(style: .grouped, levelCount: .two), selection: fan.selection, fan: fan)
    }

    @Test(arguments: [60.0, 120.0]) func idleStopsWithoutAnotherFrame(hz: Double) {
        let clock = WheelTestClock()
        let scene = LayoutWheelGlassRenderer(clock: clock)
        defer { scene.stop() }
        let rest = LayoutWheelSceneInput(configuration: .init(style: .grouped, levelCount: .two))
        scene.configure(rest, reduceMotion: false)
        #expect(!clock.isRunning)
        let input = revealed()
        scene.configure(input, reduceMotion: false)
        #expect(clock.isRunning)
        clock.settle(hz: hz)
        #expect(scene.motion.isAtRest && !clock.isRunning)
        #expect(scene.renderedFrameCount < Int(hz * 0.3))
        let frames = scene.renderedFrameCount, starts = clock.starts
        for _ in 0..<300 { clock.frame(hz: hz); scene.configure(input, reduceMotion: false) }
        #expect(scene.renderedFrameCount == frames && clock.starts == starts)
        #expect(scene.input?.fan.optionIndex == nil)
        #expect(scene.input?.fan.command == .windowAction(.maximize))
    }

    @Test func reduceMotionSnapsAnInFlightFanAndRemovesCosmeticTravel() {
        let clock = WheelTestClock()
        let renderer = LayoutWheelGlassRenderer(clock: clock)
        defer { renderer.stop() }
        let input = revealed(.left)
        renderer.configure(input, reduceMotion: false)
        clock.frame()
        #expect(!renderer.motion.isAtRest)
        renderer.configure(input, reduceMotion: true)
        #expect(renderer.motion.isAtRest && !clock.isRunning)
        #expect(renderer.motion.reveals[LayoutWheelSector.left.rawValue].value == 1)
        #expect(renderer.input?.fan.optionIndex == nil && renderer.input?.fan.command == nil)
    }

    @Test(arguments: LayoutWheelAcknowledgment.allCases, [60.0, 120.0])
    func exitsFreezeInputAndRemoveGlass(acknowledgment: LayoutWheelAcknowledgment, hz: Double) throws {
        let clock = WheelTestClock()
        let scene = LayoutWheelGlassRenderer(clock: clock)
        let input = revealed(.left)
        scene.configure(input, reduceMotion: false, reduceTransparency: false, increasedContrast: false)
        clock.settle(hz: hz)
        let frames = scene.renderedFrameCount
        var completions = 0
        scene.beginExit(acknowledgment) { completions += 1 }
        scene.beginExit(.cancel) { completions += 100 }
        let stale = try #require(clock.callback)
        scene.configure(.init(configuration: .init(levelCount: .one)), reduceMotion: false)
        #expect(scene.input == input)
        #expect(scene.exitPresentation?.acknowledgment == acknowledgment)
        if acknowledgment == .cancel {
            #expect(!scene.usesGlass)
            clock.frame(hz: hz)
            #expect(scene.exitScale < 1 && scene.exitScale > 0)
            #expect(scene.layer?.opacity == 1)
        } else {
            #expect(scene.usesGlass && scene.exitScale == 1)
        }
        clock.settle(hz: hz)
        #expect(completions == 1 && !clock.isRunning)
        #expect(scene.hosting == nil && scene.layer?.opacity == 0)
        #expect(scene.renderedFrameCount > frames)
        stale(100)
        #expect(completions == 1)
    }

    @Test(arguments: LayoutWheelAcknowledgment.allCases, [false, true])
    func reducedMotionExitIsImmediate(acknowledgment: LayoutWheelAcknowledgment, duringExit: Bool) {
        let clock = WheelTestClock()
        let scene = LayoutWheelGlassRenderer(clock: clock)
        let input = revealed()
        scene.configure(input, reduceMotion: !duringExit)
        var completions = 0
        scene.beginExit(acknowledgment) { completions += 1 }
        if duringExit { scene.configure(input, reduceMotion: true) }
        #expect(completions == 1 && !clock.isRunning && scene.hosting == nil)
    }

    @Test func reopenRejectsAnOldClockAndCloseRemovesTheHostingTree() throws {
        let clock = WheelTestClock()
        let scene = LayoutWheelGlassRenderer(clock: clock)
        let input = revealed()
        scene.configure(input, reduceMotion: false)
        scene.beginExit(.cancel) { Issue.record("Interrupted exit completed") }
        let stale = try #require(clock.callback)
        scene.configure(input, reduceMotion: false, newOpen: true)
        let frames = scene.renderedFrameCount
        stale(100)
        #expect(scene.exitPresentation == nil && scene.renderedFrameCount == frames)
        #expect(scene.hosting != nil)
        scene.stop()
        #expect(scene.hosting == nil && !clock.isRunning)
    }

    @Test func closedRendererIgnoresLateUpdatesAndDisplayOptions() {
        let scene = LayoutWheelGlassRenderer(clock: WheelTestClock())
        let input = revealed()
        scene.configure(input, reduceMotion: true)
        scene.stop()
        let frames = scene.renderedFrameCount
        scene.configure(input, reduceMotion: false)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        #expect(scene.hosting == nil && !scene.isClockRunning && scene.renderedFrameCount == frames)
    }

    @Test func everySwitchSelectsTheRenderedFallback() {
        let renderer = LayoutWheelGlassRenderer(clock: WheelTestClock())
        defer { renderer.stop() }
        for glass in [false, true] {
            for rt in [false, true] {
                for contrast in [false, true] {
                    renderer.configure(.init(configuration: .init(), appearance: .init(useLiquidGlass: glass)),
                        reduceMotion: true, reduceTransparency: rt, increasedContrast: contrast)
                    #expect(renderer.usesGlass == (glass && !rt && !contrast))
                    #expect(renderer.hosting?.rootView.reduceTransparency == rt)
                    #expect(renderer.hosting?.rootView.increasedContrast == contrast)
                }
            }
        }
    }

    /// The plate over native glass is the popup recipe: floor plus 0.20 x strength.
    /// The well has its own floor above the ring cap.
    @Test func plateOpacityIsTheFloorPlusTwentyPercentOfStrength() {
        let floor = LayoutWheelGlassTreatment.plateFloor
        #expect(LayoutWheelGlassTreatment.plateOpacity(strength: 0) == floor)
        #expect(abs(LayoutWheelGlassTreatment.plateOpacity(strength: 0.3) - (floor + 0.06)) < 1e-9)
        #expect(abs(LayoutWheelGlassTreatment.plateOpacity(strength: 1) - (floor + 0.20)) < 1e-9)
        #expect(LayoutWheelGlassTreatment.plateOpacity(strength: .nan) == floor)
        #expect(LayoutWheelGlassTreatment.plateOpacity(strength: 7) == floor + 0.20)
        let well = LayoutWheelGlassTreatment.wellPlateFloor
        #expect(LayoutWheelGlassTreatment.wellPlateOpacity(strength: 0.3) == well + 0.06)
        // The centre well uses a darker plate so its text stays readable over bright windows.
        #expect(floor >= 0.08 && floor <= LayoutWheelGlassTreatment.plateCap)
        #expect(LayoutWheelGlassTreatment.plateCap == 0.20)
        #expect(well == 0.47)
    }

    /// The scene input copies the target desktop's mode from the presentation.
    @Test func sceneInputCopiesTheCurrentModeFromThePresentation() {
        let placement = LayoutWheelPlacement.clamped(anchor: BTPoint(x: 500, y: 500), diameter: 300,
            visibleFrame: BTRect(x: 0, y: 0, width: 1000, height: 1000))
        var presentation = LayoutWheelPresentation(configuration: .init(), placement: placement,
                                                  selection: nil, unavailableCommands: [])
        #expect(LayoutWheelSceneInput(presentation).currentMode == nil)
        presentation.currentMode = .tabbed
        let input = LayoutWheelSceneInput(presentation)
        #expect(input.currentMode == .tabbed)
        #expect(input != LayoutWheelSceneInput(configuration: presentation.configuration))
    }

    @Test func groupedParentSlotsCarryG1GlyphsForEveryGroup() {
        let input = LayoutWheelSceneInput(configuration: .init(style: .grouped, levelCount: .two), currentMode: .tabbed)
        #expect(input.slot(.sector(.init(ring: .outer, sector: .top))).glyph == nil)
        #expect(input.slot(.sector(.init(ring: .outer, sector: .topRight))).glyph == nil)
        #expect(input.slot(.sector(.init(ring: .outer, sector: .right))).glyph == nil)
        #expect(input.slot(.sector(.init(ring: .outer, sector: .bottomRight))).glyph == .mode(.tabbed))
        #expect(input.slot(.sector(.init(ring: .outer, sector: .bottom))).glyph == nil)
        #expect(input.slot(.sector(.init(ring: .outer, sector: .bottomLeft))).glyph == .layouts)
        #expect(input.slot(.sector(.init(ring: .outer, sector: .left))).glyph == nil)
        #expect(input.slot(.sector(.init(ring: .outer, sector: .topLeft))).glyph == nil)
    }

    /// BetterTile's Settings override sets `NSApp.appearance`. The wheel panel
    /// must ignore it and keep the system appearance, so ink and plate follow
    /// the system.
    @Test(.macOSUI, arguments: [NSAppearance.Name.darkAqua, .aqua]) func settingsAppearanceOverrideIsIgnored(override: NSAppearance.Name) throws {
        let app = NSApplication.shared
        let saved = app.appearance
        defer { app.appearance = saved }
        app.appearance = NSAppearance(named: override)
        let system: NSAppearance.Name = override == .darkAqua ? .aqua : .darkAqua
        let presenter = LayoutWheelPanelPresenter(renderer: LayoutWheelGlassRenderer(clock: WheelTestClock()),
                                                  systemAppearance: { NSAppearance(named: system)! })
        defer { presenter.close() }
        let placement = LayoutWheelPlacement.clamped(anchor: BTPoint(x: -5000, y: -5000), diameter: 300,
            visibleFrame: BTRect(x: -6000, y: -6000, width: 2000, height: 2000))
        presenter.open(.init(configuration: .init(), placement: placement, selection: nil, unavailableCommands: []))
        let hosting = try #require(presenter.hosting)
        #expect(hosting.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == system)
        #expect(app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == override)
        // The default provider reads the global preference, not the override.
        let dark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        #expect(LayoutWheelPanelPresenter.currentSystemAppearance().bestMatch(from: [.darkAqua, .aqua]) == (dark ? .darkAqua : .aqua))
    }

    /// The wheel panel reads the system appearance, not BetterTile's own
    /// Settings override, so ink and plate follow the system.
    @Test(arguments: [NSAppearance.Name.darkAqua, .aqua]) func panelUsesTheSystemAppearance(name: NSAppearance.Name) throws {
        let presenter = LayoutWheelPanelPresenter(renderer: LayoutWheelGlassRenderer(clock: WheelTestClock()),
                                                  systemAppearance: { NSAppearance(named: name)! })
        defer { presenter.close() }
        let placement = LayoutWheelPlacement.clamped(anchor: BTPoint(x: -5000, y: -5000), diameter: 300,
            visibleFrame: BTRect(x: -6000, y: -6000, width: 2000, height: 2000))
        presenter.open(.init(configuration: .init(), placement: placement, selection: nil, unavailableCommands: []))
        let hosting = try #require(presenter.hosting)
        #expect(hosting.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == name)
        let dark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        #expect(LayoutWheelPanelPresenter.currentSystemAppearance().bestMatch(from: [.darkAqua, .aqua]) == (dark ? .darkAqua : .aqua))
    }

    /// Reduce Transparency arrives from the system, not from a caller argument.
    /// Drive that path with an injected display option, as the real notification
    /// does: the wheel must switch to opaque shapes, switch back, and keep the
    /// gesture's input unchanged.
    @Test(arguments: [ColorScheme.dark, .light]) func systemReduceTransparencyDrivesTheSolidPath(scheme: ColorScheme) throws {
        let clock = WheelTestClock()
        let renderer = LayoutWheelGlassRenderer(clock: clock)
        defer { renderer.stop() }
        var options = LayoutWheelDisplayOptions(reduceMotion: true, reduceTransparency: true, increaseContrast: false)
        renderer.displayOptions = { options }
        let input = LayoutWheelSceneInput(configuration: .init(levelCount: .one),
                                          selection: .init(ring: .inner, sector: .top))
        renderer.configure(input, newOpen: true)
        #expect(!renderer.usesGlass)
        #expect(renderer.hosting?.rootView.reduceTransparency == true)

        func body(_ view: LayoutWheelGlassView) throws -> NSColor {
            let drawn = LayoutWheelDrawnMetrics(input)
            let angle = Double.pi / 16, radius = (drawn.wellRadius + drawn.metrics.iconRadius(for: .inner, levelCount: .one)) / 2 - 8
            let size = input.diameter
            let image = ImageRenderer(content: view.frame(width: size, height: size).environment(\.colorScheme, scheme))
            image.scale = 2
            let bitmap = NSBitmapImageRep(cgImage: try #require(image.cgImage))
            let x = Int((size / 2 + cos(angle) * radius) * 2), y = Int((size / 2 + sin(angle) * radius) * 2)
            return try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        }
        let solid = try body(try #require(renderer.hosting).rootView)
        // The opaque fill replaces glass entirely, so nothing shows through.
        #expect(solid.alphaComponent > 0.99)
        // Compare with the same fill through the same renderer, so colour
        // management cannot change the expectation.
        let reference = ImageRenderer(content: Color(white: scheme == .dark ? 0.18 : 0.96).frame(width: 4, height: 4))
        reference.scale = 1
        let referenceImage = try #require(reference.cgImage)
        let fill = try #require(NSBitmapImageRep(cgImage: referenceImage).colorAt(x: 1, y: 1)?.usingColorSpace(.sRGB))
        #expect(abs(solid.redComponent - fill.redComponent) < 0.01, "solid \(solid.redComponent) expected \(fill.redComponent)")

        options.reduceTransparency = false
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        #expect(renderer.usesGlass)
        #expect(renderer.hosting?.rootView.reduceTransparency == false)
        #expect(renderer.input == input)

        options.reduceTransparency = true
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        #expect(!renderer.usesGlass)
        let again = try body(try #require(renderer.hosting).rootView)
        #expect(abs(again.redComponent - solid.redComponent) < 0.001)
    }

    /// Rasterize a transparent parent so one common commit alpha must affect
    /// body, well and overlapping selected lens exactly once.
    @Test(arguments: [false, true]) func commitAppliesOneOpacityToOverlappingPixels(glass: Bool) throws {
        let clock = WheelTestClock()
        let scene = LayoutWheelGlassRenderer(clock: clock)
        defer { scene.stop() }
        scene.configure(.init(configuration: .init(levelCount: .one), appearance: .init(useLiquidGlass: glass),
            selection: .init(ring: .inner, sector: .right)), reduceMotion: false,
            reduceTransparency: false, increasedContrast: false)
        clock.settle()
        let canvas = NSView(frame: scene.bounds); canvas.wantsLayer = true; canvas.addSubview(scene)
        func capture() throws -> NSBitmapImageRep {
            canvas.layoutSubtreeIfNeeded(); canvas.displayIfNeeded()
            let bitmap = try #require(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
            canvas.cacheDisplay(in: canvas.bounds, to: bitmap); return bitmap
        }
        let before = try capture()
        var checked = 0
        scene.beginExit(.commit) {}
        clock.frame()
        clock.time += 0.16 - 1 / 60; clock.callback?(clock.time)
        let opacity = try #require(scene.exitPresentation?.opacity)
        #expect(abs(opacity - 0.5) < 0.0001)
        let after = try capture()
        let scale = Double(before.pixelsWide) / canvas.bounds.width
        for point in [CGPoint(x: scene.bounds.midX + 58, y: scene.bounds.midY),
                      CGPoint(x: scene.bounds.midX, y: scene.bounds.midY + 16),
                      CGPoint(x: scene.bounds.midX - 65, y: scene.bounds.midY)] {
            let x = Int(point.x * scale), y = Int(point.y * scale)
            let first = try #require(before.colorAt(x: x, y: y))
            let last = try #require(after.colorAt(x: x, y: y))
            if first.alphaComponent > 0.1 { checked += 1; #expect(abs(last.alphaComponent / first.alphaComponent - opacity) < 0.03) }
        }
        if !glass { #expect(checked > 0, "The solid capture must have visible pixels") }
        // Native glass is a WindowServer effect. AppKit cacheDisplay can return
        // an empty glass subtree; verify its single alpha owner structurally.
        #expect(scene.layer?.allowsGroupOpacity == true)
        #expect(abs(Double(scene.layer?.opacity ?? 0) - opacity) < 0.0001)
        #expect(scene.hosting?.layer?.opacity == 1)
    }
}
