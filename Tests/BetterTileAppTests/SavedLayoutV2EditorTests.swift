import BetterTileCore
import Foundation
import Testing
@testable import BetterTileApp

@Suite(.appTestApplication) @MainActor struct SavedLayoutV2EditorTests {
    @Test(arguments: [LayoutMode.bento, .tabbed], TabbedPreset.allCases)
    func newPresetWithoutAppsHasFillablePanes(mode: LayoutMode, preset: TabbedPreset) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let editor = SavedLayoutEditor(files: .init(directory: root))
        editor.creation.begin(.init(mode: mode, preset: preset), editor: editor)
        let document = try #require(editor.document)
        #expect(document.slots.count == preset.paneCount)
        #expect(Set(document.slots.map(\.id)).count == preset.paneCount)
        #expect(document.slots.allSatisfy { $0.prefer.isEmpty })
        let panes = SavedLayoutCanvasGeometry.panes(document)
        #expect(panes.count == preset.paneCount)
        #expect(panes.allSatisfy { SavedLayoutCanvas.slotIDs(in: $0.node, document: document).count == 1 })
        #expect(document.groups.count == (mode == .tabbed ? preset.paneCount : 0))
        #expect(document.groups.allSatisfy { $0.slots.count == 1 && $0.selected == $0.slots.first })
        #expect(editor.creation.save(editor: editor))
        #expect(try SavedLayoutValidator.decode(editor.files.read(#require(editor.url))) == document)
    }

    @Test(arguments: [LayoutMode.bento, .tabbed, .manual])
    func newLayoutWithoutPresetHasAnAnyWindowSlot(mode: LayoutMode) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let editor = SavedLayoutEditor(files: .init(directory: root))
        editor.newLayout(mode: mode)
        let document = try #require(editor.document)
        #expect(document.slots.count == 1)
        #expect(document.slots.first?.prefer == [])
        if mode == .manual {
            #expect(document.layout == nil)
            #expect(document.windows.count == 1)
            #expect(document.windows.first?.slot == document.slots.first?.id)
        } else {
            #expect(try SavedLayoutCanvas.slotIDs(in: #require(document.layout), document: document) == document.slots.map(\.id))
        }
        #expect(try SavedLayoutValidator.decode(SavedLayoutValidator.encode(document)) == document)
    }

    @Test(arguments: [LayoutMode.bento, .tabbed])
    func editorSplitCreatesAnAnyWindowSlot(mode: LayoutMode) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let editor = SavedLayoutEditor(files: .init(directory: root))
        editor.newLayout(mode: mode)
        editor.split(try #require(editor.document.flatMap { SavedLayoutCanvasGeometry.panes($0).first }), axis: .vertical)
        let document = try #require(editor.document)
        #expect(document.slots.count == 2)
        #expect(Set(document.slots.map(\.id)).count == 2)
        #expect(document.slots.allSatisfy { $0.prefer.isEmpty })
        #expect(SavedLayoutCanvasGeometry.panes(document).allSatisfy {
            SavedLayoutCanvas.slotIDs(in: $0.node, document: document).count == 1
        })
        #expect(try SavedLayoutValidator.decode(SavedLayoutValidator.encode(document)) == document)
    }

    @Test func noAppPresetEnablesPageApplyAndArrangesBySizeAndPosition() async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow("com.example.Left", id: "left")
        h.addWindow("com.example.Right", id: "right", pid: 43)
        h.system.windows[0].frame = .init(x: 40, y: 40, width: 300, height: 200)
        h.system.windows[1].frame = .init(x: 650, y: 70, width: 250, height: 250)
        let model = h.model(); defer { model.shutdown() }
        model.hasAccessibilityPermission = true
        let applier = try #require(model.savedLayoutApplier)
        applier.observesKeyboard = false
        let session = SavedLayoutApplySession(applier: applier)
        let editor = SavedLayoutEditor(files: .init(directory: h.directory))
        editor.creation.begin(.init(name: "Shape", mode: .bento, preset: .columns), editor: editor)
        #expect(editor.creation.save(editor: editor))
        let document = try #require(editor.document)
        let page = SavedLayoutSettings(editor: editor, model: model, suppliedSession: session,
            targetOverride: .init(displayID: h.system.mainDisplay.id, spaceID: h.space(1)))
        #expect(page.canApply(document))
        #expect(page.pageStatus(document, states: [:]) == "Ready to apply")
        let result = await applier.apply(document, displayID: h.system.mainDisplay.id)
        #expect(result.issues.isEmpty)
        #expect(result.placed == 2)
        // The 1000 × 800 work area has zero gap: each 50% column is 500 × 800.
        #expect(h.system.windows[0].frame == BTRect(x: 0, y: 0, width: 500, height: 800))
        #expect(h.system.windows[1].frame == BTRect(x: 500, y: 0, width: 500, height: 800))
    }

    @Test func updateSplitPreservesNearestPreferencesAndSettings() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SLV2-3A-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let editor = SavedLayoutEditor(files: .init(directory: root))
        editor.newLayout()
        let old = SavedLayoutDocument(name: "Homework", mode: .bento, layout: .slot("old"),
            slots: [.init(id: "old", prefer: [.group("Reading"), .app("com.apple.Safari")])],
            extraWindows: .addAsPanes, keepForNewWindows: true)
        #expect(editor.edit { $0 = old }); #expect(editor.save())
        // Old centre is (0.5, 0.5). New centres are (0.35, 0.5), (0.85, 0.5).
        let capture = SavedLayoutDocument(name: "Capture", mode: .bento,
            layout: .split(axis: .vertical, ratios: [0.7, 0.3], children: [.slot("left"), .slot("right")]),
            slots: [.init(id: "left", prefer: [.app("com.apple.Preview")]),
                    .init(id: "right", prefer: [.app("com.apple.Notes")])])
        #expect(editor.updateFromCurrentDesktop(capture))
        let result = try #require(editor.document)
        let leaves = SavedLayoutCanvasGeometry.panes(result)
        let left = try #require(leaves.first)
        let id = try #require(SavedLayoutCanvasGeometry.slotIDs(in: left.node, document: result).first)
        #expect(result.slots.first { $0.id == id }?.prefer == old.slots[0].prefer)
        #expect(result.slots.filter { $0.prefer == old.slots[0].prefer }.count == 1)
        #expect(result.slots.contains { $0.prefer == [.app("com.apple.Notes")] })
        #expect(result.keepForNewWindows)
        #expect(result.extraWindows == .addAsPanes)
    }
}

extension SavedLayoutV2EditorTests {
    enum AppRemovalRoute: String, CaseIterable {
        case removeFromLayout, paneClose, palette

        @MainActor func remove(_ id: String, pane: SavedLayoutPane, editor: SavedLayoutEditor) {
            switch self {
            case .removeFromLayout: editor.removeSlot(id) // Settings Remove from Layout action.
            case .paneClose: editor.removeSlot(id) // Canvas × uses this same editor action.
            case .palette: _ = editor.drop(.pane(pane.path), onto: .palette, names: { $0 })
            }
        }
    }

    @Test(arguments: AppRemovalRoute.allCases, [LayoutMode.bento, .tabbed, .manual])
    func removingEveryAppKeepsAnyWindowPanesAndApply(route: AppRemovalRoute, mode: LayoutMode) async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow("com.example.FreeLeft", id: "free-left")
        h.addWindow("com.example.FreeRight", id: "free-right", pid: 43)
        h.system.windows[0].frame = .init(x: 25, y: 40, width: 300, height: 200)
        h.system.windows[1].frame = .init(x: 675, y: 70, width: 250, height: 250)
        let model = h.model(); defer { model.shutdown() }
        model.hasAccessibilityPermission = true
        let applier = try #require(model.savedLayoutApplier)
        applier.observesKeyboard = false
        let editor = SavedLayoutEditor(files: .init(directory: h.directory))
        let slots = [SavedLayoutSlot(id: "left", prefer: [.app("com.example.PreferredLeft")]),
                     SavedLayoutSlot(id: "right", prefer: [.app("com.example.PreferredRight")])]
        let groups: [SavedLayoutGroup] = mode == .tabbed
            ? [.init(id: "lg", slots: ["left"], selected: "left"), .init(id: "rg", slots: ["right"], selected: "right")] : []
        let document = SavedLayoutDocument(name: "Remove apps", mode: mode,
            layout: mode == .manual ? nil : .split(axis: .vertical, ratios: [0.5, 0.5],
                children: mode == .tabbed ? [.group("lg"), .group("rg")] : [.slot("left"), .slot("right")]),
            slots: slots, groups: groups,
            windows: mode == .manual ? [.init(slot: "left", rect: .init(x: 0, y: 0, width: 0.5, height: 1)),
                                       .init(slot: "right", rect: .init(x: 0.5, y: 0, width: 0.5, height: 1))] : [])
        seed(editor, document); editor.resetHistory()
        for (index, slot) in slots.enumerated() {
            let before = try #require(editor.document)
            let pane = mode == .manual
                ? SavedLayoutPane(path: [index], node: .slot(slot.id), rect: document.windows[index].rect)
                : try #require(SavedLayoutCanvasGeometry.panes(before).first { SavedLayoutCanvas.slotIDs(in: $0.node, document: before).contains(slot.id) })
            route.remove(slot.id, pane: pane, editor: editor)
            if mode == .manual, route == .palette {
                // Manual has rectangles, not pane drag controls. Do not invent those routes.
                #expect(editor.document == before)
                return
            }
            let after = try #require(editor.document)
            #expect(after.slots.first { $0.id == slot.id }?.prefer == [])
            #expect(after.layout == document.layout)
            #expect(after.groups == document.groups)
            #expect(after.windows == document.windows)
            editor.undo(); #expect(editor.document == before)
            editor.redo(); #expect(editor.document == after)
        }
        let changed = try #require(editor.document)
        #expect(changed.slots.count == 2)
        #expect(SavedLayoutQuickCapture.subtitle(for: changed) == "Any window")
        #expect(try SavedLayoutValidator.decode(SavedLayoutValidator.encode(changed)) == changed)
        #expect(editor.save())
        let session = SavedLayoutApplySession(applier: applier)
        let page = SavedLayoutSettings(editor: editor, model: model, suppliedSession: session,
            targetOverride: .init(displayID: h.system.mainDisplay.id, spaceID: h.space(1)))
        #expect(page.canApply(changed))
        let result = await applier.apply(changed, displayID: h.system.mainDisplay.id)
        #expect(result.issues.isEmpty)
        #expect(result.placed == 2)
        // Equal columns in 1000 × 800, zero gap. Tabbed reserves its 34-point strip.
        let inset = mode == .tabbed ? 34.0 : 0
        #expect(h.system.windows[0].frame == BTRect(x: 0, y: inset, width: 500, height: 800 - inset))
        #expect(h.system.windows[1].frame == BTRect(x: 500, y: inset, width: 500, height: 800 - inset))
    }

    @Test func removingOneTabbedAppKeepsOtherTabsAndLastSlotBecomesAny() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let editor = SavedLayoutEditor(files: .init(directory: root))
        let document = SavedLayoutDocument(name: "Tabs", mode: .tabbed, layout: .group("g"),
            slots: [.init(id: "a", prefer: [.app("com.example.A")]), .init(id: "b", prefer: [.app("com.example.B")])],
            groups: [.init(id: "g", slots: ["a", "b"], selected: "a")])
        seed(editor, document); editor.resetHistory()
        editor.removeSlot("a")
        let remaining = try #require(editor.document)
        #expect(remaining.slots == [document.slots[1]])
        #expect(remaining.groups == [.init(id: "g", slots: ["b"], selected: "b")])
        editor.removeSlot("b")
        let any = try #require(editor.document)
        #expect(any.layout == .group("g"))
        #expect(any.groups == remaining.groups)
        #expect(any.slots == [.init(id: "b")])
        editor.undo(); #expect(editor.document == remaining)
        editor.undo(); #expect(editor.document == document)
        editor.redo(); #expect(editor.document == remaining)
        editor.redo(); #expect(editor.document == any)
    }

    @Test(arguments: [AppRemovalRoute.palette])
    func removingAllTabbedAppsKeepsTheSelectedSlotAsAny(route: AppRemovalRoute) throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let editor = SavedLayoutEditor(files: .init(directory: root))
        let document = SavedLayoutDocument(name: "Tabs", mode: .tabbed, layout: .group("g"),
            slots: [.init(id: "a", prefer: [.app("com.example.A")]), .init(id: "b", prefer: [.app("com.example.B")])],
            groups: [.init(id: "g", slots: ["a", "b"], selected: "b")])
        seed(editor, document); editor.resetHistory()
        route.remove("b", pane: try #require(SavedLayoutCanvasGeometry.panes(document).first), editor: editor)
        let changed = try #require(editor.document)
        #expect(changed.layout == .group("g"))
        #expect(changed.slots == [.init(id: "b")])
        #expect(changed.groups == [.init(id: "g", slots: ["b"], selected: "b")])
        #expect(SavedLayoutQuickCapture.subtitle(for: changed) == "Any window")
        #expect(try SavedLayoutValidator.decode(SavedLayoutValidator.encode(changed)) == changed)
        editor.undo(); #expect(editor.document == document)
        editor.redo(); #expect(editor.document == changed)
    }

    @Test(arguments: [LayoutMode.bento, .tabbed])
    func movingLastAppOutKeepsAnAnyWindowSourcePane(mode: LayoutMode) throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let editor = SavedLayoutEditor(files: .init(directory: root))
        let document = SavedLayoutDocument(name: "Move", mode: mode,
            layout: mode == .tabbed ? .group("g") : .slot("a"),
            slots: [.init(id: "a", prefer: [.app("com.example.A")])],
            groups: mode == .tabbed ? [.init(id: "g", slots: ["a"], selected: "a")] : [])
        seed(editor, document); editor.resetHistory()
        editor.moveSlot("a", to: nil)
        let moved = try #require(editor.document)
        let source = try #require(SavedLayoutCanvasGeometry.panes(moved).first)
        let id = try #require(SavedLayoutCanvas.slotIDs(in: source.node, document: moved).first)
        #expect(id != "a")
        #expect(moved.slots.first { $0.id == id }?.prefer == [])
        #expect(moved.floats.first?.slot == "a")
        #expect(moved.slots.first { $0.id == "a" } == document.slots.first)
        #expect(try SavedLayoutValidator.decode(SavedLayoutValidator.encode(moved)) == moved)
        editor.undo(); #expect(editor.document == document)
        editor.redo(); #expect(editor.document == moved)
        editor.moveSlot("a", to: source)
        #expect(editor.document == document)
    }

    @Test func oldEmptyPaneStaysUnfilledUntilAPreferenceIsAdded() async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow("com.example.Free", id: "free")
        let model = h.model(); defer { model.shutdown() }
        let applier = try #require(model.savedLayoutApplier); applier.observesKeyboard = false
        let files = SavedLayoutFiles(directory: h.directory)
        let document = SavedLayoutDocument(name: "Old empty", mode: .bento,
            layout: .split(axis: .vertical, ratios: [0.5, 0.5], children: [.empty, .slot("right")]),
            slots: [.init(id: "right")])
        let bytes = try SavedLayoutValidator.encode(document)
        let url = try files.create(bytes)
        let editor = SavedLayoutEditor(files: files); #expect(editor.load(url))
        let empty = try #require(SavedLayoutCanvasGeometry.panes(document).first)
        #expect(empty.node == .empty)
        #expect(SavedLayoutCanvas.slotIDs(in: empty.node, document: document).isEmpty)
        let result = await applier.apply(try #require(editor.document))
        #expect(result.placed == 1)
        #expect(applier.lastPlan?.assignments.keys.sorted() == ["right"])
        #expect(h.system.windows[0].frame == BTRect(x: 500, y: 0, width: 500, height: 800))
        #expect(editor.document == document)
        #expect(try files.read(url) == bytes)
        let slot = try #require(editor.preferenceSlot(in: empty))
        #expect(editor.addPreference(.app("com.example.Free"), to: slot))
        #expect(editor.document?.slots.first { $0.id == slot }?.prefer == [.app("com.example.Free")])
        #expect(editor.document?.layout.map { SavedLayoutCanvas.node(at: [0], in: $0) } == .slot(slot))
        #expect(try files.read(url) == bytes) // Editing is local until Save.
    }

    @Test(arguments: [LayoutMode.bento, .manual])
    func removingAFloatDeletesItsTargetAndLeavesExtraWindowsInPlace(mode: LayoutMode) async throws {
        let h = ApplyHarness(); defer { h.close() }
        h.addWindow("com.example.Main", id: "main")
        h.addWindow("com.example.Extra", id: "extra", pid: 43)
        h.system.windows[1].frame = .init(x: 650, y: 100, width: 250, height: 250)
        let extraFrame = h.system.windows[1].frame
        let model = h.model(); defer { model.shutdown() }
        let applier = try #require(model.savedLayoutApplier); applier.observesKeyboard = false
        let editor = SavedLayoutEditor(files: .init(directory: h.directory))
        let main = SavedLayoutSlot(id: "pane", prefer: [.app("com.example.Main")])
        let document = SavedLayoutDocument(name: "Remove float", mode: mode,
            layout: mode == .manual ? nil : .slot("pane"),
            slots: [main, .init(id: "float", prefer: [.app("com.example.Removed")])],
            windows: mode == .manual ? [.init(slot: "pane", rect: .init(x: 0, y: 0, width: 0.5, height: 1))] : [],
            floats: [.init(slot: "float", rect: .init(x: 0.6, y: 0.6, width: 0.3, height: 0.3))])
        seed(editor, document); editor.resetHistory()
        editor.removeSlot("float")
        let changed = try #require(editor.document)
        #expect(changed.slots == [main])
        #expect(changed.floats.isEmpty)
        #expect(changed.layout == document.layout && changed.windows == document.windows)
        #expect(try SavedLayoutValidator.decode(SavedLayoutValidator.encode(changed)) == changed)
        editor.undo(); #expect(editor.document == document)
        editor.redo(); #expect(editor.document == changed)
        let result = await applier.apply(changed)
        #expect(result.issues.isEmpty && result.placed == 1)
        #expect(h.system.windows[1].frame == extraFrame)
        #expect(h.system.frameWriteCounts[h.system.windows[1].id, default: 0] == 0)
    }

    @Test(arguments: [false, true], [0, 1, 2])
    func assigningToTabbedPaneConsumesOnlyItsSoleAnySlot(drop: Bool, state: Int) throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let editor = SavedLayoutEditor(files: .init(directory: root))
        var document = SavedLayoutDocument(name: "Tabs", mode: .tabbed, layout: .group("g"),
            slots: [.init(id: "a", prefer: state == 1 ? [.app("com.example.First")] : [])],
            groups: [.init(id: "g", slots: ["a"], selected: "a")])
        if state == 2 {
            document.slots.append(.init(id: "b", prefer: [.app("com.example.Second")]))
            document.groups[0].slots.append("b")
        }
        seed(editor, document)
        let pane = try #require(SavedLayoutCanvasGeometry.panes(document).first)
        if drop { #expect(editor.drop(.app(bundleID: "com.example.New"), onto: .pane([]), names: { $0 })) }
        else { editor.assign(bundleID: "com.example.New", pane: pane) }
        let next = try #require(editor.document)
        if state == 0 {
            #expect(next.slots == [.init(id: "a", prefer: [.app("com.example.New")])])
            #expect(next.groups == document.groups)
        } else {
            #expect(Array(next.slots.prefix(document.slots.count)) == document.slots)
            #expect(next.slots.count == document.slots.count + 1)
            #expect(next.groups[0].slots.count == document.groups[0].slots.count + 1)
        }
        #expect(SavedLayoutValidator.validate(next).isEmpty)
    }

    @Test func oldEmptyRegionsLoadWithoutMigration() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let files = SavedLayoutFiles(directory: root)
        let document = SavedLayoutDocument(name: "Old shape", mode: .bento,
            layout: .split(axis: .vertical, ratios: [0.5, 0.5], children: [.empty, .empty]))
        let bytes = try SavedLayoutValidator.encode(document)
        let url = try files.create(bytes)
        let editor = SavedLayoutEditor(files: files)
        #expect(editor.load(url))
        #expect(editor.document == document)
        #expect(editor.document?.slots.isEmpty == true)
        #expect(try files.read(url) == bytes)
        #expect(!editor.isDirty)
    }

    @Test(arguments: [LayoutMode.bento, .tabbed])
    func splitLimitsCountAnyWindowPanesAndRemoveKeepsRemainingSlots(mode: LayoutMode) throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let editor = SavedLayoutEditor(files: .init(directory: root))
        editor.newLayout(mode: mode)
        let limit = mode == .bento ? 6 : 12
        for _ in 1..<limit {
            let document = try #require(editor.document)
            let largest = try #require(SavedLayoutCanvasGeometry.panes(document).max { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height })
            editor.split(largest, axis: largest.rect.width * 1200 >= largest.rect.height * 750 ? .vertical : .horizontal)
        }
        let full = try #require(editor.document)
        #expect(full.slots.count == limit)
        #expect(Set(full.slots.map(\.id)).count == limit)
        let first = try #require(SavedLayoutCanvasGeometry.panes(full).first)
        editor.split(first, axis: .horizontal)
        #expect(editor.document == full)
        editor.removePane(first)
        #expect(editor.document?.slots.count == limit - 1)
        #expect(try SavedLayoutValidator.decode(SavedLayoutValidator.encode(#require(editor.document))) == editor.document)
    }
}

extension SavedLayoutV2EditorTests {
    private func root() -> URL { FileManager.default.temporaryDirectory.appending(path: "SLV2-3A-" + UUID().uuidString) }
    private func layout(_ preferences: [AppPreference] = [.group("Reading"), .app("com.apple.Safari")]) -> SavedLayoutDocument {
        .init(name: "Homework", mode: .bento, layout: .slot("a"), slots: [.init(id: "a", prefer: preferences)])
    }
    private func seed(_ editor: SavedLayoutEditor, _ value: SavedLayoutDocument) {
        editor.newLayout(); #expect(editor.edit { $0 = value })
    }

    @Test func preferencesAddRemoveReorderAndUndoAsLists() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let editor = SavedLayoutEditor(files: .init(directory: root))
        seed(editor, layout())
        #expect(editor.addPreference(.app("com.apple.Notes"), to: "a"))
        #expect(editor.movePreference(in: "a", from: 2, to: 0))
        #expect(editor.document?.slots[0].prefer == [.app("com.apple.Notes"), .group("Reading"), .app("com.apple.Safari")])
        #expect(editor.removePreference(at: 1, from: "a"))
        #expect(editor.document?.slots[0].prefer == [.app("com.apple.Notes"), .app("com.apple.Safari")])
        editor.undo()
        #expect(editor.document?.slots[0].prefer == [.app("com.apple.Notes"), .group("Reading"), .app("com.apple.Safari")])
        let before = editor.document
        _ = editor.movePreference(in: "a", from: -1, to: 1)
        #expect(editor.document == before)
        _ = editor.addPreference(.app("com.apple.Notes"), to: "a")
        #expect(editor.document == before)
        for _ in 0..<3 { _ = editor.removePreference(at: 0, from: "a") }
        #expect(editor.document?.slots[0].prefer == [])
        #expect(editor.draft.issues.isEmpty)
    }

    @Test func emptyPaneGetsAnEditableAnyWindowSlot() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let editor = SavedLayoutEditor(files: .init(directory: root))
        editor.newLayout(mode: .tabbed)
        let pane = try #require(editor.document.flatMap { SavedLayoutCanvasGeometry.panes($0).first })
        let id = try #require(editor.preferenceSlot(in: pane))
        #expect(editor.document?.slots.first?.prefer == [])
        #expect(editor.addPreference(.group("Reading"), to: id))
        #expect(editor.document?.groups.first?.slots == [id])
    }

    private func pane(_ id: String, _ x: Double, _ width: Double = 0.2) -> SavedLayoutUpdatePane {
        .init(id: id, rect: .init(x: x, y: 0.1, width: width, height: 0.8), slots: [], selected: nil)
    }

    @Test func mappingUsesCentreDistanceOnceAndLexicalTies() throws {
        // Old centre .5; new centres .35 and .85. Squared distances .0225 and .1225.
        #expect(try SavedLayoutUpdateMapping.nearestOldPanes(old: [pane("old", 0.4)],
            new: [pane("left", 0, 0.7), pane("right", 0.7, 0.3)]) == ["left": "old"])
        // Equal centres .25 and .75 are .25 away from .5. Lexically first new ID wins.
        #expect(try SavedLayoutUpdateMapping.nearestOldPanes(old: [pane("old", 0.4)],
            new: [pane("b", 0.5, 0.5), pane("a", 0, 0.5)]) == ["a": "old"])
        // Merge: .65 is .4 from left centre .25, .1 from right centre .75.
        #expect(try SavedLayoutUpdateMapping.nearestOldPanes(old: [pane("left", 0, 0.5), pane("right", 0.5, 0.5)],
            new: [pane("merged", 0.55)]) == ["merged": "right"])
        let mapping = try SavedLayoutUpdateMapping.nearestOldPanes(old: [pane("left", 0, 0.2), pane("right", 0.8, 0.2)],
            new: [pane("a", 0, 0.2), pane("b", 0.3, 0.2), pane("c", 0.8, 0.2)])
        #expect(mapping == ["a": "left", "c": "right"])
        #expect(Set(mapping.values).count == 2)
    }

    @Test func tabbedUpdateKeepsEveryListInTheMatchedPaneAndSelection() throws {
        let original = SavedLayoutDocument(name: "Tabs", mode: .tabbed, layout: .group("old"),
            slots: [.init(id: "a", prefer: [.group("Reading"), .app("com.apple.Notes")]),
                    .init(id: "b", prefer: [.app("com.apple.Safari"), .group("Browser")])],
            groups: [.init(id: "old", slots: ["a", "b"], selected: "b")], keepForNewWindows: true)
        let capture = SavedLayoutDocument(name: "Capture", mode: .tabbed,
            layout: .split(axis: .vertical, ratios: [0.7, 0.3], children: [.group("left"), .group("right")]),
            slots: [.init(id: "c", prefer: [.app("com.apple.Preview")]), .init(id: "d", prefer: [.app("com.apple.mail")])],
            groups: [.init(id: "left", slots: ["c"], selected: "c"), .init(id: "right", slots: ["d"], selected: "d")])
        let result = try SavedLayoutUpdateMapping.updating(original, from: capture)
        #expect(result.groups[0].slots == ["a", "b"])
        #expect(result.groups[0].selected == "b")
        #expect(Array(result.slots.prefix(2)) == original.slots)
        #expect(result.slots.last?.prefer == [.app("com.apple.mail")])
        #expect(result.keepForNewWindows)
    }

    @Test func manualUpdateAndMergeUseIndependentRectangleCentres() throws {
        let original = SavedLayoutDocument(name: "Manual", mode: .manual,
            slots: [.init(id: "left", prefer: [.group("Reading")]), .init(id: "right", prefer: [.app("com.apple.Safari")])],
            windows: [.init(slot: "left", rect: .init(x: 0, y: 0, width: 0.5, height: 1)),
                      .init(slot: "right", rect: .init(x: 0.5, y: 0, width: 0.5, height: 1))], keepForNewWindows: true)
        // New rectangle centre .65 is .1 from old right .75, .4 from old left .25.
        let rect = NormalizedRect(x: 0.55, y: 0.1, width: 0.2, height: 0.8)
        let capture = SavedLayoutDocument(name: "Capture", mode: .manual,
            slots: [.init(id: "new", prefer: [.app("com.apple.Notes")])], windows: [.init(slot: "new", rect: rect)])
        let result = try SavedLayoutUpdateMapping.updating(original, from: capture)
        #expect(result.slots == [original.slots[1]])
        #expect(result.windows == [.init(slot: "right", rect: rect)])
        #expect(result.keepForNewWindows)
        #expect(result.extraWindows == original.extraWindows)
    }

    @Test func plainExportIsByteIdenticalAndGroupExportHasOnlyUsedGroups() throws {
        let original = layout()
        let groups = AppGroupsDocument(groups: [.init(name: "Reading", apps: [.init(name: "Preview", bundleID: "com.apple.Preview")]),
            .init(name: "Unused", apps: [.init(name: "Notes", bundleID: "com.apple.Notes")])])
        #expect(try SavedLayoutTransfer.encode(original, groups: .init()) == SavedLayoutValidator.encode(original))
        let bytes = try SavedLayoutTransfer.encode(original, groups: groups)
        let decoded = try SavedLayoutTransfer.decode(bytes)
        #expect(decoded.document == original)
        #expect(decoded.appGroups == [groups.groups[0]])
        #expect(throws: SavedLayoutValidationError.self) { try SavedLayoutValidator.decode(bytes) }
    }

    private func store(_ root: URL) async -> AppGroupsStore {
        let store = AppGroupsStore(directory: root, catalog: { [] }, defaultBrowserURL: { nil })
        await store.load()
        return store
    }

    @Test func importAddStartsSelectedAndLibraryOmitsGroups() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = await store(root)
        let editor = SavedLayoutEditor(files: store.layouts)
        let source = root.appending(path: "export.json")
        let group = AppGroup(name: "Reading", apps: [.init(name: "Preview", bundleID: "com.apple.Preview")])
        let exported = try SavedLayoutTransfer.encode(layout(), groups: .init(groups: [group]))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try exported.write(to: source)
        #expect(!editor.beginImport(source, groups: store))
        #expect(editor.pendingImport?.choices == ["Reading": .add])
        #expect(editor.completeImport(groups: store))
        #expect(store.document.groups == [group])
        #expect(editor.save())
        let library = try editor.files.read(#require(editor.url))
        #expect(!String(decoding: library, as: UTF8.self).contains("appGroups"))
        #expect(try SavedLayoutValidator.decode(library).slots[0].prefer == layout().slots[0].prefer)
        #expect(try Data(contentsOf: source) == exported)
    }

    @Test func importMapsThroughStoreAndRefusesChangedOrInvalidGroupFiles() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = await store(root)
        try store.save(.init(groups: [.init(name: "Web", apps: [.init(name: "Safari", bundleID: "com.apple.Safari")])]))
        let editor = SavedLayoutEditor(files: store.layouts)
        seed(editor, layout([.app("com.apple.Notes")]))
        #expect(editor.save())
        let url = try #require(editor.url), baseline = try editor.files.read(url), original = editor.document
        let source = root.appending(path: "export.json")
        try SavedLayoutTransfer.encode(layout(), groups: .init(groups: [.init(name: "Reading", apps: [])])).write(to: source)
        #expect(!editor.beginImport(source, groups: store))
        editor.pendingImport?.choices["Reading"] = .existing("Web")
        #expect(editor.completeImport(groups: store))
        #expect(editor.document?.slots[0].prefer == [.group("Web"), .app("com.apple.Safari")])
        #expect(try editor.files.read(url) == baseline)
        #expect(store.document.groups.map(\.name) == ["Web"])
        #expect(editor.discardChanges())
        #expect(editor.load(url))
        #expect(editor.document == original)
        #expect(!editor.beginImport(source, groups: store))
        try Data("invalid groups".utf8).write(to: store.fileURL)
        #expect(!editor.completeImport(groups: store))
        #expect(editor.document == original)
        #expect(editor.url == url)
        #expect(try editor.files.read(url) == baseline)
        #expect(editor.pendingImport != nil)
        #expect(store.document.groups.map(\.name) == ["Web"])
        await store.reload()
        #expect(!editor.completeImport(groups: store))
        #expect(editor.document == original)
    }

    @Test func reloadDiscardAndSaveKeepBaselineAndFileActionsAreInjected() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let editor = SavedLayoutEditor(files: .init(directory: root))
        seed(editor, layout()); #expect(editor.save())
        let url = try #require(editor.url)
        var edited: [URL] = [], revealed: [URL] = []
        editor.fileOpener = .init(edit: { edited.append($0) }, reveal: { revealed.append($0) })
        editor.editInTextEditor(); editor.revealInFinder()
        #expect(edited == [url]); #expect(revealed == [url])
        #expect(editor.edit { $0.name = "Unsaved" }); #expect(editor.hasUnsavedChanges)
        var rewritten = layout([.group("Renamed")]); rewritten.name = "Changed on disk"
        let bytes = try SavedLayoutValidator.encode(rewritten); try bytes.write(to: url)
        #expect(!editor.save()); #expect(editor.hasUnsavedChanges)
        #expect(try editor.files.read(url) == bytes)
        #expect(editor.reloadFromDisk()); #expect(!editor.hasUnsavedChanges)
        #expect(editor.document == rewritten); #expect(editor.baseline == bytes)
        #expect(editor.edit { $0.name = "Again" }); #expect(editor.discardChanges())
        #expect(editor.document == rewritten); #expect(!editor.hasUnsavedChanges)
        #expect(editor.edit { $0.name = "Saved after reload" }); #expect(editor.save())
    }
}

extension SavedLayoutV2EditorTests {
    @Test func tabbedToAdaptiveCombinesPreferencesWithoutInventingFloats() throws {
        let original = SavedLayoutDocument(name: "Tabs", mode: .tabbed, layout: .group("tabs"),
            slots: [.init(id: "a", prefer: [.app("com.apple.Safari")]),
                    .init(id: "b", prefer: [.app("com.apple.iWork.Pages"), .app("com.apple.Safari")])],
            groups: [.init(id: "tabs", slots: ["a", "b"], selected: "a")])
        let capture = SavedLayoutDocument(name: "Capture", mode: .bento, layout: .slot("new"),
            slots: [.init(id: "new", prefer: [.app("com.apple.Notes")])])
        let result = try SavedLayoutUpdateMapping.updating(original, from: capture)
        #expect(result.slots == [.init(id: "a", prefer: [.app("com.apple.Safari"), .app("com.apple.iWork.Pages")])])
        #expect(result.floats.isEmpty)
        let preferences: [AppPreference] = (0..<20).map { .app("org.example.app\($0)") }
        #expect(SavedLayoutUpdateMapping.combinedPreferences(preferences + preferences).count == 16)
    }

    @Test func transferAndCoreAgreeOnCommentsInsideStringsAndAtEOF() throws {
        var document = layout([.app("com.apple.Safari")]); document.name = "https://x"
        let bytes = try SavedLayoutValidator.encode(document) + Data("\n// last".utf8)
        #expect(try SavedLayoutTransfer.decode(bytes).document == SavedLayoutValidator.decode(bytes))
        let groups = AppGroupsDocument(groups: [.init(name: "Reading", apps: [.init(name: "https://x", bundleID: "com.apple.Preview")])])
        let exported = try SavedLayoutTransfer.encode(layout(), groups: groups) + Data("\n// last".utf8)
        let decoded = try SavedLayoutTransfer.decode(exported)
        #expect(decoded.document == layout())
        #expect(decoded.appGroups == groups.groups)
        #expect(String(decoding: exported, as: UTF8.self).contains("https://x"))
        #expect(!String(decoding: exported, as: UTF8.self).contains(#"https:\/\/x"#))
    }
}


extension SavedLayoutV2EditorTests {
    @Test func updateTurnsOffAdaptiveOnlyOptionWithAnExplanationWhenModeChanges() throws {
        var original = layout(); original.keepForNewWindows = true; original.extraWindows = .addAsPanes
        let capture = SavedLayoutDocument(name: "Capture", mode: .manual,
            slots: [.init(id: "new", prefer: [.app("com.apple.Notes")])],
            windows: [.init(slot: "new", rect: .init(x: 0, y: 0, width: 1, height: 1))])
        let manual = try SavedLayoutUpdateMapping.updating(original, from: capture)
        #expect(manual.extraWindows == .float)
        #expect(manual.keepForNewWindows)
        #expect(SavedLayoutUpdateConfirmation.extraWindowsNotice(original: original, capturedMode: .manual)
            == "Add extra windows as panes works only in Adaptive and will be turned off.")
        let adaptive = try SavedLayoutUpdateMapping.updating(original, from: layout([.app("com.apple.Notes")]))
        #expect(adaptive.extraWindows == .addAsPanes && adaptive.keepForNewWindows)
        #expect(SavedLayoutUpdateConfirmation.extraWindowsNotice(original: original, capturedMode: .bento) == nil)
    }
}

extension SavedLayoutV2EditorTests {
    @Test func exportCannotPutEmbeddedGroupsIntoAnotherLibraryFile() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let editor = SavedLayoutEditor(files: .init(directory: root))
        seed(editor, layout()); #expect(editor.save())
        let destination = root.appending(path: "another-layout.json")
        let bytes = try SavedLayoutValidator.encode(layout([.app("com.apple.Notes")]))
        try bytes.write(to: destination)
        editor.export(to: destination, groups: .init(groups: [.init(name: "Reading", apps: [])]))
        #expect(try Data(contentsOf: destination) == bytes)
        #expect(editor.messageStatus?.kind == .bad)
    }
}
