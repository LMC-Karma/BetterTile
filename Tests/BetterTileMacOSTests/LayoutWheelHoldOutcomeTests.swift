import AppKit
import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

@MainActor private final class HoldOutcomePresenter: LayoutWheelPresenting {
    var opens = 0
    func open(_ presentation: LayoutWheelPresentation) { opens += 1 }
    func update(_ presentation: LayoutWheelPresentation) {}
    func showPlacements(_ placements: [Placement]) {}
    func hidePlacements() {}
    func close() {}
}

@MainActor private final class HoldOutcomeHarness {
    let presenter = HoldOutcomePresenter()
    let controller: LayoutWheelController
    var messages: [String] = []
    static let trigger: ShortcutModifiers = [.control, .option, .shift]

    init(failingMonitor: String? = nil) {
        controller = LayoutWheelController(
            configuration: .init(), presenter: presenter,
            // Deadlines are delivered explicitly. No timer or wall-clock wait
            // can decide the result of these tests.
            activationDelay: .seconds(3600),
            pointerProvider: { BTPoint(x: 500, y: 400) },
            addGlobalMonitor: { mask, _ in
                if failingMonitor == "globalKey", mask == .keyDown { return nil }
                if failingMonitor == "pointer", mask.contains(.mouseMoved) { return nil }
                return NSObject()
            },
            addLocalMonitor: { mask, _ in
                if failingMonitor == "localKey", mask == .keyDown { return nil }
                return NSObject()
            }, removeMonitor: { _ in })
        controller.captureHandler = { _ in
            LayoutWheelTarget(displayID: .init(rawValue: "fake-display"),
                              visibleFrame: .init(x: 0, y: 0, width: 1200, height: 900))
        }
        controller.activationLogHandler = { [weak self] in self?.messages.append($0) }
        controller.start()
    }

    var outcomes: [String] { messages.filter { $0.hasPrefix("wheel hold outcome:") } }
    func begin() { controller.handleModifiers(Self.trigger) }
    func deadline(_ generation: Int = 1) { controller.handleActivationDeadline(generation: generation) }
}

@Test(.macOSTestApplication, arguments: ["applicationDeactivated", "focusedWindowChanged", "stopped", "suspended",
                  "configurationChanged", "requested", "pendingCancellation"]) @MainActor
func wheelHoldCancellationAlwaysRecordsOneOutcome(reason: String) {
    let h = HoldOutcomeHarness()
    defer { h.controller.stop() }
    h.begin()
    #expect(h.controller.isPendingActivation)
    switch reason {
    case "applicationDeactivated": h.controller.handleApplicationDeactivated()
    case "focusedWindowChanged": h.controller.handleFocusedWindowChanged()
    case "stopped": h.controller.stop()
    case "suspended": h.controller.suspend()
    case "configurationChanged": h.controller.configuration.layoutWheel.scale = 1.2
    case "pendingCancellation": h.controller.cancelPendingActivation()
    default: h.controller.cancel()
    }
    h.deadline() // An already queued deadline must not produce another outcome.
    #expect(!h.controller.isPendingActivation)
    #expect(h.presenter.opens == 0)
    #expect(h.outcomes.count == 1, "Activation messages: \(h.messages)")
    #expect(h.outcomes.first?.contains("outcome=cancel") == true)
    #expect(h.outcomes.first?.contains("reason=\(reason)") == true)
}

@Test(.macOSTestApplication, arguments: ["globalKey", "localKey"]) @MainActor
func wheelHoldKeyMonitorFailureRecordsOneOutcome(failingMonitor: String) {
    let h = HoldOutcomeHarness(failingMonitor: failingMonitor)
    defer { h.controller.stop() }
    h.begin()
    h.deadline()
    #expect(!h.controller.isPendingActivation)
    #expect(h.presenter.opens == 0)
    #expect(h.outcomes.count == 1, "Activation messages: \(h.messages)")
    #expect(h.outcomes.first?.contains("outcome=skip reason=keyMonitoringFailed") == true)
    #expect(!h.messages.contains { $0.hasPrefix("wheel activation task scheduled") })
    #expect(!h.messages.contains { $0.hasPrefix("wheel activation deadline fired") })
}


@Test(.macOSTestApplication) @MainActor func wheelHoldEarlyReleaseAndDuplicateCancellationHaveOneOutcome() {
    let h = HoldOutcomeHarness()
    defer { h.controller.stop() }
    h.begin()
    h.controller.handleModifiers([])
    h.controller.cancel()
    h.controller.handleApplicationDeactivated()
    h.deadline()
    #expect(h.presenter.opens == 0)
    #expect(h.outcomes.count == 1)
    #expect(h.outcomes.first?.contains("outcome=cancel reason=triggerReleased") == true)
}

@Test(.macOSTestApplication) @MainActor func wheelHoldOrdinaryLocalKeyRecordsReasonWithoutKeyData() throws {
    var key: (@MainActor (LayoutWheelInput) -> Bool)?
    var messages: [String] = []
    let presenter = HoldOutcomePresenter()
    let controller = LayoutWheelController(
        configuration: .init(), presenter: presenter, activationDelay: .seconds(3600),
        addGlobalMonitor: { _, _ in NSObject() },
        addLocalMonitor: { mask, handler in
            if mask == .keyDown { key = handler }
            return NSObject()
        }, removeMonitor: { _ in })
    controller.activationLogHandler = { messages.append($0) }
    controller.start()
    defer { controller.stop() }
    controller.handleModifiers(HoldOutcomeHarness.trigger)
    let handler = try #require(key)
    #expect(!handler(.init(keyCode: 17, modifiers: HoldOutcomeHarness.trigger)))
    controller.handleActivationDeadline(generation: 1)
    #expect(presenter.opens == 0)
    let outcomes = messages.filter { $0.hasPrefix("wheel hold outcome:") }
    #expect(outcomes.count == 1)
    #expect(outcomes.first?.contains("outcome=cancel reason=ordinaryKey") == true)
    #expect(!messages.joined().contains("keyCode"))
}

@Test(.macOSTestApplication, arguments: ["applicationActivated", "shortcut", "displayChanged", "spaceChanged", "waking",
                  "permissionUnavailable", "shortcutRecording"]) @MainActor
func wheelHoldModelCancellationReasonsStayDistinct(reason: String) throws {
    let h = HoldOutcomeHarness()
    defer { h.controller.stop() }
    let cancellation = try #require(LayoutWheelController.CancellationReason(rawValue: reason))
    h.begin()
    if reason == "permissionUnavailable" || reason == "shortcutRecording" {
        h.controller.suspend(reason: cancellation)
    } else {
        h.controller.cancel(reason: cancellation)
    }
    h.deadline()
    #expect(h.presenter.opens == 0)
    #expect(h.outcomes.count == 1)
    #expect(h.outcomes.first?.contains("outcome=cancel reason=\(reason)") == true)
}

@Test(.macOSTestApplication) @MainActor func wheelHoldNoTargetAndPointerMonitorFailureRecordSkip() {
    for reason in ["noEligibleTarget", "pointerMonitoringFailed"] {
        let h = HoldOutcomeHarness(failingMonitor: reason == "pointerMonitoringFailed" ? "pointer" : nil)
        defer { h.controller.stop() }
        if reason == "noEligibleTarget" { h.controller.captureHandler = { _ in nil } }
        h.begin()
        h.deadline()
        h.deadline()
        h.controller.cancel()
        #expect(!h.controller.isOpen)
        #expect(h.presenter.opens == 0)
        #expect(h.outcomes.count == 1)
        #expect(h.outcomes.first?.contains("outcome=skip reason=\(reason)") == true)
        #expect(h.messages.contains { $0.hasPrefix("wheel activation deadline fired") })
    }
}

@Test(.macOSTestApplication) @MainActor func wheelHoldRepeatedStartAndStaleDeadlineCannotResolveTheNextHold() {
    let h = HoldOutcomeHarness()
    defer { h.controller.stop() }
    h.begin()
    h.begin() // Reentrant/repeated matching flags do not replace the task.
    h.controller.cancel()
    h.controller.handleModifiers([])
    h.begin()
    h.deadline(1) // The cancelled generation is queued behind the new hold.
    #expect(h.controller.isPendingActivation)
    #expect(h.outcomes.count == 1)
    h.deadline(2)
    #expect(h.controller.isOpen)
    #expect(h.presenter.opens == 1)
    h.deadline(2)
    h.controller.cancel()
    #expect(h.outcomes.count == 2)
    #expect(h.outcomes[0].contains("hold=1 outcome=cancel"))
    #expect(h.outcomes[1].contains("hold=2 outcome=open"))
    #expect(h.messages.filter { $0.hasPrefix("wheel hold started") }.count == 2)
    #expect(h.messages.contains("wheel activation deadline ignored: hold=1 current=2"))
}

@Test(.macOSTestApplication) @MainActor func wheelHoldControllerReleaseRecordsCancellation() {
    var messages: [String] = []
    var controller: LayoutWheelController? = LayoutWheelController(
        configuration: .init(), presenter: HoldOutcomePresenter(), activationDelay: .seconds(3600),
        addGlobalMonitor: { _, _ in NSObject() },
        addLocalMonitor: { _, _ in NSObject() }, removeMonitor: { _ in })
    controller?.activationLogHandler = { messages.append($0) }
    controller?.start()
    controller?.handleModifiers(HoldOutcomeHarness.trigger)
    weak let released = controller
    controller = nil
    #expect(released == nil)
    let outcomes = messages.filter { $0.hasPrefix("wheel hold outcome:") }
    #expect(outcomes.count == 1)
    #expect(outcomes.first?.contains("outcome=cancel reason=controllerReleased") == true)
}

/// SECURITY.md: activation diagnostics hold no event content. A selection
/// or a pointer distance is derived from the pointer, so neither is logged.
@Test(.macOSTestApplication, arguments: [LayoutWheelStyle.custom, .grouped]) @MainActor
func wheelDiagnosticsOmitTheSelectionAndPointerDistance(style: LayoutWheelStyle) {
    var pointer = BTPoint(x: 500, y: 400)
    var messages: [String] = []
    var commits: [LayoutWheelCommand] = []
    let controller = LayoutWheelController(
        configuration: .init(layoutWheel: .init(style: style, levelCount: .two)), presenter: HoldOutcomePresenter(),
        activationDelay: .seconds(3600), pointerProvider: { pointer },
        addGlobalMonitor: { _, _ in NSObject() }, addLocalMonitor: { _, _ in NSObject() }, removeMonitor: { _ in })
    controller.captureHandler = { _ in
        LayoutWheelTarget(windowID: .init(rawValue: "fixture"), displayID: .init(rawValue: "fake-display"),
                          visibleFrame: .init(x: 0, y: 0, width: 1200, height: 900))
    }
    controller.previewHandler = { _, _ in .ready(placements: []) }
    controller.commitHandler = { command, _ in commits.append(command) }
    controller.activationLogHandler = { messages.append($0) }
    controller.start()
    defer { controller.stop() }
    controller.handleModifiers(HoldOutcomeHarness.trigger)
    controller.handleActivationDeadline(generation: 1)
    #expect(controller.isOpen)
    for _ in 1...12 {
        pointer.x += 10
        controller.handlePointer(pointer)
    }
    controller.handleModifiers([.control, .option])
    #expect(commits.count == 1)
    #expect(messages.contains { $0.hasPrefix("wheel release: commit") })
    for message in messages {
        #expect(!message.contains("selection"), "\(message)")
        #expect(!message.contains("Distance") && !message.contains(" pt"), "\(message)")
        #expect(!message.contains("outer/") && !message.contains("inner/"), "\(message)")
    }
}

/// Target capture receives the point the wheel opens at, so a fake pointer
/// decides the target display without reading the live pointer.
@Test(.macOSTestApplication) @MainActor func wheelTargetCaptureReceivesTheOpeningPointer() {
    let pointer = BTPoint(x: -50_000, y: -100)
    var captured: [BTPoint] = []
    let presenter = HoldOutcomePresenter()
    let controller = LayoutWheelController(
        configuration: .init(), presenter: presenter, activationDelay: .seconds(3600), pointerProvider: { pointer },
        addGlobalMonitor: { _, _ in NSObject() }, addLocalMonitor: { _, _ in NSObject() }, removeMonitor: { _ in })
    controller.captureHandler = { point in
        captured.append(point)
        return LayoutWheelTarget(displayID: .init(rawValue: "fake-display"),
                                 visibleFrame: .init(x: -51_600, y: -200, width: 1600, height: 1000))
    }
    controller.start()
    defer { controller.stop() }
    controller.handleModifiers(HoldOutcomeHarness.trigger)
    controller.handleActivationDeadline(generation: 1)
    #expect(controller.isOpen && presenter.opens == 1)
    #expect(captured == [pointer])
}
