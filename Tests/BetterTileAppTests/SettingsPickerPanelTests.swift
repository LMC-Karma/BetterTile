import AppKit
import BetterTileCore
import SwiftUI
import Testing
@testable import BetterTileApp
@testable import BetterTileMacOS

@MainActor func panelViews<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] {
    // Native glass hosts its controls in contentView, which is not part of subviews.
    let hosted = (root as? NSGlassEffectView)?.contentView.map { [$0] } ?? []
    return ((root as? T).map { [$0] } ?? []) + (root.subviews + hosted).flatMap { panelViews($0, type) }
}

@MainActor func panelReady(_ root: NSView, _ condition: () -> Bool) async throws {
    try await waitForSettingsUI("the Settings picker's expected state", in: root, timeout: .seconds(5), until: condition)
}

@MainActor private func panelKey(_ window: NSWindow, _ text: String, code: UInt16, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
        timestamp: 0, windowNumber: window.windowNumber, context: nil,
        characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
}

@MainActor private func panelParent() -> NSWindow {
    _ = NSApplication.shared
    let window = OffscreenTestWindow(contentRect: NSRect(x: 12000, y: 0, width: 980, height: 700),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    return window
}

@Suite(.appTestApplication, .serialized, .settingsUI) @MainActor struct SettingsPickerPanelTests {
    @Test(arguments: [false, true])
    func hostBlocksOnlyItsParentAndRestoresFocus(dark: Bool) throws {
        let parent = panelParent(), other = panelParent()
        parent.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let original = NSButton(title: "Settings", target: nil, action: nil)
        parent.contentView?.addSubview(original)
        #expect(parent.makeFirstResponder(original))
        let child = NSButton(title: "Choose", target: nil, action: nil)
        var dismissals = 0
        let controller = SettingsPickerController(content: child, size: NSSize(width: 420, height: 520),
                                                   appearance: .init()) { dismissals += 1 }
        defer { controller.dismiss(); parent.close(); other.close() }
        controller.present(over: parent)
        let panel = controller.panel, backing = controller.glass.backing
        backing.displayOptions = { (false, false) }; backing.refreshAppearance()
        #expect(panel.canBecomeKey && !panel.canBecomeMain)
        #expect(!panel.isOpaque && panel.backgroundColor == .clear)
        #expect(panel.parent === parent && parent.childWindows?.contains(panel) == true)
        #expect(backing.glass.contentView.map { child.isDescendant(of: $0) } == true)
        #expect(abs(panel.frame.midX - parent.frame.midX) < 1)
        let parentContent = try #require(parent.contentView)
        #expect(parentContent.subviews.count == 2) // Settings control and the dim/input blocker.
        #expect(parentContent.hitTest(NSPoint(x: 50, y: 50)) !== original)
        #expect(controller.route(try panelKey(parent, "a", code: 0)) == nil)
        let inside = try panelKey(panel, "a", code: 0)
        #expect(controller.route(inside) === inside)
        let unrelated = try panelKey(other, "a", code: 0)
        #expect(controller.route(unrelated) === unrelated)
        let mouse = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 30, y: 30),
            modifierFlags: [], timestamp: 0, windowNumber: parent.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
        #expect(controller.route(mouse) == nil)

        // Existing-view transitions retain controls and hit targets at every fallback.
        for option in [(true, false), (false, true), (false, false)] {
            backing.displayOptions = { option }
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
            #expect(backing.showsGlass == !(option.0 || option.1))
            #expect(backing.plateOpacity == (option.0 || option.1 ? 1 : (dark ? 0.35 : 0.20)))
            #expect(child.window === panel && !child.isHiddenOrHasHiddenAncestor)
            #expect(controller.glass.hitTest(NSPoint(x: 200, y: 200)) === child)
        }
        controller.glass.overlayAppearance = .init(useLiquidGlass: false)
        #expect(!backing.showsGlass && backing.plateOpacity == 1)
        controller.glass.overlayAppearance = .init(strength: 1)
        #expect(backing.showsGlass && backing.plateOpacity == (dark ? 0.35 : 0.22))
        controller.glass.overlayAppearance = .init(strength: 0)
        #expect(backing.showsGlass && backing.plateOpacity == (dark ? 0.35 : 0.20))
        parent.setFrameOrigin(NSPoint(x: 13000, y: 50))
        NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: parent)
        #expect(abs(panel.frame.midX - parent.frame.midX) < 1)
        panel.cancelOperation(nil)
        #expect(dismissals == 1 && panel.parent == nil && controller.parent == nil)
        #expect(parent.firstResponder === original)
        #expect(parentContent.subviews == [original])
        #expect(!parent.isVisible && !panel.isVisible && !parent.isKeyWindow && !panel.isKeyWindow, Comment(rawValue: keyWindowDiagnostics(parent) + "; " + keyWindowDiagnostics(panel)))
    }

    enum Exit: CaseIterable { case cancel, parentClose, spaceChange, replacement }
    @Test(arguments: Exit.allCases)
    func everyExitDetachesAndCanReopen(exit: Exit) {
        let parent = panelParent()
        var dismissals = 0
        let first = SettingsPickerController(content: NSView(), size: NSSize(width: 430, height: 480), appearance: .init()) {
            dismissals += 1
        }
        first.present(over: parent)
        switch exit {
        case .cancel: first.panel.cancelOperation(nil)
        case .parentClose: parent.close()
        case .spaceChange: NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        case .replacement: break
        }
        let second = SettingsPickerController(content: NSView(), size: NSSize(width: 430, height: 480), appearance: .init()) {}
        second.present(over: parent)
        #expect(dismissals == 1)
        #expect(first.panel.parent == nil)
        #expect(parent.childWindows == [second.panel])
        first.dismiss()
        #expect(dismissals == 1)
        second.dismiss()
        #expect(parent.childWindows?.isEmpty != false)
        #expect(parent.contentView?.subviews.isEmpty == true)
        parent.close()
        #expect(!first.panel.isVisible && !second.panel.isVisible)
    }

    enum SearchCancel: CaseIterable { case markedText, markedTextAfterQuery, query, empty, cancelButton }

    @Test(arguments: [true], SearchCancel.allCases)
    func escapeReachesSearchBeforePanel(addRule: Bool, state: SearchCancel) async throws {
        let parent = panelParent(), model = makeModel(system: FakeAppWindowSystem())
        let application = ApplicationChoice(bundleIdentifier: "test.alpha", name: "Alpha", url: URL(filePath: "/nonexistent/Alpha.app"))
        var readiness: ApplicationPickerReadiness?, dismissals = 0
        var controller: SettingsPickerController!
        let makePicker: (Set<String>, @escaping (ApplicationChoice) -> Void) -> ApplicationPicker = { exclusions, choose in
            var picker = ApplicationPicker(exclusions: exclusions, installedApplications: { [application] },
                runningApplications: { [] }, recentApplications: RecentApplications(defaults: MemoryDefaults()),
                resolveApplication: { _ in nil }, onChoose: choose)
            picker.onPresentationChange = { readiness = $0 }
            return picker
        }
        let content: AnyView
        content = AnyView(AddApplicationRuleSheet(makePicker: makePicker, model: model,
            onDismiss: { controller.dismiss() }, onAdd: { _ in Issue.record("Escape added a rule") }))
        let host = NSHostingView(rootView: content)
        controller = SettingsPickerController(content: host, size: NSSize(width: 430, height: 520), appearance: .init()) { dismissals += 1 }
        controller.present(over: parent)
        defer { controller.dismiss(); parent.close(); model.shutdown() }
        try await panelReady(host) { readiness?.isLoading == false && !panelViews(host, NSSearchField.self).isEmpty }
        let field = try #require(panelViews(host, NSSearchField.self).first)
        let editor = try #require(field.currentEditor() as? NSTextView)
        switch state {
        case .markedText, .markedTextAfterQuery:
            if state == .markedTextAfterQuery {
                editor.insertText("Al", replacementRange: editor.selectedRange())
                try await panelReady(host) { field.stringValue == "Al" && readiness?.highlight == "Results:test.alpha" }
            }
            editor.setMarkedText("あ", selectedRange: NSRange(location: 1, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
            #expect(editor.hasMarkedText())
        case .query, .cancelButton:
            editor.insertText("Al", replacementRange: editor.selectedRange())
            try await panelReady(host) { field.stringValue == "Al" && readiness?.highlight == "Results:test.alpha" }
        case .empty:
            #expect(field.stringValue.isEmpty)
        }
        if state == .cancelButton {
            // SwiftUI draws this button itself. Invoke its registered key equivalent
            // directly to test the Cancel action independently of the search editor.
            #expect(try withNativeEventLoop { controller.panel.performKeyEquivalent(with: try panelKey(controller.panel, "\u{1b}", code: 53)) })
        } else {
            try withNativeEventLoop { controller.panel.sendEvent(try panelKey(controller.panel, "\u{1b}", code: 53)) }
        }
        if state == .empty || state == .cancelButton {
            #expect(dismissals == 1 && controller.parent == nil)
        } else {
            #expect(!editor.hasMarkedText())
            #expect(dismissals == 0 && controller.parent === parent)
            let expected = state == .markedTextAfterQuery ? "Al" : ""
            #expect(field.stringValue == expected && editor.string == expected)
            #expect(controller.panel.firstResponder === editor)
            // Clearing also updates the SwiftUI query and restores the unfiltered rows.
            if expected.isEmpty {
                try await panelReady(host) { readiness?.highlight != "Results:test.alpha" }
            }
        }
    }











    @Test(arguments: [false, true], [120.0, 420.0])
    func popupActionWrappersKeepTwentyFourPointHeightInTallContainers(confirm: Bool, height: Double) async throws {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: HStack {
            if confirm {
                SettingsPickerConfirmButton(title: "Add Rule", isEnabled: true) {}
            } else {
                SettingsPickerCancelButton {}
            }
        }.frame(width: 260, height: height))
        let window = panelParent()
        defer { window.close() }
        window.setContentSize(NSSize(width: 260, height: height))
        window.contentView = host
        try await waitForSettingsUI("the action button", in: host) {
            panelViews(host, NSButton.self).first.map { $0.frame.height > 0 } ?? false
        }
        let button = try #require(panelViews(host, NSButton.self).first)
        #expect(button.title == (confirm ? "Add Rule" : "Cancel"))
        #expect(button.frame.height == 24, "Wrapper in \(height)-point container: \(button.frame)")
        #expect(abs(button.frame.width - button.intrinsicContentSize.width) <= 1)
        #expect(button.keyEquivalent == (confirm ? "\r" : "\u{1b}"))
        print("POPUP_WRAPPER confirm=\(confirm) container=\(height) frame=\(button.frame)")
        #expect(!window.isVisible && !window.isKeyWindow, Comment(rawValue: keyWindowDiagnostics(window)))
    }



    /// Background luminances measured behind the live native popup, held fixed while modelling the new foreground.
    /// This includes native material in the input; it does not predict new compositor pixels.
    @Test(arguments: [false, true])
    func liveForegroundContrastOnMismatchedBackdrops(dark: Bool) throws {
        let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
        func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        func srgb(_ v: Double) -> Double { v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055 }
        func luminance(_ c: NSColor, over background: Double) -> Double {
            let c = c.usingColorSpace(.sRGB)!, a = c.alphaComponent
            let rgb = [c.redComponent, c.greenComponent, c.blueComponent].map { linear(a * $0 + (1 - a) * srgb(background)) }
            return 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]
        }
        func ratio(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }
        appearance.performAsCurrentDrawingAppearance {
            for background in dark ? [0.117, 0.122, 0.168] : [0.367, 0.347, 0.251] {
                let browse = ratio(luminance(PickerText.browseLabelColor, over: background), background)
                #expect(browse >= 4.5, "Browse: \(browse):1 on \(background)")
                if ProcessInfo.processInfo.environment["BT_GLASS_CONTRAST_REPORT"] == "1" {
                    print("Contrast model \(dark ? "Dark" : "Light"), background \(background): Browse \(browse)")
                }
            }
            let field = luminance(.textBackgroundColor, over: 0)
            let placeholder = ratio(luminance(PickerText.searchPlaceholderColor(in: appearance), over: field), field)
            let typed = ratio(luminance(PickerText.searchLabelColor(in: appearance), over: field), field)
            #expect(placeholder >= 4.5 && typed > placeholder)
            let selection = luminance(PickerText.selectionBackgroundColor, over: 0)
            for text in [PickerText.selectedLabelColor, PickerText.selectedSecondaryLabelColor] {
                let contrast = ratio(luminance(text, over: selection), selection)
                #expect(contrast >= 4.5, "selection: \(contrast):1")
                if ProcessInfo.processInfo.environment["BT_GLASS_CONTRAST_REPORT"] == "1" {
                    print("Contrast model selected text: \(contrast)")
                }
            }
            for accent in [NSColor.systemBlue, .systemPurple, .systemPink, .systemRed, .systemOrange, .systemYellow, .systemGreen, .gray] {
                let background = luminance(PickerText.selectionBackground(for: accent), over: 0)
                #expect(ratio(luminance(PickerText.selectedLabelColor, over: background), background) >= 4.5)
            }
        }
    }




    @Test func addRuleKeepsBothStepsAndDefaultConfirmation() async throws {
        let parent = panelParent(), model = makeModel(system: FakeAppWindowSystem())
        var controller: SettingsPickerController!
        var selected: String?
        let application = ApplicationChoice(bundleIdentifier: "test.alpha", name: "Alpha", url: URL(filePath: "/nonexistent/Alpha.app"))
        var readiness: ApplicationPickerReadiness?
        let host = NSHostingView(rootView: AddApplicationRuleSheet(makePicker: { exclusions, choose in
            var picker = ApplicationPicker(exclusions: exclusions, installedApplications: { [application] },
                runningApplications: { [] }, recentApplications: RecentApplications(defaults: MemoryDefaults()),
                resolveApplication: { _ in nil }, onChoose: choose)
            picker.onPresentationChange = { readiness = $0 }
            return picker
        }, model: model, onDismiss: { controller.dismiss() }, onAdd: { selected = $0 }))
        controller = SettingsPickerController(content: host, size: NSSize(width: 420, height: 520), appearance: .init(), onDismiss: {})
        controller.present(over: parent)
        defer { controller.dismiss(); parent.close(); model.shutdown() }
        try await panelReady(host) { readiness?.isLoading == false }
        let field = try #require(panelViews(host, NSSearchField.self).first)
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.insertText("Alpha", replacementRange: editor.selectedRange())
        try await panelReady(host) { readiness?.highlight == "Results:test.alpha" }
        try withNativeEventLoop { controller.panel.sendEvent(try panelKey(controller.panel, "\r", code: 36)) }
        try await panelReady(host) { panelViews(host, NSSearchField.self).isEmpty }
        #expect(selected == nil && controller.parent === parent)
        let event = try panelKey(controller.panel, "\r", code: 36)
        #expect(try withNativeEventLoop { controller.panel.performKeyEquivalent(with: event) })
        try await panelReady(host) { selected != nil }
        #expect(model.configuration.applicationRules.configuredRule(for: application.id) == .excludeFromBento)
        #expect(controller.parent == nil)
    }

    @Test func swiftUIBindingOwnsPresentationAndCancellation() async throws {
        let parent = panelParent()
        let state = PanelBindingState()
        let host = NSHostingView(rootView: PanelBindingPage(state: state))
        parent.contentView = host
        defer { state.presented = false; parent.close() }
        for _ in 0..<2 {
            state.presented = true
            try await panelReady(host) { parent.childWindows?.first is SettingsPickerPanel }
            let panel = try #require(parent.childWindows?.first as? SettingsPickerPanel)
            #expect(!panel.isVisible && panel.isKeyWindow == false, Comment(rawValue: keyWindowDiagnostics(panel)))
            try withNativeEventLoop { panel.sendEvent(try panelKey(panel, "\u{1b}", code: 53)) }
            try await panelReady(host) { !state.presented && parent.childWindows?.isEmpty != false }
        }
    }

    /// A real Escape dismisses from inside the key event, before SwiftUI's binding turns false. Any
    /// update of the owning page in that gap must not present the picker again. Live, closing the
    /// panel refocuses Settings, which updates the page at this moment.
    @Test(arguments: [true])
    func pageUpdateAfterEscapeDismissDoesNotRepresentThePicker(addRule: Bool) async throws {
        let parent = panelParent()
        let state = PanelBindingState()
        let model = makeModel(system: FakeAppWindowSystem())
        let host = NSHostingView(rootView: PanelBindingPage(state: state, addRule: addRule, model: model))
        parent.contentView = host
        defer { state.presented = false; parent.close(); model.shutdown() }
        for use in 0..<2 {
            state.presented = true
            try await panelReady(host) { parent.childWindows?.first is SettingsPickerPanel }
            let panel = try #require(parent.childWindows?.first as? SettingsPickerPanel)
            let content = try #require(panel.contentView)
            try await panelReady(content) { panelViews(content, NSSearchField.self).first?.currentEditor() != nil }
            let field = try #require(panelViews(content, NSSearchField.self).first)
            #expect(field.stringValue.isEmpty)
            // A real key event, dispatched through the window to the active field editor.
            try withNativeEventLoop { panel.sendEvent(try panelKey(panel, "\u{1b}", code: 53)) }
            #expect(parent.childWindows?.isEmpty != false, "panel stays attached after Escape (use \(use))")
            // The page updates before the deferred binding change runs.
            state.tick += 1
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            // Let the deferred binding change run, then update the page once more.
            for _ in 0..<200 where state.presented { await Task.yield() }
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            #expect(!state.presented, "Escape left the picker presented (use \(use))")
            #expect(parent.childWindows?.isEmpty != false, "Escape presented a new picker (use \(use))")
        }
    }

    /// The deferred reset clears the self-dismiss guard. A presentation requested in the gap
    /// before the next page update must still present.
    @Test func presentationRightAfterTheDeferredResetIsNotSwallowed() async throws {
        let parent = panelParent()
        let state = PanelBindingState()
        let host = NSHostingView(rootView: PanelBindingPage(state: state))
        parent.contentView = host
        defer { state.presented = false; parent.close() }
        for use in 0..<3 {
            state.presented = true
            try await panelReady(host) { parent.childWindows?.first is SettingsPickerPanel }
            let panel = try #require(parent.childWindows?.first as? SettingsPickerPanel)
            let content = try #require(panel.contentView)
            try await panelReady(content) { panelViews(content, NSSearchField.self).first?.currentEditor() != nil }
            try withNativeEventLoop { panel.sendEvent(try panelKey(panel, "\u{1b}", code: 53)) }
            #expect(parent.childWindows?.isEmpty != false)
            // Run only the deferred binding reset: no page update happens before the next line.
            for _ in 0..<200 where state.presented { await Task.yield() }
            try #require(!state.presented, "the deferred reset did not run (use \(use))")
            state.presented = true
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            try await panelReady(host) { parent.childWindows?.first is SettingsPickerPanel }
            state.presented = false
            try await panelReady(host) { parent.childWindows?.isEmpty != false }
        }
    }

    @Test func pickerPresentsAgainAfterTheBindingClosesIt() async throws {
        let parent = panelParent()
        let state = PanelBindingState()
        let host = NSHostingView(rootView: PanelBindingPage(state: state))
        parent.contentView = host
        defer { state.presented = false; parent.close() }
        for _ in 0..<3 {
            state.presented = true
            try await panelReady(host) { parent.childWindows?.first is SettingsPickerPanel }
            state.presented = false
            try await panelReady(host) { parent.childWindows?.isEmpty != false }
        }
    }


    // These tests require a real key window; run only while the Mac is unattended.
    // Add only reviewed real-key or activation cases; keep all other tests in default suites and update NativeLaneMembership.
    @Suite(.enabled(if: NativeFocusTestLane.isEnabled, "Requires an unattended Mac; set BETTERTILE_NATIVE_FOCUS_TESTS=1"), .nativeFocus)
    @MainActor struct NativeFocus {
        @Test(arguments: [true])
        func liveSecondEscapeClosesAfterClearingQuery(addRule: Bool) async throws {
            let harness = LivePanelHarness(addRule: addRule)
            defer { harness.close() }
            try await harness.open()
            let field = try #require(panelViews(harness.host, NSSearchField.self).first)
            let editor = try #require(field.currentEditor() as? NSTextView)
            let commands = SearchCommandProbe(try #require(field.delegate))
            field.delegate = commands
            try harness.key("a", code: 0)
            try await panelReady(harness.host) { field.stringValue == "a" }
            try harness.key("\u{1b}", code: 53)
            try await panelReady(harness.host) { field.stringValue.isEmpty && harness.readiness?.highlight != "Results:test.alpha" }
            #expect(harness.controller.parent === harness.parent)
            #expect(harness.controller.panel.firstResponder === editor)
            try harness.key("\u{1b}", code: 53)
            #expect(harness.controller.parent == nil)
            #expect(harness.dismissals == 1)
            // Require explicit handling at the search delegate: NSSearchField may otherwise
            // swallow empty cancellation even though this OS's synthetic fallback dismisses.
            #expect(commands.cancelResults.last == true)
            #expect((harness.controller.panel as? OffscreenPickerPanel)?.cancelCommands == 1)
        }

        @Test(arguments: [true])
        func liveReopenedPanelAcceptsTypedKeys(addRule: Bool) async throws {
            let harness = LivePanelHarness(addRule: addRule)
            defer { harness.close() }
            for use in 0..<2 {
                try await harness.open(reusingContent: use > 0)
                let panel = harness.controller.panel
                let field = try #require(panelViews(harness.host, NSSearchField.self).first)
                let editor = try #require(field.currentEditor() as? NSTextView)
                #expect(panel.firstResponder === editor)
                try harness.key("a", code: 0)
                try await panelReady(harness.host) { field.stringValue == "a" && harness.readiness?.highlight == "Results:test.alpha" }
                #expect(editor.string == "a")
                editor.selectAll(nil); editor.insertText("", replacementRange: editor.selectedRange())
                try await panelReady(harness.host) { field.stringValue.isEmpty }
                harness.controller.dismiss()
                #expect(!panel.isKeyWindow, "closed panel retains key state after use \(use); \(keyWindowDiagnostics(panel))")
                #expect(panel.firstResponder !== editor, "closed panel retains its field editor")
            }
        }

        @Test(arguments: [false, true])
        func addRuleCancelUsesSecondaryOverlayButtonAtTwentyFourPointsInBothSteps(participation: Bool) async throws {
            let harness = LivePanelHarness(addRule: true)
            defer { harness.close() }
            try await harness.open()
            if participation {
                try harness.key("a", code: 0)
                try await panelReady(harness.host) { harness.readiness?.highlight == "Results:test.alpha" }
                try harness.key("\r", code: 36)
                try await panelReady(harness.host) { panelViews(harness.host, NSSearchField.self).isEmpty }
            }
            let cancel = try #require(panelViews(harness.host, OverlayButton.self).first { $0.title == "Cancel" })
            #expect(cancel.kind == .secondary)
            #expect(cancel.frame.height == 24, "Actual Add Rule Cancel height: \(cancel.frame.height) pt")
            #expect(abs(cancel.frame.width - cancel.intrinsicContentSize.width) <= 1)
            print("ADD_RULE_CANCEL step=\(participation ? 2 : 1) frame=\(cancel.frame)")
            #expect(cancel.keyEquivalent == "\u{1b}" && cancel.keyEquivalentModifierMask.isEmpty)
            try performNativeClick(cancel)
            #expect(harness.controller.parent == nil && harness.dismissals == 1)
            #expect(harness.selected == nil)
        }

        @Test(arguments: [false, true])
        func addRuleStepTwoCancelKeyDismissesExactlyOnce(commandPeriod: Bool) async throws {
            let harness = LivePanelHarness(addRule: true)
            defer { harness.close() }
            try await harness.open()
            try harness.key("a", code: 0)
            try await panelReady(harness.host) { harness.readiness?.highlight == "Results:test.alpha" }
            try harness.key("\r", code: 36)
            try await panelReady(harness.host) { panelViews(harness.host, NSSearchField.self).isEmpty }
            try harness.key(commandPeriod ? "." : "\u{1b}", code: commandPeriod ? 47 : 53,
                            flags: commandPeriod ? .command : [])
            try await panelReady(harness.host) { harness.controller.parent == nil }
            #expect(harness.dismissals == 1)
            #expect(harness.selected == nil)
            // A later close notification must not call the dismissal callback twice.
            harness.controller.panel.close()
            #expect(harness.dismissals == 1)
        }

        @Test func liveReturnConfirmsRuleThroughTheResponderChain() async throws {
            let harness = LivePanelHarness(addRule: true)
            defer { harness.close() }
            try await harness.open()
            try harness.key("a", code: 0)
            try await panelReady(harness.host) { harness.readiness?.highlight == "Results:test.alpha" }
            try harness.key("\r", code: 36)
            try await panelReady(harness.host) { panelViews(harness.host, NSSearchField.self).isEmpty }
            let cell = try #require(harness.controller.panel.defaultButtonCell)
            #expect(cell.isEnabled)
            #expect(cell.title == "Add Rule")
            try harness.key("\r", code: 36)
            try await panelReady(harness.host) { harness.selected == "test.alpha" }
            #expect(harness.controller.parent == nil)
        }


    }
}


@MainActor @Observable private final class PanelBindingState {
    var presented = false
    var tick = 0
}

private struct PanelBindingPage: View {
    @Bindable var state: PanelBindingState
    var addRule = true
    var model: BetterTileModel?
    var body: some View {
        // The page reads `tick`, so changing it updates the page and its panel anchor.
        Color.clear.overlay { Text("\(state.tick)").opacity(0) }
            .settingsPickerPanel(isPresented: $state.presented, size: NSSize(width: 430, height: 480), appearance: .init()) { dismiss in
                AddApplicationRuleSheet(model: model ?? makeModel(system: FakeAppWindowSystem()), onDismiss: dismiss) { _ in }
            }
    }
}

/// Nonactivating offscreen panels exercise native key dispatch without activating an app.
@MainActor final class LivePanelHarness {
    let parent: NSWindow = {
        _ = NSApplication.shared
        let parent = OffscreenSettingsParent(contentRect: NSRect(x: 12000, y: 0, width: 980, height: 700),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        return parent
    }()
    let model = makeModel(system: FakeAppWindowSystem())
    let addRule: Bool
    var host: NSHostingView<AnyView>!
    var controller: SettingsPickerController!
    var readiness: ApplicationPickerReadiness?
    var selected: String?
    var dismissals = 0

    init(addRule: Bool) { self.addRule = addRule }

    func open(reusingContent: Bool = false) async throws {
        if !reusingContent { readiness = nil }
        let application = ApplicationChoice(bundleIdentifier: "test.alpha", name: "Alpha", url: URL(filePath: "/nonexistent/Alpha.app"))
        let makePicker: (Set<String>, @escaping (ApplicationChoice) -> Void) -> ApplicationPicker = { [weak self] exclusions, choose in
            var picker = ApplicationPicker(exclusions: exclusions, installedApplications: { [application] },
                runningApplications: { [] }, recentApplications: RecentApplications(defaults: MemoryDefaults()),
                resolveApplication: { _ in nil }, onChoose: choose)
            picker.onPresentationChange = { self?.readiness = $0 }
            return picker
        }
        let dismiss = { [weak self] in self?.controller.dismiss() }
        let content: AnyView
        content = AnyView(AddApplicationRuleSheet(makePicker: makePicker, model: model,
            onDismiss: { dismiss() }, onAdd: { [weak self] in self?.selected = $0 }))
        if !reusingContent { host = NSHostingView(rootView: content) }
        let panel = OffscreenPickerPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        controller = SettingsPickerController(content: host, size: NSSize(width: 430, height: 520), appearance: .init(), panel: panel) { [weak self] in
            self?.dismissals += 1
        }
        parent.setFrameOrigin(NSPoint(x: 12000, y: 0))
        try #require(!NSScreen.screens.contains { $0.frame.intersects(parent.frame) })
        controller.present(over: parent)
        if reusingContent {
            let field = try #require(panelViews(host, NSSearchField.self).first)
            try #require(field.currentEditor() != nil, "reused search field lost its editor before reopening")
        }
        panel.setFrameOrigin(NSPoint(x: 12000, y: 0))
        try #require(!NSScreen.screens.contains { $0.frame.intersects(panel.frame) })
        panel.orderFrontForTesting()
        panel.makeKey()
        try #require(panel.isKeyWindow, Comment(rawValue: keyWindowDiagnostics(panel)))
        try await panelReady(host) { self.readiness?.isLoading == false && !panelViews(self.host, NSSearchField.self).isEmpty }
        #expect(!NSScreen.screens.contains { $0.frame.intersects(parent.frame) || $0.frame.intersects(panel.frame) })
    }

    func key(_ text: String, code: UInt16, flags: NSEvent.ModifierFlags = []) throws {
        try withNativeEventLoop { NSApp.sendEvent(try panelKey(self.controller.panel, text, code: code, flags: flags)) }
    }

    func close() { controller?.dismiss(); parent.close(); model.shutdown() }
}

@MainActor private final class OffscreenSettingsParent: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor private final class OffscreenPickerPanel: SettingsPickerPanel {
    var cancelCommands = 0
    override func cancelOperation(_ sender: Any?) { cancelCommands += 1; super.cancelOperation(sender) }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor private final class SearchCommandProbe: NSObject, NSSearchFieldDelegate {
    let original: NSSearchFieldDelegate
    var cancelResults: [Bool] = []
    init(_ original: NSSearchFieldDelegate) { self.original = original }
    func controlTextDidChange(_ notification: Notification) { original.controlTextDidChange?(notification) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let handled = original.control?(control, textView: textView, doCommandBy: selector) ?? false
        if selector == #selector(NSResponder.cancelOperation(_:)) { cancelResults.append(handled) }
        return handled
    }
}
