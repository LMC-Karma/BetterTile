// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma

import Foundation

/// One layout that the trigger reducer wants to apply. `liveIndex` is the index of the target display in
/// the live display set that the reducer was given.
public struct DisplayTriggerFire: Equatable, Sendable {
    public var layoutFile: String
    public var liveIndex: Int
    public init(layoutFile: String, liveIndex: Int) { self.layoutFile = layoutFile; self.liveIndex = liveIndex }
}

public enum DisplayTriggerEvent: Equatable, Sendable {
    /// The display set may have changed. Sent after the display-refresh debounce.
    case displaysChanged([DisplayFingerprint])
    /// The Mac or its displays went to sleep. Arms one wake Apply and holds display changes until wake.
    case sleep
    /// The Mac or its displays woke up. The set may be unchanged. It acts once for each `.sleep`.
    case wake([DisplayFingerprint])
    /// The lock screen is up. Nothing applies until `.unlocked`.
    case locked
    /// Another app became active, or the session became active. The lock screen is gone.
    case unlocked
    /// The lock lasted too long. The attempt that waited for it is dropped, without a pill.
    case lockExpired
    /// The settle wait for `token` ended. `busy` is true when the user is dragging, so the Apply waits.
    case settled(token: Int, live: [DisplayFingerprint], busy: Bool)
    /// The drag, divider drag, or Layout Wheel that postponed the Apply ended.
    case interactionEnded
    /// A mouse button or key was pressed.
    case userInput
    /// The Apply started by `.apply` ended, finished or not.
    case applyFinished
}

public enum DisplayTriggerAction: Equatable, Sendable {
    /// Start, or restart, the settle wait for `token`. A wait with an older token is stale.
    case settle(token: Int)
    /// Apply each fire in order, on its own display. `offers` are uncertain matches: they never apply on
    /// their own, and the user is asked instead.
    case apply(fires: [DisplayTriggerFire], offers: [DisplayTriggerFire])
    /// The user pressed a button or key during the wait or the Apply. Stop it and offer a manual Apply.
    case cancel(fires: [DisplayTriggerFire], applying: Bool)
    /// Invalidate the active Apply for a lock/session hold. Keep any unused pending attempt for unlock.
    case suspendApply
}

/// Decides when a Saved Layout applies by itself. Pure: events in, actions out.
///
/// - A set that differs from the last known set starts one wait. The same set again (a resolution change,
///   a repeated reconfiguration) starts none, and an attempt is used up when it is handed out.
/// - Only an exact match of an enabled trigger applies. An uncertain match becomes an offer.
/// - A wake with an unchanged set applies only triggers with "Also after wake", and only once for each sleep:
///   a second wake notification for the same sleep does nothing. Display changes that arrive during sleep are
///   held, so they fold into the one wake Apply.
/// - While the lock screen is up the attempt stays pending, unused, until `.unlocked`. A different display set
///   drops it, and so does `.lockExpired`.
public struct DisplayTriggerReducer: Sendable {
    private enum Reason { case displaysChanged, wakeOnly }

    private struct Pending {
        var reason: Reason
        var token: Int
        var postponed = false
        var awaitingUnlock = false
        var preview: [DisplayTriggerFire]
    }

    private var knownKey: String
    private var pending: Pending?
    private var applying: [DisplayTriggerFire]?
    private var nextToken = 0
    private var asleep = false
    /// Set by a sleep, cleared by the first wake after it.
    private var wakeArmed = false
    private var screenLocked = false
    /// A connect that sleep interrupted before its Apply. The next wake applies it, switch or no switch.
    private var interruptedConnect = false

    /// `initial` is the display set when BetterTile starts. Starting is not a trigger.
    public init(initial: [DisplayFingerprint]) { knownKey = Self.key(initial) }

    public var isWaiting: Bool { pending != nil }
    public var isLocked: Bool { screenLocked }
    public var isAwaitingUnlock: Bool { pending?.awaitingUnlock == true }
    public var isApplying: Bool { applying != nil }
    public var currentToken: Int? { pending?.token }

    /// The identity of a display set: the sorted UUIDs. Resolution and arrangement are not part of it.
    public static func key(_ live: [DisplayFingerprint]) -> String {
        live.map { $0.uuid.lowercased() }.sorted().joined(separator: "|")
    }

    public mutating func handle(_ event: DisplayTriggerEvent, triggers: [DisplayTrigger]) -> [DisplayTriggerAction] {
        switch event {
        case let .displaysChanged(live):
            // Held until wake: the wake judges the set as it is then.
            return asleep ? [] : changed(live, reason: .displaysChanged, triggers: triggers)
        case .sleep:
            asleep = true
            wakeArmed = true
            // A wait that was running is stale after sleep. A connect among them still happened, so the
            // wake applies it once. A wake-only wait is not kept: the next wake is armed again.
            interruptedConnect = interruptedConnect || pending?.reason == .displaysChanged
            pending = nil
            return []
        case let .wake(live):
            asleep = false
            let armed = wakeArmed
            wakeArmed = false
            let interrupted = interruptedConnect
            interruptedConnect = false
            if Self.key(live) != knownKey || interrupted {
                return changed(live, reason: .displaysChanged, triggers: triggers, force: interrupted)
            }
            // A second wake notification for the same sleep, or a wake that no sleep announced, does nothing.
            return armed ? changed(live, reason: .wakeOnly, triggers: triggers) : []
        case .locked:
            screenLocked = true
            let actions: [DisplayTriggerAction] = applying == nil ? [] : [.suspendApply]
            applying = nil
            guard var current = pending, !current.awaitingUnlock else { return actions }
            // Stale the running wait. The attempt stays pending.
            nextToken += 1
            current.token = nextToken
            current.awaitingUnlock = true
            pending = current
            return actions
        case .unlocked:
            screenLocked = false
            guard var current = pending, current.awaitingUnlock else { return [] }
            current.awaitingUnlock = false
            pending = current
            return restart()
        case .lockExpired:
            screenLocked = false
            if pending?.awaitingUnlock == true { pending = nil }
            return []
        case let .settled(token, live, busy): return settled(token, live, busy, triggers)
        case .interactionEnded: return resume()
        case .applyFinished:
            applying = nil
            return resume()
        case .userInput: return cancel()
        }
    }

    private mutating func changed(_ live: [DisplayFingerprint], reason: Reason, triggers: [DisplayTrigger],
                                  force: Bool = false) -> [DisplayTriggerAction] {
        let key = Self.key(live)
        if key == knownKey && reason == .displaysChanged && !force {
            // The same set again. A wait that already runs starts over, so it ends after the noise.
            return restart()
        }
        if key != knownKey {
            knownKey = key
            // A different set gives up an attempt that waited for the lock screen. The new set may wait too.
            if pending?.awaitingUnlock == true { pending = nil }
        }
        if var current = pending {
            // A change or a wake while a wait runs: one wait, not two. A real change wins over a wake.
            if reason == .displaysChanged { current.reason = .displaysChanged }
            let (fires, offers) = Self.evaluate(live, reason: current.reason, triggers: triggers)
            current.preview = fires + offers
            pending = current
            return restart()
        }
        let (fires, offers) = Self.evaluate(live, reason: reason, triggers: triggers)
        guard !(fires + offers).isEmpty else { return [] }
        nextToken += 1
        pending = Pending(reason: reason, token: nextToken, awaitingUnlock: screenLocked, preview: fires + offers)
        return screenLocked ? [] : [.settle(token: nextToken)]
    }

    private mutating func restart() -> [DisplayTriggerAction] {
        guard var current = pending else { return [] }
        nextToken += 1
        current.token = nextToken
        current.postponed = false
        pending = current
        return current.awaitingUnlock ? [] : [.settle(token: nextToken)]
    }

    private mutating func settled(_ token: Int, _ live: [DisplayFingerprint], _ busy: Bool,
                                  _ triggers: [DisplayTrigger]) -> [DisplayTriggerAction] {
        guard var current = pending, current.token == token else { return [] }
        if busy {
            current.postponed = true
            pending = current
            return []
        }
        let key = Self.key(live)
        if key != knownKey {
            // The set changed again during the wait. Judge the newest set.
            knownKey = key
            let (fires, offers) = Self.evaluate(live, reason: .displaysChanged, triggers: triggers)
            guard !(fires + offers).isEmpty else { pending = nil; return [] }
            current.reason = .displaysChanged
            current.preview = fires + offers
            pending = current
            return restart()
        }
        let (fires, offers) = Self.evaluate(live, reason: current.reason, triggers: triggers)
        pending = nil
        guard !(fires + offers).isEmpty else { return [] }
        if !fires.isEmpty { applying = fires }
        return [.apply(fires: fires, offers: offers)]
    }

    private mutating func resume() -> [DisplayTriggerAction] {
        guard let current = pending, current.postponed, !current.awaitingUnlock, applying == nil else { return [] }
        return restart()
    }

    private mutating func cancel() -> [DisplayTriggerAction] {
        // Input at the lock screen is the unlock, not a protest against the Apply.
        let wasApplying = applying != nil
        var fires = applying ?? []
        var cancelledWait = false
        if let current = pending, !current.awaitingUnlock {
            pending = nil
            cancelledWait = true
            // The reconnect may name the same layout as the active Apply.
            // Its applier supplies that result; offer each other layout only once.
            var files = Set(fires.map(\.layoutFile))
            fires += current.preview.filter { files.insert($0.layoutFile).inserted }
        }
        applying = nil
        return wasApplying || cancelledWait ? [.cancel(fires: fires, applying: wasApplying)] : []
    }

    /// Fires (exact matches that may apply) and offers (uncertain matches that may only ask), left to right.
    /// A display receives one layout. A disabled trigger does nothing.
    private static func evaluate(_ live: [DisplayFingerprint], reason: Reason,
                                 triggers: [DisplayTrigger]) -> (fires: [DisplayTriggerFire], offers: [DisplayTriggerFire]) {
        var fires: [DisplayTriggerFire] = []
        var offers: [DisplayTriggerFire] = []
        var taken = Set<Int>()
        for trigger in triggers where trigger.enabled && (reason == .displaysChanged || trigger.alsoAfterWake) {
            let match = DisplaySetMatcher.match(stored: trigger.displays, live: live)
            guard match.kind != .none, let index = match.pairs[trigger.target], taken.insert(index).inserted else { continue }
            let fire = DisplayTriggerFire(layoutFile: trigger.layoutFile, liveIndex: index)
            if match.kind == .exact { fires.append(fire) } else { offers.append(fire) }
        }
        func order(_ list: [DisplayTriggerFire]) -> [DisplayTriggerFire] {
            list.sorted { live[$0.liveIndex].frame.origin.x < live[$1.liveIndex].frame.origin.x }
        }
        return (order(fires), order(offers))
    }
}

/// Decides when the windows of a display have stopped moving after macOS restored them.
/// Feed it a window observation about every `quietInterval`. It is quiet when two observations in a row,
/// that far apart, show no frame change. After `limit` it gives up and names the windows that still moved.
public struct DisplaySettleDetector: Sendable {
    public enum Outcome: Equatable, Sendable {
        case waiting
        case quiet
        /// Windows whose frames changed in the last observation. They are skipped.
        case timedOut(moving: Set<WindowID>)
    }

    public let quietInterval: TimeInterval
    public let limit: TimeInterval
    private var started: TimeInterval?
    private var lastChange: TimeInterval = 0
    private var frames: [WindowID: BTRect] = [:]

    public init(quietInterval: TimeInterval = 0.15, limit: TimeInterval = 3) {
        self.quietInterval = quietInterval
        self.limit = limit
    }

    public mutating func observe(_ observed: [WindowID: BTRect], at time: TimeInterval) -> Outcome {
        guard let started else {
            self.started = time
            lastChange = time
            frames = observed
            return limit <= 0 ? .timedOut(moving: Set(observed.keys)) : .waiting
        }
        var moving = Set<WindowID>()
        for (id, frame) in observed where frames[id].map({ !$0.approximatelyEquals(frame, tolerance: 1) }) ?? true { moving.insert(id) }
        moving.formUnion(Set(frames.keys).subtracting(observed.keys))
        frames = observed
        if moving.isEmpty {
            // A millisecond of slack, so clock rounding does not cost a whole extra observation.
            if time - lastChange >= quietInterval - 0.001 { return .quiet }
        } else {
            lastChange = time
        }
        return time - started >= limit ? .timedOut(moving: moving) : .waiting
    }
}
