import ApplicationServices
import BetterTileCore
import Foundation
import Testing
@testable import BetterTileMacOS

@MainActor
@Test func disabledStageManagerResolverCannotObserveGroups() {
    let resolver = StageManagerGroupResolver(disabled: true)

    #expect(!resolver.isEnabled)
    #expect(resolver.observation(at: BTPoint(x: 10, y: 10)) == nil)
}

@Test func stageManagerPathRejectsAbsentOrChangedHierarchy() {
    #expect(StageManagerGroupResolver.rolePathIsValid([
        kAXGroupRole, kAXListRole, kAXButtonRole,
    ]))
    #expect(!StageManagerGroupResolver.rolePathIsValid([]))
    #expect(!StageManagerGroupResolver.rolePathIsValid([
        kAXGroupRole, kAXScrollAreaRole, kAXButtonRole,
    ]))
}

@Test func stageManagerWindowIDsRejectMalformedAttributeValues() {
    #expect(StageManagerGroupResolver.windowIDs(from: nil) == nil)
    #expect(StageManagerGroupResolver.windowIDs(from: []) == nil)
    #expect(StageManagerGroupResolver.windowIDs(from: [NSNumber(value: true)]) == nil)
    #expect(StageManagerGroupResolver.windowIDs(from: [NSNumber(value: 0)]) == nil)
    #expect(StageManagerGroupResolver.windowIDs(from: [NSNumber(value: 10.5)]) == nil)
    #expect(StageManagerGroupResolver.windowIDs(from: [NSNumber(value: 10), "20"]) == nil)
    #expect(StageManagerGroupResolver.windowIDs(from: [NSNumber(value: 10), NSNumber(value: 10)]) == nil)
    #expect(StageManagerGroupResolver.windowIDs(
        from: [NSNumber(value: 10), NSNumber(value: 20)]
    ) == [10, 20])
}

@Test func stageManagerSelectsOnlyTheFrontmostValidRealMember() {
    let managerPID: pid_t = 100
    let records = [
        stageRecord(id: 10, pid: managerPID),
        stageRecord(id: 20, pid: 200),
        stageRecord(id: 30, pid: 300),
        stageRecord(id: 40, pid: 400, layer: 1),
    ]

    let selected = StageManagerGroupResolver.frontmostValidWindowID(
        groupWindowIDs: [10, 20, 30, 40, 50],
        targetedRecords: records,
        frontToBackWindowIDs: [40, 30, 20, 10],
        rejectedOwnerPIDs: [managerPID],
        knownOwnerPIDs: [managerPID, 200, 300, 400]
    )

    #expect(selected == 30)
    #expect(selected != 20, "a peer must remain untouched when another member is frontmost")
}

@Test func stageManagerRejectsUnknownOwnersAndMissingWindowServerOrder() {
    let record = stageRecord(id: 20, pid: 200)

    #expect(StageManagerGroupResolver.frontmostValidWindowID(
        groupWindowIDs: [20],
        targetedRecords: [record],
        frontToBackWindowIDs: [20],
        rejectedOwnerPIDs: [100],
        knownOwnerPIDs: []
    ) == nil)
    #expect(StageManagerGroupResolver.frontmostValidWindowID(
        groupWindowIDs: [20],
        targetedRecords: [record],
        frontToBackWindowIDs: [],
        rejectedOwnerPIDs: [100],
        knownOwnerPIDs: [200]
    ) == nil)
}

@MainActor
@Test func windowExposureRetryResolvesWithinTheExistingBound() async {
    var attempts = 0
    let resolved = await WindowExposureRetry.run(delay: .zero) {
        attempts += 1
        return attempts == 4 ? .resolved : .retry
    }

    #expect(resolved)
    #expect(attempts == 4)
}

@MainActor
@Test func windowExposureRetryStopsAfterTwentyAttempts() async {
    var attempts = 0
    let resolved = await WindowExposureRetry.run(delay: .zero) {
        attempts += 1
        return .retry
    }

    #expect(!resolved)
    #expect(attempts == 20)
}

private func stageRecord(
    id: CGWindowID,
    pid: pid_t,
    layer: Int = 0
) -> WindowServerRecord {
    WindowServerRecord(
        windowID: id,
        processIdentifier: pid,
        layer: layer,
        frame: BTRect(x: 0, y: 0, width: 100, height: 100),
        isOnscreen: false
    )
}
