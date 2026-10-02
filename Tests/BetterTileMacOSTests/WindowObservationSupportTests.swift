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
    #expect(registry.windowID(forExactWindowID: 700) == provisional)
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

@Test(arguments: [false, true])
func offscreenWindowKeepsItsIdentityAcrossSweeps(exactIdentityAvailable: Bool) {
    var registry = WindowIdentityRegistry()
    let application = ApplicationLaunchInstance(processIdentifier: 42, generation: 1)
    let exactID: CGWindowID? = exactIdentityAvailable ? 700 : nil
    let original = registry.resolve(application: application, accessibilityHash: 100, exactWindowID: exactID)

    // The app still lists the window, but WindowServer filters it from the
    // active Space. It is no longer in the active managed/recent window sets.
    for _ in 0..<4 {
        _ = registry.removeClosedWindowsAfterSweep(observedApplications: [application: [100]], windowServer: nil)
    }
    let returning = registry.resolve(application: application, accessibilityHash: 100, exactWindowID: exactID)
    #expect(returning == original)
    #expect(registry.windowID(application: application, accessibilityHash: 100) == original)

    // A failed AX enumeration or a skipped hidden app supplies no evidence
    // that its windows closed. A successful empty list does.
    #expect(registry.removeClosedWindowsAfterSweep(observedApplications: [:], windowServer: nil).isEmpty)
    #expect(registry.removeClosedWindowsAfterSweep(observedApplications: [application: []], windowServer: nil).isEmpty)
    let pruned = registry.removeClosedWindowsAfterSweep(
        observedApplications: [application: []],
        windowServer: WindowServerIndex(records: [])
    )
    if exactIdentityAvailable {
        #expect(pruned.map(\.windowID) == [original])
    } else {
        #expect(pruned.isEmpty)
        // The public identity fallback waits for destruction/termination.
        registry.remove(original)
    }
    #expect(registry.records.isEmpty)
}

@Test(arguments: [false, true])
func returningWindowIdentitiesPreserveBentoOrientationAndDragging(omittedByAccessibility: Bool) throws {
    var registry = WindowIdentityRegistry()
    let application = ApplicationLaunchInstance(processIdentifier: 42, generation: 1)
    let display = DisplaySnapshot(
        id: DisplayID(rawValue: "main"),
        frame: BTRect(x: 0, y: 0, width: 1000, height: 800),
        visibleFrame: BTRect(x: 0, y: 0, width: 1000, height: 800)
    )
    let originalIDs = [100, 200].map {
        registry.resolve(application: application, accessibilityHash: $0, exactWindowID: UInt32($0))
    }
    let state = BentoLayoutState(root: .partition(BentoPartition(
        axis: .vertical, children: originalIDs.map { .leaf($0) }
    )))
    let originalFrames = state.placements(in: display.visibleFrame).map(\.frame)
    var session = LayoutSession(
        displayID: display.id, mode: .bento, bentoState: state,
        windowIDs: Set(originalIDs), bentoInsertionOrder: originalIDs,
        lastWorkArea: display.visibleFrame
    )
    let reconciler = AmbientLayoutReconciler(paneGap: 0, adjacencyTolerance: 6, singleWindowPlacement: .maximize)

    for _ in 0..<4 {
        let windowServer = WindowServerIndex(records: zip([100, 200], originalFrames).map { id, frame in
            WindowServerRecord(windowID: UInt32(id), processIdentifier: 42, layer: 0,
                               frame: frame, isOnscreen: false)
        })
        _ = registry.removeClosedWindowsAfterSweep(
            observedApplications: [application: omittedByAccessibility ? [] : [100, 200]],
            windowServer: windowServer
        )
        let returningIDs = [100, 200].map {
            registry.resolve(application: application, accessibilityHash: $0, exactWindowID: UInt32($0))
        }
        let windows = zip(returningIDs, originalFrames).map { id, frame in
            WindowSnapshot(id: id, processIdentifier: 42, frame: frame, displayID: display.id)
        }
        // The drag path freezes the stored layout before reconciliation.
        #expect(BentoDragSession(
            displayID: display.id, sourceWindowID: returningIDs[0],
            state: session.bentoState, windows: windows, workArea: display.visibleFrame
        ) != nil)
        let previousIDs = session.windowIDs
        session.windowIDs = Set(returningIDs)
        let transition = reconciler.transition(session: session, observation: AmbientLayoutObservation(
            display: display, windows: windows, wasCreated: false,
            previousWindowIDs: previousIDs, isDesktopTransition: false
        ))
        session = transition.session
        if case .observe = transition {} else {
            Issue.record("Returning to unchanged left/right halves must not issue a new layout")
        }
        #expect(session.bentoState == state)
    }
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
    #expect(index.containsIdentity(20, processIdentifier: 42))
    #expect(!index.containsIdentity(20, processIdentifier: 43))
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

@Test(arguments: ["closed", "ax-present", "ws-present", "ax-read-failed", "ws-read-failed", "no-exact"])
func retainedWindowClosureRequiresBothSuccessfulNativeSources(evidence: String) {
    var registry = WindowIdentityRegistry()
    let application = ApplicationLaunchInstance(processIdentifier: 42, generation: 1)
    let id = registry.resolve(application: application, accessibilityHash: 100,
                              exactWindowID: evidence == "no-exact" ? nil : 700)
    let observations: [ApplicationLaunchInstance: Set<CFHashCode>] = evidence == "ax-read-failed"
        ? [:] : [application: evidence == "ax-present" ? [100] : []]
    let index: WindowServerIndex? = evidence == "ws-read-failed" ? nil : WindowServerIndex(records: evidence == "ws-present" ? [
        WindowServerRecord(windowID: 700, processIdentifier: 42, layer: 0,
                           frame: BTRect(x: 0, y: 0, width: 500, height: 400), isOnscreen: false),
    ] : [])
    let closed = registry.removeClosedWindowsAfterSweep(observedApplications: observations, windowServer: index)
    #expect(closed.map(\.windowID).contains(id) == (evidence == "closed"))
    #expect((registry.records[id] == nil) == (evidence == "closed"))
    #expect(registry.removeClosedWindowsAfterSweep(observedApplications: observations, windowServer: index).isEmpty)
}

@Test func terminatedLaunchReturnsEveryIdentityOnceAndKeepsOtherApplications() {
    var registry = WindowIdentityRegistry()
    let terminated = ApplicationLaunchInstance(processIdentifier: 42, generation: 1)
    let other = ApplicationLaunchInstance(processIdentifier: 43, generation: 2)
    let first = registry.resolve(application: terminated, accessibilityHash: 100, exactWindowID: 700)
    let second = registry.resolve(application: terminated, accessibilityHash: 101, exactWindowID: nil)
    let survivor = registry.resolve(application: other, accessibilityHash: 100, exactWindowID: 701)
    let closed = registry.remove(processIdentifier: terminated.processIdentifier)
    #expect(Set(closed.map(\.windowID)) == [first, second])
    #expect(closed.allSatisfy { $0.application == terminated })
    #expect(registry.remove(processIdentifier: terminated.processIdentifier).isEmpty)
    #expect(Set(registry.records.keys) == [survivor])
    #expect(registry.windowID(application: terminated, accessibilityHash: 100) == nil)
    #expect(registry.windowID(forExactWindowID: 700) == nil)
    let relaunched = ApplicationLaunchInstance(processIdentifier: 42, generation: 3)
    let replacement = registry.resolve(application: relaunched, accessibilityHash: 100, exactWindowID: 700)
    #expect(replacement != first && replacement != second)
    #expect(registry.windowID(application: other, accessibilityHash: 100) == survivor)
}
