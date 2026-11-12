import BetterTileCore
import BetterTileMacOS
import Foundation
import Testing
@testable import BetterTileApp

@Suite(.appTestApplication, .serialized) @MainActor
struct SavedLayoutCacheLifetimeTests {
    private func count(_ field: String, in owner: Any) -> Int {
        let value = Mirror(reflecting: owner).children.first {
            $0.label?.trimmingCharacters(in: CharacterSet(charactersIn: "_")) == field
        }?.value
        return (value as? any Collection)?.count ?? -1
    }

    @Test func desktopCleanupDoesNotRetireAnInFlightApplyCheckpoint() async {
        let h = ApplyHarness(); defer { h.onCommit = nil; h.close() }
        h.addWindow()
        _ = await h.applier.apply(h.document())
        let previous = h.system.windows[0].frame
        let disconnected = DisplaySnapshot(id: .init(rawValue: "other"),
            frame: h.system.mainDisplay.frame, visibleFrame: h.system.mainDisplay.visibleFrame)
        h.onCommit = {
            h.applier.updateUndoDesktops(.init(currentSpaceByDisplay: [disconnected.id: h.space(9)],
                knownSpacesByDisplay: [disconnected.id: [h.space(9)]]), displays: [disconnected])
            #expect(self.count("rememberedAssignments", in: h.applier!) == 1)
            #expect(self.count("undos", in: h.applier!) == 1)
        }
        let document = SavedLayoutDocument(name: "Smaller", mode: .manual,
            slots: [.init(id: "editor", bundleID: "com.example.Editor")],
            windows: [.init(slot: "editor", rect: .init(x: 0, y: 0, width: 0.8, height: 0.8))])
        #expect(await h.applier.apply(document).placed == 1)
        h.applier.updateUndoDesktops(h.system.desktopObservation, displays: h.system.availableDisplays, sessions: h.sessions)
        #expect(h.applier.canUndo)
        await h.applier.undoLastApply()
        #expect(h.system.windows[0].frame == previous)
    }

    @Test func anInvalidLibraryFileIsRetainedUntilItsRemovalIsConfirmed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CacheLibrary-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let actions = SavedLayoutActions(files: .init(directory: directory))
        #expect(actions.knownLibraryFiles == nil)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let invalid = directory.appendingPathComponent("invalid.json")
        try Data("invalid".utf8).write(to: invalid)
        actions.refresh()
        #expect(actions.knownLibraryFiles == ["invalid.json"])
        try FileManager.default.removeItem(at: invalid)
        actions.refresh()
        #expect(actions.knownLibraryFiles?.isEmpty == true)
        try FileManager.default.removeItem(at: directory)
        actions.refresh()
        #expect(actions.knownLibraryFiles == nil)
    }

    /// A desktop the model still owns, including a retired one, keeps its
    /// state. After the model forgets it, it stays while it is recent.
    @Test func anAbsentDesktopKeepsItsCheckpointWhileTheModelOwnsItOrItIsRecent() async {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow()
        _ = await h.applier.apply(h.document())
        let original = SavedLayoutDesktop(displayID: h.system.mainDisplay.id, spaceID: h.space(1))
        h.applier.isDesktopRetained = { $0 == original }
        let other = DisplaySnapshot(id: .init(rawValue: "other"),
            frame: h.system.mainDisplay.frame, visibleFrame: h.system.mainDisplay.visibleFrame)
        let observation = NativeDesktopObservation(currentSpaceByDisplay: [other.id: h.space(2)],
            knownSpacesByDisplay: [other.id: [h.space(2)]])
        h.applier.updateUndoDesktops(observation, displays: [other])
        #expect(count("rememberedAssignments", in: h.applier!) == 1)
        #expect(h.applier.hasUndo)
        h.applier.isDesktopRetained = { _ in false }
        h.applier.updateUndoDesktops(observation, displays: [other])
        #expect(count("rememberedAssignments", in: h.applier!) == 1)
        #expect(h.applier.hasUndo)
    }

    /// Each reconnect brings a new display ID. Only the newest absent
    /// desktops keep their Saved Layout state, so it stays bounded.
    @Test func reconnectsKeepOnlyTheNewestAbsentDesktopsAndTheCurrentUndo() async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.usesAllDisplays = true
        let document = SavedLayoutDocument(name: "Memory", mode: .manual,
            slots: [.init(id: "editor", bundleID: "com.example.Editor")],
            windows: [.init(slot: "editor", rect: .init(x: 0, y: 0, width: 1, height: 1))])
        let baseline = BTRect(x: 100, y: 100, width: 400, height: 300)
        for index in 1...50 {
            let display = DisplaySnapshot(id: .init(rawValue: "reconnect-\(index)"),
                frame: h.system.mainDisplay.frame, visibleFrame: h.system.mainDisplay.visibleFrame)
            let space = NativeSpaceID(rawValue: UInt64(index))
            let id = WindowID(rawValue: "window-\(index)")
            h.system.availableDisplays = [display]
            h.system.windows = [.init(id: id, processIdentifier: 42, bundleIdentifier: "com.example.Editor",
                frame: baseline, displayID: display.id)]
            h.system.desktopObservation = .init(currentSpaceByDisplay: [display.id: space],
                knownSpacesByDisplay: [display.id: [space]], windowMembership: [id: [space]])
            h.sessions = [:]
            let result = await h.applier.apply(document, displayID: display.id)
            #expect(result.placed == 1)
            h.applier.updateUndoDesktops(h.system.desktopObservation, displays: [display], sessions: h.sessions)
            let expected = min(index, SavedLayoutApplier.absentDesktopLimit + 1)
            for field in ["rememberedAssignments", "undos", "undoOrder", "undoSessionCache", "appliedDesktops"] {
                #expect(count(field, in: h.applier!) == expected, "\(field) is not bounded by the absent-desktop limit")
            }
            #expect(count("expiredUndoIDs", in: h.applier!) == 0)
            #expect(h.applier.canUndo(on: display.id))
        }
        await h.applier.undoLastApply(displayID: h.system.availableDisplays[0].id)
        #expect(h.system.windows[0].frame == baseline)
    }

    /// The model's ownership keeps a desktop beyond the absent-desktop limit.
    /// Without ownership, the 33rd newer absent desktop evicts it.
    @Test(arguments: [true, false])
    func modelOwnershipAloneKeepsADesktopPastTheAbsentDesktopLimit(owned: Bool) async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.usesAllDisplays = true
        let document = SavedLayoutDocument(name: "Memory", mode: .manual,
            slots: [.init(id: "editor", bundleID: "com.example.Editor")],
            windows: [.init(slot: "editor", rect: .init(x: 0, y: 0, width: 1, height: 1))])
        let frame = BTRect(x: 100, y: 100, width: 400, height: 300)
        func applyOnNewDisplay(_ name: String, space: UInt64) async throws -> SavedLayoutDesktop {
            let display = DisplaySnapshot(id: .init(rawValue: name),
                frame: h.system.mainDisplay.frame, visibleFrame: h.system.mainDisplay.visibleFrame)
            let native = NativeSpaceID(rawValue: space)
            let id = WindowID(rawValue: "window-\(name)")
            h.system.availableDisplays = [display]
            h.system.windows = [.init(id: id, processIdentifier: 42, bundleIdentifier: "com.example.Editor",
                frame: frame, displayID: display.id)]
            h.system.desktopObservation = .init(currentSpaceByDisplay: [display.id: native],
                knownSpacesByDisplay: [display.id: [native]], windowMembership: [id: [native]])
            h.sessions = [:]
            try #require(await h.applier.apply(document, displayID: display.id).placed == 1)
            h.applier.updateUndoDesktops(h.system.desktopObservation, displays: [display], sessions: h.sessions)
            return SavedLayoutDesktop(displayID: display.id, spaceID: native)
        }
        let retired = try await applyOnNewDisplay("retired", space: 1)
        h.applier.isDesktopRetained = { owned && $0 == retired }
        let newer = SavedLayoutApplier.absentDesktopLimit + 1
        for index in 1...newer { _ = try await applyOnNewDisplay("reconnect-\(index)", space: UInt64(100 + index)) }
        // The connected desktop, the 32 newest absent ones, and the owned one.
        let expected = SavedLayoutApplier.absentDesktopLimit + 1 + (owned ? 1 : 0)
        for field in ["rememberedAssignments", "undos", "undoSessionCache", "appliedDesktops"] {
            #expect(count(field, in: h.applier!) == expected, "\(field)")
        }
        let applied = Mirror(reflecting: h.applier!).children.first {
            $0.label?.trimmingCharacters(in: CharacterSet(charactersIn: "_")) == "appliedDesktops"
        }?.value as? [SavedLayoutDesktop]
        #expect(applied?.contains(retired) == owned)
    }

    @Test func anInactiveExistingSpaceAndAnUnknownInventoryKeepAssignments() async throws {
        let h = ApplyHarness(); defer { h.close() }
        for space in [1, 2] {
            h.arrive(space); h.addWindow(id: "window-\(space)", desktop: space)
            #expect(await h.applier.apply(h.document()).placed == 1)
        }
        h.applier.updateUndoDesktops(h.system.desktopObservation, displays: [h.system.mainDisplay])
        #expect(count("rememberedAssignments", in: h.applier!) == 2)
        h.applier.updateUndoDesktops(nil, displays: [])
        #expect(count("rememberedAssignments", in: h.applier!) == 2)
        #expect(count("undos", in: h.applier!) == 1)
        // A removed Space is absent, but it is recent, so a returning key
        // still finds its assignments.
        h.system.desktopObservation?.knownSpacesByDisplay[h.system.mainDisplay.id] = [h.space(2)]
        h.applier.updateUndoDesktops(h.system.desktopObservation, displays: [h.system.mainDisplay])
        #expect(count("rememberedAssignments", in: h.applier!) == 2)
        #expect(h.applier.canUndo(on: h.system.mainDisplay.id))
    }
}
