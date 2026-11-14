import AppKit
@preconcurrency import ApplicationServices
import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

@Test(.macOSTestApplication) func provisionalWindowIdentityBindsExactIDWithoutChangingCoreID() throws {
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

@Test(.macOSTestApplication) func processAndCGWindowIDReuseCannotInheritOldIdentity() {
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

@Test(.macOSTestApplication, arguments: [false, true])
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

@Test(.macOSTestApplication, arguments: [false, true])
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

@Test(.macOSTestApplication) func exactWindowServerJoinDoesNotAcceptOverlappingSameAppFallback() {
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

/// Only a window that the window server shows on screen, at the normal window
/// layer and for the same application, is positive on-screen evidence. A closed
/// window that its application keeps alive off screen is not.
@Test(.macOSTestApplication) func onScreenEvidenceNeedsAnOnScreenNormalLayerRecordOfTheSameApplication() {
    let frame = BTRect(x: 0, y: 0, width: 500, height: 400)
    let index = WindowServerIndex(records: [
        WindowServerRecord(windowID: 10, processIdentifier: 42, layer: 0, frame: frame, isOnscreen: true),
        WindowServerRecord(windowID: 20, processIdentifier: 42, layer: 0, frame: frame, isOnscreen: false),
        WindowServerRecord(windowID: 30, processIdentifier: 42, layer: 3, frame: frame, isOnscreen: true),
    ])
    #expect(index.isOnScreen(10, processIdentifier: 42))
    #expect(!index.isOnScreen(10, processIdentifier: 43), "another application's record is no evidence")
    #expect(!index.isOnScreen(20, processIdentifier: 42), "kept alive off screen")
    #expect(!index.isOnScreen(30, processIdentifier: 42), "not the normal window layer")
    #expect(!index.isOnScreen(40, processIdentifier: 42), "no record")
}

@Test(.macOSTestApplication) func targetedSnapshotCacheMergesOnlyCompleteRefreshes() throws {
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

@Test(.macOSTestApplication) func aCreatedWindowIsAddedToTheCachedInventoryOnlyWhileItIsValid() throws {
    let displayID = DisplayID(rawValue: "display")
    func window(_ name: String) -> WindowSnapshot {
        WindowSnapshot(id: WindowID(rawValue: name), processIdentifier: 1,
                       frame: BTRect(x: 0, y: 0, width: 400, height: 400), displayID: displayID)
    }
    var cache = WindowSnapshotCache()
    #expect(cache.merge([window("new")], expectedWindowIDs: [window("new").id]) == nil)
    cache.recordFullSweep([window("old")])
    let mergeResult = cache.merge([window("new")], expectedWindowIDs: [window("new").id])
    let added = try #require(mergeResult)
    #expect(added.map(\.id.rawValue) == ["new", "old"])
    cache.invalidate() // A window that opened, closed, or minimized since.
    #expect(cache.merge([window("other")], expectedWindowIDs: [window("other").id]) == nil)
}

@Test(.macOSTestApplication) @MainActor func aRepeatedCreationCallbackKeepsItsTokenAndUnreadTokensStayBounded() {
    let system = AccessibilityWindowSystem()
    let element = AXUIElementCreateApplication(getpid())
    let token = system.creationToken(for: element, processIdentifier: getpid())
    #expect(system.creationToken(for: AXUIElementCreateApplication(getpid()), processIdentifier: getpid()) == token)
    #expect(system.creationToken(for: AXUIElementCreateApplication(1), processIdentifier: 1) != token)
    for pid in Int32(2)..<80 { _ = system.creationToken(for: AXUIElementCreateApplication(pid), processIdentifier: pid) }
    #expect(system.creationElements.count <= 32)
    #expect(system.readCreatedWindow(token: 999_999) == .unavailable)
}

@Test(.macOSTestApplication) func privateMinimumSizesAreValidatedAndMergedByGreatestDimension() {
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

@Test(.macOSTestApplication) func onlyClearDialogAndFloatingSubrolesFloatAutomatically() {
    #expect(WindowFloatingClassifier.isFloating(subrole: kAXDialogSubrole))
    #expect(WindowFloatingClassifier.isFloating(subrole: kAXSystemDialogSubrole))
    #expect(WindowFloatingClassifier.isFloating(subrole: kAXFloatingWindowSubrole))
    #expect(WindowFloatingClassifier.isFloating(subrole: kAXSystemFloatingWindowSubrole))
    #expect(!WindowFloatingClassifier.isFloating(subrole: kAXStandardWindowSubrole))
    #expect(!WindowFloatingClassifier.isFloating(subrole: nil))
}

@Test(.macOSTestApplication) @MainActor func privateWindowIdentityKillSwitchMakesResolverUnavailable() {
    #expect(!ExactWindowIDResolver(disabled: true).isAvailable)
}

@Test(.macOSTestApplication) func malformedRequiredBatchValueRequestsIndividualFallback() throws {
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

@Test(.macOSTestApplication, arguments: ["closed", "ax-present", "ws-present", "ax-read-failed", "ws-read-failed", "no-exact"])
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

@Test(.macOSTestApplication, arguments: ["invalid", "cannot-complete", "unsupported", "success", "missing-element", "ax-present", "unread-app"], [false, true])
func invalidAccessibilityElementConfirmsClosureOnlyAfterSuccessfulAbsentInventory(evidence: String, exact: Bool) {
    var registry = WindowIdentityRegistry()
    let application = ApplicationLaunchInstance(processIdentifier: 42, generation: 1)
    let id = registry.resolve(application: application, accessibilityHash: 100, exactWindowID: exact ? 700 : nil)
    let observations: [ApplicationLaunchInstance: Set<CFHashCode>] = evidence == "unread-app"
        ? [:] : [application: evidence == "ax-present" ? [100] : []]
    // WindowServer can retain an offscreen record after its AX element is destroyed.
    let index = WindowServerIndex(records: [
        WindowServerRecord(windowID: 700, processIdentifier: 42, layer: 0,
                           frame: BTRect(x: 0, y: 0, width: 500, height: 400), isOnscreen: false),
    ])
    var reads = 0
    let closed = registry.removeClosedWindowsAfterSweep(observedApplications: observations, windowServer: index) { requested in
        #expect(requested == id)
        reads += 1
        switch evidence {
        case "cannot-complete": return .cannotComplete
        case "unsupported": return .attributeUnsupported
        case "success": return .success
        case "missing-element": return nil
        default: return .invalidUIElement
        }
    }
    let shouldClose = evidence == "invalid"
    #expect(closed.map(\.windowID) == (shouldClose ? [id] : []))
    #expect((registry.records[id] == nil) == shouldClose)
    #expect(reads == (["ax-present", "unread-app"].contains(evidence) ? 0 : 1))
    #expect(registry.removeClosedWindowsAfterSweep(observedApplications: observations, windowServer: index).isEmpty)
}

@Test(.macOSTestApplication) func terminatedLaunchReturnsEveryIdentityOnceAndKeepsOtherApplications() {
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

@Test(.macOSTestApplication) func windowServerQueryEncodesRawWindowIDsWithoutObjectBridging() {
    for ids in [Set<CGWindowID>(), Set<CGWindowID>([1, 700, .max])] {
        let array = makeWindowServerIDArray(ids)
        #expect(CFArrayGetCount(array) == ids.count)
        for (index, id) in ids.sorted().enumerated() {
            #expect(UInt(bitPattern: CFArrayGetValueAtIndex(array, index)) == UInt(id))
        }
    }
}

/// Only a popup that closes without focus, such as a browser bubble, is
/// transient. Standard windows, dialogs, and floating panels are not.
@Test(.macOSTestApplication) func transientPopupsAreThePopupsThatAreNotDialogsOrPanels() {
    #expect(WindowFloatingClassifier.isTransientPopup(subrole: "AXUnknown"))
    #expect(!WindowFloatingClassifier.isTransientPopup(subrole: "AXStandardWindow"))
    #expect(!WindowFloatingClassifier.isTransientPopup(subrole: "AXDialog"))
    #expect(!WindowFloatingClassifier.isTransientPopup(subrole: "AXSystemDialog"))
    #expect(!WindowFloatingClassifier.isTransientPopup(subrole: "AXFloatingWindow"))
    #expect(!WindowFloatingClassifier.isTransientPopup(subrole: "AXSystemFloatingWindow"))
    #expect(!WindowFloatingClassifier.isTransientPopup(subrole: nil))
}

@Test(.macOSTestApplication) func cachedPeerVisibilityKeepsOnScreenPeersDropsStaleOnesAndSkipsEmptyLists() {
    let displayID = DisplayID(rawValue: "display")
    func peer(_ name: String, pid: Int32) -> WindowSnapshot {
        WindowSnapshot(id: WindowID(rawValue: name), processIdentifier: pid,
                       frame: BTRect(x: 0, y: 0, width: 400, height: 400), displayID: displayID)
    }
    func record(_ id: CGWindowID, pid: pid_t, onscreen: Bool = true) -> WindowServerRecord {
        WindowServerRecord(windowID: id, processIdentifier: pid, layer: 0,
                           frame: BTRect(x: 0, y: 0, width: 400, height: 400), isOnscreen: onscreen)
    }
    let kept = peer("kept", pid: 1)
    let stale = peer("stale", pid: 2)
    var lookups = 0

    // A peer still on screen is kept.
    #expect(CachedPeerVisibility.allOnScreen(
        peers: [kept], exactWindowIDs: [kept.id: 10],
        windowServer: { _ in lookups += 1; return WindowServerIndex(records: [record(10, pid: 1)]) }))

    // A peer that left the screen makes the cache stale, so the whole list is dropped.
    #expect(!CachedPeerVisibility.allOnScreen(
        peers: [kept, stale], exactWindowIDs: [kept.id: 10, stale.id: 20],
        windowServer: { _ in WindowServerIndex(records: [record(10, pid: 1), record(20, pid: 2, onscreen: false)]) }))

    // An empty list needs no WindowServer read.
    #expect(CachedPeerVisibility.allOnScreen(
        peers: [], exactWindowIDs: [:], windowServer: { _ in lookups += 1; return nil }))
    #expect(lookups == 1)
}

@Test(arguments: ["matching", "visible", "unknown-current-launch", "unknown-recorded-launch",
                  "both-launches-unknown", "reused-pid", "unrecorded"])
func hiddenApplicationLaunchRequiresPositiveCurrentEvidence(evidence: String) {
    let instance = ApplicationLaunchInstance(processIdentifier: 90, generation: 2)
    let currentToken: UInt64? = ["unknown-current-launch", "both-launches-unknown"].contains(evidence) ? nil : 200
    let recordedToken: UInt64? = ["unknown-recorded-launch", "both-launches-unknown"].contains(evidence)
        ? nil : (evidence == "reused-pid" ? 100 : 200)
    let result = AccessibilityWindowSystem.hiddenApplicationLaunch(
        isHidden: evidence != "visible",
        launchToken: currentToken,
        recordedLaunch: evidence == "unrecorded" ? nil : (recordedToken, instance)
    )
    #expect(result == (evidence == "matching" ? instance : nil))
}

@Test func hiddenApplicationWindowIdentitySelectionRequiresTheCurrentApplicationLaunch() {
    var registry = WindowIdentityRegistry()
    let old = ApplicationLaunchInstance(processIdentifier: 90, generation: 1)
    let current = ApplicationLaunchInstance(processIdentifier: 90, generation: 2)
    let other = ApplicationLaunchInstance(processIdentifier: 91, generation: 1)
    let stale = registry.resolve(application: old, accessibilityHash: 1, exactWindowID: nil)
    let first = registry.resolve(application: current, accessibilityHash: 2, exactWindowID: nil)
    let second = registry.resolve(application: current, accessibilityHash: 3, exactWindowID: nil)
    _ = registry.resolve(application: other, accessibilityHash: 4, exactWindowID: nil)
    #expect(registry.windowIDs(belongingTo: [current]) == [first, second])
    #expect(!registry.windowIDs(belongingTo: [current]).contains(stale))
    registry.remove(first)
    #expect(registry.windowIDs(belongingTo: [current]) == [second])
    #expect(registry.windowIDs(belongingTo: []).isEmpty)
}

private func lateRecord(_ id: CGWindowID, pid: pid_t = 42, layer: Int = 0, onscreen: Bool,
                        frame: BTRect = BTRect(x: 0, y: 0, width: 600, height: 400)) -> WindowServerRecord {
    WindowServerRecord(windowID: id, processIdentifier: pid, layer: layer, frame: frame, isOnscreen: onscreen)
}

private func lateWindow(_ name: String, pid: Int32 = 42, floating: Bool = false,
                        frame: BTRect = BTRect(x: 0, y: 0, width: 600, height: 400)) -> WindowSnapshot {
    WindowSnapshot(id: WindowID(rawValue: name), processIdentifier: pid, frame: frame,
                   displayID: DisplayID(rawValue: "main"), isFloating: floating)
}

/// The live late arrival: the sweep's window-server list, read before the
/// Accessibility reads, has the launched window's record but not on screen. The
/// targeted re-check after the reads admits it once it is on screen, and keeps
/// out a first-seen window that stays off screen or sits above the normal layer.
@Test(.macOSTestApplication) func lateOnScreenRecheckAdmitsAWindowShownDuringTheSweep() {
    let shown = LateOnScreenRecheck.Candidate(snapshot: lateWindow("shown"), exactWindowID: 701)
    let stillHidden = LateOnScreenRecheck.Candidate(snapshot: lateWindow("hidden"), exactWindowID: 702)
    let panel = LateOnScreenRecheck.Candidate(snapshot: lateWindow("panel"), exactWindowID: 703)
    let reused = LateOnScreenRecheck.Candidate(snapshot: lateWindow("reused"), exactWindowID: 704)
    let early = WindowServerIndex(records: [lateRecord(701, onscreen: false)])
    #expect(!early.contains(shown.snapshot, exactWindowID: 701))

    var requested: [Set<CGWindowID>] = []
    let admitted = LateOnScreenRecheck.admitted([shown, stillHidden, panel, reused]) { ids in
        requested.append(ids)
        return WindowServerIndex(records: [lateRecord(701, onscreen: true), lateRecord(702, onscreen: false),
                                           lateRecord(703, layer: 3, onscreen: true), lateRecord(704, pid: 43, onscreen: true)])
    }
    #expect(admitted == [shown.snapshot.id])
    #expect(requested == [[701, 702, 703, 704]], "One targeted read for every candidate")

    var calls = 0
    #expect(LateOnScreenRecheck.admitted([]) { _ in calls += 1; return nil }.isEmpty)
    #expect(calls == 0, "No candidates, no read")
    #expect(LateOnScreenRecheck.admitted([shown]) { _ in nil }.isEmpty, "A failed read admits nothing")
}

/// Sol's round-4 sequence, without exact identities: returned window A moves
/// to the frame of first-seen window B on another Space after the
/// Accessibility reads, and the window server now shows only A's record, at
/// B's frame. Neither the re-check nor discovery's read admits B, because
/// neither admits a window by frame; the next complete sweep's frame filter
/// decides it. B cannot be a re-check candidate at all, since a candidate needs
/// an exact identity; with no candidates the re-check reads and admits nothing.
@Test(.macOSTestApplication) func withoutExactIdentitiesNoWindowIsAdmittedByFrame() {
    let f1 = BTRect(x: 800, y: 0, width: 400, height: 400)
    let b = lateWindow("other-space-b", frame: f1)
    // The window server now: A's only on-screen record, at F1.
    let current = [lateRecord(900, onscreen: true, frame: f1)]
    var reads = 0
    let admitted = LateOnScreenRecheck.admitted([]) { _ in
        reads += 1
        return WindowServerIndex(records: current)
    }
    #expect(admitted.isEmpty, "B is not admitted by A's record")
    #expect(reads == 0, "Nothing to read without an exact identity")

    let discovery = LaunchedWindowVisibility.classify([b], processIdentifier: 42, exactIDs: [:]) { _ in
        reads += 1
        return current
    }
    #expect(discovery.shown.isEmpty, "Discovery places nothing it cannot identify")
    #expect(discovery.hasUnidentifiedWindow, "It asks for a complete inventory instead")
    #expect(reads == 0)
}

/// Discovery's own read: exact identities through one targeted read, panels
/// above the normal layer as floating, and floating verdicts reported as
/// provisional so the adapter clears them. A floating window without an exact
/// identity asks for no inventory.
@Test(.macOSTestApplication) func launchedWindowVisibilityShowsOnlyWindowsWithExactIdentity() {
    let frame = BTRect(x: 0, y: 0, width: 600, height: 400)
    let window = lateWindow("launched", frame: frame)
    let panel = lateWindow("panel", frame: BTRect(x: 10, y: 10, width: 200, height: 100))
    let building = lateWindow("building", floating: true, frame: BTRect(x: 300, y: 300, width: 500, height: 300))

    let exact = LaunchedWindowVisibility.classify([window, panel, building], processIdentifier: 42,
        exactIDs: [window.id: 801, panel.id: 802, building.id: 803]) { _ in
        [lateRecord(801, onscreen: true, frame: frame), lateRecord(802, layer: 3, onscreen: true), lateRecord(803, onscreen: false)]
    }
    #expect(exact.shown.map(\.id) == [window.id, panel.id])
    #expect(exact.shown.first { $0.id == panel.id }?.isFloating == true)
    #expect(exact.provisionalFloatingIDs == [building.id], "An early floating verdict is provisional")
    #expect(!exact.hasUnidentifiedWindow)

    let unidentifiedSplash = LaunchedWindowVisibility.classify([building], processIdentifier: 42, exactIDs: [:]) { _ in nil }
    #expect(unidentifiedSplash.shown.isEmpty && !unidentifiedSplash.hasUnidentifiedWindow)
}

/// A discovery read registers again the application-level notifications that
/// failed when the observer was installed, and only those.
@Test(.macOSTestApplication) func applicationObservationRepairRegistersOnlyMissingNotifications() {
    let all = ApplicationObservationRepair.applicationNotifications
    #expect(all == [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification])
    #expect(ApplicationObservationRepair.missing(registered: []) == all)
    #expect(ApplicationObservationRepair.missing(registered: [kAXFocusedWindowChangedNotification]) == [kAXWindowCreatedNotification])
    #expect(ApplicationObservationRepair.missing(registered: Set(all)).isEmpty)
}
