import AppKit
import QuartzCore
import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

@MainActor private final class FlickPresenter: LayoutWheelPresenting {
    var latest: LayoutWheelPresentation?
    func open(_ presentation: LayoutWheelPresentation) { latest = presentation }
    func update(_ presentation: LayoutWheelPresentation) { latest = presentation }
    func showPlacements(_ placements: [Placement]) {}
    func hidePlacements() {}
    func close() {}
}

/// The real controller with a fake window and presenter, driven by the geometry
/// of the live flick helper: hold the trigger past the deadline, then 12
/// pointer steps from the wheel centre straight up, then release.
@MainActor private final class FlickWheel {
    let presenter = FlickPresenter()
    let origin = BTPoint(x: 700, y: 430)
    var pointer = BTPoint(x: 700, y: 430)
    var time = 100.0
    var commits: [LayoutWheelCommand] = []
    var controller: LayoutWheelController!

    init(levels: LayoutWheelLevelCount, scale: Double, metrics: LayoutWheelMetrics) {
        var configuration = BetterTileConfiguration(layoutWheel: .init(style: .custom, levelCount: levels))
        configuration.layoutWheel.scale = scale
        controller = LayoutWheelController(
            configuration: configuration, presenter: presenter, metrics: metrics,
            now: { [unowned self] in time },
            pointerProvider: { [unowned self] in pointer },
            addGlobalMonitor: { _, _ in NSObject() },
            addLocalMonitor: { _, _ in NSObject() }, removeMonitor: { _ in })
        controller.captureHandler = { _ in
            LayoutWheelTarget(windowID: WindowID(rawValue: "fixture"), displayID: DisplayID(rawValue: "display"),
                visibleFrame: BTRect(x: 0, y: 30, width: 1920, height: 971), layoutMode: .bento)
        }
        controller.previewHandler = { _, _ in .ready(placements: []) }
        controller.commitHandler = { [unowned self] command, _ in commits.append(command) }
        controller.start()
        controller.handleModifiers([.control, .option, .shift])
        controller.handleActivationDeadline(generation: 1)
    }

    /// Delivers the first `delivered` of 12 steps to the controller, then
    /// releases. The pointer itself always reaches the endpoint, as in the live
    /// run; only the delivery of samples before the release varies.
    func flick(distance: Double, delivered: Int) {
        pointer = BTPoint(x: origin.x, y: origin.y - distance)
        for step in 1...max(1, delivered) where step <= delivered {
            time = 100 + Double(step) * 0.002
            controller.handlePointer(BTPoint(x: origin.x, y: origin.y - distance * Double(step) / 12))
        }
        controller.handleModifiers([.control, .option])
        controller.handleModifiers([.control])
        controller.handleModifiers([])
    }
}

/// Smaller Custom geometry: 23 pt hub, with all other metrics unchanged.
@MainActor private let w1CustomMetrics = LayoutWheelMetrics(
    hubRadius: 23, innerRingOuterRadius: 68, outerRingInnerRadius: 76, outerRingOuterRadius: 110,
    oneLevelInnerRingOuterRadius: 84)!

/// Custom resamples the final pointer at release, so a flick commits the sector
/// under the final pointer regardless of how many samples arrived first. These
/// tests cover both the 23 pt and 32 pt wells.
@Suite(.macOSTestApplication) struct LayoutWheelQuickFlickTests {

    @Test(arguments: [LayoutWheelLevelCount.one, .two], [0.8, 1.0, 1.2])
    @MainActor func aFullyDeliveredFlickCommitsTopHalf(levels: LayoutWheelLevelCount, scale: Double) {
        let distance = (levels == .one ? 58.0 : 50.0) * scale
        for metrics in [LayoutWheelMetrics.standard, w1CustomMetrics] {
            let wheel = FlickWheel(levels: levels, scale: scale, metrics: metrics)
            defer { wheel.controller.stop() }
            #expect(wheel.controller.isOpen)
            wheel.flick(distance: distance, delivered: 12)
            #expect(wheel.commits == [.windowAction(.topHalf)])
        }
    }

    /// Releasing with 0 to 12 of the 12 samples delivered still commits the
    /// final pointer's sector, in both geometries. Previously, the 32 pt well
    /// needed more delivered samples than the 23 pt well.
    @Test(arguments: [LayoutWheelLevelCount.one, .two], [0.8, 1.0, 1.2])
    @MainActor func aReleaseCommitsTheFinalPointerWhateverWasDelivered(levels: LayoutWheelLevelCount, scale: Double) {
        let distance = (levels == .one ? 58.0 : 50.0) * scale
        for metrics in [LayoutWheelMetrics.standard, w1CustomMetrics] {
            for delivered in 0...12 {
                let wheel = FlickWheel(levels: levels, scale: scale, metrics: metrics)
                defer { wheel.controller.stop() }
                wheel.flick(distance: distance, delivered: delivered)
                #expect(wheel.commits == [.windowAction(.topHalf)], "delivered \(delivered) of 12")
                #expect(!wheel.controller.isOpen)
            }
        }
    }

    /// A release with no pointer movement at all still cancels.
    @Test @MainActor func aReleaseWithoutMovementCancelsWithoutACommit() {
        let wheel = FlickWheel(levels: .one, scale: 1, metrics: .standard)
        defer { wheel.controller.stop() }
        wheel.flick(distance: 0, delivered: 0)
        #expect(wheel.commits.isEmpty)
        #expect(!wheel.controller.isOpen)
    }
}

/// Opt-in main-thread cost of opening and updating the real panel presenter,
/// far offscreen. It uses presenter APIs shared by both geometries. Set
/// `BT_WHEEL_TIMING_FILE`.
@Suite(.macOSTestApplication, .serialized) struct LayoutWheelPresenterTimingTests {
    @Test @MainActor func presenterOpenAndUpdateCost() throws {
        guard let path = ProcessInfo.processInfo.environment["BT_WHEEL_TIMING_FILE"] else { return }
        func millis(_ body: () -> Void) -> Double {
            let start = CACurrentMediaTime(); body(); return (CACurrentMediaTime() - start) * 1000
        }
        /// Time until a marker queued behind the pending main-thread work runs,
        /// then a Core Animation flush. This counts deferred layout and display.
        func drain() -> Double {
            let start = CACurrentMediaTime()
            var done = false
            // A nested run loop does not drain the main dispatch queue, so the
            // marker is a run loop block.
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) { done = true }
            CFRunLoopWakeUp(CFRunLoopGetMain())
            // Never pump without a bound: give up after 5 s.
            let limit = start + 5
            while !done, CACurrentMediaTime() < limit { // real-time: bounds this opt-in timing probe's run-loop pump
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
            }
            #expect(done, "The main run loop did not reach the queued marker within 5 s")
            CATransaction.flush()
            return (CACurrentMediaTime() - start) * 1000
        }
        var rows: [[String: Any]] = []
        for style in [LayoutWheelStyle.custom, .grouped] {
            let configuration = LayoutWheelConfiguration(style: style, levelCount: .two)
            let placement = LayoutWheelPlacement.clamped(anchor: BTPoint(x: -5000, y: -5000),
                diameter: style == .grouped ? LayoutWheelMetrics.grouped.groupedPresentationDiameter : 300,
                visibleFrame: BTRect(x: -6000, y: -6000, width: 2000, height: 2000))
            var presentation = LayoutWheelPresentation(configuration: configuration, placement: placement,
                                                      selection: nil, unavailableCommands: [])
            for iteration in 0..<12 {
                let presenter = LayoutWheelPanelPresenter(capturePolicy: OverlayCapturePolicy())
                presentation.selection = nil
                let open = millis { presenter.open(presentation) }
                let openSettle = drain()
                presentation.selection = .init(ring: .inner, sector: .top)
                let update = millis { presenter.update(presentation) }
                let updateSettle = drain()
                presentation.selection = .init(ring: .inner, sector: .right)
                let second = millis { presenter.update(presentation) }
                let secondSettle = drain()
                let close = millis { presenter.close() }
                rows.append(["style": style.rawValue, "iteration": iteration, "open_ms": open, "open_settle_ms": openSettle,
                             "update_ms": update, "update_settle_ms": updateSettle,
                             "second_update_ms": second, "second_settle_ms": secondSettle, "close_ms": close])
            }
        }
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(filePath: path))
    }
}
