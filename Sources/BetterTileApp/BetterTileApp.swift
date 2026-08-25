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
        let grouped = allCases.flatMap(\.actions)
        assert(grouped.count == Set(grouped).count, "Window actions must appear in one UI group only.")
        assert(Set(grouped) == Set(WindowAction.allCases), "Every window action must appear in the UI.")
#endif
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
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: self,
        userDriverDelegate: nil
    )
    private var updateIndicatorState = UpdateIndicatorState.idle
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
        installMainMenu()
        installStatusItem()
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
        let image = NSImage(
            systemSymbolName: "rectangle.3.group",
            accessibilityDescription: BetterTileVariant.displayName
        )?.withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        image?.isTemplate = true
        button.image = image
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = BetterTileVariant.displayName

        repairStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        repairStatusItem.autosaveName = "BetterTileRepairMenuBarItem"
        guard let repairButton = repairStatusItem.button else { return }
        let repairImage = NSImage(
            systemSymbolName: "arrow.triangle.2.circlepath",
            accessibilityDescription: "Repair Bento Layout"
        )?.withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        repairImage?.isTemplate = true
        repairButton.image = repairImage
        repairButton.target = self
        repairButton.action = #selector(repairCurrentLayout)
        repairButton.toolTip = "Repair Bento Layout"
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
        let panelHeight = max(360, visibleHeight - 24)
        let panel = BetterTileMenuPanel(
            model: model,
            panelHeight: panelHeight,
            openSetup: { [weak self] in self?.showSetupAssistant() },
            openSettings: { [weak self] in self?.showSettings() },
            quit: { NSApp.terminate(nil) }
        )
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
            window.contentMinSize = NSSize(width: 820, height: 560)
            window.setContentSize(NSSize(width: 920, height: 640))
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
    }

    @objc private func repairCurrentLayout() {
        closePopover()
        model.tileCurrentDisplay()
    }

    @objc private func quitApplication() {
        NSApp.terminate(nil)
    }

#if !DEBUG
    @objc private func checkForUpdates(_ sender: Any?) {
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
        updateIndicatorState = UpdateIndicator.state(after: event, from: updateIndicatorState)
        renderUpdateIndicator()
    }

    private func renderUpdateIndicator() {
        let available = updateIndicatorState == .updateAvailable
        statusItem.button?.contentTintColor = available ? .systemBlue : nil
        statusItem.button?.toolTip = available ? "BetterTile update available" : BetterTileVariant.displayName
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        applyUpdateEvent(.foundValidUpdate)
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
        populateApplicationCommands(in: appMenu)
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

    private func populateApplicationCommands(in menu: NSMenu) {
        func addItem(_ title: String, action: Selector, keyEquivalent: String = "") {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
            item.target = self
            menu.addItem(item)
        }

        addItem("Setup Assistant…", action: #selector(showSetupAssistant))
        addItem("Settings…", action: #selector(showSettings), keyEquivalent: ",")
#if !DEBUG
        addItem("Check for Updates…", action: #selector(checkForUpdates(_:)))
#endif
        addItem("Send Feedback…", action: #selector(sendFeedback))
        menu.addItem(.separator())
        addItem("Quit \(BetterTileVariant.displayName)", action: #selector(quitApplication), keyEquivalent: "q")
    }
}

#if !DEBUG
extension BetterTileAppDelegate: SPUUpdaterDelegate {}
#endif

private enum PanelSurface {
    static func base(for scheme: ColorScheme, reduceTransparency: Bool) -> Color {
        if reduceTransparency {
            return scheme == .light ? Color(nsColor: .windowBackgroundColor) : Color(white: 0.08)
        }
        return scheme == .light ? Color.white.opacity(0.72) : Color.black.opacity(0.48)
    }

    static func card(for scheme: ColorScheme) -> Color {
        scheme == .light ? Color.white.opacity(0.52) : Color.white.opacity(0.075)
    }

    static func control(for scheme: ColorScheme) -> Color {
        scheme == .light ? Color.black.opacity(0.055) : Color.white.opacity(0.09)
    }

    static func border(for scheme: ColorScheme, increaseContrast: Bool) -> Color {
        let opacity = increaseContrast ? 0.24 : 0.11
        return scheme == .light ? Color.black.opacity(opacity) : Color.white.opacity(opacity)
    }
}

private struct BetterTileMenuPanel: View {
    @Bindable var model: BetterTileModel
    let panelHeight: CGFloat
    let openSetup: () -> Void
    let openSettings: () -> Void
    let quit: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private var increaseContrast: Bool {
        colorSchemeContrast == .increased
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("BetterTile")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)

            controlsCard

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(WindowActionGroup.allCases) { group in
                        actionGroup(group)
                    }
                    if !model.configuration.customZones.isEmpty {
                        customZonesCard
                    }
                }
                .padding(.vertical, 1)
                .background(OverlayScrollerConfigurator())
            }
            .contentMargins(.horizontal, 12, for: .scrollContent)
            .contentMargins(.trailing, 4, for: .scrollIndicators)
            .padding(.horizontal, -12)
            .scrollIndicators(.automatic)

            if let feedback = model.lastActionFeedback {
                Label(feedback.message, systemImage: "\(feedback.symbolName).circle.fill")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(feedback.kind == .success ? Color.green : Color.orange)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            footer
        }
        .padding(12)
        .frame(width: 332, height: panelHeight)
        .background {
            Rectangle()
                .fill(reduceTransparency ? AnyShapeStyle(Color.clear) : AnyShapeStyle(.regularMaterial))
                .overlay(PanelSurface.base(for: colorScheme, reduceTransparency: reduceTransparency))
        }
    }

    private var controlsCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            if !model.hasAccessibilityPermission {
                HStack {
                    Label("Accessibility required", systemImage: "hand.raised.fill")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Setup…", action: openSetup)
                        .controlSize(.small)
                }
            }

            HStack {
                Text("Window mode")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Picker("Window mode", selection: Binding(
                    get: { model.activeLayoutMode },
                    set: { model.setActiveMode($0) }
                )) {
                    ForEach(LayoutMode.availableModes, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 150)
            }

            Text(model.activeContextDescription)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Toggle(
                "Enable drag snapping",
                isOn: Binding(
                    get: { model.configuration.snappingEnabled },
                    set: { value in
                        model.updateConfiguration { $0.snappingEnabled = value }
                    }
                )
            )
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .font(.system(size: 10.5, weight: .medium))

            Button {
                model.tileCurrentDisplay()
            } label: {
                Label("Repair Current Bento Layout", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(!model.hasAccessibilityPermission)
        }
        .panelCard(colorScheme: colorScheme, increaseContrast: increaseContrast)
    }

    private func actionGroup(_ group: WindowActionGroup) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            panelSectionTitle(group.title)
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 7),
                    GridItem(.flexible(), spacing: 7),
                ],
                spacing: 7
            ) {
                ForEach(group.actions) { action in
                    actionButton(action)
                }
            }
        }
        .panelCard(colorScheme: colorScheme, increaseContrast: increaseContrast)
    }

    private func actionButton(_ action: WindowAction) -> some View {
        Button {
            model.perform(action)
        } label: {
            VStack(spacing: 3) {
                HStack(spacing: 6) {
                    WindowActionGlyph(action: action)
                    Text(action.title)
                        .font(.system(size: 10.5, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }
                Text(shortcut(for: action)?.displayText ?? " ")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityHidden(shortcut(for: action) == nil)
            }
            .frame(maxWidth: .infinity, minHeight: 38)
            .padding(.horizontal, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(PanelSurface.control(for: colorScheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        PanelSurface.border(for: colorScheme, increaseContrast: increaseContrast),
                        lineWidth: 0.8
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!model.hasAccessibilityPermission)
        .help(action.title)
    }

    private var customZonesCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            panelSectionTitle("Custom Zones")
            ForEach(model.configuration.customZones) { zone in
                Button {
                    model.apply(zone: zone)
                } label: {
                    Label(zone.name, systemImage: "rectangle.dashed")
                        .font(.system(size: 10.5, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!model.hasAccessibilityPermission)
            }
        }
        .panelCard(colorScheme: colorScheme, increaseContrast: increaseContrast)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            footerButton("Settings", systemImage: "gearshape", action: openSettings)
            footerButton("Quit", systemImage: "power", action: quit)
        }
        .frame(height: 30)
        .padding(.top, 2)
    }

    private func footerButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(PanelSurface.card(for: colorScheme))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(
                            PanelSurface.border(for: colorScheme, increaseContrast: increaseContrast),
                            lineWidth: 0.8
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private func shortcut(for action: WindowAction) -> BetterTileCore.KeyboardShortcut? {
        model.configuration.shortcuts.first(where: { $0.action == action })?.shortcut
    }

    private func panelSectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9.5, weight: .bold))
            .kerning(0.45)
            .foregroundStyle(.secondary)
    }
}

private struct OverlayScrollerConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        configureWhenAttached(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configureWhenAttached(nsView)
    }

    private func configureWhenAttached(_ view: NSView) {
        DispatchQueue.main.async {
            var ancestor: NSView? = view
            while let current = ancestor {
                if let scrollView = current as? NSScrollView {
                    scrollView.scrollerStyle = .overlay
                    scrollView.autohidesScrollers = true
                    scrollView.verticalScroller?.controlSize = .small
                    return
                }
                ancestor = current.superview
            }
        }
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

    var body: some View {
        Group {
            if let footprint = action.glyphFootprint {
                GeometryReader { geometry in
                    let width = max(0, geometry.size.width - 2)
                    let height = max(0, geometry.size.height - 2)
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(.secondary, lineWidth: 1)
                            .frame(width: width, height: height)
                            .offset(x: 1, y: 1)
                        RoundedRectangle(cornerRadius: 1)
                            .fill(.primary.opacity(0.38))
                            .frame(
                                width: max(2, width * footprint.width),
                                height: max(2, height * footprint.height)
                            )
                            .offset(
                                x: 1 + width * footprint.x,
                                y: 1 + height * footprint.y
                            )
                    }
                }
            } else if let symbol = action.glyphSymbol {
                Image(
                    systemName: NSImage(
                        systemSymbolName: symbol,
                        accessibilityDescription: nil
                    ) == nil ? "rectangle" : symbol
                )
                .font(.system(size: 10, weight: .semibold))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 20, height: 14)
        .accessibilityHidden(true)
    }
}

private let cachedWindowActionGlyphFootprints: [WindowAction: NormalizedRect] = {
    let bounds = BTRect(x: 0, y: 0, width: 1_000, height: 800)
    let display = DisplaySnapshot(
        id: DisplayID(rawValue: "glyph"),
        frame: bounds,
        visibleFrame: bounds
    )
    let window = WindowSnapshot(
        id: WindowID(rawValue: "glyph"),
        processIdentifier: 0,
        frame: BTRect(x: 220, y: 176, width: 560, height: 448),
        displayID: display.id
    )
    return Dictionary(uniqueKeysWithValues: WindowAction.allCases.compactMap { action in
        guard action.glyphSymbol == nil else { return nil }
        if action == .almostMaximize {
            return (action, NormalizedRect(x: 0.14, y: 0.18, width: 0.72, height: 0.64))
        }
        return StandardActionEngine().targetFrame(
            for: action,
            window: window,
            display: display
        ).map { (action, NormalizedRect(frame: $0, in: bounds)) }
    })
}()

private extension WindowAction {
    var glyphFootprint: NormalizedRect? {
        cachedWindowActionGlyphFootprints[self]
    }

    var glyphSymbol: String? {
        switch self {
        case .previousDisplay: "arrow.left.to.line"
        case .nextDisplay: "arrow.right.to.line"
        case .moveLeft: "arrow.left"
        case .moveRight: "arrow.right"
        case .moveUp: "arrow.up"
        case .moveDown: "arrow.down"
        case .growWidth, .shrinkWidth: "arrow.left.and.right"
        case .growHeight, .shrinkHeight: "arrow.up.and.down"
        case .restore: "arrow.uturn.backward"
        default: nil
        }
    }
}
