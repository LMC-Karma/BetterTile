import Foundation
import Testing
@testable import BetterTileCore

@Suite struct DisplayTriggerReducerTests {
    private func display(_ uuid: String, serial: UInt32 = 11, x: Double = 0, width: Double = 2560) -> DisplayFingerprint {
        .init(uuid: uuid, vendor: 1552, model: 41010, serial: serial, builtIn: false, name: uuid,
              frame: BTRect(x: x, y: 0, width: width, height: 1440))
    }

    private let desk = DisplayFingerprint(uuid: "DESK", vendor: 1552, model: 41010, serial: 11, builtIn: false,
                                          name: "Desk", frame: BTRect(x: 0, y: 0, width: 2560, height: 1440))
    private let laptop = DisplayFingerprint(uuid: "LAP", vendor: 1552, model: 41022, serial: 22, builtIn: true,
                                            name: "Laptop", frame: BTRect(x: -1512, y: 0, width: 1512, height: 982))

    private func trigger(_ file: String = "desk.json", on displays: [DisplayFingerprint], target: Int = 0,
                         enabled: Bool = true, wake: Bool = false) -> DisplayTrigger {
        .init(layoutFile: file, enabled: enabled, alsoAfterWake: wake, displays: displays, target: target)
    }

    private func settle(_ actions: [DisplayTriggerAction]) -> Int? {
        if case let .settle(token)? = actions.first { return token }
        return nil
    }

    // MARK: Which sets fire

    @Test func anExactMatchWaitsThenAppliesOnTheRightDisplay() {
        var reducer = DisplayTriggerReducer(initial: [laptop])
        let triggers = [trigger(on: [desk, laptop], target: 0)]
        let token = settle(reducer.handle(.displaysChanged([laptop, desk]), triggers: triggers))
        #expect(token != nil)
        let actions = reducer.handle(.settled(token: token!, live: [laptop, desk], busy: false), triggers: triggers)
        #expect(actions == [.apply(fires: [.init(layoutFile: "desk.json", liveIndex: 1)], offers: [])])
    }

    @Test func aSwitchThatIsOffNeverFires() {
        var reducer = DisplayTriggerReducer(initial: [laptop])
        let triggers = [trigger(on: [desk, laptop], enabled: false)]
        #expect(reducer.handle(.displaysChanged([desk, laptop]), triggers: triggers).isEmpty)
        #expect(!reducer.isWaiting)
    }

    @Test func aSetThatDoesNotMatchNeverFires() {
        var reducer = DisplayTriggerReducer(initial: [laptop])
        let triggers = [trigger(on: [desk, laptop])]
        // A missing display, an extra display, and another display all give no match.
        #expect(reducer.handle(.displaysChanged([desk]), triggers: triggers).isEmpty)
        #expect(reducer.handle(.displaysChanged([desk, laptop, display("EXTRA", serial: 5, x: 3000)]), triggers: triggers).isEmpty)
        #expect(reducer.handle(.displaysChanged([display("OTHER", serial: 9), laptop]), triggers: triggers).isEmpty)
    }

    @Test func anUncertainMatchOnlyOffersAndNeverApplies() {
        let left = display("L", serial: 0, x: 0), right = display("R", serial: 0, x: 2560)
        var reducer = DisplayTriggerReducer(initial: [])
        let triggers = [trigger(on: [left, right], target: 1)]
        let swapped = [display("left-b", serial: 0, x: 0), display("right-b", serial: 0, x: 2560)]
        let token = settle(reducer.handle(.displaysChanged(swapped), triggers: triggers))!
        let actions = reducer.handle(.settled(token: token, live: swapped, busy: false), triggers: triggers)
        #expect(actions == [.apply(fires: [], offers: [.init(layoutFile: "desk.json", liveIndex: 1)])])
        #expect(!reducer.isApplying)
    }

    @Test func eachBoundDisplayAppliesLeftToRightAndOnlyItsOwnLayout() {
        var reducer = DisplayTriggerReducer(initial: [])
        let triggers = [trigger("laptop.json", on: [desk, laptop], target: 1), trigger("desk.json", on: [desk, laptop], target: 0),
                        trigger("elsewhere.json", on: [desk], target: 0)]
        let token = settle(reducer.handle(.displaysChanged([desk, laptop]), triggers: triggers))!
        let actions = reducer.handle(.settled(token: token, live: [desk, laptop], busy: false), triggers: triggers)
        #expect(actions == [.apply(fires: [.init(layoutFile: "laptop.json", liveIndex: 1), .init(layoutFile: "desk.json", liveIndex: 0)],
                                   offers: [])])
    }

    // MARK: Once per connect

    @Test func theSameSetAgainDoesNotFire() {
        var reducer = DisplayTriggerReducer(initial: [desk])
        let triggers = [trigger(on: [desk])]
        // A resolution change keeps the identity.
        #expect(reducer.handle(.displaysChanged([display("DESK", width: 1920)]), triggers: triggers).isEmpty)
        #expect(reducer.handle(.displaysChanged([desk]), triggers: triggers).isEmpty)
    }

    @Test func startingBetterTileWithTheSetConnectedIsNotATrigger() {
        var reducer = DisplayTriggerReducer(initial: [desk, laptop])
        #expect(reducer.handle(.displaysChanged([desk, laptop]), triggers: [trigger(on: [desk, laptop])]).isEmpty)
    }

    @Test func repeatedReconfigurationFiresOnce() {
        var reducer = DisplayTriggerReducer(initial: [laptop])
        let triggers = [trigger(on: [desk, laptop])]
        var applies = 0
        var token = settle(reducer.handle(.displaysChanged([desk, laptop]), triggers: triggers))!
        // Noise during the wait restarts the wait and makes the older one stale.
        for _ in 0..<4 {
            let stale = token
            token = settle(reducer.handle(.displaysChanged([desk, laptop]), triggers: triggers))!
            #expect(token != stale)
            #expect(reducer.handle(.settled(token: stale, live: [desk, laptop], busy: false), triggers: triggers).isEmpty)
        }
        for event in [DisplayTriggerEvent.settled(token: token, live: [desk, laptop], busy: false),
                      .settled(token: token, live: [desk, laptop], busy: false), .applyFinished,
                      .displaysChanged([desk, laptop]), .displaysChanged([desk, laptop])] {
            for case .apply in reducer.handle(event, triggers: triggers) { applies += 1 }
        }
        #expect(applies == 1)
    }

    @Test func aFailedAttemptIsUsedUpAndNotRetried() {
        var reducer = DisplayTriggerReducer(initial: [laptop])
        let triggers = [trigger(on: [desk, laptop])]
        let token = settle(reducer.handle(.displaysChanged([desk, laptop]), triggers: triggers))!
        _ = reducer.handle(.settled(token: token, live: [desk, laptop], busy: false), triggers: triggers)
        #expect(reducer.handle(.applyFinished, triggers: triggers).isEmpty)
        #expect(reducer.handle(.displaysChanged([desk, laptop]), triggers: triggers).isEmpty)
        #expect(!reducer.isWaiting && !reducer.isApplying)
    }

    @Test func disconnectingAndConnectingAgainFiresAgain() {
        var reducer = DisplayTriggerReducer(initial: [laptop])
        let triggers = [trigger(on: [desk, laptop])]
        for _ in 0..<2 {
            let token = settle(reducer.handle(.displaysChanged([desk, laptop]), triggers: triggers))!
            #expect(reducer.handle(.settled(token: token, live: [desk, laptop], busy: false), triggers: triggers).count == 1)
            _ = reducer.handle(.applyFinished, triggers: triggers)
            #expect(reducer.handle(.displaysChanged([laptop]), triggers: triggers).isEmpty)
        }
    }

    @Test func theSetChangingDuringTheWaitJudgesTheNewestSet() {
        var reducer = DisplayTriggerReducer(initial: [laptop])
        let triggers = [trigger(on: [desk, laptop])]
        let token = settle(reducer.handle(.displaysChanged([desk, laptop]), triggers: triggers))!
        // The settle wait ends and the desk display is gone again: no apply.
        #expect(reducer.handle(.settled(token: token, live: [laptop], busy: false), triggers: triggers).isEmpty)
        #expect(!reducer.isWaiting)
    }

    // MARK: Wake

    @Test func wakeWithTheSameSetFiresOnlyWithTheSwitch() {
        let set = [desk, laptop]
        var off = DisplayTriggerReducer(initial: set)
        _ = off.handle(.sleep, triggers: [])
        #expect(off.handle(.wake(set), triggers: [trigger(on: set, wake: false)]).isEmpty)

        var on = DisplayTriggerReducer(initial: set)
        let triggers = [trigger(on: set, wake: true)]
        _ = on.handle(.sleep, triggers: triggers)
        let token = settle(on.handle(.wake(set), triggers: triggers))
        #expect(token != nil)
        #expect(on.handle(.settled(token: token!, live: set, busy: false), triggers: triggers).count == 1)
    }

    @Test func wakeAfterASetChangeDuringSleepFiresWithoutTheWakeSwitch() {
        var reducer = DisplayTriggerReducer(initial: [laptop])
        let triggers = [trigger(on: [desk, laptop], wake: false)]
        _ = reducer.handle(.sleep, triggers: triggers)
        // The display arrives during sleep: held, not started.
        #expect(reducer.handle(.displaysChanged([desk, laptop]), triggers: triggers).isEmpty)
        #expect(!reducer.isWaiting)
        let token = settle(reducer.handle(.wake([desk, laptop]), triggers: triggers))
        #expect(token != nil)
        #expect(reducer.handle(.settled(token: token!, live: [desk, laptop], busy: false), triggers: triggers).count == 1)
    }

    @Test func twoWakeNotificationsForOneSleepApplyOnce() {
        let set = [desk, laptop]
        var reducer = DisplayTriggerReducer(initial: set)
        let triggers = [trigger(on: set, wake: true)]
        _ = reducer.handle(.sleep, triggers: triggers)
        _ = reducer.handle(.sleep, triggers: triggers) // the display-sleep notification of the same sleep
        var applies = 0
        let token = settle(reducer.handle(.wake(set), triggers: triggers))!
        for event in [DisplayTriggerEvent.wake(set), .settled(token: token, live: set, busy: false), .applyFinished,
                      .wake(set), .wake(set)] {
            for case .apply in reducer.handle(event, triggers: triggers) { applies += 1 }
        }
        #expect(applies == 1)
        #expect(reducer.handle(.wake(set), triggers: triggers).isEmpty)
    }

    @Test func aWakeThatNoSleepAnnouncedFiresNothing() {
        let set = [desk, laptop]
        var reducer = DisplayTriggerReducer(initial: set)
        #expect(reducer.handle(.wake(set), triggers: [trigger(on: set, wake: true)]).isEmpty)
    }

    @Test func aSecondSleepArmsAnotherWakeApply() {
        let set = [desk, laptop]
        var reducer = DisplayTriggerReducer(initial: set)
        let triggers = [trigger(on: set, wake: true)]
        for _ in 0..<2 {
            _ = reducer.handle(.sleep, triggers: triggers)
            let token = settle(reducer.handle(.wake(set), triggers: triggers))!
            #expect(reducer.handle(.settled(token: token, live: set, busy: false), triggers: triggers).count == 1)
            _ = reducer.handle(.applyFinished, triggers: triggers)
        }
    }

    @Test func displayChangesDuringSleepFoldIntoTheOneWakeApply() {
        var reducer = DisplayTriggerReducer(initial: [desk, laptop])
        let triggers = [trigger(on: [desk, laptop], wake: true)]
        _ = reducer.handle(.sleep, triggers: triggers)
        // The set drops and returns while asleep: both events are held, and the wake sees the same set.
        #expect(reducer.handle(.displaysChanged([laptop]), triggers: triggers).isEmpty)
        #expect(reducer.handle(.displaysChanged([desk, laptop]), triggers: triggers).isEmpty)
        var applies = 0
        let token = settle(reducer.handle(.wake([desk, laptop]), triggers: triggers))!
        for event in [DisplayTriggerEvent.settled(token: token, live: [desk, laptop], busy: false), .applyFinished,
                      .wake([desk, laptop])] {
            for case .apply in reducer.handle(event, triggers: triggers) { applies += 1 }
        }
        #expect(applies == 1)
    }

    @Test func aConnectThatSleepInterruptedAppliesOnceAfterWakeWithoutTheWakeSwitch() {
        var reducer = DisplayTriggerReducer(initial: [laptop])
        let triggers = [trigger(on: [desk, laptop], wake: false)]
        let first = settle(reducer.handle(.displaysChanged([desk, laptop]), triggers: triggers))!
        _ = reducer.handle(.sleep, triggers: triggers)
        _ = reducer.handle(.sleep, triggers: triggers)
        // The old wait is stale. The wake sees the same set as before sleep and still runs the connect Apply.
        #expect(reducer.handle(.settled(token: first, live: [desk, laptop], busy: false), triggers: triggers).isEmpty)
        var applies = 0
        let token = settle(reducer.handle(.wake([desk, laptop]), triggers: triggers))!
        for event in [DisplayTriggerEvent.wake([desk, laptop]), .settled(token: token, live: [desk, laptop], busy: false),
                      .applyFinished, .wake([desk, laptop])] {
            for case .apply in reducer.handle(event, triggers: triggers) { applies += 1 }
        }
        #expect(applies == 1)
        // The next sleep and wake do not repeat it.
        _ = reducer.handle(.sleep, triggers: triggers)
        #expect(reducer.handle(.wake([desk, laptop]), triggers: triggers).isEmpty)
    }

    @Test func aConnectInterruptedBySleepFoldsIntoTheOneWakeApplyWhenTheSwitchIsOn() {
        let set = [desk, laptop]
        var reducer = DisplayTriggerReducer(initial: [laptop])
        let triggers = [trigger(on: set, wake: true)]
        _ = reducer.handle(.displaysChanged(set), triggers: triggers)
        _ = reducer.handle(.sleep, triggers: triggers)
        var applies = 0
        let token = settle(reducer.handle(.wake(set), triggers: triggers))!
        for event in [DisplayTriggerEvent.settled(token: token, live: set, busy: false), .applyFinished, .wake(set)] {
            for case .apply in reducer.handle(event, triggers: triggers) { applies += 1 }
        }
        #expect(applies == 1)
    }

    @Test func aWakeOnlyWaitInterruptedBySleepIsNotCarriedOver() {
        let set = [desk, laptop]
        var reducer = DisplayTriggerReducer(initial: set)
        let triggers = [trigger(on: set, wake: true)]
        _ = reducer.handle(.sleep, triggers: triggers)
        _ = reducer.handle(.wake(set), triggers: triggers)
        _ = reducer.handle(.sleep, triggers: [trigger(on: set, wake: false)])
        // The switch is now off and nothing connected: the second wake has nothing to run.
        #expect(reducer.handle(.wake(set), triggers: [trigger(on: set, wake: false)]).isEmpty)
    }

    // MARK: Lock screen

    @Test func aWakeAtTheLockScreenStaysPendingAndUnused() {
        let set = [desk, laptop]
        var reducer = DisplayTriggerReducer(initial: set)
        let triggers = [trigger(on: set, wake: true)]
        _ = reducer.handle(.sleep, triggers: triggers)
        _ = reducer.handle(.locked, triggers: triggers)
        #expect(reducer.handle(.wake(set), triggers: triggers).isEmpty)
        #expect(reducer.isWaiting && reducer.isAwaitingUnlock && reducer.isLocked)
        // A second wake, input at the lock screen, and noise change nothing.
        #expect(reducer.handle(.wake(set), triggers: triggers).isEmpty)
        #expect(reducer.handle(.userInput, triggers: triggers).isEmpty)
        #expect(reducer.handle(.displaysChanged(set), triggers: triggers).isEmpty)
        #expect(reducer.isWaiting && reducer.isAwaitingUnlock)
    }

    @Test func unlockingReleasesThePendingAttemptToTheSettleWait() {
        let set = [desk, laptop]
        var reducer = DisplayTriggerReducer(initial: set)
        let triggers = [trigger(on: set, wake: true)]
        _ = reducer.handle(.sleep, triggers: triggers)
        _ = reducer.handle(.locked, triggers: triggers)
        _ = reducer.handle(.wake(set), triggers: triggers)
        let token = settle(reducer.handle(.unlocked, triggers: triggers))
        #expect(token != nil && !reducer.isAwaitingUnlock && !reducer.isLocked)
        #expect(reducer.handle(.settled(token: token!, live: set, busy: false), triggers: triggers).count == 1)
    }

    @Test func aLockThatBeginsDuringTheWaitStalesItAndKeepsTheAttempt() {
        let set = [desk, laptop]
        var reducer = DisplayTriggerReducer(initial: set)
        let triggers = [trigger(on: set, wake: true)]
        _ = reducer.handle(.sleep, triggers: triggers)
        let token = settle(reducer.handle(.wake(set), triggers: triggers))!
        _ = reducer.handle(.locked, triggers: triggers)
        #expect(reducer.handle(.settled(token: token, live: set, busy: false), triggers: triggers).isEmpty)
        #expect(reducer.isAwaitingUnlock)
        #expect(settle(reducer.handle(.unlocked, triggers: triggers)) != nil)
    }

    @Test func theLockExpiringGivesUpWithoutAnApply() {
        let set = [desk, laptop]
        var reducer = DisplayTriggerReducer(initial: set)
        let triggers = [trigger(on: set, wake: true)]
        _ = reducer.handle(.sleep, triggers: triggers)
        _ = reducer.handle(.locked, triggers: triggers)
        _ = reducer.handle(.wake(set), triggers: triggers)
        #expect(reducer.handle(.lockExpired, triggers: triggers).isEmpty)
        #expect(!reducer.isWaiting && !reducer.isLocked)
        // A late unlock finds nothing to release.
        #expect(reducer.handle(.unlocked, triggers: triggers).isEmpty)
    }

    @Test func aDifferentSetAtTheLockScreenDropsTheOldAttemptAndTheNewOneWaitsToo() {
        var reducer = DisplayTriggerReducer(initial: [laptop])
        let triggers = [trigger("a.json", on: [laptop], target: 0, wake: true),
                        trigger("b.json", on: [desk, laptop], target: 0)]
        _ = reducer.handle(.sleep, triggers: triggers)
        _ = reducer.handle(.locked, triggers: triggers)
        _ = reducer.handle(.wake([laptop]), triggers: triggers)
        #expect(reducer.isAwaitingUnlock)
        // The desk display connects while the screen is locked: a different set.
        #expect(reducer.handle(.displaysChanged([desk, laptop]), triggers: triggers).isEmpty)
        #expect(reducer.isAwaitingUnlock)
        let token = settle(reducer.handle(.unlocked, triggers: triggers))!
        #expect(reducer.handle(.settled(token: token, live: [desk, laptop], busy: false), triggers: triggers)
                == [.apply(fires: [.init(layoutFile: "b.json", liveIndex: 0)], offers: [])])
    }

    @Test func aDifferentSetWithNoBindingEndsTheLockedAttempt() {
        var reducer = DisplayTriggerReducer(initial: [laptop])
        let triggers = [trigger(on: [laptop], wake: true)]
        _ = reducer.handle(.sleep, triggers: triggers)
        _ = reducer.handle(.locked, triggers: triggers)
        _ = reducer.handle(.wake([laptop]), triggers: triggers)
        _ = reducer.handle(.displaysChanged([desk, laptop]), triggers: triggers)
        #expect(!reducer.isWaiting)
        #expect(reducer.handle(.unlocked, triggers: triggers).isEmpty)
    }

    @Test func aWakeAndADisplayChangeTogetherFireOnce() {
        var reducer = DisplayTriggerReducer(initial: [laptop])
        let set = [desk, laptop]
        let triggers = [trigger(on: set, wake: true)]
        _ = reducer.handle(.sleep, triggers: triggers)
        let first = settle(reducer.handle(.wake(set), triggers: triggers))!
        // The display change that follows the wake joins the same wait.
        let token = settle(reducer.handle(.displaysChanged(set), triggers: triggers))!
        #expect(token != first)
        #expect(reducer.handle(.settled(token: token, live: set, busy: false), triggers: triggers).count == 1)
        #expect(reducer.handle(.wake(set), triggers: [trigger(on: set, wake: false)]).isEmpty)
    }

    @Test func aWakeThatTheSwitchesDoNotCoverDoesNotUpgradeToAFullFire() {
        // The set is unchanged and only an "Also after wake" trigger applies; the other stays quiet.
        let set = [desk, laptop]
        var reducer = DisplayTriggerReducer(initial: set)
        let triggers = [trigger("a.json", on: set, target: 0, wake: true), trigger("b.json", on: set, target: 1, wake: false)]
        _ = reducer.handle(.sleep, triggers: triggers)
        let token = settle(reducer.handle(.wake(set), triggers: triggers))!
        #expect(reducer.handle(.settled(token: token, live: set, busy: false), triggers: triggers)
                == [.apply(fires: [.init(layoutFile: "a.json", liveIndex: 0)], offers: [])])
    }

    // MARK: Input and postponing

    @Test func inputDuringTheWaitCancelsAndOffersTheLayout() {
        var reducer = DisplayTriggerReducer(initial: [laptop])
        let triggers = [trigger(on: [desk, laptop])]
        let token = settle(reducer.handle(.displaysChanged([desk, laptop]), triggers: triggers))!
        #expect(reducer.handle(.userInput, triggers: triggers)
                == [.cancel(fires: [.init(layoutFile: "desk.json", liveIndex: 0)], applying: false)])
        // The stale wait does nothing, and the set is not retried.
        #expect(reducer.handle(.settled(token: token, live: [desk, laptop], busy: false), triggers: triggers).isEmpty)
        #expect(reducer.handle(.displaysChanged([desk, laptop]), triggers: triggers).isEmpty)
    }

    @Test func inputDuringTheApplyCancelsIt() {
        var reducer = DisplayTriggerReducer(initial: [laptop])
        let triggers = [trigger(on: [desk, laptop])]
        let token = settle(reducer.handle(.displaysChanged([desk, laptop]), triggers: triggers))!
        _ = reducer.handle(.settled(token: token, live: [desk, laptop], busy: false), triggers: triggers)
        #expect(reducer.handle(.userInput, triggers: triggers)
                == [.cancel(fires: [.init(layoutFile: "desk.json", liveIndex: 0)], applying: true)])
        #expect(reducer.handle(.userInput, triggers: triggers).isEmpty)
    }

    @Test func inputCancelsBothAnApplyAndItsNewPendingWaitOnce() throws {
        var reducer = DisplayTriggerReducer(initial: [laptop])
        let set = [desk, laptop]
        let triggers = [trigger(on: set)]
        let first = try #require(settle(reducer.handle(.displaysChanged(set), triggers: triggers)))
        _ = reducer.handle(.settled(token: first, live: set, busy: false), triggers: triggers)
        _ = reducer.handle(.displaysChanged([laptop]), triggers: triggers)
        let next = try #require(settle(reducer.handle(.displaysChanged(set), triggers: triggers)))
        _ = reducer.handle(.settled(token: next, live: set, busy: true), triggers: triggers)
        try #require(reducer.isApplying && reducer.isWaiting)
        #expect(reducer.handle(.userInput, triggers: triggers)
            == [.cancel(fires: [.init(layoutFile: "desk.json", liveIndex: 0)], applying: true)])
        #expect(!reducer.isApplying && !reducer.isWaiting)
        #expect(reducer.handle(.applyFinished, triggers: triggers).isEmpty)
        #expect(reducer.handle(.interactionEnded, triggers: triggers).isEmpty)
        #expect(reducer.handle(.settled(token: next, live: set, busy: false), triggers: triggers).isEmpty)
        #expect(reducer.handle(.displaysChanged(set), triggers: triggers).isEmpty)
        #expect(reducer.handle(.userInput, triggers: triggers).isEmpty)
    }

    @Test func inputWithNothingPendingDoesNothing() {
        var reducer = DisplayTriggerReducer(initial: [laptop])
        #expect(reducer.handle(.userInput, triggers: [trigger(on: [desk, laptop])]).isEmpty)
    }

    @Test func aLockCancelsTheActiveApplyButKeepsTheUnusedReconnect() throws {
        var reducer = DisplayTriggerReducer(initial: [laptop])
        let set = [desk, laptop]
        let triggers = [trigger(on: set)]
        let first = try #require(settle(reducer.handle(.displaysChanged(set), triggers: triggers)))
        _ = reducer.handle(.settled(token: first, live: set, busy: false), triggers: triggers)
        _ = reducer.handle(.displaysChanged([laptop]), triggers: triggers)
        let next = try #require(settle(reducer.handle(.displaysChanged(set), triggers: triggers)))
        _ = reducer.handle(.settled(token: next, live: set, busy: true), triggers: triggers)
        #expect(reducer.handle(.locked, triggers: triggers).count == 1)
        #expect(!reducer.isApplying && reducer.isAwaitingUnlock && reducer.isLocked)
        #expect(reducer.handle(.applyFinished, triggers: triggers).isEmpty)
        #expect(reducer.handle(.settled(token: next, live: set, busy: false), triggers: triggers).isEmpty)
        let fresh = try #require(settle(reducer.handle(.unlocked, triggers: triggers)))
        #expect(fresh != next)
        #expect(reducer.handle(.settled(token: fresh, live: set, busy: false), triggers: triggers)
            == [.apply(fires: [.init(layoutFile: "desk.json", liveIndex: 0)], offers: [])])
    }

    @Test func aDragPostponesTheApplyAndTheEndOfTheDragResumesIt() {
        var reducer = DisplayTriggerReducer(initial: [laptop])
        let triggers = [trigger(on: [desk, laptop])]
        let first = settle(reducer.handle(.displaysChanged([desk, laptop]), triggers: triggers))!
        #expect(reducer.handle(.settled(token: first, live: [desk, laptop], busy: true), triggers: triggers).isEmpty)
        #expect(reducer.isWaiting)
        let second = settle(reducer.handle(.interactionEnded, triggers: triggers))
        #expect(second != nil && second != first)
        #expect(reducer.handle(.settled(token: second!, live: [desk, laptop], busy: false), triggers: triggers).count == 1)
        // Nothing postponed: the end of an interaction is ignored.
        #expect(reducer.handle(.interactionEnded, triggers: triggers).isEmpty)
    }

    @Test func aSetChangeDuringAnApplyWaitsForTheApplyToFinish() {
        var reducer = DisplayTriggerReducer(initial: [laptop])
        let triggers = [trigger("desk.json", on: [desk, laptop]), trigger("tv.json", on: [laptop, display("TV", serial: 7, x: 3000)])]
        let token = settle(reducer.handle(.displaysChanged([desk, laptop]), triggers: triggers))!
        _ = reducer.handle(.settled(token: token, live: [desk, laptop], busy: false), triggers: triggers)
        let tvSet = [laptop, display("TV", serial: 7, x: 3000)]
        let next = settle(reducer.handle(.displaysChanged(tvSet), triggers: triggers))!
        #expect(reducer.handle(.settled(token: next, live: tvSet, busy: true), triggers: triggers).isEmpty)
        #expect(settle(reducer.handle(.applyFinished, triggers: triggers)) != nil)
    }
}

@Suite struct DisplaySettleDetectorTests {
    private let a = WindowID(rawValue: "a"), b = WindowID(rawValue: "b")
    private func frame(_ x: Double) -> BTRect { BTRect(x: x, y: 0, width: 400, height: 300) }

    @Test func twoObservationsWithoutAChangeAreQuiet() {
        var detector = DisplaySettleDetector()
        #expect(detector.observe([a: frame(0)], at: 0) == .waiting)
        #expect(detector.observe([a: frame(0)], at: 0.15) == .quiet)
    }

    @Test func aTooShortGapIsNotQuiet() {
        var detector = DisplaySettleDetector()
        _ = detector.observe([a: frame(0)], at: 0)
        #expect(detector.observe([a: frame(0)], at: 0.05) == .waiting)
        #expect(detector.observe([a: frame(0)], at: 0.16) == .quiet)
    }

    @Test func aMovingWindowRestartsTheQuietClock() {
        var detector = DisplaySettleDetector()
        _ = detector.observe([a: frame(0)], at: 0)
        #expect(detector.observe([a: frame(40)], at: 0.15) == .waiting)
        #expect(detector.observe([a: frame(40)], at: 0.30) == .quiet)
    }

    @Test func aWindowThatAppearsOrLeavesCountsAsMoving() {
        var detector = DisplaySettleDetector()
        _ = detector.observe([a: frame(0)], at: 0)
        #expect(detector.observe([a: frame(0), b: frame(500)], at: 0.15) == .waiting)
        #expect(detector.observe([b: frame(500)], at: 0.30) == .waiting)
        #expect(detector.observe([b: frame(500)], at: 0.45) == .quiet)
    }

    @Test func aSubPointChangeIsQuiet() {
        var detector = DisplaySettleDetector()
        _ = detector.observe([a: frame(0)], at: 0)
        #expect(detector.observe([a: frame(0.4)], at: 0.15) == .quiet)
    }

    @Test func afterTheLimitItNamesTheWindowsThatStillMoved() {
        var detector = DisplaySettleDetector(quietInterval: 0.15, limit: 1)
        _ = detector.observe([a: frame(0), b: frame(500)], at: 0)
        var time = 0.0, x = 0.0
        var outcome = DisplaySettleDetector.Outcome.waiting
        while case .waiting = outcome {
            time += 0.15; x += 30
            outcome = detector.observe([a: frame(x), b: frame(500)], at: time)
        }
        #expect(outcome == .timedOut(moving: [a]))
        #expect(time >= 1)
    }
}
