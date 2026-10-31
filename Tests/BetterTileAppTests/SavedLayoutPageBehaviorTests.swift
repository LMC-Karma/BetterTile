import AppKit
import BetterTileCore
import SwiftUI
import Testing
@testable import BetterTileApp

@Suite(.appTestApplication, .settingsUI) @MainActor struct SavedLayoutPageBehaviorTests {
    @Test func targetWorkAreaMustNotRenderAtTwoPointSixToOne() throws {
        let targetArea = BTRect(x: 1200, y: 30, width: 1600, height: 1000)
        let document = SavedLayoutDocument(name: "Wide target", mode: .bento, layout: .empty)
        let host = NSHostingView(rootView: SavedLayoutPagePreview(document: document, applications: [:], workArea: targetArea).frame(width: 520))
        let size = host.fittingSize
        #expect(abs(size.height - 520 * targetArea.size.height / targetArea.size.width) < 1)
    }
}

extension SavedLayoutPageBehaviorTests {
    @Test func planReadsOnlyOnEventsAndDisconnectedPickKeepsItsOwnWorkArea() throws {
        let f = SavedLayoutDisplayPickerFixture(); defer { f.close() }
        f.refresh(); f.page.pickDisplay(SavedLayoutDisplayPickerFixture.b.id)
        let page = f.page
        var reads = 0
        let applier = try #require(f.model.savedLayoutApplier)
        let original = applier.snapshot
        applier.snapshot = { reads += 1; return try original() }
        page.refreshPagePlan()
        #expect(reads == 1)
        let area = page.pagePlan.workArea
        for _ in 0..<20 { _ = page.body }
        #expect(reads == 1)
        f.live.removeAll { $0.id == SavedLayoutDisplayPickerFixture.b.id }; f.sync(); page.refreshTarget()
        #expect(f.target.unavailableReason != nil)
        #expect(page.pagePlan.workArea == area)
        #expect(page.pagePlan.preview == nil)
        #expect(reads == 1)
        let reopened = f.page
        reopened.refreshPagePlan()
        #expect(reopened.pagePlan.workArea == area)
        #expect(reads == 1)
        #expect(f.system.frameWriteCounts.isEmpty)
    }
    @Test func newCaptureNamesUseDistinctDisplayNamesAndKeepCollisionSuffix() {
        let slots = ["x", "s", "x", "n", "m"].enumerated().map { SavedLayoutSlot(id: "s\($0.offset)", bundleID: $0.element) }
        let doc = SavedLayoutDocument(name: "Old", mode: .manual, slots: slots)
        let names = ["x": "Xcode", "s": "Safari", "n": "Notes", "m": "Mail"]
        #expect(SavedLayoutQuickCapture.name(for: doc, existingNames: [], appNames: names) == "Xcode + Safari + 2 more")
        #expect(SavedLayoutQuickCapture.name(for: doc, existingNames: ["xcode + safari + 2 more"], appNames: names) == "Xcode + Safari + 2 more 2")
        let unknown = SavedLayoutQuickCapture.name(for: doc, existingNames: [])
        #expect(unknown == "This app")
        let long = SavedLayoutQuickCapture.name(for: doc, existingNames: [], appNames: ["x": String(repeating: "Long name ", count: 40)])
        #expect(long.count <= 120)
        #expect(!long.contains("org.example"))
    }
    @Test func sidecarIsBoundedOptionalAndAbsentFromExportAndLayoutEnumeration() throws {
        let f = SavedLayoutDisplayPickerFixture(); defer { f.close() }
        #expect(f.editor.save(as: "Writing"))
        let url = try #require(f.editor.url), store = f.editor.positions
        let frame = NormalizedRect(x: 0.1, y: 0.1, width: 0.4, height: 0.7)
        store.set(["editor": frame], for: url.lastPathComponent)
        #expect(SavedLayoutPositions(files: f.editor.files).frames(for: url.lastPathComponent) == ["editor": frame])
        #expect(try f.editor.files.entries() == [url])
        let exported = f.directory.appending(path: "export.json"); f.editor.export(to: exported)
        #expect(try Data(contentsOf: exported) == f.editor.baseline)
        let data = try Data(contentsOf: store.url)
        let text = try #require(String(data: data, encoding: .utf8))
        for key in ["windowID", "pid", "bundleID", "title", "displayID", "spaceID"] { #expect(!text.contains(key)) }
        try Data("corrupt".utf8).write(to: store.url)
        #expect(store.frames(for: url.lastPathComponent).isEmpty)
        store.set(["editor": frame], for: url.lastPathComponent)
        #expect(try Data(contentsOf: store.url) == Data("corrupt".utf8))
        try Data(repeating: 32, count: SavedLayoutPositions.maximumBytes + 1).write(to: store.url)
        #expect(store.frames(for: url.lastPathComponent).isEmpty)
        try FileManager.default.removeItem(at: store.url)
        store.set(["editor": frame, "gone": frame], for: url.lastPathComponent)
        let original = try #require(f.editor.document)
        #expect(f.editor.updateFromCurrentDesktop(original))
        #expect(store.frames(for: url.lastPathComponent) == ["editor": frame])
        #expect(f.editor.delete())
        #expect(store.frames(for: url.lastPathComponent).isEmpty)
    }
}

extension SavedLayoutPageBehaviorTests {
    @Test func cacheEvictsMissingAndOlderLayoutsInsteadOfStoppingAtItsLimit() throws {
        let f = SavedLayoutDisplayPickerFixture(); defer { f.close() }
        #expect(f.editor.save(as: "Recent"))
        let current = try #require(f.editor.url).lastPathComponent
        let store = f.editor.positions
        let rect = NormalizedRect(x: 0, y: 0, width: 0.5, height: 0.5)
        var layouts: [String: [String: NormalizedRect]] = ["deleted.json": ["editor": rect]]
        for index in 0..<257 {
            let name = "layout-\(index).json"
            let url = f.editor.files.directory.appendingPathComponent(name)
            try f.editor.draft.source.write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index))], ofItemAtPath: url.path)
            layouts[name] = ["editor": rect]
        }
        struct Cache: Encodable { var version = 1; var layouts: [String: [String: NormalizedRect]] }
        try JSONEncoder().encode(Cache(layouts: layouts)).write(to: store.url)
        store.set(["editor": rect], for: current)
        #expect(store.frames(for: current) == ["editor": rect])
        #expect(store.frames(for: "deleted.json").isEmpty)
        #expect(store.frames(for: "layout-0.json").isEmpty)
        #expect(store.frames(for: "layout-1.json").isEmpty)
        #expect(store.frames(for: "layout-256.json") == ["editor": rect])
        let contents = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as? [String: Any])
        #expect((contents["layouts"] as? [String: Any])?.count == 256)
    }
    @Test func updateDropsUnmappedSlotsAndAnOlderRestoreCannotOverwriteNewerHints() throws {
        let f = SavedLayoutDisplayPickerFixture(); defer { f.close() }
        f.editor.newLayout(mode: .manual)
        f.editor.assign(bundleID: "com.apple.Safari", pane: nil)
        f.editor.assign(bundleID: "com.apple.Notes", pane: nil)
        #expect(f.editor.edit { document in
            document.windows[0].rect = .init(x: 0, y: 0, width: 0.5, height: 1)
            document.windows[1].rect = .init(x: 0.5, y: 0, width: 0.5, height: 1)
        })
        #expect(f.editor.save(as: "Two apps"))
        let file = try #require(f.editor.url).lastPathComponent
        let before = try #require(f.editor.document)
        let first = before.slots[0].id, second = before.slots[1].id
        let store = f.editor.positions
        let rect = NormalizedRect(x: 0, y: 0, width: 0.5, height: 0.5)
        store.set([first: rect, second: rect], for: file)
        var replacement = before
        replacement.slots.removeLast(); replacement.windows.removeAll { $0.slot == second }
        #expect(f.editor.updateFromCurrentDesktop(replacement))
        #expect(store.frames(for: file) == [first: rect])
        let newer = [first: NormalizedRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)]
        store.set(newer, for: file)
        store.restore([:], for: file, ifCurrent: [first: rect])
        #expect(store.frames(for: file) == newer)
        #expect(f.editor.delete())
        #expect(store.frames(for: file).isEmpty)
    }
}


extension SavedLayoutPageBehaviorTests {
    @Test func pageKeepsOneSectionAndRealBridgeSavesRenamesAndReloadsLibrary() async throws {
        let f = SavedLayoutDisplayPickerFixture(); defer { f.close() }
        let store = f.model.appGroupsStore
        await store.load()
        try store.save(.init(groups: [.init(name: "Old", apps: [])]))
        let editor = SavedLayoutEditor(files: store.layouts)
        editor.newLayout()
        #expect(editor.edit { $0 = .init(name: "Work", mode: .bento, layout: .slot("a"),
            slots: [.init(id: "a", prefer: [.group("Old")])]) })
        #expect(editor.save())
        let other = try store.layouts.create(SavedLayoutValidator.encode(.init(name: "Other", mode: .bento,
            layout: .slot("b"), slots: [.init(id: "b", prefer: [.group("Old")])])))
        editor.refreshLibrary()
        let page = SavedLayoutSettings(editor: editor, model: f.model, suppliedSession: f.session)
        page.initializePage()
        let section = try #require(page.groupsIntegration.section)
        #expect(section.store === store)
        #expect(editor.edit { $0.name = "Edited" })
        section.requestRename("New")
        #expect(section.pendingRename == "New")
        page.initializePage(); page.refreshPagePlan()
        #expect(page.groupsIntegration.section === section)
        #expect(section.selectedName == "Old" && section.pendingRename == "New")
        let revision = try #require(f.model.savedLayoutApplier).planRevision
        section.resolvePendingRename(saveChanges: true)
        #expect(section.pendingRename == nil && section.message == nil)
        #expect(editor.document?.name == "Edited")
        #expect(editor.document?.slots[0].prefer == [.group("New")])
        #expect(!editor.hasUnsavedChanges)
        #expect(editor.entryDocuments[other]?.slots[0].prefer == [.group("New")])
        #expect(f.model.savedLayoutApplier!.planRevision > revision)
        let before = try Data(contentsOf: store.fileURL)
        #expect(editor.edit { $0.name = "Unsaved change" })
        try Data("external edit".utf8).write(to: #require(editor.url))
        section.requestRename("Stopped")
        #expect(section.pendingRename == "Stopped")
        section.resolvePendingRename(saveChanges: true)
        #expect(section.message != nil)
        #expect(try Data(contentsOf: store.fileURL) == before)
        #expect(store.document.groups[0].name == "New")
    }

    @Test(arguments: [false, true]) func pageImportRefreshesSectionAndPlanRevision(map: Bool) async throws {
        let f = SavedLayoutDisplayPickerFixture(); defer { f.close() }
        let store = f.model.appGroupsStore
        await store.load()
        try store.save(.init(groups: [.init(name: "Existing", apps: [])]))
        let page = f.page; page.initializePage()
        let section = try #require(page.groupsIntegration.section)
        let doc = SavedLayoutDocument(name: "Imported", mode: .bento, layout: .slot("a"),
            slots: [.init(id: "a", prefer: [.group("Imported")])])
        let source = f.directory.appending(path: "import.json")
        try SavedLayoutTransfer.encode(doc, groups: .init(groups: [.init(name: "Imported", apps: [])])).write(to: source)
        #expect(!f.editor.beginImport(source, groups: store))
        if map { f.editor.pendingImport?.choices["Imported"] = .existing("Existing") }
        let revision = try #require(f.model.savedLayoutApplier).planRevision
        let sectionRevision = section.revision
        #expect(page.completeImport())
        #expect(f.model.savedLayoutApplier!.planRevision > revision)
        #expect(section.revision > sectionRevision)
        #expect(page.groupsIntegration.section === section)
        #expect(section.store.document.groups.map(\.name) == (map ? ["Existing"] : ["Existing", "Imported"]))
        #expect(f.editor.document?.slots[0].prefer == [.group(map ? "Existing" : "Imported")])
    }

    @Test func plainTextEditorUsesDefaultThenFallbackAndHandlesNeither() {
        let file = URL(filePath: "/tmp/Layout.json")
        let preferred = URL(filePath: "/Applications/Editor.app"), fallback = URL(filePath: "/Applications/TextEdit.app")
        var opened: [(URL, URL)] = []; var fallbackReads = 0
        var helper = PlainTextFileEditor(preferredApplication: { preferred }, fallbackApplication: {
            fallbackReads += 1; return fallback
        }, open: { opened.append(($0, $1)) })
        helper.edit(file)
        #expect(opened.count == 1 && opened[0].0 == file && opened[0].1 == preferred)
        #expect(fallbackReads == 0)
        helper.preferredApplication = { nil }; helper.edit(file)
        #expect(opened.count == 2 && opened[1].1 == fallback && fallbackReads == 1)
        helper.fallbackApplication = { nil }; helper.edit(file)
        #expect(opened.count == 2)
    }
}


extension SavedLayoutPageBehaviorTests {
    @Test func groupChangeReplansHostedPageThroughRevisionObserver() async throws {
        let f = SavedLayoutDisplayPickerFixture(); defer { f.close() }
        let store = f.model.appGroupsStore
        await store.load()
        try store.save(.init(groups: [.init(name: "Browser", apps: [.init(bundleID: "com.apple.Safari")])]))
        let display = SavedLayoutDisplayPickerFixture.a.id
        f.system.windows = [.init(id: .init(rawValue: "safari"), processIdentifier: 42,
            bundleIdentifier: "com.apple.Safari", frame: .init(x: 50, y: 50, width: 300, height: 300), displayID: display)]
        f.system.windows.append(.init(id: .init(rawValue: "notes"), processIdentifier: 43,
            bundleIdentifier: "com.apple.Notes", frame: .init(x: 400, y: 50, width: 300, height: 300), displayID: display))
        f.system.desktopObservation?.windowMembership[.init(rawValue: "safari")] = [.init(rawValue: 1)]
        f.system.desktopObservation?.windowMembership[.init(rawValue: "notes")] = [.init(rawValue: 1)]
        let applier = try #require(f.model.savedLayoutApplier)
        let installed = SavedLayoutPageSnapshotTests.installed
        applier.application = { id in installed.first { $0.id == id } }
        #expect(f.editor.edit { $0.slots[0].prefer = [.group("Browser")] })
        #expect(f.editor.save())
        let page = f.page
        page.initializePage(); page.refreshTarget()
        let host = NSHostingView(rootView: page.frame(width: 860, height: 1500))
        host.frame.size = .init(width: 860, height: 1500)
        let window = OffscreenTestWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        try await waitForSavedLayoutSnapshot(in: host) {
            page.groupsIntegration.section != nil && page.pagePlan.preview?.rows.first?.appName == "Safari"
        }
        let initial = try #require(page.pagePlan.preview?.rows.first)
        #expect(initial.outcome(screenName: { _ in "Display" }) == "Uses its open window")
        let section = try #require(page.groupsIntegration.section)
        let revision = applier.planRevision
        section.updateApps { $0 = [.init(bundleID: "com.apple.Notes")] }
        try await waitForSavedLayoutSnapshot(in: host) {
            applier.planRevision > revision && page.pagePlan.preview?.rows.first?.appName == "Notes"
        }
        #expect(applier.planRevision > revision)
        let updated = try #require(page.pagePlan.preview?.rows.first)
        #expect(initial.appName == "Safari")
        #expect(updated.appName == "Notes")
        #expect(f.system.frameWriteCounts.isEmpty)
    }
}


extension SavedLayoutPageBehaviorTests {
    @Test func sectionCountsThePageLibraryBeforeAndAfterRename() async throws {
        let f = SavedLayoutDisplayPickerFixture(); defer { f.close() }
        let store = f.model.appGroupsStore
        await store.load()
        try store.save(.init(groups: [.init(name: "Browser", apps: [])]))
        #expect(f.editor.edit { $0.slots[0].prefer = [.group("Browser")] })
        #expect(f.editor.save())
        let page = f.page; page.initializePage()
        let section = try #require(page.groupsIntegration.section)
        #expect(f.editor.files.directory == f.model.savedLayoutActions.files.directory)
        #expect(f.editor.files.directory == store.layouts.directory)
        #expect(section.layoutCount(for: "Browser") == 1)
        section.requestRename("Web")
        #expect(section.layoutCount(for: "Browser") == 0)
        #expect(section.layoutCount(for: "Web") == 1)
        #expect(f.editor.document?.slots[0].prefer == [.group("Web")])
    }
}
