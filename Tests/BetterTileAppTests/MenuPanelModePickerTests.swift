import AppKit
import BetterTileCore
import SwiftUI
import Testing
@testable import BetterTileApp
@testable import BetterTileMacOS

@Suite(.appTestApplication, .serialized, .settingsUI) @MainActor struct MenuPanelModePickerTests {
    private func key(_ code: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
    }

    @Test(arguments: [false, true])
    func drawnSegmentsKeepNativeHeightEqualWidthsAndGlyphSpacing(dark: Bool) throws {
        _ = NSApplication.shared
        let original = NSApp.appearance
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        defer { NSApp.appearance = original }
        let control = MenuPanelModeControl(selection: .linked)
        let window = OffscreenTestWindow(contentRect: NSRect(x: 12000, y: 0, width: 284, height: 24),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSApp.appearance
        window.contentView = control
        defer { window.close() }
        control.layoutSubtreeIfNeeded()
        let native = NSSegmentedControl(labels: LayoutMode.availableModes.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
        #expect(control.frame.size == NSSize(width: 284, height: 24))
        #expect(control.frame.height == native.fittingSize.height)
        #expect(control.buttons.count == 3 && control.selection == .manual)
        #expect(control.buttons.map(\.title) == LayoutMode.availableModes.map(\.title))
        for (index, button) in control.buttons.enumerated() {
            #expect(abs(button.frame.width - 284.0 / 3) < 0.000001)
            #expect(abs(button.frame.minX - Double(index) * 284.0 / 3) < 0.000001)
            let rects = button.contentRects()
            #expect(rects.glyph.width == LayoutModePicker.glyphSize)
            #expect(rects.title.minX - rects.glyph.maxX == 4)
            #expect(rects.glyph.minX >= 0 && rects.title.maxX <= button.bounds.width)
            #expect(button.isSelected == (index == 0))
            #expect(button.focusRingMaskBounds == button.bounds)
            #expect(button.fillRect == (index == 0 ? button.bounds.insetBy(dx: 2, dy: 2) : button.bounds))
            #expect(button.fillRadius == (index == 0 ? 4 : 6))
        }
        #expect(!window.isVisible && !window.isKeyWindow, Comment(rawValue: keyWindowDiagnostics(window)))
    }

    @Test(arguments: [false, true])
    func selectedModeUsesShadedAccentWithContrastInEveryPointerState(dark: Bool) throws {
        _ = NSApplication.shared
        let original = NSApp.appearance
        let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
        NSApp.appearance = appearance
        defer { NSApp.appearance = original }
        let control = MenuPanelModeControl(selection: .bento)
        for button in control.buttons {
            for (pressed, hovered) in [(false, false), (false, true), (true, true)] {
                let colors = button.palette(pressed: pressed, hovered: hovered)
                if button.mode != .bento {
                    #expect(colors.ink == NSColor.labelColor && colors.fill == nil)
                    continue
                }
                var ratio = 0.0
                appearance.performAsCurrentDrawingAppearance {
                    let fill = colors.fill!.usingColorSpace(.sRGB)!
                    let ink = colors.ink.usingColorSpace(.sRGB)!
                    let overlay = colors.overlay?.alphaComponent ?? 0
                    func luminance(_ rgb: [Double]) -> Double {
                        let linear = rgb.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
                        return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
                    }
                    let background = luminance([fill.redComponent, fill.greenComponent, fill.blueComponent].map { $0 * (1 - overlay) })
                    let foreground = luminance([ink.redComponent, ink.greenComponent, ink.blueComponent])
                    ratio = (max(background, foreground) + 0.05) / (min(background, foreground) + 0.05)
                }
                #expect(ratio >= 4.5)
                #expect(colors.overlay?.alphaComponent ?? 0 == (pressed ? 0.16 : hovered ? 0.08 : 0))
            }
        }
    }

    @Test func arrowsMoveFocusWithoutChangingModeAndActivationSelects() throws {
        _ = NSApplication.shared
        let control = MenuPanelModeControl(selection: .manual)
        var choices: [LayoutMode] = []
        control.onSelect = { choices.append($0); control.setSelection($0) }
        control.fullKeyboardAccess = { true }
        let window = OffscreenTestWindow(contentRect: NSRect(x: 12000, y: 0, width: 284, height: 24),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = control
        defer { window.close() }
        #expect(control.buttons.map(\.acceptsFirstResponder) == [true, false, false])
        #expect(window.makeFirstResponder(control.buttons[0]))
        window.recalculateKeyViewLoop()
        window.selectNextKeyView(nil)
        #expect(window.firstResponder === control.buttons[0]) // One Tab stop, with wraparound.
        control.buttons[0].keyDown(with: try key(124)) // Right
        #expect(control.selection == .manual && window.firstResponder === control.buttons[1])
        #expect(control.buttons.map(\.acceptsFirstResponder) == [false, true, false])
        control.buttons[1].keyDown(with: try key(125)) // Down
        control.buttons[2].keyDown(with: try key(124)) // Right at the end
        #expect(control.selection == .manual && window.firstResponder === control.buttons[2])
        #expect(control.buttons.map(\.acceptsFirstResponder) == [false, false, true])
        #expect(choices.isEmpty) // Traversing Adaptive must never retile the desktop.
        window.selectNextKeyView(nil)
        #expect(window.firstResponder === control.buttons[2])
        try withNativeEventLoop { control.buttons[2].keyDown(with: try self.key(49)) } // Space selects Tabbed directly.
        #expect(choices == [.tabbed] && control.selection == .tabbed)
        control.buttons[2].keyDown(with: try key(123)) // Left
        control.buttons[1].keyDown(with: try key(126)) // Up
        #expect(control.selection == .tabbed && window.firstResponder === control.buttons[0])
        #expect(choices == [.tabbed])
        try withNativeEventLoop { control.buttons[0].keyDown(with: try self.key(36)) } // Return
        try withNativeEventLoop { control.buttons[0].keyDown(with: try self.key(76)) } // Keypad Enter
        #expect(choices == [.tabbed, .manual, .manual])
        control.fullKeyboardAccess = { false }
        #expect(control.buttons.allSatisfy { !$0.acceptsFirstResponder })
        control.fullKeyboardAccess = { true }
        control.buttons[0].isEnabled = false
        #expect(!control.buttons[0].acceptsFirstResponder)
        #expect(!window.isVisible && !window.isKeyWindow, Comment(rawValue: keyWindowDiagnostics(window)))
    }

    @Test func refusedModeDoesNotChangeTheDisplayedSelection() throws {
        _ = NSApplication.shared
        let control = MenuPanelModeControl(selection: .manual)
        var choices: [LayoutMode] = []
        control.onSelect = { choices.append($0) } // The model refuses the request.
        try performNativeClick(control.buttons[2])
        #expect(choices == [.tabbed])
        #expect(control.selection == .manual)
        #expect(control.buttons.map(\.isSelected) == [true, false, false])
    }

    @Test func hostedBindingSnapsBackWhenTheModelRefusesAMode() throws {
        _ = NSApplication.shared
        var selected = LayoutMode.manual
        var acceptsRequest = false
        var requests: [LayoutMode] = []
        let binding = Binding(get: { selected }, set: { mode in
            requests.append(mode)
            if acceptsRequest { selected = mode }
        })
        let host = NSHostingView(rootView: MenuPanelModePicker(selection: binding).frame(width: 284))
        host.frame = NSRect(x: 0, y: 0, width: 284, height: 40)
        host.layoutSubtreeIfNeeded()
        let control = try #require(findControl(in: host))
        try performNativeClick(control.buttons[2])
        #expect(requests == [.tabbed] && selected == .manual)
        #expect(control.selection == .manual && control.buttons[0].isSelected)
        acceptsRequest = true
        try performNativeClick(control.buttons[1])
        #expect(requests == [.tabbed, .bento] && selected == .bento)
        #expect(control.selection == .bento && control.buttons[1].isSelected)
    }

    @Test func capturedBindingWaitsForTheAcceptedModelSnapshotWithoutFlashingBack() throws {
        _ = NSApplication.shared
        var modelMode = LayoutMode.manual
        var requests: [LayoutMode] = []
        func picker() -> MenuPanelModePicker {
            let captured = modelMode // Like MenuPanelControls' value from its parent body.
            return MenuPanelModePicker(selection: Binding(get: { captured }, set: {
                requests.append($0)
                modelMode = $0
            }))
        }
        let host = NSHostingView(rootView: picker().frame(width: 284))
        host.frame = NSRect(x: 0, y: 0, width: 284, height: 40)
        host.layoutSubtreeIfNeeded()
        let control = try #require(findControl(in: host))
        try performNativeClick(control.buttons[2])
        #expect(modelMode == .tabbed && requests == [.tabbed])
        // No optimistic Tabbed frame can be followed by a stale Manual readback.
        #expect(control.selection == .manual && control.buttons[0].isSelected)
        host.rootView = picker().frame(width: 284)
        host.layoutSubtreeIfNeeded()
        #expect(control.selection == .tabbed && control.buttons[2].isSelected)
        host.layoutSubtreeIfNeeded()
        #expect(control.selection == .tabbed && requests == [.tabbed])
    }

    @Test func settingsPreviewDoesNotTakeKeyboardFocusOrSelect() throws {
        _ = NSApplication.shared
        let preview = MenuPanelControls(hasAccessibilityPermission: true, activeMode: .manual,
            contextDescription: "Current desktop", snappingEnabled: true, setMode: nil,
            setSnappingEnabled: nil, repairLayout: nil, openSetup: nil)
        let host = NSHostingView(rootView: preview.frame(width: 284))
        host.frame = NSRect(x: 0, y: 0, width: 284, height: 200)
        host.layoutSubtreeIfNeeded()
        let control = try #require(findControl(in: host))
        control.fullKeyboardAccess = { true }
        #expect(control.buttons.allSatisfy { !$0.acceptsFirstResponder })
        try performNativeClick(control.buttons[2])
        #expect(control.selection == .manual)
    }

    private func findControl(in view: NSView) -> MenuPanelModeControl? {
        if let control = view as? MenuPanelModeControl { return control }
        return view.subviews.lazy.compactMap { findControl(in: $0) }.first
    }

    @Test func mouseActivationAndExternalSelectionStayInSync() throws {
        _ = NSApplication.shared
        let control = MenuPanelModeControl(selection: .manual)
        var choices: [LayoutMode] = []
        control.onSelect = { choices.append($0); control.setSelection($0) }
        try performNativeClick(control.buttons[2])
        #expect(choices == [.tabbed] && control.selection == .tabbed)
        #expect(control.buttons.map(\.isSelected) == [false, false, true])
        control.setSelection(.bento)
        #expect(choices == [.tabbed]) // A model refresh must not send another action.
        #expect(control.buttons.map(\.isSelected) == [false, true, false])
        control.setSelection(.linked)
        #expect(control.buttons.map(\.isSelected) == [true, false, false])
    }
}
