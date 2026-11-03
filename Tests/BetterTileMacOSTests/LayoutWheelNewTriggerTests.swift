import AppKit
import BetterTileCore
import IOKit.hidsystem
import Testing
@testable import BetterTileMacOS

@MainActor private final class NewTriggerMouse: LayoutWheelMiddleClickMonitoring {
    var eventHandler: ((LayoutWheelMiddleClickEvent) -> Void)?
    var failureHandler: ((String?) -> Void)?
    var isRunning = false
    var trigger = LayoutWheelTriggers.Mouse.off
    var acceptsNewGesture = true
    func start() -> Bool { isRunning = true; return true }
    func stop() { isRunning = false }
    func send(_ kind: LayoutWheelMiddleClickEventKind, modifiers: ShortcutModifiers = .option) {
        eventHandler?(.init(kind: kind, position: .init(x: 800, y: kind == .down ? 500 : 450),
                            button: 2, modifiers: modifiers, timestamp: 1))
    }
}

@MainActor private final class NewTriggerPresenter: LayoutWheelPresenting {
    var opens = 0
    var prepares = 0
    var discardedPreparations = 0
    func prepareToOpen(configuration: LayoutWheelConfiguration, appearance: OverlayAppearance) { prepares += 1 }
    func discardPreparation() { discardedPreparations += 1 }
    func open(_ presentation: LayoutWheelPresentation) { opens += 1 }
    func update(_ presentation: LayoutWheelPresentation) {}
    func showPlacements(_ placements: [Placement]) {}
    func hidePlacements() {}
    func close() {}
}

@MainActor private final class NewTriggerHarness {
    let mouse = NewTriggerMouse()
    let presenter = NewTriggerPresenter()
    var controller: LayoutWheelController!
    var local: [UInt64: @MainActor (LayoutWheelInput) -> Bool] = [:]
    var global: [UInt64: (NSEvent) -> Void] = [:]
    var currentFlags: UInt?
    var commits: [LayoutWheelCommand] = []
    var pointer = BTPoint(x: 800, y: 500)
    /// One value per global key or modifier event, sent after the controller has handled it.
    private let handled: AsyncStream<Void>
    init(keyboard: LayoutWheelTriggers.Keyboard = .rightControl, currentFlags: UInt? = nil) {
        self.currentFlags = currentFlags
        let (handledEvents, markHandled) = AsyncStream.makeStream(of: Void.self)
        handled = handledEvents
        controller = LayoutWheelController(
            configuration: .init(layoutWheel: .init(triggers: .init(keyboard: keyboard, mouse: .optionMiddleClick))),
            presenter: presenter, activationDelay: .seconds(3600), pointerProvider: { [unowned self] in pointer },
            addGlobalMonitor: { [unowned self] mask, handler in global[mask.rawValue] = handler; return NSObject() },
            addLocalMonitor: { [unowned self] mask, handler in local[mask.rawValue] = handler; return NSObject() },
            removeMonitor: { _ in }, modifierFlagsProvider: { [unowned self] in self.currentFlags }, middleClickMonitor: mouse)
        controller.captureHandler = { _ in .init(windowID: .init(rawValue: "fixture"), displayID: .init(rawValue: "display"),
                                           visibleFrame: .init(x: 0, y: 0, width: 1600, height: 1000)) }
        controller.previewHandler = { _, _ in .ready(placements: []) }
        controller.commitHandler = { [unowned self] command, _ in commits.append(command) }
        controller.globalInputHandledForTesting = { markHandled.yield() }
        controller.start()
    }
    func point() { pointer.y = 450; controller.handlePointer(pointer) }
    func send(_ flags: NSEvent.ModifierFlags, code: UInt16 = 0x3E, globalMonitor: Bool = false) async throws {
        let event = try #require(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags,
            timestamp: 1, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: code))
        if globalMonitor {
            let handler = try #require(global[NSEvent.EventTypeMask.flagsChanged.rawValue])
            handler(event)
            // The monitor queues a main-actor task. Wait until it has handled the event.
            var events = handled.makeAsyncIterator()
            await events.next()
        } else {
            let handler = try #require(local[NSEvent.EventTypeMask.flagsChanged.rawValue])
            _ = handler(LayoutWheelController.localMonitorInput(for: event))
        }
    }
    static var right: NSEvent.ModifierFlags { .init(rawValue: NSEvent.ModifierFlags.control.rawValue | UInt(NX_DEVICERCTLKEYMASK)) }
}

@Suite(.macOSTestApplication) struct LayoutWheelNewTriggerTests {
    @Test(arguments: [false, true]) @MainActor
    func rightControlUsesSideBitsThroughBothMonitors(global: Bool) async throws {
        let h = NewTriggerHarness(); defer { h.controller.stop() }
        try await h.send(NewTriggerHarness.right, globalMonitor: global)
        #expect(h.controller.isPendingActivation)
        try await h.send(NewTriggerHarness.right, globalMonitor: global)
        h.controller.handleActivationDeadline(generation: 1)
        #expect(h.controller.isOpen)
        #expect(!h.mouse.acceptsNewGesture)
        h.point()
        try await h.send([], globalMonitor: global)
        try await h.send([], globalMonitor: global)
        #expect(h.commits == [.windowAction(.topHalf)])
        #expect(h.presenter.opens == 1)
    }

    @Test(arguments: [false, true], [false, true]) @MainActor
    func rightControlMouseDownCancelsPendingAndOpen(global: Bool, open: Bool) async throws {
        for type in [NSEvent.EventType.leftMouseDown, .rightMouseDown] {
            let h = NewTriggerHarness(); defer { h.controller.stop() }
            try await h.send(NewTriggerHarness.right)
            if open { h.controller.handleActivationDeadline(generation: 1); h.point() }
            let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
            let event = try #require(NSEvent.mouseEvent(with: type, location: .zero,
                modifierFlags: NewTriggerHarness.right, timestamp: 1, windowNumber: 0,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            if global {
                let handler = try #require(h.global[mask.rawValue])
                handler(event)
                for _ in 0..<20 { await Task.yield() }
            } else {
                let handler = try #require(h.local[mask.rawValue])
                #expect(!handler(LayoutWheelController.localMonitorInput(for: event)))
            }
            #expect(!h.controller.isOpen && !h.controller.isPendingActivation)
            #expect(h.presenter.prepares == 1)
            #expect(h.presenter.discardedPreparations == (open ? 0 : 1))
            try await h.send(NewTriggerHarness.right)
            #expect(!h.controller.isPendingActivation)
            h.controller.handleActivationDeadline(generation: 1)
            try await h.send([])
            #expect(h.commits.isEmpty)
        }
    }

    @Test(arguments: ["left", "ambiguous", "both", "extra", "function", "wrongKeyCode"]) @MainActor
    func invalidSideIdentityCannotOpenOrFallBackToEitherControl(kind: String) async throws {
        let h = NewTriggerHarness(); defer { h.controller.stop() }
        var flags = NewTriggerHarness.right
        var code: UInt16 = 0x3E
        switch kind {
        case "left": flags = .init(rawValue: NSEvent.ModifierFlags.control.rawValue | UInt(NX_DEVICELCTLKEYMASK)); code = 0x3B
        case "ambiguous": flags = .control
        case "both": flags.insert(.init(rawValue: UInt(NX_DEVICELCTLKEYMASK)))
        case "extra": flags.insert(.shift)
        case "function": flags.insert(.function)
        default: code = 0x3B
        }
        try await h.send(flags, code: code)
        h.controller.handleActivationDeadline(generation: 1)
        #expect(!h.controller.isOpen && !h.controller.isPendingActivation)
        try await h.send(NewTriggerHarness.right)
        #expect(!h.controller.isPendingActivation)
        try await h.send([])
        try await h.send(NewTriggerHarness.right)
        h.controller.handleActivationDeadline(generation: 1)
        #expect(h.controller.isOpen)
    }

    @Test(arguments: ["left", "missingSide", "unknownRelease", "ordinaryKey"]) @MainActor
    func contaminatedOrUnknownRightReleaseCancels(kind: String) async throws {
        let h = NewTriggerHarness(); defer { h.controller.stop() }
        try await h.send(NewTriggerHarness.right)
        h.controller.handleActivationDeadline(generation: 1); h.point()
        switch kind {
        case "left": try await h.send(NewTriggerHarness.right.union(.init(rawValue: UInt(NX_DEVICELCTLKEYMASK))), code: 0x3B)
        case "missingSide": try await h.send(.control)
        case "unknownRelease": try await h.send([], code: 0)
        default:
            let handler = try #require(h.local[NSEvent.EventTypeMask.keyDown.rawValue])
            _ = handler(.init(keyCode: 0, modifiers: .control))
        }
        #expect(!h.controller.isOpen)
        try await h.send([])
        #expect(h.commits.isEmpty)
    }

    @Test @MainActor func deadlineRejectsAReleaseThatNeverReachedTheMonitor() async throws {
        let h = NewTriggerHarness(currentFlags: 0); defer { h.controller.stop() }
        h.currentFlags = NewTriggerHarness.right.rawValue
        try await h.send(NewTriggerHarness.right)
        h.currentFlags = 0
        h.controller.handleActivationDeadline(generation: 1)
        #expect(!h.controller.isOpen && !h.controller.isPendingActivation)
        #expect(h.presenter.opens == 0)
    }

    @Test(arguments: [false, true]) @MainActor
    func rightControlReleaseCommitsWhileAnArrowKeyIsHeldThroughBothMonitors(global: Bool) async throws {
        let h = NewTriggerHarness(); defer { h.controller.stop() }
        try await h.send(NewTriggerHarness.right, globalMonitor: global)
        h.controller.handleActivationDeadline(generation: 1); h.point()
        try await h.send(.function, code: 0x3E, globalMonitor: global)
        #expect(!h.controller.isOpen)
        #expect(h.commits.count == 1)
    }

    @Test(arguments: [false, true]) @MainActor
    func physicalFunctionKeyCancelsARightControlWheelWhileAnArrowKeyIsHeld(global: Bool) async throws {
        let h = NewTriggerHarness(); defer { h.controller.stop() }
        try await h.send(NewTriggerHarness.right, globalMonitor: global)
        h.controller.handleActivationDeadline(generation: 1); h.point()
        #expect(h.controller.isOpen)
        // The Fn key's own event carries its key code, so it still counts as Fn.
        try await h.send(NewTriggerHarness.right.union(.function), code: 0x3F, globalMonitor: global)
        #expect(!h.controller.isOpen)
        #expect(h.commits.isEmpty)
        // The later Right Control release, with the arrow still down, commits nothing.
        try await h.send(.function, code: 0x3E, globalMonitor: global)
        #expect(h.commits.isEmpty)
    }

    @Test(arguments: [false, true]) @MainActor
    func anUnrelatedFlagChangeWhileRightControlIsHeldDoesNotCommit(global: Bool) async throws {
        let h = NewTriggerHarness(); defer { h.controller.stop() }
        try await h.send(NewTriggerHarness.right, globalMonitor: global)
        h.controller.handleActivationDeadline(generation: 1); h.point()
        // A flag change with another key code while an arrow key holds the function flag.
        try await h.send(NewTriggerHarness.right.union(.function), code: 57, globalMonitor: global)
        #expect(h.controller.isOpen && h.commits.isEmpty)
        // The arrow comes up; Right Control is still down.
        try await h.send(NewTriggerHarness.right, code: 57, globalMonitor: global)
        #expect(h.controller.isOpen && h.commits.isEmpty)
        try await h.send([], globalMonitor: global)
        #expect(!h.controller.isOpen)
        #expect(h.commits.count == 1)
    }

    @Test @MainActor func restartingWhileRightControlIsHeldRequiresNeutralFirst() async throws {
        let h = NewTriggerHarness(currentFlags: NewTriggerHarness.right.rawValue); defer { h.controller.stop() }
        try await h.send(NewTriggerHarness.right)
        #expect(!h.controller.isPendingActivation)
        h.currentFlags = 0; try await h.send([])
        h.currentFlags = NewTriggerHarness.right.rawValue; try await h.send(NewTriggerHarness.right)
        h.controller.handleActivationDeadline(generation: 1)
        #expect(h.controller.isOpen)
        h.controller.stop(); h.controller.start()
        try await h.send(NewTriggerHarness.right)
        #expect(!h.controller.isPendingActivation)
    }

    @Test(arguments: [LayoutWheelTriggers.Keyboard.modifiers, .rightControl]) @MainActor
    func keyboardAndMouseCannotOwnCompetingSessions(keyboard: LayoutWheelTriggers.Keyboard) async throws {
        let h = NewTriggerHarness(keyboard: keyboard); defer { h.controller.stop() }
        let flags: NSEvent.ModifierFlags = keyboard == .rightControl ? NewTriggerHarness.right : [.control, .option, .shift]
        try await h.send(flags)
        #expect(!h.mouse.acceptsNewGesture)
        h.mouse.send(.down)
        #expect(h.controller.isPendingActivation && !h.controller.isOpen)
        h.controller.handleActivationDeadline(generation: 1)
        #expect(h.controller.isOpen)
        h.controller.cancel(); try await h.send([])
        #expect(h.mouse.acceptsNewGesture)
        h.mouse.send(.down)
        #expect(h.controller.isOpen)
        try await h.send(flags)
        h.mouse.send(.dragged, modifiers: [])
        h.controller.handleKey(.commit)
        #expect(h.commits.isEmpty && h.controller.isOpen)
        try await h.send([])
        #expect(h.controller.isOpen)
        h.mouse.send(.up, modifiers: [])
        h.mouse.send(.up, modifiers: [])
        #expect(h.commits == [.windowAction(.topHalf)])
    }

    @Test @MainActor func aCancelledMouseGestureKeepsOwnershipUntilItsUp() async throws {
        let h = NewTriggerHarness(); defer { h.controller.stop() }
        #expect(h.mouse.trigger == .optionMiddleClick)
        h.mouse.send(.down); h.controller.cancel()
        #expect(!h.mouse.acceptsNewGesture)
        try await h.send(NewTriggerHarness.right)
        #expect(!h.controller.isPendingActivation)
        try await h.send([])
        h.mouse.send(.up, modifiers: [])
        #expect(h.mouse.acceptsNewGesture)
        try await h.send(NewTriggerHarness.right)
        #expect(h.controller.isPendingActivation)
        #expect(h.commits.isEmpty)
    }

    @Test @MainActor func aTriggerChangeRetiresQueuedModifierEvents() async throws {
        let h = NewTriggerHarness(); defer { h.controller.stop() }
        let stale = try #require(h.global[NSEvent.EventTypeMask.flagsChanged.rawValue])
        let event = try #require(NSEvent.keyEvent(with: .flagsChanged, location: .zero,
            modifierFlags: NewTriggerHarness.right, timestamp: 1, windowNumber: 0, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 0x3E))
        stale(event)
        h.controller.configuration.layoutWheel.triggers.mouse = .middleClick
        for _ in 0..<20 { await Task.yield() }
        #expect(!h.controller.isPendingActivation)
        h.controller.handleActivationDeadline(generation: 1)
        #expect(h.presenter.opens == 0)
    }

    @Test @MainActor func aMissingModifierMonitorCannotOpenRightControl() {
        let presenter = NewTriggerPresenter()
        let controller = LayoutWheelController(
            configuration: .init(layoutWheel: .init(triggers: .init(keyboard: .rightControl))),
            presenter: presenter, addGlobalMonitor: { _, _ in nil },
            addLocalMonitor: { _, _ in NSObject() }, removeMonitor: { _ in })
        controller.captureHandler = { _ in .init(displayID: .init(rawValue: "fixture"), visibleFrame: .init(x: 0, y: 0, width: 1000, height: 800)) }
        controller.start(); defer { controller.stop() }
        controller.handleModifierInput(.init(keyCode: 0x3E, flags: NewTriggerHarness.right))
        controller.handleActivationDeadline(generation: 1)
        #expect(!controller.isPendingActivation)
        #expect(presenter.opens == 0)
    }

    @Test(arguments: [false, true]) @MainActor
    func rightControlRequiresBothMouseDownMonitors(missingLocal: Bool) {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        var removedMouseMonitor = false
        let controller = LayoutWheelController(
            configuration: .init(layoutWheel: .init(triggers: .init(keyboard: .rightControl))),
            presenter: NewTriggerPresenter(),
            addGlobalMonitor: { requested, _ in
                if requested == mask { return missingLocal ? "mouse" : nil }
                return NSObject()
            },
            addLocalMonitor: { requested, _ in
                if requested == mask { return missingLocal ? nil : "mouse" }
                return NSObject()
            },
            removeMonitor: { if ($0 as? String) == "mouse" { removedMouseMonitor = true } })
        controller.start(); defer { controller.stop() }
        controller.handleModifierInput(.init(keyCode: 0x3E, flags: NewTriggerHarness.right))
        #expect(!controller.isPendingActivation && !controller.isOpen)
        #expect(removedMouseMonitor)
        controller.handleActivationDeadline(generation: 1)
        #expect(!controller.isOpen)
    }

    @Test func optionMiddleCapturesItsExactPredicateAtDown() {
        var reservation = LayoutWheelMiddleClickReservation(trigger: .optionMiddleClick)
        let reserved1 = reservation.shouldReserve(kind: .down, button: 2, modifiers: .option, hasFunctionModifier: true)
        #expect(!reserved1)
        let reserved2 = reservation.shouldReserve(kind: .down, button: 2, modifiers: [])
        #expect(!reserved2)
        let reserved3 = reservation.shouldReserve(kind: .dragged, button: 2, modifiers: .option)
        #expect(!reserved3)
        let reserved4 = reservation.shouldReserve(kind: .up, button: 2, modifiers: .option)
        #expect(!reserved4)
        let reserved5 = reservation.shouldReserve(kind: .down, button: 2, modifiers: [.option, .control])
        #expect(!reserved5)
        let reserved6 = reservation.shouldReserve(kind: .down, button: 3, modifiers: .option)
        #expect(!reserved6)
        let reserved7 = reservation.shouldReserve(kind: .down, button: 2, modifiers: .option, acceptsNewGesture: false)
        #expect(!reserved7)
        let reserved8 = reservation.shouldReserve(kind: .down, button: 2, modifiers: .option)
        #expect(reserved8)
        reservation.trigger = .off
        let reserved9 = reservation.shouldReserve(kind: .dragged, button: 2, modifiers: [], acceptsNewGesture: false)
        #expect(reserved9)
        let reserved10 = reservation.shouldReserve(kind: .up, button: 2, modifiers: [.shift], acceptsNewGesture: false)
        #expect(reserved10)
        let reserved11 = reservation.shouldReserve(kind: .down, button: 2, modifiers: .option)
        #expect(!reserved11)
    }
}
