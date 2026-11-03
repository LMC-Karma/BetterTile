import AppKit
import BetterTileCore
@testable import BetterTileMacOS
import Foundation
import Testing
@testable import BetterTileApp

@Suite(.appTestApplication, .serialized) @MainActor
struct NonRecoverySettlementTests {
    private func twoWindows() -> FakeAppWindowSystem {
        _ = NSApplication.shared
        let system = FakeAppWindowSystem()
        system.windows.append(WindowSnapshot(id: WindowID(rawValue: "peer"), processIdentifier: 43,
            bundleIdentifier: "com.example.Peer", frame: BTRect(x: 300, y: 200, width: 600, height: 400),
            displayID: system.mainDisplay.id))
        return system
    }
    private func report(_ name: String, _ system: FakeAppWindowSystem) {
        let frames = system.windows.sorted { $0.id < $1.id }.map {
            "\($0.id.rawValue)=\($0.frame.minX),\($0.frame.minY),\($0.frame.size.width),\($0.frame.size.height);writes=\(system.frameWriteCounts[$0.id, default: 0])"
        }.joined(separator: " | ")
        print("COMPARISON \(name): \(frames)")
    }

    @Test(arguments: ["nativeSnap", "edgeResize", "unrecognisedMove"])
    func ordinaryEventDuringSettlement(kind: String) async throws {
        let system = twoWindows()
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.setActiveMode(.bento)
        try #require(await waitFor { model.settlementTasks.isEmpty })
        system.enforcedMinimumWidths[system.windows[0].id] = 510
        model.perform(.rightHalf)
        let owned = try #require(model.settlementTasks[system.mainDisplay.id])
        let writes = system.frameWriteCounts
        if kind == "nativeSnap" {
            system.windows[0].frame = BTRect(x: 0, y: 0, width: 510, height: 800)
        } else if kind == "edgeResize" {
            system.windows[0].frame.size.width += 80
        } else {
            system.windows[0].frame.origin.x += 75
            system.windows[0].frame.origin.y += 30
        }
        system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: system.windows[0].id, processIdentifier: 42))
        // Drain this batch before the actor yields to read-back settlement.
        model.processPendingWindowEvents()
        try #require(model.settlementTasks[system.mainDisplay.id] != nil, "The event must run during active settlement.")
        #expect(!owned.isCancelled, "An ordinary frame event must leave settlement in control.")
        #expect(system.frameWriteCounts == writes, "The event pass must not start a second transaction.")
        try #require(await waitFor { model.settlementTasks.isEmpty })
        report(kind, system)
    }

    @Test func ordinaryClampCallbacksKeepSettlement() async throws {
        let system = twoWindows()
        system.measuresOnWrite = true
        system.emitsFrameEvents = true
        let kept = system.windows[0].id
        system.enforcedMinimumWidths[kept] = 600
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.setActiveMode(.bento)
        let owned = try #require(model.settlementTasks[system.mainDisplay.id])
        system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: kept, processIdentifier: 42))
        // Drain this batch before the actor yields to read-back settlement.
        model.processPendingWindowEvents()
        try #require(model.settlementTasks[system.mainDisplay.id] != nil, "The event must run during active settlement.")
        #expect(!owned.isCancelled)
        try #require(await waitFor {
            system.windows[0].constraints.minimumSize.width == 600 && model.settlementTasks.isEmpty
        })
        #expect(BentoLayoutVerifier.overlappingWindowIDs(Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, $0.frame) })).isEmpty)
        report("minimumClamp", system)
    }

    @Test func dividerCommitCallbacksKeepSettlement() async throws {
        let system = twoWindows()
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.setActiveMode(.bento)
        try #require(await waitFor { model.settlementTasks.isEmpty })
        let presentation = model.dividerPresentation(windows: system.windows)
        model.dividerResize.refresh(boundaries: presentation.boundaries, obscuringFrames: [])
        let start = BTPoint(x: 500, y: 200)
        let interaction = try #require(DividerInteractionResolver.resolve(at: start, in: presentation.boundaries,
            hitWidth: 18, adjacencyTolerance: 6, paneGap: model.configuration.bentoInnerGap))
        let screen = try #require(NSScreen.screens.first)
        let release = CGPoint(x: 600, y: screen.frame.maxY - start.y)
        // Concurrent tests share NSApp.windows; another test's panel must not cover this grip.
        model.dividerResize.ownWindowsProvider = { [] }
        model.dividerResize.beginGesture(interaction: interaction, at: start)
        model.dividerResize.drag(to: release)
        model.dividerResize.displayTick()
        model.dividerResize.end(at: release)
        let owned = try #require(model.settlementTasks[system.mainDisplay.id])
        system.windows[0].frame.size.width += 8
        let writes = system.frameWriteCounts
        system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: system.windows[0].id, processIdentifier: 42))
        // Drain this batch before the actor yields to read-back settlement.
        model.processPendingWindowEvents()
        try #require(model.settlementTasks[system.mainDisplay.id] != nil, "The event must run during active settlement.")
        #expect(!owned.isCancelled)
        #expect(system.frameWriteCounts == writes)
        try #require(await waitFor { model.settlementTasks.isEmpty })
        report("divider", system)
    }

    @Test func dragSnapKeepsItsPartitionAfterCallbacks() async throws {
        let system = twoWindows()
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.setActiveMode(.bento)
        try #require(await waitFor { model.settlementTasks.isEmpty })
        let source = system.windows[0].id, display = system.mainDisplay.id
        try #require(model.beginBentoDrag(displayID: display, sourceID: source))
        system.windows[0].frame.origin.x += 70
        system.eventHandler?(WindowSystemEvent(kind: .moved, windowID: source, processIdentifier: 42))
        let frame = BTRect(x: 500, y: 0, width: 500, height: 800)
        model.finishBentoDrag(displayID: display, sourceID: source, outcome: .snap(action: .rightHalf, frame: frame))
        system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: source, processIdentifier: 42))
        await model.windowEventTask?.value
        try #require(await waitFor { model.settlementTasks.isEmpty })
        #expect(system.windows[0].frame.approximatelyEquals(frame, tolerance: 1))
        report("dragSnap", system)
    }
}
