import ApplicationServices
import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

/// Applications with an `AXEnhancedUserInterface` value each, standing in for live Accessibility.
@MainActor private final class FakeEnhancedApplications: EnhancedInterfaceAccess {
    struct Write: Equatable {
        let pid: pid_t
        let isEnabled: Bool
        let gated: Bool
    }

    var attribute: [pid_t: Bool]
    /// The answer for each write to a process, in order; a process without one succeeds.
    var switchOffErrors: [pid_t: [AXError]] = [:]
    var switchOnErrors: [pid_t: [AXError]] = [:]
    private(set) var writes: [Write] = []
    private(set) var reports: [EnhancedInterfaceFailure] = []

    init(_ attribute: [pid_t: Bool]) { self.attribute = attribute }

    func application(for pid: pid_t) -> pid_t { pid }

    func isEnhanced(_ application: pid_t) -> Bool { attribute[application] ?? false }

    func write(_ isEnabled: Bool, to application: pid_t, gated: Bool) -> AXError {
        writes.append(Write(pid: application, isEnabled: isEnabled, gated: gated))
        let error: AXError
        if isEnabled, var queued = switchOnErrors[application], !queued.isEmpty {
            error = queued.removeFirst()
            switchOnErrors[application] = queued
        } else if !isEnabled, var queued = switchOffErrors[application], !queued.isEmpty {
            error = queued.removeFirst()
            switchOffErrors[application] = queued
        } else {
            error = .success
        }
        if error == .success { attribute[application] = isEnabled }
        return error
    }

    func report(_ failure: EnhancedInterfaceFailure, _ error: AXError) { reports.append(failure) }

    func writes(to pid: pid_t) -> [Write] { writes.filter { $0.pid == pid } }
}

private typealias Ledger = EnhancedInterfaceLedger<pid_t>

@MainActor @Suite struct EnhancedInterfaceLedgerTests {
    @Test func aBatchSwitchesEachApplicationOffOnceAndBackOnAtTheEnd() {
        let apps = FakeEnhancedApplications([10: true, 11: true, 12: false])
        var ledger = Ledger()
        ledger.openBatch()
        for pid: pid_t in [10, 11, 12, 10, 11] {
            _ = ledger.suspend(pid: pid, policy: .disableAndRestore, using: apps)
        }
        #expect(apps.attribute == [10: false, 11: false, 12: false])
        #expect(apps.writes(to: 10) == [.init(pid: 10, isEnabled: false, gated: false)])
        #expect(apps.writes(to: 12).isEmpty, "An application without the attribute on is never written")

        ledger.closeBatch(using: apps)
        #expect(apps.attribute == [10: true, 11: true, 12: false])
        #expect(apps.writes(to: 11).last == .init(pid: 11, isEnabled: true, gated: true))
        #expect(apps.writes(to: 12).isEmpty)
        #expect(ledger.waiting.isEmpty && apps.reports.isEmpty && !ledger.isBatching)
    }

    @Test func aWriteOutsideABatchIsSwitchedBackOnRightAway() {
        let apps = FakeEnhancedApplications([10: true])
        var ledger = Ledger()
        let hold = ledger.suspend(pid: 10, policy: .disableAndRestore, using: apps)
        #expect(apps.attribute[10] == false)
        ledger.settle(hold, using: apps)
        #expect(apps.attribute[10] == true)
        // Nothing is remembered between unbatched writes: the next one reads and writes again.
        _ = ledger.suspend(pid: 10, policy: .disableAndRestore, using: apps)
        #expect(apps.writes(to: 10).count == 3)
    }

    @Test func leaveDisabledNeverSwitchesBackOn() {
        let apps = FakeEnhancedApplications([10: true])
        var ledger = Ledger()
        ledger.openBatch()
        let hold = ledger.suspend(pid: 10, policy: .disableOnly, using: apps)
        ledger.closeBatch(using: apps)
        #expect(!hold.owesRestore)
        #expect(apps.attribute[10] == false)
        #expect(apps.writes(to: 10).count == 1)
    }

    @Test func aFailedSwitchOffIsReportedAndOwesNoSwitchBackOn() {
        let apps = FakeEnhancedApplications([10: true])
        apps.switchOffErrors[10] = [.failure]
        var ledger = Ledger()
        ledger.openBatch()
        let hold = ledger.suspend(pid: 10, policy: .disableAndRestore, using: apps)
        ledger.closeBatch(using: apps)
        #expect(hold.application == 10 && !hold.owesRestore)
        #expect(apps.reports == [.switchOff])
        #expect(apps.attribute[10] == true, "The attribute was never changed")
        #expect(apps.writes(to: 10).count == 1, "No switch back on is attempted")
    }

    @Test func anApplicationThatCannotAnswerWaitsAndIsSwitchedBackOnInTheNextBatch() {
        let apps = FakeEnhancedApplications([10: true, 11: true])
        apps.switchOnErrors[11] = [.cannotComplete]
        var ledger = Ledger()
        ledger.openBatch()
        _ = ledger.suspend(pid: 10, policy: .disableAndRestore, using: apps)
        _ = ledger.suspend(pid: 11, policy: .disableAndRestore, using: apps)
        ledger.closeBatch(using: apps)
        #expect(apps.attribute == [10: true, 11: false])
        #expect(Set(ledger.waiting.keys) == [11])
        #expect(apps.reports.isEmpty, "Waiting is not a failure")

        ledger.retryWaiting(running: { [10, 11] }, using: apps)
        #expect(apps.attribute == [10: true, 11: true])
        #expect(ledger.waiting.isEmpty)
        #expect(apps.writes(to: 11).filter { $0.isEnabled }.allSatisfy { $0.gated })
    }

    @Test func anyOtherSwitchBackOnFailureIsReportedAndCountsAsDone() {
        let apps = FakeEnhancedApplications([10: true, 11: true])
        apps.switchOnErrors[11] = [.failure]
        var ledger = Ledger()
        ledger.openBatch()
        _ = ledger.suspend(pid: 10, policy: .disableAndRestore, using: apps)
        _ = ledger.suspend(pid: 11, policy: .disableAndRestore, using: apps)
        ledger.closeBatch(using: apps)
        #expect(apps.attribute == [10: true, 11: false])
        #expect(apps.reports == [.switchOn])
        #expect(ledger.waiting.isEmpty)
        ledger.retryWaiting(running: { [10, 11] }, using: apps)
        #expect(apps.writes(to: 11).count == 2, "A failure other than no answer is not retried")
    }

    @Test func aWaitingApplicationThatQuitIsDropped() {
        let apps = FakeEnhancedApplications([10: true])
        apps.switchOnErrors[10] = [.cannotComplete]
        var ledger = Ledger()
        ledger.openBatch()
        _ = ledger.suspend(pid: 10, policy: .disableAndRestore, using: apps)
        ledger.closeBatch(using: apps)
        ledger.retryWaiting(running: { [] }, using: apps)
        #expect(ledger.waiting.isEmpty)
        #expect(apps.writes(to: 10).count == 2, "No write to a process that quit")
    }

    @Test func beforeQuitEveryWaitingApplicationIsTriedOnceMoreWithoutTheGate() {
        let apps = FakeEnhancedApplications([10: true, 11: true, 12: true])
        apps.switchOnErrors = [10: [.cannotComplete], 11: [.cannotComplete, .failure], 12: [.cannotComplete]]
        var ledger = Ledger()
        ledger.openBatch()
        for pid: pid_t in [10, 11, 12] { _ = ledger.suspend(pid: pid, policy: .disableAndRestore, using: apps) }
        ledger.closeBatch(using: apps)
        #expect(Set(ledger.waiting.keys) == [10, 11, 12])

        // 12 quit; 10 answers; 11 fails again and keeps waiting.
        ledger.switchBackOnBeforeQuit(running: { [10, 11] }, using: apps)
        #expect(apps.attribute == [10: true, 11: false, 12: false])
        #expect(Set(ledger.waiting.keys) == [11])
        #expect(apps.reports == [.switchOn])
        #expect(apps.writes(to: 10).last == .init(pid: 10, isEnabled: true, gated: false))
        #expect(apps.writes(to: 12).count == 2)
    }
}
