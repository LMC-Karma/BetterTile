import AppKit
import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

@MainActor private final class TriggerRulesPresenter: LayoutWheelPresenting {
    var latest: LayoutWheelPresentation?
    var acknowledgments: [LayoutWheelAcknowledgment] = []
    func open(_ presentation: LayoutWheelPresentation) { latest = presentation }
    func update(_ presentation: LayoutWheelPresentation) { latest = presentation }
    func showPlacements(_ placements: [Placement]) {}
    func hidePlacements() {}
    func close() {}
    func end(_ acknowledgment: LayoutWheelAcknowledgment) { acknowledgments.append(acknowledgment) }
}

/// Delivers events through the installed local or global monitor, without
/// observing real input or showing an AppKit panel.
@MainActor private final class TriggerRulesHarness {
    let presenter = TriggerRulesPresenter()
    var controller: LayoutWheelController!
    var global: [UInt64: (NSEvent) -> Void] = [:]
    var local: [UInt64: @MainActor (LayoutWheelInput) -> Bool] = [:]
    var commits: [LayoutWheelCommand] = []
    var pointer = BTPoint(x: 800, y: 500)
    /// The modifier state read at the activation deadline; nil uses the last delivered sample.
    var currentFlags: UInt?
    /// The Fn key's own key code. Other function-flag events come from arrow keys.
    static let functionKeyCode: UInt16 = 63
    static let rightArrowKeyCode: UInt16 = 124
    static let commandKeyCode: UInt16 = 55
    let usesLocalMonitor: Bool
    let trigger: ShortcutModifiers
    /// One value per global event, sent after the controller has handled it.
    private let handled: AsyncStream<Void>

    init(style: LayoutWheelStyle, local: Bool, trigger: ShortcutModifiers = [.control, .option, .shift]) {
        usesLocalMonitor = local
        self.trigger = trigger
        let (handledEvents, markHandled) = AsyncStream.makeStream(of: Void.self)
        handled = handledEvents
        controller = LayoutWheelController(
            configuration: .init(layoutWheel: .init(style: style, levelCount: .two, keyboardModifiers: trigger)),
            presenter: presenter, activationDelay: .seconds(3600),
            pointerProvider: { [unowned self] in pointer },
            addGlobalMonitor: { [unowned self] mask, handler in
                global[mask.rawValue] = handler
                return NSObject()
            }, addLocalMonitor: { [unowned self] mask, handler in
                self.local[mask.rawValue] = handler
                return NSObject()
            }, removeMonitor: { _ in }, modifierFlagsProvider: { [unowned self] in currentFlags })
        controller.captureHandler = { _ in
            LayoutWheelTarget(windowID: .init(rawValue: "fixture"), displayID: .init(rawValue: "display"),
                              visibleFrame: .init(x: 0, y: 0, width: 1600, height: 1000))
        }
        controller.previewHandler = { _, _ in .ready(placements: []) }
        controller.commitHandler = { [unowned self] command, _ in commits.append(command) }
        controller.globalInputHandledForTesting = { markHandled.yield() }
        controller.start()
    }

    static func flags(_ modifiers: ShortcutModifiers, function: Bool = false) -> NSEvent.ModifierFlags {
        var flags = NSEvent.ModifierFlags()
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.command) { flags.insert(.command) }
        if function { flags.insert(.function) }
        return flags
    }

    @discardableResult
    func send(_ type: NSEvent.EventType, modifiers: ShortcutModifiers, function: Bool = false,
              keyCode: UInt16 = 0) async throws -> Bool {
        let mask: NSEvent.EventTypeMask = type == .flagsChanged ? .flagsChanged : .keyDown
        let flags = Self.flags(modifiers, function: function)
        if usesLocalMonitor {
            let handler = try #require(local[mask.rawValue])
            return handler(.init(keyCode: keyCode, flags: flags))
        }
        let event = try #require(NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: flags, timestamp: 1,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: keyCode))
        let handler = try #require(global[mask.rawValue])
        handler(event)
        // The monitor queues a main-actor task. Wait until it has handled the event.
        var events = handled.makeAsyncIterator()
        await events.next()
        return false
    }

    func open() async throws {
        try await send(.flagsChanged, modifiers: trigger)
        #expect(controller.isPendingActivation)
        controller.handleActivationDeadline(generation: 1)
        #expect(controller.isOpen)
        pointer.y -= 50
        controller.handlePointer(pointer)
        #expect(presenter.latest?.selection == .init(ring: .inner, sector: .top))
    }
}

@Suite(.macOSTestApplication) struct LayoutWheelTriggerRulesTests {
    @Test(arguments: [LayoutWheelStyle.custom, .grouped], [false, true]) @MainActor
    func idleSupersetChordCannotOpenWhenExtraModifierIsReleasedFirst(style: LayoutWheelStyle, local: Bool) async throws {
        let h = TriggerRulesHarness(style: style, local: local)
        defer { h.controller.stop() }
        try await h.send(.flagsChanged, modifiers: [.command])
        try await h.send(.flagsChanged, modifiers: [.command, .control])
        try await h.send(.flagsChanged, modifiers: [.command, .control, .option])
        try await h.send(.flagsChanged, modifiers: h.trigger.union(.command))
        #expect(!h.controller.isPendingActivation)
        try await h.send(.flagsChanged, modifiers: h.trigger)
        #expect(!h.controller.isPendingActivation)
        h.controller.handleActivationDeadline(generation: 1)
        #expect(!h.controller.isOpen)
        #expect(h.commits.isEmpty)

        // A partial release and re-press must leave the trigger disarmed.
        try await h.send(.flagsChanged, modifiers: [.control])
        try await h.send(.flagsChanged, modifiers: h.trigger)
        #expect(!h.controller.isPendingActivation)
        try await h.send(.flagsChanged, modifiers: [])
        try await h.open()
    }

    @Test(arguments: [LayoutWheelStyle.custom, .grouped], [false, true]) @MainActor
    func normalChordPressStillOpens(style: LayoutWheelStyle, local: Bool) async throws {
        let h = TriggerRulesHarness(style: style, local: local)
        defer { h.controller.stop() }
        try await h.send(.flagsChanged, modifiers: [.control])
        try await h.send(.flagsChanged, modifiers: [.control, .option])
        try await h.open()
        #expect(h.commits.isEmpty)
    }

    @Test(arguments: [false, true]) @MainActor
    func configuredChordsDistinguishEveryExtraModifierFromRequiredKeyReleases(local: Bool) async throws {
        let keys: [ShortcutModifiers] = [.control, .option, .shift, .command]
        for rawValue: UInt in 1..<16 where rawValue.nonzeroBitCount >= 2 {
            let trigger = ShortcutModifiers(rawValue: rawValue)
            for key in keys {
                let h = TriggerRulesHarness(style: .custom, local: local, trigger: trigger)
                defer { h.controller.stop() }
                try await h.open()
                if trigger.contains(key) {
                    try await h.send(.flagsChanged, modifiers: trigger.subtracting(key))
                    #expect(h.commits == [.windowAction(.topHalf)])
                    #expect(h.presenter.acknowledgments == [.commit])
                } else {
                    // An added modifier takes cancellation priority even if
                    // a required key is missing in the same delivered sample.
                    let required = try #require(keys.first { trigger.contains($0) })
                    try await h.send(.flagsChanged, modifiers: trigger.subtracting(required).union(key))
                    #expect(h.commits.isEmpty)
                    #expect(h.presenter.acknowledgments == [.cancel])
                }
                try await h.send(.flagsChanged, modifiers: trigger)
                #expect(!h.controller.isPendingActivation)
            }
        }
    }

    @Test(arguments: [LayoutWheelStyle.custom, .grouped], [false, true]) @MainActor
    func extraModifierCancelsWithoutDispatchAndCannotReopen(style: LayoutWheelStyle, local: Bool) async throws {
        let h = TriggerRulesHarness(style: style, local: local)
        defer { h.controller.stop() }
        try await h.open()
        try await h.send(.flagsChanged, modifiers: h.trigger.union(.command))
        #expect(!h.controller.isOpen)
        #expect(h.presenter.acknowledgments == [.cancel])
        #expect(h.commits.isEmpty)

        // Removing just the contaminating key must not restart the hold.
        try await h.send(.flagsChanged, modifiers: h.trigger)
        #expect(!h.controller.isPendingActivation)
        h.controller.handleActivationDeadline(generation: 2)
        #expect(!h.controller.isOpen)
        try await h.send(.flagsChanged, modifiers: [])
        #expect(h.commits.isEmpty)
        #expect(h.presenter.acknowledgments == [.cancel])

        try await h.send(.flagsChanged, modifiers: h.trigger)
        #expect(h.controller.isPendingActivation)
        h.controller.handleActivationDeadline(generation: 2)
        #expect(h.controller.isOpen)
    }

    @Test(arguments: [LayoutWheelStyle.custom, .grouped], [false, true]) @MainActor
    func functionKeyIsAnExtraModifierBeforeAndAfterOpening(style: LayoutWheelStyle, local: Bool) async throws {
        let h = TriggerRulesHarness(style: style, local: local)
        defer { h.controller.stop() }
        // Fn with the chord cannot start a hold, and releasing Fn first cannot either.
        try await h.send(.flagsChanged, modifiers: h.trigger, function: true)
        #expect(!h.controller.isPendingActivation)
        try await h.send(.flagsChanged, modifiers: h.trigger)
        #expect(!h.controller.isPendingActivation)
        try await h.send(.flagsChanged, modifiers: [])

        // Fn added during the hold cancels it.
        try await h.send(.flagsChanged, modifiers: h.trigger)
        #expect(h.controller.isPendingActivation)
        try await h.send(.flagsChanged, modifiers: h.trigger, function: true)
        #expect(!h.controller.isPendingActivation)
        h.controller.handleActivationDeadline(generation: 1)
        #expect(!h.controller.isOpen)
        try await h.send(.flagsChanged, modifiers: [])

        // Fn added after a selection cancels; a later release commits nothing.
        try await h.send(.flagsChanged, modifiers: h.trigger)
        h.controller.handleActivationDeadline(generation: 2)
        #expect(h.controller.isOpen)
        h.pointer.y -= 50
        h.controller.handlePointer(h.pointer)
        try await h.send(.flagsChanged, modifiers: h.trigger, function: true, keyCode: TriggerRulesHarness.functionKeyCode)
        #expect(!h.controller.isOpen)
        #expect(h.presenter.acknowledgments == [.cancel])
        try await h.send(.flagsChanged, modifiers: [.control, .option], function: true)
        try await h.send(.flagsChanged, modifiers: [])
        #expect(h.commits.isEmpty)
    }

    @Test(arguments: [false, true]) @MainActor
    func functionKeyAtTheDeadlineCancelsTheHold(local: Bool) async throws {
        let h = TriggerRulesHarness(style: .custom, local: local)
        defer { h.controller.stop() }
        try await h.send(.flagsChanged, modifiers: h.trigger)
        #expect(h.controller.isPendingActivation)
        // Fn went down, but its flagsChanged never reached the monitor.
        h.currentFlags = TriggerRulesHarness.flags(h.trigger, function: true).rawValue
        h.controller.handleActivationDeadline(generation: 1)
        #expect(!h.controller.isOpen && !h.controller.isPendingActivation)
        #expect(h.commits.isEmpty)
    }

    @Test(arguments: [LayoutWheelStyle.custom, .grouped], [false, true]) @MainActor
    func triggerKeyReleaseCommitsOnceAndRearmsOnlyAfterAllTriggerKeysAreUp(style: LayoutWheelStyle, local: Bool) async throws {
        let h = TriggerRulesHarness(style: style, local: local)
        defer { h.controller.stop() }
        try await h.open()
        try await h.send(.flagsChanged, modifiers: [.control, .option])
        #expect(h.commits == [.windowAction(.topHalf)])
        #expect(h.presenter.acknowledgments == [.commit])
        try await h.send(.flagsChanged, modifiers: [.control])
        try await h.send(.flagsChanged, modifiers: h.trigger)
        #expect(!h.controller.isPendingActivation)
        h.controller.handleActivationDeadline(generation: 2)
        #expect(!h.controller.isOpen)
        try await h.send(.flagsChanged, modifiers: [])
        #expect(h.commits.count == 1)
        try await h.send(.flagsChanged, modifiers: h.trigger)
        #expect(h.controller.isPendingActivation)
    }

    @Test(arguments: [LayoutWheelStyle.custom, .grouped], [false, true]) @MainActor
    func ordinaryKeyCancelsAnOpenWheelAndLaterReleaseDoesNothing(style: LayoutWheelStyle, local: Bool) async throws {
        let h = TriggerRulesHarness(style: style, local: local)
        defer { h.controller.stop() }
        try await h.open()
        let consumed = try await h.send(.keyDown, modifiers: h.trigger, keyCode: 0) // A
        #expect(!consumed)
        #expect(!h.controller.isOpen)
        #expect(h.presenter.acknowledgments == [.cancel])
        try await h.send(.flagsChanged, modifiers: [.control, .option])
        try await h.send(.flagsChanged, modifiers: h.trigger)
        #expect(!h.controller.isPendingActivation)
        try await h.send(.flagsChanged, modifiers: [])
        #expect(h.commits.isEmpty)
        #expect(h.presenter.acknowledgments == [.cancel])
    }

    @Test(arguments: [false, true]) @MainActor
    func ordinaryKeyBeforeOpeningCancelsTheHoldUntilAllUp(local: Bool) async throws {
        let h = TriggerRulesHarness(style: .custom, local: local)
        defer { h.controller.stop() }
        try await h.send(.flagsChanged, modifiers: h.trigger)
        let consumed = try await h.send(.keyDown, modifiers: h.trigger, keyCode: 0)
        #expect(!consumed)
        try await h.send(.flagsChanged, modifiers: [.control])
        try await h.send(.flagsChanged, modifiers: h.trigger)
        #expect(!h.controller.isPendingActivation)
        h.controller.handleActivationDeadline(generation: 1)
        #expect(!h.controller.isOpen)
        #expect(h.commits.isEmpty)
        try await h.send(.flagsChanged, modifiers: [])
        try await h.send(.flagsChanged, modifiers: h.trigger)
        #expect(h.controller.isPendingActivation)
    }

    @Test(arguments: [LayoutWheelStyle.custom, .grouped], [false, true]) @MainActor
    func navigationReturnAndEscapeKeepTheirBehavior(style: LayoutWheelStyle, local: Bool) async throws {
        for keyCode: UInt16 in [48, 123, 124, 125, 126, 36, 76, 53] {
            let h = TriggerRulesHarness(style: style, local: local)
            defer { h.controller.stop() }
            try await h.open()
            let consumed = try await h.send(.keyDown, modifiers: h.trigger, keyCode: keyCode)
            #expect(consumed == local)
            switch keyCode {
            case 36, 76:
                #expect(h.commits == [.windowAction(.topHalf)])
                #expect(h.presenter.acknowledgments == [.commit])
            case 53:
                #expect(h.commits.isEmpty)
                #expect(h.presenter.acknowledgments == [.cancel])
            default:
                #expect(h.controller.isOpen)
                #expect(h.commits.isEmpty)
                #expect(h.presenter.acknowledgments.isEmpty)
                if keyCode == 123 { #expect(h.presenter.latest?.selection?.sector == .topLeft) }
                if keyCode == 124 { #expect(h.presenter.latest?.selection?.sector == .topRight) }
            }
        }
    }

    // MARK: An arrow key adds the function flag

    @Test(arguments: [LayoutWheelStyle.custom, .grouped], [false, true]) @MainActor
    func chordReleaseCommitsWhileAnArrowKeyIsHeld(style: LayoutWheelStyle, local: Bool) async throws {
        let h = TriggerRulesHarness(style: style, local: local)
        defer { h.controller.stop() }
        try await h.open()
        // An arrow key moves the selection and keeps the function flag set.
        try await h.send(.keyDown, modifiers: h.trigger, function: true, keyCode: TriggerRulesHarness.rightArrowKeyCode)
        #expect(h.controller.isOpen && h.commits.isEmpty)
        // Only the chord decides the release; the held arrow does not.
        try await h.send(.flagsChanged, modifiers: [], function: true, keyCode: TriggerRulesHarness.commandKeyCode)
        #expect(!h.controller.isOpen)
        #expect(h.commits.count == 1)
        #expect(h.presenter.acknowledgments == [.commit])
        // Releasing the arrow later, with the flag now clear, commits nothing more.
        try await h.send(.flagsChanged, modifiers: [])
        #expect(h.commits.count == 1)
    }

    @Test(arguments: [LayoutWheelStyle.custom, .grouped], [false, true]) @MainActor
    func anArrowPressedWhileTheChordIsHeldDoesNotCommitEarly(style: LayoutWheelStyle, local: Bool) async throws {
        let h = TriggerRulesHarness(style: style, local: local)
        defer { h.controller.stop() }
        try await h.open()
        try await h.send(.keyDown, modifiers: h.trigger, function: true, keyCode: TriggerRulesHarness.rightArrowKeyCode)
        // Another flag change arrives while the chord is intact and the arrow is down.
        try await h.send(.flagsChanged, modifiers: h.trigger, function: true, keyCode: 57)
        #expect(h.controller.isOpen && h.commits.isEmpty && h.presenter.acknowledgments.isEmpty)
        // The arrow comes up first; the chord is still held.
        try await h.send(.flagsChanged, modifiers: h.trigger, keyCode: 57)
        #expect(h.controller.isOpen && h.commits.isEmpty)
        try await h.send(.flagsChanged, modifiers: [])
        #expect(h.commits.count == 1)
        #expect(h.presenter.acknowledgments == [.commit])
    }

    @Test(arguments: [LayoutWheelStyle.custom, .grouped], [false, true]) @MainActor
    func physicalFunctionKeyStillCancelsWhileAnArrowKeyIsHeld(style: LayoutWheelStyle, local: Bool) async throws {
        let h = TriggerRulesHarness(style: style, local: local)
        defer { h.controller.stop() }
        try await h.open()
        try await h.send(.keyDown, modifiers: h.trigger, function: true, keyCode: TriggerRulesHarness.rightArrowKeyCode)
        try await h.send(.flagsChanged, modifiers: h.trigger, function: true, keyCode: TriggerRulesHarness.functionKeyCode)
        #expect(!h.controller.isOpen)
        #expect(h.presenter.acknowledgments == [.cancel])
        try await h.send(.flagsChanged, modifiers: [], function: true, keyCode: TriggerRulesHarness.commandKeyCode)
        #expect(h.commits.isEmpty)
    }
}
