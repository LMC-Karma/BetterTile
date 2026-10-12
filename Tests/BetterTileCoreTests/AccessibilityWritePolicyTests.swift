import Foundation
import Testing
@testable import BetterTileCore

// MARK: - Enhanced accessibility

@Test func enhancedUserInterfaceIsNeverTouchedWhenTheApplicationHadItOff() {
    for policy in EnhancedUserInterfacePolicy.allCases {
        let decision = EnhancedUserInterfaceCoordinator.decision(
            policy: policy,
            isCurrentlyEnabled: false
        )
        #expect(decision == .untouched)
    }
}

@Test func enhancedUserInterfaceIsDisabledAndRestoredByDefault() {
    let decision = EnhancedUserInterfaceCoordinator.decision(
        policy: .disableAndRestore,
        isCurrentlyEnabled: true
    )
    #expect(decision.shouldDisableBeforeWrite)
    #expect(decision.shouldRestoreAfterWrite)
}

@Test func disableOnlyPolicyLeavesEnhancedUserInterfaceOff() {
    let decision = EnhancedUserInterfaceCoordinator.decision(
        policy: .disableOnly,
        isCurrentlyEnabled: true
    )
    #expect(decision.shouldDisableBeforeWrite)
    #expect(!decision.shouldRestoreAfterWrite)
}

// MARK: - Frame write planning

private let target = BTRect(x: 100, y: 100, width: 600, height: 400)

@Test func anUnknownCurrentFrameKeepsTheFullWriteSequence() {
    let plan = FrameWritePlanner.plan(target: target, knownCurrentFrame: nil)
    #expect(plan.writesInitialSize)
    #expect(plan.writesPosition)
    #expect(plan.writesFinalSize)
    #expect(plan.writeCount == 3)
}

@Test func aResizeKeepsTheFullWriteSequence() {
    let plan = FrameWritePlanner.plan(
        target: target,
        knownCurrentFrame: BTRect(x: 100, y: 100, width: 500, height: 400)
    )
    #expect(plan.writeCount == 3)
}

@Test func aPureMoveSkipsTheLeadingSizeWrite() {
    let plan = FrameWritePlanner.plan(
        target: target,
        knownCurrentFrame: BTRect(x: 0, y: 0, width: 600, height: 400)
    )
    #expect(!plan.writesInitialSize)
    #expect(plan.writesPosition)
    // The trailing write still corrects an application that clamped while the
    // position changed, so it is never skipped.
    #expect(plan.writesFinalSize)
    #expect(plan.writeCount == 2)
}

@Test func subPointSizeDriftStillCountsAsAPureMove() {
    let plan = FrameWritePlanner.plan(
        target: target,
        knownCurrentFrame: BTRect(x: 0, y: 0, width: 600.4, height: 399.7)
    )
    #expect(!plan.writesInitialSize)
    #expect(plan.writeCount == 2)
}

@Test func aSizeChangeJustBeyondToleranceKeepsTheLeadingWrite() {
    let plan = FrameWritePlanner.plan(
        target: target,
        knownCurrentFrame: BTRect(x: 100, y: 100, width: 600.6, height: 400)
    )
    #expect(plan.writesInitialSize)
    #expect(plan.writeCount == 3)
}

@Test func aFullyUnchangedFrameStillWritesPositionAndSize() {
    // Deliberate: the caller's reading can be stale, and the write is what
    // corrects it. Dropping to zero writes needs read-back verification.
    let plan = FrameWritePlanner.plan(target: target, knownCurrentFrame: target)
    #expect(!plan.writesInitialSize)
    #expect(plan.writeCount == 2)
}

// MARK: - Configuration

@Test func enhancedUserInterfacePolicyDefaultsToRestoreAndSurvivesARoundTrip() throws {
    #expect(BetterTileConfiguration().enhancedUserInterfacePolicy == .disableAndRestore)

    var configuration = BetterTileConfiguration()
    configuration.enhancedUserInterfacePolicy = .disableOnly
    let data = try JSONEncoder().encode(configuration)
    let decoded = try JSONDecoder().decode(BetterTileConfiguration.self, from: data)
    #expect(decoded.enhancedUserInterfacePolicy == .disableOnly)
}

@Test func configurationFilesWithoutTheKeyDecodeToTheSafeDefault() throws {
    let json = Data(#"{"schemaVersion":8}"#.utf8)
    let decoded = try JSONDecoder().decode(BetterTileConfiguration.self, from: json)
    #expect(decoded.enhancedUserInterfacePolicy == .disableAndRestore)
}

@Test func changingTheEnhancedUserInterfacePolicyIsARuntimeChange() {
    var updated = BetterTileConfiguration()
    updated.enhancedUserInterfacePolicy = .disableOnly
    let changes = ConfigurationChangeSet.between(BetterTileConfiguration(), updated)
    #expect(changes.contains(.accessibilityWrites))
}

@Test func intermediateGestureSamplesSkipTheClampCorrectingSizeWrite() {
    let target = BTRect(x: 10, y: 20, width: 300, height: 200)
    let changing = FrameWritePlanner.plan(
        target: target,
        knownCurrentFrame: BTRect(x: 0, y: 20, width: 310, height: 200),
        correctsClamping: false
    )
    #expect(changing == FrameWritePlan(writesInitialSize: true, writesPosition: true, writesFinalSize: false))
    let unknown = FrameWritePlanner.plan(target: target, knownCurrentFrame: nil, correctsClamping: false)
    #expect(unknown.writeCount == 2)
}

@Test func clampConfirmationRunsOnlyForANewClamp() {
    let requested = BTRect(x: 100, y: 50, width: 200, height: 150)
    let clamped = BTRect(x: 100, y: 50, width: 300, height: 150)
    // An unexplained clamp is confirmed.
    #expect(WriteReadbackPolicy.confirmsClamp(requested: requested, actual: clamped,
                                              learnedMinimum: nil))
    #expect(WriteReadbackPolicy.confirmsClamp(requested: requested, actual: clamped,
                                              learnedMinimum: BTSize(width: 250, height: 0)))
    // A clamp the learned minimum already explains needs no nudge.
    #expect(!WriteReadbackPolicy.confirmsClamp(requested: requested, actual: clamped,
                                               learnedMinimum: BTSize(width: 300, height: 0)))
    // A new clamp on the other axis is still confirmed.
    let taller = BTRect(x: 100, y: 50, width: 300, height: 240)
    #expect(WriteReadbackPolicy.confirmsClamp(requested: requested, actual: taller,
                                              learnedMinimum: BTSize(width: 300, height: 0)))
    // A window that moved away from the requested origin is not a clamp.
    #expect(!WriteReadbackPolicy.confirmsClamp(requested: requested, actual: clamped.offsetBy(dx: 40, dy: 0),
                                               learnedMinimum: nil))
    // A window that took the requested size is not a clamp.
    #expect(!WriteReadbackPolicy.confirmsClamp(requested: requested, actual: requested,
                                               learnedMinimum: nil))
}
