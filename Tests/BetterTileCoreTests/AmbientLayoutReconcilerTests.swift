import Testing
@testable import BetterTileCore

private let ambientDisplayID = DisplayID(rawValue: "ambient")
private let ambientBounds = BTRect(x: 0, y: 0, width: 1_200, height: 800)
private let ambientDisplay = DisplaySnapshot(
    id: ambientDisplayID,
    frame: ambientBounds,
    visibleFrame: ambientBounds
)

private func ambientWindow(_ name: String, frame: BTRect) -> WindowSnapshot {
    WindowSnapshot(
        id: WindowID(rawValue: name),
        processIdentifier: 1,
        frame: frame,
        displayID: ambientDisplayID
    )
}

private func ambientObservation(
    windows: [WindowSnapshot],
    display: DisplaySnapshot = ambientDisplay,
    wasCreated: Bool = false,
    previousWindowIDs: Set<WindowID>? = nil,
    isDesktopTransition: Bool = false,
    confirmedGone: Set<WindowID> = [],
    confirmedMinimized: Set<WindowID> = []
) -> AmbientLayoutObservation {
    AmbientLayoutObservation(
        display: display,
        windows: windows,
        wasCreated: wasCreated,
        previousWindowIDs: previousWindowIDs ?? Set(windows.map(\.id)),
        isDesktopTransition: isDesktopTransition,
        confirmedGone: confirmedGone,
        confirmedMinimized: confirmedMinimized
    )
}

private func ambientReconciler(
    singleWindowPlacement: WindowAction? = nil
) -> AmbientLayoutReconciler {
    AmbientLayoutReconciler(
        paneGap: 0,
        adjacencyTolerance: 6,
        singleWindowPlacement: singleWindowPlacement
    )
}

private func horizontalPaneState(_ windows: [WindowSnapshot]) -> BentoLayoutState {
    BentoLayoutState(root: .partition(BentoPartition(
        axis: .vertical,
        children: windows.map { .leaf($0.id) }
    )))
}

private let ambientLeft = ambientWindow(
    "left",
    frame: BTRect(x: 0, y: 0, width: 600, height: 800)
)
private let ambientRight = ambientWindow(
    "right",
    frame: BTRect(x: 600, y: 0, width: 600, height: 800)
)
private let ambientThird = ambientWindow(
    "third",
    frame: BTRect(x: 800, y: 0, width: 400, height: 800)
)

@Test func aNewAdoptableDesktopInitializesWithoutWritingFrames() throws {
    let windows = [ambientLeft, ambientRight]
    let session = LayoutSession(
        displayID: ambientDisplayID,
        mode: .bento,
        windowIDs: Set(windows.map(\.id))
    )

    let transition = ambientReconciler().transition(
        session: session,
        observation: ambientObservation(windows: windows, wasCreated: true, previousWindowIDs: [])
    )

    guard case let .observe(updated) = transition else {
        Issue.record("An adoptable new desktop must not move its windows")
        return
    }
    #expect(updated.isBentoInitialized)
    #expect(Set(updated.bentoState.root?.windowIDs ?? []) == Set(windows.map(\.id)))
}

@Test func aNewNonAdoptableDesktopAppliesTheCanonicalLayout() throws {
    let overlapping = [
        ambientWindow("a", frame: ambientBounds),
        ambientWindow("b", frame: ambientBounds),
    ]
    let session = LayoutSession(
        displayID: ambientDisplayID,
        mode: .bento,
        windowIDs: Set(overlapping.map(\.id))
    )

    let transition = ambientReconciler().transition(
        session: session,
        observation: ambientObservation(windows: overlapping, wasCreated: true, previousWindowIDs: [])
    )

    guard case let .applyLayout(updated, placements, settleWorkArea) = transition else {
        Issue.record("A non-adoptable desktop must receive a canonical layout")
        return
    }
    #expect(updated.isBentoInitialized)
    #expect(Set(placements.map(\.windowID)) == Set(overlapping.map(\.id)))
    #expect(settleWorkArea == nil)
}

@Test func aLoneWindowUsesTheConfiguredPlacement() throws {
    let window = ambientWindow("solo", frame: BTRect(x: 200, y: 100, width: 500, height: 400))
    let session = LayoutSession(displayID: ambientDisplayID, mode: .bento, windowIDs: [window.id])

    let transition = ambientReconciler(singleWindowPlacement: .maximize).transition(
        session: session,
        observation: ambientObservation(windows: [window], wasCreated: true, previousWindowIDs: [])
    )

    guard case let .placeSingleWindow(updated, placement) = transition else {
        Issue.record("The single-window latch must produce its configured placement")
        return
    }
    #expect(updated.hasAppliedSingleWindowPlacement)
    #expect(placement.windowID == window.id)
    #expect(placement.frame == ambientBounds)
}

@Test func theSingleWindowLatchFiresOnceAndRearmsAfterMembershipChanges() throws {
    let solo = ambientWindow("solo", frame: BTRect(x: 100, y: 100, width: 500, height: 400))
    let peer = ambientWindow("peer", frame: BTRect(x: 600, y: 0, width: 600, height: 800))
    let reconciler = ambientReconciler(singleWindowPlacement: .maximize)
    let initial = LayoutSession(displayID: ambientDisplayID, mode: .manual, windowIDs: [solo.id])

    let first = reconciler.transition(
        session: initial,
        observation: ambientObservation(windows: [solo], wasCreated: true, previousWindowIDs: [])
    )
    guard case let .placeSingleWindow(firstSession, _) = first else {
        Issue.record("The first single-window observation must place the window")
        return
    }

    let second = reconciler.transition(
        session: firstSession,
        observation: ambientObservation(windows: [solo])
    )
    guard case let .observe(secondSession) = second else {
        Issue.record("An unchanged single-window observation must not place it again")
        return
    }

    var twoWindowSession = secondSession
    twoWindowSession.windowIDs = [solo.id, peer.id]
    let rearmed = reconciler.transition(
        session: twoWindowSession,
        observation: ambientObservation(windows: [solo, peer], previousWindowIDs: [solo.id])
    ).session
    #expect(!rearmed.hasAppliedSingleWindowPlacement)

    var soloAgain = rearmed
    soloAgain.windowIDs = [solo.id]
    let final = reconciler.transition(
        session: soloAgain,
        observation: ambientObservation(windows: [solo], previousWindowIDs: [solo.id, peer.id])
    )
    guard case .placeSingleWindow = final else {
        Issue.record("Returning to one window must fire the rearmed latch")
        return
    }
}

@Test func suspendedWritesStillAdvanceTheSingleWindowLatch() throws {
    let solo = ambientWindow("solo", frame: ambientBounds)
    let session = LayoutSession(
        displayID: ambientDisplayID,
        mode: .manual,
        windowIDs: [solo.id],
        automaticWritesSuspended: true
    )
    let reconciler = ambientReconciler(singleWindowPlacement: .maximize)

    let suspended = reconciler.transition(
        session: session,
        observation: ambientObservation(windows: [solo])
    )
    guard case let .observe(suspendedSession) = suspended else {
        Issue.record("Suspension must suppress the frame write")
        return
    }
    #expect(suspendedSession.hasAppliedSingleWindowPlacement)

    var resumed = suspendedSession
    resumed.resumeAutomaticWrites()
    let next = reconciler.transition(
        session: resumed,
        observation: ambientObservation(windows: [solo])
    )
    guard case .observe = next else {
        Issue.record("Resuming must not replay a latch already spent during suspension")
        return
    }
}

@Test func suspendedBentoWritesLeaveTheTreeUntouchedAndRearmTheLatch() throws {
    let windows = [ambientLeft, ambientRight]
    let state = horizontalPaneState(windows)
    let session = LayoutSession(
        displayID: ambientDisplayID,
        mode: .bento,
        bentoState: state,
        windowIDs: Set(windows.map(\.id)),
        bentoInsertionOrder: windows.map(\.id),
        hasAppliedSingleWindowPlacement: true,
        automaticWritesSuspended: true
    )

    let transition = ambientReconciler().transition(
        session: session,
        observation: ambientObservation(windows: windows, confirmedGone: [ambientRight.id])
    )

    guard case let .observe(updated) = transition else {
        Issue.record("Suspended Bento writes must remain bookkeeping-only")
        return
    }
    #expect(updated.bentoState == state)
    #expect(!updated.hasAppliedSingleWindowPlacement)
}

@Test func aKnownDesktopTransitionKeepsItsBentoTreeReadOnly() throws {
    let state = horizontalPaneState([ambientLeft, ambientRight])
    let session = LayoutSession(
        displayID: ambientDisplayID,
        mode: .bento,
        bentoState: state,
        windowIDs: [ambientLeft.id],
        bentoInsertionOrder: [ambientLeft.id, ambientRight.id]
    )

    let transition = ambientReconciler().transition(
        session: session,
        observation: ambientObservation(
            windows: [ambientLeft],
            previousWindowIDs: [ambientLeft.id, ambientRight.id],
            isDesktopTransition: true,
            confirmedMinimized: [ambientRight.id]
        )
    )

    guard case let .observe(updated) = transition else {
        Issue.record("A known desktop transition must not rewrite its Bento tree")
        return
    }
    #expect(updated.bentoState == state)
    #expect(updated.bentoReinsertionAnchors.isEmpty)
}

@Test func singleWindowPlacementStillPrecedesDesktopTransitionReadOnlyPolicy() throws {
    let window = ambientWindow("solo", frame: BTRect(x: 100, y: 100, width: 500, height: 400))
    let session = LayoutSession(
        displayID: ambientDisplayID,
        mode: .bento,
        bentoState: BentoLayoutState(root: .leaf(window.id)),
        windowIDs: [window.id]
    )

    let transition = ambientReconciler(singleWindowPlacement: .maximize).transition(
        session: session,
        observation: ambientObservation(windows: [window], isDesktopTransition: true)
    )

    guard case .placeSingleWindow = transition else {
        Issue.record("The existing single-window precedence must survive desktop transitions")
        return
    }
}

@Test func confirmedRemovalChangesTheTreeEvenWithoutObservedMembershipChange() throws {
    let windows = [ambientLeft, ambientRight, ambientThird]
    let remaining = [ambientLeft, ambientRight]
    let session = LayoutSession(
        displayID: ambientDisplayID,
        mode: .bento,
        bentoState: horizontalPaneState(windows),
        windowIDs: Set(remaining.map(\.id)),
        bentoInsertionOrder: windows.map(\.id),
        lastWorkArea: ambientBounds
    )

    let transition = ambientReconciler().transition(
        session: session,
        observation: ambientObservation(
            windows: remaining,
            previousWindowIDs: Set(remaining.map(\.id)),
            confirmedGone: [ambientThird.id]
        )
    )

    guard case let .applyLayout(updated, placements, _) = transition else {
        Issue.record("Direct removal evidence must apply the reduced tree")
        return
    }
    #expect(updated.bentoState.root?.windowIDs.contains(ambientThird.id) == false)
    #expect(Set(placements.map(\.windowID)) == Set(remaining.map(\.id)))
}

@Test func minimizedRemovalKeepsAReinsertionAnchor() throws {
    let windows = [ambientLeft, ambientRight, ambientThird]
    let remaining = [ambientLeft, ambientRight]
    let session = LayoutSession(
        displayID: ambientDisplayID,
        mode: .bento,
        bentoState: horizontalPaneState(windows),
        windowIDs: Set(remaining.map(\.id)),
        bentoInsertionOrder: windows.map(\.id),
        lastWorkArea: ambientBounds
    )

    let transition = ambientReconciler().transition(
        session: session,
        observation: ambientObservation(
            windows: remaining,
            confirmedMinimized: [ambientThird.id]
        )
    )

    guard case let .applyLayout(updated, _, _) = transition else {
        Issue.record("Minimize evidence must apply the reduced tree")
        return
    }
    #expect(updated.bentoReinsertionAnchors[ambientThird.id] != nil)
}

@Test func aWorkAreaChangeRequestsSettlementAndLeavesTheStoredAreaStale() throws {
    let windows = [ambientLeft, ambientRight]
    let newBounds = BTRect(x: 0, y: 0, width: 1_000, height: 800)
    let changedDisplay = DisplaySnapshot(
        id: ambientDisplayID,
        frame: newBounds,
        visibleFrame: newBounds
    )
    let session = LayoutSession(
        displayID: ambientDisplayID,
        mode: .bento,
        bentoState: horizontalPaneState(windows),
        windowIDs: Set(windows.map(\.id)),
        bentoInsertionOrder: windows.map(\.id),
        lastWorkArea: ambientBounds
    )

    let transition = ambientReconciler().transition(
        session: session,
        observation: ambientObservation(windows: windows, display: changedDisplay)
    )

    guard case let .applyLayout(updated, _, settleWorkArea) = transition else {
        Issue.record("A changed work area must apply and settle the layout")
        return
    }
    #expect(settleWorkArea == newBounds)
    #expect(updated.lastWorkArea == ambientBounds)
}

@Test func anUnchangedObservationOnlyRefreshesBookkeeping() throws {
    let windows = [ambientLeft, ambientRight]
    let session = LayoutSession(
        displayID: ambientDisplayID,
        mode: .bento,
        bentoState: horizontalPaneState(windows),
        windowIDs: Set(windows.map(\.id)),
        bentoInsertionOrder: windows.map(\.id)
    )

    let transition = ambientReconciler().transition(
        session: session,
        observation: ambientObservation(windows: windows)
    )

    guard case let .observe(updated) = transition else {
        Issue.record("Stable membership must not write frames")
        return
    }
    #expect(updated.lastObservedFrames == Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0.frame) }))
    #expect(updated.lastWorkArea == ambientBounds)
}

@Test func anExistingUninitializedAdoptableSessionAppliesItsNewTree() throws {
    let windows = [ambientLeft, ambientRight]
    let session = LayoutSession(
        displayID: ambientDisplayID,
        mode: .bento,
        windowIDs: Set(windows.map(\.id))
    )

    let transition = ambientReconciler().transition(
        session: session,
        observation: ambientObservation(windows: windows)
    )

    guard case let .applyLayout(updated, placements, _) = transition else {
        Issue.record("An existing uninitialized session must apply its adopted tree")
        return
    }
    #expect(updated.isBentoInitialized)
    #expect(Set(placements.map(\.windowID)) == Set(windows.map(\.id)))
}

@Test func anExistingUninitializedNonAdoptableSessionAppliesItsNewTree() throws {
    let windows = [
        ambientWindow("a", frame: ambientBounds),
        ambientWindow("b", frame: ambientBounds),
    ]
    let session = LayoutSession(
        displayID: ambientDisplayID,
        mode: .bento,
        windowIDs: Set(windows.map(\.id))
    )

    let transition = ambientReconciler().transition(
        session: session,
        observation: ambientObservation(windows: windows)
    )

    guard case .applyLayout = transition else {
        Issue.record("An existing non-adoptable session must apply its canonical tree")
        return
    }
}

@Test func nativeAndLinkedModesRetainSingleWindowPlacement() throws {
    let window = ambientWindow("solo", frame: BTRect(x: 100, y: 100, width: 500, height: 400))
    let reconciler = ambientReconciler(singleWindowPlacement: .maximize)

    for mode in [LayoutMode.manual, .linked] {
        let session = LayoutSession(displayID: ambientDisplayID, mode: mode, windowIDs: [window.id])
        let transition = reconciler.transition(
            session: session,
            observation: ambientObservation(windows: [window])
        )
        guard case .placeSingleWindow = transition else {
            Issue.record("\(mode) mode lost the shared single-window policy")
            continue
        }
    }
}

@Test func aDirectLayoutCauseReachesAnExactNoWriteFixedPoint() throws {
    let windows = [
        ambientWindow("a", frame: ambientBounds),
        ambientWindow("b", frame: ambientBounds),
    ]
    let session = LayoutSession(
        displayID: ambientDisplayID,
        mode: .bento,
        windowIDs: Set(windows.map(\.id))
    )
    let reconciler = ambientReconciler()

    let first = reconciler.transition(
        session: session,
        observation: ambientObservation(windows: windows)
    )
    guard case let .applyLayout(firstSession, _, _) = first else {
        Issue.record("The initial cause must produce a layout")
        return
    }
    let second = reconciler.transition(
        session: firstSession,
        observation: ambientObservation(windows: windows)
    )
    guard case let .observe(secondSession) = second else {
        Issue.record("The same stable facts must not produce a second write")
        return
    }
    #expect(secondSession == firstSession)
}

@Test func inferredAbsenceConvergesAfterItsBoundedCorroboration() throws {
    let all = [ambientLeft, ambientRight, ambientThird]
    let visible = [ambientLeft, ambientRight]
    var session = LayoutSession(
        displayID: ambientDisplayID,
        mode: .bento,
        bentoState: horizontalPaneState(all),
        windowIDs: Set(visible.map(\.id)),
        bentoInsertionOrder: all.map(\.id),
        lastWorkArea: ambientBounds
    )
    let reconciler = ambientReconciler()

    let first = reconciler.transition(
        session: session,
        observation: ambientObservation(
            windows: visible,
            previousWindowIDs: Set(all.map(\.id))
        )
    )
    guard case let .applyLayout(firstSession, _, _) = first else {
        Issue.record("The initial membership change must produce the existing write")
        return
    }
    #expect(firstSession.presence.pending[ambientThird.id] == 1)

    session = firstSession
    let second = reconciler.transition(
        session: session,
        observation: ambientObservation(windows: visible)
    )
    guard case let .observe(secondSession) = second else {
        Issue.record("The second corroborating miss changes bookkeeping without writing")
        return
    }
    #expect(secondSession.presence.pending[ambientThird.id] == 2)

    let third = reconciler.transition(
        session: secondSession,
        observation: ambientObservation(windows: visible)
    )
    guard case let .applyLayout(thirdSession, _, _) = third else {
        Issue.record("The bounded final miss must remove the pane and apply once")
        return
    }
    #expect(thirdSession.bentoState.root?.windowIDs.contains(ambientThird.id) == false)

    let stable = reconciler.transition(
        session: thirdSession,
        observation: ambientObservation(windows: visible)
    )
    guard case let .observe(stableSession) = stable else {
        Issue.record("The reconciled absence must reach a no-write fixed point")
        return
    }
    #expect(stableSession == thirdSession)
}
