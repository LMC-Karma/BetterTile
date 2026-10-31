import AppKit
import BetterTileCore
import BetterTileMacOS
import Foundation
import Testing
@testable import BetterTileApp

@Test(.appTestApplication) func applicationRuleWarningMatchesRuleState() {
    #expect(ApplicationRuleWarning.text(bundleIdentifier: " \t\n ", isInstalled: true)
            == "Invalid app identifier. Remove this rule and choose an application again.")
    #expect(ApplicationRuleWarning.text(bundleIdentifier: "test.missing", isInstalled: false)
            == "App not installed. This rule stays saved and applies when the app is available again.")
    #expect(ApplicationRuleWarning.text(bundleIdentifier: "test.installed", isInstalled: true) == nil)
}

@Test(.appTestApplication) func appRuleNamesKeepKnownNamesAndHideMissingIdentifiers() {
    #expect(ApplicationRuleAppName.displayName(bundleIdentifier: "test.missing", knownName: "Notes") == "Notes")
    #expect(ApplicationRuleAppName.displayName(bundleIdentifier: "test.missing") == "App not installed")
    #expect(ApplicationRuleAppName.displayName(bundleIdentifier: " \t ") == "No app identifier")
    #expect(ApplicationRuleAppName.displayName(bundleIdentifier: "test.missing", knownName: "") == "App not installed")
    #expect(ApplicationRuleAppName.missingAppNotice(knownName: "Notes") == "Notes is not installed")
    #expect(ApplicationRuleAppName.missingAppNotice(knownName: nil) == "App not installed")
}

@Test(.appTestApplication) @MainActor func appRuleAddChangeAndRemovePersistWithoutAccessibility() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ConfigurationStore(fileURL: directory.appending(path: "configuration.json"))
    let system = FakeAppWindowSystem()
    system.permission = false
    let model = makeOffscreenModel(store: store, system: system, startRuntime: false)
    defer { model.shutdown() }
    let id = "test.uninstalled.application"
    #expect(!model.hasAccessibilityPermission)
    model.setRule(.excludeFromBento, for: id)
    model.flushConfiguration()
    #expect(try store.load().applicationRules.rule(for: id) == .excludeFromBento)
    model.setRule(.ignoreEverywhere, for: id)
    model.flushConfiguration()
    #expect(try store.load().applicationRules.entries.count == 1)
    #expect(try store.load().applicationRules.rule(for: id) == .ignoreEverywhere)
    model.setRule(.manageNormally, for: id)
    model.flushConfiguration()
    #expect(try store.load().applicationRules.isEmpty)
    model.setRule(.excludeFromBento, for: id)
    model.clearRule(for: id)
    model.flushConfiguration()
    #expect(try store.load().applicationRules.isEmpty)
    #expect(system.completeSweepCount == 0)
    #expect(system.frameWriteCounts.isEmpty)
}

@Test(.appTestApplication) @MainActor func existingAppRuleEncodingLoadsUnchangedAndKeepsMissingApps() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = ConfigurationStore(fileURL: directory.appending(path: "configuration.json"))
    let json = #"{"schemaVersion":12,"showDockIcon":true,"applicationRules":[{"bundleIdentifier":"test.missing","rule":"excludeFromBento"},{"bundleIdentifier":"test.ignored","rule":"ignoreEverywhere"}]}"#
    try Data(json.utf8).write(to: store.fileURL)
    let system = FakeAppWindowSystem()
    system.permission = false
    let model = makeOffscreenModel(store: store, system: system, startRuntime: false)
    defer { model.shutdown() }
    #expect(model.configurationLoadError == nil)
    #expect(model.configuration.showDockIcon)
    #expect(model.configuration.applicationRules.rule(for: "test.missing") == .excludeFromBento)
    #expect(model.configuration.applicationRules.rule(for: "test.ignored") == .ignoreEverywhere)
    model.setRule(.ignoreEverywhere, for: "test.missing")
    model.flushConfiguration()
    let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
    let rules = try #require(object["applicationRules"] as? [[String: String]])
    #expect(rules == [["bundleIdentifier": "test.ignored", "rule": "ignoreEverywhere"],
                      ["bundleIdentifier": "test.missing", "rule": "ignoreEverywhere"]])
    #expect(try store.load() == model.configuration)
}

@Test(.appTestApplication) @MainActor func matchingAppRuleWindowsUseExistingObservationsWithoutExtraReads() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let system = FakeAppWindowSystem()
    system.windows[0].title = "First document"
    var second = system.windows[0]
    second.id = WindowID(rawValue: "second")
    second.title = "Second document"
    system.windows.append(second)
    var other = second
    other.id = WindowID(rawValue: "other")
    other.bundleIdentifier = "test.other"
    system.windows.append(other)
    let model = makeOffscreenModel(store: ConfigurationStore(fileURL: directory.appending(path: "configuration.json")),
                               system: system, startRuntime: false)
    defer { model.shutdown() }
    model.watchdog()
    let reads = system.completeSweepCount
    #expect(model.matchingRuleWindows(for: "com.example.Test").map(\.title) == ["First document", "Second document"])
    #expect(model.matchingRuleWindows(for: "test.absent").isEmpty)
    #expect(system.completeSweepCount == reads)
    system.windows.removeAll { $0.id == second.id }
    system.windows[0].title = "Renamed document"
    model.watchdog()
    #expect(model.matchingRuleWindows(for: "com.example.Test").map(\.title) == ["Renamed document"])
    system.permission = false
    model.watchdog()
    #expect(model.matchingRuleWindows(for: "com.example.Test").isEmpty)
    #expect(system.frameWriteCounts.isEmpty)
}

@Test(.appTestApplication) @MainActor func whitespaceAppRuleIsPreservedUntilExplicitRemoval() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = ConfigurationStore(fileURL: directory.appending(path: "configuration.json"))
    let json = #"{"schemaVersion":12,"applicationRules":[{"bundleIdentifier":" \t\n ","rule":"ignoreEverywhere"}]}"#
    try Data(json.utf8).write(to: store.fileURL)
    let id = " \t\n "
    let model = makeOffscreenModel(store: store, system: FakeAppWindowSystem(), startRuntime: false)
    defer { model.shutdown() }
    #expect(model.configurationLoadError == nil)
    #expect(model.configuration.applicationRules.entries.map(\.bundleIdentifier) == [id])
    model.updateConfiguration { $0.showMenuBarIcon.toggle() }
    model.flushConfiguration()
    #expect(try store.load().applicationRules.rule(for: id) == .ignoreEverywhere)
    #expect(try store.load().applicationRules.entries.map(\.bundleIdentifier) == [id])
    model.clearRule(for: id)
    model.flushConfiguration()
    #expect(try store.load().applicationRules.isEmpty)
}

@MainActor @Suite(.appTestApplication, .serialized) struct ApplicationRuleModelTests {
    enum SheetResult: CaseIterable {
        case existingRule, newRule, replacement
    }

    @Test(arguments: SheetResult.allCases)
    func sheetResultClearsSearchAndShowsSelectedRule(result: SheetResult) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let system = FakeAppWindowSystem()
        system.permission = false
        let model = makeOffscreenModel(store: ConfigurationStore(fileURL: directory.appending(path: "configuration.json")),
                                   system: system, startRuntime: false)
        defer { model.shutdown() }
        let notes = "com.apple.Notes"
        let safari = "com.apple.Safari"
        model.setRule(.ignoreEverywhere, for: notes)
        switch result {
        case .existingRule:
            model.setRule(.excludeFromBento, for: safari)
        case .newRule:
            break
        case .replacement:
            model.setRule(.excludeFromBento, for: "test.missing")
            model.setRuleEnabled(false, for: "test.missing")
        }
        var list = ApplicationRuleListState(search: "Notes", selection: notes)
        #expect(!list.includes(bundleIdentifier: safari, name: "Safari"))

        switch result {
        case .existingRule:
            // Opening an existing rule returns its identifier without changing configuration.
            #expect(model.configuration.applicationRules.configuredRule(for: safari) == .excludeFromBento)
        case .newRule:
            #expect(model.configuration.applicationRules.configuredRule(for: safari) == nil)
            model.setRule(.excludeFromBento, for: safari)
        case .replacement:
            model.moveRule(from: "test.missing", to: safari)
            #expect(model.configuration.applicationRules.configuredRule(for: "test.missing") == nil)
            #expect(!model.configuration.applicationRules.isEnabled(for: safari))
        }
        // Every sheet completion uses this same transition before the detail guard runs.
        list.selectSheetResult(safari)
        #expect(list.search.isEmpty)
        #expect(list.selection == safari)
        let visible = model.configuration.applicationRules.entries.filter {
            list.includes(bundleIdentifier: $0.bundleIdentifier, name: $0.bundleIdentifier == safari ? "Safari" : "Notes")
        }
        let detail = try #require(visible.first { $0.bundleIdentifier == list.selection })
        #expect(detail.bundleIdentifier == safari)
        #expect(detail.rule == .excludeFromBento)
    }

    @Test func enabledSwitchKeepsParticipationAndPersists() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigurationStore(fileURL: directory.appending(path: "configuration.json"))
        let system = FakeAppWindowSystem()
        system.permission = false
        let model = makeOffscreenModel(store: store, system: system, startRuntime: false)
        defer { model.shutdown() }
        let id = "test.enabled"
        model.setRule(.ignoreEverywhere, for: id)

        for enabled in [false, true] {
            model.setRuleEnabled(enabled, for: id)
            model.flushConfiguration()
            let rules = try store.load().applicationRules
            #expect(rules.configuredRule(for: id) == .ignoreEverywhere)
            #expect(rules.isEnabled(for: id) == enabled)
            #expect(rules.rule(for: id) == (enabled ? .ignoreEverywhere : .manageNormally))
            #expect(model.statusMessage == (enabled
                ? "App not installed: Ignore Everywhere."
                : "App not installed is managed normally while its rule is off."))
        }
        let before = model.configuration
        let status = model.statusMessage
        for enabled in [false, true] {
            model.setRuleEnabled(enabled, for: "test.no-rule")
            #expect(model.configuration == before)
            #expect(model.statusMessage == status)
        }
        model.flushConfiguration()
        #expect(try store.load() == before)
        #expect(system.frameWriteCounts.isEmpty)
    }

    @Test func disabledRuleAllowsPlacementAndKeepsBundleMatches() {
        let system = FakeAppWindowSystem()
        var other = system.windows[0]
        other.id = WindowID(rawValue: "other-app")
        other.bundleIdentifier = "test.other"
        system.windows.append(other)
        let model = makeModel(system: system)
        defer { model.shutdown() }
        let id = "com.example.Test"
        let window = system.windows[0]
        model.watchdog()
        model.setRule(.ignoreEverywhere, for: id)
        let target = LayoutWheelTarget(windowID: window.id, displayID: window.displayID,
                                       visibleFrame: system.mainDisplay.visibleFrame)
        guard case .unavailable = model.previewLayoutWheel(.windowAction(.leftHalf), for: target) else {
            Issue.record("An enabled Ignore Everywhere rule must reject placement")
            return
        }
        model.setRuleEnabled(false, for: id)
        #expect(model.configuration.applicationRules.rule(for: id) == .manageNormally)
        guard case let .ready(placements) = model.previewLayoutWheel(.windowAction(.leftHalf), for: target) else {
            Issue.record("A disabled rule must allow normal placement")
            return
        }
        #expect(placements.map(\.windowID) == [window.id])
        #expect(model.matchingRuleWindows(for: id).map(\.id) == [window.id])
        #expect(model.matchingRuleWindows(for: "test.other").map(\.id) == [other.id])
        model.setRuleEnabled(true, for: id)
        guard case .unavailable = model.previewLayoutWheel(.windowAction(.leftHalf), for: target) else {
            Issue.record("Enabling the rule again must reject placement")
            return
        }
    }

    @Test(arguments: [false, true])
    func movingRuleKeepsParticipationAndEnabledState(enabled: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigurationStore(fileURL: directory.appending(path: "configuration.json"))
        let system = FakeAppWindowSystem()
        system.permission = false
        let model = makeOffscreenModel(store: store, system: system, startRuntime: false)
        defer { model.shutdown() }
        model.setRule(.excludeFromBento, for: "test.original")
        model.setRuleEnabled(enabled, for: "test.original")
        model.moveRule(from: "test.original", to: "test.replacement")
        model.flushConfiguration()
        let moved = try store.load().applicationRules
        #expect(moved.configuredRule(for: "test.original") == nil)
        #expect(moved.configuredRule(for: "test.replacement") == .excludeFromBento)
        #expect(moved.isEnabled(for: "test.replacement") == enabled)
        #expect(moved.entries.count == 1)

        model.setRule(.ignoreEverywhere, for: "test.occupied")
        model.setRuleEnabled(false, for: "test.occupied")
        let before = model.configuration
        model.moveRule(from: "test.replacement", to: "test.occupied")
        #expect(model.configuration == before, "Even a disabled target rule must be preserved")
        model.flushConfiguration()
        #expect(try store.load() == before)
    }

}

/// Setting a table's style reloads its rows. A representable can attach during SwiftUI layout.
@MainActor private final class RuleHighlightTable: NSTableView {
    var isAttachingRow = false
    var highlightWrites = 0
    var writesWhileAttaching = 0

    override var selectionHighlightStyle: NSTableView.SelectionHighlightStyle {
        didSet {
            highlightWrites += 1
            if isAttachingRow { writesWhileAttaching += 1 }
        }
    }
}

@Test(.appTestApplication) @MainActor func appRuleSelectionStyleWaitsUntilTheRowFinishesAttaching() async throws {
    let table = RuleHighlightTable()
    table.selectionHighlightStyle = .regular
    table.highlightWrites = 0
    let row = NSView()
    table.addSubview(row)
    let selection = RuleListSelectionView()
    table.isAttachingRow = true
    row.addSubview(selection)
    // SwiftUI can update the representable again in the same render pass.
    selection.suppressNativeHighlight()
    selection.suppressNativeHighlight()
    #expect(table.writesWhileAttaching == 0, "A style reload must not re-enter the current render pass")
    #expect(table.selectionHighlightStyle == .regular)
    table.isAttachingRow = false
    try #require(await waitFor { table.selectionHighlightStyle == .none })
    #expect(table.highlightWrites == 1, "Coalesce the attachment and representable updates")
    selection.suppressNativeHighlight()
    // A main-queue barrier follows the queued style update without waiting on elapsed time.
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
    #expect(table.highlightWrites == 1, "An unchanged style must not reload the table")
}

@Test(.appTestApplication) @MainActor func appRuleSelectionStyleDoesNotReloadADetachedTable() async {
    let table = RuleHighlightTable()
    table.selectionHighlightStyle = .regular
    table.highlightWrites = 0
    let selection = RuleListSelectionView()
    table.addSubview(selection)
    selection.removeFromSuperview()
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
    #expect(table.highlightWrites == 0)
}
