import AppKit
import Metal
import Testing
#if !BETTERTILE_TEST_HOOKS
#error("Tests require BETTERTILE_TEST_HOOKS. Use Tools/test.sh LOG --release for Release tests.")
#endif
@_spi(LiquidWheelPrototype) @testable import BetterTileCore
@_spi(LiquidWheelPrototype) @testable import BetterTileMacOS

/// The panel opens far outside every display, so nothing appears on screen.
/// `WheelTestClock` replaces the display link; the GPU work is real.
@MainActor @Suite(.macOSTestApplication, .serialized) struct LayoutWheelLiquidPresenterTests {
    private let offscreen = BTPoint(x: -20_000, y: -20_000)
    private let grouped = LayoutWheelLiquidContent(configuration: .init(style: .grouped), levelCount: .two)

    private func selection(_ sector: LayoutWheelSector, ring: LayoutWheelRing = .outer) -> LayoutWheelLiquidState {
        let content = grouped
        let index = content.ringIndex(ring) ?? 0
        let angle = content.layout.slotAngle(sector.rawValue)
        let radius = content.layout.iconRadii[index]
        return .init(selection: .init(ring: ring, sector: sector),
                     pointer: BTPoint(x: cos(angle) * radius, y: sin(angle) * radius))
    }

    private func makePresenter(_ clock: WheelTestClock) -> LayoutWheelLiquidPresenter {
        let presenter = LayoutWheelLiquidPresenter(clock: clock)
        presenter.reduceMotion = false
        presenter.dark = true
        presenter.opaque = false
        return presenter
    }

    @Test(.liquidPipeline) func openingWaitsForAReadyDrawable() throws {
        try #require(MTLCreateSystemDefaultDevice() != nil)
        let clock = WheelTestClock()
        let presenter = makePresenter(clock)
        #expect(presenter.open(grouped, center: offscreen))
        // Opening requests a frame. It must never acquire a drawable synchronously.
        #expect(presenter.renderedFrameCount == 0)
        clock.frame()
        #expect(presenter.renderedFrameCount == 1)
        presenter.close()
        let closed = presenter.renderedFrameCount
        clock.frame()
        #expect(presenter.renderedFrameCount == closed)
    }

    @Test(.liquidPipeline) func centreNameWaitsForTheBodyFrame() throws {
        try #require(MTLCreateSystemDefaultDevice() != nil)
        let clock = WheelTestClock()
        let presenter = makePresenter(clock)
        #expect(presenter.open(grouped, center: offscreen))
        clock.frame()
        let before = try #require(presenter.labelImageForTesting)
        presenter.update(selection(.right))
        #expect(presenter.labelImageForTesting === before)
        clock.frame()
        #expect(presenter.labelImageForTesting !== before)
        presenter.close()
    }

    @Test(.liquidPipeline) func pipelineIsBuiltOnceForEveryOpen() throws {
        try #require(MTLCreateSystemDefaultDevice() != nil, "This Mac has no Metal device.")
        #expect(LayoutWheelLiquidPresenter.prepare())
        let builds = LayoutWheelLiquidPipeline.buildCount
        #expect(builds == 1)
        let clock = WheelTestClock()
        for _ in 0..<3 {
            let presenter = makePresenter(clock)
            #expect(presenter.open(grouped, center: offscreen))
            presenter.close()
        }
        #expect(LayoutWheelLiquidPresenter.prepare())
        #expect(LayoutWheelLiquidPipeline.buildCount == builds)
    }

    @Test(.liquidPipeline) func clockRunsOnlyWhileTheModelMoves() throws {
        try #require(MTLCreateSystemDefaultDevice() != nil)
        let clock = WheelTestClock()
        let presenter = makePresenter(clock)
        #expect(presenter.open(grouped, center: offscreen))
        #expect(clock.isRunning)
        clock.settle(hz: 120)
        #expect(!clock.isRunning)
        let resting = presenter.renderedFrameCount
        // The same state again, and the clock stays stopped.
        presenter.update(.init())
        #expect(!clock.isRunning)
        // A new aim wakes it; it stops again once the snap settles.
        presenter.update(selection(.right))
        #expect(clock.isRunning)
        clock.settle(hz: 120)
        #expect(!clock.isRunning)
        let settled = presenter.renderedFrameCount
        #expect(settled > resting)
        #expect(presenter.currentModel?.isAtRest == true)
        // Pointer motion inside the same slot draws nothing new.
        var same = selection(.right)
        same.pointer = BTPoint(x: 110, y: 2)
        presenter.update(same)
        #expect(!clock.isRunning)
        #expect(presenter.renderedFrameCount == settled)
        presenter.close()
    }

    @Test(.liquidPipeline) func closingFreesTheDrawablesAndStopsEverything() throws {
        try #require(MTLCreateSystemDefaultDevice() != nil)
        for ending in [LayoutWheelLiquid.Ending.commit, .cancel] {
            let clock = WheelTestClock()
            let presenter = makePresenter(clock)
            var closedCount = 0
            presenter.onClosed = { closedCount += 1 }
            #expect(presenter.open(grouped, center: offscreen, state: selection(.left)))
            #expect(presenter.holdsDrawables && presenter.isVisible)
            clock.settle(hz: 120)
            let full = try #require(presenter.drawableSizeForTesting)
            #expect(full.width >= grouped.diameter && full.height >= grouped.diameter)
            presenter.end(ending)
            #expect(clock.isRunning)
            var frames = 0
            while clock.isRunning, frames < 120 { clock.frame(hz: 120); frames += 1 }
            #expect(frames < (ending == .commit ? 60 : 40))
            #expect(closedCount == 1)
            #expect(!presenter.isOpen && !presenter.isVisible)
            // The real release: the layer's drawables shrink to one pixel.
            #expect(presenter.drawableSizeForTesting == CGSize(width: 1, height: 1))
            #expect(!presenter.holdsDrawables)
            #expect(!clock.isRunning)
            // Late input after closing does nothing.
            presenter.update(selection(.top))
            presenter.end(.commit)
            #expect(!clock.isRunning && closedCount == 1)
        }
    }

    @Test(.liquidPipeline) func preparingDuringTheHoldShowsNothingAndOpenReusesIt() throws {
        try #require(MTLCreateSystemDefaultDevice() != nil)
        let clock = WheelTestClock()
        let presenter = makePresenter(clock)
        #expect(presenter.prepareToOpen(grouped))
        #expect(!presenter.isVisible && !presenter.isOpen && !clock.isRunning)
        #expect(presenter.holdsDrawables)
        #expect(presenter.renderedFrameCount == 0)
        let atlas = try #require(presenter.atlasForTesting)
        #expect(presenter.open(grouped, center: offscreen))
        // The icons drawn at the hold are the ones the open uses.
        #expect(presenter.atlasForTesting === atlas)
        #expect(presenter.renderedFrameCount == 0 && presenter.isVisible)
        clock.frame()
        #expect(presenter.renderedFrameCount == 1)
        presenter.close()
        #expect(!presenter.holdsDrawables)
        // The next hold sets the drawables up again.
        #expect(presenter.prepareToOpen(grouped))
        #expect(presenter.holdsDrawables && !presenter.isVisible)
    }

    @Test(.liquidPipeline) func openingWithTheCapturedTargetReusesTheHoldPreparation() throws {
        try #require(MTLCreateSystemDefaultDevice() != nil)
        let clock = WheelTestClock()
        let presenter = makePresenter(clock)
        // The hold starts before the target is captured.
        #expect(presenter.prepareToOpen(grouped))
        #expect(presenter.preparationCountForTesting == 1)
        let target = LayoutWheelLiquidContent(configuration: .init(style: .grouped), levelCount: .two,
                                              unavailableCommands: [.windowAction(.maximize)],
                                              layoutAvailable: false, currentMode: .manual)
        #expect(presenter.open(target, center: offscreen))
        #expect(presenter.preparationCountForTesting == 1)
        clock.frame()
        #expect(presenter.renderedFrameCount == 1)
        // The drawn content follows the captured target.
        #expect(presenter.currentModel != nil)
        presenter.update(target, state: selection(.top))
        presenter.close()
        // A different wheel still prepares in full.
        #expect(presenter.prepareToOpen(grouped))
        let custom = LayoutWheelLiquidContent(configuration: .init(), levelCount: .two)
        #expect(presenter.open(custom, center: offscreen))
        #expect(presenter.preparationCountForTesting == 3)
        presenter.close()
    }

    @Test(.liquidPipeline) func reduceMotionClosesWithAShortFade() throws {
        try #require(MTLCreateSystemDefaultDevice() != nil)
        let clock = WheelTestClock()
        let presenter = makePresenter(clock)
        presenter.reduceMotion = true
        #expect(presenter.open(grouped, center: offscreen, state: selection(.top)))
        clock.settle(hz: 120)
        #expect(presenter.currentModel?.scale == 1)
        presenter.end(.cancel)
        var frames = 0
        while clock.isRunning, frames < 120 { clock.frame(hz: 120); frames += 1 }
        #expect(frames <= 16) // About 0.12 s at 120 Hz.
        #expect(!presenter.holdsDrawables)
    }

    @Test(.liquidPipeline) func offscreenFrameDrawsTheBodyAndLeavesTheCornersClear() throws {
        try #require(MTLCreateSystemDefaultDevice() != nil)
        let pipeline = try #require(LayoutWheelLiquidPipeline.prepare())
        let encoder = try #require(LayoutWheelLiquidEncoder(pipeline: pipeline))
        var model = LayoutWheelLiquid(layout: grouped.layout)
        model.open()
        for _ in 0..<120 { model.advance(1 / 60) }
        let size = CGSize(width: grouped.diameter, height: grouped.diameter)
        let image = try #require(encoder.image(model, style: .make(dark: true, opaque: false), size: size, scale: 1))
        let rep = NSBitmapImageRep(cgImage: image)
        func alpha(_ x: Int, _ y: Int) -> CGFloat { rep.colorAt(x: x, y: y)?.alphaComponent ?? -1 }
        let side = Int(grouped.diameter)
        #expect(alpha(2, 2) == 0)
        // Inside the outer ring, between two icons.
        let angle = grouped.layout.slotAngle(0) + .pi / 8
        let r = grouped.layout.iconRadii[1]
        #expect(alpha(side / 2 + Int(cos(angle) * r), side / 2 + Int(sin(angle) * r)) > 0.2)
    }

    @Test func groupedIsTheCustomSizePlusChevronRoom() {
        for levels in LayoutWheelLevelCount.allCases {
            for size in LayoutWheelSize.allCases {
                var configuration = LayoutWheelConfiguration(style: .custom, levelCount: levels)
                configuration.appearance.size = size
                let custom = LayoutWheelLiquidContent(configuration: configuration, levelCount: levels)
                configuration.style = .grouped
                let groupedContent = LayoutWheelLiquidContent(configuration: configuration, levelCount: levels)
                #expect(abs(groupedContent.layout.outerRadius - custom.layout.outerRadius
                            - LayoutWheelLiquidContent.chevronRoom * size.scale) < 1e-9)
                #expect(groupedContent.layout.wellRadius == custom.layout.wellRadius)
                #expect(groupedContent.layout.iconRadii == custom.layout.iconRadii)
            }
        }
        // A fan needs less room than a cluster of six.
        let fanned = LayoutWheelLiquidContent(configuration: .init(style: .grouped), levelCount: .two, submenuStyle: .fan)
        let clustered = LayoutWheelLiquidContent(configuration: .init(style: .grouped), levelCount: .two,
                                                 submenuStyle: .cluster)
        #expect(fanned.diameter < clustered.diameter)
        #expect(fanned.diameter < 400)
    }

    @Test(arguments: [LayoutWheelStyle.custom, .grouped], [LayoutWheelLevelCount.one, .two])
    func legacyScaleDrawsAtTheSelectedSize(style: LayoutWheelStyle, levels: LayoutWheelLevelCount) {
        for (legacy, size) in [(0.85, LayoutWheelSize.small), (1.1, .large), (1.3, .large), (0.95, .medium)] {
            var migrated = LayoutWheelConfiguration(style: style, levelCount: levels)
            migrated.scale = legacy
            #expect(migrated.appearance.size == size)
            var chosen = LayoutWheelConfiguration(style: style, levelCount: levels)
            chosen.appearance.size = size
            let drawn = LayoutWheelLiquidContent(configuration: migrated, levelCount: levels)
            let expected = LayoutWheelLiquidContent(configuration: chosen, levelCount: levels)
            #expect(drawn.layout.scale == size.scale, "legacy \(legacy)")
            #expect(drawn.diameter == expected.diameter && drawn.layout.iconRadii == expected.layout.iconRadii)
            #expect(drawn.wheelGeometry.hubRadius == expected.wheelGeometry.hubRadius)
        }
    }

    @Test(arguments: [LayoutWheelLevelCount.one, .two], LayoutWheelSubmenuStyle.allCases)
    func leavingTheBoundedLockClearsTheRenderedAimAndRelease(levels: LayoutWheelLevelCount,
                                                           style: LayoutWheelSubmenuStyle) throws {
        let content = LayoutWheelLiquidContent(configuration: .init(style: .grouped, levelCount: levels), levelCount: levels,
                                               submenuStyle: style)
        let layout = try #require(content.submenuLayout)
        let parent = BTPoint(x: content.layout.iconRadii.last!, y: 0)
        var submenu = LayoutWheelSubmenuState()
        func update(_ vector: BTPoint, _ time: Double) {
            submenu.update(vector: vector, at: time, geometry: content.wheelGeometry, layout: layout,
                           lockBeyondRim: .withinGroupAngle, configuration: content.configuration)
        }
        update(parent, 0)
        update(parent, 0.25)
        update(layout.positions(sector: .right, count: 1)[0], 0.3)
        #expect(content.command(.init(submenu: submenu, pointer: nil)) == .windowAction(.previousDisplay))
        let farSide = BTPoint(x: -1_000, y: 0)
        update(farSide, 0.4)
        let state = LayoutWheelLiquidState(submenu: submenu, pointer: farSide)
        #expect(content.command(state) == nil && content.centreName(state) == nil)
        let input = content.liquidInput(state)
        #expect(input.fan == nil && input.focus == nil)
        #expect(submenu.release() == nil)
    }

    @Test func contentDrawsTheSameCommandsAsTheNativeWheel() {
        let custom = LayoutWheelLiquidContent(configuration: .init(levelCount: .two), levelCount: .two)
        let native = LayoutWheelSceneInput(configuration: .init(levelCount: .two))
        for ring in LayoutWheelRing.allCases {
            for sector in LayoutWheelSector.allCases {
                let selection = LayoutWheelSelection(ring: ring, sector: sector)
                #expect(custom.slot(selection) == native.slot(.sector(selection)))
                #expect(custom.command(.init(selection: selection)) == LayoutWheelConfiguration(levelCount: .two).command(at: selection))
            }
        }
        // Grouped: the aimed child wins over its parent.
        var submenu = LayoutWheelSubmenuState()
        let layout = try! #require(grouped.submenuLayout)
        let parent = BTPoint(x: grouped.layout.iconRadii[1], y: 0)
        submenu.update(vector: parent, at: 0, geometry: grouped.wheelGeometry, layout: layout)
        submenu.update(vector: parent, at: 0.25, geometry: grouped.wheelGeometry, layout: layout)
        #expect(submenu.openSector == .right)
        let child = layout.positions(sector: .right, count: 1)[0]
        submenu.update(vector: child, at: 0.3, geometry: grouped.wheelGeometry, layout: layout)
        let state = LayoutWheelLiquidState(submenu: submenu, pointer: child)
        #expect(grouped.command(state) == .windowAction(.previousDisplay))
        let input = grouped.liquidInput(state)
        #expect(input.fan?.options.count == 1 && input.fan?.aimedOption == 0)
        #expect(input.focus == .init(ring: 1, slot: LayoutWheelSector.right.rawValue))
        // The native wheel's fan state maps onto the same moment.
        #expect(LayoutWheelLiquidState(selection: submenu.selection, fan: nil, pointer: nil).openSector == nil)
    }
}
