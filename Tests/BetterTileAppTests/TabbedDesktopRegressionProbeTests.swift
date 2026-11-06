import AppKit
import Testing
@testable import BetterTileApp
@testable import BetterTileCore
@testable import BetterTileMacOS

@MainActor private final class DesktopProbe {
    let system: FakeAppWindowSystem
    let model: BetterTileModel
    let display: DisplayID
    let home = NativeSpaceID(rawValue: 101)
    let away = NativeSpaceID(rawValue: 102)
    let ids: [WindowID]
    var other: [WindowSnapshot]
    var state: TabbedLayoutState? { session(display)?.tabbedState }
    var bounds: BTRect { system.availableDisplays.first { $0.id == display }!.visibleFrame }

    init(count: Int = 6, sameApp: Bool = false, secondDisplay: Bool = false) {
        let system = makeManualWindowSystem(drivingPolicyDeadlines: true)
        self.system = system
        let display = system.mainDisplay.id
        self.display = display
        let ids = (0..<count).map { WindowID(rawValue: "probe-\($0)") }
        self.ids = ids
        let home = NativeSpaceID(rawValue: 101), away = NativeSpaceID(rawValue: 102)
        system.windows = ids.enumerated().map { index, id in
            WindowSnapshot(id: id, processIdentifier: sameApp && (index == 1 || index == 2) ? 501 : Int32(410 + index),
                bundleIdentifier: sameApp && (index == 1 || index == 2) ? "com.example.shared" : "com.example.probe\(index)",
                title: "Document \(index)", frame: BTRect(x: 100, y: 100, width: 400, height: 300), displayID: display,
                constraints: .init(minimumSize: .init(width: 120, height: 80), minimumSizeSource: .hint))
        }
        other = (0..<2).map { index in
            WindowSnapshot(id: .init(rawValue: "other-\(index)"), processIdentifier: Int32(610 + index),
                frame: BTRect(x: 150 + Double(index) * 400, y: 100, width: 350, height: 500), displayID: display)
        }
        var current = [display: home], known = [display: Set([home, away])]
        var membership = Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, Set([home])) } + other.map { ($0.id, Set([away])) })
        if secondDisplay {
            let second = DisplayID(rawValue: "secondary-probe")
            system.availableDisplays.append(.init(id: second, frame: BTRect(x: 1000, y: 0, width: 1000, height: 800),
                                                  visibleFrame: BTRect(x: 1000, y: 0, width: 1000, height: 800)))
            current[second] = .init(rawValue: 201); known[second] = [.init(rawValue: 201), .init(rawValue: 202)]
            for index in 0..<2 {
                let w = WindowSnapshot(id: .init(rawValue: "secondary-\(index)"), processIdentifier: Int32(710 + index),
                    frame: BTRect(x: 1050 + Double(index) * 450, y: 80, width: 400, height: 600), displayID: second)
                system.windows.append(w); membership[w.id] = [.init(rawValue: 201)]
            }
        }
        system.desktopObservation = .init(currentSpaceByDisplay: current, knownSpacesByDisplay: known, windowMembership: membership)
        system.focusedID = ids[0]
        model = makeModel(system: system)
        model.configuration.defaultLayoutMode = .manual
        model.configuration.defaultTabbedPreset = .focus
        // Other-desktop fixtures must use the same off-screen coordinate translation.
        other = other.map { value in
            var value = value
            value.frame.origin.x += system.availableDisplays[0].frame.minX
            value.frame.origin.y += system.availableDisplays[0].frame.minY
            return value
        }
    }
    func session(_ id: DisplayID) -> LayoutSession? {
        (Mirror(reflecting: model).children.first { $0.label?.hasSuffix("sessionStore") == true }?.value as? LayoutSessionStore)?.session(for: id)
    }
    func settle() async throws {
        await system.advance(by: .milliseconds(350))
        try #require(await system.waitFor {
            !self.model.isStabilizingSpace && !self.model.hasPendingTabbedPlacement && self.model.windowEventTask == nil
        })
        await system.join(model.tabbedFocusTask)
    }
    func start() async throws {
        model.setActiveMode(.tabbed)
        try await settle()
        try #require(state?.windowIDs == Set(ids))
        model.performTabbed(.preset(.focus, grouping: .distributeWindows))
        try await settle()
        model.performTabbed(.select(ids[0]))
        try await settle()
        try #require(state?.panes.count == 3)
    }
    func action(_ intent: TabbedUIIntent) async throws {
        model.performTabbed(intent); try await settle()
    }
    func focus(_ id: WindowID) async throws {
        system.focusedID = id
        let pid = try #require(system.windows.first { $0.id == id }?.processIdentifier)
        system.eventHandler?(.init(kind: .focused, windowID: id, processIdentifier: pid))
        try await settle()
    }
    func switchTo(_ space: NativeSpaceID, windows: [WindowSnapshot], focus: WindowID) async throws {
        system.windows = windows; system.focusedID = focus
        system.desktopObservation?.currentSpaceByDisplay[display] = space
        model.beginActiveSpaceStabilization(); try await settle()
    }
    func event(_ kind: WindowSystemEvent.Kind, _ id: WindowID, pid: Int32? = nil) {
        system.eventHandler?(.init(kind: kind, windowID: id,
            processIdentifier: pid ?? system.windows.first { $0.id == id }!.processIdentifier))
    }
    func add(_ id: WindowID, pid: Int32 = 900, bundle: String = "com.example.arrival", title: String = "Document 1") {
        system.windows.append(.init(id: id, processIdentifier: pid, bundleIdentifier: bundle, title: title,
            frame: BTRect(x: bounds.minX + 100, y: bounds.minY + 100, width: 350, height: 300), displayID: display))
        system.desktopObservation?.windowMembership[id] = [home]
        event(.created, id)
    }
}

// Probe: Ten switches with changing focus on the other desktop.
@Test(.appTestApplication) @MainActor func probeTenSwitchesKeepThreePaneOrderAndSelection() async throws {
    let f = DesktopProbe(); defer { f.model.shutdown() }; try await f.start()
    let before = try #require(f.state), windows = f.system.windows
    for i in 0..<10 {
        try await f.switchTo(f.away, windows: f.other, focus: f.other[i % 2].id)
        try await f.focus(f.other[(i + 1) % 2].id)
        try await f.switchTo(f.home, windows: windows, focus: f.ids[0])
        #expect(f.state?.panes == before.panes)
        #expect(f.state?.frames(in: f.bounds) == before.frames(in: f.bounds))
    }
}

// Probe: Activation switches Space and focuses a previously hidden tab.
@Test(.appTestApplication) @MainActor func probeSpaceActivationSelectsHiddenTabWithoutReordering() async throws {
    let f = DesktopProbe(); defer { f.model.shutdown() }; try await f.start()
    let before = try #require(f.state), windows = f.system.windows, hidden = f.ids[4]
    try #require(before.hiddenWindowIDs.contains(hidden))
    try await f.switchTo(f.away, windows: f.other, focus: f.other[0].id)
    try await f.switchTo(f.home, windows: windows, focus: hidden)
    try await f.focus(hidden)
    #expect(f.state?.activeWindowID == hidden)
    #expect(f.state?.panes.map(\.tabs) == before.panes.map(\.tabs))
    #expect(f.state?.frames(in: f.bounds) == before.frames(in: f.bounds))
}

// Probe: Restored windows from a relaunched app have new IDs, despite matching titles.
@Test(.appTestApplication) @MainActor func probeRelaunchDoesNotReuseClosedWindowsPaneSlots() async throws {
    let f = DesktopProbe(sameApp: true); defer { f.model.shutdown() }; try await f.start()
    let destination = try #require(f.state?.activePaneID)
    for id in [f.ids[1], f.ids[2]] {
        f.system.windows.removeAll { $0.id == id }; f.event(.destroyed, id, pid: 501)
    }
    try await f.settle()
    let replacements = [WindowID(rawValue: "restored-new-1"), .init(rawValue: "restored-new-2")]
    for (index, id) in replacements.enumerated() { f.add(id, pid: 950, bundle: "com.example.shared", title: "Document \(index + 1)") }
    try await f.settle()
    for id in replacements { #expect(f.state?.paneID(containing: id) == destination) }
    #expect(f.state?.windowIDs.isDisjoint(with: [f.ids[1], f.ids[2]]) == true)
}

// Probe: Closing a selected middle tab leaves pane identity, dimensions and peers intact.
@Test(.appTestApplication) @MainActor func probeClosingMiddleSelectionUsesRightNeighborWithoutResize() async throws {
    let f = DesktopProbe(count: 7); defer { f.model.shutdown() }; try await f.start()
    try await f.action(.select(f.ids[3]))
    let before = try #require(f.state), home = try #require(f.state?.pane(containing: f.ids[3]))
    f.system.windows.removeAll { $0.id == f.ids[3] }; f.event(.destroyed, f.ids[3], pid: 413)
    try await f.settle()
    #expect(f.state?.panes.first { $0.id == home.id }?.tabs == [f.ids[0], f.ids[6]])
    #expect(f.state?.panes.first { $0.id == home.id }?.selected == f.ids[6])
    #expect(f.state?.panes.map(\.id) == before.panes.map(\.id))
    #expect(f.state?.frames(in: f.bounds) == before.frames(in: f.bounds))
}

// Probe: Explicit pane activation differs from the still-focused application's pane.
@Test(.appTestApplication) @MainActor func probeArrivalHonorsActivePaneWithFocusElsewhere() async throws {
    let f = DesktopProbe(); defer { f.model.shutdown() }; try await f.start()
    let target = try #require(f.state?.panes[1].id)
    try await f.action(.activate(target))
    try #require(f.system.focusedID == f.ids[0])
    let arrival = WindowID(rawValue: "active-pane-arrival"); f.add(arrival)
    try await f.settle()
    #expect(f.state?.paneID(containing: arrival) == target)
    #expect(f.state?.panes.first { $0.id == target }?.selected == arrival)
}

// Probe: Repair keeps a hand-reordered group and a deliberate float on three panes.
@Test(.appTestApplication) @MainActor func probeRepairKeepsReorderedTabsAndUserFloat() async throws {
    let f = DesktopProbe(); defer { f.model.shutdown() }; try await f.start()
    let home = try #require(f.state?.paneID(containing: f.ids[3]))
    try await f.action(.move(f.ids[3], pane: home, index: 0))
    try await f.action(.float(f.ids[5]))
    let before = try #require(f.state), frame = try #require(f.system.windows.first { $0.id == f.ids[5] }?.frame)
    try await f.action(.repair)
    #expect(f.state?.panes == before.panes)
    #expect(f.state?.floatingWindowIDs.contains(f.ids[5]) == true)
    #expect(f.system.windows.first { $0.id == f.ids[5] }?.frame == frame)
}

// Probe: Native tear-off returns to the beginning of its own strip.
@Test(.appTestApplication) @MainActor func probeTearOffReturnsToOwnPaneFront() async throws {
    let f = DesktopProbe(count: 7); defer { f.model.shutdown() }; try await f.start()
    let before = try #require(f.state), home = try #require(before.paneID(containing: f.ids[3]))
    try #require(f.model.beginBentoDrag(displayID: f.display, sourceID: f.ids[3]))
    f.model.finishBentoDrag(displayID: f.display, sourceID: f.ids[3], outcome: .tab(paneID: home, index: 0))
    try await f.settle()
    #expect(f.state?.panes.first { $0.id == home }?.tabs == [f.ids[3], f.ids[0], f.ids[6]])
    #expect(f.state?.panes.first { $0.id == home }?.selected == f.ids[3])
    #expect(f.state?.panes.filter { $0.id != home } == before.panes.filter { $0.id != home })
}

// Probe: Native tear-off returns to the last index with one Undo step.
@Test(.appTestApplication) @MainActor func probeTearOffReturnsToOwnPaneEndAndUndoes() async throws {
    let f = DesktopProbe(count: 7); defer { f.model.shutdown() }; try await f.start()
    let before = try #require(f.state), home = try #require(before.paneID(containing: f.ids[3]))
    try #require(f.model.beginBentoDrag(displayID: f.display, sourceID: f.ids[3]))
    f.model.finishBentoDrag(displayID: f.display, sourceID: f.ids[3], outcome: .tab(paneID: home, index: 2))
    try await f.settle()
    #expect(f.state?.panes.first { $0.id == home }?.tabs == [f.ids[0], f.ids[6], f.ids[3]])
    try await f.action(.undo)
    #expect(f.state?.panes == before.panes)
}

// Probe: Auto-hide's small reserve does not prevent a floating center drop or its Undo.
@Test(.appTestApplication) @MainActor func probeAutoHideFloatingCenterDropKeepsOtherPaneOrder() async throws {
    let f = DesktopProbe(); defer { f.model.shutdown() }
    f.model.configuration.tabbedStripPresentation = .autoHide; try await f.start()
    try await f.action(.float(f.ids[5]))
    let before = try #require(f.state), target = try #require(before.panes[1].selected)
    try #require(f.model.beginBentoDrag(displayID: f.display, sourceID: f.ids[5]))
    f.model.finishBentoDrag(displayID: f.display, sourceID: f.ids[5], outcome: .swap(targetWindowID: target))
    try await f.settle()
    #expect(f.state?.paneID(containing: f.ids[5]) == before.paneID(containing: target))
    #expect(f.state?.presentation == .autoHide)
    #expect(f.state?.panes[0] == before.panes[0])
    try await f.action(.undo)
    #expect(f.state?.panes == before.panes && f.state?.floatingWindowIDs == before.floatingWindowIDs)
}

// Probe: A Space switch cancels a queued pane move before its first placement.
@Test(.appTestApplication) @MainActor func probeSwitchBeforePlacementDoesNotPublishUnplacedMove() async throws {
    let f = DesktopProbe(); defer { f.model.shutdown() }; try await f.start()
    let before = try #require(f.state), windows = f.system.windows
    f.model.performTabbed(.move(f.ids[3], pane: before.panes[1].id, index: 0))
    try #require(f.model.hasPendingTabbedPlacement)
    try await f.switchTo(f.away, windows: f.other, focus: f.other[0].id)
    try await f.switchTo(f.home, windows: windows, focus: f.ids[0])
    #expect(f.state?.panes == before.panes)
    #expect(f.state?.frames(in: f.bounds) == before.frames(in: f.bounds))
}

// Probe: A Space switch only on an Adaptive secondary display leaves primary Tabbed panes alone.
@Test(.appTestApplication) @MainActor func probeSecondaryAdaptiveSpaceSwitchKeepsPrimaryTabbedState() async throws {
    let f = DesktopProbe(secondDisplay: true); defer { f.model.shutdown() }; try await f.start()
    let second = DisplayID(rawValue: "secondary-probe")
    f.system.focusedID = .init(rawValue: "secondary-0"); f.model.setActiveMode(.bento); try await f.settle()
    let before = try #require(f.state), primary = f.system.windows.filter { $0.displayID == f.display }
    let secondary = f.system.windows.filter { $0.displayID == second }
    let writes = Dictionary(uniqueKeysWithValues: f.ids.map { ($0, f.system.frameWriteCounts[$0, default: 0]) })
    for _ in 0..<3 {
        f.system.windows = primary; f.system.focusedID = f.ids[0]
        f.system.desktopObservation?.currentSpaceByDisplay[second] = .init(rawValue: 202)
        f.model.beginActiveSpaceStabilization(); try await f.settle()
        f.system.windows = primary + secondary; f.system.focusedID = .init(rawValue: "secondary-0")
        f.system.desktopObservation?.currentSpaceByDisplay[second] = .init(rawValue: 201)
        f.model.beginActiveSpaceStabilization(); try await f.settle()
        #expect(f.state?.panes == before.panes)
    }
    #expect(f.state?.frames(in: f.bounds) == before.frames(in: f.bounds))
    #expect(Dictionary(uniqueKeysWithValues: f.ids.map { ($0, f.system.frameWriteCounts[$0, default: 0]) }) == writes)
}

// Probe: Removing an active empty pane and Undo restores pane identity and arrival routing.
@Test(.appTestApplication) @MainActor func probeRemoveActiveEmptyPaneUndoRestoresArrivalDestination() async throws {
    let f = DesktopProbe(count: 2); defer { f.model.shutdown() }; try await f.start()
    let empty = try #require(f.state?.panes.last?.id)
    try await f.action(.activate(empty))
    let before = try #require(f.state)
    try await f.action(.removePane(empty)); try await f.action(.undo)
    #expect(f.state?.panes == before.panes && f.state?.activePaneID == empty)
    let id = WindowID(rawValue: "after-pane-undo"); f.add(id); try await f.settle()
    #expect(f.state?.paneID(containing: id) == empty)
}

// Probe: A keep-groups preset with an empty pane survives a round trip and Undo.
@Test(.appTestApplication) @MainActor func probePresetThenSpaceRoundTripKeepsUndoGroups() async throws {
    let f = DesktopProbe(); defer { f.model.shutdown() }; try await f.start()
    let before = try #require(f.state)
    try await f.action(.preset(.grid, grouping: .keepTabGroups))
    let grid = try #require(f.state), windows = f.system.windows
    try await f.switchTo(f.away, windows: f.other, focus: f.other[1].id)
    try await f.switchTo(f.home, windows: windows, focus: f.ids[0])
    #expect(f.state?.panes == grid.panes)
    try await f.action(.undo)
    #expect(f.state?.panes == before.panes)
}

// Probe: A hidden-tab focus change in another pane must not reorder a custom strip.
@Test(.appTestApplication) @MainActor func probeSameAppHiddenFocusKeepsCustomTabOrder() async throws {
    let f = DesktopProbe(sameApp: true); defer { f.model.shutdown() }
    f.system.windows[4].processIdentifier = 501
    f.system.windows[4].bundleIdentifier = "com.example.shared"
    try await f.start()
    let pane = try #require(f.state?.paneID(containing: f.ids[4]))
    try await f.action(.move(f.ids[4], pane: pane, index: 0))
    try await f.action(.select(f.ids[1]))
    let before = try #require(f.state)
    try await f.focus(f.ids[2]); try await f.focus(f.ids[4])
    #expect(f.state?.panes.map(\.tabs) == before.panes.map(\.tabs))
    #expect(f.state?.activeWindowID == f.ids[4])
    #expect(f.state?.frames(in: f.bounds) == before.frames(in: f.bounds))
}
