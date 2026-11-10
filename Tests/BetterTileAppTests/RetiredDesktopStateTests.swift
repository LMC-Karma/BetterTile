import Foundation
import Testing
@testable import BetterTileApp
@testable import BetterTileCore
@testable import BetterTileMacOS

/// A display unplug retires its desktops after the display hold. A reconnect
/// restores a retired desktop with the same session ID, so the state that the
/// desktop owns must stay until the session store forgets that desktop.
@MainActor private final class RetiredDesktopFixture {
    let system = makeManualWindowSystem(drivingPolicyDeadlines: true)
    let model: BetterTileModel
    let left = WindowID(rawValue: "left-editor"), right = WindowID(rawValue: "right-editor")
    init(carryOver: Bool) {
        var display = system.mainDisplay
        display.persistentIdentifier = "A"
        system.availableDisplays = [display]
        system.windows = [left, right].enumerated().map { index, id in
            WindowSnapshot(id: id, processIdentifier: Int32(41 + index), bundleIdentifier: "com.example.Editor",
                frame: BTRect(x: Double(index * 400), y: 40, width: 400, height: 500), displayID: display.id)
        }
        system.focusedID = right
        let space = NativeSpaceID(rawValue: 1)
        system.desktopObservation = NativeDesktopObservation(currentSpaceByDisplay: [display.id: space],
            knownSpacesByDisplay: [display.id: [space]], windowMembership: [left: [space], right: [space]])
        model = makeModel(system: system)
        model.configuration.defaultLayoutMode = .manual
        model.configuration.defaultTabbedPreset = .single
        model.configuration.keepsDesktopLayoutsAcrossDisplays = carryOver
    }
    var display: DisplayID { system.availableDisplays[0].id }
    func store() throws -> LayoutSessionStore { try sessionStore(of: model) }
    func idle() async throws {
        await system.advance(by: .seconds(1))
        try #require(await system.waitFor { !self.model.isHoldingDisplayChange && !self.model.hasPendingTabbedPlacement
            && self.model.windowEventTask == nil && self.model.settlementTasks.isEmpty })
    }
    /// Replaces the only display. The hold ends, so the old display's desktops retire.
    func replaceDisplay(_ name: String, uuid: String, space: UInt64) async throws {
        model.handleDisplayChange(.displayReconfigurationBegan)
        var screen = system.mainDisplay
        screen.id = DisplayID(rawValue: name)
        screen.persistentIdentifier = uuid
        system.availableDisplays = [screen]
        for index in system.windows.indices { system.windows[index].displayID = screen.id }
        let native = NativeSpaceID(rawValue: space)
        system.desktopObservation = NativeDesktopObservation(currentSpaceByDisplay: [screen.id: native],
            knownSpacesByDisplay: [screen.id: [native]],
            windowMembership: Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, [native]) }))
        model.handleDisplayChange(.displayReconfigurationEnded)
        try await idle()
    }
    func field(_ name: String, of owner: Any) -> Any? {
        Mirror(reflecting: owner).children.first {
            $0.label?.trimmingCharacters(in: CharacterSet(charactersIn: "_")) == name
        }?.value
    }
    /// The desktop-owned model collections that the reconnect can use again.
    func ownedFields(_ id: DesktopSessionID) -> [String: Bool] {
        var owned: [String: Bool] = [:]
        for name in ["tabbedUndo", "onScreenProtectedPanes", "applicationRecoveryFallbackMatches", "bentoStateBeforeFocus"] {
            owned[name] = (field(name, of: model) as? [DesktopSessionID: Any])?[id] != nil
        }
        owned["spacePanelCorrections"] = (field("spacePanelCorrections", of: model) as? Set<DesktopSessionID>)?.contains(id) == true
        return owned
    }
    func count(_ name: String, in owner: Any) -> Int { (field(name, of: owner) as? any Collection)?.count ?? -1 }
}

@Suite(.appTestApplication, .serialized) @MainActor
struct RetiredDesktopStateTests {
    /// Unplug, hold expiry and retirement keep the desktop's Tabbed state.
    /// The reconnect then treats it exactly as main does: restoration drops
    /// geometry-dependent Tabbed Undo from the old screen, and Undo works for
    /// the restored desktop's next change.
    @Test(arguments: [false, true])
    func aRetiredTabbedDesktopKeepsItsStateUntilAReconnectRestoresIt(carryOver: Bool) async throws {
        let f = RetiredDesktopFixture(carryOver: carryOver)
        defer { f.model.shutdown() }
        f.model.setActiveMode(.tabbed)
        try await f.idle()
        f.model.performTabbed(.preset(.columns, grouping: .distributeWindows))
        try await f.idle()
        let original = try #require(f.store().session(for: f.display))
        let owned = f.ownedFields(original.id)
        try #require(owned["tabbedUndo"] == true)

        try await f.replaceDisplay("away", uuid: "B", space: 2)
        if !carryOver {
            try #require(f.store().retiredSessions.contains { $0.session.id == original.id })
            #expect(f.ownedFields(original.id) == owned, "A retired desktop lost state that its reconnect can use")
        }

        try await f.replaceDisplay("returned", uuid: "A", space: 3)
        let restored = try #require(f.store().session(for: f.display))
        #expect(restored.id == original.id && restored.mode == .tabbed)
        var afterRestore = owned
        afterRestore["tabbedUndo"] = false
        #expect(f.ownedFields(original.id) == afterRestore)
        let before = f.model.activeTabbedState
        f.model.performTabbed(.preset(.rows, grouping: .distributeWindows))
        try await f.idle()
        #expect(f.model.activeTabbedState != before)
        f.model.performTabbed(.undo)
        try await f.idle()
        #expect(f.model.activeTabbedState?.groups.panes.count == before?.groups.panes.count)
    }

    /// A Display Trigger that applies again after a reconnect keeps two
    /// same-app windows in the slots they held before the unplug.
    @Test(arguments: [false, true])
    func aReconnectKeepsSameAppWindowsInTheirSavedLayoutSlots(carryOver: Bool) async throws {
        let f = RetiredDesktopFixture(carryOver: carryOver)
        defer { f.model.shutdown() }
        try await f.idle()
        let applier = try #require(f.model.savedLayoutApplier)
        applier.observesKeyboard = false
        applier.application = { id in .init(bundleIdentifier: id, name: id, url: URL(fileURLWithPath: "/fixture/\(id).app")) }
        let document = SavedLayoutDocument(name: "Pair", mode: .manual,
            slots: [.init(id: "first", bundleID: "com.example.Editor"), .init(id: "second", bundleID: "com.example.Editor")],
            windows: [.init(slot: "first", rect: .init(x: 0, y: 0, width: 0.5, height: 1)),
                      .init(slot: "second", rect: .init(x: 0.5, y: 0, width: 0.5, height: 1))])
        let first = await f.system.drive { await applier.apply(document, displayID: f.display, automatic: true) }
        #expect(first?.placed == 2)
        let remembered = try #require(applier.lastPlan?.assignments)
        try await f.idle()
        // The user swaps the two windows. The fresh optimum then swaps the
        // equally ranked windows; only the remembered assignment keeps them.
        // A renamed copy of the layout has no remembered assignment.
        var copy = document
        copy.name = "Pair copy"
        func swapWindows() throws {
            let one = try #require(f.system.windows.firstIndex { $0.id == f.left })
            let two = try #require(f.system.windows.firstIndex { $0.id == f.right })
            (f.system.windows[one].frame, f.system.windows[two].frame) = (f.system.windows[two].frame, f.system.windows[one].frame)
        }
        func checkMemoryDecides() throws {
            let fresh = try #require(applier.preview(copy, displayID: f.display).plan).assignments
            try #require(fresh != remembered, "The fresh optimum must differ, or this test proves nothing")
        }
        try swapWindows()
        try checkMemoryDecides()
        #expect(try #require(applier.preview(document, displayID: f.display).plan).assignments == remembered)

        try await f.replaceDisplay("away", uuid: "B", space: 2)
        #expect(f.count("rememberedAssignments", in: applier) >= 1)
        #expect(applier.hasUndo)

        try await f.replaceDisplay(f.system.mainDisplay.id.rawValue, uuid: "A", space: 1)
        try checkMemoryDecides()
        let again = await f.system.drive { await applier.apply(document, displayID: f.display, automatic: true) }
        #expect(again?.issues.isEmpty == true)
        #expect(applier.lastPlan?.assignments == remembered, "A reconnect swapped two same-app windows")
    }

    /// Retired desktops stay bounded. Desktops whose windows all closed are
    /// forgotten, and their owned state goes with them.
    @Test func aForgottenRetiredDesktopReleasesItsTabbedState() async throws {
        let f = RetiredDesktopFixture(carryOver: false)
        defer { f.model.shutdown() }
        f.model.setActiveMode(.tabbed)
        try await f.idle()
        f.model.performTabbed(.preset(.columns, grouping: .distributeWindows))
        try await f.idle()
        let original = try #require(f.store().session(for: f.display))
        try await f.replaceDisplay("away", uuid: "B", space: 2)
        try #require(f.ownedFields(original.id)["tabbedUndo"] == true)
        for id in [f.left, f.right] {
            f.system.windows.removeAll { $0.id == id }
            f.system.eventHandler?(.init(kind: .destroyed, windowID: id, processIdentifier: 41))
        }
        try await f.idle()
        #expect(try !f.store().retiredSessions.contains { $0.session.id == original.id })
        #expect(f.ownedFields(original.id).values.allSatisfy { !$0 })
    }
}
