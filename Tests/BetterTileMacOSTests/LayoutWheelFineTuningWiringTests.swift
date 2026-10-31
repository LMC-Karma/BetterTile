import AppKit
import BetterTileCore
import Testing
@testable import BetterTileMacOS

@MainActor @Suite(.macOSTestApplication, .serialized) struct LayoutWheelFineTuningWiringTests {
    @Test func everySettingMapsToProductRendererAndContent() {
        var wheel = LayoutWheelConfiguration(style: .grouped, levelCount: .two)
        wheel.appearance.liquid.look = .init(material: .clear, highlightColour: .violet, names: .underIcons, actionTint: true)
        wheel.appearance.liquid.motion = .init(opening: .quick, closing: .sink, pointerLean: true, leanAmount: 13)
        wheel.appearance.liquid.feel = .init(tension: 5, ringing: 0.8, bulge: 15, stretch: 57,
                                            splash: 2, magnetDamping: 0.9, dropletResponse: 0.7)
        wheel.appearance.liquid.translucency = .init(light: 0.15, dark: 0.8)
        wheel.appearance.liquid.submenus = .init(arrangement: .clusterAboveThree, keepOpen: .withinGroupAngle)
        let renderer = LayoutWheelLiquidPresenter()
        renderer.panelForTesting.animationBehavior = .none
        LayoutWheelLiquidDefaults.apply(to: renderer, configuration: wheel, appearance: .init(), systemDark: true)
        #expect(renderer.tuning.tension == 5)
        #expect(renderer.tuning.ringing == 0.8)
        #expect(renderer.tuning.bulge == 15)
        #expect(renderer.tuning.stretch == 57)
        #expect(renderer.tuning.splash == 2)
        #expect(renderer.tuning.magnetDamping == 0.9)
        #expect(renderer.tuning.dropletResponse == 0.7)
        #expect(renderer.tuning.opening == .quick && renderer.tuning.closing == .sink)
        #expect(renderer.tuning.drift == 13)
        #expect(renderer.material == .automatic && renderer.names == .underIcons && renderer.actionTint)
        #expect(renderer.accent == LayoutWheelLiquidDefaults.accent(.violet))
        #expect(renderer.translucency == 0.8)
        #expect(LayoutWheelLiquidDefaults.content(configuration: wheel).submenuLayout?.style == .clusterAboveThree)
        #expect(LayoutWheelLiquidDefaults.lockBeyondRim(configuration: wheel) == .withinGroupAngle)
        wheel.appearance.liquid.motion.pointerLean = false
        LayoutWheelLiquidDefaults.apply(to: renderer, configuration: wheel, appearance: .init())
        #expect(renderer.tuning.drift == 0)
        #expect(wheel.appearance.liquid.isModified)
        wheel.appearance.liquid.resetToStyleDefaults()
        LayoutWheelLiquidDefaults.apply(to: renderer, configuration: wheel, appearance: .init())
        #expect(!wheel.appearance.liquid.isModified)
        #expect(renderer.tuning.tension == 2.6 && renderer.material == .automatic && renderer.names == .centre)
    }

    @Test(arguments: [false, true]) func systemAndExplicitThemesChooseMatchingTranslucency(dark: Bool) {
        var wheel = LayoutWheelConfiguration()
        wheel.appearance.liquid.translucency = .init(light: 0.17, dark: 0.83)
        let renderer = LayoutWheelLiquidPresenter()
        renderer.panelForTesting.animationBehavior = .none
        LayoutWheelLiquidDefaults.apply(to: renderer, configuration: wheel, appearance: .init(), systemDark: dark)
        #expect(renderer.dark == nil && renderer.translucency == (dark ? 0.83 : 0.17))
        wheel.appearance.liquid.appearance = .light
        LayoutWheelLiquidDefaults.apply(to: renderer, configuration: wheel, appearance: .init(), systemDark: dark)
        #expect(renderer.dark == false && renderer.translucency == 0.17)
        wheel.appearance.liquid.appearance = .dark
        LayoutWheelLiquidDefaults.apply(to: renderer, configuration: wheel, appearance: .init(), systemDark: dark)
        #expect(renderer.dark == true && renderer.translucency == 0.83)
    }

    @Test func prewarmRetainsThemeAndNamesInItsKey() {
        let adapter = LayoutWheelLiquidAdapter()
        adapter.isOpenHandler = { true }
        adapter.refreshAppearanceHandler = {}
        var dark = false, count = 0
        adapter.systemDarkProvider = { dark }
        adapter.prewarmHandler = { _ in count += 1 }
        var wheel = LayoutWheelConfiguration()
        adapter.prewarm(configuration: wheel, appearance: .init())
        #expect(count == 1)
        wheel.appearance.liquid.feel.tension = 5
        adapter.prewarm(configuration: wheel, appearance: .init())
        #expect(count == 1)
        wheel.appearance.liquid.appearance = .dark
        adapter.prewarm(configuration: wheel, appearance: .init())
        #expect(count == 2)
        wheel.appearance.liquid.look.names = .underIcons
        adapter.prewarm(configuration: wheel, appearance: .init())
        #expect(count == 3)
        wheel.appearance.liquid.appearance = .system
        adapter.prewarm(configuration: wheel, appearance: .init())
        #expect(count == 4)
        dark = true
        adapter.prewarm(configuration: wheel, appearance: .init())
        #expect(count == 5)
    }

    @Test func closedSettingsChangesPrepareOnlyThePipeline() {
        let adapter = LayoutWheelLiquidAdapter()
        var pipelines = 0, contents = 0, refreshes = 0
        adapter.pipelinePrepareHandler = { pipelines += 1; return true }
        adapter.prewarmHandler = { _ in contents += 1 }
        adapter.refreshAppearanceHandler = { refreshes += 1 }
        var wheel = LayoutWheelConfiguration()
        adapter.prewarm(configuration: wheel, appearance: .init())
        wheel.appearance.liquid.feel.tension = 5
        adapter.prewarm(configuration: wheel, appearance: .init())
        wheel.appearance.liquid.appearance = .dark
        adapter.prewarm(configuration: wheel, appearance: .init())
        wheel.appearance.liquid.look.names = .underIcons
        adapter.prewarm(configuration: wheel, appearance: .init())
        wheel.setGroup(.init(quickAction: .windowAction(.center), options: [.windowAction(.restore)]), at: .top)
        adapter.prewarm(configuration: wheel, appearance: .init())
        #expect(pipelines == 5)
        #expect(contents == 0 && refreshes == 0)
        #expect(adapter.renderer.atlasForTesting == nil)
        #expect(adapter.renderer.tuning.tension == 5 && adapter.renderer.dark == true && adapter.renderer.names == .underIcons)
    }

    @Test func openWheelPicksUpSettingsChangesWithoutClosedPrewarming() {
        let adapter = LayoutWheelLiquidAdapter()
        var open = true, pipelines = 0, contents = 0, refreshes = 0
        adapter.isOpenHandler = { open }
        adapter.pipelinePrepareHandler = { pipelines += 1; return true }
        adapter.prewarmHandler = { _ in contents += 1 }
        adapter.refreshAppearanceHandler = { refreshes += 1 }
        var wheel = LayoutWheelConfiguration()
        adapter.prewarm(configuration: wheel, appearance: .init())
        adapter.prewarm(configuration: wheel, appearance: .init())
        #expect(contents == 1 && refreshes == 1)
        wheel.appearance.liquid.selectPreset(.warm)
        adapter.prewarm(configuration: wheel, appearance: .init())
        #expect(adapter.renderer.accent == LayoutWheelLiquidDefaults.accent(.champagne))
        #expect(adapter.renderer.tuning.tension == 2.6 && adapter.renderer.tuning.bulge == 4)
        #expect(contents == 1 && refreshes == 2 && pipelines == 0)
        open = false
        wheel.appearance.liquid.look.names = .hidden
        adapter.prewarm(configuration: wheel, appearance: .init())
        #expect(contents == 1 && refreshes == 2 && pipelines == 1)
        open = true
        adapter.prewarm(configuration: wheel, appearance: .init())
        #expect(contents == 2 && refreshes == 3 && adapter.renderer.names == .hidden)
    }

    @Test func iceUsesSharedFixedBlueAndOnlySystemAccentIsNil() {
        for colour in LayoutWheelLiquidSettings.HighlightColour.allCases {
            #expect((LayoutWheelLiquidDefaults.accent(colour) == nil) == (colour == .systemAccent))
        }
        for preset in [LayoutWheelLiquidSettings.Preset.ice] {
            var wheel = LayoutWheelConfiguration()
            wheel.appearance.liquid = .init(preset: preset)
            let renderer = LayoutWheelLiquidPresenter()
            renderer.panelForTesting.animationBehavior = .none
            LayoutWheelLiquidDefaults.apply(to: renderer, configuration: wheel, appearance: .init())
            #expect(renderer.accent == LayoutWheelLiquidDefaults.iceBlue)
            #expect(renderer.accent != NSColor.systemPink)
            let pink = LayoutWheelLiquidStyle.make(dark: true, opaque: false, accent: renderer.accent ?? .systemPink)
            let green = LayoutWheelLiquidStyle.make(dark: true, opaque: false, accent: renderer.accent ?? .systemGreen)
            #expect(pink.accent == green.accent)
        }
    }

    @Test(arguments: [false, true]) func previewFailuresDrawPanelWithMatchingGeometry(late: Bool) async throws {
        let coordinator = LayoutWheelLiquidPreview.Coordinator()
        coordinator.prepareHandler = { late }
        coordinator.openHandler = { _, _ in false }
        let host = NSView()
        var mode = LayoutWheelPreviewMode.liquid
        let wheel = LayoutWheelConfiguration(style: .grouped, levelCount: .two)
        coordinator.update(host, configuration: wheel, appearance: .init(), state: .init(), currentMode: .manual,
                           playback: nil, modeChanged: { mode = $0 })
        await Task.yield()
        #expect(mode == .panel)
        #expect(coordinator.fallback != nil && !host.subviews.isEmpty)
        let geometry = LayoutWheelPreviewGeometry(configuration: wheel, mode: mode)
        var actual = LayoutWheelFanState(), expected = LayoutWheelFanState()
        let vector = BTPoint(x: 0, y: -130)
        let result = geometry.update(vector: vector, at: 1, fan: &actual)
        expected.update(vector: vector, at: 1, geometry: LayoutWheelMetrics.grouped.fanGeometry(for: wheel))
        #expect(result == expected.selection)
        #expect(geometry.diameter == LayoutWheelMetrics.grouped.groupedPresentationDiameter)
        #expect(coordinator.fallback?.frame.width == CGFloat(geometry.diameter))
        coordinator.stop()
    }

    @Test func sliderEditsDoNotReplayButPlayAndStyleChangesDo() {
        let coordinator = LayoutWheelLiquidPreview.Coordinator()
        coordinator.prepareHandler = { true }
        var opens = 0
        var endings: [LayoutWheelLiquid.Ending] = []
        coordinator.endHandler = { endings.append($0) }
        coordinator.openHandler = { _, _ in opens += 1; return true }
        let host = NSView()
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        var wheel = LayoutWheelConfiguration()
        func update(_ play: LayoutWheelPreviewPlayback? = nil) {
            coordinator.update(host, configuration: wheel, appearance: .init(), state: .init(), currentMode: .manual,
                               playback: play, modeChanged: { _ in })
        }
        update(); #expect(opens == 1)
        wheel.appearance.liquid.feel.tension = 5
        update(); #expect(opens == 1)
        #expect(coordinator.renderer.tuning.tension == 5)
        wheel.appearance.liquid.translucency.light = 0.7
        update(); #expect(opens == 1)
        update(.init(generation: 1, motion: .opening)); #expect(opens == 2)
        update(.init(generation: 1, motion: .opening)); #expect(opens == 2)
        update(.init(generation: 2, motion: .closing)); #expect(opens == 3)
        #expect(endings == [.cancel])
        wheel.appearance.liquid.selectPreset(.warm)
        update(.init(generation: 2, motion: .closing)); #expect(opens == 4)
        wheel.appearance.size = .large
        update(.init(generation: 2, motion: .closing)); #expect(opens == 5)
        #expect(coordinator.renderer.reduceMotion == true)
        wheel.appearance.liquid.look.material = .clear
        update(.init(generation: 2, motion: .closing)); #expect(opens == 5)
        update(.init(generation: 3, motion: .opening)); #expect(opens == 6)
        #expect(coordinator.renderer.reduceMotion == nil)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        wheel.appearance.liquid.feel.tension = 4
        update(); #expect(opens == 6)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        #expect(opens == 7)
        coordinator.stop()
    }

    private final class GesturePresenter: LayoutWheelPresenting {
        var usesLiquidGeometry = true
        var last: LayoutWheelPresentation?
        func open(_ value: LayoutWheelPresentation) { last = value }
        func update(_ value: LayoutWheelPresentation) { last = value }
        func showPlacements(_ placements: [Placement]) {}
        func hidePlacements() {}
        func close() {}
    }

    @Test(arguments: LayoutWheelLiquidSettings.Arrangement.allCases, LayoutWheelLiquidSettings.KeepOpen.allCases)
    func controllerAndPreviewShareConfiguredSubmenus(arrangement: LayoutWheelLiquidSettings.Arrangement,
                                                     keep: LayoutWheelLiquidSettings.KeepOpen) throws {
        var wheel = LayoutWheelConfiguration(style: .grouped, levelCount: .two)
        wheel.appearance.liquid.submenus = .init(arrangement: arrangement, keepOpen: keep)
        wheel.setGroup(.init(quickAction: .windowAction(.center), options:
            [.windowAction(.leftHalf), .windowAction(.rightHalf), .windowAction(.topHalf), .windowAction(.bottomHalf)]), at: .top)
        var leaning = wheel
        leaning.appearance.liquid.motion.pointerLean = true
        leaning.appearance.liquid.motion.leanAmount = 16
        let content = LayoutWheelLiquidDefaults.content(configuration: wheel)
        let leanGeometry = LayoutWheelLiquidDefaults.content(configuration: leaning).wheelGeometry
        #expect(leanGeometry.hubRadius == content.wheelGeometry.hubRadius)
        #expect(leanGeometry.innerRingOuterRadius == content.wheelGeometry.innerRingOuterRadius)
        #expect(leanGeometry.outerRingInnerRadius == content.wheelGeometry.outerRingInnerRadius)
        wheel = leaning
        let layout = try #require(content.submenuLayout)
        #expect(layout.usesCluster(count: 4) == (arrangement != .fan))
        let presenter = GesturePresenter()
        var pointer = BTPoint(x: 800, y: 500), time = 1.0
        let target = LayoutWheelTarget(windowID: .init(rawValue: "fixture"), displayID: .init(rawValue: "test"),
            visibleFrame: .init(x: 0, y: 0, width: 1600, height: 1000))
        let controller = LayoutWheelController(configuration: .init(layoutWheel: wheel), presenter: presenter,
            now: { time }, pointerProvider: { pointer }, addGlobalMonitor: { _, _ in NSObject() },
            addLocalMonitor: { _, _ in NSObject() }, removeMonitor: { _ in })
        controller.captureHandler = { _ in target }
        controller.previewHandler = { _, _ in .ready(placements: []) }
        controller.start()
        defer { controller.stop() }
        controller.handleModifiers([.control, .option, .shift])
        controller.handleActivationDeadline(generation: 1)
        let center = try #require(presenter.last?.placement.center)
        #expect(center == pointer)
        var previewFan = LayoutWheelFanState()
        let geometry = LayoutWheelPreviewGeometry(configuration: wheel, mode: .liquid)
        func move(_ vector: BTPoint) {
            pointer = .init(x: center.x + vector.x, y: center.y + vector.y)
            controller.handlePointer(pointer)
            _ = geometry.update(vector: vector, at: time, fan: &previewFan)
        }
        let top = BTPoint(x: 0, y: -content.layout.iconRadii.last!)
        move(top)
        time += 0.21
        controller.handleFanDeadline()
        _ = geometry.update(vector: top, at: time, fan: &previewFan)
        #expect(presenter.last?.fan.openSector == .top)
        for (index, point) in layout.positions(sector: .top, count: 4).enumerated() {
            move(point)
            #expect(presenter.last?.fan.optionIndex == index)
            #expect(previewFan.optionIndex == index)
        }
        move(.init(x: 500, y: 500))
        #expect((presenter.last?.fan.openSector == .top) == (keep == .always))
        #expect((previewFan.openSector == .top) == (keep == .always))
    }

    @Test func snapshotCacheIsBoundedByStyleThemeAndSizeAndReleasesImages() async {
        var calls = 0
        weak var image: NSImage?
        weak var cache: LayoutWheelStyleSnapshots?
        do {
            let snapshots = LayoutWheelStyleSnapshots { _, _, _ in calls += 1; return NSImage(size: .init(width: 20, height: 20)) }
            cache = snapshots
            #expect(snapshots.image(preset: .ice, dark: false, size: .medium) == nil)
            #expect(calls == 0) // A body read never creates a render.
            await snapshots.load(dark: false, size: .medium)
            image = snapshots.image(preset: .ice, dark: false, size: .medium)
            #expect(image != nil && calls == 4)
            await snapshots.load(dark: false, size: .medium)
            #expect(calls == 4)
            await snapshots.load(dark: true, size: .medium)
            #expect(snapshots.count == 8 && calls == 8)
            await snapshots.load(dark: true, size: .large)
            #expect(snapshots.count == 4 && calls == 12)
            let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
            snapshots.observe(window: window)
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            #expect(snapshots.count == 0 && !snapshots.isActive)
            await snapshots.load(dark: false, size: .large)
            #expect(calls == 12)
        }
        #expect(image == nil && cache == nil)
        let failed = LayoutWheelStyleSnapshots { _, _, _ in nil }
        await failed.load(dark: false, size: .medium)
        #expect(failed.image(preset: .ice, dark: false, size: .medium) == nil)
    }

    @Test func snapshotStyleMatchesPresenterStyle() throws {
        guard LayoutWheelLiquidPresenter.prepare() else { return }
        let renderer = LayoutWheelLiquidPresenter(clock: WheelTestClock())
        defer { renderer.close() }
        for preset in LayoutWheelLiquidSettings.Preset.allCases {
            for dark in [false, true] {
                var wheel = LayoutWheelConfiguration()
                wheel.appearance.liquid = .init(preset: preset, appearance: dark ? .dark : .light)
                LayoutWheelLiquidDefaults.apply(to: renderer, configuration: wheel, appearance: .init())
                renderer.opaque = false
                let content = LayoutWheelLiquidDefaults.content(configuration: wheel)
                #expect(renderer.prepareToOpen(content))
                #expect(renderer.styleForTesting == LayoutWheelLiquidDefaults.snapshotStyle(configuration: wheel, dark: dark))
            }
        }
    }

    @Test func snapshotPreparationCost() async throws {
        guard let folder = ProcessInfo.processInfo.environment["BT_WHEEL_SNAPSHOT_TIMING_DIR"] else { return }
        let snapshots = LayoutWheelStyleSnapshots()
        let render = snapshots.render
        var times: [Double] = []
        let uptime = { ProcessInfo.processInfo.systemUptime } // real-time: this opt-in benchmark reports actual render cost
        snapshots.render = { preset, dark, size in
            let began = uptime()
            defer { times.append((uptime() - began) * 1000) }
            return render(preset, dark, size)
        }
        let began = uptime()
        await snapshots.load(dark: false, size: .medium)
        let elapsed = (uptime() - began) * 1000
        let data = try JSONSerialization.data(withJSONObject: ["fourImagesMs": elapsed, "perImageMs": times,
            "images": snapshots.count, "policy": "Task-driven; lookup in body never renders"], options: .prettyPrinted)
        try data.write(to: URL(filePath: folder).appending(path: "snapshot-timing.json"))
    }
}
