// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma
// Contains portions adapted from Vorssaint, Copyright (C) 2026 Vorssaint.

import AppKit
import BetterTileCore
import BetterTileMacOS
import os
import Sparkle
import SwiftUI

/// App windows follow normal application stacking. The Accessibility adapter
/// excludes our process independently of window level or desktop mode.
@MainActor
enum ApplicationWindowPresentation {
    static func configure(_ window: NSWindow) {
        window.level = .normal
        window.hidesOnDeactivate = false
        window.collectionBehavior.insert([.moveToActiveSpace, .fullScreenAuxiliary])
    }
}

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
    static let defaultStyle: Self = .dark

    case classic
    case ice
    case dark

    var id: Self { self }
    var title: String {
        switch self {
        case .classic: "Classic"
        case .ice: "Ice Blue"
        case .dark: "Dark"
        }
    }

    var resourceName: String {
        let name = switch self {
        case .classic: "AppIcon"
        case .ice: "AppIconIce"
        case .dark: "AppIconDark"
        }
#if DEBUG
        return name + "Debug"
#else
        return name
#endif
    }

    static func selected(in defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? defaultStyle
    }

    @MainActor
    var image: NSImage? { Bundle.main.image(forResource: resourceName) }

    @MainActor
    @discardableResult
    static func apply(
        _ style: Self? = nil,
        defaults: UserDefaults = .standard,
        updateFinder: @MainActor (Self) -> Bool = { $0.updateFinderIcon() },
        updateDock: @MainActor (Self) -> Void = { selected in
            // nil restores the system-rendered primary Icon Composer icon.
            NSApp.applicationIconImage = selected == defaultStyle ? nil : selected.image
            NSApp.dockTile.display()
        }
    ) -> Bool {
        let selected = style ?? selected(in: defaults)
        // A fresh install already has the primary icon. Only an explicit or saved
        // choice should replace an icon the user may have set outside BetterTile.
        let updatesFinder = style != nil || defaults.string(forKey: defaultsKey) != nil
        let finderUpdated = !updatesFinder || updateFinder(selected)
        // Clear the Finder override first so the Dock cannot pick up the old icon.
        updateDock(selected)
        return finderUpdated
    }

    @MainActor
    func updateFinderIcon(
        at bundleURL: URL = Bundle.main.bundleURL,
        loadImage: (String) -> NSImage? = { Bundle.main.image(forResource: $0) },
        setIcon: (NSImage?, String) -> Bool = { NSWorkspace.shared.setIcon($0, forFile: $1, options: []) }
    ) -> Bool {
        guard bundleURL.isFileURL, bundleURL.pathExtension == "app" else { return false }
        if self == Self.defaultStyle {
            return setIcon(nil, bundleURL.path)
        }
        // A missing alternate must not erase an existing Finder icon.
        guard let image = loadImage(resourceName) else { return false }
        return setIcon(image, bundleURL.path)
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
    case tabs

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
        case .tabs: "Tabs"
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
        case .tabs:
            [.showTabBar] + WindowAction.tabCommands
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
final class BetterTileAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
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
    private var menuPanel: MenuPanelController<BetterTileMenuPanel>?
    private var statusItem: NSStatusItem!
    private var repairStatusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    /// An unsaved Saved Layout draft survives a change of Settings page, so it
    /// also survives closing the Settings window.
    private lazy var savedLayoutEditor = SavedLayoutEditor()
    private var setupWindow: NSWindow?
    private var globalDismissMonitor: Any?
    private var localDismissMonitor: Any?

#if BETTERTILE_TEST_HOOKS
    private var closeMenuPanelForTesting: ((MenuPanelCloseReason) -> Void)?

    private var settingsPresentationForTesting: SettingsPresentationForTesting?

    convenience init(model: BetterTileModel, closeMenuPanel: @escaping (MenuPanelCloseReason) -> Void) {
        self.init()
        self.model = model
        closeMenuPanelForTesting = closeMenuPanel
    }

    /// Tests build Settings in their own window, with their own Saved Layouts
    /// folder and frame name, and never activate the test process.
    struct SettingsPresentationForTesting {
        var makeWindow: @MainActor (NSViewController) -> NSWindow
        var savedLayoutEditor: SavedLayoutEditor
        var frameAutosaveName: String?
    }

    convenience init(model: BetterTileModel, settingsPresentation: SettingsPresentationForTesting) {
        self.init(model: model, closeMenuPanel: { _ in })
        settingsPresentationForTesting = settingsPresentation
        savedLayoutEditor = settingsPresentation.savedLayoutEditor
    }

    var settingsWindowForTesting: NSWindow? { settingsWindow }
    var savedLayoutEditorForTesting: SavedLayoutEditor { savedLayoutEditor }
    func showSettingsForTesting() { showSettings() }
#endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isRunningFromReadOnlyVolume else {
            showMoveToApplicationsAlertAndQuit()
            return
        }
        guard quitRunningSiblingIfNeeded() else { return }
        modelStarted = true
        model.openSettings = { [weak self] in self?.showSettings() }
        WindowActionGroup.assertComplete()
        AppAppearance.apply()
        AppIconStyle.apply()
        installMainMenu()
        installStatusItem()
#if !DEBUG
        renderUpdateIndicator()
#endif
        model.setMenuBarIconVisible = { [weak self] in self?.setStatusItemsVisible($0) }
        setStatusItemsVisible(model.configuration.showMenuBarIcon)
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
        MenuPanelStatusButton.configure(button)
        button.toolTip = BetterTileVariant.displayName

        repairStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        repairStatusItem.autosaveName = "BetterTileRepairMenuBarItem"
        guard let repairButton = repairStatusItem.button else { return }
        let repairImage = NSImage(
            systemSymbolName: "arrow.triangle.2.circlepath",
            accessibilityDescription: "Repair Layout"
        )?.withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        repairImage?.isTemplate = true
        repairButton.image = repairImage
        repairButton.target = self
        repairButton.action = #selector(repairCurrentLayout)
        repairButton.toolTip = "Repair Layout"
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

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else if let menuPanel, menuPanel.isShown {
            menuPanel.toggle(relativeTo: .zero, visibleFrame: .zero)
        } else {
            showPopover()
        }
    }

    /// Show menu bar icon off hides both status items. Settings stays reachable by reopening the app.
    private func setStatusItemsVisible(_ visible: Bool) {
        if !visible { closePopover() }
        statusItem?.isVisible = visible
        repairStatusItem?.isVisible = visible
    }

    private func showPopover() {
        let interval = Self.signposter.beginInterval("showPopover")
        defer { Self.signposter.endInterval("showPopover", interval) }
        guard let button = statusItem.button,
              let geometry = MenuPanelStatusButton.presentationGeometry(
                for: button, isVisible: statusItem.isVisible, window: button.window,
                visibleFrame: button.window?.screen?.visibleFrame) else { return }
        let panelHeight = max(0, geometry.visibleFrame.height - 24)
#if DEBUG
        let panel = BetterTileMenuPanel(
            model: model,
            panelHeight: panelHeight,
            openSetup: { [weak self] in self?.showSetupAssistant() },
            openSettings: { [weak self] in self?.showSettings() },
            quit: { NSApp.terminate(nil) },
            close: { [weak self] in self?.closePopover(reason: .command) },
            surfaceChanged: { [weak self] in self?.menuPanel?.glass.overlayAppearance = $0 }
        )
#else
        let panel = BetterTileMenuPanel(
            model: model,
            panelHeight: panelHeight,
            updatePresentation: updatePresentation,
            checkForUpdates: { [weak self] in self?.checkForUpdates(nil) },
            openSetup: { [weak self] in self?.showSetupAssistant() },
            openSettings: { [weak self] in self?.showSettings() },
            quit: { NSApp.terminate(nil) },
            close: { [weak self] in self?.closePopover(reason: .command) },
            surfaceChanged: { [weak self] in self?.menuPanel?.glass.overlayAppearance = $0 }
        )
#endif
        let controller: MenuPanelController<BetterTileMenuPanel>
        if let existing = menuPanel {
            existing.update(rootView: panel, appearance: model.configuration.overlayAppearance)
            controller = existing
        } else {
            let creation = Self.signposter.beginInterval("createPopoverHost")
            let closeCallbacks = MenuPanelCloseCallbacks(model: model,
                closeReason: { [weak self] in self?.menuPanel?.closeReason },
                onDismiss: { [weak self, weak button] in
                    if let button { MenuPanelStatusButton.setPanelShown(false, on: button) }
                    self?.removeDismissMonitors()
                })
            controller = MenuPanelController(rootView: panel, appearance: model.configuration.overlayAppearance,
                onShow: { [weak button] in
                    if let button { MenuPanelStatusButton.setPanelShown(true, on: button) }
                }, onDismiss: closeCallbacks.onDismiss)
            menuPanel = controller
            Self.signposter.endInterval("createPopoverHost", creation)
        }
        model.menuPanelIsShown = { [weak self] in self?.menuPanel?.isShown == true }
        model.menuPanelWillOpen()
        controller.show(relativeTo: geometry.anchor, visibleFrame: geometry.visibleFrame)
        NSApp.activate(ignoringOtherApps: true)
        installDismissMonitors()
    }

    private func closePopover(reason: MenuPanelCloseReason = .programmatic) {
        let interval = Self.signposter.beginInterval("closePopover")
        defer { Self.signposter.endInterval("closePopover", interval) }
#if BETTERTILE_TEST_HOOKS
        if let closeMenuPanelForTesting { closeMenuPanelForTesting(reason); return }
#endif
        menuPanel?.dismiss(reason: reason)
        if let button = statusItem?.button { MenuPanelStatusButton.setPanelShown(false, on: button) }
        removeDismissMonitors()
    }

    private func installDismissMonitors() {
        removeDismissMonitors()
        globalDismissMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            // AppKit invokes monitors on the main thread. Route mouse-down before the button's mouse-up action.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.menuPanel?.routeGlobalMouseDown(event, isOverStatusItem: self.statusButtonContainsMouse())
            }
        }
        localDismissMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            guard let menuPanel else { return event }
            let excluded = [settingsWindow, setupWindow].contains { candidate in
                guard let candidate else { return false }
                return candidate === event.window || (event.type == .keyDown && candidate === NSApp.keyWindow)
            }
            return menuPanel.route(event, isExcludedWindow: excluded, isOverStatusItem: statusButtonContainsMouse())
        }
    }

    private func statusButtonContainsMouse() -> Bool {
        guard let button = statusItem?.button, let window = button.window else { return false }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
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
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                statusItem.menu = nil
                if let button = statusItem.button {
                    MenuPanelStatusButton.setPanelShown(menuPanel?.isShown == true, on: button)
                }
            }
        }
    }

    @objc private func showSettings() {
        let interval = Self.signposter.beginInterval("showSettings")
        defer { Self.signposter.endInterval("showSettings", interval) }
        closePopover(reason: .settings)
        let created = settingsWindow == nil
        if settingsWindow == nil {
            let creation = Self.signposter.beginInterval("createSettings")
#if DEBUG
            let settingsView = SettingsView(
                model: model,
                openSetup: { [weak self] in self?.showSetupAssistant() },
                savedLayoutEditor: savedLayoutEditor
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
                openSetup: { [weak self] in self?.showSetupAssistant() },
                savedLayoutEditor: savedLayoutEditor
            )
#endif
            let host = NSHostingController(rootView: settingsView)
            let window = makeSettingsWindow(host)
            window.title = "\(BetterTileVariant.displayName) Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            // Full-size content includes the 52 pt title bar, so these keep
            // the usable page area at 980 × 640 minimum and 1060 × 760 initially.
            window.contentMinSize = NSSize(width: 980, height: 692)
            window.setContentSize(NSSize(width: 1060, height: 812))
            window.isReleasedWhenClosed = false
            ApplicationWindowPresentation.configure(window)
            if let name = settingsFrameAutosaveName { window.setFrameAutosaveName(name) }
            window.delegate = self
            settingsWindow = window
            Self.signposter.endInterval("createSettings", creation)
        }
        activateForSettings()
        if created {
            settingsWindow?.center()
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.orderFrontRegardless()
    }

    private func makeSettingsWindow(_ host: NSViewController) -> NSWindow {
#if BETTERTILE_TEST_HOOKS
        if let settingsPresentationForTesting { return settingsPresentationForTesting.makeWindow(host) }
#endif
        return NSWindow(contentViewController: host)
    }

    private var settingsFrameAutosaveName: String? {
#if BETTERTILE_TEST_HOOKS
        if let settingsPresentationForTesting { return settingsPresentationForTesting.frameAutosaveName }
#endif
        return "BetterTileSettingsWindow"
    }

    private func activateForSettings() {
#if BETTERTILE_TEST_HOOKS
        if settingsPresentationForTesting != nil { return }
#endif
        NSApp.activate(ignoringOtherApps: true)
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
        closePopover(reason: .command)
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
            ApplicationWindowPresentation.configure(window)
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

    @objc private func showTabBar() {
        MenuPanelCommand.showTabBar.perform(model: model) { closePopover(reason: $0) }
    }

    @objc private func repairCurrentLayout() {
        MenuPanelCommand.repairLayout.perform(model: model) { closePopover(reason: $0) }
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
        closePopover(reason: .command)
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
    /// the menu bar. Close Settings before presenting the update window to
    /// keep one window in front for the update decision. Leave Settings open
    /// when no update is found.
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
        addItem("Show Tab Bar", action: #selector(showTabBar))
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

    static func card(for scheme: ColorScheme) -> AnyShapeStyle {
        scheme == .light ? AnyShapeStyle(Color.white.opacity(0.52)) : AnyShapeStyle(.fill.quaternary)
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
    let close: () -> Void
    let surfaceChanged: (OverlayAppearance) -> Void

    var body: some View {
        MenuPanelContent(
            model: model,
            availableHeight: panelHeight,
            openSetup: openSetup,
            openSettings: openSettings,
            quit: quit,
            close: close
        ) {
            LazyVGrid(columns: MenuPanelMetrics.columns, spacing: MenuPanelMetrics.gap) {
                ForEach(model.configuration.menuBarActions) { action in
                    MenuPanelActionButton(
                        action: action,
                        shortcut: model.configuration.shortcuts.first(where: { $0.action == action })?.shortcut,
                        isEnabled: model.hasAccessibilityPermission
                    ) {
                        close()
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
                        Text(update.displayVersion)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.fill.quaternary, in: Capsule())
                            .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
                            .lineLimit(1)
                            .accessibilityLabel("Update available, version \(update.displayVersion)")
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("View update, version \(update.displayVersion)")
            }
#endif
        }
        .onChange(of: model.configuration.overlayAppearance) { _, appearance in
            surfaceChanged(appearance)
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
    var close: (() -> Void)?
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
                repairLayout: isEditing ? nil : { close?(); model.repairCurrentLayout() },
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
                    .foregroundStyle(PopupGlass.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .overlay(Capsule().strokeBorder(.separator))
            }

            notice()

            controls

            if !isEditing { SavedLayoutPanelSection(model: model, openSettings: openSettings) }

            HStack {
                Text("Window actions")
                Spacer()
                Text("\(model.configuration.menuBarActions.count) selected")
            }
            .font(.system(size: 11))
            .foregroundStyle(PopupGlass.secondaryText)

            Group {
                if isEditing && !model.configuration.menuBarActions.isEmpty {
                    actions()
                } else {
                    MenuPanelScrollView {
                        if model.configuration.menuBarActions.isEmpty {
                            VStack(spacing: 6) {
                                Text("No window actions").fontWeight(.medium)
                                Text(isEditing ? "Choose actions on the left." : "Add actions in Menu Bar Settings.")
                                    .foregroundStyle(PopupGlass.secondaryText)
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
                    Label {
                        Text(feedback.message)
                    } icon: {
                        Image(systemName: "\(feedback.symbolName).circle.fill")
                            .foregroundStyle(feedback.kind == .success ? Color.green : Color.orange)
                    }
                } else {
                    Text(isEditing ? "Drag window actions into your preferred order." : "Choose an action for the focused window.")
                        .foregroundStyle(PopupGlass.secondaryText)
                }
            }
            .font(.system(size: 11))
            .fixedSize(horizontal: false, vertical: true)

            Divider()
            MenuPanelFooter(openSettings: openSettings, quit: quit)
        }
        .foregroundStyle(PopupGlass.secondaryText)
        .padding(MenuPanelMetrics.padding)
        .frame(width: MenuPanelMetrics.width)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { if !isEditing { model.savedLayoutActions.checkForChanges(); model.refreshSavedLayoutActionTarget() } }
        .onGeometryChange(for: CGFloat.self) { [actionHeight] proxy in
            proxy.size.height - actionHeight
        } action: { height in
            if abs(chromeHeight - height) > 0.5 { chromeHeight = height }
        }
    }
}

/// Use the native button's persistent on/off state without drawing menu-bar chrome.
@MainActor enum MenuPanelStatusButton {
    static func configure(_ button: NSStatusBarButton) {
        button.setButtonType(.pushOnPushOff)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.state = .off
    }

    static func presentationGeometry(for button: NSStatusBarButton, isVisible: Bool,
                                     window: NSWindow?, visibleFrame: NSRect?) -> (anchor: NSRect, visibleFrame: NSRect)? {
        // The push-on/push-off button toggles before its action, even when opening cannot proceed.
        setPanelShown(false, on: button)
        guard isVisible, let window, let visibleFrame else { return nil }
        return (window.convertToScreen(button.convert(button.bounds, to: nil)), visibleFrame)
    }

    static func setPanelShown(_ shown: Bool, on button: NSStatusBarButton) {
        button.state = shown ? .on : .off
        if !shown { button.isHighlighted = false }
    }
}

enum MenuPanelPhase { case hidden, opening, shown, closing }
/// Commands that close the menu panel before dispatching their action.
enum MenuPanelCommand: CaseIterable {
    case showTabBar, repairLayout

    @MainActor func perform(model: BetterTileModel, close: (MenuPanelCloseReason) -> Void) {
        close(.command)
        switch self {
        case .showTabBar: model.perform(.showTabBar)
        case .repairLayout: model.repairCurrentLayout()
        }
    }
}

/// The production close callbacks, shared with fake-system panel lifecycle tests.
@MainActor struct MenuPanelCloseCallbacks {
    let onDismiss: () -> Void

    init(model: BetterTileModel, closeReason: @escaping () -> MenuPanelCloseReason?,
         applicationIsActive: @escaping () -> Bool = { NSApp.isActive },
         onDismiss: @escaping () -> Void = {}) {
        self.init(closeReason: closeReason, applicationIsActive: applicationIsActive, onDismiss: onDismiss,
            didDismiss: { [weak model] in model?.menuPanelDidDismiss(authorization: $0) })
    }

    /// `didDismiss` receives the dismissal's focus rule. The model applies it at once, and again when a
    /// placement that commits after the dismissal ends its wait, with the application activity then.
    init(closeReason: @escaping () -> MenuPanelCloseReason?, applicationIsActive: @escaping () -> Bool,
         onDismiss: @escaping () -> Void = {}, didDismiss: @escaping (@escaping () -> Bool) -> Void) {
        self.onDismiss = {
            onDismiss()
            let reason = closeReason()
            didDismiss { reason?.allowsDeferredFocus(applicationIsActive: applicationIsActive()) == true }
        }
    }
}

enum MenuPanelCloseReason: CaseIterable {
    case statusItem, outsideClick, escape, command, settings, programmatic

    var restoresDeferredFocus: Bool {
        self == .statusItem || self == .escape
    }

    func allowsDeferredFocus(applicationIsActive: Bool) -> Bool {
        applicationIsActive && restoresDeferredFocus
    }
}

struct MenuPanelAnimation {
    let opening: Bool
    let reduceMotion: Bool
    var duration: TimeInterval { reduceMotion ? 0.12 : opening ? 0.26 : 0.18 }
    var hiddenScale: CGFloat { reduceMotion ? 1 : 0.25 }

    static func transform(scale: CGFloat, pivot: NSPoint, origin: NSPoint) -> CATransform3D {
        CATransform3DMakeAffineTransform(CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
            tx: (pivot.x - origin.x) * (1 - scale), ty: (pivot.y - origin.y) * (1 - scale)))
    }
}

/// A single popup material, without NSPopover's additional system backing or arrow.
@MainActor final class MenuPanelController<Content: View> {
    let panel = MenuPanelWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
    let glass: PopupGlassHost
    var animationLayer: CALayer? { host.view.layer }
    private let host: MenuPanelHostingController<Content>
    private let presentWindow: (NSPanel) -> Void
    private let onShow: () -> Void
    private let onDismiss: () -> Void
    private let onDidClose: (MenuPanelCloseReason) -> Void
    private weak var responderBeforeClosing: NSResponder?
    private var anchor = NSRect.zero
    private var visibleFrame = NSRect.zero
    private var presentationGeneration = 0
    private(set) var phase = MenuPanelPhase.hidden
    private(set) var closeReason: MenuPanelCloseReason?
    var isShown: Bool { phase == .opening || phase == .shown }
    private let reduceMotion: () -> Bool
    private let animate: ((MenuPanelAnimation, @escaping @MainActor () -> Void) -> Void)?

    init(rootView: Content, appearance: OverlayAppearance,
         presentWindow: @escaping (NSPanel) -> Void = { $0.makeKeyAndOrderFront(nil) },
         onShow: @escaping () -> Void = {},
         onDismiss: @escaping () -> Void = {},
         onDidClose: @escaping (MenuPanelCloseReason) -> Void = { _ in },
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
         animate: ((MenuPanelAnimation, @escaping @MainActor () -> Void) -> Void)? = nil) {
        self.reduceMotion = reduceMotion
        self.animate = animate
        host = MenuPanelHostingController(rootView: rootView)
        host.view.wantsLayer = true
        glass = PopupGlassHost(content: host.view, appearance: appearance)
        self.presentWindow = presentWindow
        self.onShow = onShow
        self.onDismiss = onDismiss
        self.onDidClose = onDidClose
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Keep the glass stationary while the window fades and its controls grow from the status item.
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.level = .popUpMenu
        panel.contentView = glass
        panel.onCancel = { [weak self] in self?.dismiss(reason: .escape) }
        host.onSizeChange = { [weak self] in self?.position() }
        host.sizingOptions = .preferredContentSize
    }

    func update(rootView: Content, appearance: OverlayAppearance) {
        host.rootView = rootView
        glass.overlayAppearance = appearance
        if isShown { position() }
    }

    func show(relativeTo anchor: NSRect, visibleFrame: NSRect) {
        self.anchor = anchor
        self.visibleFrame = visibleFrame
        // The menu bar window can retain the system appearance when the app overrides it.
        // Resolve glass, plate and hosted labels in the app appearance, like other popups.
        panel.appearance = NSApp.appearance
        host.view.appearance = NSApp.appearance
        let wasHidden = phase == .hidden
        phase = .opening
        closeReason = nil
        presentationGeneration += 1
        let generation = presentationGeneration
        panel.ignoresMouseEvents = false
        panel.acceptsControlInput = true
        position()
        let transition = MenuPanelAnimation(opening: true, reduceMotion: reduceMotion())
        if wasHidden, let layer = animationLayer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            panel.alphaValue = 0
            layer.opacity = 1
            layer.transform = hiddenTransform(for: transition)
            CATransaction.commit()
        }
        presentWindow(panel)
        if let responderBeforeClosing { panel.makeFirstResponder(responderBeforeClosing) }
        guard isShown, presentationGeneration == generation else { return }
        onShow()
        transitionAnimation(transition) { [weak self] in
            guard let self, self.presentationGeneration == generation, self.phase == .opening else { return }
            self.phase = .shown
        }
        // The status button's mouse-up tracking can clear its highlight after the action.
        // Reapply only for this opening; a queued callback must not revive a closed panel.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isShown, self.presentationGeneration == generation else { return }
            self.onShow()
        }
    }

    func toggle(relativeTo anchor: NSRect, visibleFrame: NSRect) {
        if isShown { dismiss(reason: .statusItem) } else { show(relativeTo: anchor, visibleFrame: visibleFrame) }
    }

    func dismiss(reason: MenuPanelCloseReason = .programmatic) {
        guard isShown else { return }
        phase = .closing
        closeReason = reason
        presentationGeneration += 1
        let generation = presentationGeneration
        panel.ignoresMouseEvents = true
        responderBeforeClosing = panel.firstResponder
        panel.makeFirstResponder(nil)
        panel.acceptsControlInput = false
        onDismiss()
        guard phase == .closing, presentationGeneration == generation else { return }
        transitionAnimation(MenuPanelAnimation(opening: false, reduceMotion: reduceMotion())) { [weak self] in
            guard let self, self.presentationGeneration == generation, self.phase == .closing else { return }
            self.panel.orderOut(nil)
            self.phase = .hidden
            self.responderBeforeClosing = nil
            self.onDidClose(reason)
        }
    }

    private func hiddenTransform(for transition: MenuPanelAnimation) -> CATransform3D {
        guard !transition.reduceMotion, let layer = animationLayer else { return CATransform3DIdentity }
        let glassPivot = NSPoint(x: min(glass.bounds.maxX, max(glass.bounds.minX, anchor.midX - panel.frame.minX)),
                                 y: glass.bounds.maxY)
        let pivot = host.view.convert(glassPivot, from: glass)
        let origin = NSPoint(x: layer.bounds.minX + layer.anchorPoint.x * layer.bounds.width,
                             y: layer.bounds.minY + layer.anchorPoint.y * layer.bounds.height)
        return MenuPanelAnimation.transform(scale: transition.hiddenScale, pivot: pivot, origin: origin)
    }

    private func transitionAnimation(_ transition: MenuPanelAnimation, completion: @escaping @MainActor () -> Void) {
        if let animate { animate(transition, completion); return }
        guard let layer = animationLayer else { completion(); return }
        let current = layer.presentation() ?? layer
        let transform = CABasicAnimation(keyPath: "transform")
        transform.fromValue = NSValue(caTransform3D: current.transform)
        transform.toValue = NSValue(caTransform3D: transition.opening ? CATransform3DIdentity : hiddenTransform(for: transition))
        let group = CAAnimationGroup()
        group.animations = transition.reduceMotion ? [] : [transform]
        group.duration = transition.duration
        group.timingFunction = transition.opening
            ? CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            : CAMediaTimingFunction(name: .easeIn)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: "menuPanelTransition")
        layer.opacity = 1
        layer.transform = transition.opening ? CATransform3DIdentity : hiddenTransform(for: transition)
        if !transition.reduceMotion { layer.add(group, forKey: "menuPanelTransition") }
        CATransaction.commit()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = transition.duration
            context.timingFunction = group.timingFunction
            panel.animator().alphaValue = transition.opening ? 1 : 0
        } completionHandler: {
            Task { @MainActor in completion() }
        }
    }

    func route(_ event: NSEvent, isExcludedWindow: Bool = false, isOverStatusItem: Bool = false) -> NSEvent? {
        guard isShown else { return event }
        if event.type == .keyDown {
            if event.keyCode == 53 {
                if isExcludedWindow { return event }
                dismiss(reason: .escape)
                return nil
            }
            return event
        }
        if event.window !== panel && !isExcludedWindow && !isOverStatusItem { dismiss(reason: .outsideClick) }
        return event
    }

    func routeGlobalMouseDown(_ event: NSEvent, isOverStatusItem: Bool) {
        _ = route(event, isOverStatusItem: isOverStatusItem)
    }

    private func position() {
        guard isShown, !visibleFrame.isEmpty else { return }
        let height = min(host.view.fittingSize.height, max(0, visibleFrame.height - 16))
        let frame = Self.frame(height: height, anchor: anchor, visibleFrame: visibleFrame)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
    }

    static func frame(height: CGFloat, anchor: NSRect, visibleFrame: NSRect) -> NSRect {
        let width = MenuPanelMetrics.width
        let x = max(visibleFrame.minX + 8, min(anchor.midX - width / 2, visibleFrame.maxX - 8 - width))
        let top = min(anchor.minY - 4, visibleFrame.maxY - 4)
        let y = max(visibleFrame.minY + 8, top - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }
}

@MainActor final class MenuPanelWindow: NSPanel {
    var onCancel: (() -> Void)?
    var acceptsControlInput = true
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if !acceptsControlInput { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func sendEvent(_ event: NSEvent) {
        if !acceptsControlInput, event.type == .keyDown || event.type == .keyUp { return }
        super.sendEvent(event)
    }
}

@MainActor private final class MenuPanelHostingController<Content: View>: NSHostingController<Content> {
    var onSizeChange: (() -> Void)?
    override var preferredContentSize: NSSize {
        didSet { if preferredContentSize != oldValue { onSizeChange?() } }
    }
}

/// Draw only the menu's dense mode track. Saved Layouts retains the native picker.
struct MenuPanelModePicker: NSViewRepresentable {
    @Binding var selection: LayoutMode
    var isInteractive = true

    func makeNSView(context: Context) -> MenuPanelModeControl {
        let control = MenuPanelModeControl(selection: selection)
        updateNSView(control, context: context)
        return control
    }

    func updateNSView(_ control: MenuPanelModeControl, context: Context) {
        control.isInteractive = isInteractive
        control.setSelection(selection)
        control.onSelect = { [weak control] mode in
            selection = mode
            // Read back even when the model refuses the request and SwiftUI has no update to send.
            control?.setSelection(selection)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MenuPanelModeControl, context: Context) -> CGSize? {
        NSSize(width: MenuPanelModeControl.width, height: MenuPanelModeControl.height)
    }
}

private struct MenuPanelModeTrack: View {
    var body: some View {
        RoundedRectangle(cornerRadius: PopupGlass.controlRadius, style: .continuous)
            .fill(.fill.quaternary)
            .allowsHitTesting(false)
    }
}

/// One material-free track, with native buttons for focus and activation.
@MainActor final class MenuPanelModeControl: NSView {
    static let width: CGFloat = 284
    static let height: CGFloat = 24
    private let track = NSHostingView(rootView: MenuPanelModeTrack())
    private(set) var buttons: [MenuPanelModeButton] = []
    private(set) var selection: LayoutMode = .manual
    private var focusedMode: LayoutMode?
    var isInteractive = true
    var onSelect: ((LayoutMode) -> Void)?
    var fullKeyboardAccess: () -> Bool = { NSApp.isFullKeyboardAccessEnabled }

    init(selection: LayoutMode) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))
        addSubview(track)
        for mode in LayoutMode.availableModes {
            let button = MenuPanelModeButton(mode: mode)
            button.owner = self
            button.target = self
            button.action = #selector(choose(_:))
            buttons.append(button)
            addSubview(button)
        }
        setSelection(selection)
    }

    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { NSSize(width: Self.width, height: Self.height) }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        track.frame = bounds
        let width = bounds.width / CGFloat(buttons.count)
        for (i, button) in buttons.enumerated() {
            button.frame = NSRect(x: CGFloat(i) * width, y: 0, width: width, height: bounds.height)
        }
    }

    func setSelection(_ mode: LayoutMode) {
        selection = mode.availableMode
        if !buttons.contains(where: { window?.firstResponder === $0 }) { focusedMode = nil }
        for button in buttons {
            button.isSelected = button.mode == selection
            button.setAccessibilityValue(button.isSelected ? "Selected" : "Not selected")
        }
    }

    func acceptsFocus(on mode: LayoutMode) -> Bool {
        isInteractive && fullKeyboardAccess() && mode == (focusedMode ?? selection)
    }

    @objc private func choose(_ sender: MenuPanelModeButton) {
        guard isInteractive else { return }
        onSelect?(sender.mode)
    }

    func move(from mode: LayoutMode, by offset: Int) {
        guard isInteractive, let index = buttons.firstIndex(where: { $0.mode == mode }) else { return }
        let next = min(buttons.count - 1, max(0, index + offset))
        guard next != index else { return }
        let previous = focusedMode
        focusedMode = buttons[next].mode
        if window?.makeFirstResponder(buttons[next]) != true { focusedMode = previous }
    }
}

@MainActor final class MenuPanelModeButton: NSButton {
    let mode: LayoutMode
    weak var owner: MenuPanelModeControl?
    var isSelected = false { didSet { needsDisplay = true } }
    private(set) var isHovered = false
    static var titleFont: NSFont { .systemFont(ofSize: 13) }

    init(mode: LayoutMode) {
        self.mode = mode
        super.init(frame: .zero)
        title = mode.title
        isBordered = false
        setButtonType(.momentaryChange)
        focusRingType = .exterior
        setAccessibilityLabel(mode.title)
        setAccessibilityRole(.radioButton)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    // This custom artwork uses OverlayButton's opaque shade/white-ink palette.
    // NSButton's automatic vibrancy would brighten that already-shaded fill.
    override var allowsVibrancy: Bool { false }
    override var acceptsFirstResponder: Bool { isEnabled && (owner?.acceptsFocus(on: mode) ?? false) }
    override var isHighlighted: Bool { didSet { needsDisplay = true } }
    override var isEnabled: Bool { didSet { needsDisplay = true } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
                                      owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: PopupGlass.controlRadius, yRadius: PopupGlass.controlRadius).fill()
    }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 123, 126: owner?.move(from: mode, by: -1)
        case 124, 125: owner?.move(from: mode, by: 1)
        case 49, 36, 76: performClick(nil)
        default: super.keyDown(with: event)
        }
    }

    func palette(pressed: Bool? = nil, hovered: Bool? = nil) -> (fill: NSColor?, ink: NSColor, overlay: NSColor?) {
        let overlay = (pressed ?? isHighlighted) ? OverlayButtonMetrics.pressedBlackOpacity
            : ((hovered ?? isHovered) && isEnabled ? OverlayButtonMetrics.hoverBlackOpacity : 0)
        return (isSelected ? PopupGlass.accentShadeColor : nil, isSelected ? .white : .labelColor,
                overlay > 0 ? NSColor.black.withAlphaComponent(overlay) : nil)
    }

    var fillRect: NSRect { isSelected ? bounds.insetBy(dx: 2, dy: 2) : bounds }
    var fillRadius: CGFloat { isSelected ? PopupGlass.controlRadius - 2 : PopupGlass.controlRadius }

    func contentRects() -> (glyph: NSRect, title: NSRect) {
        let size = (title as NSString).size(withAttributes: [.font: Self.titleFont])
        let canvas = LayoutModePicker.glyphSize
        let x = (bounds.width - canvas - LayoutModePicker.glyphSpacing - size.width) / 2
        return (NSRect(x: x, y: (bounds.height - canvas) / 2, width: canvas, height: canvas),
                NSRect(x: x + canvas + LayoutModePicker.glyphSpacing, y: (bounds.height - size.height) / 2,
                       width: size.width, height: size.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        defer { context.restoreGraphicsState() }
        if !isEnabled { context.cgContext.setAlpha(OverlayButtonMetrics.disabledOpacity) }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let colors = palette()
            let shape = NSBezierPath(roundedRect: fillRect, xRadius: fillRadius, yRadius: fillRadius)
            if let fill = colors.fill?.usingColorSpace(.sRGB) { fill.setFill(); shape.fill() }
            if let overlay = colors.overlay { overlay.setFill(); shape.fill() }
            let rects = contentRects()
            LayoutGlyph.mode(mode).stroke(in: context.cgContext, origin: rects.glyph.origin,
                                          canvasSize: rects.glyph.width, color: colors.ink.cgColor, flipped: isFlipped)
            (title as NSString).draw(in: rects.title, withAttributes: [.font: Self.titleFont, .foregroundColor: colors.ink])
        }
    }
}

struct MenuPanelControls: View {
    let hasAccessibilityPermission: Bool
    let activeMode: LayoutMode
    let contextDescription: String

    private var repairHelp: String {
        switch activeMode {
        case .tabbed: "Rebuild this desktop's panes and tabs from its current windows."
        case .bento: "Re-tile this desktop's windows into a clean Adaptive layout."
        case .manual, .linked:
            "Tile this display's windows with Adaptive. A single window moves to its configured placement; several windows switch the desktop to Adaptive."
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
                    Label {
                        Text("Accessibility required")
                    } icon: {
                        Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                    }
                    Spacer()
                    Button("Setup…") { openSetup?() }
                        .controlSize(.small)
                }
            }

            // The icons need about 61 pt more than the text-only control. The label moves to its own
            // line and the picker takes the full width of the card.
            VStack(alignment: .leading, spacing: 6) {
                Text("Window mode")
                    .font(.system(size: 12))
                MenuPanelModePicker(selection: Binding(get: { activeMode }, set: { setMode?($0) }),
                                    isInteractive: setMode != nil)
            }

            Text(contextDescription)
                .font(.system(size: 11))
                .foregroundStyle(PopupGlass.secondaryText)
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
                Label("Repair Layout", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .help(repairHelp)
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(!hasAccessibilityPermission)
        }
        .foregroundStyle(PopupGlass.secondaryText)
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
            .foregroundStyle(PopupGlass.secondaryText)
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
        .foregroundStyle(PopupGlass.secondaryText)
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
