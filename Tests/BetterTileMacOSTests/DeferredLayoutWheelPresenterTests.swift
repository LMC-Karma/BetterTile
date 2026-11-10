import AppKit
import BetterTileCore
import Testing
@testable import BetterTileMacOS

@MainActor private final class DeferredPresenterRecorder: LayoutWheelPresenting {
    var usesLiquidGeometry = true
    var presentationFailureHandler: (@MainActor () -> Void)?
    var captures: [Bool] = []
    var warmed: [(LayoutWheelConfiguration, OverlayAppearance)] = []
    var preparations = 0
    var gestures = 0
    var closes = 0
    var discards = 0
    var hiddenPlacements = 0
    var prepare: () -> Void = {}
    var opened: () -> Void = {}
    func setCaptureVisibility(showsInRecordings: Bool) { captures.append(showsInRecordings) }
    func prewarm(configuration: LayoutWheelConfiguration, appearance: OverlayAppearance) { warmed.append((configuration, appearance)) }
    func prepareToOpen(configuration: LayoutWheelConfiguration, appearance: OverlayAppearance) { preparations += 1; prepare() }
    func beginGesture() { gestures += 1 }
    func open(_ presentation: LayoutWheelPresentation) { opened() }
    func update(_ presentation: LayoutWheelPresentation) {}
    func showPlacements(_ placements: [Placement]) {}
    func hidePlacements() { hiddenPlacements += 1 }
    func close() { closes += 1 }
    func discardPreparation() { discards += 1 }
}

@Suite(.macOSTestApplication) @MainActor
struct DeferredLayoutWheelPresenterTests {
    @Test func keyboardWarmupAndIdleCleanupDoNotCreateAController() {
        var creations = 0
        let deferred = DeferredLayoutWheelPresenter { creations += 1; return DeferredPresenterRecorder() }
        deferred.prewarm(configuration: .init(), appearance: .init())
        deferred.setCaptureVisibility(showsInRecordings: true)
        deferred.close()
        deferred.discardPreparation()
        deferred.hidePlacements()
        deferred.end(.cancel)
        #expect(creations == 0)
    }

    @Test func firstPreparationUsesTheLatestConfigurationAndCapturePolicy() {
        var creations = 0
        var failures = 0
        let backend = DeferredPresenterRecorder()
        let deferred = DeferredLayoutWheelPresenter { creations += 1; return backend }
        deferred.presentationFailureHandler = { failures += 1 }
        var configuration = LayoutWheelConfiguration()
        deferred.prewarm(configuration: configuration, appearance: .init())
        configuration.scale = 1.2
        deferred.prewarm(configuration: configuration, appearance: .init())
        deferred.setCaptureVisibility(showsInRecordings: true)
        #expect(creations == 0)
        deferred.prepareToOpen(configuration: configuration, appearance: .init())
        #expect(creations == 1 && backend.preparations == 1)
        #expect(backend.warmed.count == 1 && backend.warmed[0].0 == configuration)
        #expect(backend.captures == [true])
        backend.presentationFailureHandler?()
        #expect(failures == 1)
    }

    @Test(arguments: [LayoutWheelTriggers.Mouse.middleClick, .optionMiddleClick])
    func mouseTriggersKeepLaunchPreparation(mouse: LayoutWheelTriggers.Mouse) {
        var creations = 0
        let backend = DeferredPresenterRecorder()
        let deferred = DeferredLayoutWheelPresenter { creations += 1; return backend }
        var configuration = LayoutWheelConfiguration()
        configuration.triggers.mouse = mouse
        deferred.prewarm(configuration: configuration, appearance: .init())
        #expect(creations == 1 && backend.warmed.count == 1)
        deferred.beginGesture()
        #expect(creations == 1 && backend.gestures == 1)
    }

    @Test func enablingAMouseTriggerPreparesItBeforeTheFirstClick() {
        var creations = 0
        let deferred = DeferredLayoutWheelPresenter { creations += 1; return DeferredPresenterRecorder() }
        var configuration = LayoutWheelConfiguration()
        configuration.triggers.mouse = .middleClick
        configuration.isEnabled = false
        deferred.prewarm(configuration: configuration, appearance: .init())
        #expect(creations == 0)
        configuration.isEnabled = true
        deferred.prewarm(configuration: configuration, appearance: .init())
        #expect(creations == 1)
    }

    @Test func subsequentGesturesAndCleanupReuseThePresenter() {
        var creations = 0
        let backend = DeferredPresenterRecorder()
        let deferred = DeferredLayoutWheelPresenter { creations += 1; return backend }
        for _ in 0..<3 {
            deferred.prepareToOpen(configuration: .init(), appearance: .init())
            deferred.beginGesture()
            deferred.discardPreparation()
            deferred.hidePlacements()
            deferred.close()
        }
        #expect(creations == 1 && backend.preparations == 3 && backend.gestures == 3)
        #expect(backend.discards == 3 && backend.hiddenPlacements == 3 && backend.closes == 3)
    }

    @Test func aFallbackReportsItsGeometryBeforeTheControllerPlacesIt() {
        let backend = DeferredPresenterRecorder()
        backend.usesLiquidGeometry = false
        let deferred = DeferredLayoutWheelPresenter { backend }
        deferred.prepareToOpen(configuration: .init(), appearance: .init())
        #expect(!deferred.usesLiquidGeometry)
    }

    @Test func deferredPreparationConsumesTheExistingKeyboardHold() async {
        var uptime = 0.0
        var requestedWait: Duration?
        var openedAt: Double?
        let backend = DeferredPresenterRecorder()
        backend.prepare = { uptime += 0.076 }
        backend.opened = { openedAt = uptime }
        let deferred = DeferredLayoutWheelPresenter { backend }
        let controller = LayoutWheelController(configuration: .init(), presenter: deferred,
            activationWait: { duration in
                requestedWait = duration
                let parts = duration.components
                uptime += Double(parts.seconds) + Double(parts.attoseconds) / 1e18
            }, now: { uptime }, pointerProvider: { .init(x: 500, y: 400) },
            addGlobalMonitor: { _, _ in NSObject() }, addLocalMonitor: { _, _ in NSObject() }, removeMonitor: { _ in })
        controller.captureHandler = { _ in .init(windowID: .init(rawValue: "fake-window"), displayID: .init(rawValue: "fake-display"), visibleFrame: .init(x: 0, y: 0, width: 1000, height: 800)) }
        controller.previewHandler = { _, _ in .ready(placements: []) }
        controller.start()
        defer { controller.stop() }
        controller.handleModifiers(LayoutWheelTriggers.defaultModifiers)
        await controller.activationTaskForTesting?.value
        let wait = requestedWait?.components
        let remaining = wait.map { Double($0.seconds) + Double($0.attoseconds) / 1e18 }
        #expect(remaining.map { abs($0 - 0.144) < 0.000001 } == true)
        #expect(openedAt.map { abs($0 - 0.220) < 0.000001 } == true)
        #expect(controller.isOpen)
    }
}
