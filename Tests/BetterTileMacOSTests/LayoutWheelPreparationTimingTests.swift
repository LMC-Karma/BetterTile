import AppKit
import BetterTileTestSupport
import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

@MainActor @Suite(.macOSTestApplication, .serialized) struct LayoutWheelPreparationTimingTests {
    private final class Presenter: LayoutWheelPresenting {
        var prepare: () -> Void = {}
        func prepareToOpen(configuration: LayoutWheelConfiguration, appearance: OverlayAppearance) { prepare() }
        func open(_ presentation: LayoutWheelPresentation) {}
        func update(_ presentation: LayoutWheelPresentation) {}
        func showPlacements(_ placements: [Placement]) {}
        func hidePlacements() {}
        func close() {}
    }

    @Test(arguments: [0.052, 0.08, 0.25])
    func preparationConsumesTheExistingHold(preparationSeconds: Double) async throws {
        var time = 0.0
        var waits: [Double] = []
        let presenter = Presenter()
        presenter.prepare = { time += preparationSeconds }
        let controller = LayoutWheelController(configuration: .init(), presenter: presenter,
            activationWait: { delay in
                let parts = delay.components
                waits.append(Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
            }, now: { time }, pointerProvider: { .init(x: 800, y: 500) },
            addGlobalMonitor: { _, _ in NSObject() }, addLocalMonitor: { _, _ in NSObject() }, removeMonitor: { _ in })
        controller.start()
        defer { controller.stop() }
        controller.handleModifiers([.control, .option, .shift])
        for _ in 0..<10 where waits.isEmpty { await Task.yield() }
        let waited = try #require(waits.first)
        #expect(abs(waited - max(0, 0.22 - preparationSeconds)) < 1e-9)
    }

    @Test func stoppedActivationDoesNotReadAReleasedClockOwner() async throws {
        var ownerAlive = true
        var lateRead = false
        var waits = 0
        let controller = LayoutWheelController(configuration: .init(), presenter: Presenter(),
            activationWait: { _ in waits += 1 },
            now: { if !ownerAlive { lateRead = true }; return 0 },
            pointerProvider: { .init(x: 800, y: 500) },
            addGlobalMonitor: { _, _ in NSObject() }, addLocalMonitor: { _, _ in NSObject() }, removeMonitor: { _ in })
        controller.start()
        controller.handleModifiers([.control, .option, .shift])
        // stop() clears the controller's handle; keep the task to join it.
        let activation = try #require(controller.activationTaskForTesting)
        controller.stop()
        ownerAlive = false
        await activation.value
        #expect(!lateRead)
        // The cancelled task left at its first check and never began the wait.
        #expect(waits == 0)
    }

    @Test func activationCancelledDuringTheHoldDoesNotReadAReleasedClockOwner() async throws {
        let clock = ManualClock()
        var ownerAlive = true
        var lateRead = false
        var waitEnd: String?
        let controller = LayoutWheelController(configuration: .init(), presenter: Presenter(),
            activationWait: { delay in
                do {
                    try await clock.sleep(for: delay)
                    waitEnd = "elapsed"
                } catch {
                    waitEnd = "cancelled"
                    throw error
                }
            },
            now: { if !ownerAlive { lateRead = true }; return 0 },
            pointerProvider: { .init(x: 800, y: 500) },
            addGlobalMonitor: { _, _ in NSObject() }, addLocalMonitor: { _, _ in NSObject() }, removeMonitor: { _ in })
        controller.start()
        controller.handleModifiers([.control, .option, .shift])
        let activation = try #require(controller.activationTaskForTesting)
        await clock.waitForSleepers(count: 1)
        controller.stop()
        ownerAlive = false
        await activation.value
        #expect(waitEnd == "cancelled")
        #expect(clock.pendingSleepCount == 0)
        #expect(!lateRead)
    }
}
