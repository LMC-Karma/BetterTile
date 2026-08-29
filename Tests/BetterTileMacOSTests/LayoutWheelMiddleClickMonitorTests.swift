import AppKit
import BetterTileCore
import CoreGraphics
import Foundation
import Testing
@testable import BetterTileMacOS

private let middleTarget = LayoutWheelTarget(
    windowID: WindowID(rawValue: "middle-window"),
    displayID: DisplayID(rawValue: "middle-display"),
    visibleFrame: BTRect(x: 0, y: 0, width: 1600, height: 1000)
)
private let middleAnchor = BTPoint(x: 800, y: 500)
private let middleKeyboardTrigger: ShortcutModifiers = [.control, .option, .shift]

@Test func onlyUnmodifiedPhysicalButtonTwoIsReserved() {
    #expect(LayoutWheelMiddleClickEvent.reserves(button: 2, modifiers: []))
    #expect(!LayoutWheelMiddleClickEvent.reserves(button: 0, modifiers: []))
    #expect(!LayoutWheelMiddleClickEvent.reserves(button: 1, modifiers: []))
    #expect(!LayoutWheelMiddleClickEvent.reserves(button: 3, modifiers: []))
    #expect(!LayoutWheelMiddleClickEvent.reserves(button: 2, modifiers: [.command]))
    #expect(!LayoutWheelMiddleClickEvent.reserves(button: 2, modifiers: [.control, .option]))
}

@Test func reservationOwnsTheWholeClickEvenIfModifiersChange() {
    var reservation = LayoutWheelMiddleClickReservation()

    let down = reservation.shouldReserve(kind: .down, button: 2, modifiers: [])
    #expect(down)
    #expect(reservation.ownsGesture)
    let extraButton = reservation.shouldReserve(kind: .dragged, button: 3, modifiers: [])
    let dragged = reservation.shouldReserve(kind: .dragged, button: 2, modifiers: [.command])
    let up = reservation.shouldReserve(kind: .up, button: 2, modifiers: [.command])
    #expect(!extraButton)
    #expect(dragged)
    #expect(up)
    #expect(!reservation.ownsGesture)
}

@Test func modifiedMiddleClickNeverBecomesReserved() {
    var reservation = LayoutWheelMiddleClickReservation()

    let down = reservation.shouldReserve(kind: .down, button: 2, modifiers: [.shift])
    let dragged = reservation.shouldReserve(kind: .dragged, button: 2, modifiers: [])
    let up = reservation.shouldReserve(kind: .up, button: 2, modifiers: [])
    #expect(!down)
    #expect(!dragged)
    #expect(!up)
}

@MainActor
private final class FakeMiddleClickMonitor: LayoutWheelMiddleClickMonitoring {
    var eventHandler: ((LayoutWheelMiddleClickEvent) -> Void)?
    var failureHandler: ((String?) -> Void)?
    var isRunning = false
    var canStart = true
    var stopCount = 0

    func start() -> Bool {
        guard canStart else {
            failureHandler?("Middle-click reservation failed.")
            return false
        }
        isRunning = true
        failureHandler?(nil)
        return true
    }

    func stop() {
        isRunning = false
        stopCount += 1
    }

    func emit(_ kind: LayoutWheelMiddleClickEventKind, at position: BTPoint) {
        eventHandler?(LayoutWheelMiddleClickEvent(
            kind: kind,
            position: position,
            button: 2,
            modifiers: [],
            timestamp: 1
        ))
    }

    func fail() {
        isRunning = false
        failureHandler?("Middle-click reservation failed.")
    }
}

@MainActor
private final class MiddleClickPresenter: LayoutWheelPresenting {
    var openCount = 0
    var closeCount = 0
    var presentation: LayoutWheelPresentation?

    func open(_ presentation: LayoutWheelPresentation) {
        openCount += 1
        self.presentation = presentation
    }
    func update(_ presentation: LayoutWheelPresentation) { self.presentation = presentation }
    func showPlacements(_ placements: [Placement]) {}
    func hidePlacements() {}
    func close() { closeCount += 1 }
}

@Test @MainActor func middleClickUsesPressMoveReleaseAndCommitsOnce() {
    var configuration = BetterTileConfiguration()
    configuration.layoutWheel.middleClickTriggerEnabled = true
    let monitor = FakeMiddleClickMonitor()
    let presenter = MiddleClickPresenter()
    let controller = LayoutWheelController(
        configuration: configuration,
        presenter: presenter,
        addGlobalMonitor: { _, _ in NSObject() },
        removeMonitor: { _ in },
        middleClickMonitor: monitor
    )
    controller.captureHandler = { middleTarget }
    controller.previewHandler = { _, _ in .ready(placements: []) }
    var commits: [(LayoutWheelCommand, LayoutWheelTarget)] = []
    controller.commitHandler = { commits.append(($0, $1)) }
    controller.start()

    monitor.emit(.down, at: middleAnchor)
    #expect(controller.isOpen)
    monitor.emit(.dragged, at: BTPoint(x: middleAnchor.x, y: middleAnchor.y - 70))
    #expect(presenter.presentation?.selection == .init(ring: .inner, sector: .top))
    monitor.emit(.up, at: BTPoint(x: middleAnchor.x, y: middleAnchor.y - 70))
    monitor.emit(.up, at: BTPoint(x: middleAnchor.x, y: middleAnchor.y - 70))

    #expect(commits.count == 1)
    #expect(commits.first?.0 == .windowAction(.topHalf))
    #expect(commits.first?.1 == middleTarget)
    #expect(presenter.closeCount == 1)
}

@Test @MainActor func middleClickFailureCancelsItsGestureButLeavesKeyboardAvailable() {
    var configuration = BetterTileConfiguration()
    configuration.layoutWheel.middleClickTriggerEnabled = true
    let monitor = FakeMiddleClickMonitor()
    let controller = LayoutWheelController(
        configuration: configuration,
        presenter: MiddleClickPresenter(),
        addGlobalMonitor: { _, _ in NSObject() },
        removeMonitor: { _ in },
        middleClickMonitor: monitor
    )
    controller.captureHandler = { middleTarget }
    controller.previewHandler = { _, _ in .ready(placements: []) }
    var commits = 0
    controller.commitHandler = { _, _ in commits += 1 }
    controller.start()

    monitor.emit(.down, at: middleAnchor)
    #expect(controller.isOpen)
    monitor.fail()
    #expect(!controller.isOpen)
    #expect(commits == 0)

    controller.handleModifiers(middleKeyboardTrigger)
    controller.handleActivationDeadline(generation: 1)
    #expect(controller.isOpen)
}

@Test @MainActor func disablingMiddleClickStopsReservationAndRestoresOrdinaryClicks() {
    var configuration = BetterTileConfiguration()
    configuration.layoutWheel.middleClickTriggerEnabled = true
    let monitor = FakeMiddleClickMonitor()
    let controller = LayoutWheelController(
        configuration: configuration,
        presenter: MiddleClickPresenter(),
        addGlobalMonitor: { _, _ in NSObject() },
        removeMonitor: { _ in },
        middleClickMonitor: monitor
    )
    controller.start()
    #expect(monitor.isRunning)

    configuration.layoutWheel.middleClickTriggerEnabled = false
    controller.configuration = configuration

    #expect(!monitor.isRunning)
    #expect(monitor.stopCount > 0)
}

private final class MiddleClickWorkerLog: @unchecked Sendable {
    var canStart = false
    var starts = 0
    var stops = 0
    var handlers: [@Sendable (LayoutWheelMiddleClickTapMessage) -> Void] = []
}

private final class FakeMiddleClickWorker: LayoutWheelMiddleClickTapWorking {
    let log: MiddleClickWorkerLog
    init(log: MiddleClickWorkerLog) { self.log = log }
    func start() -> Bool {
        log.starts += 1
        return log.canStart
    }
    func stop() { log.stops += 1 }
}

@Test @MainActor func recoveryDefaultPreventsTheSuppressingTapFromStarting() {
    let log = MiddleClickWorkerLog()
    log.canStart = true
    let monitor = LayoutWheelMiddleClickMonitor(
        disabled: true,
        cooldown: 30,
        now: { 0 },
        makeWorker: { _ in FakeMiddleClickWorker(log: log) }
    )
    var failure: String?
    monitor.failureHandler = { failure = $0 }

    #expect(!monitor.start())
    #expect(log.starts == 0)
    #expect(failure?.contains("recovery setting") == true)
}

@Test @MainActor func failedTapRecoveryLeavesNoRunningReservation() async {
    let log = MiddleClickWorkerLog()
    log.canStart = true
    let monitor = LayoutWheelMiddleClickMonitor(
        disabled: false,
        cooldown: 30,
        now: { 0 },
        makeWorker: { handler in
            log.handlers.append(handler)
            return FakeMiddleClickWorker(log: log)
        }
    )
    #expect(monitor.start())

    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        monitor.failureHandler = { failure in
            if failure != nil { continuation.resume() }
        }
        log.handlers[0](.failed)
    }

    #expect(!monitor.isRunning)
    #expect(log.stops == 1)
}
