import AppKit
import BetterTileCore
import Testing
import Synchronization
@testable import BetterTileMacOS

@Test(.macOSTestApplication) func paneLauncherNewWindowRequiresAnEnabledExplicitPressCommand() {
    #expect(NewWindowMenuCommand.matches(title: "New Window", role: "AXMenuItem", enabled: true, actions: ["AXPress"]))
    for title in ["New", "New Tab", "New Private Window", "New Document", "Nouvelle fenêtre"] {
        #expect(!NewWindowMenuCommand.matches(title: title, role: "AXMenuItem", enabled: true, actions: ["AXPress"]))
    }
    #expect(!NewWindowMenuCommand.matches(title: "New Window", role: "AXMenuItem", enabled: false, actions: ["AXPress"]))
    #expect(!NewWindowMenuCommand.matches(title: "New Window", role: "AXMenuItem", enabled: nil, actions: ["AXPress"]))
    #expect(!NewWindowMenuCommand.matches(title: "New Window", role: "AXButton", enabled: true, actions: ["AXPress"]))
    #expect(!NewWindowMenuCommand.matches(title: "New Window", role: "AXMenuItem", enabled: true, actions: []))
}



@Test(.macOSTestApplication) func paneLauncherAutoHideHoldKeepsBarRevealedUntilRelease() {
    var visibility = TabbedBarVisibility()
    visibility.hold(.applicationPicker, enabled: true, at: 0)
    visibility.enter(at: 0)
    visibility.leave(at: 0.1)
    visibility.advance(to: 20)
    #expect(visibility.isRevealed)
    #expect(visibility.nextDeadline == nil)
    visibility.hold(.applicationPicker, enabled: false, at: 20)
    visibility.advance(to: 20.5)
    #expect(!visibility.isRevealed)
}

@Test(.macOSTestApplication, .enabled(if: ProcessInfo.processInfo.environment["BETTERTILE_PANE_LAUNCHER_RENDER_DIR"] != nil)) @MainActor
func paneLauncherControlsOffscreenRenders() throws {
    let directory = try #require(ProcessInfo.processInfo.environment["BETTERTILE_PANE_LAUNCHER_RENDER_DIR"])
    _ = NSApplication.shared
    for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        for width in [170.0, 450.0] {
            for populated in [false, true] {
                let appearance = try #require(NSAppearance(named: appearanceName))
                let height = populated ? 34.0 : 240.0
                let view = TabbedPaneView(frame: NSRect(x: 0, y: 0, width: width, height: height))
                view.appearance = appearance
                view.active = true
                if populated {
                    let id = WindowID(rawValue: "render")
                    view.pane.tabs = [id]; view.pane.selected = id
                    view.titles = ["Research notes — a long fixture window title"]
                }
                view.layoutSubtreeIfNeeded()
                view.content.layoutSubtreeIfNeeded()
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                appearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(filePath: directory).appending(path: "pane-\(name)-\(Int(width))-\(populated ? "tabs" : "empty").png"))
            }
        }
    }
}

private struct FakeAXMenuNode: Sendable {
    var title: String
    var children: [FakeAXMenuNode]? = nil
    var role = "AXMenuItem"
    var enabled: Bool? = true
    var actions = ["AXPress"]
    var character: String? = nil
    var modifiers: Int? = nil

    static func menu(_ title: String, _ items: [Self]) -> Self {
        .init(title: title, children: [.init(title: "", children: items)])
    }
    static func command(_ title: String, character: String = "n", modifiers: Int = 0) -> Self {
        .init(title: title, character: character, modifiers: modifiers)
    }
}

private func discoverCommand(_ entries: [FakeAXMenuNode], bundleID: String = "", language: String = "en", applicationMenuIndex: Int? = 0, valid: () -> Bool = { true }) -> NewWindowMenuCommand? {
    NewWindowMenuDiscovery<FakeAXMenuNode>(children: { $0.children }, command: {
        .init(title: $0.title, role: $0.role, enabled: $0.enabled, actions: $0.actions,
              commandCharacter: $0.character, commandModifiers: $0.modifiers)
    }, applicationMenuIndex: applicationMenuIndex, bundleIdentifier: bundleID, language: language).find(in: entries, validating: valid)?.command
}

@Test(.macOSTestApplication) func commandNExactTitleWinsBeforeKeyboardEquivalent() {
    let item = discoverCommand([.menu("App", []), .menu("Fichier", [.command("New")]),
                                .menu("Other", [.init(title: "New Window")])])
    #expect(item?.title == "New Window")
}

@Test(.macOSTestApplication, arguments: [("New Finder Window", "en"), ("Nouvelle fenêtre", "fr"), ("New Window", "fr")])
func commandNKnownCompleteTitles(pair: (String, String)) {
    let item = discoverCommand([.menu("App", []), .menu("Localized File", [.command(pair.0)])], language: pair.1)
    #expect(item?.isCommandN == true)
}

@Test(.macOSTestApplication) func commandNFileMenuUsesPositionAndRejectsBareCommandElsewhere() {
    let entries: [FakeAXMenuNode] = [.menu("App", []), .menu("Fichier", [.command("New")]),
                                    .menu("File", [.command("Other")])]
    #expect(discoverCommand(entries)?.title == "New")
    #expect(discoverCommand([.menu("Unknown", [.command("New")])], applicationMenuIndex: nil) == nil)
    #expect(discoverCommand([.menu("App", []), .menu("Fichier", []), .menu("Tools", [.command("New")])]) == nil)
}

@Test(.macOSTestApplication, arguments: [1, 2, 4, 8, 3, 16])
func commandNRejectsExtraOrMissingCommandModifiers(modifiers: Int) {
    #expect(discoverCommand([.menu("App", []), .menu("File", [.command("New", modifiers: modifiers)])]) == nil)
}

@Test(.macOSTestApplication) func commandNRejectsDisabledMissingAttributesAmbiguityAndUnpressableItems() {
    var disabled = FakeAXMenuNode.command("New"); disabled.enabled = false
    var unknown = FakeAXMenuNode.command("New"); unknown.enabled = nil
    var noPress = FakeAXMenuNode.command("New"); noPress.actions = []
    var wrongRole = FakeAXMenuNode.command("New"); wrongRole.role = "AXButton"
    var noModifiers = FakeAXMenuNode.command("New"); noModifiers.modifiers = nil
    var noCharacter = FakeAXMenuNode.command("New"); noCharacter.character = nil
    for item in [disabled, unknown, noPress, wrongRole, noModifiers, noCharacter, .command("New Tab", character: "t")] {
        #expect(discoverCommand([.menu("App", []), .menu("File", [item])]) == nil)
    }
    #expect(discoverCommand([.menu("App", []), .menu("File", [.command("New"), .command("New Document")])]) == nil)
    #expect(discoverCommand([]) == nil)
    #expect(discoverCommand([.menu("App", []), .menu("File", [.command("New")])], valid: { false }) == nil)
    #expect(discoverCommand(Array(repeating: .menu("Menu", []), count: 33)) == nil)
    #expect(discoverCommand([.menu("App", []), .menu("File", Array(repeating: .command("New"), count: 129))]) == nil)
}

@Test(.macOSTestApplication) func commandNAutomaticallyAcceptsAllowlistedGenericTitles() {
    for title in ["New", "New Document", "New File", "New Window"] {
        let item = discoverCommand([.menu("App", []), .menu("File", [.command(title)])])
        #expect(item?.title == title)
    }
}

@Test(.macOSTestApplication) func commandNFileFollowsApplicationMenuWhenAppleComesFirst() {
    let entries: [FakeAXMenuNode] = [.menu("Apple", []), .menu("TextEdit", [.command("Wrong")]),
                                    .menu("Fichier", [.command("New")]), .menu("File", [.command("Other")])]
    let discovery = NewWindowMenuDiscovery<FakeAXMenuNode>(children: { $0.children }, command: {
        .init(title: $0.title, role: $0.role, enabled: $0.enabled, actions: $0.actions,
              commandCharacter: $0.character, commandModifiers: $0.modifiers)
    }, applicationMenuIndex: 1)
    #expect(discovery.find(in: entries, validating: { true })?.command.title == "New")
    var withoutAnchor = discovery
    withoutAnchor.applicationMenuIndex = nil
    #expect(withoutAnchor.find(in: entries, validating: { true }) == nil)
}

/// A fake AX server that honors the timeout supplied to each blocking read.
@Test(.macOSTestApplication) @MainActor func commandNDelayedReaderBoundsReadsAndKeepsMainActorResponsive() async {
    let reads = Mutex(0)
    let workerStarted = Mutex(false)
    let mainActorProgress = Mutex(false)
    let heartbeat = Task { @MainActor in
        while !workerStarted.withLock({ $0 }) { await Task.yield() }
        mainActorProgress.withLock { $0 = true }
    }
    let result = await NewWindowMenuReadBudget.inBackground(seconds: 0.08) { budget in
        #expect(!Thread.isMainThread)
        workerStarted.withLock { $0 = true }
        let started = ProcessInfo.processInfo.systemUptime // real-time: measures the blocking reader integration budget
        let entries: [FakeAXMenuNode] = [.menu("App", []), .menu("File", [.command("New")]),
            .menu("Slow", Array(repeating: .command("Other"), count: 128))]
        let command = NewWindowMenuDiscovery<FakeAXMenuNode>(children: { node in budget.read { _ in node.children } }, command: { node in
            if node.title == "New" {
                return .init(title: node.title, role: node.role, enabled: node.enabled, actions: node.actions,
                    commandCharacter: node.character, commandModifiers: node.modifiers)
            }
            let character: String? = budget.read { timeout in
                #expect(timeout > 0 && timeout <= 0.05)
                reads.withLock { $0 += 1 }
                Thread.sleep(forTimeInterval: TimeInterval(timeout)) // real-time: simulates a blocking AX call honoring its messaging timeout
                return node.character
            }
            // A second AX attribute read after the deadline must never reach the server.
            let modifiers: Int? = budget.read { _ in reads.withLock { $0 += 1 }; return node.modifiers }
            return .init(title: node.title, role: node.role, enabled: node.enabled, actions: node.actions,
                commandCharacter: character, commandModifiers: modifiers)
        }).find(in: entries, validating: { budget.remaining > 0 })?.command
        return (command: command, elapsed: ProcessInfo.processInfo.systemUptime - started) // real-time: measures the blocking reader integration budget
    }
    let progressedDuringScan = mainActorProgress.withLock { $0 }
    await heartbeat.value
    #expect(progressedDuringScan)
    #expect(result.elapsed < 0.5)
    #expect(reads.withLock { $0 } <= 3)
    #expect(result.command?.title == "New") // A complete earlier candidate survives the final slow read.
}

@Test(.macOSTestApplication) func commandNDeadlineKeepsFoundFileCommandAndChecksBeforeEveryChildRead() {
    var permits = 5
    var reads = 0
    let entries: [FakeAXMenuNode] = [.menu("App", []), .menu("File", [.command("New")]), .menu("Slow", [])]
    let result = NewWindowMenuDiscovery<FakeAXMenuNode>(children: { node in
        reads += 1
        return node.children
    }, command: { node in
        .init(title: node.title, role: node.role, enabled: node.enabled, actions: node.actions,
            commandCharacter: node.character, commandModifiers: node.modifiers)
    }).find(in: entries, validating: { permits -= 1; return permits >= 0 })
    #expect(result?.command.title == "New")
    #expect(reads == 4)
}

@Test(.macOSTestApplication, arguments: ["com.apple.Notes", "com.apple.mail", "com.apple.MobileSMS", "com.apple.reminders"])
func commandNJustWorksUsesTitleAllowlistForEveryApp(bundleID: String) {
    let bare: [FakeAXMenuNode] = [.menu("App", []), .menu("File", [.command("New Note")])]
    #expect(discoverCommand(bare, bundleID: bundleID) == nil)
    let real: [FakeAXMenuNode] = [.menu("App", []), .menu("File", [.command("New Message"), .init(title: "New Viewer Window")])]
    #expect(discoverCommand(real, bundleID: bundleID)?.title == "New Viewer Window")
}

@Test(.macOSTestApplication, arguments: ["New Note", "New Message", "New Email", "New Document in Library", "New Reminder"])
func commandNJustWorksSkipsContentTitles(title: String) {
    #expect(discoverCommand([.menu("App", []), .menu("File", [.command(title)])]) == nil)
}

@Test(.macOSTestApplication) func commandNJustWorksPrefersLocalizedWindowOverBareCommand() {
    let entries: [FakeAXMenuNode] = [.menu("App", []), .menu("Fichier", [.command("Nouveau"), .init(title: "Nouvelle fenêtre")])]
    #expect(discoverCommand(entries, language: "fr")?.title == "Nouvelle fenêtre")
    let item = discoverCommand([.menu("App", []), .menu("File", [.command("New Document")])])
    #expect(item?.canRequestWindow(bundleIdentifier: "com.apple.TextEdit", language: "en") == true)
}

@Test(.macOSTestApplication, arguments: ["New Recording", "New Event", "New Card", "New Note", "New Message",
                  "New Board", "New Shortcut", "New To-Do", "Create", "New Private Window", ""])
func commandNSecurityRejectsUnlistedTitles(title: String) {
    #expect(discoverCommand([.menu("App", []), .menu("File", [.command(title)])]) == nil)
    #expect(!NewWindowMenuCommand(title: title, role: "AXMenuItem", enabled: true, actions: ["AXPress"],
        commandCharacter: "n", commandModifiers: 0).canRequestWindow(bundleIdentifier: "test.app", language: "en"))
}

@Test(.macOSTestApplication, arguments: [("Nouveau", "fr"), ("Nouveau document", "fr"), ("Nouveau fichier", "fr"),
    ("Neu", "de"), ("Neues Dokument", "de"), ("Neue Datei", "de"),
    ("Nuevo", "es"), ("Nuevo documento", "es"), ("Nuevo archivo", "es"),
    ("Nuovo", "it"), ("Nuovo documento", "it"), ("Nuovo file", "it"),
    ("新規", "ja"), ("新規書類", "ja"), ("新規ファイル", "ja")])
func commandNSecurityAcceptsOnlyCompleteLocalizedDocumentTitles(pair: (String, String)) {
    let entries: [FakeAXMenuNode] = [.menu("App", []), .menu("File", [.command(pair.0)])]
    #expect(discoverCommand(entries, language: pair.1)?.title == pair.0)
    #expect(discoverCommand(entries, language: "en") == nil)
    #expect(discoverCommand([.menu("App", []), .menu("File", [.init(title: pair.0)])], language: pair.1) == nil)
}

// These tests inspect key state or share a real-key fixture; run only while the Mac is unattended.
// Add only reviewed real-key or activation cases; keep all other tests in default suites and update NativeLaneMembership.
@Suite(.enabled(if: NativeFocusTestLane.isEnabled, "Requires an unattended Mac; set BETTERTILE_NATIVE_FOCUS_TESTS=1"), .nativeFocus)
@MainActor struct NativeFocusPaneApplicationControlsTests {
    @Test(.macOSTestApplication, .macOSUI, arguments: TabbedStripPresentation.allCases, [false, true]) @MainActor
    func paneLauncherPlusControlsHaveAccessibleKeyboardAndOwnerGuards(presentation: TabbedStripPresentation, populated: Bool) throws {
        _ = NSApplication.shared
        var state = TabbedLayoutState(preset: .single, presentation: presentation)
        let window = WindowID(rawValue: "fixture")
        if populated { state.reconcile(windowIDs: [window], removed: [], focused: window) }
        var panels: [NSPanel] = []
        let overlay = TabbedOverlayController(panelFactory: {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panels.append(panel)
            return panel
        }, addGlobalKeyMonitor: { _ in nil }, addLocalKeyMonitor: { _ in nil })
        defer { overlay.hide() }
        overlay.refresh(state: state, bounds: BTRect(x: 12000, y: 0, width: 450, height: 260), windows: [])
        let pane = try #require(panels.compactMap { $0.contentView as? TabbedPaneView }.first)
        if presentation == .autoHide { overlay.holdApplicationPicker(state.activePaneID, enabled: true) }
        pane.layoutSubtreeIfNeeded()
        pane.content.layoutSubtreeIfNeeded()
        let add = pane.content.addButton
        #expect(add.accessibilityLabel()?.contains("Add app to pane") == true)
        #expect(!add.isHidden)
        #expect(add.frame.minX >= pane.stripLayout.tabFrame(0).maxX || !populated)
        var requests: [UUID] = []
        overlay.onAddApplication = { paneID, _, _ in requests.append(paneID) }
        try performNativeClick(add)
        #expect(requests == [state.activePaneID])
        if !populated {
            try performNativeClick(pane.content.emptyAddButton)
            #expect(requests.count == 2)
        }
        let plus = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift,
            timestamp: 0, windowNumber: pane.window!.windowNumber, context: nil,
            characters: "+", charactersIgnoringModifiers: "=", isARepeat: false, keyCode: 24))
        #expect(pane.window?.makeFirstResponder(pane) == true)
        pane.window?.sendEvent(plus)
        #expect(requests.count == (populated ? 2 : 3))
        let before = requests.count
        overlay.acceptsTabDrags = false
        try performNativeClick(add)
        #expect(requests.count == before + 1) // App selection has its own model placement gate.
        overlay.prepareForSpaceChange()
        try performNativeClick(add)
        #expect(requests.count == before + 1)
        overlay.hide()
        overlay.acceptsTabDrags = true
        try performNativeClick(add)
        #expect(requests.count == before + 1) // An old offscreen owner cannot reopen a picker.
    }
}
