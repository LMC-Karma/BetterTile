import BetterTileCore
import Testing
@testable import BetterTileMacOS

@Suite(.macOSTestApplication) @MainActor
struct WindowMutationOwnershipTests {
    @Test func serialOwnershipBatchPreflightsEveryWindowBeforeWritingAny() {
        let system = FakeWindowSystem()
        system.addSecondWindow()
        let ids = Set(system.windows.map(\.id))
        system.unpreparedBatchWindowID = system.windows[1].id
        let coordinator = WindowCoordinator(system: system)
        let outcome = coordinator.applyPlacements(system.windows.map {
            Placement(windowID: $0.id, frame: BTRect(x: 0, y: 0, width: 400, height: 300))
        }, revalidateBeforeEachWrite: true, validating: { true })
        #expect(system.preparedFrameWriteIDs == [ids])
        #expect(system.frameWriteCounts.isEmpty)
        guard case .failed = outcome else { Issue.record("Preflight must fail without writes"); return }
    }

    @Test func cancelledRequestRestoresHiddenTabWritesWhileTheDesktopRemainsOwned() async {
        let system = FakeWindowSystem()
        system.addSecondWindow()
        let before = system.windows
        let selected = before[0], hidden = before[1]
        let coordinator = WindowCoordinator(system: system)
        var requestIsCurrent = true
        system.writeReadbackHandler = { _, _, _, _ in requestIsCurrent = false }
        let outcome = await coordinator.applyTabbed(placements: [
            Placement(windowID: selected.id, frame: selected.frame),
            Placement(windowID: hidden.id, frame: BTRect(x: 0, y: 0, width: 400, height: 300))
        ], required: [selected.id], selected: [], previousSelected: [], focus: nil,
            rollbackValidating: { true }, revalidateBeforeEachWrite: true, isCurrent: { requestIsCurrent })
        guard case .failed = outcome else { Issue.record("Authorized hidden-tab restoration must fail cleanly"); return }
        #expect(system.windows == before)
        #expect(system.frameWriteCounts[selected.id] == nil)
        #expect(system.frameWriteCounts[hidden.id] == 2)
    }

    @Test(arguments: [false, true])
    func cancelledRequestRestoresFramesWhileDesktopOwnershipRemainsValid(tabbed: Bool) async {
        let system = FakeWindowSystem()
        system.addSecondWindow()
        let before = system.windows
        let windows = before.sorted { $0.id < $1.id }
        let coordinator = WindowCoordinator(system: system)
        var requestIsCurrent = true
        system.writeReadbackHandler = { _, _, _, _ in requestIsCurrent = false }
        let placements = windows.map {
            Placement(windowID: $0.id, frame: BTRect(x: 0, y: 0, width: 400, height: 300))
        }
        let outcome = if tabbed {
            await coordinator.applyTabbed(placements: placements, selected: [], previousSelected: [], focus: nil,
                rollbackValidating: { true }, revalidateBeforeEachWrite: true, isCurrent: { requestIsCurrent })
        } else {
            coordinator.applyPlacements(placements, rollbackValidating: { true }, revalidateBeforeEachWrite: true, validating: { requestIsCurrent })
        }
        guard case .failed = outcome else { Issue.record("Complete authorized restoration must fail cleanly"); return }
        #expect(system.windows == before)
        #expect(system.frameWriteCounts[windows[0].id] == 2)
        #expect(system.frameWriteCounts[windows[1].id] == nil)
    }

    @Test func placementStopsBeforeTheNextWriteAndRollbackAfterOwnershipChanges() {
        let system = FakeWindowSystem()
        system.addSecondWindow()
        let coordinator = WindowCoordinator(system: system)
        let windows = system.windows.sorted { $0.id < $1.id }
        var ownsDesktop = true
        system.writeReadbackHandler = { _, _, _, _ in ownsDesktop = false }
        let outcome = coordinator.applyPlacements(windows.map {
            Placement(windowID: $0.id, frame: BTRect(x: 0, y: 0, width: 400, height: 300))
        }, revalidateBeforeEachWrite: true, validating: { ownsDesktop })
        guard case .degraded = outcome else { Issue.record("Partial placement must require Repair Layout"); return }
        #expect(system.frameWriteCounts[windows[0].id] == 1)
        #expect(system.frameWriteCounts[windows[1].id] == nil)
    }

    @Test func rollbackStopsBeforeItsNextWriteAfterOwnershipChanges() {
        let system = FakeWindowSystem()
        system.addSecondWindow()
        var third = system.windows[1]
        third.id = WindowID(rawValue: "zz-failing")
        system.windows.append(third)
        let windows = system.windows.sorted { $0.id < $1.id }
        let coordinator = WindowCoordinator(system: system)
        system.partiallyFailedFrameWriteNumbers[third.id] = [1]
        var ownsDesktop = true
        system.writeReadbackHandler = { id, _, _, _ in
            if system.frameWriteCounts[id] == 2 { ownsDesktop = false }
        }
        let outcome = coordinator.applyPlacements(windows.map {
            Placement(windowID: $0.id, frame: BTRect(x: 0, y: 0, width: 400, height: 300))
        }, revalidateBeforeEachWrite: true, validating: { ownsDesktop })
        guard case .degraded = outcome else { Issue.record("Interrupted rollback must require Repair Layout"); return }
        #expect(system.frameWriteCounts[windows[0].id] == 1)
        #expect(system.frameWriteCounts[windows[1].id] == 1)
        #expect(system.frameWriteCounts[third.id] == 2)
    }

    @Test(arguments: [false, true])
    func tabbedStopsBeforeRequiredOrHiddenWritesAndRaises(hidden: Bool) async {
        let system = FakeWindowSystem()
        system.addSecondWindow()
        let windows = system.windows.sorted { $0.id < $1.id }
        let coordinator = WindowCoordinator(system: system)
        var ownsDesktop = true
        system.writeReadbackHandler = { _, _, _, _ in ownsDesktop = false }
        let outcome = await coordinator.applyTabbed(placements: windows.map {
            Placement(windowID: $0.id, frame: BTRect(x: 0, y: 0, width: 400, height: 300))
        }, required: hidden ? [windows[0].id] : nil,
            selected: [windows[0].id], previousSelected: [], focus: windows[0].id,
            revalidateBeforeEachWrite: true, isCurrent: { ownsDesktop })
        guard case .degraded = outcome else { Issue.record("Partial Tabbed placement must require Repair Layout"); return }
        #expect(system.frameWriteCounts[windows[0].id] == 1)
        #expect(system.frameWriteCounts[windows[1].id] == nil)
        #expect(system.raisedWindows.isEmpty)
    }
}
