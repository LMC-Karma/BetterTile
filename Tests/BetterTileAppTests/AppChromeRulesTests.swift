import AppKit
import Testing
@testable import BetterTileApp

/// The app appearance choice and the rules the menu panel's dismiss monitors apply.
@MainActor @Suite(.appTestApplication, .serialized) struct AppChromeRulesTests {
    @Test func appearanceChoicesKeepTheirTitlesStoredValuesAndOrder() {
        #expect(ColorModePreference.defaultsKey == "BetterTileAppAppearance")
        #expect(ColorModePreference.allCases.map(\.rawValue) == ["system", "light", "dark"])
        #expect(ColorModePreference.allCases.map(\.title) == ["System", "Light", "Dark"])
        #expect(ColorModePreference.allCases.map(\.id) == ColorModePreference.allCases)
    }

    @Test(arguments: [
        (nil, nil), ("system", nil), ("light", NSAppearance.Name.aqua), ("dark", .darkAqua), ("bogus", nil),
    ] as [(String?, NSAppearance.Name?)])
    func applyingTheStoredChoiceSetsTheApplicationAppearance(stored: String?, expected: NSAppearance.Name?) throws {
        let defaults = MemoryDefaults()
        if let stored { defaults.set(stored, forKey: ColorModePreference.defaultsKey) }
        _ = NSApplication.shared
        let previous = NSApp.appearance
        defer { NSApp.appearance = previous }
        // Start from the opposite override so a missing write is visible.
        NSApp.appearance = NSAppearance(named: expected == .aqua ? .darkAqua : .aqua)
        ColorModePreference.apply(defaults: defaults)
        #expect(NSApp.appearance?.name == expected)
    }

    @Test func anExplicitChoiceWinsOverTheStoredOne() throws {
        let defaults = MemoryDefaults()
        defaults.set("light", forKey: ColorModePreference.defaultsKey)
        _ = NSApplication.shared
        let previous = NSApp.appearance
        defer { NSApp.appearance = previous }
        ColorModePreference.apply(.dark, defaults: defaults)
        #expect(NSApp.appearance?.name == .darkAqua)
        ColorModePreference.apply(.system, defaults: defaults)
        #expect(NSApp.appearance == nil)
    }

    @Test func theStatusItemHitAreaGrowsFourPointsSidewaysAndEightVertically() {
        let button = NSRect(x: 1200, y: 1000, width: 24, height: 22)
        let area = MenuPanelDismissRules.statusItemHitArea(around: button)
        #expect(area == NSRect(x: 1196, y: 992, width: 32, height: 38))
        #expect(area.contains(NSPoint(x: 1196.5, y: 1029.5)))
        #expect(!area.contains(NSPoint(x: 1195.5, y: 1010)))
        #expect(!area.contains(NSPoint(x: 1210, y: 1030.5)))
    }

    @Test func clicksAndKeysFromSettingsOrSetupKeepThePanelOpen() {
        func window() -> NSWindow {
            let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 10, height: 10),
                                  styleMask: [.borderless], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            return window
        }
        let settings = window()
        let setup = window()
        let other = window()
        let excluded = [settings, setup]
        func rule(_ eventWindow: NSWindow?, keyDown: Bool, key: NSWindow?) -> Bool {
            MenuPanelDismissRules.comesFromExcludedWindow(
                eventWindow: eventWindow, isKeyDown: keyDown, keyWindow: key, excludedWindows: excluded)
        }
        #expect(rule(settings, keyDown: false, key: nil))
        #expect(rule(setup, keyDown: false, key: other))
        #expect(!rule(other, keyDown: false, key: settings), "A click elsewhere closes even while Settings is key")
        #expect(!rule(nil, keyDown: false, key: setup))
        #expect(rule(nil, keyDown: true, key: settings), "A key press while Settings is key")
        #expect(rule(other, keyDown: true, key: setup))
        #expect(!rule(other, keyDown: true, key: other))
        #expect(!rule(nil, keyDown: true, key: nil))
        #expect(!MenuPanelDismissRules.comesFromExcludedWindow(
            eventWindow: settings, isKeyDown: true, keyWindow: settings, excludedWindows: []))
    }
}
