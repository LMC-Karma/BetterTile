import AppKit
import BetterTileCore
import SwiftUI
import Testing
@testable import BetterTileApp

@MainActor @Suite(.appTestApplication, .serialized, .settingsUI) struct ShortcutsSettingsTests {
    @Test func masterSwitchUsesTheExistingFieldAndPreservesAssignments() {
        let model = makeModel(system: FakeAppWindowSystem())
        defer { model.shutdown() }
        let original = model.configuration
        let page = ShortcutsSettings(model: model)
        for enabled in [false, true] {
            page.keyboardShortcutsBinding.wrappedValue = enabled
            #expect(model.configuration.keyboardShortcutsEnabled == enabled)
            #expect(model.configuration.shortcuts == original.shortcuts)
        }
        #expect(model.configuration == original)
    }

    @Test func duplicateRejectionKeepsThePreviousBinding() throws {
        let model = makeModel(system: FakeAppWindowSystem())
        defer { model.shutdown() }
        let duplicate = try #require(model.configuration.shortcuts.first { $0.action == .rightHalf }?.shortcut)
        let original = model.configuration
        model.assign(shortcut: duplicate, to: .leftHalf)
        #expect(model.configuration == original)
        let message = try #require(model.statusMessage)
        let host = try SettingsSnapshotHost(
            ShortcutsSettings(model: model, shortcutError: (.leftHalf, message)),
            dark: false, width: 770, height: 900, fitHeight: false)
        defer { host.close() }
        #expect(try host.render().pixelsHigh >= 900)
        #expect(model.configuration == original)
    }

    @Test func rendersAllNineGroupsAndFortyOneActions() throws {
        let model = makeModel(system: FakeAppWindowSystem())
        defer { model.shutdown() }
        #expect(WindowActionGroup.allCases.count == 9)
        #expect(WindowActionGroup.flattenedActions.count == 41)
        #expect(Set(WindowActionGroup.flattenedActions) == Set(WindowAction.allCases))
        let page = ShortcutsSettings(model: model)
        #expect(page.filteredGroups.count == 9)
        #expect(page.filteredGroups.flatMap(page.filteredActions).count == 41)
        for group in WindowActionGroup.allCases {
            #expect(page.isExpanded(group) == (group == .halves || group == .thirds))
        }
        let search = ShortcutsSettings(model: model, search: "left half")
        #expect(search.filteredGroups.flatMap(search.filteredActions) == [.leftHalf])
        #expect(search.isExpanded(.halves))
        #expect(ShortcutsSettings(model: model, search: "no-such-action").filteredGroups.isEmpty)
        let host = try SettingsSnapshotHost(ShortcutsSettings(model: model, expandedGroups: Set(WindowActionGroup.allCases)), dark: false,
                                            width: 770, height: 2600, fitHeight: false)
        defer { host.close() }
        #expect(try host.render().pixelsWide >= 770)
    }

    @Test func inlineKeyCaptureRecordsModifiersAndEscapeCancels() throws {
        let view = InlineKeyCaptureNSView()
        var captured: BetterTileCore.KeyboardShortcut?
        var cancelled = false
        view.capture = { captured = $0 }
        view.cancel = { cancelled = true }
        func event(_ code: UInt16, characters: String) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [.control, .option], timestamp: 0, windowNumber: 0,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code))
        }
        view.keyDown(with: try event(4, characters: "h"))
        #expect(captured == .init(keyCode: 4, modifiers: [.control, .option], keyLabel: "h"))
        let previous = captured
        view.keyDown(with: try event(53, characters: "\u{1b}"))
        #expect(cancelled)
        #expect(captured == previous)
    }

    @Test func nativeSwitchChangesTheSameFieldWithoutChangingBindings() async throws {
        let model = makeModel(system: FakeAppWindowSystem())
        defer { model.shutdown() }
        let bindings = model.configuration.shortcuts
        let host = try SettingsSnapshotHost(ShortcutsSettings(model: model), dark: false,
                                            width: 770, height: 900, fitHeight: false)
        defer { host.close() }
        host.window.setFrameOrigin(CGPoint(x: 12000, y: 0))
        host.window.orderFront(nil)
        func switches(_ view: NSView) -> [NSView] {
            (String(describing: type(of: view)) == "PlatformSwitch" ? [view] : []) + view.subviews.flatMap(switches)
        }
        try await waitForSettingsUI("Shortcuts switch", in: host.view) { switches(host.view).count == 1 }
        let toggle = try #require(switches(host.view).first)
        let frame = toggle.convert(toggle.bounds, to: host.view)
        for enabled in [false, true] {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(with: type,
                    location: host.view.convert(CGPoint(x: frame.midX, y: frame.midY), to: nil),
                    modifierFlags: [], timestamp: 0,
                    windowNumber: host.window.windowNumber, context: nil, eventNumber: 1,
                    clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
                try withNativeEventLoop { host.window.sendEvent(event) }
            }
            try await waitForSettingsUI("switch value \(enabled)", in: host.view) {
                model.configuration.keyboardShortcutsEnabled == enabled
            }
            #expect(model.configuration.shortcuts == bindings)
        }
    }
}
