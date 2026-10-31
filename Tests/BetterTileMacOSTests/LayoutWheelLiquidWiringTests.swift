import AppKit
import Metal
import QuartzCore
import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

@MainActor @Suite(.macOSTestApplication, .serialized) struct LayoutWheelLiquidWiringTests {
    private final class Presenter: LayoutWheelPresenting {
        var usesLiquidGeometry = true
        var events: [String] = []
        var failOpenToPanel = false
        var last: LayoutWheelPresentation?
        func prewarm(configuration: LayoutWheelConfiguration, appearance: OverlayAppearance) { events.append("prewarm") }
        func prepareToOpen(configuration: LayoutWheelConfiguration, appearance: OverlayAppearance) { events.append("prepare") }
        func discardPreparation() { events.append("discard") }
        func open(_ presentation: LayoutWheelPresentation) {
            events.append("open"); last = presentation
            if failOpenToPanel { usesLiquidGeometry = false; failOpenToPanel = false }
        }
        func update(_ presentation: LayoutWheelPresentation) { last = presentation }
        func showPlacements(_ placements: [Placement]) {}
        func hidePlacements() {}
        func close() {}
    }

    @Test func preparationFollowsLaunchConfigurationHoldAndCancellation() {
        let presenter = Presenter()
        let controller = LayoutWheelController(configuration: .init(), presenter: presenter,
            pointerProvider: { .init(x: 800, y: 500) }, addGlobalMonitor: { _, _ in NSObject() },
            addLocalMonitor: { _, _ in NSObject() }, removeMonitor: { _ in })
        controller.start()
        #expect(presenter.events == ["prewarm"])
        controller.configuration.layoutWheel.levelCount = .two
        #expect(presenter.events.last == "prewarm")
        controller.handleModifiers([.control, .option, .shift])
        #expect(presenter.events.last == "prepare")
        controller.cancelPendingActivation()
        #expect(presenter.events.last == "discard")
        controller.stop()
    }

    @Test(arguments: ["release", "stop", "disable", "triggerChange", "noTarget", "ownership", "monitorFailure"])
    func everyPendingExitDiscardsPreparation(_ reason: String) {
        let presenter = Presenter()
        let controller = LayoutWheelController(configuration: .init(), presenter: presenter,
            pointerProvider: { .init(x: 800, y: 500) },
            addGlobalMonitor: { mask, _ in reason == "monitorFailure" && mask.contains(.keyDown) ? nil : NSObject() },
            addLocalMonitor: { _, _ in NSObject() }, removeMonitor: { _ in })
        controller.start()
        controller.handleModifiers([.control, .option, .shift])
        #expect(presenter.events.contains("prepare"))
        switch reason {
        case "release": controller.handleModifiers([])
        case "stop": controller.stop()
        case "disable": controller.configuration.layoutWheel.isEnabled = false
        case "triggerChange": controller.configuration.layoutWheel.keyboardModifiers = [.control, .command]
        case "noTarget": controller.handleActivationDeadline(generation: 1)
        case "ownership": controller.cancel(reason: .mouseDown)
        default: break
        }
        #expect(!controller.isPendingActivation && !controller.isOpen)
        #expect(presenter.events.filter { $0 == "discard" }.count == 1)
        controller.stop()
    }

    @Test(arguments: [LayoutWheelStyle.custom, .grouped], [LayoutWheelLevelCount.one, .two])
    func controllerGeometryAndReleaseMatchLiquidContent(style: LayoutWheelStyle, levels: LayoutWheelLevelCount) throws {
        for size in [LayoutWheelSize.small, .medium, .large] {
            var configuration = LayoutWheelConfiguration(style: style, levelCount: levels)
            configuration.appearance.size = size
            configuration.setGroup(.init(quickAction: .windowAction(.center), options: [.repairBento, nil, .setMode(.tabbed)]), at: .top)
            configuration.groupedInnerSlots[0] = .windowAction(.restore)
            let content = LayoutWheelLiquidDefaults.content(configuration: configuration, currentMode: .tabbed)
            let presenter = Presenter()
            var pointer = BTPoint(x: 800, y: 500)
            var time = 1.0
            let target = LayoutWheelTarget(windowID: .init(rawValue: "fixture"), displayID: .init(rawValue: "display"),
                                          visibleFrame: .init(x: 0, y: 0, width: 1600, height: 1000), layoutMode: .tabbed)
            let controller = LayoutWheelController(configuration: .init(layoutWheel: configuration), presenter: presenter,
                metrics: .grouped, now: { time }, pointerProvider: { pointer },
                addGlobalMonitor: { _, _ in NSObject() }, addLocalMonitor: { _, _ in NSObject() }, removeMonitor: { _ in })
            controller.captureHandler = { _ in target }
            controller.previewHandler = { _, _ in .ready(placements: []) }
            var commits: [LayoutWheelCommand] = []
            controller.commitHandler = { command, _ in commits.append(command) }
            controller.start()
            defer { controller.stop() }
            var generation = 0
            func open() throws -> BTPoint {
                pointer = .init(x: 800, y: 500)
                generation += 1
                controller.handleModifiers([.control, .option, .shift])
                controller.handleActivationDeadline(generation: generation)
                let presentation = try #require(presenter.last)
                #expect(presentation.placement.diameter == content.diameter)
                return presentation.placement.center
            }
            func move(_ vector: BTPoint, center: BTPoint) {
                pointer = .init(x: center.x + vector.x, y: center.y + vector.y)
                controller.handlePointer(pointer)
            }
            func release(expected: LayoutWheelCommand?) {
                let count = commits.count
                controller.handleModifiers([])
                #expect(commits.count == count + (expected == nil ? 0 : 1))
                if let expected { #expect(commits.last == expected) }
            }
            for ring in content.rings {
                for sector in LayoutWheelSector.allCases {
                    let center = try open()
                    let index = try #require(content.ringIndex(ring.ring))
                    let angle = content.layout.slotAngle(sector.rawValue)
                    let vector = BTPoint(x: cos(angle) * content.layout.iconRadii[index], y: sin(angle) * content.layout.iconRadii[index])
                    move(vector, center: center)
                    let selection = content.wheelGeometry.selection(for: vector, levelCount: levels)
                    #expect(presenter.last?.selection == selection)
                    let state = LayoutWheelLiquidState(selection: selection)
                    release(expected: content.command(state))
                }
            }
            if style == .grouped, let layout = content.submenuLayout {
                for sector in LayoutWheelSector.allCases {
                    for (index, point) in layout.positions(sector: sector, count: configuration.group(at: sector).options.count).enumerated() {
                        let center = try open()
                        let angle = content.layout.slotAngle(sector.rawValue)
                        let radius = content.layout.iconRadii.last!
                        move(.init(x: cos(angle) * radius, y: sin(angle) * radius), center: center)
                        time += 0.21
                        controller.handleFanDeadline()
                        move(point, center: center)
                        let state = LayoutWheelLiquidState(selection: presenter.last?.selection, fan: presenter.last?.fan, pointer: point)
                        #expect(presenter.last?.fan.optionIndex == index)
                        release(expected: content.command(state))
                    }
                }
            }
        }
    }

    @Test func lateFallbackReopensWithMatchingPanelGeometry() throws {
        let presenter = Presenter()
        presenter.failOpenToPanel = true
        var pointer = BTPoint(x: 800, y: 500)
        let configuration = LayoutWheelConfiguration(style: .grouped, levelCount: .two)
        let target = LayoutWheelTarget(windowID: .init(rawValue: "fixture"), displayID: .init(rawValue: "display"),
                                      visibleFrame: .init(x: 0, y: 0, width: 1600, height: 1000))
        let controller = LayoutWheelController(configuration: .init(layoutWheel: configuration), presenter: presenter,
            pointerProvider: { pointer }, addGlobalMonitor: { _, _ in NSObject() },
            addLocalMonitor: { _, _ in NSObject() }, removeMonitor: { _ in })
        controller.captureHandler = { _ in target }
        controller.previewHandler = { _, _ in .ready(placements: []) }
        var commits: [LayoutWheelCommand] = []
        controller.commitHandler = { command, _ in commits.append(command) }
        controller.start()
        defer { controller.stop() }
        controller.handleModifiers([.control, .option, .shift])
        controller.handleActivationDeadline(generation: 1)
        #expect(presenter.events.filter { $0 == "open" }.count == 2)
        #expect(presenter.last?.placement.diameter == LayoutWheelMetrics.grouped.groupedPresentationDiameter)
        let center = try #require(presenter.last?.placement.center)
        pointer = .init(x: center.x + 124, y: center.y)
        controller.handlePointer(pointer)
        controller.handleModifiers([])
        #expect(commits == [.windowAction(.nextDisplay)])
    }

    @Test func edgePlacementReservesEveryEditedFan() throws {
        let presenter = Presenter()
        var configuration = LayoutWheelConfiguration(style: .grouped, levelCount: .two)
        configuration.setGroup(.init(quickAction: nil, options: Array(repeating: .repairBento, count: 6)), at: .top)
        let content = LayoutWheelLiquidDefaults.content(configuration: configuration)
        let target = LayoutWheelTarget(displayID: .init(rawValue: "display"),
                                      visibleFrame: .init(x: 0, y: 0, width: 1600, height: 1000))
        let controller = LayoutWheelController(configuration: .init(layoutWheel: configuration), presenter: presenter,
            pointerProvider: { .init(x: 1, y: 1) }, addGlobalMonitor: { _, _ in NSObject() },
            addLocalMonitor: { _, _ in NSObject() }, removeMonitor: { _ in })
        controller.captureHandler = { _ in target }
        controller.start()
        defer { controller.stop() }
        controller.handleModifiers([.control, .option, .shift])
        controller.handleActivationDeadline(generation: 1)
        let placement = try #require(presenter.last?.placement)
        #expect(placement.diameter == content.diameter)
        let layout = try #require(content.submenuLayout)
        for sector in LayoutWheelSector.allCases {
            for point in layout.positions(sector: sector, count: configuration.group(at: sector).options.count) {
                #expect(placement.center.x + point.x - layout.optionRadius >= 0)
                #expect(placement.center.y + point.y - layout.optionRadius >= 0)
                #expect(placement.center.x + point.x + layout.optionRadius <= 1600)
                #expect(placement.center.y + point.y + layout.optionRadius <= 1000)
            }
        }
    }

    @Test func failedPipelineUsesPanelFallback() {
        var attempts = 0
        let presenter = LayoutWheelLiquidAdapter.make { attempts += 1; return false }
        #expect(presenter is LayoutWheelPanelPresenter)
        #expect(!presenter.usesLiquidGeometry && attempts == 1)
    }

    @Test(arguments: [true, false])
    func systemGlassFallbackIsOpaqueForBothAppearanceOptions(reduceTransparency: Bool) throws {
        try #require(MTLCreateSystemDefaultDevice() != nil)
        let renderer = LayoutWheelLiquidPresenter(clock: WheelTestClock())
        renderer.displayOptions = {
            .init(reduceMotion: true, reduceTransparency: reduceTransparency, increaseContrast: !reduceTransparency)
        }
        let configuration = LayoutWheelConfiguration()
        LayoutWheelLiquidDefaults.apply(to: renderer, configuration: configuration, appearance: .init())
        #expect(renderer.prepareToOpen(LayoutWheelLiquidDefaults.content(configuration: configuration)))
        #expect(renderer.styleForTesting.bodyTint.w == 1)
        #expect(renderer.blurIsHiddenForTesting)
        renderer.close()
        #expect(renderer.drawableSizeForTesting == CGSize(width: 1, height: 1))
    }

    @Test func semanticChangesAtRestRebuildModeIconsAndUnavailableInk() throws {
        try #require(MTLCreateSystemDefaultDevice() != nil)
        let clock = WheelTestClock()
        let renderer = LayoutWheelLiquidPresenter(clock: clock)
        let configuration = LayoutWheelConfiguration(style: .grouped, levelCount: .two)
        let first = LayoutWheelLiquidDefaults.content(configuration: configuration, currentMode: .manual)
        #expect(renderer.open(first, center: .init(x: -20_000, y: -20_000)))
        clock.settle(hz: 60)
        let oldAtlas = try #require(renderer.atlasForTesting)
        let modeChange = LayoutWheelLiquidDefaults.content(configuration: configuration, currentMode: .tabbed)
        renderer.update(modeChange, state: .init())
        #expect(renderer.atlasForTesting !== oldAtlas)
        let modeAtlas = try #require(renderer.atlasForTesting)
        let unavailable: Set<LayoutWheelCommand> = [.windowAction(.maximize), .windowAction(.almostMaximize),
                                                   .windowAction(.center), .windowAction(.centerResize)]
        let changed = LayoutWheelLiquidDefaults.content(configuration: configuration,
            unavailableCommands: unavailable, layoutAvailable: false, currentMode: .tabbed)
        renderer.update(changed, state: .init(selection: .init(ring: .outer, sector: .top)))
        #expect(renderer.atlasForTesting === modeAtlas)
        #expect(clock.isRunning)
        clock.frame()
        #expect(changed.centreName(.init(selection: .init(ring: .outer, sector: .top)))?.available == false)
        renderer.close()
    }

    @Test func displayOptionsCanChangeDuringAnOpenGesture() throws {
        try #require(MTLCreateSystemDefaultDevice() != nil)
        let clock = WheelTestClock()
        let renderer = LayoutWheelLiquidPresenter(clock: clock)
        var options = LayoutWheelDisplayOptions(reduceMotion: false, reduceTransparency: false, increaseContrast: false)
        renderer.displayOptions = { options }
        let content = LayoutWheelLiquidDefaults.content(configuration: .init())
        #expect(renderer.open(content, center: .init(x: -20_000, y: -20_000)))
        for option in 0..<3 {
            options = .init(reduceMotion: option == 2, reduceTransparency: option == 0, increaseContrast: option == 1)
            renderer.refreshAppearance()
            #expect(renderer.currentModel?.reduceMotion == options.reduceMotion)
            #expect(renderer.blurIsHiddenForTesting == (option < 2))
            #expect((renderer.styleForTesting.bodyTint.w == 1) == (option < 2))
        }
        renderer.opaque = true
        renderer.refreshAppearance()
        #expect(renderer.styleForTesting.bodyTint.w == 1 && renderer.blurIsHiddenForTesting)
        renderer.close()
    }

    @Test func quickReopenReplacesTheClosingGesture() throws {
        try #require(MTLCreateSystemDefaultDevice() != nil)
        let clock = WheelTestClock()
        let renderer = LayoutWheelLiquidPresenter(clock: clock)
        let content = LayoutWheelLiquidDefaults.content(configuration: .init())
        let center = BTPoint(x: -20_000, y: -20_000)
        #expect(renderer.open(content, center: center))
        clock.frame()
        renderer.end(.commit)
        clock.frame()
        #expect(renderer.open(content, center: center))
        clock.settle(hz: 60)
        #expect(renderer.currentModel?.phase == .open && renderer.isOpen)
        renderer.close()
    }

    @Test func realMetalLinkCanReprepareRefreshAndReopenDuringClosing() throws {
        try #require(MTLCreateSystemDefaultDevice() != nil)
        let renderer = LayoutWheelLiquidPresenter()
        renderer.panelForTesting.animationBehavior = .none
        let content = LayoutWheelLiquidDefaults.content(configuration: .init())
        let center = BTPoint(x: -20_000, y: -20_000)
        #expect(renderer.open(content, center: center))
        renderer.end(.commit)
        #expect(renderer.prepareToOpen(content))
        #expect(renderer.open(content, center: center))
        renderer.refreshAppearance()
        #expect(renderer.currentModel?.phase == .open)
        renderer.close()
    }

    @Test func preparationFailureAndOpenFailureUseFallback() throws {
        let renderer = LayoutWheelLiquidPresenter(clock: WheelTestClock())
        let adapter = LayoutWheelLiquidAdapter(renderer: renderer)
        adapter.prepareHandler = { _ in false }
        adapter.prepareToOpen(configuration: .init(), appearance: .init())
        #expect(!adapter.usesLiquidGeometry)
        let other = LayoutWheelLiquidAdapter(renderer: renderer)
        other.openHandler = { _, _, _ in false }
        let presentation = LayoutWheelPresentation(configuration: .init(),
            placement: .init(anchor: .init(x: -20_000, y: -20_000), center: .init(x: -20_000, y: -20_000), diameter: 300),
            selection: nil, unavailableCommands: [])
        other.open(presentation)
        #expect(!other.usesLiquidGeometry)
        other.update(presentation)
        other.close()
    }

    @Test func holdPreparationUsesTheLastCapturedTarget() throws {
        try #require(MTLCreateSystemDefaultDevice() != nil)
        let renderer = LayoutWheelLiquidPresenter(clock: WheelTestClock())
        let adapter = LayoutWheelLiquidAdapter(renderer: renderer)
        let configuration = LayoutWheelConfiguration(style: .grouped, levelCount: .two)
        let center = BTPoint(x: -20_000, y: -20_000)
        // An ordinary Manual desktop: a known mode, and Choose Layout unavailable.
        let presentation = LayoutWheelPresentation(configuration: configuration,
            placement: .init(anchor: center, center: center, diameter: 300), selection: nil,
            unavailableCommands: [], layoutAvailable: false, currentMode: .manual)
        var atlasRebuiltAtOpen: [Bool] = []
        for _ in 0..<2 {
            adapter.prepareToOpen(configuration: configuration, appearance: .init())
            let prepared = renderer.preparationCountForTesting
            let atlas = try #require(renderer.atlasForTesting)
            adapter.open(presentation)
            #expect(adapter.usesLiquidGeometry && renderer.isOpen)
            // Opening never repeats the hold's full preparation.
            #expect(renderer.preparationCountForTesting == prepared)
            atlasRebuiltAtOpen.append(renderer.atlasForTesting !== atlas)
            adapter.close()
        }
        // The first hold could not know the Mode icon. The next hold uses the
        // last captured target, so its icons are ready at open.
        #expect(atlasRebuiltAtOpen == [true, false])
    }

    @Test func adapterAndEmbeddedPreviewReleaseTheirRendererAndView() throws {
        try #require(MTLCreateSystemDefaultDevice() != nil)
        weak var weakAdapter: LayoutWheelLiquidAdapter?
        weak var weakRenderer: LayoutWheelLiquidPresenter?
        weak var weakView: NSView?
        weak var weakPanel: NSPanel?
        weak var weakCoordinator: LayoutWheelLiquidPreview.Coordinator?
        autoreleasepool {
            let renderer = LayoutWheelLiquidPresenter(clock: WheelTestClock())
            let adapter = LayoutWheelLiquidAdapter(renderer: renderer)
            adapter.prewarm(configuration: .init(), appearance: .init())
            adapter.prepareToOpen(configuration: .init(), appearance: .init())
            weakAdapter = adapter; weakRenderer = renderer; weakView = renderer.previewView; weakPanel = renderer.panelForTesting
        }
        CATransaction.flush()
        #expect(weakAdapter == nil && weakRenderer == nil && weakView == nil && weakPanel == nil)
        autoreleasepool {
            let coordinator = LayoutWheelLiquidPreview.Coordinator()
            weakCoordinator = coordinator
            weakRenderer = coordinator.renderer
            weakView = coordinator.renderer.previewView
            let host = NSView()
            host.addSubview(coordinator.renderer.makePreviewView())
            let content = LayoutWheelLiquidDefaults.content(configuration: .init())
            #expect(coordinator.renderer.open(content, center: .init(x: 0, y: 0), state: .init(), inPanel: false))
            #expect(!coordinator.renderer.isVisible)
            coordinator.renderer.refreshAppearance()
            #expect(coordinator.renderer.isOpen && coordinator.renderer.previewView.superview === host)
            LayoutWheelLiquidPreview.dismantleNSView(host, coordinator: coordinator)
        }
        CATransaction.flush()
        #expect(weakCoordinator == nil && weakRenderer == nil && weakView == nil)
    }
}
