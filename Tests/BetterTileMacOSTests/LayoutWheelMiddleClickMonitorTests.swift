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
private let middleInnerSelectionOffset =
    (LayoutWheelMetrics.standard.geometry.hubRadius
        + LayoutWheelMetrics.standard.geometry.innerRingOuterRadius) / 2

@Test(.macOSTestApplication) func onlyUnmodifiedPhysicalButtonTwoIsReserved() {
    #expect(LayoutWheelMiddleClickEvent.reserves(button: 2, modifiers: []))
    #expect(!LayoutWheelMiddleClickEvent.reserves(button: 0, modifiers: []))
    #expect(!LayoutWheelMiddleClickEvent.reserves(button: 1, modifiers: []))
    #expect(!LayoutWheelMiddleClickEvent.reserves(button: 3, modifiers: []))
    #expect(!LayoutWheelMiddleClickEvent.reserves(button: 2, modifiers: [.command]))
    #expect(!LayoutWheelMiddleClickEvent.reserves(button: 2, modifiers: [.control, .option]))
}

@Test(.macOSTestApplication) func reservationOwnsTheWholeClickEvenIfModifiersChange() {
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

@Test(.macOSTestApplication) func modifiedMiddleClickNeverBecomesReserved() {
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
    var trigger = LayoutWheelTriggers.Mouse.middleClick
    var acceptsNewGesture = true
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

@Test(.macOSTestApplication) @MainActor func middleClickUsesPressMoveReleaseAndCommitsOnce() {
    var configuration = BetterTileConfiguration()
    configuration.layoutWheel.middleClickTriggerEnabled = true
    let monitor = FakeMiddleClickMonitor()
    let presenter = MiddleClickPresenter()
    let controller = LayoutWheelController(
        configuration: configuration,
        presenter: presenter,
        addGlobalMonitor: { _, _ in NSObject() },
        addLocalMonitor: { _, _ in NSObject() },
        removeMonitor: { _ in },
        middleClickMonitor: monitor
    )
    controller.captureHandler = { _ in middleTarget }
    controller.previewHandler = { _, _ in .ready(placements: []) }
    var commits: [(LayoutWheelCommand, LayoutWheelTarget)] = []
    controller.commitHandler = { commits.append(($0, $1)) }
    controller.start()

    monitor.emit(.down, at: middleAnchor)
    #expect(controller.isOpen)
    monitor.emit(.dragged, at: BTPoint(x: middleAnchor.x, y: middleAnchor.y - middleInnerSelectionOffset))
    #expect(presenter.presentation?.selection == .init(ring: .inner, sector: .top))
    monitor.emit(.up, at: BTPoint(x: middleAnchor.x, y: middleAnchor.y - middleInnerSelectionOffset))
    monitor.emit(.up, at: BTPoint(x: middleAnchor.x, y: middleAnchor.y - middleInnerSelectionOffset))

    #expect(commits.count == 1)
    #expect(commits.first?.0 == .windowAction(.topHalf))
    #expect(commits.first?.1 == middleTarget)
    #expect(presenter.closeCount == 1)
}

@Test(.macOSTestApplication) @MainActor func middleClickFailureCancelsItsGestureButLeavesKeyboardAvailable() {
    var configuration = BetterTileConfiguration()
    configuration.layoutWheel.middleClickTriggerEnabled = true
    let monitor = FakeMiddleClickMonitor()
    let controller = LayoutWheelController(
        configuration: configuration,
        presenter: MiddleClickPresenter(),
        addGlobalMonitor: { _, _ in NSObject() },
        addLocalMonitor: { _, _ in NSObject() },
        removeMonitor: { _ in },
        middleClickMonitor: monitor
    )
    controller.captureHandler = { _ in middleTarget }
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

@Test(.macOSTestApplication) @MainActor func disablingMiddleClickStopsReservationAndRestoresOrdinaryClicks() {
    var configuration = BetterTileConfiguration()
    configuration.layoutWheel.middleClickTriggerEnabled = true
    let monitor = FakeMiddleClickMonitor()
    let controller = LayoutWheelController(
        configuration: configuration,
        presenter: MiddleClickPresenter(),
        addGlobalMonitor: { _, _ in NSObject() },
        addLocalMonitor: { _, _ in NSObject() },
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
    var acceptsNewGesture = true
    let log: MiddleClickWorkerLog
    init(log: MiddleClickWorkerLog) { self.log = log }
    func start() -> Bool {
        log.starts += 1
        return log.canStart
    }
    func stop() { log.stops += 1 }
}

@Test(.macOSTestApplication) @MainActor func recoveryDefaultPreventsTheSuppressingTapFromStarting() {
    let log = MiddleClickWorkerLog()
    log.canStart = true
    let monitor = LayoutWheelMiddleClickMonitor(
        disabled: true,
        cooldown: 30,
        now: { 0 },
        makeWorker: { _, _ in FakeMiddleClickWorker(log: log) }
    )
    var failure: String?
    monitor.failureHandler = { failure = $0 }

    #expect(!monitor.start())
    #expect(log.starts == 0)
    #expect(failure?.contains("recovery setting") == true)
}

@Test(.macOSTestApplication) @MainActor func failedTapRecoveryLeavesNoRunningReservation() async {
    let log = MiddleClickWorkerLog()
    log.canStart = true
    let monitor = LayoutWheelMiddleClickMonitor(
        disabled: false,
        cooldown: 30,
        now: { 0 },
        makeWorker: { _, handler in
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

@MainActor private final class GroupedMiddleClickClock { var time: TimeInterval = 100 }

@Test(.macOSTestApplication, arguments: [LayoutWheelSector.top, .bottomRight]) @MainActor
func groupedMiddleClickStationaryReleaseDoesNotAcquireRevealedOption(_ sector: LayoutWheelSector) {
    var configuration = BetterTileConfiguration()
    configuration.layoutWheel.style = .grouped
    configuration.layoutWheel.middleClickTriggerEnabled = true
    let monitor = FakeMiddleClickMonitor()
    let presenter = MiddleClickPresenter()
    let clock = GroupedMiddleClickClock()
    let controller = LayoutWheelController(configuration: configuration, presenter: presenter,
        now: { clock.time }, addGlobalMonitor: { _, _ in NSObject() },
        addLocalMonitor: { _, _ in NSObject() }, removeMonitor: { _ in }, middleClickMonitor: monitor)
    controller.captureHandler = { _ in middleTarget }
    controller.previewHandler = { _, _ in .ready(placements: []) }
    var commits: [LayoutWheelCommand] = []
    controller.commitHandler = { command, _ in commits.append(command) }
    controller.start()
    defer { controller.stop() }
    monitor.emit(.down, at: middleAnchor)
    let angle = Double(sector.rawValue) * .pi / 4
    let resting = BTPoint(x: middleAnchor.x + sin(angle) * 197, y: middleAnchor.y - cos(angle) * 197)
    monitor.emit(.dragged, at: resting)
    clock.time = 100.2
    controller.handleFanDeadline()
    #expect(presenter.presentation?.fan.openSector == sector)
    #expect(presenter.presentation?.fan.optionIndex == nil)
    monitor.emit(.up, at: resting)
    monitor.emit(.up, at: resting)
    #expect(commits == LayoutWheelGroup.at(sector).quickAction.map { [$0] } ?? [])
    #expect(!controller.isOpen)
}

@Test(.macOSTestApplication) @MainActor func changingMousePredicateRetiresQueuedEventsAndPreservesTheKeyboardGate() async {
    let log = MiddleClickWorkerLog()
    log.canStart = true
    var selected: [LayoutWheelTriggers.Mouse] = []
    var workers: [FakeMiddleClickWorker] = []
    let monitor = LayoutWheelMiddleClickMonitor(disabled: false, cooldown: 0, now: { 0 },
        makeWorker: { trigger, handler in
            selected.append(trigger)
            log.handlers.append(handler)
            let worker = FakeMiddleClickWorker(log: log)
            workers.append(worker)
            return worker
        })
    monitor.trigger = .optionMiddleClick
    monitor.acceptsNewGesture = false
    var received = 0
    monitor.eventHandler = { _ in received += 1 }
    #expect(monitor.start())
    #expect(selected == [.optionMiddleClick])
    #expect(!workers[0].acceptsNewGesture)
    monitor.acceptsNewGesture = true
    #expect(workers[0].acceptsNewGesture)
    monitor.trigger = .middleClick
    #expect(!monitor.isRunning)
    #expect(monitor.start())
    #expect(selected == [.optionMiddleClick, .middleClick])
    let event = LayoutWheelMiddleClickEvent(kind: .down, position: middleAnchor, button: 2,
                                          modifiers: [], timestamp: 1)
    log.handlers[0](.event(event))
    log.handlers[1](.event(event))
    await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    #expect(received == 1)
    log.handlers[1](.failed)
    log.handlers[1](.event(event))
    await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    #expect(!monitor.isRunning)
    #expect(received == 1)
    monitor.stop()
}

private final class MiddleClickRecoveryLog: @unchecked Sendable {
    var failures = 0
    var recoveries = 0
}

@Test(.macOSTestApplication, arguments: [CGEventType.tapDisabledByTimeout, .tapDisabledByUserInput], [false, true])
func disabledMiddleTapRecoversOnlyOutsideAnOwnedGesture(type: CGEventType, ownsGesture: Bool) throws {
    let log = MiddleClickRecoveryLog()
    let worker = LayoutWheelMiddleClickTapWorker(reenableTap: { _ in
        log.recoveries += 1
        return true
    }, handler: { if case .failed = $0 { log.failures += 1 } })
    let event = try #require(CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown,
                                             mouseCursorPosition: .zero, mouseButton: .center))
    event.setIntegerValueField(.mouseEventButtonNumber, value: 2)
    event.flags = []
    if ownsGesture { #expect(worker.handle(type: .otherMouseDown, event: event)) }
    #expect(!worker.handle(type: type, event: event))
    #expect(log.recoveries == (ownsGesture ? 0 : 1))
    #expect(log.failures == (ownsGesture ? 1 : 0))
}

@Test(.macOSTestApplication) func failedMiddleTapReenableReportsFailure() throws {
    let log = MiddleClickRecoveryLog()
    let worker = LayoutWheelMiddleClickTapWorker(reenableTap: { _ in
        log.recoveries += 1
        return false
    }, handler: { if case .failed = $0 { log.failures += 1 } })
    #expect(!worker.handle(type: .tapDisabledByTimeout, event: try #require(CGEvent(source: nil))))
    #expect(log.recoveries == 1)
    #expect(log.failures == 1)
}

@Test(.macOSTestApplication) func middleTapRecoversAfterTheOwnedButtonWasReleased() throws {
    let log = MiddleClickRecoveryLog()
    let worker = LayoutWheelMiddleClickTapWorker(reenableTap: { _ in
        log.recoveries += 1
        return true
    }, handler: { if case .failed = $0 { log.failures += 1 } })
    let event = try #require(CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown,
                                             mouseCursorPosition: .zero, mouseButton: .center))
    event.setIntegerValueField(.mouseEventButtonNumber, value: 2)
    event.flags = []
    #expect(worker.handle(type: .otherMouseDown, event: event))
    #expect(worker.handle(type: .otherMouseUp, event: event))
    #expect(!worker.handle(type: .tapDisabledByTimeout, event: event))
    #expect(log.recoveries == 1)
    #expect(log.failures == 0)
}
