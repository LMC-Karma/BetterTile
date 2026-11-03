import AppKit
import BetterTileCore
import Testing
@testable import BetterTileApp

@MainActor private func transferFeedbackFixture(
    count: Int = 2, destinationCount: Int = 2, minimumSize: BTSize = BTSize(width: 120, height: 80),
    stacked: Bool = false
) async throws -> (FakeAppWindowSystem, BetterTileModel) {
    _ = NSApplication.shared
    let system = makeManualWindowSystem()
    system.availableDisplays = (0..<count).map { index in
        let frame = BTRect(x: stacked ? -800 : Double(index) * 2560, y: stacked ? Double(index - 1) * 1440 : 0, width: index == 2 ? 1920 : 2560, height: index == 2 ? 1080 : 1440)
        return DisplaySnapshot(id: DisplayID(rawValue: "display-\(index)"), frame: frame,
            visibleFrame: BTRect(x: frame.minX, y: frame.minY + 30, width: frame.size.width, height: frame.size.height - (index == 0 ? 110 : 30)),
            scaleFactor: index == 0 ? 2 : 1, isMain: index == 0)
    }
    system.windows = system.availableDisplays.enumerated().flatMap { index, display in
        let panes = index == 1 ? destinationCount : 2
        return (0..<panes).map { pane in
            WindowSnapshot(id: WindowID(rawValue: "window-\(index)-\(pane)"),
                processIdentifier: Int32(42 + index * 2 + pane),
                frame: BTRect(x: display.visibleFrame.minX + Double(pane) * display.visibleFrame.size.width / Double(panes), y: display.visibleFrame.minY,
                              width: display.visibleFrame.size.width / Double(panes), height: display.visibleFrame.size.height), displayID: display.id,
                constraints: WindowConstraints(minimumSize: minimumSize, minimumSizeSource: .hint))
        }
    }
    system.focusedID = system.windows[0].id
    let model = makeModel(system: system)
    model.configuration.defaultLayoutMode = .bento
    model.configuration.bentoInnerGap = 0
    model.setActiveMode(.bento)
    try #require(system.availableDisplays.allSatisfy { model.activeMode(for: $0.id) == .bento })
    await system.advance(by: .milliseconds(350))
    system.requestedFrames = [:]
    system.frameWriteCounts = [:]
    return (system, model)
}

@MainActor private func transferFeedbackStore(_ model: BetterTileModel) -> LayoutSessionStore? {
    Mirror(reflecting: model).children.first { $0.label?.hasSuffix("sessionStore") == true }?.value as? LayoutSessionStore
}
@Suite(.appTestApplication, .serialized) @MainActor
struct TransferActionFeedbackTests {
    @Test(arguments: ["none", "source", "destination", "both"], ["write", "cas"])
    func transferFeedbackFeedback(changed: String, failure: String) async throws {
        let (system, model) = try await transferFeedbackFixture()
        defer { model.shutdown() }
        let displays = system.availableDisplays
        let first = NativeSpaceID(rawValue: 1), second = NativeSpaceID(rawValue: 2)
        system.desktopObservation = NativeDesktopObservation(currentSpaceByDisplay: Dictionary(uniqueKeysWithValues: displays.map { ($0.id, first) }),
            knownSpacesByDisplay: Dictionary(uniqueKeysWithValues: displays.map { ($0.id, Set([first, second])) }),
            windowMembership: Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, Set([first])) }))
        model.handleApplicationTopologyChange()
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        let owners = displays.map { transferFeedbackStore(model)!.session(for: $0.id)! }
        let before = system.windows
        system.frameWriteCounts = [:]
        system.requestedFrames = [:]
        let moved = before[0].id, peer = before[1].id
        if failure == "write" { system.failedFrameWriteNumbers[peer] = [1] }
        system.failedFrameWriteNumbers[moved] = failure == "cas" && changed == "none" ? [2, 3] : [2]
        var switched = false
        func changeSessions() {
            guard !switched else { return }; switched = true
            for (index, display) in displays.enumerated() where changed == "both" || changed == (index == 0 ? "source" : "destination") {
                system.desktopObservation?.currentSpaceByDisplay[display.id] = second
                system.offscreenWindowIDs.formUnion(before.filter { $0.displayID == display.id }.map(\.id))
            }
            if changed != "none" { model.beginActiveSpaceStabilization() }
            else if failure == "cas" { model.configuration.singleWindowPlacement = .center; model.setActiveMode(.manual) }
        }
        if failure == "write" {
            system.onWindowSnapshots = {
                if system.frameWriteCounts[peer, default: 0] > 0 { changeSessions() }
            }
        } else {
            system.onFrameWrite = { id, _ in if id == peer { changeSessions() } }
        }
        model.perform(.nextDisplay)
        try #require(switched)
        for owner in owners {
            let stored = try #require(transferFeedbackStore(model)?.allSessions(for: owner.displayID).first { $0.id == owner.id })
            #expect(stored.automaticWritesSuspended, "The captured source and destination must both suspend.")
            if let active = transferFeedbackStore(model)?.session(for: owner.displayID), active.id != owner.id {
                #expect(!active.automaticWritesSuspended)
            }
        }
        #expect(system.windows.map(\.frame) != before.map(\.frame))
        #expect(model.statusMessage?.contains("Repair Layout on both affected desktops") == true)
        let visible = [model.lastActionFeedback?.message, model.lastActionFeedback?.detail].compactMap { $0 }.joined(separator: " ")
        #expect(model.lastActionFeedback?.kind == .failure)
        #expect(model.lastActionFeedback?.detail == model.statusMessage)
        #expect(visible.contains("both affected desktops"), "The visible result must name both affected desktops")
    }
}
