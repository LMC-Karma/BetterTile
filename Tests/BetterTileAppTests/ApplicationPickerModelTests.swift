import Foundation
import Testing
@testable import BetterTileApp

private func choice(_ id: String, _ name: String, _ path: String? = nil) -> ApplicationChoice {
    ApplicationChoice(bundleIdentifier: id, name: name, url: URL(filePath: path ?? "/Applications/\(name).app"))
}

private let home = URL(filePath: "/Users/fixture")

private func layout(_ sections: [ApplicationPickerModel.Section]) -> [String] {
    sections.map { "\($0.kind.rawValue): " + $0.rows.map(\.application.id).joined(separator: ",") }
}

@Test(.appTestApplication) func pickerSectionsListRecentThenRunningThenAllApps() {
    let notes = choice("test.notes", "Notes")
    let safari = choice("test.safari", "Safari")
    let xcode = choice("test.xcode", "Xcode")
    let mail = choice("test.mail", "Mail")
    let sections = ApplicationPickerModel.sections(installed: [xcode, notes, safari], running: [safari, mail],
                                                   recent: [xcode, safari], home: home)
    #expect(layout(sections) == [
        "Recent: test.xcode,test.safari",
        "Running: test.mail,test.safari",
        "All Apps: test.mail,test.notes,test.safari,test.xcode",
    ])
    // Rows of one app in several sections keep distinct identities for the keyboard highlight.
    #expect(Set(sections.flatMap(\.rows).map(\.id)).count == 8)
}

@Test(.appTestApplication) func pickerSectionsOmitEmptyRecentButKeepEmptyRunning() {
    let notes = choice("test.notes", "Notes")
    let sections = ApplicationPickerModel.sections(installed: [notes], running: [], home: home)
    #expect(layout(sections) == ["Running: ", "All Apps: test.notes"])
}

@Test(.appTestApplication) func pickerSectionsApplyExclusionsAndDropBlankIdentifiers() {
    let own = choice("test.own", "BetterTile")
    let blank = choice("  ", "Blank")
    let notes = choice("test.notes", "Notes")
    let sections = ApplicationPickerModel.sections(installed: [own, blank, notes], running: [own],
                                                   recent: [own, notes], excluding: ["test.own"], home: home)
    #expect(layout(sections) == ["Recent: test.notes", "Running: ", "All Apps: test.notes"])
}

@Test(.appTestApplication) func pickerSearchShowsOneResultsSectionMatchedByNameOnly() {
    let editor = choice("test.editor", "Résumé Editor", "/Elsewhere/Editor.app")
    let installed = [choice("test.notes", "Notes"), choice("test.editor", "Editor"), choice("com.example.hidden", "Calculator")]
    let results = ApplicationPickerModel.sections(installed: installed, running: [editor], recent: [editor],
                                                  search: "  resume  ", home: home)
    #expect(layout(results) == ["Results: test.editor"])
    // The first listed copy wins, so the running app's URL is kept.
    #expect(results[0].rows[0].application.url == editor.url)
    #expect(ApplicationPickerModel.sections(installed: installed, running: [], search: "com.example",
                                            home: home)[0].rows.isEmpty)
    #expect(layout(ApplicationPickerModel.sections(installed: installed, running: [], search: "o",
                                                   home: home)) == ["Results: com.example.hidden,test.editor,test.notes"])
    #expect(ApplicationPickerModel.sections(installed: installed, running: [], search: "zzq", home: home)[0].rows.isEmpty)
}

@Test(.appTestApplication) func pickerCaptionsOnlyDuplicateNamesWithTheirFolder() {
    let system = choice("test.editor.system", "Editor", "/Applications/Editor.app")
    let user = choice("test.editor.user", "editor", "/Users/fixture/Applications/Editor.app")
    let notes = choice("test.notes", "Notes")
    let sections = ApplicationPickerModel.sections(installed: [system, user, notes], running: [], home: home)
    let captions = Dictionary(uniqueKeysWithValues: sections.flatMap(\.rows).map { ($0.application.id, $0.caption) })
    #expect(captions["test.editor.system"] == "/Applications")
    #expect(captions["test.editor.user"] == "~/Applications")
    #expect(captions["test.notes"] == .some(nil))
    // The same app in two sections is not a duplicate of itself.
    let single = ApplicationPickerModel.sections(installed: [notes], running: [notes], recent: [notes], home: home)
    #expect(single.flatMap(\.rows).allSatisfy { $0.caption == nil })
}

@Test(.appTestApplication) func pickerFolderCaptionAbbreviatesHomeOnly() {
    #expect(ApplicationPickerModel.folderCaption(for: URL(filePath: "/Users/fixture/Applications/A.app"), home: home) == "~/Applications")
    #expect(ApplicationPickerModel.folderCaption(for: URL(filePath: "/Users/fixture/A.app"), home: home) == "~")
    #expect(ApplicationPickerModel.folderCaption(for: URL(filePath: "/Users/fixture2/A.app"), home: home) == "/Users/fixture2")
    #expect(ApplicationPickerModel.folderCaption(for: URL(filePath: "/System/Applications/Utilities/Terminal.app"), home: home)
        == "/System/Applications/Utilities")
}

@Test(.appTestApplication) func pickerFolderCaptionUsesFinderNamesWithoutLocalizedSuffix() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appending(path: "home")
    let web = home.appending(path: "Applications/Chrome Apps.localized")
    try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
    #expect(ApplicationPickerModel.folderCaption(for: web.appending(path: "YouTube.app"), home: home) == "~/Applications/Chrome Apps")
    let elsewhere = root.appending(path: "Vendor Apps.localized")
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    let caption = ApplicationPickerModel.folderCaption(for: elsewhere.appending(path: "Tool.app"), home: home)
    #expect(caption.hasSuffix("/Vendor Apps"))
    #expect(!caption.contains(".localized"))
}

@Test(.appTestApplication) func pickerAnnouncementNamesTheRowCaptionAndSection() {
    let editor = choice("test.editor", "Editor", "/Applications/Editor.app")
    let copy = choice("test.editor.copy", "Editor", "/Users/fixture/Applications/Editor.app")
    let rows = ApplicationPickerModel.sections(installed: [editor, copy], running: [], recent: [editor], home: home)
        .flatMap(\.rows)
    #expect(rows.map(ApplicationPickerModel.announcement(for:)) == [
        "Editor, /Applications, Recent", "Editor, /Applications, All Apps", "Editor, ~/Applications, All Apps",
    ])
}

@Test(.appTestApplication) func pickerRecentChoicesResolveKnownAppsFirstAndDropMissingOnes() {
    let notes = choice("test.notes", "Notes")
    var lookups: [String] = []
    let resolved = ApplicationPickerModel.recentChoices(["test.notes", "test.gone", "test.elsewhere"], known: [notes]) {
        lookups.append($0)
        return $0 == "test.elsewhere" ? choice("test.elsewhere", "Elsewhere", "/Volumes/Apps/Elsewhere.app") : nil
    }
    #expect(resolved.map(\.id) == ["test.notes", "test.elsewhere"])
    #expect(lookups == ["test.gone", "test.elsewhere"])
}

@Test(.appTestApplication) func pickerKeyboardMovesAndClampsHighlight() {
    let sections = ApplicationPickerModel.sections(installed: [choice("a", "A"), choice("b", "B")], running: [],
                                                   recent: [choice("b", "B")], home: home)
    let rows = sections.flatMap(\.rows)
    #expect(rows.map(\.id) == ["Recent:b", "All Apps:a", "All Apps:b"])
    #expect(ApplicationPickerModel.move(nil, by: 1, in: rows) == "Recent:b")
    #expect(ApplicationPickerModel.move(nil, by: -1, in: rows) == nil)
    #expect(ApplicationPickerModel.move("Recent:b", by: 1, in: rows) == "All Apps:a")
    #expect(ApplicationPickerModel.move("All Apps:b", by: 1, in: rows) == "All Apps:b")
    #expect(ApplicationPickerModel.move("Recent:b", by: -1, in: rows) == "Recent:b")
    #expect(ApplicationPickerModel.move("Missing:x", by: 1, in: rows) == "Recent:b")
    #expect(ApplicationPickerModel.move("Recent:b", by: 1, in: []) == nil)
}

@Test(.appTestApplication) func pickerHighlightKeepsListedRowAndStartsSearchAtFirstResult() {
    let rows = ApplicationPickerModel.sections(installed: [choice("a", "A"), choice("b", "B")], running: [],
                                               search: "", home: home).flatMap(\.rows)
    #expect(ApplicationPickerModel.highlight("All Apps:b", in: rows, searching: false) == "All Apps:b")
    #expect(ApplicationPickerModel.highlight(nil, in: rows, searching: false) == nil)
    #expect(ApplicationPickerModel.highlight("Gone:x", in: rows, searching: false) == nil)
    #expect(ApplicationPickerModel.highlight("Gone:x", in: rows, searching: true) == "All Apps:a")
    #expect(ApplicationPickerModel.highlight(nil, in: [], searching: true) == nil)
}

@Test(.appTestApplication) func pickerRejectsMissingIdentifiersAndExcludedBrowseChoices() {
    #expect(ApplicationPickerModel.validationMessage(for: nil, excluding: []) != nil)
    #expect(ApplicationPickerModel.validationMessage(for: choice("  ", "Invalid"), excluding: []) != nil)
    #expect(ApplicationPickerModel.validationMessage(for: choice("test.editor", "Editor"), excluding: ["test.editor"]) != nil)
    #expect(ApplicationPickerModel.validationMessage(for: choice("test.editor", "Editor"), excluding: []) == nil)
}

@Test(.appTestApplication) func pickerSectionsUsePrecomputedCaptionsInsteadOfReadingDisk() {
    let system = choice("test.editor.system", "Editor", "/Applications/Editor.app")
    let user = choice("test.editor.user", "Editor", "/Users/fixture/Applications/Editor.app")
    let computed = ApplicationPickerModel.folderCaptions(for: [system, user], home: home)
    #expect(computed == ["test.editor.system": "/Applications", "test.editor.user": "~/Applications"])
    let given = ApplicationPickerModel.sections(installed: [system, user], running: [], captions: ["test.editor.user": "Given"],
                                                home: home).flatMap(\.rows)
    #expect(given.map(\.caption) == [nil, "Given"])
}

@Test(.appTestApplication) func pickerWindowRowsAreOptInAndKeepSectionIdentities() throws {
    let app = choice("safari", "Safari")
    let sections = ApplicationPickerModel.sections(installed: [app], running: [app], recent: [app])
    let plain = ApplicationPickerModel.windowSections(sections, expansion: .init(), windows: nil)
    #expect(plain == sections)
    let windows = (1...7).map { ApplicationPickerWindow(id: "w\($0)", title: "Window \($0)") }
    let collapsed = ApplicationPickerModel.windowSections(sections, expansion: .init(), windows: { _ in windows })
    var expansion = ApplicationPickerModel.Expansion()
    let didExpand = expansion.expand(collapsed[1].rows[0])
    #expect(didExpand)
    let expanded = ApplicationPickerModel.windowSections(sections, expansion: expansion, windows: { _ in windows })
    #expect(expanded[0].rows.count == 1)
    #expect(expanded[1].rows.count == 7) // App, five windows, Show all.
    #expect(expanded[2].rows.count == 1)
    #expect(expanded[1].rows.dropFirst().prefix(5).compactMap(\.window) == Array(windows.prefix(5)))
    #expect(expanded[1].rows.last?.showsAllAction == true)
    let rows = expanded.flatMap(\.rows)
    #expect(Set(rows.map(\.id)).count == rows.count)
    #expect(ApplicationPickerModel.move(collapsed[1].rows[0].id, by: 1, in: rows) == expanded[1].rows[1].id)
    #expect(ApplicationPickerModel.move(expanded[1].rows[1].id, by: -1, in: rows) == collapsed[1].rows[0].id)
    #expect(ApplicationPickerModel.hints(for: expanded[1].rows[1], returnHint: "New window").primary == "Use this window")
    #expect(ApplicationPickerModel.hints(for: expanded[1].rows[1], returnHint: "New window").secondary == "Back")
    #expect(ApplicationPickerModel.hints(for: collapsed[1].rows[0], returnHint: "New window").secondary == "Windows")
    expansion.showingAll = true
    let all = ApplicationPickerModel.windowSections(sections, expansion: expansion, windows: { _ in windows })
    #expect(all[1].rows.compactMap(\.window).count == 7)
    #expect(!all[1].rows.contains { $0.showsAllAction })
    #expect(expansion.collapse() == collapsed[1].rows[0].id)
    #expect(expansion.rowID == nil)
    #expect(!expansion.showingAll)
}

@Test(.appTestApplication) func pickerWindowRowsHandleNoWindowsAndStoppedApps() throws {
    let app = choice("safari", "Safari")
    let sections = ApplicationPickerModel.sections(installed: [app], running: [])
    for windows in [Optional<[ApplicationPickerWindow]>.none, []] {
        let row = try #require(ApplicationPickerModel.windowSections(sections, expansion: .init(), windows: { _ in windows }).last?.rows.first)
        var expansion = ApplicationPickerModel.Expansion()
        let didExpand = expansion.expand(row)
        #expect(!didExpand)
        #expect(ApplicationPickerModel.hints(for: row, returnHint: "New window").secondary == nil)
    }
    #expect(ApplicationPickerModel.windowCount(0) == "No window here")
    #expect(ApplicationPickerModel.windowCount(1) == "1 window")
    #expect(ApplicationPickerModel.windowCount(3) == "3 windows")

}

/// The picker passes Recent, Running and installed lists together, so one app appears several times.
/// Copies of one bundle ID are one app, not a duplicate name.
@Test(.appTestApplication) func pickerFolderCaptionsIgnoreRepeatsOfTheSameApp() {
    let safari = choice("com.apple.Safari", "Safari", "/Applications/Safari.app")
    let notes = choice("com.apple.Notes", "Notes", "/System/Applications/Notes.app")
    #expect(ApplicationPickerModel.folderCaptions(for: [safari, notes, safari, notes, safari], home: home).isEmpty)
    let copy = choice("com.example.Safari", "Safari", "/Users/fixture/Applications/Safari.app")
    #expect(ApplicationPickerModel.folderCaptions(for: [safari, safari, copy], home: home)
            == ["com.apple.Safari": "/Applications", "com.example.Safari": "~/Applications"])
}
