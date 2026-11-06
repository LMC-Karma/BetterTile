import BetterTileCore
import Testing
@testable import BetterTileApp

@Test(.appTestApplication) func generalSettingsSearchPreservesEveryPreviouslySearchableTerm() {
    let previousKeywords = """
        permission accessibility dock icon classic ice blue appearance light dark system drag snapping application update automatic check
        macos tiling move resize edge
        advanced enhanced user interface chromium electron voiceover
        """
    for term in previousKeywords.split(whereSeparator: \.isWhitespace) {
        #expect(SettingsDestination.general.matchesSearch(String(term)), "General must still match \(term)")
    }
}

@Test(.appTestApplication) func reorganizedGeneralControlsRemainSearchable() {
    let generalControls = [
        "Accessibility", "Request Access", "Open Accessibility Settings", "Check Again",
        "Open Setup Assistant", "Version",
        "Automatically check for updates", "Check for Updates", "View Update", "Update available",
        "Appearance", "Show Dock icon", "App icon", "Classic", "Ice Blue", "Dark",
        "Enhanced accessibility", "Restore After Moving", "Leave Disabled", "License", "Third-Party Notices",
    ]
    for control in generalControls {
        #expect(SettingsDestination.general.matchesSearch(control), "General must contain \(control)")
    }
    for control in ["BetterTile Drag Snapping", "macOS window tiling", "Move", "Resize"] {
        #expect(SettingsDestination.snapZones.matchesSearch(control), "Snap Zones must contain \(control)")
        #expect(SettingsDestination.general.matchesSearch(control), "General must retain its destination link for \(control)")
    }
}

@Test(.appTestApplication) func generalTaskSectionsAndSummaryAreSearchable() {
    for section in [
        "BetterTile at a glance", "Default mode", "Enable window controls", "Start & personalize",
        "Keep BetterTile ready", "Compatibility", "Development details", "About BetterTile",
    ] {
        #expect(SettingsDestination.general.matchesSearch(section))
    }
}

@Test(.appTestApplication) func settingsSearchNormalizesQueriesAndPreservesDestinationMapping() {
    #expect(SettingsDestination.general.matchesSearch("  ACCESSIBILITY\n"))
    #expect(SettingsDestination.snapZones.matchesSearch("  DRAG SNAPPING  "))
    #expect(SettingsDestination.windowLayout.matchesSearch("Default mode"))
    #expect(SettingsDestination.windowLayout.matchesSearch("mode"))
    #expect(SettingsDestination.menuBar.matchesSearch("reorder"))
    #expect(SettingsDestination.layoutWheel.matchesSearch("middle click"))
    #expect(SettingsDestination.applicationRules.matchesSearch("exclude"))
    #expect(SettingsDestination.allCases.allSatisfy { $0.matchesSearch(" \n") })
    #expect(SettingsDestination.allCases.allSatisfy { !$0.matchesSearch("unmatched-setting-query") })
}

@Test(.appTestApplication) func integratedSettingsSearchKeepsReviewedFeatureTerms() {
    for preset in TabbedPreset.allCases {
        #expect(SettingsDestination.windowLayout.matchesSearch(preset.title), "The visible preset title must find Window Layout: \(preset.title)")
    }
    for term in ["Adaptive", "Manual", "Resize Preview", "Compact", "Auto-hide"] {
        #expect(SettingsDestination.windowLayout.matchesSearch(term))
    }
    for term in ["Activation area", "width", "size", "reach", "extension", "BetterTile Drag Snapping"] {
        #expect(SettingsDestination.snapZones.matchesSearch(term))
    }
    for term in ["Repair Layout", "Next Tab", "Move Tab"] {
        #expect(SettingsDestination.layoutWheel.matchesSearch(term))
    }
    #expect(SettingsDestination.applicationRules.matchesSearch("Adaptive"))
}

@Test(.appTestApplication, arguments: [
    (SettingsDestination.general, [
        "Startup", "Launch at login", "Show menu bar icon", "Show Dock icon", "App icon",
        "Appearance", "BetterTile appearance", "Keyboard", "Setup Assistant",
        "Updates", "Automatically check for updates", "BetterTile updates", "Development details",
        "Compatibility", "Enhanced accessibility", "Privacy", "What BetterTile can see", "About", "Version",
    ]),
    (.windowLayout, [
        "Window mode", "Default mode", "When a desktop has one window", "New window side", "Balance on new window",
        "Swap delay", "Apply starting layout", "Tab bar presentation", "Restore pane size when switching tabs",
        "Keep desktop modes when displays change", "Leave space for Dock", "Resize", "Resize adjacent windows together", "Window feedback", "Divider width",
        "Appearance", "Use Liquid Glass", "Glass transparency", "Pane gap", "Starting layout",
    ]),
    (.snapZones, [
        "Drag snapping", "Zones", "Activation area", "Window top",
        "Double-click the top of a window to maximize or restore", "Edge", "Reach", "Custom",
    ]),
    (.layoutWheel, [
        "Layout Wheel", "Open the wheel", "Keyboard modifiers", "Modifier keys", "Hold delay", "Mouse trigger",
        "Middle click", "Option + Middle click", "Content", "Custom", "Grouped", "Levels", "One Level", "Two Levels",
        "Edit wheel", "Visible fans", "All fans", "One fan", "Swap Inner and Outer Rings", "Reset Layout Wheel",
        "Group contents", "Wheel appearance", "Style", "Appearance", "Size", "Fine-Tuning", "Look", "Motion", "Feel",
        "Sub-menus", "Reset appearance",
    ]),
    (.applicationRules, ["Enabled", "Participation", "Matching live windows"]),
])
func everyVisibleRowLabelFindsItsPage(destination: SettingsDestination, labels: [String]) {
    for label in labels {
        #expect(destination.matchesSearch(label), "\(destination.rawValue) must match its row “\(label)”")
    }
}

@Test(.appTestApplication) func shortcutSearchRoutesToTheNewPage() {
    for term in ["left half", "shortcut", "keyboard", "enable", "disable", "master toggle",
                 "Show Tab Bar", "Next Tab", "Previous Tab", "Move Tab", "Reset All Shortcuts"] {
        #expect(SettingsDestination.shortcuts.matchesSearch(term))
    }
    for term in ["left half", "shortcut", "master toggle"] {
        #expect(!SettingsDestination.general.matchesSearch(term))
        #expect(!SettingsDestination.windowLayout.matchesSearch(term))
    }
    #expect(SettingsDestination.layoutWheel.matchesSearch("shortcut"))
    #expect(SettingsDestination(rawValue: "Window Layout") == .windowLayout)
    #expect(SettingsDestination(rawValue: "Shortcuts") == .shortcuts)
}
