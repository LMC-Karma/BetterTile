import AppKit
import BetterTileCore
import Testing
@testable import BetterTileApp

@MainActor private func recoveryTransferFixture(
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

@MainActor private func recoveryTransferStore(_ model: BetterTileModel) -> LayoutSessionStore? {
    Mirror(reflecting: model).children.first { $0.label?.hasSuffix("sessionStore") == true }?.value as? LayoutSessionStore
}
@Suite(.appTestApplication, .serialized) @MainActor
struct DisplayTransferRecoveryOwnershipTests {
    @Test(arguments: ["none", "source", "destination", "both"], ["write", "cas"])
    func transferRollbackSuspendsCapturedOwners(changed: String, failure: String) async throws {
        let (system, model) = try await recoveryTransferFixture()
        defer { model.shutdown() }
        let displays = system.availableDisplays
        let first = NativeSpaceID(rawValue: 1), second = NativeSpaceID(rawValue: 2)
        system.desktopObservation = NativeDesktopObservation(currentSpaceByDisplay: Dictionary(uniqueKeysWithValues: displays.map { ($0.id, first) }),
            knownSpacesByDisplay: Dictionary(uniqueKeysWithValues: displays.map { ($0.id, Set([first, second])) }),
            windowMembership: Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, Set([first])) }))
        model.handleApplicationTopologyChange()
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        let owners = displays.map { recoveryTransferStore(model)!.session(for: $0.id)! }
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
            let stored = try #require(recoveryTransferStore(model)?.allSessions(for: owner.displayID).first { $0.id == owner.id })
            #expect(stored.automaticWritesSuspended, "The captured source and destination must both suspend.")
            if let active = recoveryTransferStore(model)?.session(for: owner.displayID), active.id != owner.id {
                #expect(!active.automaticWritesSuspended)
            }
        }
        #expect(system.windows.map(\.frame) != before.map(\.frame))
        #expect(model.statusMessage?.contains("Repair Layout on both affected desktops") == true)
    }
}

@Suite(.appTestApplication, .serialized) @MainActor
struct DisplayTransferRecoveryPreflightTests {
    @Test(arguments: [1, 2], ["source", "destination", "nativeSource", "nativeDestination"])
    func returningInventoryCannotTransferAfterSpaceChanges(read: Int, changed: String) async throws {
        let (system, model) = try await recoveryTransferFixture()
        defer { model.shutdown() }
        let displays = system.availableDisplays
        let first = NativeSpaceID(rawValue: 1), second = NativeSpaceID(rawValue: 2)
        system.desktopObservation = NativeDesktopObservation(currentSpaceByDisplay: Dictionary(uniqueKeysWithValues: displays.map { ($0.id, first) }),
            knownSpacesByDisplay: Dictionary(uniqueKeysWithValues: displays.map { ($0.id, Set([first, second])) }),
            windowMembership: Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, Set([first])) }))
        model.handleApplicationTopologyChange()
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        let before = system.windows
        let display = displays[changed.lowercased().contains("source") ? 0 : 1]
        system.applicationHoldsUntil[before[0].processIdentifier] = system.uptime - 1
        system.frameWriteCounts = [:]; system.requestedFrames = [:]
        var reads = 0
        var invalidated = false
        var returningRecorded = false
        var inventoryRead = false
        system.onVisibleWindowSweep = { _ in inventoryRead = true }
        system.onWindowSnapshots = { [weak model, weak system] in
            guard let model, let system, inventoryRead, !invalidated else { return }
            reads += 1
            guard reads == read else { return }
            invalidated = true
            let pending = Mirror(reflecting: model).children.first { $0.label?.hasSuffix("applicationRecoveryPendingWindows") == true }?.value as? [WindowID: Int32]
            returningRecorded = pending?[before[0].id] == before[0].processIdentifier
            system.desktopObservation?.currentSpaceByDisplay[display.id] = second
            if !changed.hasPrefix("native") { model.beginActiveSpaceStabilization() }
        }
        model.perform(.nextDisplay)
        try #require(invalidated)
        try #require(returningRecorded)
        #expect(system.frameWriteCounts.isEmpty, "No old-Space transfer may dispatch after preflight observes a new desktop.")
        #expect(system.windows == before)
    }
}

@Suite(.appTestApplication, .serialized) @MainActor
struct DisplayTransferRecoveryContextTests {
    @Test(arguments: [1, 2], ["nativeToPublic", "publicToNative", "fullscreenSource", "fullscreenDestination",
                            "workAreaSource", "workAreaDestination", "commandSource", "commandDestination",
                            "stableNative", "stablePublic"])
    func transferRevalidatesBothDesktopsAfterInventory(read: Int, change: String) async throws {
        let (system, model) = try await recoveryTransferFixture()
        defer { model.shutdown() }
        let displays = system.availableDisplays
        let spaces = displays.indices.map { NativeSpaceID(rawValue: UInt64($0 + 1)) }
        let observation = NativeDesktopObservation(
            currentSpaceByDisplay: Dictionary(uniqueKeysWithValues: displays.enumerated().map { ($0.element.id, spaces[$0.offset]) }),
            knownSpacesByDisplay: Dictionary(uniqueKeysWithValues: displays.enumerated().map { ($0.element.id, Set([spaces[$0.offset]])) }),
            windowMembership: Dictionary(uniqueKeysWithValues: system.windows.map { window in
                (window.id, Set([spaces[displays.firstIndex { $0.id == window.displayID }!]]))
            }))
        if change != "publicToNative", change != "stablePublic" { system.desktopObservation = observation }
        model.handleApplicationTopologyChange()
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        let before = system.windows
        let owners = displays.map { recoveryTransferStore(model)!.session(for: $0.id)! }
        system.applicationHoldsUntil[before[0].processIdentifier] = system.uptime - 1
        system.frameWriteCounts = [:]
        system.requestedFrames = [:]
        var inventoryRead = false
        var reads = 0
        var reached = false
        var newerOwner: LayoutSession?
        system.onVisibleWindowSweep = { _ in inventoryRead = true }
        system.onWindowSnapshots = { [weak model, weak system] in
            guard let model, let system, inventoryRead, !reached else { return }
            reads += 1
            guard reads == read else { return }
            reached = true
            let index = change.hasSuffix("Destination") ? 1 : 0
            switch change {
            case "nativeToPublic": system.desktopObservation = nil
            case "publicToNative": system.desktopObservation = observation
            case "fullscreenSource", "fullscreenDestination":
                // Keep the Space identity unchanged, isolating automatic-layout eligibility.
                system.desktopObservation?.fullscreenSpaceIDs.insert(spaces[index])
            case "workAreaSource", "workAreaDestination":
                system.availableDisplays[index].visibleFrame.size.width -= 80
            case "commandSource", "commandDestination":
                system.focusedID = before[index * 2].id
                model.setActiveMode(.manual)
                newerOwner = recoveryTransferStore(model)?.session(for: displays[index].id)
            default: break
            }
        }
        model.perform(.nextDisplay)
        try #require(reached)
        if change.hasPrefix("stable") {
            #expect(system.windows[0].displayID == displays[1].id)
            #expect(system.windows != before)
            #expect(!system.frameWriteCounts.isEmpty)
            #expect(model.statusMessage == nil)
        } else {
            #expect(system.frameWriteCounts.isEmpty, "Invalid context must reject before the first transfer write.")
            #expect(system.windows == before)
            #expect(model.statusMessage != nil)
            for owner in owners {
                let stored = try #require(recoveryTransferStore(model)?.allSessions(for: owner.displayID).first { $0.id == owner.id })
                #expect(!stored.automaticWritesSuspended, "A pre-dispatch rejection caused no damage.")
            }
            if let newerOwner {
                #expect(recoveryTransferStore(model)?.session(for: newerOwner.displayID) == newerOwner)
                #expect(newerOwner.mode == .manual)
            }
        }
    }
}
