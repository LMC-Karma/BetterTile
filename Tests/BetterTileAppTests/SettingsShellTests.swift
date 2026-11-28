import AppKit
import Carbon
import BetterTileCore
import SwiftUI
import Testing
@testable import BetterTileApp

/// Behaviour of the Settings shell: search, sidebar filtering, auto-selection, page requests and ⌘F.
/// Each test drives the real window content through AppKit, as a person would.
@MainActor @Suite(.appTestApplication, .serialized, .settingsUI) struct SettingsShellTests {
    // Sidebar rows with an empty query: section headers count as rows.
    // 0 Essentials, 1 General, 2 Window Management, 3 Window Layout, 4 Saved Layouts,
    // 5 Shortcuts, 6 Snap Zones, 7 Menu Bar, 8 Layout Wheel, 9 Advanced, 10 Per-App Rules.
    private static let unfilteredRowCount = 3 + SettingsDestination.allCases.count

    @Test func aChangedQuerySelectsTheFirstMatchInCatalogueOrder() async throws {
        let shell = try ShellWindow(selection: .general)
        defer { shell.close() }
        try await shell.waitFor("the unfiltered sidebar") { shell.sidebarRows == Self.unfilteredRowCount }
        try shell.type("saved")
        // The sidebar lists Saved Layouts above Snap Zones, but the catalogue lists Snap Zones first.
        try await shell.waitFor("Snap Zones selected for “saved”") {
            shell.sidebarRows == 3 && shell.selectedSidebarRow == 2
        }
        #expect(shell.pageSubtitleIsShown(.snapZones))
        #expect(!shell.pageSubtitleIsShown(.savedLayouts))
    }

    @Test func aQueryThatStillMatchesKeepsTheSelection() async throws {
        let shell = try ShellWindow(selection: .menuBar)
        defer { shell.close() }
        try await shell.waitFor("the Menu Bar page") { shell.selectedSidebarRow == 7 }
        try shell.type("drag")
        // “drag” matches General, Snap Zones and Menu Bar; Menu Bar stays selected.
        try await shell.waitFor("Menu Bar kept for “drag”") {
            shell.sidebarRows == 5 && shell.selectedSidebarRow == 4 && shell.pageSubtitleIsShown(.menuBar)
        }
        try shell.type("reorder")
        try await shell.waitFor("Menu Bar kept for “reorder”") {
            shell.sidebarRows == 2 && shell.selectedSidebarRow == 1 && shell.pageSubtitleIsShown(.menuBar)
        }
    }

    @Test func aQueryWithNoMatchKeepsTheSelectionForWhenItClears() async throws {
        let shell = try ShellWindow(selection: .shortcuts)
        defer { shell.close() }
        try await shell.waitFor("the Shortcuts page") { shell.switchCount == 1 }
        try shell.type("zzqx")
        try await shell.waitFor("an empty sidebar") { shell.sidebarRows == 0 }
        try await shell.waitFor("no page switches") { shell.switchCount == 0 }
        try await shell.waitFor("the no-result detail") { shell.element(labelled: "Clear Search") != nil }
        try shell.type("")
        try await shell.waitFor("the Shortcuts page again") {
            shell.switchCount == 1 && shell.sidebarRows == Self.unfilteredRowCount && shell.selectedSidebarRow == 5
        }
    }

    @Test(arguments: [("reorder", 2), ("keyboard", 5), ("", 3 + 8)])
    func sectionsWithoutAMatchDisappear(query: String, rows: Int) async throws {
        let shell = try ShellWindow(selection: .general)
        defer { shell.close() }
        try await shell.waitFor("the unfiltered sidebar") { shell.sidebarRows == Self.unfilteredRowCount }
        try shell.type(query)
        try await shell.waitFor("\(rows) sidebar rows for “\(query)”") { shell.sidebarRows == rows }
    }

    @Test(arguments: ClearPath.allCases)
    func everyClearPathEmptiesTheQuery(path: ClearPath) async throws {
        let shell = try ShellWindow(selection: .general)
        defer { shell.close() }
        try shell.type(path == .detailButton ? "zzqx" : "keyboard")
        try await shell.waitFor("the searched sidebar") { shell.sidebarRows != Self.unfilteredRowCount }
        switch path {
        case .detailButton:
            try await shell.waitFor("the Clear Search button") { shell.element(labelled: "Clear Search") != nil }
            #expect(AXProbe.press(try #require(shell.element(labelled: "Clear Search"))))
        case .fieldButton:
            try await shell.waitFor("the clear button") { shell.element(labelled: "Clear search") != nil }
            #expect(AXProbe.press(try #require(shell.element(labelled: "Clear search"))))
        case .escape:
            let editor = try #require(shell.findBox?.currentEditor() as? NSTextView)
            editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        }
        try await shell.waitFor("the cleared query") {
            shell.findBox?.stringValue == "" && shell.sidebarRows == Self.unfilteredRowCount
        }
    }

    enum ClearPath: CaseIterable { case detailButton, fieldButton, escape }

    @Test(arguments: [KeyPress.latinF, .russianF])
    func commandFFocusesTheSearchField(press: KeyPress) async throws {
        let shell = try ShellWindow(selection: .shortcuts)
        defer { shell.close() }
        try await shell.waitFor("the Shortcuts page") { shell.switchCount == 1 }
        let outline = try #require(shell.outline)
        shell.window.makeFirstResponder(outline)
        #expect(!shell.findBoxIsFocused)
        let event = try press.event(windowNumber: shell.window.windowNumber)
        #expect(shell.window.performKeyEquivalent(with: event))
        try await shell.waitFor("the focused search field") { shell.findBoxIsFocused }
    }

    @Test func commandYOnACommandQWERTYLayoutLeavesFocusWhereItIs() async throws {
        let shell = try ShellWindow(selection: .shortcuts)
        defer { shell.close() }
        try await shell.waitFor("the Shortcuts page") { shell.switchCount == 1 }
        let outline = try #require(shell.outline)
        shell.window.makeFirstResponder(outline)
        // The key whose Dvorak letter is F; with ⌘ held this layout types Y.
        _ = shell.window.performKeyEquivalent(with: try KeyPress.dvorakCommandY.event(windowNumber: shell.window.windowNumber))
        try await shell.waitFor("focus still in the sidebar") { shell.window.firstResponder === outline }
        #expect(!shell.findBoxIsFocused)
    }

    /// The find shortcut follows the layout's Command-key character, as macOS menu shortcuts do.
    @Test(arguments: KeyPress.allCases)
    func theFindShortcutMatchesTheCommandLayerCharacter(press: KeyPress) throws {
        let event = try press.event()
        #expect(FindShortcutCatcher.isFindShortcut(event) == press.isFind)
        // The layouts really differ from the Latin letters the shortcut is named after.
        switch press {
        case .russianF, .greekF, .dvorakCommandF: #expect(event.charactersIgnoringModifiers != "f")
        case .dvorakCommandY: #expect(event.charactersIgnoringModifiers == "f")
        case .latinF, .russianA: break
        }
    }

    @Test func theFindShortcutNeedsCommandAlone() throws {
        func event(_ modifiers: NSEvent.ModifierFlags, type: NSEvent.EventType = .keyDown) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                context: nil, characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
        }
        #expect(FindShortcutCatcher.isFindShortcut(try event(.command)))
        #expect(FindShortcutCatcher.isFindShortcut(try event([.command, .capsLock])))
        #expect(!FindShortcutCatcher.isFindShortcut(try event([])))
        #expect(!FindShortcutCatcher.isFindShortcut(try event([.command, .shift])))
        #expect(!FindShortcutCatcher.isFindShortcut(try event([.command, .option])))
        #expect(!FindShortcutCatcher.isFindShortcut(try event([.command, .control])))
        #expect(!FindShortcutCatcher.isFindShortcut(try event(.command, type: .keyUp)))
    }

    /// General's Shortcuts and Snap Zones links call the same `show(_:)` as a page request.
    /// Offscreen, SwiftUI exposes no pressable element for a link, so the request drives it.
    @Test(arguments: [SettingsDestination.shortcuts, .snapZones])
    func openingALinkedPageWhileSearchingClearsTheSearch(destination: SettingsDestination) async throws {
        let model = makeModel(system: FakeAppWindowSystem())
        let shell = try ShellWindow(model: model, selection: .general)
        defer { shell.close() }
        try await shell.waitFor("the unfiltered sidebar") { shell.sidebarRows == Self.unfilteredRowCount }
        // “drag” keeps General shown and lists both linked pages.
        try shell.type("drag")
        try await shell.waitFor("the searched sidebar") {
            shell.findBox?.stringValue == "drag" && shell.sidebarRows == 5 && shell.pageSubtitleIsShown(.general)
        }
        model.requestedSettingsDestination = destination
        let row = destination == .shortcuts ? 5 : 6
        try await shell.waitFor("the \(destination.rawValue) page with an empty search") {
            model.requestedSettingsDestination == nil && shell.findBox?.stringValue == ""
                && shell.sidebarRows == Self.unfilteredRowCount && shell.selectedSidebarRow == row
                && shell.pageSubtitleIsShown(destination)
        }
    }

    @Test func generalLinksOpenTheirOwnPages() {
        var opened: [SettingsDestination] = []
        let links = GeneralLinkActions(show: { opened.append($0) })
        links.openShortcuts()
        links.openSnapZones()
        #expect(opened == [.shortcuts, .snapZones])
    }

    @Test func aRequestBeforeTheWindowExistsOpensThatPage() async throws {
        let model = makeModel(system: FakeAppWindowSystem())
        model.requestedSettingsDestination = .menuBar
        let shell = try ShellWindow(model: model, selection: .general)
        defer { shell.close() }
        try await shell.waitFor("the requested Menu Bar page") {
            model.requestedSettingsDestination == nil && shell.selectedSidebarRow == 7 && shell.pageSubtitleIsShown(.menuBar)
        }
    }

    @Test(arguments: SettingsDestination.allCases)
    func everyPageButSavedLayoutsHasAHeader(destination: SettingsDestination) async throws {
        let shell = try ShellWindow(selection: destination)
        defer { shell.close() }
        try await shell.waitFor("the sidebar") { shell.sidebarRows == Self.unfilteredRowCount }
        if destination == .savedLayouts {
            try await shell.waitFor("the Saved Layouts page") { shell.switchCount > 0 || shell.hasElement(labelled: "Saved Layouts") }
            #expect(!shell.pageSubtitleIsShown(destination))
        } else {
            try await shell.waitFor("the \(destination.rawValue) header") { shell.pageSubtitleIsShown(destination) }
        }
    }

    @Test(arguments: [1060.0, 980.0])
    func sidebarStaysWithinItsColumnLimits(width: Double) async throws {
        let shell = try ShellWindow(selection: .general, width: width, height: 760)
        defer { shell.close() }
        try await shell.waitFor("the split view") { shell.sidebarWidth != nil }
        let sidebar = try #require(shell.sidebarWidth)
        // The ideal width is 210 pt, but the split view treats it as a hint and some test machines
        // settle a few points away from it, so the test checks the column limits.
        #expect(sidebar >= 198 && sidebar <= 240, "Sidebar is \(sidebar) pt wide")
    }

    @Test func matchingTrimsAndLowerCasesButComparesInnerTextAsTyped() {
        #expect(SettingsDestination.allCases.allSatisfy { $0.matchesSearch(" \t\n ") })
        #expect(SettingsDestination.shortcuts.matchesSearch("left half"))
        #expect(!SettingsDestination.shortcuts.matchesSearch("left  half"))
        #expect(SettingsDestination.savedLayouts.matchesSearch("JSON"))
        #expect(SettingsDestination.savedLayouts.matchesSearch("json"))
        #expect(SettingsDestination.menuBar.matchesSearch("reorder"))
        #expect(!SettingsDestination.menuBar.matchesSearch("réorder"))
        #expect(SettingsDestination.allCases.filter { $0.matchesSearch("saved") } == [.snapZones, .savedLayouts])
    }

    @Test func aSaveWarningSitsAboveBothColumnsAtTheMinimumWidth() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "configuration.json")
        try Data("broken JSON".utf8).write(to: file)
        let system = FakeAppWindowSystem()
        let model = makeOffscreenModel(store: ConfigurationStore(fileURL: file), system: system, startRuntime: false)
        let reason = try #require(model.configurationSaveBlockedReason)
        let shell = try ShellWindow(model: model, selection: .general, width: 980, height: 640)
        defer { shell.close() }
        try await shell.waitFor("the warning and the split view") {
            shell.element(containing: String(reason.prefix(24))) != nil && shell.splitView != nil
        }
        let warning = AXProbe.frame(try #require(shell.element(containing: String(reason.prefix(24)))))
        let split = try #require(shell.splitView)
        let splitTop = shell.window.convertToScreen(split.convert(split.bounds, to: nil)).maxY
        #expect(warning.minY >= splitTop - 0.5, "Warning \(warning) must sit above the split view top \(splitTop)")
        #expect(warning.width > 0 && warning.maxX <= shell.window.frame.maxX + 0.5)
    }
}

/// An offscreen Settings window and the AppKit handles a test reads from it.
@MainActor private struct ShellWindow {
    let model: BetterTileModel
    let host: SettingsSnapshotHost

    var window: NSWindow { host.window }

    init(model: BetterTileModel? = nil, selection: SettingsDestination,
         width: Double = 1060, height: Double = 760) throws {
        self.model = model ?? makeModel(system: FakeAppWindowSystem())
        host = try SettingsSnapshotHost(
            // SwiftUI builds its accessibility tree only while accessibility is in use.
            SettingsTestFactory.makeSettingsView(model: self.model, openSetup: {}, selection: selection)
                .environment(\.accessibilityEnabled, true),
            dark: false, width: width, height: height, fitHeight: false)
    }

    func close() {
        host.close()
        model.shutdown()
    }

    func waitFor(_ description: String, _ ready: () -> Bool) async throws {
        var held = 0
        try await waitForSettingsUI(description, in: host.view, timeout: .seconds(10)) {
            held = ready() ? held + 1 : 0
            return held >= 3
        }
    }

    // MARK: AppKit views

    private func views<T: NSView>(_ type: T.Type, in view: NSView? = nil) -> [T] {
        let root = view ?? host.view
        return ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { views(type, in: $0) }
    }

    var findBox: NSTextField? {
        views(NSTextField.self).first { $0.placeholderString == "Search settings" }
    }

    var findBoxIsFocused: Bool {
        guard let findBox, let responder = window.firstResponder else { return false }
        return responder === findBox || (findBox.currentEditor().map { $0 === responder } ?? false)
    }

    /// The sidebar list, not a list a page may contain.
    var outline: NSOutlineView? {
        guard let sidebar = splitView?.arrangedSubviews.first else { return nil }
        return views(NSOutlineView.self, in: sidebar).first
    }
    var splitView: NSSplitView? { views(NSSplitView.self).first }
    var sidebarRows: Int? { outline?.numberOfRows }

    var selectedSidebarRow: Int? {
        guard let row = outline?.selectedRow, row >= 0 else { return nil }
        return row
    }

    var sidebarWidth: CGFloat? {
        guard let split = splitView, split.arrangedSubviews.count >= 2 else { return nil }
        return split.arrangedSubviews[0].frame.width
    }

    var switchCount: Int { views(NSSwitch.self).count }

    /// Replaces the search text through the field editor, the way typing does.
    func type(_ text: String) throws {
        let field = try #require(findBox)
        if field.currentEditor() == nil { window.makeFirstResponder(field) }
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        if text.isEmpty {
            editor.deleteBackward(nil)
        } else {
            editor.insertText(text, replacementRange: editor.selectedRange())
        }
    }

    // MARK: Accessibility

    private var elements: [NSObject] { AXProbe.all(under: host.view) }

    func element(labelled text: String) -> NSObject? {
        elements.first { AXProbe.label($0) == text }
    }

    func element(containing text: String) -> NSObject? {
        elements.first {
            AXProbe.label($0).contains(text)
                || AXProbe.string($0, #selector(NSAccessibilityProtocol.accessibilityValue))?.contains(text) == true
        }
    }

    func hasElement(labelled text: String) -> Bool {
        elements.contains { AXProbe.label($0).contains(text) }
    }

    /// The page header combines the title and subtitle, so the subtitle identifies the shown page.
    func pageSubtitleIsShown(_ destination: SettingsDestination) -> Bool {
        hasElement(labelled: destination.subtitle)
    }
}

/// One key press as a keyboard layout produces it, built from the layout's own key table.
enum KeyPress: CaseIterable, CustomTestStringConvertible {
    case latinF, russianF, russianA, greekF, dvorakCommandF, dvorakCommandY

    var testDescription: String { "\(self)" }

    /// Whether macOS matches this press to a ⌘F menu shortcut.
    var isFind: Bool {
        switch self {
        case .latinF, .russianF, .greekF, .dvorakCommandF: true
        case .russianA, .dvorakCommandY: false
        }
    }

    private var layout: String {
        switch self {
        case .latinF: "com.apple.keylayout.US"
        case .russianF, .russianA: "com.apple.keylayout.Russian"
        case .greekF: "com.apple.keylayout.Greek"
        case .dvorakCommandF, .dvorakCommandY: "com.apple.keylayout.DVORAK-QWERTYCMD"
        }
    }

    private var keyCode: UInt16 {
        switch self {
        case .latinF, .russianF, .greekF, .dvorakCommandF: UInt16(kVK_ANSI_F)
        case .russianA: UInt16(kVK_ANSI_A)
        case .dvorakCommandY: UInt16(kVK_ANSI_Y)
        }
    }

    /// A ⌘ key-down whose two character strings are what the layout types with and without ⌘.
    func event(windowNumber: Int = 0) throws -> NSEvent {
        let withCommand = try Self.translate(keyCode, layout: layout, command: true)
        let plain = try Self.translate(keyCode, layout: layout, command: false)
        return try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: windowNumber, context: nil, characters: withCommand,
            charactersIgnoringModifiers: plain, isARepeat: false, keyCode: keyCode))
    }

    private static func translate(_ keyCode: UInt16, layout: String, command: Bool) throws -> String {
        let filter = [kTISPropertyInputSourceID as String: layout] as CFDictionary
        let sources = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource] ?? []
        let source = try #require(sources.first, "Keyboard layout \(layout) is not installed")
        let property = try #require(TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData))
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 8)
        let status = data.withUnsafeBytes { bytes in
            UCKeyTranslate(
                bytes.baseAddress!.assumingMemoryBound(to: UCKeyboardLayout.self), keyCode,
                UInt16(kUCKeyActionDown), command ? UInt32(cmdKey >> 8) & 0xFF : 0,
                UInt32(LMGetKbdType()), OptionBits(1 << kUCKeyTranslateNoDeadKeysBit),
                &deadKeys, characters.count, &length, &characters)
        }
        try #require(status == noErr)
        return String(utf16CodeUnits: characters, count: length)
    }
}
