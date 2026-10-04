// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma
// Contains portions adapted from Vorssaint, Copyright (C) 2026 Vorssaint.

import AppKit
import BetterTileCore
import BetterTileMacOS
import os
import Sparkle
import SwiftUI

private enum BetterTileVariant {
    static var displayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "BetterTile"
    }

#if DEBUG
    static let configurationDirectoryName = "BetterTile Debug"
    static let siblingBundleIdentifier = "com.lmckarma.BetterTile"
    static let siblingDisplayName = "BetterTile"
#else
    static let configurationDirectoryName = "BetterTile"
    static let siblingBundleIdentifier = "com.lmckarma.BetterTile.debug"
    static let siblingDisplayName = "BetterTile Debug"
#endif
}

#if !DEBUG
@MainActor
@Observable
final class UpdatePresentationModel {
    private static let defaultsKey = "BetterTileAvailableUpdate"

    private let defaults: UserDefaults
    private(set) var state: UpdateIndicatorState

    init(defaults: UserDefaults = .standard, runningBuildVersion: String) {
        self.defaults = defaults
        let stored = defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode(UpdateIndicatorState.self, from: $0) }
            ?? .idle
        state = UpdateIndicator.restoredState(stored, runningBuildVersion: runningBuildVersion)
        persist()
    }

    func apply(_ event: UpdateIndicatorEvent) {
        state = UpdateIndicator.state(after: event, from: state)
        persist()
    }

    private func persist() {
        guard state != .idle else {
            defaults.removeObject(forKey: Self.defaultsKey)
            return
        }
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
#endif

enum AppAppearance: String, CaseIterable, Identifiable {
    static let defaultsKey = "BetterTileAppAppearance"

    case system
    case light
    case dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    @MainActor
    static func apply(_ appearance: AppAppearance? = nil) {
        let selected = appearance
            ?? UserDefaults.standard.string(forKey: defaultsKey).flatMap(AppAppearance.init(rawValue:))
            ?? .system
        NSApp.appearance = switch selected {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

enum AppIconStyle: String, CaseIterable, Identifiable {
    static let defaultsKey = "BetterTileAppIcon"

    case classic
    case ice

    var id: Self { self }
    var title: String { self == .classic ? "Classic" : "Ice Blue" }

    var resourceName: String {
        let name = self == .classic ? "AppIcon" : "AppIconIce"
#if DEBUG
        return name + "Debug"
#else
        return name
#endif
    }

    static func selected(in defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .classic
    }

    @MainActor
    var image: NSImage? { Bundle.main.image(forResource: resourceName) }

    @MainActor
    static func apply(_ style: Self? = nil) {
        let selected = style ?? selected()
        // nil restores the system-rendered primary Icon Composer icon.
        NSApp.applicationIconImage = selected == .classic ? nil : selected.image
        NSApp.dockTile.display()
    }
}

enum WindowActionGroup: String, CaseIterable, Identifiable {
    case halves
    case thirds
    case quarters
    case sixths
    case positionAndSize
    case move
    case resize
    case displaysAndRestore

    var id: Self { self }

    var title: String {
        switch self {
        case .halves: "Halves"
        case .thirds: "Thirds"
        case .quarters: "Quarters"
        case .sixths: "Sixths"
        case .positionAndSize: "Position & Size"
        case .move: "Move"
        case .resize: "Resize"
        case .displaysAndRestore: "Displays & Restore"
        }
    }

    var actions: [WindowAction] {
        switch self {
        case .halves:
            [.leftHalf, .rightHalf, .topHalf, .bottomHalf]
        case .thirds:
            [.leftThird, .centerThird, .rightThird, .leftTwoThirds, .rightTwoThirds]
        case .quarters:
            [.topLeftQuarter, .topRightQuarter, .bottomLeftQuarter, .bottomRightQuarter]
        case .sixths:
            [
                .topLeftSixth, .topCenterSixth, .topRightSixth,
                .bottomLeftSixth, .bottomCenterSixth, .bottomRightSixth,
            ]
        case .positionAndSize:
            [.maximize, .almostMaximize, .center, .centerResize]
        case .move:
            [.moveLeft, .moveRight, .moveUp, .moveDown]
        case .resize:
            [.growWidth, .shrinkWidth, .growHeight, .shrinkHeight]
        case .displaysAndRestore:
            [.previousDisplay, .nextDisplay, .restore]
        }
    }

    static func assertComplete() {
#if DEBUG
        let grouped = flattenedActions
        assert(grouped.count == Set(grouped).count, "Window actions must appear in one UI group only.")
        assert(Set(grouped) == Set(WindowAction.allCases), "Every window action must appear in the UI.")
#endif
    }

    static var flattenedActions: [WindowAction] { allCases.flatMap(\.actions) }
}

enum MenuPanelMetrics {
    static let width: CGFloat = 332
    static let padding: CGFloat = 14
    static let scrollContentInset: CGFloat = 12
    static let tileHeight: CGFloat = 60
    static let gap: CGFloat = 7
    static let tileWidth = (width - padding * 2 - gap) / 2
    static let maximumActionHeight: CGFloat = 328
    static let columns = [
        GridItem(.fixed(tileWidth), spacing: gap),
        GridItem(.fixed(tileWidth), spacing: gap),
    ]

    static func actionHeight(actionCount: Int, editing: Bool = false) -> CGFloat {
        let rows = CGFloat((max(0, actionCount) + 1) / 2)
        return rows == 0 ? 72 : rows * tileHeight + max(0, rows - 1) * gap + (editing ? 22 + gap : 0)
    }

    static func viewportHeight(actionCount: Int, editing: Bool, availableHeight: CGFloat, chromeHeight: CGFloat) -> CGFloat {
        min(actionHeight(actionCount: actionCount, editing: editing), maximumActionHeight,
            max(0, availableHeight - chromeHeight))
    }

}

@main
enum BetterTileApplication {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = BetterTileAppDelegate()
        application.delegate = delegate
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
private final class BetterTileAppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    private static let signposter = OSSignposter(
        subsystem: "com.lmckarma.BetterTile",
        category: "ApplicationUI"
    )

    private lazy var model = BetterTileModel(
        store: .defaultStore(directoryName: BetterTileVariant.configurationDirectoryName)
    )
#if !DEBUG
    private lazy var updatePresentation = UpdatePresentationModel(
        runningBuildVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    )
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: self,
        userDriverDelegate: self
    )
    private var mainUpdateMenuItem: NSMenuItem?
#endif
    private var modelStarted = false
    private let popover = NSPopover()
    private var popoverHost: NSHostingController<BetterTileMenuPanel>?
    private var statusItem: NSStatusItem!
    private var repairStatusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var setupWindow: NSWindow?
    private var globalDismissMonitor: Any?
    private var localDismissMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isRunningFromReadOnlyVolume else {
            showMoveToApplicationsAlertAndQuit()
            return
        }
        guard quitRunningSiblingIfNeeded() else { return }
        modelStarted = true
        _ = model
        WindowActionGroup.assertComplete()
        AppAppearance.apply()
        AppIconStyle.apply()
        installMainMenu()
        installStatusItem()
#if !DEBUG
        renderUpdateIndicator()
#endif
        configurePopover()
#if !DEBUG
        // Start the release updater only after the status item exists: its
        // delegate callbacks drive the update-available indicator.
        _ = updaterController
#endif
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let page = diagnosticSetupPage(arguments: arguments) {
            DispatchQueue.main.async { [weak self] in self?.presentSetupAssistant(page: page) }
            return
        } else if arguments.contains("--diagnostic-open-setup") {
            DispatchQueue.main.async { [weak self] in self?.presentSetupAssistant(page: .welcome) }
            return
        } else if let cycles = diagnosticCycleCount(prefix: "--diagnostic-cycle-popover=", arguments: arguments) {
            DispatchQueue.main.async { [weak self] in self?.cyclePopover(remaining: cycles) }
            return
        } else if let cycles = diagnosticCycleCount(prefix: "--diagnostic-cycle-settings=", arguments: arguments) {
            DispatchQueue.main.async { [weak self] in self?.cycleSettings(remaining: cycles) }
            return
        } else if arguments.contains("--diagnostic-open-settings") {
            DispatchQueue.main.async { [weak self] in self?.showSettings() }
            return
        } else if arguments.contains("--diagnostic-open-popover") {
            DispatchQueue.main.async { [weak self] in self?.showPopover() }
            return
        }
#endif
        showSetupAtLaunchIfNeeded()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showSettings()
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let settingsItem = NSMenuItem(
            title: "Open Settings…",
            action: #selector(showSettings),
            keyEquivalent: ""
        )
        settingsItem.target = self
        menu.addItem(settingsItem)
        return menu
    }

    func applicationWillTerminate(_ notification: Notification) {
        if modelStarted { model.shutdown() }
    }

    private var isRunningFromReadOnlyVolume: Bool {
        let values = try? Bundle.main.bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey])
        return ApplicationVolume.requiresRelocation(volumeIsReadOnly: values?.volumeIsReadOnly)
    }

    private func quitRunningSiblingIfNeeded() -> Bool {
        guard let sibling = NSRunningApplication.runningApplications(
            withBundleIdentifier: BetterTileVariant.siblingBundleIdentifier
        ).first(where: { !$0.isTerminated }) else { return true }

        var userChoseToQuitSibling: Bool?
        var terminationRequestAccepted: Bool?
        var deadline: Date?
        while true {
            let decision = SiblingApplicationLaunch.nextDecision(
                userChoseToQuitSibling: userChoseToQuitSibling,
                terminationRequestAccepted: terminationRequestAccepted,
                siblingIsTerminated: sibling.isTerminated,
                deadlinePassed: deadline.map { Date.now >= $0 } ?? false
            )
            switch decision {
            case .askUser:
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "\(BetterTileVariant.siblingDisplayName) Is Already Running"
                alert.informativeText = "Only one BetterTile variant can manage windows at a time."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Quit \(BetterTileVariant.siblingDisplayName) & Continue")
                alert.addButton(withTitle: "Quit \(BetterTileVariant.displayName)")
                userChoseToQuitSibling = alert.runModal() == .alertFirstButtonReturn
            case .requestTermination:
                terminationRequestAccepted = sibling.terminate()
                deadline = Date.now.addingTimeInterval(3)
            case .waitForTermination:
                let nextCheck = min(deadline ?? Date.now, Date.now.addingTimeInterval(0.05))
                RunLoop.current.run(mode: .default, before: nextCheck)
            case .continueLaunching:
                return true
            case .quitCurrentApplication:
                NSApp.terminate(nil)
                return false
            case .showTerminationFailure:
                showSiblingTerminationFailure()
                NSApp.terminate(nil)
                return false
            }
        }
    }

    private func showSiblingTerminationFailure() {
        NSApp.activate(ignoringOtherApps: true)
        let failure = NSAlert()
        failure.messageText = "Could Not Quit \(BetterTileVariant.siblingDisplayName)"
        failure.informativeText = "Quit it manually, then reopen \(BetterTileVariant.displayName)."
        failure.alertStyle = .warning
        failure.addButton(withTitle: "Quit \(BetterTileVariant.displayName)")
        failure.runModal()
    }

    private func showMoveToApplicationsAlertAndQuit() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Move BetterTile to Applications"
        alert.informativeText = "Drag BetterTile into the Applications folder before opening it so updates can be installed."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Applications")
        alert.addButton(withTitle: "Quit")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
        }
        NSApp.terminate(nil)
    }

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "BetterTileMenuBarItem"
        statusItem.behavior = []
        guard let button = statusItem.button else { return }
        button.image = Self.statusImage(availableUpdate: nil)
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = BetterTileVariant.displayName

        repairStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        repairStatusItem.autosaveName = "BetterTileRepairMenuBarItem"
        guard let repairButton = repairStatusItem.button else { return }
        let repairImage = NSImage(
            systemSymbolName: "arrow.triangle.2.circlepath",
            accessibilityDescription: "Repair Current Layout"
        )?.withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        repairImage?.isTemplate = true
        repairButton.image = repairImage
        repairButton.target = self
        repairButton.action = #selector(repairCurrentLayout)
        repairButton.toolTip = "Repair Current Layout"
    }

    private static func statusImage(availableUpdate: AvailableUpdate?) -> NSImage? {
        let updateAvailable = availableUpdate != nil
        var configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        if updateAvailable {
            configuration = configuration.applying(.init(hierarchicalColor: .systemBlue))
        }
        let image = NSImage(
            systemSymbolName: updateAvailable ? "arrow.down.circle.fill" : "rectangle.3.group",
            accessibilityDescription: availableUpdate.map {
                "BetterTile update available, version \($0.displayVersion)"
            } ?? BetterTileVariant.displayName
        )?.withSymbolConfiguration(configuration)
        image?.isTemplate = !updateAvailable
        return image
    }

    private func configurePopover() {
        popover.behavior = .applicationDefined
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.delegate = self
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        let interval = Self.signposter.beginInterval("showPopover")
        defer { Self.signposter.endInterval("showPopover", interval) }
        guard let button = statusItem.button else { return }
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let visibleHeight = button.window?.screen?.visibleFrame.height
            ?? NSScreen.main?.visibleFrame.height
            ?? 760
        let panelHeight = max(0, visibleHeight - 24)
#if DEBUG
        let panel = BetterTileMenuPanel(
            model: model,
            panelHeight: panelHeight,
            openSetup: { [weak self] in self?.showSetupAssistant() },
            openSettings: { [weak self] in self?.showSettings() },
            quit: { NSApp.terminate(nil) }
        )
#else
        let panel = BetterTileMenuPanel(
            model: model,
            panelHeight: panelHeight,
            updatePresentation: updatePresentation,
            checkForUpdates: { [weak self] in self?.checkForUpdates(nil) },
            openSetup: { [weak self] in self?.showSetupAssistant() },
            openSettings: { [weak self] in self?.showSettings() },
            quit: { NSApp.terminate(nil) }
        )
#endif
        let host: NSHostingController<BetterTileMenuPanel>
        if let existing = popoverHost {
            existing.rootView = panel
            host = existing
        } else {
            let creation = Self.signposter.beginInterval("createPopoverHost")
            host = NSHostingController(rootView: panel)
            popoverHost = host
            Self.signposter.endInterval("createPopoverHost", creation)
        }
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        if let window = popover.contentViewController?.view.window {
            window.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
            if let panel = window as? NSPanel {
                panel.hidesOnDeactivate = false
            }
            window.makeKey()
        }
        NSApp.activate(ignoringOtherApps: true)
        installDismissMonitors()
    }

    private func closePopover() {
        guard popover.isShown else {
            removeDismissMonitors()
            return
        }
        let interval = Self.signposter.beginInterval("closePopover")
        defer { Self.signposter.endInterval("closePopover", interval) }
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        removeDismissMonitors()
    }

    private func installDismissMonitors() {
        removeDismissMonitors()
        globalDismissMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.closePopover() }
        }
        localDismissMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                closePopover()
                return nil
            }
            guard event.type != .keyDown else { return event }
            if popover.contentViewController?.view.window === event.window
                || settingsWindow === event.window
                || setupWindow === event.window
                || statusButtonContainsMouse() {
                return event
            }
            closePopover()
            return event
        }
    }

    private func statusButtonContainsMouse() -> Bool {
        guard let frame = statusItem.button?.window?.frame else { return false }
        return frame.insetBy(dx: -4, dy: -8).contains(NSEvent.mouseLocation)
    }

    private func removeDismissMonitors() {
        if let globalDismissMonitor {
            NSEvent.removeMonitor(globalDismissMonitor)
            self.globalDismissMonitor = nil
        }
        if let localDismissMonitor {
            NSEvent.removeMonitor(localDismissMonitor)
            self.localDismissMonitor = nil
        }
    }

#if DEBUG
    private func diagnosticSetupPage(arguments: [String]) -> SetupPage? {
        let prefix = "--diagnostic-setup-page="
        return arguments
            .first(where: { $0.hasPrefix(prefix) })
            .flatMap { SetupPage(diagnosticName: String($0.dropFirst(prefix.count))) }
    }

    private func diagnosticCycleCount(prefix: String, arguments: [String]) -> Int? {
        arguments
            .first(where: { $0.hasPrefix(prefix) })
            .flatMap { Int($0.dropFirst(prefix.count)) }
            .map { max(0, $0) }
    }

    private func cyclePopover(remaining: Int) {
        guard remaining > 0 else { return }
        showPopover()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.closePopover()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                self?.cyclePopover(remaining: remaining - 1)
            }
        }
    }

    private func cycleSettings(remaining: Int) {
        guard remaining > 0 else { return }
        showSettings()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.settingsWindow?.performClose(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                self?.cycleSettings(remaining: remaining - 1)
            }
        }
    }
#endif

    private func showContextMenu() {
        closePopover()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let menu = NSMenu()
            populateApplicationCommands(in: menu)
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            DispatchQueue.main.async { [weak self] in self?.statusItem.menu = nil }
        }
    }

    @objc private func showSettings() {
        let interval = Self.signposter.beginInterval("showSettings")
        defer { Self.signposter.endInterval("showSettings", interval) }
        closePopover()
        let created = settingsWindow == nil
        if settingsWindow == nil {
            let creation = Self.signposter.beginInterval("createSettings")
#if DEBUG
            let settingsView = SettingsView(
                model: model,
                openSetup: { [weak self] in self?.showSetupAssistant() }
            )
#else
            let settingsView = SettingsView(
                model: model,
                updatePresentation: updatePresentation,
                automaticallyChecksForUpdates: Binding(
                    get: { [weak self] in
                        self?.updaterController.updater.automaticallyChecksForUpdates ?? false
                    },
                    set: { [weak self] value in
                        self?.updaterController.updater.automaticallyChecksForUpdates = value
                    }
                ),
                checkForUpdates: { [weak self] in self?.checkForUpdates(nil) },
                openSetup: { [weak self] in self?.showSetupAssistant() }
            )
#endif
            let host = NSHostingController(rootView: settingsView)
            let window = NSWindow(contentViewController: host)
            window.title = "\(BetterTileVariant.displayName) Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.contentMinSize = NSSize(width: 980, height: 640)
            window.setContentSize(NSSize(width: 1060, height: 760))
            window.level = .floating
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.collectionBehavior.insert([.moveToActiveSpace, .fullScreenAuxiliary])
            window.setFrameAutosaveName("BetterTileSettingsWindow")
            window.delegate = self
            settingsWindow = window
            Self.signposter.endInterval("createSettings", creation)
        }
        NSApp.activate(ignoringOtherApps: true)
        if created {
            settingsWindow?.center()
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.orderFrontRegardless()
    }

    private func showSetupAtLaunchIfNeeded() {
        let page: SetupPage?
        if model.configuration.setupCompletionVersion < SetupAssistantView.currentVersion {
            page = .welcome
        } else if !model.hasAccessibilityPermission {
            page = .accessibility
        } else {
            page = nil
        }
        guard let page else { return }
        DispatchQueue.main.async { [weak self] in self?.presentSetupAssistant(page: page) }
    }

    @objc private func showSetupAssistant() {
        presentSetupAssistant(page: .welcome)
    }

    private func presentSetupAssistant(page: SetupPage) {
        closePopover()
        let created = setupWindow == nil
        if setupWindow == nil {
            let host = NSHostingController(rootView: SetupAssistantView(
                model: model,
                initialPage: page,
                close: { [weak self] in self?.setupWindow?.performClose(nil) }
            ))
            let window = NSWindow(contentViewController: host)
            window.title = "\(BetterTileVariant.displayName) Setup"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.contentMinSize = NSSize(width: 680, height: 540)
            window.setContentSize(NSSize(width: 720, height: 580))
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.collectionBehavior.insert(.moveToActiveSpace)
            window.setFrameAutosaveName("BetterTileSetupWindow")
            window.delegate = self
            setupWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        if created {
            setupWindow?.center()
        }
        setupWindow?.makeKeyAndOrderFront(nil)
        setupWindow?.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === settingsWindow || window === setupWindow
        else { return }
        let interval = Self.signposter.beginInterval("closeWindow")
        defer { Self.signposter.endInterval("closeWindow", interval) }
        model.flushConfiguration()
        if window === setupWindow {
            // A new request starts at its requested page. Retaining the closed
            // hosting controller would retain the previous SwiftUI page state.
            setupWindow = nil
        }
    }

    @objc private func repairCurrentLayout() {
        closePopover()
        model.repairCurrentLayout()
    }

    @objc private func quitApplication() {
        NSApp.terminate(nil)
    }

#if !DEBUG
    /// Sparkle skips its own activation when the app is already active, which it
    /// is whenever the popover opened it. Sparkle also skips the delegate callback
    /// when it brings an existing update back into focus, so close Settings for
    /// that active session here. A newly found update closes it in the callback.
    @objc private func checkForUpdates(_ sender: Any?) {
        closePopover()
        NSApp.activate(ignoringOtherApps: true)
        let updater = updaterController.updater
        if updatePresentation.state.availableUpdate != nil,
           updater.sessionInProgress,
           updater.canCheckForUpdates {
            settingsWindow?.close()
        }
        updaterController.checkForUpdates(sender)
    }
#endif

    @objc private func sendFeedback() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        guard let url = FeedbackLink.url(version: version, build: build) else { return }
        NSWorkspace.shared.open(url)
    }

#if !DEBUG
    /// Translates one updater outcome into the menu-bar indicator. The decision
    /// itself lives in `UpdateIndicator` so it can be tested without Sparkle.
    private func applyUpdateEvent(_ event: UpdateIndicatorEvent) {
        updatePresentation.apply(event)
        renderUpdateIndicator()
    }

    private func renderUpdateIndicator() {
        let update = updatePresentation.state.availableUpdate
        let description = update.map {
            "BetterTile update available, version \($0.displayVersion)"
        } ?? BetterTileVariant.displayName
        statusItem.button?.image = Self.statusImage(availableUpdate: update)
        statusItem.button?.contentTintColor = nil
        statusItem.button?.toolTip = description
        statusItem.button?.setAccessibilityLabel(description)
        configureUpdateMenuItem(mainUpdateMenuItem)
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    /// Sparkle calls this before it shows the update window, and again with
    /// `willShowUpdate` false for a gentle scheduled reminder that only marks
    /// the menu bar. The update window uses the normal window level while
    /// Settings floats above it, so Settings has to close first or the update
    /// opens behind a window the user cannot see past. Closing it here rather
    /// than when the check starts keeps Settings open when no update is found.
    func standardUserDriverWillHandleShowingUpdate(
        _ willShowUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state _: SPUUserUpdateState
    ) {
        if willShowUpdate { settingsWindow?.close() }
        applyUpdateEvent(.foundValidUpdate(AvailableUpdate(
            displayVersion: update.displayVersionString,
            buildVersion: update.versionString
        )))
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        applyUpdateEvent(.confirmedNoUpdate)
    }

    /// Sparkle reports a failed cycle here. A check that could not complete says
    /// nothing about whether an update exists, so the indicator is left alone.
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if error != nil { applyUpdateEvent(.checkFailed) }
    }

    func updater(
        _ updater: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate item: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        switch choice {
        case .skip: applyUpdateEvent(.userSkippedUpdate)
        case .install: applyUpdateEvent(.userBeganInstallingUpdate)
        case .dismiss: applyUpdateEvent(.userDeferredUpdate)
        @unknown default: break
        }
    }
#endif

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: BetterTileVariant.displayName)
#if DEBUG
        populateApplicationCommands(in: appMenu)
#else
        mainUpdateMenuItem = populateApplicationCommands(in: appMenu)
#endif
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(
            NSMenuItem(
                title: "Minimize",
                action: #selector(NSWindow.performMiniaturize(_:)),
                keyEquivalent: "m"
            )
        )
        windowMenu.addItem(
            NSMenuItem(
                title: "Bring All to Front",
                action: #selector(NSApplication.arrangeInFront(_:)),
                keyEquivalent: ""
            )
        )
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    @discardableResult
    private func populateApplicationCommands(in menu: NSMenu) -> NSMenuItem? {
        @discardableResult
        func addItem(_ title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
            item.target = self
            menu.addItem(item)
            return item
        }

        addItem("Setup Assistant…", action: #selector(showSetupAssistant))
        addItem("Settings…", action: #selector(showSettings), keyEquivalent: ",")
        var updateItem: NSMenuItem?
#if !DEBUG
        updateItem = addItem("Check for Updates…", action: #selector(checkForUpdates(_:)))
        configureUpdateMenuItem(updateItem)
#endif
        addItem("Send Feedback…", action: #selector(sendFeedback))
        menu.addItem(.separator())
        addItem("Quit \(BetterTileVariant.displayName)", action: #selector(quitApplication), keyEquivalent: "q")
        return updateItem
    }

#if !DEBUG
    private func configureUpdateMenuItem(_ item: NSMenuItem?) {
        guard let item else { return }
        guard let update = updatePresentation.state.availableUpdate else {
            item.title = "Check for Updates…"
            item.image = nil
            item.badge = nil
            item.toolTip = nil
            item.setAccessibilityLabel(nil)
            return
        }

        let description = "Update available, version \(update.displayVersion)"
        item.title = "Update Available…"
        item.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: description)
        item.badge = NSMenuItemBadge(string: update.displayVersion)
        item.toolTip = description
        item.setAccessibilityLabel(description)
    }
#endif
}

#if !DEBUG
extension BetterTileAppDelegate: SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {}
#endif

enum PanelSurface {
    static func base(for scheme: ColorScheme, reduceTransparency: Bool) -> Color {
        if reduceTransparency {
            return scheme == .light ? Color(nsColor: .windowBackgroundColor) : Color(white: 0.08)
        }
        return scheme == .light ? Color.white.opacity(0.72) : Color.black.opacity(0.48)
    }

    static func card(for scheme: ColorScheme) -> Color {
        scheme == .light ? Color.white.opacity(0.52) : Color.white.opacity(0.075)
    }

    static func border(for scheme: ColorScheme, increaseContrast: Bool) -> Color {
        let opacity = increaseContrast ? 0.24 : 0.11
        return scheme == .light ? Color.black.opacity(opacity) : Color.white.opacity(opacity)
    }
}

private struct BetterTileMenuPanel: View {
    @Bindable var model: BetterTileModel
    let panelHeight: CGFloat
#if !DEBUG
    @Bindable var updatePresentation: UpdatePresentationModel
    let checkForUpdates: () -> Void
#endif
    let openSetup: () -> Void
    let openSettings: () -> Void
    let quit: () -> Void

    var body: some View {
        MenuPanelContent(
            model: model,
            availableHeight: panelHeight,
            openSetup: openSetup,
            openSettings: openSettings,
            quit: quit
        ) {
            LazyVGrid(columns: MenuPanelMetrics.columns, spacing: MenuPanelMetrics.gap) {
                ForEach(model.configuration.menuBarActions) { action in
                    MenuPanelActionButton(
                        action: action,
                        shortcut: model.configuration.shortcuts.first(where: { $0.action == action })?.shortcut,
                        isEnabled: model.hasAccessibilityPermission
                    ) {
                        model.perform(action)
                    }
                }
            }
        } notice: {
#if !DEBUG
            if let update = updatePresentation.state.availableUpdate {
                Button(action: checkForUpdates) {
                    HStack {
                        Label("Update available", systemImage: "arrow.down.circle.fill")
                        Spacer()
                        UpdateVersionBadge(version: update.displayVersion)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("View update, version \(update.displayVersion)")
            }
#endif
        }
    }
}

/// The real menu and its editor share all presentation. Only the action grid
/// and callbacks differ: editing a preview cannot operate on the desktop.
struct MenuPanelContent<Actions: View, Notice: View>: View {
    @Bindable var model: BetterTileModel
    var isEditing = false
    var availableHeight: CGFloat = 760
    var openSetup: (() -> Void)?
    var openSettings: (() -> Void)?
    var quit: (() -> Void)?
    @ViewBuilder let actions: () -> Actions
    @ViewBuilder let notice: () -> Notice
    @State private var chromeHeight: CGFloat = 286

    private var actionHeight: CGFloat {
        MenuPanelMetrics.viewportHeight(actionCount: model.configuration.menuBarActions.count, editing: isEditing,
                                        availableHeight: availableHeight, chromeHeight: chromeHeight)
    }

    private var controls: some View {
            MenuPanelControls(
                hasAccessibilityPermission: isEditing || model.hasAccessibilityPermission,
                activeMode: model.activeLayoutMode,
                contextDescription: model.activeContextDescription,
                snappingEnabled: model.configuration.snappingEnabled,
                setMode: isEditing ? nil : { model.setActiveMode($0) },
                setSnappingEnabled: isEditing ? nil : { value in
                    model.updateConfiguration { $0.snappingEnabled = value }
                },
                repairLayout: isEditing ? nil : { model.repairCurrentLayout() },
                openSetup: openSetup
            )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.tint)
                Text("BetterTile").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(model.activeLayoutMode.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .overlay(Capsule().strokeBorder(.separator))
            }

            notice()

            controls

            HStack {
                Text("Window actions")
                Spacer()
                Text("\(model.configuration.menuBarActions.count) selected")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            Group {
                if isEditing && !model.configuration.menuBarActions.isEmpty {
                    actions()
                } else {
                    MenuPanelScrollView {
                        if model.configuration.menuBarActions.isEmpty {
                            VStack(spacing: 6) {
                                Text("No window actions").fontWeight(.medium)
                                Text(isEditing ? "Choose actions on the left." : "Add actions in Menu Bar Settings.")
                                    .foregroundStyle(.secondary)
                            }
                            .font(.system(size: 12))
                            .frame(maxWidth: .infinity, minHeight: 72)
                        } else {
                            actions()
                        }
                    }
                }
            }
            .frame(height: actionHeight)
            .padding(.horizontal, -MenuPanelMetrics.scrollContentInset)

            Group {
                if !isEditing, let feedback = model.lastActionFeedback {
                    Label(feedback.message, systemImage: "\(feedback.symbolName).circle.fill")
                        .foregroundStyle(feedback.kind == .success ? Color.green : Color.orange)
                } else {
                    Text(isEditing ? "Drag window actions into your preferred order." : "Choose an action for the focused window.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11))
            .fixedSize(horizontal: false, vertical: true)

            Divider()
            MenuPanelFooter(openSettings: openSettings, quit: quit)
        }
        .padding(MenuPanelMetrics.padding)
        .frame(width: MenuPanelMetrics.width)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            // NSPopover supplies the native glass. Another material here
            // would hide its optics and make the transparency control ineffective.
            GlassBacking(model.configuration.overlayAppearance)
        }
        .onGeometryChange(for: CGFloat.self) { [actionHeight] proxy in
            proxy.size.height - actionHeight
        } action: { height in
            if abs(chromeHeight - height) > 0.5 { chromeHeight = height }
        }
    }
}

struct MenuPanelControls: View {
    let hasAccessibilityPermission: Bool
    let activeMode: LayoutMode
    let contextDescription: String

    /// Native has no layout to repair; the same action arranges its windows
    /// with Bento, so the label names that effect.
    private var repairTitle: String {
        switch activeMode {
        case .tabbed: "Repair Tabbed"
        case .bento: "Repair Bento"
        case .manual, .linked: "Arrange with Bento"
        }
    }

    private var repairHelp: String {
        switch activeMode {
        case .tabbed: "Rebuild this desktop's panes and tabs from its current windows."
        case .bento: "Re-tile this desktop's windows into a clean Bento layout."
        case .manual, .linked:
            "Tile this display's windows with Bento. A single window moves to its configured placement."
        }
    }
    let snappingEnabled: Bool
    let setMode: ((LayoutMode) -> Void)?
    let setSnappingEnabled: ((Bool) -> Void)?
    let repairLayout: (() -> Void)?
    let openSetup: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private var isInteractive: Bool {
        setMode != nil || setSnappingEnabled != nil || repairLayout != nil || openSetup != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if !hasAccessibilityPermission {
                HStack {
                    Label("Accessibility required", systemImage: "hand.raised.fill")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Setup…") { openSetup?() }
                        .controlSize(.small)
                }
            }

            HStack {
                Text("Window mode")
                    .font(.system(size: 12))
                Spacer()
                Picker("Window mode", selection: Binding(
                    get: { activeMode },
                    set: { setMode?($0) }
                )) {
                    ForEach(LayoutMode.availableModes, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: LayoutMode.availableModes.contains(.tabbed) ? 230 : 138)
            }

            Text(contextDescription)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(contextDescription)

            Toggle(
                "Drag snapping",
                isOn: Binding(get: { snappingEnabled }, set: { setSnappingEnabled?($0) })
            )
            .toggleStyle(SettingsSwitchStyle())
            .controlSize(.small)
            .font(.system(size: 12))

            Button {
                repairLayout?()
            } label: {
                Label(repairTitle, systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .help(repairHelp)
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(!hasAccessibilityPermission)
        }
        .allowsHitTesting(isInteractive)
        .accessibilityHidden(!isInteractive)
        .panelCard(
            colorScheme: colorScheme,
            increaseContrast: colorSchemeContrast == .increased
        )
    }
}

struct MenuPanelActionButton: View {
    let action: WindowAction
    let shortcut: BetterTileCore.KeyboardShortcut?
    var isEnabled = true
    let perform: () -> Void

    var body: some View {
        Button(action: perform) {
            HStack(spacing: 8) {
                WindowActionGlyph(action: action)
                VStack(alignment: .leading, spacing: 4) {
                    Text(action.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    ShortcutLabel(shortcut: shortcut)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: MenuPanelMetrics.tileHeight,
                   maxHeight: MenuPanelMetrics.tileHeight, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(MenuActionButtonStyle())
        .disabled(!isEnabled)
        .accessibilityLabel(action.title)
        .accessibilityValue(shortcut?.displayText ?? "No shortcut")
        .help(action.title)
    }
}

struct MenuActionButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(PanelSurface.card(for: scheme))
                    .overlay {
                        if isEnabled && (isHovered || configuration.isPressed) {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.accentColor.opacity(configuration.isPressed ? 0.2 : 0.08))
                        }
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isEnabled && isHovered ? Color.accentColor :
                        PanelSurface.border(for: scheme, increaseContrast: contrast == .increased))
            }
            .opacity(isEnabled ? 1 : 0.5)
            .onHover { isHovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isHovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct ShortcutLabel: View {
    let shortcut: BetterTileCore.KeyboardShortcut?
    var emptyLabel = "No shortcut"
    var size: CGFloat = 11

    var body: some View {
        HStack(spacing: 4) {
            if let shortcut {
                if !shortcut.modifiers.isEmpty { Text(shortcut.modifiers.displayText) }
                Text(shortcut.keyLabel.uppercased())
            } else {
                Text(emptyLabel)
            }
        }
        .font(.system(size: size, weight: .medium))
        .foregroundStyle(.secondary)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shortcut?.displayText ?? emptyLabel)
    }
}

struct MenuPanelFooter: View {
    let openSettings: (() -> Void)?
    let quit: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private var isInteractive: Bool {
        openSettings != nil || quit != nil
    }

    var body: some View {
        HStack(spacing: 7) {
            footerButton("Settings", systemImage: "gearshape", action: openSettings)
            footerButton("Quit", systemImage: "power", action: quit)
        }
        .frame(height: 30)
        .padding(.top, 2)
        .allowsHitTesting(isInteractive)
        .accessibilityHidden(!isInteractive)
    }

    private func footerButton(
        _ title: String,
        systemImage: String,
        action: (() -> Void)?
    ) -> some View {
        Button { action?() } label: {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(PanelSurface.card(for: colorScheme))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(
                            PanelSurface.border(
                                for: colorScheme,
                                increaseContrast: colorSchemeContrast == .increased
                            ),
                            lineWidth: 0.8
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}

/// Own the scroll view in both hosts. An overlay scroller occupies the outer
/// gutter; document padding leaves the tiles aligned with the panel's chrome.
struct MenuPanelScrollView<Content: View>: NSViewRepresentable {
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> MenuPanelScrollHost<Content> {
        MenuPanelScrollHost(content: content())
    }

    func updateNSView(_ view: MenuPanelScrollHost<Content>, context: Context) {
        view.update(content: content())
    }
}

class MenuPanelNativeScrollView: NSScrollView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        automaticallyAdjustsContentInsets = false
        verticalScroller?.controlSize = .small
    }

    required init?(coder: NSCoder) { nil }
}

final class MenuPanelScrollHost<Content: View>: MenuPanelNativeScrollView {
    private let host: NSHostingView<AnyView>
    private static var documentWidth: CGFloat {
        MenuPanelMetrics.width - MenuPanelMetrics.padding * 2 + MenuPanelMetrics.scrollContentInset * 2
    }

    init(content: Content) {
        host = NSHostingView(rootView: Self.document(content))
        super.init(frame: .zero)
        documentView = host
        update(content: content)
    }

    required init?(coder: NSCoder) { nil }

    private static func document(_ content: Content) -> AnyView {
        AnyView(content
            .frame(width: MenuPanelMetrics.width - MenuPanelMetrics.padding * 2)
            .padding(.horizontal, MenuPanelMetrics.scrollContentInset))
    }

    func update(content: Content) {
        host.rootView = Self.document(content)
        host.setFrameSize(NSSize(width: Self.documentWidth, height: host.fittingSize.height))
    }
}

private extension View {
    func panelCard(colorScheme: ColorScheme, increaseContrast: Bool) -> some View {
        padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(PanelSurface.card(for: colorScheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        PanelSurface.border(for: colorScheme, increaseContrast: increaseContrast),
                        lineWidth: 0.8
                    )
            )
    }
}

struct WindowActionGlyph: View {
    let action: WindowAction
    private static var images: [WindowAction: NSImage] = [:]

    /// A template image also works in AppKit-backed Picker menus, where a
    /// Canvas label cannot reliably supply an NSMenuItem image.
    static func image(for action: WindowAction) -> Image {
        if let cached = images[action] { return Image(nsImage: cached) }
        let renderer = ImageRenderer(content:
            LayoutWheelActionGlyph(action: action, tint: .black, fontSize: 20)
                .frame(width: 30, height: 26)
        )
        renderer.scale = 2
        guard let image = renderer.nsImage else {
            return Image(systemName: action.layoutWheelSymbolName)
        }
        image.isTemplate = true
        images[action] = image
        return Image(nsImage: image)
    }

    var body: some View {
        Self.image(for: action)
            .frame(width: 30, height: 26)
            .accessibilityHidden(true)
    }
}
