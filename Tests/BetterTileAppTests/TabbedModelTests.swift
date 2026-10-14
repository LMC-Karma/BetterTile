import AppKit
import BetterTileCore
@testable import BetterTileMacOS
import Testing
@testable import BetterTileApp

/// Two columns: `focused` selected over hidden `tab-1` on the left, `tab-3`
/// selected over hidden `tab-2` on the right.
@MainActor private func makeTwoTabbedColumns(_ system: FakeAppWindowSystem, model suppliedModel: BetterTileModel? = nil) async throws -> BetterTileModel {
    _ = NSApplication.shared
    addTabbedWindows(3, to: system)
    let model = suppliedModel ?? makeModel(system: system)
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 4 })
    let right = try #require(model.activeTabbedState?.panes[1].id)
    for id in [system.windows[2].id, system.windows[3].id] {
        model.performTabbed(.move(id, pane: right, index: nil))
        try #require(await waitFor { model.activeTabbedState?.panes[1].selected == id })
    }
    let left = system.windows[0].id
    model.performTabbed(.select(left))
    try #require(await waitFor { model.activeTabbedState?.activeWindowID == left })
    try await Task.sleep(for: .milliseconds(400)) // Let focus refreshes settle.
    return model
}

private func stackEntry(_ window: WindowSnapshot) -> TabbedStackEntry {
    TabbedStackEntry(windowID: window.id, frame: window.frame)
}

@Test(arguments: [false, true]) @MainActor
func activationWithBetterTileInFrontNeverSelectsOrActivatesATab(staleFocusIsHidden: Bool) async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTwoTabbedColumns(system)
    defer { model.shutdown() }
    let state = try #require(model.activeTabbedState)
    // BetterTile's Settings is in front. focusedWindow() skips BetterTile and
    // reports the last managed app's window instead.
    system.frontmostOverride = 999
    system.focusedID = staleFocusIsHidden ? system.windows[1].id : system.windows[0].id
    let raises = system.raiseRequests.count

    model.handleApplicationActivation()
    try await Task.sleep(for: .milliseconds(500))
    #expect(system.raiseRequests.count == raises)
    #expect(model.activeTabbedState == state)
}

@Test(arguments: [false, true]) @MainActor
func activationRaisesSelectionsAboveAllInactiveTabs(failOrdering: Bool) async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTwoTabbedColumns(system)
    defer { model.shutdown() }
    // Cmd-Tab to the left tab's app brought its hidden right-hand tab over
    // that pane's selected tab.
    system.windows[2].processIdentifier = system.windows[0].processIdentifier
    system.stack = [2, 0, 3, 1].map { stackEntry(system.windows[$0]) }
    system.focusedID = system.windows[0].id
    let state = try #require(model.activeTabbedState)
    let frames = system.windows.map(\.frame)
    let writes = system.frameWriteCounts
    let raises = system.raiseRequests.count
    if failOrdering { system.failingNextRaiseWindowID = system.windows[3].id }

    model.handleApplicationActivation()
    // An AX focus event after activation must not discard the repair.
    system.eventHandler?(WindowSystemEvent(kind: .focused, windowID: system.windows[0].id,
                                          processIdentifier: system.windows[0].processIdentifier))
    if failOrdering {
        #expect(await waitFor(timeout: .seconds(1)) { model.statusMessage != nil })
        // Ordering is best effort. Later safe raises still run when one
        // selected tab refuses, but no verified curtain anchor is returned.
        #expect(system.raiseRequests.dropFirst(raises).map(\.0) == [system.windows[0].id])
    } else {
        #expect(await waitFor(timeout: .seconds(1)) { system.raiseRequests.count > raises })
        try await Task.sleep(for: .milliseconds(200))
        #expect(system.raiseRequests.dropFirst(raises).map(\.0) == [system.windows[3].id, system.windows[0].id])
        #expect(!system.raiseRequests.dropFirst(raises).contains { $0.1 })
        #expect(system.stack?.map(\.windowID) == [0, 3, 2, 1].map { system.windows[$0].id })
    }
    #expect(system.focusedID == system.windows[0].id)
    #expect(system.windows.map(\.frame) == frames)
    #expect(system.frameWriteCounts == writes)
    #expect(model.activeTabbedState == state)
}

/// One Pane: `focused` selected over hidden `tab-1`, `tab-2`, and `tab-3`,
/// each of another application, as in a browser with three hidden tabs.
@MainActor private func makeOnePaneWithHiddenTabs(_ system: FakeAppWindowSystem) async throws -> BetterTileModel {
    _ = NSApplication.shared
    addTabbedWindows(3, to: system)
    system.focusedID = system.windows[0].id
    let model = makeModel(system: system)
    model.configuration.defaultTabbedPreset = .single
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 4 })
    let selected = system.windows[0].id
    if model.activeTabbedState?.activeWindowID != selected {
        model.performTabbed(.select(selected))
        try #require(await waitFor { model.activeTabbedState?.activeWindowID == selected })
    }
    try await Task.sleep(for: .milliseconds(400)) // Let focus refreshes settle.
    return model
}

/// A toolbar bubble of the selected tab's application: a popup that floats,
/// cannot be resized, and takes keyboard focus.
@MainActor private func addToolbarBubble(to system: FakeAppWindowSystem) -> WindowSnapshot {
    var bubble = system.windows[0]
    bubble.id = WindowID(rawValue: "toolbar-bubble")
    bubble.frame = BTRect(x: 600, y: 120, width: 320, height: 420)
    bubble.isFloating = true
    bubble.constraints.isResizable = false
    system.windows.append(bubble)
    system.transientPopupIDs.insert(bubble.id)
    return bubble
}

/// Live: a browser bubble opened from the toolbar closed within 200 ms in a
/// One Pane layout with hidden tabs. The focus refresh raised a window of the
/// browser, which took focus from the bubble. While a window that is not a
/// tab has focus, Tabbed raises, focuses, selects, and moves nothing of its
/// application. The repair runs once focus returns to the tab.
@Test(arguments: ["bubble-behind-selected", "hidden-tab-exposed"], [false, true]) @MainActor
func aFocusedPopupKeepsFocusUntilItsApplicationReturnsToATab(order: String, closesSilently: Bool) async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeOnePaneWithHiddenTabs(system)
    defer { model.shutdown() }
    let state = try #require(model.activeTabbedState)
    let bubble = addToolbarBubble(to: system)
    // Either order makes the repair raise a window of the bubble's application.
    system.stack = order == "bubble-behind-selected"
        ? [system.windows[0], bubble, system.windows[1], system.windows[2], system.windows[3]].map(stackEntry)
        : [bubble, system.windows[1], system.windows[0], system.windows[2], system.windows[3]].map(stackEntry)
    system.raiseFocusesFrontmostApplicationWindow = true
    system.focusedID = bubble.id
    let frames = system.windows.map(\.frame)
    let writes = system.frameWriteCounts
    let raises = system.raiseRequests.count
    let focusRequests = system.focusRequests.count

    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: bubble.id, processIdentifier: bubble.processIdentifier))
    system.eventHandler?(WindowSystemEvent(kind: .focused, windowID: bubble.id, processIdentifier: bubble.processIdentifier))
    let focusRefresh = try #require(model.tabbedFocusTask)
    await focusRefresh.value
    try await Task.sleep(for: .milliseconds(500)) // Curtain rechecks and the sweep.
    #expect(system.raiseRequests.count == raises)
    #expect(system.focusRequests.count == focusRequests)
    #expect(system.focusedID == bubble.id)
    #expect(system.windows.map(\.frame) == frames)
    #expect(system.frameWriteCounts == writes)
    #expect(model.activeTabbedState == state)
    #expect(model.tabbedRepairDeferred == [system.mainDisplay.id])

    // The bubble closes and focus returns to the selected tab. The repair
    // that waited now runs, after the focus notification or, when none
    // arrives, from the watchdog.
    system.windows.removeAll { $0.id == bubble.id }
    system.stack = [1, 0, 2, 3].map { stackEntry(system.windows[$0]) }
    system.focusedID = system.windows[0].id
    if closesSilently {
        model.watchdog()
    } else {
        system.eventHandler?(WindowSystemEvent(kind: .destroyed, windowID: bubble.id, processIdentifier: bubble.processIdentifier))
        system.eventHandler?(WindowSystemEvent(kind: .focused, windowID: system.windows[0].id,
                                              processIdentifier: system.windows[0].processIdentifier))
    }
    #expect(await waitFor(timeout: .seconds(3)) { system.raiseRequests.count > raises })
    try await Task.sleep(for: .milliseconds(200))
    #expect(system.raiseRequests.dropFirst(raises).map(\.0) == [system.windows[0].id])
    #expect(!system.raiseRequests.dropFirst(raises).contains { $0.1 })
    #expect(system.stack?.first?.windowID == system.windows[0].id)
    #expect(system.focusedID == system.windows[0].id)
    #expect(system.windows.map(\.frame) == Array(frames.dropLast()))
    #expect(model.activeTabbedState == state)
    #expect(model.tabbedRepairDeferred.isEmpty)
}

/// A repair that waited for a popup does not block later repairs. Cmd-Tab
/// away closes the popup; Cmd-Tab back brings the application's hidden tab
/// in the other pane forward, and the repair puts it back at once.
@Test @MainActor func anApplicationSwitchStillRepairsStackingAfterAPopupWaited() async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTwoTabbedColumns(system)
    defer { model.shutdown() }
    let state = try #require(model.activeTabbedState)
    let bubble = addToolbarBubble(to: system)
    system.stack = [bubble, system.windows[1], system.windows[0], system.windows[3], system.windows[2]].map(stackEntry)
    system.focusedID = bubble.id
    let raises = system.raiseRequests.count
    system.eventHandler?(WindowSystemEvent(kind: .focused, windowID: bubble.id, processIdentifier: bubble.processIdentifier))
    let focusRefresh = try #require(model.tabbedFocusTask)
    await focusRefresh.value
    #expect(system.raiseRequests.count == raises)

    system.windows.removeAll { $0.id == bubble.id }
    system.windows[2].processIdentifier = system.windows[0].processIdentifier
    system.stack = [2, 0, 3, 1].map { stackEntry(system.windows[$0]) }
    system.focusedID = system.windows[0].id
    model.handleApplicationActivation()
    #expect(await waitFor(timeout: .seconds(3)) { system.raiseRequests.count > raises })
    try await Task.sleep(for: .milliseconds(200))
    #expect(system.raiseRequests.dropFirst(raises).map(\.0) == [system.windows[3].id, system.windows[0].id])
    #expect(!system.raiseRequests.dropFirst(raises).contains { $0.1 })
    #expect(system.stack?.map(\.windowID) == [0, 3, 2, 1].map { system.windows[$0].id })
    #expect(system.focusedID == system.windows[0].id)
    #expect(model.activeTabbedState == state)
}

/// `focusedWindow()` reports another window of the application when it
/// cannot read the focused popup. That report must not select a tab or
/// raise a window of the application.
@Test(arguments: [false, true]) @MainActor
func aFocusReportedInPlaceOfAnUnreadablePopupSelectsNothing(unknownFocus: Bool) async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeOnePaneWithHiddenTabs(system)
    defer { model.shutdown() }
    let state = try #require(model.activeTabbedState)
    // The hidden tab's application is in front with a popup focused, and
    // focusedWindow() reports the hidden tab instead.
    system.stack = [0, 1, 2, 3].map { stackEntry(system.windows[$0]) }
    system.focusedID = system.windows[1].id
    if unknownFocus { system.focusedWindowIsUnknown = true } else { system.focusedWindowIsFallback = true }
    let frames = system.windows.map(\.frame)
    let writes = system.frameWriteCounts
    let raises = system.raiseRequests.count

    system.eventHandler?(WindowSystemEvent(kind: .focused, windowID: nil, processIdentifier: system.windows[1].processIdentifier))
    let focusRefresh = try #require(model.tabbedFocusTask)
    await focusRefresh.value
    try await Task.sleep(for: .milliseconds(300))
    #expect(model.activeTabbedState == state)
    #expect(system.raiseRequests.count == raises)
    #expect(system.windows.map(\.frame) == frames)
    #expect(system.frameWriteCounts == writes)
}

/// Cmd-Tab to an application whose focused window is a standard window the
/// user floated: that window is raised again last, so it keeps focus.
@Test @MainActor func aFloatedStandardKeyWindowIsRaisedLastAfterActivation() async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTwoTabbedColumns(system)
    defer { model.shutdown() }
    var floated = system.windows[0]
    floated.id = WindowID(rawValue: "user-floated")
    floated.frame = BTRect(x: 300, y: 300, width: 300, height: 200)
    system.windows.append(floated)
    system.windows[2].processIdentifier = system.windows[0].processIdentifier
    system.stack = [system.windows[2], floated, system.windows[0], system.windows[3], system.windows[1]].map(stackEntry)
    system.focusedID = floated.id
    let raises = system.raiseRequests.count
    model.handleApplicationActivation()
    #expect(await waitFor(timeout: .seconds(3)) { system.raiseRequests.count > raises })
    try await Task.sleep(for: .milliseconds(200))
    let raised = system.raiseRequests.dropFirst(raises)
    #expect(raised.last?.0 == floated.id)
    #expect(raised.contains { $0.0 == system.windows[3].id })
    #expect(!raised.contains { $0.1 })
    #expect(model.tabbedRepairDeferred.isEmpty)
}

/// A standard window of the selected tab's application that BetterTile
/// floats as a popup, such as Finder's Connect to Server.
@MainActor private func addFloatedDialog(_ name: String, to system: FakeAppWindowSystem, x: Double) -> WindowSnapshot {
    var dialog = system.windows[0]
    dialog.id = WindowID(rawValue: name)
    dialog.frame = BTRect(x: x, y: 200, width: 486, height: 234)
    dialog.isFloating = true
    system.windows.append(dialog)
    return dialog
}

/// Checks the verified order: floating windows above the curtain, hidden
/// tabs behind it, and a second repair raises nothing.
@MainActor private func expectOneVerifiedRound(_ model: BetterTileModel, _ system: FakeAppWindowSystem,
                                               state: TabbedLayoutState, above: [WindowID], below: [WindowID]) throws {
    let raises = system.raiseRequests.count
    let anchor = try #require(model.repairTabbedOrder(state: state, windows: system.windows,
                                                      bounds: system.mainDisplay.visibleFrame)?.first)
    #expect(system.raiseRequests.count == raises)
    let order = try #require(system.stack?.compactMap { $0.windowID })
    let curtain = try #require(order.firstIndex(of: anchor))
    #expect(above.allSatisfy { (order.firstIndex(of: $0) ?? .max) <= curtain })
    #expect(below.allSatisfy { (order.firstIndex(of: $0) ?? .min) > curtain })
}

/// Live: Cmd-Tab back to Finder lifted its hidden tab above the curtain.
/// The repair raised the floated Connect to Server dialog and then the key
/// window again last, which put the dialog back behind the selected tab and
/// so behind the curtain. The readback never verified, so every focus event
/// the raises caused started another round. Now the dialog keeps its place
/// in front of the curtain, the key window keeps focus, and one round ends
/// the repair.
@Test(arguments: [true, false]) @MainActor
func aFrontApplicationDialogStaysAboveTheCurtainAfterActivation(dialogHasFocus: Bool) async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeOnePaneWithHiddenTabs(system)
    defer { model.shutdown() }
    let state = try #require(model.activeTabbedState)
    system.windows[1].processIdentifier = system.windows[0].processIdentifier
    let selected = system.windows[0].id, hidden = system.windows[1].id
    let dialog = addFloatedDialog("connect-to-server", to: system, x: 700)
    system.stack = [system.windows[1], system.windows[0], dialog, system.windows[2], system.windows[3]].map(stackEntry)
    system.raiseFocusesFrontmostApplicationWindow = true
    let key = dialogHasFocus ? dialog.id : selected
    system.focusedID = key
    let raises = system.raiseRequests.count

    model.handleApplicationActivation()
    #expect(await waitFor(timeout: .seconds(3)) { system.raiseRequests.count > raises })
    try await Task.sleep(for: .milliseconds(200))
    let raised = system.raiseRequests.dropFirst(raises)
    #expect(raised.map(\.0) == (dialogHasFocus ? [selected, dialog.id] : [dialog.id, selected]))
    #expect(!raised.contains { $0.1 })
    #expect(system.focusedID == key)
    try expectOneVerifiedRound(model, system, state: state, above: [selected, dialog.id], below: [hidden])

    // The raises' own focus events start no further round.
    let rounds = system.raiseRequests.count
    model.handleApplicationActivation()
    try await Task.sleep(for: .milliseconds(500))
    #expect(system.raiseRequests.count == rounds)
    #expect(system.focusedID == key)
    #expect(model.activeTabbedState == state)
    #expect(model.tabbedRepairDeferred.isEmpty)
}

/// Two floating windows of the front application keep their front-to-back
/// order around the selected tab; the focused one is raised last.
@Test @MainActor func frontApplicationFloatsKeepTheirOrderAfterActivation() async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeOnePaneWithHiddenTabs(system)
    defer { model.shutdown() }
    let state = try #require(model.activeTabbedState)
    system.windows[1].processIdentifier = system.windows[0].processIdentifier
    let selected = system.windows[0].id, hidden = system.windows[1].id
    let front = addFloatedDialog("front-dialog", to: system, x: 100)
    let back = addFloatedDialog("back-dialog", to: system, x: 900)
    system.stack = [system.windows[1], front, system.windows[0], back, system.windows[2], system.windows[3]].map(stackEntry)
    system.raiseFocusesFrontmostApplicationWindow = true
    system.focusedID = front.id
    let raises = system.raiseRequests.count

    model.handleApplicationActivation()
    #expect(await waitFor(timeout: .seconds(3)) { system.raiseRequests.count > raises })
    try await Task.sleep(for: .milliseconds(200))
    #expect(system.raiseRequests.dropFirst(raises).map(\.0) == [back.id, selected, front.id])
    #expect(system.stack?.prefix(4).map(\.windowID) == [front.id, selected, back.id, hidden])
    #expect(system.focusedID == front.id)
    try expectOneVerifiedRound(model, system, state: state, above: [front.id, selected, back.id], below: [hidden])
}

/// Live: after a click on another application's tab, Finder's floated
/// Connect to Server dialog sat behind the new selected tab. The repair
/// raised it about ten times: AXRaise of a background application's window
/// was ignored, so the order never verified and every focus event repeated
/// the raise. The dialog now keeps its place above the curtain. Cmd-Tab
/// back, with Finder's focus on its tab or unreadable, starts no loop either.
@Test(arguments: ["tab", "unknown"]) @MainActor
func aBackgroundDialogKeepsItsPlaceWithoutARaiseLoop(activationFocus: String) async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeOnePaneWithHiddenTabs(system)
    defer { model.shutdown() }
    let selected = system.windows[0].id, finderTab = system.windows[1].id
    var dialog = addFloatedDialog("connect-to-server", to: system, x: 700)
    dialog.processIdentifier = system.windows[1].processIdentifier
    system.windows[system.windows.count - 1] = dialog
    system.stack = [system.windows[0], dialog, system.windows[1], system.windows[2], system.windows[3]].map(stackEntry)
    system.updatesStackOnRaise = false
    system.raiseFocusesFrontmostApplicationWindow = true
    let raises = system.raiseRequests.count

    model.handleApplicationActivation()
    try await Task.sleep(for: .milliseconds(500))
    #expect(system.raiseRequests.count == raises)
    let state = try #require(model.activeTabbedState)
    try expectOneVerifiedRound(model, system, state: state, above: [selected, dialog.id],
                               below: [finderTab, system.windows[2].id, system.windows[3].id])

    // Cmd-Tab to Finder lifts its windows; its focus is on the hidden tab or
    // cannot be read. Whatever the first round does, it is not repeated.
    system.updatesStackOnRaise = true
    system.stack = [system.windows[1], dialog, system.windows[0], system.windows[2], system.windows[3]].map(stackEntry)
    system.focusedID = activationFocus == "tab" ? finderTab : dialog.id
    system.focusedWindowIsUnknown = activationFocus == "unknown"
    model.handleApplicationActivation()
    try await Task.sleep(for: .milliseconds(600))
    #expect(await waitFor { activationFocus != "tab" || model.activeTabbedState?.activeWindowID == finderTab })
    try await Task.sleep(for: .milliseconds(600)) // The selection's own focus refresh.
    let settled = system.raiseRequests.count
    model.handleApplicationActivation()
    try await Task.sleep(for: .milliseconds(600))
    #expect(system.raiseRequests.dropFirst(settled).map(\.0.rawValue) == [])
    #expect(!system.raiseRequests.dropFirst(raises).contains { $0.0 == dialog.id })
    if activationFocus == "tab" {
        #expect(model.activeTabbedState?.activeWindowID == finderTab)
        #expect(system.focusedID == finderTab)
        let state = try #require(model.activeTabbedState)
        try expectOneVerifiedRound(model, system, state: state, above: [finderTab, dialog.id], below: [selected])
    } else {
        // An unreadable focus may be a popup: the repair waits, as before.
        #expect(model.activeTabbedState?.activeWindowID == selected)
        #expect(model.tabbedRepairDeferred == [system.mainDisplay.id])
    }
}

/// Review: Cmd-Tab to an application whose hidden tab sits in front of
/// another application's floating dialog. Raising the background dialog
/// above the hidden tab is ignored by macOS, so that plan never verified and
/// repeated until the curtain gave way. The dialog stays under the curtain.
@Test @MainActor func aBackgroundFloatBehindAHiddenTabStartsNoRaiseLoop() async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeOnePaneWithHiddenTabs(system)
    defer { model.shutdown() }
    let state = try #require(model.activeTabbedState)
    system.windows[1].processIdentifier = system.windows[0].processIdentifier
    var dialog = addFloatedDialog("background-dialog", to: system, x: 700)
    dialog.processIdentifier = system.windows[2].processIdentifier
    system.windows[system.windows.count - 1] = dialog
    system.stack = [system.windows[0], system.windows[1], dialog, system.windows[2], system.windows[3]].map(stackEntry)
    system.updatesStackOnRaise = false
    let raises = system.raiseRequests.count

    model.handleApplicationActivation()
    try await Task.sleep(for: .milliseconds(500))
    #expect(system.raiseRequests.count == raises)
    #expect(model.repairTabbedOrder(state: state, windows: system.windows,
                                    bounds: system.mainDisplay.visibleFrame) == [system.windows[0].id, system.windows[0].id])
    #expect(system.raiseRequests.count == raises)
}

/// An ineligible floating window has no validated window number, so it is
/// never the curtain anchor. A kept window comes with the backmost selected
/// tab as a fallback anchor.
@Test @MainActor func curtainAnchorsSkipIneligibleFloatsAndFallBackToTheSelectedTab() async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeOnePaneWithHiddenTabs(system)
    defer { model.shutdown() }
    var state = try #require(model.activeTabbedState)
    let selected = system.windows[0].id, floated = system.windows[3].id
    state.float(floated)
    let index = try #require(system.windows.firstIndex { $0.id == floated })
    system.windows[index].frame = BTRect(x: 700, y: 200, width: 486, height: 234)
    let dialog = addFloatedDialog("background-dialog", to: system, x: 100)
    system.windows[system.windows.count - 1].processIdentifier = system.windows[2].processIdentifier
    system.stack = [system.windows[0], dialog, system.windows[1], system.windows[2]].map(stackEntry)
    #expect(model.repairTabbedOrder(state: state, windows: system.windows,
                                    bounds: system.mainDisplay.visibleFrame) == [dialog.id, selected])
    // An unmovable floating window behind the selected tab is no anchor.
    system.windows[index].constraints.isMovable = false
    system.stack = [system.windows[0], system.windows[3], system.windows[1], system.windows[2]].map(stackEntry)
    let anchors = model.repairTabbedOrder(state: state, windows: system.windows, bounds: system.mainDisplay.visibleFrame)
    #expect(anchors?.contains(floated) != true)
}

/// A clean repair on one display must not forget a repair that waits on
/// another. The watchdog still retries the waiting display after its popup
/// closes without a notification, and then stops.
@Test @MainActor func aDeferredRepairIsRememberedPerDisplay() async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeOnePaneWithHiddenTabs(system)
    defer { model.shutdown() }
    let main = system.mainDisplay
    let mainState = try #require(model.activeTabbedState)
    let other = DisplaySnapshot(id: DisplayID(rawValue: "other"),
        frame: BTRect(x: 1000, y: 0, width: 1000, height: 800),
        visibleFrame: BTRect(x: 1000, y: 0, width: 1000, height: 800))
    system.availableDisplays.append(other)
    var otherWindow = system.windows[1]
    otherWindow.id = WindowID(rawValue: "other-selected")
    otherWindow.displayID = other.id
    otherWindow.frame.origin.x += 1000
    system.windows.append(otherWindow)
    var otherState = TabbedLayoutState(preset: .single)
    otherState.reconcile(windowIDs: [otherWindow.id], removed: [], focused: otherWindow.id)
    let bubble = addToolbarBubble(to: system)
    system.focusedID = bubble.id
    system.stack = [system.windows[0], bubble, system.windows[1], system.windows[2], system.windows[3], otherWindow]
        .map(stackEntry)

    #expect(model.repairTabbedOrder(state: mainState, windows: system.windows, bounds: main.visibleFrame,
                                    displayID: main.id) == nil)
    #expect(model.tabbedRepairDeferred == [main.id])
    #expect(model.repairTabbedOrder(state: otherState, windows: system.windows, bounds: other.visibleFrame,
                                    displayID: other.id) != nil)
    #expect(model.tabbedRepairDeferred == [main.id])

    system.windows.removeAll { $0.id == bubble.id }
    system.stack?.removeAll { $0.windowID == bubble.id }
    system.focusedID = system.windows[0].id
    model.watchdog()
    #expect(model.tabbedRepairDeferred.isEmpty)
}

/// A dialog or floating panel, such as the Font panel or a file dialog,
/// gets focus back when it is raised last, so the repair still runs while
/// it is open and hidden tabs do not stay exposed.
@Test @MainActor func aFocusedDialogIsRaisedLastInsteadOfDeferringTheRepair() async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeOnePaneWithHiddenTabs(system)
    defer { model.shutdown() }
    var dialog = system.windows[0]
    dialog.id = WindowID(rawValue: "font-panel")
    dialog.frame = BTRect(x: 600, y: 120, width: 300, height: 300)
    dialog.isFloating = true
    system.windows.append(dialog)
    system.stack = [dialog, system.windows[1], system.windows[0], system.windows[2], system.windows[3]].map(stackEntry)
    system.focusedID = dialog.id
    let raises = system.raiseRequests.count
    system.eventHandler?(WindowSystemEvent(kind: .focused, windowID: dialog.id, processIdentifier: dialog.processIdentifier))
    #expect(await waitFor(timeout: .seconds(3)) { system.raiseRequests.count > raises })
    try await Task.sleep(for: .milliseconds(200))
    let raised = system.raiseRequests.dropFirst(raises)
    #expect(raised.map(\.0).first == system.windows[0].id)
    #expect(raised.last?.0 == dialog.id)
    #expect(!raised.contains { $0.1 })
    #expect(model.tabbedRepairDeferred.isEmpty)
}

/// Live: a click on the selected browser tab's toolbar started a drag that
/// tore the tab from its group. Its release placed the group again and
/// activated the window, which closed the bubble the click opened. A
/// release that moved nothing restores the group without a placement.
@Test(arguments: [false, true]) @MainActor
func aTabbedDragThatMovesNothingRestoresTheGroupWithoutAPlacement(popupFocused: Bool) async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeOnePaneWithHiddenTabs(system)
    defer { model.shutdown() }
    let state = try #require(model.activeTabbedState)
    if popupFocused { system.focusedID = addToolbarBubble(to: system).id }
    let frames = system.windows.map(\.frame)
    let writes = system.frameWriteCounts
    let raises = system.raiseRequests.count
    let selected = system.windows[0].id
    #expect(model.completeBentoDrag(displayID: system.mainDisplay.id, sourceID: selected, outcome: .restore))
    try await Task.sleep(for: .milliseconds(300))
    #expect(model.activeTabbedState == state)
    #expect(system.raiseRequests.count == raises)
    #expect(system.windows.map(\.frame) == frames)
    #expect(system.frameWriteCounts == writes)
}

/// A drag that did move the selected tab is placed back. While its
/// application's bubble has focus, the placement orders and focuses none of
/// that application's windows. When the tab already has focus, it is only
/// ordered, not activated again.
@Test(arguments: [false, true]) @MainActor
func aTabbedPlacementKeepsAPopupsFocusAndDoesNotRefocusTheFocusedTab(popupFocused: Bool) async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeOnePaneWithHiddenTabs(system)
    defer { model.shutdown() }
    let state = try #require(model.activeTabbedState)
    let bubble = popupFocused ? addToolbarBubble(to: system) : nil
    system.focusedID = bubble?.id ?? system.windows[0].id
    let selected = system.windows[0].id
    let original = system.windows[0].frame
    let raises = system.raiseRequests.count
    let focusRequests = system.focusRequests.count
    #expect(model.beginBentoDrag(displayID: system.mainDisplay.id, sourceID: selected))
    system.windows[0].frame.origin.x += 40
    model.finishBentoDrag(displayID: system.mainDisplay.id, sourceID: selected, outcome: .restore)
    #expect(await waitFor(timeout: .seconds(3)) { system.windows[0].frame == original })
    try await Task.sleep(for: .milliseconds(300))
    #expect(model.activeTabbedState == state)
    #expect(system.focusRequests.count == focusRequests)
    let raised = system.raiseRequests.dropFirst(raises)
    if popupFocused {
        #expect(!raised.contains { $0.0 == selected })
        #expect(system.focusedID == bubble?.id)
    } else {
        #expect(raised.contains { $0.0 == selected })
        #expect(!raised.contains { $0.1 })
    }
}

@Test(arguments: [false, true]) @MainActor
func stackingRepairKeepsAWindowInFrontOrLeavesAnUnreadableOneAlone(readable: Bool) async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTwoTabbedColumns(system)
    defer { model.shutdown() }
    let right = system.windows[3].frame
    let floating = WindowID(rawValue: "ignored-floating")
    // A window outside Tabbed was in front of the right pane before a hidden
    // tab came forward.
    let front = TabbedStackEntry(windowID: readable ? floating : nil,
                                 frame: BTRect(x: right.minX + 50, y: right.minY + 50, width: 200, height: 150))
    system.stack = [stackEntry(system.windows[2]), front] + [3, 0, 1].map { stackEntry(system.windows[$0]) }
    system.focusedID = system.windows[0].id
    let raises = system.raiseRequests.count

    model.handleApplicationActivation()
    if readable {
        // The stacking check is asynchronous; wait for it on a loaded runner.
        try #require(await waitFor(timeout: .seconds(3)) { system.raiseRequests.count >= raises + 3 })
    }
    try await Task.sleep(for: .milliseconds(500))
    let raised = system.raiseRequests.dropFirst(raises)
    #expect(raised.map(\.0) == (readable ? [system.windows[0].id, system.windows[3].id, floating] : []))
    #expect(!raised.contains { $0.1 })
}

@Test(arguments: [false, true]) @MainActor
func activationRepairsHiddenTabsOnAnotherTabbedDisplay(focusedDisplayTabbed: Bool) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    addTabbedWindows(2, to: system)
    let other = DisplayID(rawValue: "other")
    system.availableDisplays.append(DisplaySnapshot(id: other,
        frame: BTRect(x: 1000, y: 0, width: 1000, height: 800),
        visibleFrame: BTRect(x: 1000, y: 0, width: 1000, height: 800)))
    for index in 1...2 { system.windows[index].displayID = other }
    system.windows[1].processIdentifier = system.windows[0].processIdentifier
    let model = makeModel(system: system)
    defer { model.shutdown() }
    if focusedDisplayTabbed {
        model.setActiveMode(.tabbed)
        try #require(await waitFor { model.activeTabbedState?.windowIDs == [system.windows[0].id] })
    }
    system.focusedID = system.windows[2].id
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 2 })
    try #require(model.activeTabbedState?.activeWindowID == system.windows[2].id)
    try await Task.sleep(for: .milliseconds(350)) // Let both entry placements settle.
    let frames = system.windows.map(\.frame)
    let writes = system.frameWriteCounts
    let raises = system.raiseRequests.count

    try await Task.sleep(for: .milliseconds(100))
    #expect(system.raiseRequests.count == raises) // An unchanged desktop settles once.

    // Cmd-Tab to the first window's app also raised its hidden tab on the
    // other display.
    system.stack = [1, 0, 2].map { stackEntry(system.windows[$0]) }
    system.focusedID = system.windows[0].id
    model.handleApplicationActivation()
    #expect(await waitFor(timeout: .seconds(1)) { system.raiseRequests.count > raises })
    #expect(system.raiseRequests.dropFirst(raises).map(\.0) == [system.windows[2].id])
    #expect(!system.raiseRequests.dropFirst(raises).contains { $0.1 })
    #expect(system.focusedID == system.windows[0].id)
    #expect(system.windows.map(\.frame) == frames)
    #expect(system.frameWriteCounts == writes)
}

@Test(arguments: [false, true]) @MainActor
func tabSelectionPreservesFloatingOrderWhenRepairingTheSharedCurtain(readableOrder: Bool) async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTwoTabbedColumns(system)
    defer { model.shutdown() }
    // The left hidden tab shares an app with the right selected tab, and a
    // floating window is in front of the right pane.
    system.windows[1].processIdentifier = system.windows[3].processIdentifier
    let right = system.windows[3].frame
    let floating = TabbedStackEntry(windowID: WindowID(rawValue: "floating"),
                                    frame: BTRect(x: right.minX + 50, y: right.minY + 50, width: 200, height: 150))
    if readableOrder { system.stack = [floating] + [0, 3, 1, 2].map { stackEntry(system.windows[$0]) } }
    let raises = system.raiseRequests.count

    let target = system.windows[1].id
    model.performTabbed(.select(target))
    #expect(await waitFor(timeout: .seconds(3)) { model.activeTabbedState?.activeWindowID == target })
    // The formerly selected left tab is now inactive above the right
    // selection. Repair puts both selected tabs above it, preserving floating.
    let expected: Set<WindowID> = readableOrder ? [target, system.windows[3].id, floating.windowID!]
                                                : [target, system.windows[3].id]
    // The stacking check follows the selection asynchronously.
    _ = await waitFor(timeout: .seconds(3)) { Set(system.raiseRequests.dropFirst(raises).map(\.0)) == expected }
    try await Task.sleep(for: .milliseconds(200))
    let raised = Set(system.raiseRequests.dropFirst(raises).map(\.0))
    #expect(raised == expected)
}

@Test(arguments: [false, true]) @MainActor
func tabbedCurtainsResolveOnlySelectedWindowsAfterPlacementAndFocus(failSelection: Bool) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    addTabbedWindows(1, to: system)
    // Keep the test panels off-screen; no desktop capture or live AX.
    system.availableDisplays[0].frame.origin.x = 12000
    system.availableDisplays[0].visibleFrame.origin.x = 12000
    for index in system.windows.indices { system.windows[index].frame.origin.x += 12000 }
    let store = ConfigurationStore(fileURL: URL(filePath: "/private/tmp/BetterTileAppTests-\(UUID().uuidString)/configuration.json"))
    let model = BetterTileModel(store: store, system: system, startRuntime: false, presentsTabbedChrome: true)
    model.primaryButtonIsPressed = { false }
    defer { model.shutdown() }
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 2 })
    #expect(system.windowNumberRequests.last == [system.windows[0].id])
    let hidden = system.windows[1].id
    let initialRequests = system.windowNumberRequests.count
    // The early raise and the verified placement both fail to order it.
    if failSelection { system.failingRaiseWindowIDs = [hidden] }
    model.performTabbed(.select(hidden))
    let shown = failSelection ? system.windows[0].id : hidden
    if failSelection { try #require(await waitFor { model.statusMessage != nil }) }
    else { try #require(await waitFor { model.activeTabbedState?.activeWindowID == shown }) }
    #expect(system.windowNumberRequests.count > initialRequests) // Rollback reorders curtains too.
    #expect(system.windowNumberRequests.last == [shown])
    let requests = system.windowNumberRequests.count
    let status = model.statusMessage
    model.handleApplicationActivation()
    let focusRefresh = try #require(model.tabbedFocusTask)
    await focusRefresh.value
    #expect(system.windowNumberRequests.count > requests)
    #expect(system.windowNumberRequests.last == [shown])
    #expect(model.statusMessage == status) // Missing IDs add no error.
}

@Test(arguments: [false, true]) @MainActor
func tabSelectionDoesNotRearrangeOrRefitOtherWindows(sharedApplication: Bool) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    for index in 1...3 {
        var window = system.windows[0]
        window.id = WindowID(rawValue: "tab-\(index)")
        window.processIdentifier += Int32(index)
        system.windows.append(window)
    }
    if sharedApplication { system.windows[2].processIdentifier = system.windows[1].processIdentifier }
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 4 })
    let right = try #require(model.activeTabbedState?.panes[1].id)
    model.performTabbed(.move(system.windows[2].id, pane: right, index: nil))
    try #require(await waitFor { model.activeTabbedState?.panes[1].selected == system.windows[2].id })
    model.performTabbed(.move(system.windows[3].id, pane: right, index: nil))
    try #require(await waitFor { model.activeTabbedState?.panes[1].selected == system.windows[3].id })
    let previous = try #require(model.activeTabbedState)
    // Another app has changed its constraints and frame. A tab click must not
    // refit that pane or fail because that unrelated app cannot be resized.
    system.windows[3].constraints.isResizable = false
    system.windows[3].constraints.minimumSize.width = 900
    system.windows[3].frame = BTRect(x: 550, y: 70, width: 400, height: 600)
    let frames = system.windows.map(\.frame)
    let writes = system.frameWriteCounts
    let raises = system.raiseRequests.count
    let target = system.windows[1].id
    model.performTabbed(.select(target))
    #expect(await waitFor(timeout: .seconds(1)) { model.activeTabbedState?.activeWindowID == target })
    // Selecting swaps which window a pane shows; pane geometry stays put.
    #expect(model.activeTabbedState?.frames(in: system.mainDisplay.visibleFrame) == previous.frames(in: system.mainDisplay.visibleFrame))
    #expect(model.activeTabbedState?.panes[1] == previous.panes[1])
    #expect(system.windows.map(\.frame) == frames)
    #expect(system.frameWriteCounts == writes)
    #expect(system.focusedID == target)
    let raisedOtherPane = system.raiseRequests.dropFirst(raises).contains { $0.0 == system.windows[3].id }
    #expect(raisedOtherPane == sharedApplication)
}

@Test @MainActor func activatingEmptyTabbedPaneCancelsAnOlderFocusNotification() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.panes.count == 2 })
    let emptyPane = try #require(model.activeTabbedState?.panes[1].id)
    system.eventHandler?(WindowSystemEvent(kind: .focused, windowID: system.windows[0].id, processIdentifier: system.windows[0].processIdentifier))
    model.performTabbed(.activate(emptyPane))
    try await Task.sleep(for: .milliseconds(400))
    #expect(model.activeTabbedState?.activePaneID == emptyPane)
}

@Test @MainActor func failedTabbedFocusReadDoesNotLeaveARefreshPending() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 1 })
    try await Task.sleep(for: .milliseconds(350))
    system.focusedWindowReadFails = true
    system.eventHandler?(WindowSystemEvent(kind: .focused, windowID: system.windows[0].id, processIdentifier: system.windows[0].processIdentifier))
    #expect(model.tabbedNeedsFocusRefresh)
    let refresh = try #require(model.tabbedFocusTask)
    await refresh.value
    #expect(!model.tabbedNeedsFocusRefresh)
}

@Test @MainActor func repairCurrentLayoutRestoresTabbedFramesAndPreservesGroups() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.panes.count == 2 })
    let before = try #require(model.activeTabbedState)
    let frame = system.windows[0].frame
    system.windows[0].frame = BTRect(x: 100, y: 150, width: 600, height: 500)
    model.repairCurrentLayout()
    try #require(await waitFor { system.windows[0].frame == frame })
    #expect(model.activeLayoutMode == .tabbed)
    #expect(model.activeTabbedState == before)
}

@Test(arguments: [false, true], [600.0, 611.37]) @MainActor
func tabbedModelAdaptsReportedAndLearnedWidthsAndRetainsThemThroughUndo(learnWidth: Bool, minimumWidth: Double) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    system.windows[0].frame = BTRect(x: 50, y: 50, width: 800, height: 500)
    var wide = system.windows[0]
    wide.id = WindowID(rawValue: "wide")
    wide.processIdentifier = 43
    if learnWidth { system.enforcedMinimumWidths[wide.id] = minimumWidth }
    else { wide.constraints.minimumSize.width = minimumWidth }
    system.windows.append(wide)
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 2 })
    // Both tabs share one pane below the strip. The hidden wide tab does not
    // widen the pane: only the selected tab's minimum counts.
    #expect(system.windows.allSatisfy { $0.frame.minY == 34 })
    let shown = try #require(model.activeTabbedState?.panes[0].selected)
    #expect(shown != wide.id)
    #expect(abs((system.windows.first { $0.id == shown }?.frame.size.width ?? 0) - 497) < 0.001)

    let right = try #require(model.activeTabbedState?.panes[1].id)
    model.performTabbed(.move(wide.id, pane: right, index: nil))
    try #require(await waitFor { model.activeTabbedState?.panes[1].tabs == [wide.id] })
    #expect(abs(system.windows[0].frame.size.width - (994 - minimumWidth)) < 0.001)
    #expect(abs(system.windows[1].frame.size.width - minimumWidth) < 0.001)
    let fitted = try #require(model.activeTabbedState)
    let frames = system.windows.map(\.frame)
    #expect(abs(fitted.frames(in: system.mainDisplay.visibleFrame)[right]!.size.width - system.windows[1].frame.size.width) < 0.001)
    model.performTabbed(.preset(.single))
    try #require(await waitFor { model.activeTabbedState?.panes.count == 1 })
    model.performTabbed(.undo)
    try #require(await waitFor { model.activeTabbedState?.panes.count == 2 })
    #expect(model.activeTabbedState == fitted)
    #expect(system.windows.map(\.frame) == frames)
}

@Test @MainActor func tabbedImpossibleWidthMovePreservesMembershipAndFrames() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    system.windows[0].constraints.minimumSize.width = 300
    var wide = system.windows[0]
    wide.id = WindowID(rawValue: "wide")
    wide.constraints.minimumSize.width = 800
    wide.frame.size.width = 800
    system.windows.append(wide)
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 2 })
    let before = try #require(model.activeTabbedState)
    let frames = system.windows.map(\.frame)
    let writes = system.frameWriteCounts
    model.performTabbed(.move(wide.id, pane: before.panes[1].id, index: nil))
    #expect(model.statusMessage != nil)
    #expect(model.activeTabbedState == before)
    #expect(system.windows.map(\.frame) == frames)
    #expect(system.frameWriteCounts == writes)
}

@Test(arguments: [false, true]) @MainActor
func tabbedLearnedWidthFailureDoesNotCommitOrRetryDegradedRestoration(failRestore: Bool) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let id = system.windows[0].id
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState != nil })
    let before = try #require(model.activeTabbedState)
    let frame = system.windows[0].frame
    let writes = system.frameWriteCounts[id, default: 0]
    // With an empty pane's 120-point minimum, 900 cannot fit this display.
    system.enforcedMinimumWidths[id] = failRestore ? 600 : 900
    if failRestore { system.failedFrameWriteNumbers[id] = [writes + 2] }
    model.statusMessage = nil
    model.performTabbed(.preset(.columns))
    try #require(await waitFor { model.statusMessage != nil })
    #expect(model.activeTabbedState == before)
    #expect(system.frameWriteCounts[id] == writes + 2)
    if !failRestore { #expect(system.windows[0].frame == frame) }
}

@Test @MainActor func tabbedImpossibleHeightRefusalLearnsBothAxesAndPreservesFrames() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let id = system.windows[0].id
    system.windows[0].frame = BTRect(x: 0, y: 0, width: 800, height: 800)
    system.enforcedMinimumWidths[id] = 600
    system.enforcedMinimumHeights[id] = 780
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.singleWindowPlacement = nil
    let before = system.windows[0].frame
    let writes = system.frameWriteCounts[id, default: 0]
    model.configuration.defaultTabbedPreset = .columns
    model.statusMessage = nil
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.statusMessage != nil })
    #expect(model.activeTabbedState == nil)
    #expect(system.windows[0].frame == before)
    #expect(system.frameWriteCounts[id] == writes + 2)
    #expect(system.windows[0].constraints.minimumSize.width == 600)
    #expect(system.windows[0].constraints.minimumSize.height == 780)
}

@Test @MainActor func tabbedFailedUndoCanBeRetried() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.panes.count == 2 })
    model.performTabbed(.preset(.single))
    try #require(await waitFor { model.activeTabbedState?.panes.count == 1 })

    model.statusMessage = nil
    system.ignoredFrameWriteWindowIDs = [system.windows[0].id]
    model.performTabbed(.undo)
    try #require(await waitFor { model.statusMessage != nil })
    #expect(model.activeTabbedState?.panes.count == 1)

    system.ignoredFrameWriteWindowIDs = []
    model.performTabbed(.undo)
    #expect(await waitFor { model.activeTabbedState?.panes.count == 2 })
}

@Test @MainActor func tabbedModelSupportsEmptyPanePlacementAndNativeRestoration() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let first = system.windows[0]
    let second = WindowSnapshot(id: WindowID(rawValue: "second"), processIdentifier: 43,
                                frame: BTRect(x: 10, y: 10, width: 400, height: 300), displayID: first.displayID)
    system.windows.append(second)
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.panes.count == 2 })
    let state = try #require(model.activeTabbedState)
    #expect(state.panes[0].tabs.count == 2)
    #expect(state.panes[1].tabs.isEmpty)
    #expect(system.windows[0].frame == system.windows[1].frame)
    model.performTabbed(.activate(state.panes[1].id))
    let third = WindowSnapshot(id: WindowID(rawValue: "third"), processIdentifier: 44,
                               frame: BTRect(x: 10, y: 10, width: 400, height: 300), displayID: first.displayID)
    system.windows.append(third)
    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: third.id, processIdentifier: 44))
    try #require(await waitFor { model.activeTabbedState?.panes[1].selected == third.id })
    #expect(model.activeTabbedState?.panes[1].tabs == [third.id])
    let thirdTabbedFrame = system.windows[2].frame
    model.setActiveMode(.manual)
    try #require(await waitFor { model.activeLayoutMode == .manual })
    #expect(system.windows[0].frame == first.frame)
    #expect(system.windows[1].frame == second.frame)
    #expect(system.windows[2].frame == thirdTabbedFrame)
    model.setActiveMode(.tabbed)
    try #require(await waitFor { system.windows[0].frame.minY == 34 })
    #expect(model.activeTabbedState?.panes[1].tabs == [third.id])
}

@Test @MainActor func tabbedModelKeepsNativeSpaceSessionsSeparate() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let display = system.mainDisplay.id
    let a = NativeSpaceID(rawValue: 1), b = NativeSpaceID(rawValue: 2)
    system.desktopObservation = NativeDesktopObservation(currentSpaceByDisplay: [display: a], knownSpacesByDisplay: [display: [a, b]], windowMembership: [system.windows[0].id: [a]])
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.singleWindowPlacement = nil
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState != nil })
    let originalPane = model.activeTabbedState?.panes[0].id
    let firstWindows = system.windows
    model.installWorkspaceTriggers()
    system.desktopObservation?.currentSpaceByDisplay[display] = b
    system.windows = []
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    try #require(await waitFor { model.activeLayoutMode == .manual })
    system.desktopObservation?.currentSpaceByDisplay[display] = a
    system.windows = firstWindows
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    try #require(await waitFor { model.activeLayoutMode == .tabbed && model.activeTabbedState?.panes[0].id == originalPane })
}

@Test @MainActor func tabbedModelFloatCanBeReattachedAndPresetUndoRestoresAssignments() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let first = system.windows[0]
    system.windows.append(WindowSnapshot(id: WindowID(rawValue: "second"), processIdentifier: 43,
                                        frame: first.frame, displayID: first.displayID))
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 2 })
    model.performTabbed(.float(first.id))
    try #require(await waitFor { model.activeTabbedState?.floatingWindowIDs.contains(first.id) == true })
    #expect(system.focusedID == first.id)
    #expect(system.windows[0].frame == first.frame)
    let pane = try #require(model.activeTabbedState?.panes[0].id)
    model.performTabbed(.move(first.id, pane: pane, index: nil))
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 2 })
    model.performTabbed(.preset(.columns))
    try #require(await waitFor { model.activeTabbedState?.panes.count == 2 })
    model.performTabbed(.undo)
    try #require(await waitFor { model.activeTabbedState?.panes.count == 1 })
    #expect(model.activeTabbedState?.panes[0].id == pane)
    #expect(model.activeTabbedState?.windowIDs.count == 2)
}

@Test(arguments: ["unchanged", "larger-minimum", "learned-minimum", "oversized-minimum", "oversized-baseline", "no-entry-baseline", "no-entry-larger-minimum"]) @MainActor
func floatingATabRestoresAReachableFrameRespectingCurrentMinimums(scenario: String) async throws {
    let system = FakeAppWindowSystem()
    if scenario == "oversized-baseline" {
        system.windows[0].frame = BTRect(x: -50, y: 200, width: 1100, height: 400)
    }
    let entryWindow = system.windows[0]
    if scenario.hasPrefix("no-entry") { system.windows = [] }
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.singleWindowPlacement = nil
    model.configuration.defaultTabbedPreset = .single
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState != nil })
    if scenario.hasPrefix("no-entry") {
        system.windows = [entryWindow]
        system.eventHandler?(WindowSystemEvent(kind: .created, windowID: entryWindow.id,
                                              processIdentifier: entryWindow.processIdentifier))
    }
    try #require(await waitFor { model.activeTabbedState?.windowIDs == [entryWindow.id] })
    let expected: BTRect
    switch scenario {
    case "larger-minimum":
        system.windows[0].constraints.minimumSize = BTSize(width: 640, height: 480)
        expected = BTRect(x: 200, y: 200, width: 640, height: 480)
    case "learned-minimum":
        try #require(system.observeApplicationEnforcedMinimum(
            windowID: entryWindow.id,
            requested: BTRect(x: 200, y: 200, width: 400, height: 300),
            baseline: BTRect(x: 200, y: 200, width: 800, height: 600),
            actual: BTRect(x: 200, y: 200, width: 640, height: 480)
        ))
        expected = BTRect(x: 200, y: 200, width: 640, height: 480)
    case "oversized-minimum":
        system.windows[0].constraints.minimumSize = BTSize(width: 1200, height: 400)
        expected = BTRect(x: 0, y: 200, width: 1200, height: 400)
    case "no-entry-baseline":
        expected = BTRect(x: 0, y: 34, width: 1000, height: 766)
    case "no-entry-larger-minimum":
        system.windows[0].constraints.minimumSize = BTSize(width: 1200, height: 900)
        expected = BTRect(x: 0, y: 0, width: 1200, height: 900)
    default: expected = entryWindow.frame
    }
    model.statusMessage = nil
    model.performTabbed(.float(entryWindow.id))
    try #require(await waitFor { model.activeTabbedState?.floatingWindowIDs.contains(entryWindow.id) == true })
    #expect(model.activeTabbedState?.windowIDs.contains(entryWindow.id) == false)
    #expect(model.activeLayoutMode == .tabbed)
    #expect(system.windows[0].frame == expected)
    #expect(model.statusMessage == nil)
}

@Test(arguments: [false, true]) @MainActor
func rejectedFloatingRestorationRetainsTabbedMembershipAndFrames(ignored: Bool) async throws {
    let system = FakeAppWindowSystem()
    let id = system.windows[0].id
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.singleWindowPlacement = nil
    model.configuration.defaultTabbedPreset = .single
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs == [id] })
    let state = try #require(model.activeTabbedState)
    let frame = system.windows[0].frame
    let writes = system.frameWriteCounts[id, default: 0]
    if ignored { system.ignoredFrameWriteWindowIDs.insert(id) }
    else { system.failedFrameWriteNumbers[id] = [writes + 1] }
    model.statusMessage = nil
    model.performTabbed(.float(id))
    try #require(await waitFor { model.statusMessage != nil || model.activeTabbedState?.floatingWindowIDs.contains(id) == true })
    #expect(model.statusMessage != nil)
    #expect(model.activeTabbedState == state)
    #expect(system.windows[0].frame == frame)
    #expect(system.frameWriteCounts[id, default: 0] > writes)
}

@Test @MainActor func failedFloatingBatchRollsBackAndDoesNotAddUndo() async throws {
    let system = FakeAppWindowSystem()
    addTabbedWindows(1, to: system)
    let first = system.windows[0].id, second = system.windows[1].id
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.singleWindowPlacement = nil
    model.configuration.defaultTabbedPreset = .single
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 2 })
    let initial = try #require(model.activeTabbedState)
    model.performTabbed(.preset(.columns))
    try #require(await waitFor { model.activeTabbedState?.panes.count == 2 })
    let right = try #require(model.activeTabbedState?.panes[1].id)
    model.performTabbed(.move(second, pane: right, index: nil))
    try #require(await waitFor { model.activeTabbedState?.panes[1].selected == second })
    let state = try #require(model.activeTabbedState)
    // The second required participant must be rewritten after the first tab's
    // native frame has already been restored, then reject that batch write.
    system.windows[1].frame = system.windows[1].frame.offsetBy(dx: 10, dy: 10)
    let frames = system.windows.map(\.frame)
    let writes = system.frameWriteCounts
    system.failedFrameWriteNumbers[second] = [writes[second, default: 0] + 1]
    model.statusMessage = nil
    model.performTabbed(.float(first))
    try #require(await waitFor { model.statusMessage != nil || model.activeTabbedState?.floatingWindowIDs.contains(first) == true })
    #expect(model.statusMessage != nil)
    #expect(model.activeTabbedState == state)
    #expect(system.windows.map(\.frame) == frames)
    #expect(system.frameWriteCounts[first, default: 0] >= writes[first, default: 0] + 2)
    system.failedFrameWriteNumbers = [:]
    model.performTabbed(.undo)
    try #require(await waitFor { model.activeTabbedState != state })
    // The failed float added nothing: Undo removes the successful move, then
    // the successful preset, returning to the original single pane.
    #expect(model.activeTabbedState?.floatingWindowIDs.isEmpty == true)
    #expect(model.activeTabbedState?.panes[1].tabs.isEmpty == true)
    model.performTabbed(.undo)
    try #require(await waitFor { model.activeTabbedState?.panes.count == 1 })
    #expect(model.activeTabbedState == initial)
}

@Test @MainActor func floatingRestorationLearnsAnUnreportedMinimumAndRetriesOnce() async throws {
    let system = FakeAppWindowSystem()
    let id = system.windows[0].id
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.singleWindowPlacement = nil
    model.configuration.defaultTabbedPreset = .single
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs == [id] })
    let writes = system.frameWriteCounts[id, default: 0]
    system.enforcedMinimumWidths[id] = 640
    system.enforcedMinimumHeights[id] = 480
    model.statusMessage = nil
    model.performTabbed(.float(id))
    try #require(await waitFor { model.activeTabbedState?.floatingWindowIDs.contains(id) == true || model.statusMessage != nil })
    #expect(model.activeTabbedState?.floatingWindowIDs.contains(id) == true)
    #expect(system.windows[0].frame == BTRect(x: 200, y: 200, width: 640, height: 480))
    #expect(system.windows[0].constraints.minimumSize == BTSize(width: 640, height: 480))
    #expect(system.frameWriteCounts[id] == writes + 3)
    #expect(model.statusMessage == nil)
}

@Test @MainActor func destroyedFloatingTabbedWindowIsRemovedFromStateAndUndo() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let first = system.windows[0]
    var second = first
    second.id = WindowID(rawValue: "second")
    system.windows.append(second)
    let model = makeModel(system: system)
    defer { model.shutdown() }

    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 2 })
    model.performTabbed(.float(first.id))
    try #require(await waitFor { model.activeTabbedState?.floatingWindowIDs.contains(first.id) == true })
    model.performTabbed(.preset(.columns))
    try #require(await waitFor { model.activeTabbedState?.panes.count == 2 })

    system.windows.removeAll { $0.id == first.id }
    system.eventHandler?(WindowSystemEvent(
        kind: .destroyed,
        windowID: first.id,
        processIdentifier: first.processIdentifier
    ))

    try #require(await waitFor { model.activeTabbedState?.floatingWindowIDs.contains(first.id) == false })
    model.performTabbed(.undo)
    try #require(await waitFor { model.activeTabbedState?.panes.count == 1 })
    #expect(model.activeTabbedState?.windowIDs.contains(first.id) == false)
    #expect(model.activeTabbedState?.floatingWindowIDs.contains(first.id) == false)
}

@Test @MainActor func tabbedEmptyActivationDoesNotCaptureNewWindowAsPreexistingBaseline() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let window = system.windows[0]
    system.windows = []
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState != nil })
    system.windows = [window]
    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: window.id, processIdentifier: window.processIdentifier))
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 1 })
    let frame = system.windows[0].frame
    model.configuration.singleWindowPlacement = nil
    model.setActiveMode(.manual)
    try #require(await waitFor { model.activeLayoutMode == .manual })
    #expect(system.windows[0].frame == frame)
}

@MainActor private func tabbedWindows(_ system: FakeAppWindowSystem, _ names: [String]) -> [WindowSnapshot] {
    let base = system.windows[0]
    system.windows = names.enumerated().map { index, name in
        var window = base
        window.id = WindowID(rawValue: name)
        window.processIdentifier = pid_t(100 + index)
        window.frame = BTRect(x: 20 * Double(index), y: 20, width: 500, height: 400)
        return window
    }
    return system.windows
}

@Test @MainActor func tabbedHalfScreenSplitIgnoresAHiddenTabsMinimum() async throws {
    // Reported failure: a tab dragged to half the screen said the layout
    // could not apply because a hidden wide tab counted.
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    var windows = tabbedWindows(system, ["a", "b", "wide"])
    windows[2].constraints.minimumSize.width = 900
    system.windows = windows
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 3 })
    let state = try #require(model.activeTabbedState)
    let b = WindowID(rawValue: "b")
    if state.activeWindowID == WindowID(rawValue: "wide") { model.performTabbed(.select(WindowID(rawValue: "a"))) }
    try #require(await waitFor { model.activeTabbedState?.activeWindowID != WindowID(rawValue: "wide") })
    model.statusMessage = nil
    model.performTabbed(.split(b, pane: state.panes[0].id, edge: .right))
    try #require(await waitFor { model.activeTabbedState?.panes.count == 2 })
    #expect(model.statusMessage == nil)
    let frames = Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, $0.frame) })
    #expect(abs(frames[b]!.size.width - 497) < 1)
    #expect(frames[b]!.minX > 500)
}

@Test @MainActor func tabbedWindowDragsUseBentoAndCenterDropsAddATab() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    _ = tabbedWindows(system, ["a", "b", "c"])
    let a = WindowID(rawValue: "a"), b = WindowID(rawValue: "b"), c = WindowID(rawValue: "c")
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 3 })
    let right = try #require(model.activeTabbedState?.panes[1].id)
    model.performTabbed(.move(b, pane: right, index: nil))
    try #require(await waitFor { model.activeTabbedState?.panes[1].tabs == [b] })
    let display = system.mainDisplay.id

    // Tear one tab out of the left group and drop it on the right pane's edge:
    // Bento splits, and the rest of the group stays where it was.
    let left = try #require(model.activeTabbedState?.panes[0])
    let torn = try #require(left.selected)
    let remaining = try #require(left.tabs.first { $0 != torn })
    #expect(model.completeBentoDrag(displayID: display, sourceID: torn, outcome: .insert(targetWindowID: b, edge: .bottom)))
    try #require(await waitFor { model.activeTabbedState?.panes.count == 3 })
    #expect(model.activeTabbedState?.panes[0].tabs == [remaining])
    #expect(model.activeTabbedState?.panes.first { $0.tabs == [torn] } != nil)
    #expect(model.activeTabbedState?.layout.metrics.contentTopInset == TabbedLayoutState.headerHeight)

    // A center drop adds the window to that pane as a tab.
    #expect(model.completeBentoDrag(displayID: display, sourceID: torn, outcome: .swap(targetWindowID: b)))
    try #require(await waitFor { model.activeTabbedState?.pane(containing: b)?.tabs.contains(torn) == true })
    #expect(model.activeTabbedState?.pane(containing: b)?.selected == torn)
    let bFrame = system.windows.first { $0.id == b }?.frame
    #expect(await waitFor { system.windows.first { $0.id == torn }?.frame == bFrame })

    // A torn tab dropped nowhere returns to its group.
    let group = try #require(model.activeTabbedState?.pane(containing: b))
    #expect(model.completeBentoDrag(displayID: display, sourceID: torn, outcome: .restore))
    try #require(await waitFor { model.activeTabbedState?.pane(containing: torn)?.id == group.id })
    _ = a; _ = c
}

@Test @MainActor func tabbedPointerDropsRecordUndo() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    _ = tabbedWindows(system, ["a", "b", "c"])
    let b = WindowID(rawValue: "b")
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 3 })
    let right = try #require(model.activeTabbedState?.panes[1].id)
    model.performTabbed(.move(b, pane: right, index: nil))
    try #require(await waitFor { model.activeTabbedState?.panes[1].tabs == [b] })
    let before = try #require(model.activeTabbedState)
    let torn = try #require(before.panes[0].selected)
    // An edge drop is a Bento split; Undo returns the torn tab to its group.
    #expect(model.completeBentoDrag(displayID: system.mainDisplay.id, sourceID: torn,
                                    outcome: .insert(targetWindowID: b, edge: .bottom)))
    try #require(await waitFor { model.activeTabbedState?.panes.count == 3 })
    try #require(await waitFor { model.activeTabbedState?.pane(containing: torn)?.tabs == [torn] })
    model.performTabbed(.undo)
    #expect(await waitFor { model.activeTabbedState?.pane(containing: torn)?.id == before.panes[0].id })
}

@Test func leavingTabbedForBentoRestoresPlainBentoMetrics() {
    var state = TabbedLayoutState(preset: .columns)
    state.reconcile(windowIDs: [WindowID(rawValue: "a")], removed: [], focused: nil)
    let bento = state.unstacked(in: BTRect(x: 0, y: 0, width: 1000, height: 800))
    #expect(bento.metrics.contentTopInset == 0)
    #expect(bento.metrics.vacantMinimumSize == BTSize(width: 0, height: 0))
}

@MainActor private func addTabbedWindows(_ count: Int, to system: FakeAppWindowSystem) {
    for index in 1...count {
        var window = system.windows[0]
        window.id = WindowID(rawValue: "tab-\(index)")
        window.processIdentifier += Int32(index)
        system.windows.append(window)
    }
}

@MainActor private func sendResize(_ id: WindowID, to frame: BTRect, in system: FakeAppWindowSystem) throws {
    let index = try #require(system.windows.firstIndex { $0.id == id })
    system.windows[index].frame = frame
    system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: id, processIdentifier: system.windows[index].processIdentifier))
}

@MainActor private func frame(_ id: WindowID, in system: FakeAppWindowSystem) -> BTRect? {
    system.windows.first { $0.id == id }?.frame
}

@Test(arguments: [false, true]) @MainActor
func tabbedOnePaneEdgeResizeSnapsBackAfterRelease(holdButton: Bool) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    addTabbedWindows(1, to: system)
    let model = makeModel(system: system)
    defer { model.shutdown() }
    var pressed = false
    model.primaryButtonIsPressed = { pressed }
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 2 })
    let state = try #require(model.activeTabbedState)
    let pane = try #require(state.frames(in: system.mainDisplay.visibleFrame)[state.panes[0].id])
    let content = TabbedLayoutState.contentFrame(pane)
    try #require(await waitFor { system.windows.allSatisfy { $0.frame == content } })
    try await Task.sleep(for: .milliseconds(350))
    let selected = try #require(state.panes[0].selected)
    let hidden = try #require(state.panes[0].tabs.first { $0 != selected })
    let shrunk = BTRect(x: content.minX, y: content.minY, width: content.size.width - 300, height: content.size.height)

    pressed = holdButton
    try sendResize(selected, to: shrunk, in: system)
    if holdButton {
        // The edge is still held: BetterTile must not fight the drag.
        try await Task.sleep(for: .milliseconds(400))
        #expect(frame(selected, in: system) == shrunk)
        pressed = false
    }
    #expect(await waitFor(timeout: .seconds(2)) { frame(selected, in: system) == content })
    #expect(frame(hidden, in: system) == content)
    #expect(model.activeTabbedState?.panes == state.panes)
    #expect(model.activeTabbedState?.frames(in: system.mainDisplay.visibleFrame) == state.frames(in: system.mainDisplay.visibleFrame))
}

@Test(arguments: [nil, 450.0] as [Double?]) @MainActor
func tabbedSharedEdgeResizeMovesThePaneItsHiddenTabsAndItsNeighbor(neighborMinimum: Double?) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    addTabbedWindows(2, to: system)
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 3 })
    let rightPane = try #require(model.activeTabbedState?.panes[1].id)
    let neighbor = system.windows[2].id
    model.performTabbed(.move(neighbor, pane: rightPane, index: nil))
    try #require(await waitFor { model.activeTabbedState?.panes[1].selected == neighbor })
    let bounds = system.mainDisplay.visibleFrame
    let state = try #require(model.activeTabbedState)
    let leftPane = state.panes[0]
    let selected = try #require(leftPane.selected)
    let hidden = try #require(leftPane.tabs.first { $0 != selected })
    let left = TabbedLayoutState.contentFrame(try #require(state.frames(in: bounds)[leftPane.id]))
    try #require(await waitFor { frame(selected, in: system) == left && frame(hidden, in: system) == left })
    try await Task.sleep(for: .milliseconds(350))
    if let neighborMinimum {
        let index = try #require(system.windows.firstIndex { $0.id == neighbor })
        system.windows[index].constraints.minimumSize.width = neighborMinimum
    }

    // The user drags the shared edge 150 points into the right pane.
    try sendResize(selected, to: BTRect(x: left.minX, y: left.minY, width: left.size.width + 150, height: left.size.height), in: system)
    let edge = neighborMinimum.map { bounds.maxX - $0 - TabbedLayoutState.gap } ?? left.maxX + 150
    #expect(await waitFor(timeout: .seconds(2)) {
        guard let current = frame(selected, in: system), let behind = frame(hidden, in: system),
              let next = frame(neighbor, in: system) else { return false }
        return abs(current.maxX - edge) < 1 && abs(behind.maxX - edge) < 1
            && abs(next.minX - (edge + TabbedLayoutState.gap)) < 1
    })
    let adopted = try #require(model.activeTabbedState)
    #expect(try abs(#require(adopted.frames(in: bounds)[leftPane.id]).maxX - edge) < 1)
    #expect(adopted.panes.map(\.tabs) == state.panes.map(\.tabs))

    model.performTabbed(.undo)
    #expect(await waitFor(timeout: .seconds(2)) {
        frame(selected, in: system)?.approximatelyEquals(left, tolerance: 1) == true
    })
}

@Test(arguments: [false, true], [false, true]) @MainActor
func tabSelectionRefitsForReportedMinimumInBothAxes(height: Bool, learned: Bool) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    var other = system.windows[0]
    other.id = WindowID(rawValue: "larger-tab")
    system.windows.append(other)
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = height ? .rows : .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 2 })
    let target = other.id
    if learned {
        if height { system.enforcedMinimumHeights[target] = 450 }
        else { system.enforcedMinimumWidths[target] = 600 }
        system.windows[1].frame.size = BTSize(width: 800, height: 600)
    } else if height { system.windows[1].constraints.minimumSize.height = 450 }
    else { system.windows[1].constraints.minimumSize.width = 600 }
    model.performTabbed(.select(target))
    try #require(await waitFor { model.activeTabbedState?.activeWindowID == target })
    #expect(height ? system.windows[1].frame.size.height >= 450 : system.windows[1].frame.size.width >= 600)
    #expect(model.statusMessage == nil)
}

@Test @MainActor func repairTabbedLearnsHeightAndRestoresDisplacedWindow() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = .rows
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState != nil && system.windows[0].frame.minY == 34 })
    let id = system.windows[0].id
    system.windows[0].frame = BTRect(x: 100, y: 50, width: 800, height: 600)
    system.enforcedMinimumHeights[id] = 450
    model.repairCurrentLayout()
    try #require(await waitFor { system.windows[0].frame.minX == 0 && system.windows[0].constraints.minimumSize.height >= 450 })
    #expect(model.statusMessage == nil)
    #expect(system.windows[0].constraints.minimumSize.height >= 450)
}

@Test(arguments: [false, true]) @MainActor
func impossibleTabSelectionPreservesSelectionAndFrames(height: Bool) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    var other = system.windows[0]
    other.id = WindowID(rawValue: "impossible-tab")
    system.windows.append(other)
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = height ? .rows : .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 2 })
    let before = try #require(model.activeTabbedState)
    let frames = system.windows.map(\.frame)
    let writes = system.frameWriteCounts
    if height { system.windows[1].constraints.minimumSize.height = 780 }
    else { system.windows[1].constraints.minimumSize.width = 950 }
    model.performTabbed(.select(other.id))
    #expect(model.statusMessage != nil)
    #expect(model.activeTabbedState == before)
    #expect(system.windows.map(\.frame) == frames)
    #expect(system.frameWriteCounts == writes)
}

@Test @MainActor
func activationRepairsAnInactiveTabAboveAnotherPanesSelection() async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTwoTabbedColumns(system)
    defer { model.shutdown() }
    // Each pane's selected tab is above its own inactive tab, but the left
    // inactive tab still sits above the right selection and shared curtain.
    system.stack = [0, 1, 3, 2].map { stackEntry(system.windows[$0]) }
    system.focusedID = system.windows[0].id
    let raises = system.raiseRequests.count
    model.handleApplicationActivation()
    #expect(await waitFor { system.raiseRequests.count > raises })
    #expect(system.raiseRequests.dropFirst(raises).map(\.0) == [system.windows[3].id])
    let selected = Set(try #require(model.activeTabbedState).selectedWindowIDs)
    let order = try #require(system.stack).compactMap(\.windowID)
    #expect(Set(order.prefix(2)) == selected)
    #expect(!system.raiseRequests.dropFirst(raises).contains { $0.1 })
}

@Test @MainActor
func sharedCurtainRepairKeepsAFloatingWindowInThePaneGapInFront() async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTwoTabbedColumns(system)
    defer { model.shutdown() }
    let state = try #require(model.activeTabbedState)
    let bounds = system.mainDisplay.visibleFrame
    let left = try #require(state.frames(in: bounds)[state.panes[0].id])
    let floating = WindowID(rawValue: "gap-floating")
    let gap = TabbedStackEntry(windowID: floating,
        frame: BTRect(x: left.maxX + 1, y: bounds.minY + 100, width: 2, height: 100))
    system.stack = [0, 1].map { stackEntry(system.windows[$0]) }
        + [gap] + [3, 2].map { stackEntry(system.windows[$0]) }
    let raises = system.raiseRequests.count
    model.handleApplicationActivation()
    #expect(await waitFor { system.raiseRequests.count > raises })
    #expect(system.raiseRequests.dropFirst(raises).map(\.0) == [system.windows[3].id, floating])
    #expect(system.stack?.first?.windowID == floating)
    #expect(!system.raiseRequests.dropFirst(raises).contains { $0.1 })
}

@Test @MainActor
func sharedCurtainRequiresVerifiedOrderAfterAnIgnoredRaise() async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTwoTabbedColumns(system)
    defer { model.shutdown() }
    let state = try #require(model.activeTabbedState)
    system.stack = [0, 1, 3, 2].map { stackEntry(system.windows[$0]) }
    system.updatesStackOnRaise = false
    #expect(model.repairTabbedOrder(state: state, windows: system.windows,
        bounds: system.mainDisplay.visibleFrame) == nil)
}

@Test @MainActor
func tabbedDividerPresentationSurvivesDisplacedWindowsAndExcludesInactiveTabs() async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTwoTabbedColumns(system)
    defer { model.shutdown() }
    let state = try #require(model.activeTabbedState)
    let bounds = system.mainDisplay.visibleFrame
    let expected = state.layout.boundaries(in: bounds, displayID: system.mainDisplay.id)
    let hidden = try #require(state.panes[0].tabs.first { $0 != state.panes[0].selected })
    let index = try #require(system.windows.firstIndex { $0.id == hidden })
    system.windows[index].processIdentifier = system.windows[0].processIdentifier
    system.windows[0].frame.size.width -= 200
    // A frontmost floating window still suppresses a handle it overlaps.
    var floating = system.windows[0]
    floating.id = WindowID(rawValue: "divider-floating")
    floating.isFloating = true
    system.windows.append(floating)
    let presentation = model.dividerPresentation(windows: system.windows)
    #expect(presentation.boundaries == expected)
    #expect(presentation.obscuringFrames == [floating.frame])
    #expect(presentation.managedWindowIDs == [system.mainDisplay.id: state.windowIDs])
    #expect(presentation.managedWindowIDs[system.mainDisplay.id]?.contains(hidden) == true)
}

@Test(arguments: [false, true]) @MainActor
func tabbedDividerUsesVerifiedFloatingOrderAcrossApps(floatingInFront: Bool) async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTwoTabbedColumns(system)
    defer { model.shutdown() }
    var floating = system.windows[0]
    floating.id = WindowID(rawValue: "inactive-app-floating")
    if floatingInFront { floating.processIdentifier += 500 }
    floating.isFloating = true
    system.windows.append(floating)
    let managed = [0, 3, 1, 2].map { stackEntry(system.windows[$0]) }
    system.stack = floatingInFront ? [stackEntry(floating)] + managed : managed + [stackEntry(floating)]
    #expect(model.dividerPresentation(windows: system.windows).obscuringFrames.contains(floating.frame) == floatingInFront)
}

@Test(arguments: [false, true]) @MainActor
func tabbedGesturesRetainEvidenceForAnAlreadyClampedInactiveTab(height: Bool) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    var hidden = system.windows[0]
    hidden.id = WindowID(rawValue: "already-clamped")
    hidden.frame.size = BTSize(width: 800, height: 600)
    system.windows.append(hidden)
    if height { system.enforcedMinimumHeights[hidden.id] = 450 }
    else { system.enforcedMinimumWidths[hidden.id] = 600 }
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = height ? .rows : .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor {
        height ? system.windows[1].constraints.minimumSize.height >= 450
               : system.windows[1].constraints.minimumSize.width >= 600
    })
    model.prepareWindowGesture()
    model.performTabbed(.select(hidden.id))
    try #require(await waitFor { model.activeTabbedState?.activeWindowID == hidden.id })
    #expect(model.statusMessage == nil)
    #expect(height ? system.windows[1].frame.size.height >= 450 : system.windows[1].frame.size.width >= 600)
}

@Test @MainActor
func observedSmallerInactiveTabNoLongerForcesItsPreviousMinimum() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    var hidden = system.windows[0]
    hidden.id = WindowID(rawValue: "content-minimum-changed")
    hidden.frame.size.width = 800
    system.windows.append(hidden)
    system.enforcedMinimumWidths[hidden.id] = 600
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { system.windows[1].constraints.minimumSize.width >= 600 })
    let previous = try #require(model.activeTabbedState).frames(in: system.mainDisplay.visibleFrame)
    system.enforcedMinimumWidths[hidden.id] = 400
    system.windows[1].frame.size.width = 400
    // Two matching observations confirm the app's smaller settled size.
    _ = try system.visibleWindows()
    _ = try system.visibleWindows()
    model.performTabbed(.select(hidden.id))
    try #require(await waitFor { model.activeTabbedState?.activeWindowID == hidden.id })
    #expect(model.activeTabbedState?.frames(in: system.mainDisplay.visibleFrame) == previous)
    #expect(model.statusMessage == nil)
}

@Test(arguments: [false, true]) @MainActor
func gestureOnAnotherDisplayPreservesAnInactiveTabbedMinimum(nativeVisit: Bool) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let first = system.windows[0].id
    let otherDisplay = DisplayID(rawValue: "tabbed-other-display")
    system.availableDisplays.append(DisplaySnapshot(id: otherDisplay,
        frame: BTRect(x: 1000, y: 0, width: 1000, height: 800),
        visibleFrame: BTRect(x: 1000, y: 0, width: 1000, height: 800)))
    var selected = system.windows[0]
    selected.id = WindowID(rawValue: "other-selected")
    selected.displayID = otherDisplay
    selected.frame.origin.x += 1000
    var hidden = selected
    hidden.id = WindowID(rawValue: "other-inactive-minimum")
    hidden.frame.size.width = 800
    system.windows += [selected, hidden]
    system.enforcedMinimumWidths[hidden.id] = 600
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    system.focusedID = selected.id
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { system.windows[2].constraints.minimumSize.width >= 600 })
    if nativeVisit {
        model.setActiveMode(.manual)
        try #require(await waitFor { model.activeMode(for: otherDisplay) == .manual })
    }
    system.focusedID = first // A Bento gesture starts on the first display.
    model.prepareWindowGesture()
    system.focusedID = selected.id
    if nativeVisit {
        model.setActiveMode(.tabbed)
        try #require(await waitFor { model.activeTabbedState != nil })
    }
    model.performTabbed(.select(hidden.id))
    try #require(await waitFor { model.activeTabbedState?.activeWindowID == hidden.id })
    #expect(model.statusMessage == nil)
}

@Test @MainActor func glassPreferenceDoesNotMoveOrRaiseTabbedWindows() async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTwoTabbedColumns(system)
    defer { model.shutdown() }
    let state = model.activeTabbedState
    let frames = system.windows.map(\.frame)
    let writes = system.frameWriteCounts
    let raises = system.raiseRequests.count
    model.updateConfiguration { $0.overlayAppearance = .init(useLiquidGlass: false, strength: 0.8) }
    #expect(model.configuration.overlayAppearance == OverlayAppearance(useLiquidGlass: false, strength: 0.8))
    #expect(model.activeTabbedState == state)
    #expect(system.windows.map(\.frame) == frames)
    #expect(system.frameWriteCounts == writes)
    #expect(system.raiseRequests.count == raises)
}

@Test(arguments: [false, true]) @MainActor
func shutdownPreventsQueuedTabbedExitFromMutatingWindows(pendingPlacement: Bool) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs == [system.windows[0].id] })
    try await Task.sleep(for: .milliseconds(350))
    if pendingPlacement {
        model.performTabbed(.preset(.columns))
    }
    model.setActiveMode(.manual)
    // The exit task has been queued but has not resumed on the main actor.
    model.shutdown()
    let writes = system.frameWriteCounts
    let sweeps = system.completeSweepCount
    let frames = system.windows.map(\.frame)
    try await Task.sleep(for: .milliseconds(500))
    #expect(system.frameWriteCounts == writes)
    #expect(system.completeSweepCount == sweeps)
    #expect(system.windows.map(\.frame) == frames)
}

@Test(arguments: ["unchanged", "larger-minimum", "oversized-minimum", "oversized-baseline"], [false, true]) @MainActor
func restoringTabbedBaselineRespectsCurrentMinimums(scenario: String, shuttingDown: Bool) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    if scenario == "oversized-baseline" {
        system.windows[0].frame = BTRect(x: -50, y: 200, width: 1100, height: 400)
    }
    let baseline = system.windows[0].frame
    let id = system.windows[0].id
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.singleWindowPlacement = nil
    model.configuration.defaultTabbedPreset = .single
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs == [id] })
    let expected: BTRect
    switch scenario {
    case "larger-minimum":
        system.windows[0].constraints.minimumSize = BTSize(width: 640, height: 480)
        expected = BTRect(x: 200, y: 200, width: 640, height: 480)
    case "oversized-minimum":
        system.windows[0].constraints.minimumSize = BTSize(width: 1200, height: 400)
        expected = BTRect(x: 0, y: 200, width: 1200, height: 400)
    default: expected = baseline
    }
    model.statusMessage = nil
    if shuttingDown {
        model.shutdown()
    } else {
        model.setActiveMode(.manual)
        try #require(await waitFor { model.activeMode(for: system.mainDisplay.id) == .manual || model.statusMessage != nil })
        #expect(model.activeMode(for: system.mainDisplay.id) == .manual)
    }
    #expect(system.windows[0].frame == expected)
    #expect(model.statusMessage == nil)
}

@Test @MainActor func failedNativeExitRestorationRollsBackAndKeepsTabbed() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    addTabbedWindows(1, to: system)
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.singleWindowPlacement = nil
    model.configuration.defaultTabbedPreset = .single
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 2 })
    let state = try #require(model.activeTabbedState)
    let frames = system.windows.map(\.frame)
    let first = system.windows[0].id, second = system.windows[1].id
    let writes = system.frameWriteCounts
    system.windows[0].constraints.minimumSize.width = 640
    system.failedFrameWriteNumbers[second] = [writes[second, default: 0] + 1]
    model.statusMessage = nil
    model.setActiveMode(.manual)
    try #require(await waitFor { model.statusMessage != nil })
    #expect(model.activeMode(for: system.mainDisplay.id) == .tabbed)
    #expect(model.activeTabbedState == state)
    #expect(system.windows.map(\.frame) == frames)
    #expect(system.frameWriteCounts[first] == writes[first, default: 0] + 2)
    #expect(system.frameWriteCounts[second] == writes[second, default: 0] + 1)
}

@Test @MainActor func shutdownRestoresEntryFramesAfterCancellingLiveDivider() async throws {
    let system = FakeAppWindowSystem()
    let baseline = system.windows[0].frame
    let model = try await makeTwoTabbedColumns(system)
    defer { model.shutdown() }
    model.configuration.resizeFeedbackMode = .live
    model.dividerResize.configuration = model.configuration
    let bounds = system.mainDisplay.visibleFrame
    let start = BTPoint(x: bounds.midX, y: bounds.midY)
    let presentation = model.dividerPresentation(windows: system.windows)
    model.dividerResize.refresh(boundaries: presentation.boundaries, obscuringFrames: presentation.obscuringFrames)
    let interaction = try #require(DividerInteractionResolver.resolve(
        at: start, in: presentation.boundaries,
        hitWidth: 18, adjacencyTolerance: 6, paneGap: model.configuration.bentoInnerGap
    ))
    let screen = try #require(NSScreen.screens.first)
    model.dividerResize.beginGesture(interaction: interaction, at: start)
    try #require(model.dividerResize.isDragging)
    let paneFrames = system.windows.map(\.frame)
    model.dividerResize.drag(to: CGPoint(x: start.x + 60, y: screen.frame.maxY - start.y))
    model.dividerResize.displayTick()
    try #require(system.windows.map(\.frame) != paneFrames)

    model.shutdown()

    #expect(!model.dividerResize.isDragging)
    #expect(system.windows.allSatisfy { $0.frame == baseline })
}

@Test(arguments: [ResizeFeedbackMode.ghost, .live], [false, true]) @MainActor
func tabbedDividerRecoversAnUnreportedMinimumAtRelease(feedback: ResizeFeedbackMode, height: Bool) async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTwoTabbedColumns(system)
    defer { model.shutdown() }
    if height {
        model.performTabbed(.preset(.rows))
        try #require(await waitFor { system.windows.allSatisfy { $0.frame.size.width == 1000 } })
    }
    model.configuration.resizeFeedbackMode = feedback
    model.dividerResize.configuration = model.configuration
    let before = try #require(model.activeTabbedState)
    let right = try #require(before.panes[1].selected)
    if height { system.enforcedMinimumHeights[right] = 300 }
    else { system.enforcedMinimumWidths[right] = 400 }
    let baseline = system.windows.map(\.frame)
    let bounds = system.mainDisplay.visibleFrame
    let start = BTPoint(x: bounds.midX, y: bounds.midY)
    let presentation = model.dividerPresentation(windows: system.windows)
    model.dividerResize.refresh(boundaries: presentation.boundaries, obscuringFrames: [])
    let interaction = try #require(DividerInteractionResolver.resolve(
        at: start, in: presentation.boundaries, hitWidth: 18,
        adjacencyTolerance: 6, paneGap: model.configuration.bentoInnerGap
    ))
    let screen = try #require(NSScreen.screens.first)
    let release = CGPoint(x: start.x + (height ? 0 : 200), y: screen.frame.maxY - start.y - (height ? 200 : 0))
    model.dividerResize.beginGesture(interaction: interaction, at: start)
    try #require(model.dividerResize.isDragging)
    model.dividerResize.drag(to: release)
    model.dividerResize.displayTick()
    if feedback == .ghost { #expect(system.windows.map(\.frame) == baseline) }
    model.dividerResize.end(at: release)
    #expect(await waitFor(timeout: .seconds(2)) {
        guard let state = model.activeTabbedState else { return false }
        let panes = state.frames(in: bounds)
        return state.selectedWindowIDs.allSatisfy { id in
            guard let pane = state.panes.first(where: { $0.selected == id }),
                  let rect = panes[pane.id] else { return false }
            return frame(id, in: system)?.approximatelyEquals(TabbedLayoutState.contentFrame(rect), tolerance: 1) == true
        }
    })
    #expect(model.activeTabbedState?.panes.map(\.tabs) == before.panes.map(\.tabs))
    let settled = try #require(frame(right, in: system))
    #expect(abs((height ? settled.size.height : settled.size.width) - (height ? 300 : 400)) < 1)
    #expect(model.statusMessage == nil)
}

@Test @MainActor func failedNativeTabbedResizeRestoresTheVerifiedLayout() async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTwoTabbedColumns(system)
    defer { model.shutdown() }
    let before = try #require(model.activeTabbedState)
    let baseline = system.windows.map(\.frame)
    let selected = try #require(before.panes[0].selected)
    let right = try #require(before.panes[1].selected)
    system.failedFrameWriteNumbers[right] = [system.frameWriteCounts[right, default: 0] + 1]
    var wider = try #require(frame(selected, in: system))
    wider.size.width += 150
    try sendResize(selected, to: wider, in: system)
    try #require(await waitFor { model.statusMessage != nil })
    #expect(model.activeTabbedState == before)
    #expect(system.windows.map(\.frame) == baseline)
}

@Test @MainActor func impossibleNativeTabbedResizeStillRestoresItsCheckpoint() async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTwoTabbedColumns(system)
    defer { model.shutdown() }
    let before = try #require(model.activeTabbedState)
    let baseline = system.windows.map(\.frame)
    let selected = try #require(before.panes[0].selected)
    let right = try #require(before.panes[1].selected)
    let index = try #require(system.windows.firstIndex { $0.id == right })
    // A new size hint makes the proposal impossible before any placement
    // batch. The application still accepts its previously verified frame.
    system.windows[index].constraints.minimumSize.width = 950
    var wider = try #require(frame(selected, in: system))
    wider.size.width += 150
    try sendResize(selected, to: wider, in: system)
    try #require(await waitFor { model.statusMessage != nil })
    #expect(model.activeTabbedState == before)
    #expect(system.windows.map(\.frame) == baseline)
    // The rollback refreshes the divider: our own restore writes are
    // suppressed, so nothing else would bring its handles back.
    #expect(await waitFor(timeout: .seconds(2)) {
        model.dividerResize.currentBoundaries.contains { $0.beforeWindowIDs.contains(selected) || $0.afterWindowIDs.contains(selected) }
    }, "\(model.dividerResize.currentBoundaries.map { ($0.beforeWindowIDs, $0.afterWindowIDs) })")
}

@Test(arguments: [ResizeFeedbackMode.ghost, .live], [false, true]) @MainActor
func ignoredTabbedDividerWritesRestoreWithoutLearningOrRepeating(feedback: ResizeFeedbackMode, displaced: Bool) async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTwoTabbedColumns(system)
    defer { model.shutdown() }
    model.configuration.resizeFeedbackMode = feedback
    model.dividerResize.configuration = model.configuration
    let before = try #require(model.activeTabbedState)
    let baseline = system.windows.map(\.frame)
    let right = try #require(before.panes[1].selected)
    system.ignoredFrameWriteWindowIDs.insert(right)
    if displaced { system.windows[0].frame.size.width -= 50 }
    let bounds = system.mainDisplay.visibleFrame
    let start = BTPoint(x: bounds.midX, y: bounds.midY)
    let presentation = model.dividerPresentation(windows: system.windows)
    model.dividerResize.refresh(boundaries: presentation.boundaries, obscuringFrames: [])
    let interaction = try #require(DividerInteractionResolver.resolve(
        at: start, in: presentation.boundaries, hitWidth: 18,
        adjacencyTolerance: 6, paneGap: model.configuration.bentoInnerGap
    ))
    let screen = try #require(NSScreen.screens.first)
    let release = CGPoint(x: start.x + 150, y: screen.frame.maxY - start.y)
    model.dividerResize.beginGesture(interaction: interaction, at: start)
    try #require(model.dividerResize.isDragging)
    model.dividerResize.drag(to: release)
    model.dividerResize.displayTick()
    #expect(!model.dividerResize.dragLimit.isLimited)
    model.dividerResize.end(at: release)
    try #require(await waitFor { model.statusMessage != nil })
    #expect(model.activeTabbedState == before)
    #expect(system.windows.map(\.frame) == baseline)
    #expect(system.windows.first { $0.id == right }?.constraints.minimumSize.width == 120)
    let writes = system.frameWriteCounts
    let selected = try #require(before.panes[0].selected)
    try sendResize(selected, to: try #require(frame(selected, in: system)), in: system)
    try await Task.sleep(for: .milliseconds(300))
    #expect(system.frameWriteCounts == writes)
}

@Test @MainActor func refusedTabbedCheckpointRestoreSuspendsAutomaticCorrections() async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTwoTabbedColumns(system)
    defer { model.shutdown() }
    let before = try #require(model.activeTabbedState)
    let selected = try #require(before.panes[0].selected)
    let right = try #require(before.panes[1].selected)
    let index = try #require(system.windows.firstIndex { $0.id == right })
    system.windows[index].constraints.minimumSize.width = 950
    system.ignoredFrameWriteWindowIDs.insert(selected)
    var wider = try #require(frame(selected, in: system))
    wider.size.width += 150
    try sendResize(selected, to: wider, in: system)
    try #require(await waitFor { model.statusMessage?.contains("could not fully restore") == true })
    #expect(model.activeTabbedState == before)
    let writes = system.frameWriteCounts
    system.windows[index].constraints.minimumSize.width = 120
    system.ignoredFrameWriteWindowIDs.remove(selected)
    try sendResize(selected, to: wider, in: system)
    try await Task.sleep(for: .milliseconds(300))
    #expect(system.frameWriteCounts == writes)
}

@Test @MainActor func delayedNativeTabbedCheckpointRestoreDoesNotReportDegraded() async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTwoTabbedColumns(system)
    defer { model.shutdown() }
    let before = try #require(model.activeTabbedState)
    let baseline = system.windows.map(\.frame)
    let selected = try #require(before.panes[0].selected)
    let right = try #require(before.panes[1].selected)
    let index = try #require(system.windows.firstIndex { $0.id == right })
    system.windows[index].constraints.minimumSize.width = 950
    system.frameApplicationDelays[selected] = .milliseconds(100)
    var wider = try #require(frame(selected, in: system))
    wider.size.width += 150
    try sendResize(selected, to: wider, in: system)
    try #require(await waitFor { system.windows.map(\.frame) == baseline && model.statusMessage != nil })
    #expect(model.activeTabbedState == before)
    #expect(model.statusMessage?.contains("could not fully restore") == false)
}

@Test(arguments: [false, true]) @MainActor
func delayedNativeTabbedCheckpointRestoreLocksTabDragsUntilCompletion(cancelRestore: Bool) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    // Keep the test's own panels off-screen; all window writes use the fake.
    system.availableDisplays[0].frame.origin.x = 12000
    system.availableDisplays[0].visibleFrame.origin.x = 12000
    for index in system.windows.indices { system.windows[index].frame.origin.x += 12000 }
    let store = ConfigurationStore(fileURL: URL(filePath: "/private/tmp/BetterTileAppTests-\(UUID().uuidString)/configuration.json"))
    let model = BetterTileModel(store: store, system: system, startRuntime: false, presentsTabbedChrome: true)
    model.primaryButtonIsPressed = { false }
    defer { model.shutdown() }
    _ = try await makeTwoTabbedColumns(system, model: model)
    let before = try #require(model.activeTabbedState)
    let pane = try #require(NSApp.windows.compactMap(\.contentView).compactMap { $0 as? TabbedPaneView }
        .first { $0.pane.id == before.panes[0].id })
    let overlay = try #require(pane.owner)
    try #require(await waitFor { overlay.acceptsTabDrags })
    let baseline = system.windows.map(\.frame)
    let selected = try #require(before.panes[0].selected)
    let right = try #require(before.panes[1].selected)
    let index = try #require(system.windows.firstIndex { $0.id == right })
    system.windows[index].constraints.minimumSize.width = 950
    system.frameApplicationDelays[selected] = .milliseconds(100)
    let writes = system.frameWriteCounts[selected, default: 0]
    var wider = try #require(frame(selected, in: system))
    wider.size.width += 150
    try sendResize(selected, to: wider, in: system)
    try #require(await waitFor { system.frameWriteCounts[selected, default: 0] > writes })
    #expect(!overlay.acceptsTabDrags)
    if cancelRestore {
        model.shutdown()
    } else {
        try #require(await waitFor { system.windows.map(\.frame) == baseline && model.statusMessage != nil })
        #expect(model.activeTabbedState == before)
    }
    try #require(await waitFor { overlay.acceptsTabDrags })
    #expect(!overlay.isDropPending)
}

@Test @MainActor func shutdownCancelsDelayedNativeCheckpointVerification() async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTwoTabbedColumns(system)
    defer { model.shutdown() }
    let state = try #require(model.activeTabbedState)
    let selected = try #require(state.panes[0].selected)
    let right = try #require(state.panes[1].selected)
    let index = try #require(system.windows.firstIndex { $0.id == right })
    system.windows[index].constraints.minimumSize.width = 950
    system.frameApplicationDelays[selected] = .milliseconds(100)
    let writes = system.frameWriteCounts[selected, default: 0]
    var wider = try #require(frame(selected, in: system))
    wider.size.width += 150
    try sendResize(selected, to: wider, in: system)
    try #require(await waitFor { system.frameWriteCounts[selected, default: 0] > writes })
    model.statusMessage = "shutdown-checkpoint"
    model.shutdown()
    let shutdownWrites = system.frameWriteCounts
    try await Task.sleep(for: .milliseconds(200))
    #expect(model.statusMessage == "shutdown-checkpoint")
    #expect(system.frameWriteCounts == shutdownWrites)
}

@Test @MainActor func dividerManagedMembersStayOnTheirDisplayIncludingInactiveTabs() async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTwoTabbedColumns(system)
    defer { model.shutdown() }
    let firstState = try #require(model.activeTabbedState)
    let otherDisplay = DisplayID(rawValue: "seam-other-display")
    system.availableDisplays.append(DisplaySnapshot(
        id: otherDisplay, frame: BTRect(x: 1000, y: 0, width: 1000, height: 800),
        visibleFrame: BTRect(x: 1000, y: 0, width: 1000, height: 800)
    ))
    let otherWindows = (0..<3).map { index in
        WindowSnapshot(id: WindowID(rawValue: "other-\(index)"), processIdentifier: 77,
                       frame: BTRect(x: 1100, y: 100, width: 500, height: 500), displayID: otherDisplay)
    }
    system.windows += otherWindows
    system.focusedID = otherWindows[0].id
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 3 })
    let presentation = model.dividerPresentation(windows: system.windows)
    #expect(presentation.managedWindowIDs[system.mainDisplay.id] == firstState.windowIDs)
    #expect(presentation.managedWindowIDs[otherDisplay] == Set(otherWindows.map(\.id)))
}

/// The same application owns the selected tabs of both panes. Selecting a
/// tab activates the application, which exposes the other pane's hidden tab.
/// The stacking repair raises the other pane's selected window; keyboard
/// focus must still end on the clicked tab.
@Test(arguments: [false, true]) @MainActor
func selectingASameApplicationTabKeepsFocusOnTheClickedTab(activationRestoresOldMain: Bool) async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTwoTabbedColumns(system)
    defer { model.shutdown() }
    for index in system.windows.indices { system.windows[index].processIdentifier = 7 }
    system.raiseFocusesFrontmostApplicationWindow = true
    let hiddenLeft = system.windows[1].id
    let rightSelected = system.windows[3].id
    // Right pane's hidden tab is in front of its selected tab after activation.
    system.stack = [0, 2, 3, 1].map { stackEntry(system.windows[$0]) }
    system.focusedID = system.windows[0].id
    if activationRestoresOldMain { system.activationFocusesInstead = rightSelected }

    model.performTabbed(.select(hiddenLeft))
    try #require(await waitFor { model.activeTabbedState?.panes[0].selected == hiddenLeft })
    try await Task.sleep(for: .milliseconds(900)) // Let focus refreshes run.
    #expect(system.focusedID == hiddenLeft)
    #expect(model.activeTabbedState?.panes[0].selected == hiddenLeft)
    #expect(model.activeTabbedState?.panes[1].selected == rightSelected)
    #expect(model.activeTabbedState?.activeWindowID == hiddenLeft)
}

/// After the selected tab had focus, the user moves focus to the other
/// pane's window of the same application. That is a choice, not a focus
/// change to correct.
@Test @MainActor
func aSameApplicationFocusChangeAfterTheSelectionIsKept() async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTwoTabbedColumns(system)
    defer { model.shutdown() }
    for index in system.windows.indices { system.windows[index].processIdentifier = 7 }
    let hiddenLeft = system.windows[1].id
    let rightSelected = system.windows[3].id
    system.focusedID = system.windows[0].id
    model.performTabbed(.select(hiddenLeft))
    try #require(await waitFor { model.activeTabbedState?.panes[0].selected == hiddenLeft && system.focusedID == hiddenLeft })
    // The user clicks the right pane's window at once, before any focus
    // refresh ran; the placement already saw the clicked tab focused.
    let raises = system.raiseRequests.count
    system.focusedID = rightSelected
    system.eventHandler?(WindowSystemEvent(kind: .focused, windowID: rightSelected, processIdentifier: 7))
    // The focus refresh runs once the selection's suppression ends.
    #expect(await waitFor(timeout: .seconds(3)) { model.activeTabbedState?.activeWindowID == rightSelected })
    try await Task.sleep(for: .milliseconds(200))
    #expect(system.focusedID == rightSelected)
    #expect(!system.raiseRequests.dropFirst(raises).contains { $0.0 == hiddenLeft && $0.1 })
    #expect(model.activeTabbedState?.activeWindowID == rightSelected)
}

/// A selection raises its tab before the placement is prepared. When the
/// placement is rejected, the old tab and the old focus come back.
@Test @MainActor func aRejectedSelectionPutsBackTheEarlyRaise() async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTwoTabbedColumns(system)
    defer { model.shutdown() }
    let state = try #require(model.activeTabbedState)
    let previous = try #require(state.panes[0].selected)
    let previousFocus = try #require(state.activeWindowID)
    let hidden = try #require(state.panes[0].tabs.first { $0 != previous })
    let index = try #require(system.windows.firstIndex { $0.id == hidden })
    // The tab cannot fit its pane, so the selection is rejected.
    system.windows[index].constraints.minimumSize = BTSize(width: 5000, height: 5000)
    system.focusedID = previousFocus
    let raises = system.raiseRequests.count
    model.performTabbed(.select(hidden))
    try await Task.sleep(for: .milliseconds(300))
    #expect(system.raiseRequests.dropFirst(raises).first?.0 == hidden)
    #expect(model.activeTabbedState?.panes[0].selected == previous)
    #expect(system.focusedID == previousFocus)
    #expect(system.raiseRequests.last?.0 == previousFocus)
}

/// A pressed tab draws as selected at once. When the model rejects that
/// selection before any placement starts, the strip shows the previous tab
/// again at once, not after the highlight's timeout. The placement can
/// reject the tab, or the model can stop before it because no window list
/// can be read.
@Test(arguments: [false, true]) @MainActor
func aPressRejectedBeforePlacementDropsItsHighlightAtOnce(unreadableWindows: Bool) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    // Keep the test's own panels off-screen; all window writes use the fake.
    system.availableDisplays[0].frame.origin.x = 12000
    system.availableDisplays[0].visibleFrame.origin.x = 12000
    for index in system.windows.indices { system.windows[index].frame.origin.x += 12000 }
    let store = ConfigurationStore(fileURL: URL(filePath: "/private/tmp/BetterTileAppTests-\(UUID().uuidString)/configuration.json"))
    let model = BetterTileModel(store: store, system: system, startRuntime: false, presentsTabbedChrome: true)
    model.primaryButtonIsPressed = { false }
    defer { model.shutdown() }
    _ = try await makeTwoTabbedColumns(system, model: model)
    let state = try #require(model.activeTabbedState)
    let previous = try #require(state.panes[0].selected)
    let hidden = try #require(state.panes[0].tabs.first { $0 != previous })
    let pane = try #require(NSApp.windows.compactMap(\.contentView).compactMap { $0 as? TabbedPaneView }
        .first { $0.pane.id == state.panes[0].id })
    let overlay = try #require(pane.owner)
    try #require(await waitFor { overlay.acceptsTabDrags })
    if unreadableWindows {
        system.cachedRefreshFails = true
        system.failedVisibleWindowSweeps = [system.completeSweepCount + 1]
    } else {
        let index = try #require(system.windows.firstIndex { $0.id == hidden })
        // The tab cannot fit its pane, so the selection is rejected.
        system.windows[index].constraints.minimumSize = BTSize(width: 5000, height: 5000)
    }
    pane.layoutSubtreeIfNeeded()
    let tab = pane.strip.tabFrame(try #require(pane.content.renderedIndex(of: hidden)))
    let window = try #require(pane.window)
    let location = pane.content.convert(NSPoint(x: tab.midX, y: tab.midY), to: nil)
    let press = try #require(NSEvent.mouseEvent(
        with: .leftMouseDown, location: location, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
    ))
    pane.mouseDown(with: press)
    #expect(model.activeTabbedState?.panes[0].selected == previous)
    #expect((model.statusMessage != nil) != unreadableWindows)
    #expect(pane.displayedSelection == previous)
}

/// A focus change the user made selects its tab without an early raise.
/// When that selection is rejected, the window they chose stays in front.
@Test @MainActor func aRejectedFocusSelectionKeepsTheChosenWindowInFront() async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTwoTabbedColumns(system)
    defer { model.shutdown() }
    let state = try #require(model.activeTabbedState)
    let previous = try #require(state.panes[0].selected)
    let previousFocus = try #require(state.activeWindowID)
    let hidden = try #require(state.panes[0].tabs.first { $0 != previous })
    let index = try #require(system.windows.firstIndex { $0.id == hidden })
    system.windows[index].constraints.minimumSize = BTSize(width: 5000, height: 5000)
    let raises = system.raiseRequests.count
    system.focusedID = hidden
    system.eventHandler?(WindowSystemEvent(kind: .focused, windowID: hidden,
                                           processIdentifier: system.windows[index].processIdentifier))
    try await Task.sleep(for: .milliseconds(500))
    #expect(model.activeTabbedState?.panes[0].selected == previous)
    #expect(system.focusedID == hidden)
    #expect(!system.raiseRequests.dropFirst(raises).contains { $0.0 == previousFocus && $0.1 })
}

/// The placement's own checks can also reject a selection before any
/// write, here because the tab cannot be read. The early raise is undone.
@Test @MainActor func aSelectionRejectedByThePlacementPutsBackTheEarlyRaise() async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTwoTabbedColumns(system)
    defer { model.shutdown() }
    let state = try #require(model.activeTabbedState)
    let previous = try #require(state.panes[0].selected)
    let previousFocus = try #require(state.activeWindowID)
    let hidden = try #require(state.panes[0].tabs.first { $0 != previous })
    system.unreadableAfterWrites[hidden] = 0
    system.focusedID = previousFocus
    let raises = system.raiseRequests.count
    model.performTabbed(.select(hidden))
    try await Task.sleep(for: .milliseconds(400))
    #expect(system.raiseRequests.dropFirst(raises).first?.0 == hidden)
    #expect(model.activeTabbedState?.panes[0].selected == previous)
    #expect(system.focusedID == previousFocus)
}

/// A selection whose write fails is rolled back, and the rollback already
/// returns focus to the previous tab. The early raise's undo does not
/// activate it a second time.
@Test @MainActor func aRolledBackSelectionReturnsFocusOnce() async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTwoTabbedColumns(system)
    defer { model.shutdown() }
    let state = try #require(model.activeTabbedState)
    let previous = try #require(state.panes[0].selected)
    let previousFocus = try #require(state.activeWindowID)
    let hidden = try #require(state.panes[0].tabs.first { $0 != previous })
    let index = try #require(system.windows.firstIndex { $0.id == hidden })
    // The tab sits off its pane, so selecting it writes its frame; that
    // write fails.
    system.windows[index].frame.origin.x += 7
    let next = system.frameWriteCounts[hidden, default: 0] + 1
    system.failedFrameWriteNumbers[hidden] = Set(next...(next + 50))
    system.focusedID = previousFocus
    let raises = system.raiseRequests.count
    model.performTabbed(.select(hidden))
    try await Task.sleep(for: .milliseconds(500))
    #expect(model.activeTabbedState?.panes[0].selected == previous)
    #expect(system.focusedID == previousFocus)
    let activations = system.raiseRequests.dropFirst(raises).filter { $0.0 == previousFocus && $0.1 }
    #expect(activations.count == 1, "\(system.raiseRequests.dropFirst(raises).map { "\($0.0.rawValue):\($0.1)" })")
}

@Test @MainActor
func stackingRepairOfTheKeyApplicationRaisesTheKeyWindowLast() async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTwoTabbedColumns(system)
    defer { model.shutdown() }
    for index in system.windows.indices { system.windows[index].processIdentifier = 7 }
    system.raiseFocusesFrontmostApplicationWindow = true
    // The key window is in front; only the right pane needs a raise.
    system.stack = [0, 2, 3, 1].map { stackEntry(system.windows[$0]) }
    system.focusedID = system.windows[0].id
    let state = try #require(model.activeTabbedState)
    let raises = system.raiseRequests.count

    model.handleApplicationActivation()
    #expect(await waitFor(timeout: .seconds(1)) { system.raiseRequests.count > raises })
    try await Task.sleep(for: .milliseconds(500))
    #expect(system.raiseRequests.dropFirst(raises).map(\.0) == [system.windows[3].id, system.windows[0].id])
    #expect(system.focusedID == system.windows[0].id)
    #expect(model.activeTabbedState == state)
}

/// Terminal settles on whole character cells, just short of its pane. The
/// tab is selected, and its real frame is not read as a user resize.
@Test(arguments: [false, true]) @MainActor
func steppedApplicationTabIsSelectedWithoutResizeLoops(emitsEvents: Bool) async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTwoTabbedColumns(system)
    defer { model.shutdown() }
    let terminal = system.windows[1].id
    system.widthSteps[terminal] = 10
    // The hidden tab drifted, so selecting it must write its pane frame.
    system.windows[1].frame.size.width = 300
    system.emitsFrameEvents = emitsEvents

    model.performTabbed(.select(terminal))
    #expect(await waitFor(timeout: .seconds(2)) { model.activeTabbedState?.panes[0].selected == terminal })
    try await Task.sleep(for: .milliseconds(600))
    let writes = system.frameWriteCounts
    try await Task.sleep(for: .milliseconds(600))
    #expect(model.activeTabbedState?.panes[0].selected == terminal)
    #expect(system.frameWriteCounts == writes) // No adopt-and-refit loop.
    #expect(model.statusMessage == nil)
}

/// While the button is held on a selected tab's shared edge, the strips
/// follow that edge live; the layout is committed only at release.
@Test @MainActor func tabStripsFollowANativeEdgeResizeWhileTheButtonIsHeld() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    system.availableDisplays[0].frame.origin.x = 12000
    system.availableDisplays[0].visibleFrame.origin.x = 12000
    for index in system.windows.indices { system.windows[index].frame.origin.x += 12000 }
    addTabbedWindows(1, to: system)
    for index in system.windows.indices { system.windows[index].frame.origin.x = 12000 + 100 }
    let store = ConfigurationStore(fileURL: URL(filePath: "/private/tmp/BetterTileAppTests-\(UUID().uuidString)/configuration.json"))
    let model = BetterTileModel(store: store, system: system, startRuntime: false, presentsTabbedChrome: true)
    var held = false
    model.primaryButtonIsPressed = { held }
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 2 })
    let right = try #require(model.activeTabbedState?.panes[1].id)
    model.performTabbed(.move(system.windows[1].id, pane: right, index: nil))
    try #require(await waitFor { model.activeTabbedState?.panes[1].selected == system.windows[1].id })
    try await Task.sleep(for: .milliseconds(400))
    let display = system.mainDisplay.id
    let before = try #require(model.presentedTabbedState(on: display)?.frames(in: system.availableDisplays[0].visibleFrame))
    let leftPane = try #require(model.activeTabbedState?.panes[0].id)

    held = true
    var left = system.windows[0].frame
    left.size.width += 120
    system.windows[0].frame = left
    system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: system.windows[0].id,
                                          processIdentifier: system.windows[0].processIdentifier))
    let during = try #require(model.presentedTabbedState(on: display)?.frames(in: system.availableDisplays[0].visibleFrame))
    #expect((during[leftPane]?.maxX ?? 0) > (before[leftPane]?.maxX ?? 0) + 100)
    held = false
}

/// A native edge resize that ends where it started changes no pane. The
/// tab strips previewed the edge while the button was held, so they return
/// to the committed panes at release.
@Test @MainActor func tabStripsReturnWhenANativeEdgeResizeEndsUnchanged() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    system.availableDisplays[0].frame.origin.x = 12000
    system.availableDisplays[0].visibleFrame.origin.x = 12000
    for index in system.windows.indices { system.windows[index].frame.origin.x += 12000 }
    addTabbedWindows(1, to: system)
    for index in system.windows.indices { system.windows[index].frame.origin.x = 12000 + 100 }
    let store = ConfigurationStore(fileURL: URL(filePath: "/private/tmp/BetterTileAppTests-\(UUID().uuidString)/configuration.json"))
    let model = BetterTileModel(store: store, system: system, startRuntime: false, presentsTabbedChrome: true)
    var held = false
    model.primaryButtonIsPressed = { held }
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 2 })
    let right = try #require(model.activeTabbedState?.panes[1].id)
    model.performTabbed(.move(system.windows[1].id, pane: right, index: nil))
    try #require(await waitFor { model.activeTabbedState?.panes[1].selected == system.windows[1].id })
    try await Task.sleep(for: .milliseconds(400))
    let display = system.mainDisplay.id
    let committed = try #require(model.activeTabbedState)
    let bounds = system.availableDisplays[0].visibleFrame
    let before = try #require(model.presentedTabbedState(on: display)?.frames(in: bounds))
    let leftPane = committed.panes[0].id
    let original = system.windows[0].frame
    // The callback for BetterTile's own last write ends its ownership of
    // that frame, so the frame the edge returns to is the user's. Its
    // processing reads the window list once.
    let reads = system.cachedRefreshCount
    system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: system.windows[0].id,
                                          processIdentifier: system.windows[0].processIdentifier))
    try #require(await waitFor { system.cachedRefreshCount > reads })

    held = true
    var wider = original
    wider.size.width += 120
    system.windows[0].frame = wider
    system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: system.windows[0].id,
                                          processIdentifier: system.windows[0].processIdentifier))
    let during = try #require(model.presentedTabbedState(on: display)?.frames(in: bounds))
    try #require((during[leftPane]?.maxX ?? 0) > (before[leftPane]?.maxX ?? 0) + 100)
    // The edge returns within the preview's 30 Hz interval, so the strips
    // keep the last preview while the button is held.
    system.windows[0].frame = original
    system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: system.windows[0].id,
                                          processIdentifier: system.windows[0].processIdentifier))
    try #require(model.presentedTabbedState(on: display)?.frames(in: bounds) == during)
    // The event pass runs while the button is still held; the gesture has not
    // ended, so the strips keep the preview.
    try await Task.sleep(for: .milliseconds(400))
    #expect(model.presentedTabbedState(on: display)?.frames(in: bounds) == during)
    held = false
    #expect(await waitFor(timeout: .seconds(3)) { model.presentedTabbedState(on: display)?.frames(in: bounds) == before })
    #expect(model.activeTabbedState == committed)
    #expect(system.windows[0].frame == original)
}

/// A fixed-size tab wider than its pane widens the pane when it is
/// selected, like a resizable tab with a large minimum, instead of failing.
@Test @MainActor func fixedSizeTabWiderThanItsPaneWidensThePane() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    addTabbedWindows(2, to: system)
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 3 })
    let fixed = system.windows[2].id
    let pane = try #require(model.activeTabbedState?.panes.first { $0.tabs.contains(fixed) })
    let bounds = system.mainDisplay.visibleFrame
    let width = try #require(model.activeTabbedState?.frames(in: bounds)[pane.id]).size.width + 80
    if pane.selected == fixed {
        let other = try #require(pane.tabs.first { $0 != fixed })
        model.performTabbed(.select(other))
        try #require(await waitFor { model.activeTabbedState?.panes.first { $0.id == pane.id }?.selected == other })
    }
    let index = try #require(system.windows.firstIndex { $0.id == fixed })
    system.windows[index].constraints.isResizable = false
    system.windows[index].frame.size = BTSize(width: width, height: 300)
    model.performTabbed(.select(fixed))
    #expect(await waitFor { model.activeTabbedState?.activeWindowID == fixed })
    #expect(system.windows[index].frame.size == BTSize(width: width, height: 300))
    let paneFrame = try #require(model.activeTabbedState?.frames(in: bounds)[pane.id])
    #expect(paneFrame.size.width + 0.5 >= width, "pane \(paneFrame) window \(width)")
    #expect(model.statusMessage == nil, "\(model.statusMessage ?? "")")
}

/// Leaving Tabbed for Bento gives every tab a pane except a fixed-size one,
/// which floats. Its pane is not left empty.
@Test @MainActor func leavingTabbedForBentoLeavesNoPaneForAFixedSizeTab() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    addTabbedWindows(2, to: system)
    system.windows[2].constraints.isResizable = false
    system.windows[2].frame.size = BTSize(width: 230, height: 408)
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 3 })
    model.setActiveMode(.bento)
    let visible = system.mainDisplay.visibleFrame
    let filled = await waitFor {
        system.windows.prefix(2).reduce(0) { $0 + $1.frame.area } > visible.area * 0.95
    }
    #expect(filled, "\(system.windows.map(\.frame))")
    #expect(system.windows[2].frame.size == BTSize(width: 230, height: 408))
}

/// A fixed-size tab can be selected at its own size. Before, any layout in
/// which it was the selected tab failed and rolled back.
@Test @MainActor func fixedSizeTabCanBeSelectedAtItsOwnSize() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    addTabbedWindows(2, to: system)
    system.windows[2].constraints.isResizable = false
    system.windows[2].frame.size = BTSize(width: 230, height: 408)
    let store = ConfigurationStore(fileURL: URL(filePath: "/private/tmp/BetterTileAppTests-\(UUID().uuidString)/configuration.json"))
    let model = BetterTileModel(store: store, system: system, startRuntime: false)
    model.primaryButtonIsPressed = { false }
    defer { model.shutdown() }
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 3 })
    let fixed = system.windows[2].id
    model.performTabbed(.select(fixed))
    #expect(await waitFor { model.activeTabbedState?.activeWindowID == fixed })
    #expect(system.windows[2].frame.size == BTSize(width: 230, height: 408))
    #expect(model.statusMessage == nil, "\(model.statusMessage ?? "")")
}

/// After a Tabbed divider drag the handle must follow the new pane edge.
/// Window events from BetterTile's own writes are suppressed, so the
/// finished placement refreshes the boundaries itself; otherwise the next
/// drag at the new edge found nothing to grab.
@Test @MainActor func tabbedDividerHandleFollowsTheEdgeAfterADrag() async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTwoTabbedColumns(system)
    defer { model.shutdown() }
    model.configuration.resizeFeedbackMode = .ghost
    model.dividerResize.configuration = model.configuration
    let bounds = system.mainDisplay.visibleFrame
    let start = BTPoint(x: bounds.midX, y: bounds.midY)
    let presentation = model.dividerPresentation(windows: system.windows)
    model.dividerResize.refresh(boundaries: presentation.boundaries, obscuringFrames: presentation.obscuringFrames)
    let interaction = try #require(DividerInteractionResolver.resolve(
        at: start, in: presentation.boundaries, hitWidth: 18, adjacencyTolerance: 6, paneGap: model.configuration.bentoInnerGap))
    let screen = try #require(NSScreen.screens.first)
    model.dividerResize.beginGesture(interaction: interaction, at: start)
    model.dividerResize.drag(to: CGPoint(x: start.x - 100, y: screen.frame.maxY - start.y))
    model.dividerResize.displayTick()
    model.dividerResize.end(at: CGPoint(x: start.x - 100, y: screen.frame.maxY - start.y))
    let moved = await waitFor {
        model.dividerResize.currentBoundaries.contains { abs($0.coordinate - (start.x - 100)) < 8 }
    }
    #expect(moved, "\(model.dividerResize.currentBoundaries.map(\.coordinate))")
}

/// Selecting a tab changes which window a divider drag resizes, so the
/// boundaries must name the newly selected tab; a stale boundary resized a
/// hidden tab and left the visible one for a later pass.
@Test @MainActor func tabbedDividerBoundariesNameTheSelectedTab() async throws {
    let system = FakeAppWindowSystem()
    let model = try await makeTwoTabbedColumns(system)
    defer { model.shutdown() }
    let left = try #require(model.activeTabbedState?.panes[0])
    let hidden = try #require(system.windows.first { $0.id != left.selected && left.tabs.contains($0.id) }?.id
        ?? system.windows.first { !left.tabs.contains($0.id) }?.id)
    if !left.tabs.contains(hidden) {
        model.performTabbed(.move(hidden, pane: left.id, index: nil))
        try #require(await waitFor { model.activeTabbedState?.panes[0].selected == hidden })
    } else {
        model.performTabbed(.select(hidden))
        try #require(await waitFor { model.activeTabbedState?.panes[0].selected == hidden })
    }
    let named = await waitFor {
        model.dividerResize.currentBoundaries.contains { $0.beforeWindowIDs.contains(hidden) || $0.afterWindowIDs.contains(hidden) }
    }
    #expect(named, "\(model.dividerResize.currentBoundaries.map { ($0.beforeWindowIDs, $0.afterWindowIDs) })")
}

/// An empty Tabbed pane leaves no blank space in Bento: the window beside
/// it takes the whole work area.
@Test @MainActor func leavingTabbedForBentoFillsAnEmptyPane() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 1 })
    try #require(model.activeTabbedState?.panes.contains { $0.tabs.isEmpty } == true)
    model.setActiveMode(.bento)
    let visible = system.mainDisplay.visibleFrame
    let filled = await waitFor { system.windows[0].frame.area > visible.area * 0.95 }
    #expect(filled, "\(system.windows[0].frame) in \(visible)")
}
