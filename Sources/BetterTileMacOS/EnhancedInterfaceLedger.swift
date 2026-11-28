@preconcurrency import ApplicationServices
import BetterTileCore

/// The Accessibility calls that switch an application's `AXEnhancedUserInterface` off before
/// BetterTile writes its window frames and back on afterwards. `AccessibilityWindowSystem`
/// makes them live; tests use a fake.
@MainActor protocol EnhancedInterfaceAccess {
    associatedtype Application

    func application(for pid: pid_t) -> Application
    /// Reads the attribute through the unresponsive-application gate. An unanswered read is off.
    func isEnhanced(_ application: Application) -> Bool
    /// Writes the attribute with the frame-write messaging timeout. A gated write fails at once
    /// with `.cannotComplete` while the application is held as unresponsive.
    func write(_ isEnabled: Bool, to application: Application, gated: Bool) -> AXError
    func report(_ failure: EnhancedInterfaceFailure, _ error: AXError)
}

enum EnhancedInterfaceFailure: Equatable {
    case switchOff
    case switchOn
}

/// Which applications have `AXEnhancedUserInterface` switched off for the current frame-write
/// batch, and which still wait to have it switched back on.
@MainActor struct EnhancedInterfaceLedger<Application> {
    /// One application's state for a batch: the application written to, nil when the attribute
    /// was left alone, and whether it is owed a switch back on. A switch back on is owed only when
    /// the policy asks for one and the switch-off succeeded. After a failed switch-off the
    /// application is kept, but nothing is owed.
    struct Hold {
        let pid: pid_t
        let application: Application?
        let owesRestore: Bool

        static func untouched(_ pid: pid_t) -> Hold {
            Hold(pid: pid, application: nil, owesRestore: false)
        }
    }

    /// Nil outside a batch. Outside a batch every hold is settled right after its write.
    private var batch: [pid_t: Hold]?
    /// Switches back on that the application could not answer yet, by process.
    private(set) var waiting: [pid_t: Hold] = [:]

    var isBatching: Bool { batch != nil }

    mutating func openBatch() {
        batch = [:]
    }

    /// Ends the batch and switches every application it holds back on.
    mutating func closeBatch<Access: EnhancedInterfaceAccess>(using access: Access)
    where Access.Application == Application {
        let held = batch ?? [:]
        batch = nil
        for hold in held.values { settle(hold, using: access) }
    }

    /// Switches the attribute off before a frame write when the policy and the application's
    /// current value call for it. Within a batch each process is asked once; later writes reuse
    /// its hold. A failed switch-off is reported and the frame write goes ahead.
    mutating func suspend<Access: EnhancedInterfaceAccess>(
        pid: pid_t,
        policy: EnhancedUserInterfacePolicy,
        using access: Access
    ) -> Hold where Access.Application == Application {
        if let existing = batch?[pid] { return existing }
        let application = access.application(for: pid)
        let decision = EnhancedUserInterfaceCoordinator.decision(
            policy: policy,
            isCurrentlyEnabled: access.isEnhanced(application)
        )
        var hold = Hold.untouched(pid)
        if decision.shouldDisableBeforeWrite {
            let error = access.write(false, to: application, gated: false)
            if error != .success { access.report(.switchOff, error) }
            hold = Hold(
                pid: pid,
                application: application,
                owesRestore: decision.shouldRestoreAfterWrite && error == .success
            )
        }
        batch?[pid] = hold
        return hold
    }

    /// Switches one hold back on. One whose application could not answer waits for a retry.
    mutating func settle<Access: EnhancedInterfaceAccess>(_ hold: Hold, using access: Access)
    where Access.Application == Application {
        if !Self.switchBackOn(hold, using: access) { waiting[hold.pid] = hold }
    }

    /// Retries every waiting switch back on whose process still runs, through the gate. One that
    /// still cannot answer keeps waiting; one whose process quit is dropped.
    mutating func retryWaiting<Access: EnhancedInterfaceAccess>(
        running: () -> Set<pid_t>,
        using access: Access
    ) where Access.Application == Application {
        guard !waiting.isEmpty else { return }
        let alive = running()
        let retries = waiting.filter { alive.contains($0.key) }
        waiting = [:]
        for hold in retries.values { settle(hold, using: access) }
    }

    /// The last try before BetterTile quits, without the gate, because no later write will retry.
    /// A process that quit is dropped. A write that fails is reported and keeps waiting.
    mutating func switchBackOnBeforeQuit<Access: EnhancedInterfaceAccess>(
        running: () -> Set<pid_t>,
        using access: Access
    ) where Access.Application == Application {
        guard !waiting.isEmpty else { return }
        let alive = running()
        waiting = waiting.filter { pid, hold in
            guard alive.contains(pid), hold.owesRestore, let application = hold.application else { return false }
            let error = access.write(true, to: application, gated: false)
            guard error != .success else { return false }
            access.report(.switchOn, error)
            return true
        }
    }

    /// False only when the application could not answer. Any other failure is reported and counts
    /// as done, because failing here would undo a placement that already landed.
    private static func switchBackOn<Access: EnhancedInterfaceAccess>(_ hold: Hold, using access: Access) -> Bool
    where Access.Application == Application {
        guard hold.owesRestore, let application = hold.application else { return true }
        let error = access.write(true, to: application, gated: true)
        if error == .success { return true }
        if error == .cannotComplete { return false }
        access.report(.switchOn, error)
        return true
    }
}
