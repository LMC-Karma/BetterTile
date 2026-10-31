import AppKit
import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

/// Feed the adapter's application-admission decision into a fake inventory,
/// then exercise the mutation route for each mode. No live AX reads are used.
@Test(.macOSTestApplication, arguments: LayoutMode.availableModes) @MainActor
func ownApplicationWindowsStayOutsideEveryLayoutMode(mode: LayoutMode) async throws {
    let system = FakeWindowSystem()
    let display = system.availableDisplays[0]
    let ownPID: Int32 = 42
    let settings = WindowSnapshot(
        id: WindowID(rawValue: "settings"), processIdentifier: ownPID,
        frame: BTRect(x: 100, y: 100, width: 700, height: 600), displayID: display.id
    )
    var setup = settings
    setup.id = WindowID(rawValue: "setup")
    let peers = [43, 44].map { pid in
        WindowSnapshot(id: WindowID(rawValue: "peer-\(pid)"), processIdentifier: Int32(pid),
                       frame: BTRect(x: 200, y: 200, width: 600, height: 400), displayID: display.id)
    }
    // Level is deliberately absent: normal and floating windows use the same
    // process rule, including when Show Dock Icon makes BetterTile regular.
    system.windows = ([settings, setup] + peers).filter {
        AccessibilityWindowSystem.shouldManageApplication(
            processIdentifier: $0.processIdentifier, ownProcessIdentifier: ownPID,
            activationPolicy: .regular, isHidden: false, includeHidden: false)
    }
    #expect(Set(system.windows.map(\.id)) == Set(peers.map(\.id)))
    let coordinator = WindowCoordinator(system: system)
    if case .unavailable = coordinator.plan(.leftHalf, for: settings.id) {} else {
        Issue.record("Settings must not be available to a captured action")
    }
    switch mode {
    case .manual, .linked:
        guard case let .ready(plan) = coordinator.plan(.leftHalf) else {
            Issue.record("The external window must be available")
            return
        }
        #expect(coordinator.perform(plan).isApplied)
    case .bento, .tabbed:
        let layout = BentoLayoutState(root: .partition(BentoPartition(
            axis: .vertical, children: system.windows.map { .leaf($0.id) })))
        if mode == .bento {
            let placements = BentoLayoutEngine(state: layout).placements(for: system.windows, in: display)
            #expect(coordinator.applyPlacements(placements).isApplied)
        } else {
            let tabbed = try #require(TabbedLayoutState(adopting: layout))
            #expect(tabbed.windowIDs.isDisjoint(with: [settings.id, setup.id]))
            let placements = try tabbed.placements(in: display.visibleFrame, windows: system.windows)
            let result = await coordinator.applyTabbed(
                placements: placements, selected: peers.map(\.id), previousSelected: [],
                focus: peers[0].id, isCurrent: { true })
            #expect(result.isApplied)
        }
    }
    #expect(!system.frameWriteCounts.isEmpty)
    #expect(system.frameWriteCounts[settings.id] == nil)
    #expect(system.frameWriteCounts[setup.id] == nil)
    #expect(system.raisedWindows.allSatisfy { $0.0 != settings.id && $0.0 != setup.id })
}

@Test(.macOSTestApplication, arguments: [NSApplication.ActivationPolicy.regular, .accessory, .prohibited], [false, true])
func ownApplicationExclusionAlsoAppliesToHiddenObserverInventories(
    policy: NSApplication.ActivationPolicy, includeHidden: Bool
) {
    #expect(!AccessibilityWindowSystem.shouldManageApplication(
        processIdentifier: 42, ownProcessIdentifier: 42, activationPolicy: policy,
        isHidden: true, includeHidden: includeHidden))
}
