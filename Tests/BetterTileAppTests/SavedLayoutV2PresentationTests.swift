import BetterTileCore
import Foundation
import Testing
@testable import BetterTileApp

@Suite(.appTestApplication) @MainActor struct SavedLayoutV2PresentationTests {
    @Test func panelSubtitleNamesFirstPreferenceAndCaptureNamesStayTheSame() {
        let group = SavedLayoutDocument(name: "Homework", mode: .bento, layout: .slot("a"),
            slots: [.init(id: "a", prefer: [.group("Reading"), .app("com.example.Later")])])
        #expect(SavedLayoutQuickCapture.subtitle(for: group, appNames: ["com.example.Later": "Later"]) == "Reading")
        let any = SavedLayoutDocument(name: "Shape", mode: .bento,
            layout: .split(axis: .vertical, ratios: [0.5, 0.5], children: [.slot("a"), .slot("b")]),
            slots: [.init(id: "a"), .init(id: "b")])
        #expect(SavedLayoutQuickCapture.subtitle(for: any) == "Any window")
        var unresolved = group
        unresolved.slots[0].prefer = [.app("org.example.Uninstalled"), .group("Reading")]
        #expect(SavedLayoutQuickCapture.subtitle(for: unresolved) == "An app that is not installed")
        unresolved.slots.append(.init(id: "any"))
        #expect(SavedLayoutQuickCapture.subtitle(for: unresolved) == "An app that is not installed + Any window")
        var captured = any
        captured.slots = [.init(id: "a", prefer: [.app("com.example.Editor")]), .init(id: "b", prefer: [.app("com.example.Browser")])]
        let names = ["com.example.Editor": "Editor", "com.example.Browser": "Browser"]
        #expect(SavedLayoutQuickCapture.name(for: captured, existingNames: [], appNames: names) == "Editor + Browser")
        #expect(SavedLayoutQuickCapture.name(for: captured, existingNames: ["Editor + Browser"], appNames: names) == "Editor + Browser 2")
    }

    @Test func preferenceTextAndTooltipsNeverExposeBundleIDs() {
        let secretID = "org.example.NeverDisplayThisBundleID"
        let app = SavedLayoutPreferencePresentation(.app(secretID), applications: [:], groups: .init())
        #expect(app.title == "An app that is not installed")
        #expect(app.unavailable && !app.isGroup)
        #expect(!app.title.contains(secretID))
        #expect(app.detail?.contains(secretID) == false)
        let group = SavedLayoutPreferencePresentation(.group("Reading"), applications: [:], groups: .init())
        #expect(group.title == "@Reading")
        #expect(group.isGroup && group.unavailable && group.iconURL == nil)
        #expect(group.detail == "Group not found · skipped when you apply")
    }

    @Test func previewUsesTheSameReasonAndTextAsDetailsIncludingManualLabels() throws {
        let bounds = BTRect(x: 0, y: 0, width: 1000, height: 800)
        let display = DisplayID(rawValue: "test-display")
        let id = WindowID(rawValue: "front")
        let document = SavedLayoutDocument(name: "Manual", mode: .manual,
            slots: [.init(id: "a")], windows: [.init(slot: "a", rect: .init(x: 0, y: 0, width: 1, height: 1))])
        let window = WindowSnapshot(id: id, processIdentifier: 0, bundleIdentifier: "org.example.NeverDisplayThisBundleID",
            frame: bounds, displayID: display)
        let eligible = SavedLayoutEligibleWindow(id: id, bundleID: "org.example.NeverDisplayThisBundleID", frame: bounds)
        let plan = SavedLayoutApplyPlan(assignments: ["a": id], placements: [], slotReasons: ["a": .largestFreeSlot],
            targetSession: .manual, needsSessionUpdate: false)
        let row = SavedLayoutPreviewRow(slot: document.slots[0], appName: "Preview", status: .matched(window), eligibleWindowCount: 3)
        #expect(row.outcome(reason: plan.slotReasons["a"], screenName: { _ in "Display" }) == "Frontmost window · largest free pane")
        let cache = SavedLayoutPagePlan()
        cache.refresh(document: document, displayID: display, identity: nil,
            displays: [.init(id: display, frame: bounds, visibleFrame: bounds, isMain: true)], unavailable: nil) { _, _ in
                .init(document: document, displayID: display, rows: [row], problem: nil, workArea: bounds, plan: plan)
            }
        let presentation = try #require(cache.presentation(groups: .init(), resolvedBundleIDs: [:], name: { _ in "An app that is not installed" }, displayName: { _ in "Display" }))
        let details = SavedLayoutPlanPresentation(document: document, plan: plan, windows: [eligible], workArea: bounds,
            groups: .init(), resolvedBundleIDs: [:], name: { _ in "An app that is not installed" }, windowName: { _ in "Preview" })
        #expect(presentation.lines == details.lines)
        #expect(presentation.lines == ["Rectangle 1 — Preview (frontmost window; largest free pane)"])
        #expect(!presentation.lines.joined().contains("nearest"))
        #expect(!presentation.lines.joined().contains("org.example"))
    }

    @Test func preferencePickerUsesSharedSectionsRecentSearchAndDuplicateCaptions() {
        let a = ApplicationChoice(bundleIdentifier: "org.example.a", name: "Editor", url: URL(filePath: "/Applications/Editor.app"))
        let b = ApplicationChoice(bundleIdentifier: "org.example.b", name: "Editor", url: URL(filePath: "/Other/Editor.app"))
        let sections = PanePreferenceApplicationPicker.appSections(installed: [a, b], running: [a], recent: [b], selected: [], search: "")
        #expect(sections == ApplicationPickerModel.sections(installed: [a, b], running: [a], recent: [b]))
        #expect(sections.map(\.kind) == [.recent, .running, .allApps])
        #expect(sections.flatMap(\.rows).allSatisfy { $0.caption != nil })
        let filtered = PanePreferenceApplicationPicker.appSections(installed: [a, b], running: [a], recent: [b], selected: [.app(a.id)], search: "Editor")
        #expect(filtered.flatMap(\.rows).map(\.application.id) == [b.id])
    }

    @Test func adapterIsRemovedAndNewSourcesHaveNativeTargetRegistration() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(at: root.appending(path: "Sources/BetterTileApp"), includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "swift" {
            #expect(!(try String(contentsOf: file, encoding: .utf8)).contains("primaryBundleID"), Comment(rawValue: file.lastPathComponent))
        }
        let project = try String(contentsOf: root.appending(path: "BetterTile.xcodeproj/project.pbxproj"), encoding: .utf8)
        for name in ["SavedLayoutPreferences.swift", "SavedLayoutTransfer.swift"] {
            #expect(project.components(separatedBy: name).count >= 5)
        }
        let picker = try String(contentsOf: root.appending(path: "Sources/BetterTileApp/PaneApplicationPicker.swift"), encoding: .utf8)
        #expect(picker.contains("guard application.activationPolicy") == false) // Filtering belongs to the existing source.
        let shared = try String(contentsOf: root.appending(path: "Sources/BetterTileApp/ApplicationPicker.swift"), encoding: .utf8)
        #expect(shared.contains("guard application.activationPolicy == .regular"))
    }
}
