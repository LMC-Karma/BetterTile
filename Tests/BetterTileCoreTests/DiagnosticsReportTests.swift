import Foundation
import Testing
@testable import BetterTileCore

@Suite struct DiagnosticsReportTests {
    private let environment = DiagnosticsReport.Environment(
        appVersion: "0.6.3", appBuild: "63", macOSVersion: "26.1", macOSBuild: "25B78", architecture: "arm64",
        accessibilityGranted: true, privateAPIsDisabled: false, automaticUpdateChecks: true)

    private let main = DisplaySnapshot(
        id: DisplayID(rawValue: "1"), frame: BTRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: BTRect(x: 0, y: 33, width: 1512, height: 949), scaleFactor: 2, isMain: true,
        persistentIdentifier: "37D8832A-2D66-02CA-B9F7-8F30A301B230")
    private let side = DisplaySnapshot(
        id: DisplayID(rawValue: "2"), frame: BTRect(x: -1920, y: -98.5, width: 1920, height: 1080),
        visibleFrame: BTRect(x: -1920, y: -73.5, width: 1920, height: 1055), scaleFactor: 1.5,
        persistentIdentifier: "9A1C0E44-SERIAL-UUID")

    private func configuration() -> BetterTileConfiguration {
        var c = BetterTileConfiguration()
        c.defaultLayoutMode = .bento
        c.snappingEnabled = true
        c.linkedResizeEnabled = false
        c.resizeFeedbackMode = .ghost
        c.bentoInnerGap = 8
        c.bentoNewWindowSide = .automatic
        c.bentoBalancesNewWindows = false
        c.defaultTabbedPreset = .columns
        c.tabbedEntryPlacement = .allInOnePane
        c.tabbedStripPresentation = .autoHide
        c.leavesSpaceForDock = true
        c.keepsDesktopLayoutsAcrossDisplays = true
        c.doubleClickTitleBarToMaximize = false
        c.keyboardShortcutsEnabled = true
        c.layoutWheel.isEnabled = true
        c.layoutWheel.style = .grouped
        c.layoutWheel.levelCount = .two
        c.layoutWheel.triggers = LayoutWheelTriggers(keyboardEnabled: true, keyboard: .modifiers,
                                                     modifiers: [.control, .option], mouse: .middleClick)
        c.overlayAppearance.useLiquidGlass = true
        c.enhancedUserInterfacePolicy = .disableAndRestore
        return c
    }

    private func sessions() -> [DisplayID: LayoutSession] {
        [main.id: LayoutSession(displayID: main.id, mode: .bento,
                                windowIDs: [WindowID(rawValue: "41"), WindowID(rawValue: "42"), WindowID(rawValue: "43")],
                                automaticallyFloatingWindowIDs: [WindowID(rawValue: "43")],
                                automaticWritesSuspended: true)]
    }

    @Test func formatsTheReport() {
        var log = DiagnosticsResultLog()
        log.record(kind: .success, title: "Pane added")
        log.record(kind: .failure, title: "Can’t fit this layout")
        let report = DiagnosticsReport(environment: environment, displays: [main, side], sessions: sessions(),
                                       configuration: configuration(), recentResults: log)
        #expect(report.text == """
        BetterTile diagnostics
        Contains no window titles, app names, file paths, user or computer names, or hardware identifiers.

        BetterTile: 0.6.3 (63)
        macOS: 26.1 (25B78)
        Architecture: arm64
        Accessibility permission: Granted
        Private APIs: On

        Displays: 2
        Display 1 (primary, keyboard focus): 1512 × 982 pt, scale 2x, origin 0, 0
          Mode: Adaptive
          Windows: 3, floating automatically: 1
          Follows a Saved Layout: No
          Automatic placement paused: Yes
        Display 2: 1920 × 1080 pt, scale 1.5x, origin -1920, -98.5
          Mode: no layout session yet

        Settings
        Default mode: Adaptive
        Snapping: On
        Linked resize: Off
        Resize feedback: Resize Preview
        Adaptive gap: 8 pt
        Adaptive new window side: Automatic
        Balance on new window: Off
        Tabbed preset: 2 Columns
        Tabbed entry: All in one pane
        Tab bar: Auto-hide
        Leave space for Dock: On
        Keep layouts across displays: On
        Double-click title bar to maximize: Off
        Keyboard shortcuts: On
        Layout Wheel: On, Grouped, Two Levels
        Layout Wheel keyboard trigger: Control + Option
        Layout Wheel mouse trigger: Middle click
        Liquid Glass overlays: On
        Enhanced accessibility: Restore After Moving
        App rules: 0
        Update checks: Automatic

        Recent results, newest first
        Failure: Can’t fit this layout
        Success: Pane added

        """)
    }

    @Test func reportsMissingFactsPlainly() {
        var env = environment
        env.accessibilityGranted = false
        env.privateAPIsDisabled = true
        env.automaticUpdateChecks = nil
        var c = configuration()
        c.layoutWheel.isEnabled = false
        c.layoutWheel.triggers = LayoutWheelTriggers(keyboardEnabled: true, keyboard: .rightControl, mouse: .off)
        let text = DiagnosticsReport(environment: env, displays: [], sessions: [:], configuration: c,
                                     recentResults: DiagnosticsResultLog()).text
        #expect(text.contains("Accessibility permission: Not granted\n"))
        #expect(text.contains("Private APIs: Off (disablePrivateAPIs is set)\n"))
        #expect(text.contains("Update checks: Not available in this build\n"))
        #expect(text.contains("Displays: 0\n"))
        #expect(text.contains("Layout Wheel: Off\n"))
        #expect(text.contains("Layout Wheel keyboard trigger: Right Control\n"))
        #expect(text.contains("Layout Wheel mouse trigger: Off\n"))
        #expect(text.hasSuffix("Recent results, newest first\nNone\n"))
    }

    /// `DisplaySnapshot.isMain` follows keyboard focus, so it can be a display
    /// other than the primary one. A live test found the report calling that
    /// display "main" while macOS's main display was another.
    @Test func separatesThePrimaryDisplayFromTheFocusedOne() {
        var primary = main
        primary.isMain = false
        var focused = side
        focused.isMain = true
        let text = DiagnosticsReport(environment: environment, displays: [primary, focused], sessions: [:],
                                     configuration: configuration(), recentResults: DiagnosticsResultLog()).text
        #expect(text.contains("Display 1 (primary): 1512 × 982 pt"))
        #expect(text.contains("Display 2 (keyboard focus): 1920 × 1080 pt"))
        #expect(!text.contains("(main)"))
    }

    /// Product text names the modes Manual, Adaptive and Tabbed.
    @Test(arguments: [(LayoutMode.manual, "Manual"), (.linked, "Manual"), (.bento, "Adaptive"), (.tabbed, "Tabbed")])
    func namesModesAsTheProductDoes(mode: LayoutMode, title: String) {
        var c = configuration()
        c.defaultLayoutMode = mode
        let text = DiagnosticsReport(environment: environment, displays: [main],
                                     sessions: [main.id: LayoutSession(displayID: main.id, mode: mode)],
                                     configuration: c, recentResults: DiagnosticsResultLog()).text
        #expect(text.contains("  Mode: \(title)\n"))
        #expect(text.contains("Default mode: \(title)\n"))
        for hidden in ["Bento", "bento", "Native", "Mode: Linked", "ghost"] { #expect(!text.contains(hidden)) }
    }

    /// Every identifying value that the inputs carry stays out of the text:
    /// window titles and app names in pill titles, bundle identifiers in app
    /// rules, Saved Layout names and files, shortcut labels and display UUIDs.
    @Test func leavesIdentifyingValuesOut() {
        let secrets = [
            "Quarterly Plan.docx", "Safari", "com.secret.Editor", "org.example.Private",
            "Board Meeting Layout", "/Users/alex/Library/Application Support/BetterTile/Layouts/board.json",
            "37D8832A-2D66-02CA-B9F7-8F30A301B230", "9A1C0E44-SERIAL-UUID", "alex",
        ]
        var c = configuration()
        c.applicationRules.set(.excludeFromBento, for: "com.secret.Editor")
        c.applicationRules.set(.excludeFromBento, for: "org.example.Private")
        c.layoutWheel.savedLayouts = [LayoutWheelSavedLayout(
            file: "/Users/alex/Library/Application Support/BetterTile/Layouts/board.json",
            name: "Board Meeting Layout")]
        var log = DiagnosticsResultLog()
        log.record(kind: .failure, title: "Quarterly Plan.docx is floating")
        log.record(kind: .success, title: "Board Meeting Layout applied")
        log.record(kind: .warning, title: "Displays look like the set for Board Meeting Layout")
        log.record(kind: .failure, title: "Safari doesn’t fit here")
        let report = DiagnosticsReport(environment: environment, displays: [main, side], sessions: sessions(),
                                       configuration: c, recentResults: log)
        for secret in secrets { #expect(!report.text.contains(secret), "\(secret)") }
        #expect(report.text.contains("App rules: 2\n"))
        #expect(report.recentResults.allSatisfy { $0.message == nil })
        #expect(report.text.contains("Failure: (title withheld because it can name a window)\n"))
    }
}

@Suite struct DiagnosticsResultLogTests {
    @Test func keepsTheLastFiveOldestFirst() {
        var log = DiagnosticsResultLog()
        for title in ["Pane added", "Pane removed", "Pane restored", "Adaptive arranged",
                      "Desktop changed", "Window changed", "Nothing to repair"] {
            log.record(kind: .success, title: title)
        }
        #expect(log.entries.map(\.message) == ["Pane restored", "Adaptive arranged", "Desktop changed",
                                                "Window changed", "Nothing to repair"])
    }

    @Test func ignoresItsOwnCopyResult() {
        var log = DiagnosticsResultLog()
        log.record(kind: .success, title: DiagnosticsReport.copiedMessage)
        log.record(kind: .failure, title: DiagnosticsReport.copyFailedMessage)
        #expect(log.entries.isEmpty)
    }

    @Test(arguments: [
        ("1 window returned to a pane", true), ("12 windows returned to panes", true),
        ("Notes window returned to a pane", false), ("١ window returned to a pane", false),
        ("Pane added ", false), ("pane added", false), ("Report.pdf is floating", false), ("", false),
    ])
    func keepsOnlyFixedTitles(title: String, kept: Bool) {
        #expect((DiagnosticsResultLog.reportableTitle(title) != nil) == kept)
    }
}
