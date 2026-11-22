import Foundation

/// The outcome of one recent Result pill, as Copy Diagnostics reports it.
public enum DiagnosticsResultKind: String, Equatable, Sendable {
    case success, warning, failure

    var title: String {
        switch self {
        case .success: "Success"
        case .warning: "Warning"
        case .failure: "Failure"
        }
    }
}

/// One recent Result pill. `message` is set only for BetterTile's own fixed
/// titles. A title that can name a window, an app or a Saved Layout is withheld.
public struct DiagnosticsResult: Equatable, Sendable {
    public var kind: DiagnosticsResultKind
    public var message: String?

    public init(kind: DiagnosticsResultKind, message: String?) {
        self.kind = kind
        self.message = message
    }
}

/// The last few Result pills, kept in memory for Copy Diagnostics only.
///
/// The log decides at record time what it keeps, so a window title is never
/// stored here. Pill details are never recorded: they can quote a window title
/// or a system error.
public struct DiagnosticsResultLog: Equatable, Sendable {
    public static let capacity = 5
    /// Oldest first.
    public private(set) var entries: [DiagnosticsResult] = []

    public init() {}

    public mutating func record(kind: DiagnosticsResultKind, title: String) {
        // The result of a copy is not a desktop result.
        guard title != DiagnosticsReport.copiedMessage, title != DiagnosticsReport.copyFailedMessage else { return }
        entries.append(DiagnosticsResult(kind: kind, message: Self.reportableTitle(title)))
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
    }

    /// Returns `title` when it is one of BetterTile's fixed Result pill titles.
    /// Any other title can contain a window title, an app name or a Saved Layout
    /// name, so it returns nil.
    public static func reportableTitle(_ title: String) -> String? {
        if fixedTitles.contains(title) { return title }
        // "1 window returned to a pane" or "3 windows returned to panes".
        let parts = title.split(separator: " ", maxSplits: 1)
        if parts.count == 2, parts[0].allSatisfy(\.isASCII), Int(parts[0]) != nil,
           ["window returned to a pane", "windows returned to panes"].contains(String(parts[1])) {
            return title
        }
        return nil
    }

    /// Result pill titles that never contain user text. Keep this list in step
    /// with `ResultPillFeedback.failure(_:)` and the planners' fixed titles.
    static let fixedTitles: Set<String> = [
        // Successes.
        "Layout applied", "Layout restored", "Nothing to repair", "Pane added", "Pane removed", "Pane restored",
        "Existing panes adopted", "Adaptive arranged", "Adaptive panes repaired", "Adaptive panes retiled",
        "Shortcut layout repaired", "Stored Adaptive layout repaired",
        // Failures with fixed titles.
        "Couldn’t enter Tabbed", "Stopped waiting for a click",
        // Focus mode warnings when a peer window does not come back.
        "Layout partly restored", "Layout partly applied",
        // `ResultPillFeedback.failure(_:)` reduces every error to one of these.
        "Accessibility required", "App is ignored", "Tabbed not active", "Focus a tab to use tab commands.",
        "Adaptive not active", "No eligible window", "Adaptive is full", "Can’t fit this layout",
        "Window refused this size", "Choose Single Pane", "Use Tabbed Undo", "Float this window first",
        "Use Repair Layout", "Desktop changed", "Window changed", "Couldn’t apply layout",
    ]
}

/// A plain-text report that a user copies into a bug report.
///
/// It holds versions, display geometry, layout modes, window counts and a
/// short list of settings. It never holds window titles, app names or bundle
/// identifiers, document names or paths, user or computer names, serial
/// numbers, or display and hardware identifiers. The initializers read only
/// the fields they report, so other values in their inputs cannot reach the text.
public struct DiagnosticsReport: Equatable, Sendable {
    public static let copiedMessage = "Diagnostics copied"
    public static let copyFailedMessage = "Couldn’t copy diagnostics"

    public struct Environment: Equatable, Sendable {
        public var appVersion: String
        public var appBuild: String
        public var macOSVersion: String
        public var macOSBuild: String
        public var architecture: String
        public var accessibilityGranted: Bool
        /// The `disablePrivateAPIs` user default.
        public var privateAPIsDisabled: Bool
        /// Nil when this build has no updater, as in Debug builds.
        public var automaticUpdateChecks: Bool?

        public init(appVersion: String, appBuild: String, macOSVersion: String, macOSBuild: String,
                    architecture: String, accessibilityGranted: Bool, privateAPIsDisabled: Bool,
                    automaticUpdateChecks: Bool?) {
            self.appVersion = appVersion
            self.appBuild = appBuild
            self.macOSVersion = macOSVersion
            self.macOSBuild = macOSBuild
            self.architecture = architecture
            self.accessibilityGranted = accessibilityGranted
            self.privateAPIsDisabled = privateAPIsDisabled
            self.automaticUpdateChecks = automaticUpdateChecks
        }
    }

    public struct Display: Equatable, Sendable {
        /// 1-based, in the order macOS lists the displays.
        public var index: Int
        public var isMain: Bool
        /// Top-left logical points.
        public var frame: BTRect
        public var scaleFactor: Double
        /// Nil when BetterTile has no layout session on the display yet.
        public var mode: LayoutMode?
        public var managedWindowCount: Int
        public var automaticFloatCount: Int
        public var followsSavedLayout: Bool
        public var automaticPlacementPaused: Bool

        /// Reads only geometry from `display` and only mode, counts and flags from `session`.
        public init(index: Int, display: DisplaySnapshot, session: LayoutSession?) {
            self.index = index
            isMain = display.isMain
            frame = display.frame
            scaleFactor = display.scaleFactor
            mode = session?.mode.availableMode
            managedWindowCount = session?.windowIDs.count ?? 0
            automaticFloatCount = session?.automaticallyFloatingWindowIDs.count ?? 0
            followsSavedLayout = session?.followed != nil
            automaticPlacementPaused = session?.automaticWritesSuspended ?? false
        }
    }

    public struct Setting: Equatable, Sendable {
        public var name: String
        public var value: String

        public init(_ name: String, _ value: String) {
            self.name = name
            self.value = value
        }
    }

    public var environment: Environment
    public var displays: [Display]
    public var settings: [Setting]
    /// Newest first.
    public var recentResults: [DiagnosticsResult]

    public init(environment: Environment, displays: [DisplaySnapshot], sessions: [DisplayID: LayoutSession],
                configuration: BetterTileConfiguration, recentResults: DiagnosticsResultLog) {
        self.environment = environment
        self.displays = displays.enumerated().map { offset, display in
            Display(index: offset + 1, display: display, session: sessions[display.id])
        }
        settings = Self.settings(configuration: configuration,
                                 automaticUpdateChecks: environment.automaticUpdateChecks)
        self.recentResults = recentResults.entries.reversed()
    }

    /// Settings that change window behavior. App rules appear only as a count,
    /// because each rule names an app. Shortcuts, snap areas, Saved Layouts and
    /// App Groups are left out.
    static func settings(configuration c: BetterTileConfiguration, automaticUpdateChecks: Bool?) -> [Setting] {
        let wheel = c.layoutWheel
        let keyboardTrigger: String = if !wheel.triggers.keyboardEnabled {
            "Off"
        } else if wheel.triggers.keyboard == .rightControl {
            "Right Control"
        } else {
            modifierNames(wheel.triggers.modifiers)
        }
        let mouseTrigger = switch wheel.triggers.mouse {
        case .off: "Off"
        case .middleClick: "Middle click"
        case .optionMiddleClick: "Option + Middle click"
        }
        let updates = switch automaticUpdateChecks {
        case true?: "Automatic"
        case false?: "Manual"
        case nil: "Not available in this build"
        }
        return [
            Setting("Default mode", c.defaultLayoutMode.availableMode.title),
            Setting("Snapping", onOff(c.snappingEnabled)),
            Setting("Linked resize", onOff(c.linkedResizeEnabled)),
            Setting("Resize feedback", c.resizeFeedbackMode == .ghost ? "Resize Preview" : "Live Resize"),
            Setting("Adaptive gap", "\(number(c.bentoInnerGap)) pt"),
            Setting("Adaptive new window side", c.bentoNewWindowSide.rawValue.capitalized),
            Setting("Balance on new window", onOff(c.bentoBalancesNewWindows)),
            Setting("Tabbed preset", c.defaultTabbedPreset.title),
            Setting("Tabbed entry", c.tabbedEntryPlacement.title),
            Setting("Tab bar", c.tabbedStripPresentation.title),
            Setting("Leave space for Dock", onOff(c.leavesSpaceForDock)),
            Setting("Keep layouts across displays", onOff(c.keepsDesktopLayoutsAcrossDisplays)),
            Setting("Double-click title bar to maximize", onOff(c.doubleClickTitleBarToMaximize)),
            Setting("Keyboard shortcuts", onOff(c.keyboardShortcutsEnabled)),
            Setting("Layout Wheel", wheel.isEnabled
                ? "On, \(wheel.style == .grouped ? "Grouped" : "Custom"), "
                    + "\(wheel.levelCount == .one ? "One Level" : "Two Levels")"
                : "Off"),
            Setting("Layout Wheel keyboard trigger", keyboardTrigger),
            Setting("Layout Wheel mouse trigger", mouseTrigger),
            Setting("Liquid Glass overlays", onOff(c.overlayAppearance.useLiquidGlass)),
            Setting("Enhanced accessibility", c.enhancedUserInterfacePolicy.title),
            Setting("App rules", "\(c.applicationRules.entries.count)"),
            Setting("Update checks", updates),
        ]
    }

    /// The report as plain text, in English, for a bug report.
    public var text: String {
        var lines = [
            "BetterTile diagnostics",
            "Contains no window titles, app names, file paths, user or computer names, or hardware identifiers.",
            "",
            "BetterTile: \(environment.appVersion) (\(environment.appBuild))",
            "macOS: \(environment.macOSVersion) (\(environment.macOSBuild))",
            "Architecture: \(environment.architecture)",
            "Accessibility permission: \(environment.accessibilityGranted ? "Granted" : "Not granted")",
            "Private APIs: \(environment.privateAPIsDisabled ? "Off (disablePrivateAPIs is set)" : "On")",
            "",
            "Displays: \(displays.count)",
        ]
        for display in displays {
            let frame = display.frame
            lines.append("Display \(display.index)\(display.isMain ? " (main)" : ""): "
                + "\(number(frame.size.width)) × \(number(frame.size.height)) pt, scale \(number(display.scaleFactor))x, "
                + "origin \(number(frame.minX)), \(number(frame.minY))")
            guard let mode = display.mode else {
                lines.append("  Mode: no layout session yet")
                continue
            }
            lines.append("  Mode: \(mode.title)")
            lines.append("  Managed windows: \(display.managedWindowCount), "
                + "automatic floats: \(display.automaticFloatCount)")
            lines.append("  Follows a Saved Layout: \(display.followsSavedLayout ? "Yes" : "No")")
            lines.append("  Automatic placement paused: \(display.automaticPlacementPaused ? "Yes" : "No")")
        }
        lines += ["", "Settings"]
        lines += settings.map { "\($0.name): \($0.value)" }
        lines += ["", "Recent results, newest first"]
        if recentResults.isEmpty { lines.append("None") }
        lines += recentResults.map { result in
            "\(result.kind.title): \(result.message ?? "(title withheld because it can name a window)")"
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func onOff(_ value: Bool) -> String { value ? "On" : "Off" }
}

private func modifierNames(_ modifiers: ShortcutModifiers) -> String {
    var names: [String] = []
    if modifiers.contains(.control) { names.append("Control") }
    if modifiers.contains(.option) { names.append("Option") }
    if modifiers.contains(.shift) { names.append("Shift") }
    if modifiers.contains(.command) { names.append("Command") }
    return names.joined(separator: " + ")
}

/// Whole numbers without a decimal point, others with up to two decimals.
private func number(_ value: Double) -> String {
    guard value.isFinite else { return "unknown" }
    if value == value.rounded() { return String(Int(value)) }
    var text = String(format: "%.2f", value)
    while text.hasSuffix("0") { text.removeLast() }
    return text
}
