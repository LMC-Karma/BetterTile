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
