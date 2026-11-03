import AppKit
import SwiftUI
import Testing
@testable import BetterTileApp

@MainActor @Suite(.appTestApplication, .serialized, .settingsUI) struct SettingsNavigationTests {
    /// A Saved Layout result pill's Details action requests a page while Settings may still hold a search.
    /// The requested page must replace a zero-result search instead of staying hidden behind it.
    @Test func requestedDestinationClearsASearchThatHidesIt() async throws {
        let model = makeModel(system: FakeAppWindowSystem())
        defer { model.shutdown() }
        let query = "unmatched-setting-query"
        #expect(!SettingsDestination.allCases.contains { $0.matchesSearch(query) })
        model.requestedSettingsDestination = .shortcuts
        let host = try SettingsSnapshotHost(
            SettingsTestFactory.makeSettingsView(model: model, openSetup: {}, search: query),
            dark: false, width: 1000, height: 700, fitHeight: false)
        defer { host.close() }
        func switches(_ view: NSView) -> [NSView] {
            (String(describing: type(of: view)) == "PlatformSwitch" ? [view] : []) + view.subviews.flatMap(switches)
        }
        // The Shortcuts page has exactly one switch; the zero-result placeholder has none.
        try await waitForSettingsUI("the requested Shortcuts page", in: host.view, timeout: .seconds(5)) {
            model.requestedSettingsDestination == nil && switches(host.view).count == 1
        }
    }

    /// Settings is already open with a search, either one that matches nothing or one that matches only
    /// General. A later request must clear the search field and show the requested page.
    @Test(arguments: ["unmatched-setting-query", "launch at login"])
    func requestToAnOpenSettingsWindowClearsItsSearch(query: String) async throws {
        let model = makeModel(system: FakeAppWindowSystem())
        defer { model.shutdown() }
        #expect(!SettingsDestination.shortcuts.matchesSearch(query))
        let host = try SettingsSnapshotHost(
            SettingsTestFactory.makeSettingsView(model: model, openSetup: {}, search: query),
            dark: false, width: 1000, height: 700, fitHeight: false)
        defer { host.close() }
        func views<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] {
            ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views($0, type) }
        }
        func searchField() -> NSTextField? {
            views(host.view, NSTextField.self).first { $0.placeholderString == "Search settings" }
        }
        func switchCount() -> Int { views(host.view, NSSwitch.self).count }
        // The sidebar lists only the pages that match the search, under their section headers.
        func sidebarRows() -> Int? { views(host.view, NSOutlineView.self).first?.numberOfRows }
        let matchesGeneral = SettingsDestination.general.matchesSearch(query)
        let searchedRows = matchesGeneral ? 2 : 0
        // Wait until the searched state has held for several layout opportunities: no page for no
        // results, or General's several switches, with the sidebar filtered to match.
        var held = 0
        try await waitForSettingsUI("the searched Settings window", in: host.view) {
            let searched = searchField()?.stringValue == query && sidebarRows() == searchedRows
                && (matchesGeneral ? switchCount() > 1 : switchCount() == 0)
            held = searched ? held + 1 : 0
            return held >= 3
        }
        model.requestedSettingsDestination = .shortcuts
        // The Shortcuts page has exactly one switch, and the cleared search lists every page again.
        try await waitForSettingsUI("the requested Shortcuts page with no search", in: host.view, timeout: .seconds(5)) {
            model.requestedSettingsDestination == nil && switchCount() == 1
                && searchField()?.stringValue == "" && (sidebarRows() ?? 0) > SettingsDestination.allCases.count
        }
        #expect(searchField()?.stringValue == "")
        #expect((sidebarRows() ?? 0) > SettingsDestination.allCases.count, "Every page and its section header")
    }
}
