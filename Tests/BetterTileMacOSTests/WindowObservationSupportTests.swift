import AppKit
@preconcurrency import ApplicationServices
import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

@Test func provisionalWindowIdentityBindsExactIDWithoutChangingCoreID() throws {
    var registry = WindowIdentityRegistry()
    let application = ApplicationLaunchInstance(processIdentifier: 42, generation: 1)

    let provisional = registry.resolve(
        application: application,
        accessibilityHash: 100,
        exactWindowID: nil
    )
    let bound = registry.resolve(
        application: application,
        accessibilityHash: 100,
        exactWindowID: 700
    )
    let refreshedElement = registry.resolve(
        application: application,
        accessibilityHash: 101,
        exactWindowID: 700
    )

    #expect(bound == provisional)
    #expect(refreshedElement == provisional)
    #expect(registry.exactWindowID(for: provisional) == 700)
    #expect(registry.windowID(application: application, accessibilityHash: 101) == provisional)
}

@Test func processAndCGWindowIDReuseCannotInheritOldIdentity() {
    var registry = WindowIdentityRegistry()
    let firstLaunch = ApplicationLaunchInstance(processIdentifier: 42, generation: 1)
    let secondLaunch = ApplicationLaunchInstance(processIdentifier: 42, generation: 2)
    let first = registry.resolve(
        application: firstLaunch,
        accessibilityHash: 100,
        exactWindowID: 700
    )
    let second = registry.resolve(
        application: secondLaunch,
        accessibilityHash: 100,
        exactWindowID: 700
    )
    #expect(first != second)

    registry.remove(first)
    let reused = registry.resolve(
        application: firstLaunch,
        accessibilityHash: 200,
        exactWindowID: 700
    )
    #expect(reused != first)
}

@Test func exactWindowServerJoinDoesNotAcceptOverlappingSameAppFallback() {
    let frame = BTRect(x: 100, y: 100, width: 600, height: 400)
    let displayID = DisplayID(rawValue: "main")
    let window = WindowSnapshot(
        id: WindowID(rawValue: "behind"),
        processIdentifier: 42,
        frame: frame,
        displayID: displayID
    )
    let index = WindowServerIndex(records: [
        WindowServerRecord(
            windowID: 10,
            processIdentifier: 42,
            layer: 0,
            frame: frame,
            isOnscreen: true
        ),
        WindowServerRecord(
            windowID: 20,
            processIdentifier: 42,
            layer: 0,
            frame: frame,
            isOnscreen: false
        ),
    ])

    #expect(index.contains(window, exactWindowID: nil))
    #expect(!index.contains(window, exactWindowID: 20))
    #expect(index.contains(window, exactWindowID: 10))
}

@Test func targetedSnapshotCacheMergesOnlyCompleteRefreshes() throws {
    let displayID = DisplayID(rawValue: "main")
    let first = WindowSnapshot(
        id: WindowID(rawValue: "first"),
        processIdentifier: 1,
        frame: BTRect(x: 0, y: 0, width: 400, height: 400),
        displayID: displayID
    )
    let second = WindowSnapshot(
        id: WindowID(rawValue: "second"),
        processIdentifier: 2,
        frame: BTRect(x: 400, y: 0, width: 400, height: 400),
        displayID: displayID
    )
    var cache = WindowSnapshotCache()
    cache.recordFullSweep([first, second])

    var moved = first
    moved.frame = moved.frame.offsetBy(dx: 20, dy: 0)
    let mergeResult = cache.merge([moved], expectedWindowIDs: [first.id])
    let merged = try #require(mergeResult)
    #expect(merged.first(where: { $0.id == first.id })?.frame == moved.frame)
    #expect(merged.contains(where: { $0.id == second.id }))

    #expect(cache.merge([], expectedWindowIDs: [second.id]) == nil)
    #expect(cache.snapshots == nil)
}

@Test func privateMinimumSizesAreValidatedAndMergedByGreatestDimension() {
    let result = MinimumSizeHintValidator.merged(
        defaultSize: BTSize(width: 120, height: 80),
        hints: [
            BTSize(width: 300, height: 100),
            BTSize(width: 200, height: 240),
            BTSize(width: .nan, height: 100),
            BTSize(width: -1, height: 100),
            BTSize(width: 2_000, height: 100),
        ],
        displaySize: BTSize(width: 1_000, height: 800)
    )
    #expect(result == BTSize(width: 300, height: 240))
}

@Test func onlyClearDialogAndFloatingSubrolesFloatAutomatically() {
    #expect(WindowFloatingClassifier.isFloating(subrole: kAXDialogSubrole))
    #expect(WindowFloatingClassifier.isFloating(subrole: kAXSystemDialogSubrole))
    #expect(WindowFloatingClassifier.isFloating(subrole: kAXFloatingWindowSubrole))
    #expect(WindowFloatingClassifier.isFloating(subrole: kAXSystemFloatingWindowSubrole))
    #expect(!WindowFloatingClassifier.isFloating(subrole: kAXStandardWindowSubrole))
    #expect(!WindowFloatingClassifier.isFloating(subrole: nil))
}

@Test @MainActor func privateWindowIdentityKillSwitchMakesResolverUnavailable() {
    #expect(!ExactWindowIDResolver(disabled: true).isAvailable)
}

@Test func malformedRequiredBatchValueRequestsIndividualFallback() throws {
    var point = CGPoint(x: 100, y: 100)
    var size = CGSize(width: 600, height: 400)
    var minimum = CGSize(width: 300, height: 200)
    let pointValue = try #require(AXValueCreate(.cgPoint, &point))
    let sizeValue = try #require(AXValueCreate(.cgSize, &size))
    let minimumValue = try #require(AXValueCreate(.cgSize, &minimum))
    let values: [Any] = [
        kAXWindowRole,
        pointValue,
        sizeValue,
        false,
        false,
        "Window",
        kAXStandardWindowSubrole,
        minimumValue,
        NSNull(),
    ]

    let parsed = try #require(
        AccessibilityWindowSystem.parsedBatchedSnapshotAttributes(values)
    )
    #expect(parsed.minimumSizes == [BTSize(width: 300, height: 200)])

    var malformed = values
    malformed[2] = "not a size"
    #expect(AccessibilityWindowSystem.parsedBatchedSnapshotAttributes(malformed) == nil)
}
