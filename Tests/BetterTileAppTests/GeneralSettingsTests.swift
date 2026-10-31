import AppKit
import BetterTileCore
import SwiftUI
import Testing
@testable import BetterTileApp

@MainActor final class FakeLaunchAtLogin: LaunchAtLoginService {
    struct Refusal: LocalizedError {
        var errorDescription: String? { "The operation could not be completed." }
    }

    var state: LaunchAtLoginState
    var requests: [Bool] = []
    var openedLoginItems = 0
    /// When set, a request fails and macOS keeps its previous state.
    var failure: (any Error)?
    /// The state macOS reports after a successful registration.
    var registeredState: LaunchAtLoginState = .on

    init(_ state: LaunchAtLoginState) {
        self.state = state
    }

    func setEnabled(_ enabled: Bool) throws {
        requests.append(enabled)
        if let failure { throw failure }
        state = enabled ? registeredState : .off
    }

    func openLoginItemsSettings() {
        openedLoginItems += 1
    }
}

@MainActor @Suite(.appTestApplication, .serialized) struct GeneralSettingsTests {
    @Test func menuBarIconSettingReachesTheStatusItems() {
        let model = makeModel(system: FakeAppWindowSystem())
        defer { model.shutdown() }
        var visibility: [Bool] = []
        model.setMenuBarIconVisible = { visibility.append($0) }
        model.updateConfiguration { $0.showMenuBarIcon = false }
        model.updateConfiguration { $0.showDockIcon = false }
        model.updateConfiguration { $0.showMenuBarIcon = true }
        #expect(visibility == [false, true])
    }

    @Test func requestingAccessibilityRemembersThatMacOSShowedItsPrompt() {
        let system = FakeAppWindowSystem()
        system.permission = false
        let model = makeModel(system: system)
        defer { model.shutdown() }
        #expect(!model.configuration.accessibilityPromptRequested)
        model.requestAccessibilityPermission()
        #expect(model.configuration.accessibilityPromptRequested)
        // The request still explains where to enable access.
        #expect(model.statusMessage?.contains("Accessibility") == true)
    }

    @Test func requestingAccessibilityWhenTrustedChangesNothing() {
        let model = makeModel(system: FakeAppWindowSystem())
        defer { model.shutdown() }
        model.requestAccessibilityPermission()
        #expect(!model.configuration.accessibilityPromptRequested)
    }
}

/// The Launch at login switch shows the state macOS reports, not the state the user asked for.
/// These tests drive the hosted switch with a fake service, so no real login item changes.
@MainActor @Suite(.appTestApplication, .serialized, .settingsUI) struct LaunchAtLoginSettingsTests {
    @MainActor private struct Page {
        let model: BetterTileModel
        let host: SettingsSnapshotHost

        /// The first switch on the page, in the Startup group.
        var toggle: NSSwitch? {
            func switches(_ view: NSView) -> [NSSwitch] {
                ((view as? NSSwitch).map { [$0] } ?? []) + view.subviews.flatMap(switches)
            }
            return switches(host.view).max { $0.convert($0.bounds, to: nil).minY < $1.convert($1.bounds, to: nil).minY }
        }

        func waitForToggle(_ description: String, _ ready: (NSSwitch) -> Bool) async throws {
            try await waitForSettingsUI(description, in: host.view) { toggle.map(ready) ?? false }
        }

        func close() {
            host.close()
            model.shutdown()
        }
    }

    private func makePage(_ service: FakeLaunchAtLogin) throws -> Page {
        let model = makeModel(system: FakeAppWindowSystem())
        let page = SettingsTestFactory.makeGeneralSettingsPage(
            model: model, openSetup: {}, search: "", openShortcuts: {}, openSnapZones: {}, launchAtLogin: service
        )
        let host = try SettingsSnapshotHost(page, dark: false, width: 770, height: 900, fitHeight: false)
        return Page(model: model, host: host)
    }

    @Test(arguments: [(LaunchAtLoginState.off, true), (.on, false)])
    func switchRegistersOrUnregistersAndShowsTheNewState(initial: LaunchAtLoginState, enabled: Bool) async throws {
        let service = FakeLaunchAtLogin(initial)
        let page = try makePage(service)
        defer { page.close() }
        try await page.waitForToggle("the initial state") { $0.state == (enabled ? .off : .on) }
        try #require(page.toggle).performClick(nil)
        try await page.waitForToggle("the changed state") { $0.state == (enabled ? .on : .off) }
        #expect(service.requests == [enabled])
        #expect(service.state == (enabled ? .on : .off))
        #expect(page.model.statusMessage == nil)
    }

    /// macOS can register BetterTile but wait for the user's approval in Login Items. The switch stays on.
    @Test func registrationThatNeedsApprovalKeepsTheSwitchOn() async throws {
        let service = FakeLaunchAtLogin(.off)
        service.registeredState = .needsApproval
        let page = try makePage(service)
        defer { page.close() }
        try await page.waitForToggle("the initial state") { $0.state == .off }
        try #require(page.toggle).performClick(nil)
        try await page.waitForToggle("the switch after registration") { $0.state == .on }
        #expect(service.requests == [true])
        #expect(service.state == .needsApproval)
        #expect(page.model.statusMessage == nil)
    }

    @Test(arguments: [(LaunchAtLoginState.off, true), (.on, false)])
    func aRefusedChangeKeepsTheReportedStateAndExplainsTheFailure(
        initial: LaunchAtLoginState, enabled: Bool
    ) async throws {
        let service = FakeLaunchAtLogin(initial)
        service.failure = FakeLaunchAtLogin.Refusal()
        let page = try makePage(service)
        defer { page.close() }
        let shown: NSControl.StateValue = initial == .on ? .on : .off
        try await page.waitForToggle("the initial state") { $0.state == shown }
        try #require(page.toggle).performClick(nil)
        try await waitForSettingsUI("the failure message", in: page.host.view) { page.model.statusMessage != nil }
        #expect(service.requests == [enabled])
        #expect(page.model.statusMessage
            == "Launch at login could not change: The operation could not be completed.")
        try await page.waitForToggle("the state macOS still reports") { $0.state == shown }
    }

    @Test func anUnavailableServiceDisablesTheSwitch() async throws {
        let service = FakeLaunchAtLogin(.unavailable)
        let page = try makePage(service)
        defer { page.close() }
        try await page.waitForToggle("the disabled switch") { !$0.isEnabled && $0.state == .off }
        #expect(service.requests.isEmpty)
    }

    @Test func activatingTheAppShowsAChangeMadeInSystemSettings() async throws {
        let service = FakeLaunchAtLogin(.off)
        let page = try makePage(service)
        defer { page.close() }
        try await page.waitForToggle("the initial state") { $0.state == .off }
        service.state = .on
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        try await page.waitForToggle("the state changed in System Settings") { $0.state == .on }
        #expect(service.requests.isEmpty)
    }
}

/// Offline snapshots of General and of the Settings window. They write PNGs only when `BT_SNAPSHOT_DIR` is set.
@MainActor @Suite(.appTestApplication, .serialized) struct GeneralSettingsSnapshotTests {
    nonisolated static let snapshotDirectory = ProcessInfo.processInfo.environment["BT_SNAPSHOT_DIR"]

    enum State: String, CaseIterable {
        case normal, accessibilityFirstRequest, accessibilityPromptDismissed, menuBarIconOff, loginNeedsApproval
    }

    struct Variant: CustomTestStringConvertible {
        var state: State, dark: Bool, width: Double
        var testDescription: String { "\(state.rawValue) \(dark ? "dark" : "light") \(Int(width))" }
    }

    nonisolated static let variants: [Variant] = snapshotDirectory == nil
        ? [Variant(state: .accessibilityFirstRequest, dark: false, width: 770)]
        : State.allCases.flatMap { state in
            [false, true].flatMap { dark in [770.0, 1070].map { Variant(state: state, dark: dark, width: $0) } }
        }

    @Test(arguments: variants)
    func rendersGeneral(variant: Variant) throws {
        let system = FakeAppWindowSystem()
        let model = makeModel(system: system)
        defer { model.shutdown() }
        var launch = FakeLaunchAtLogin(.on)
        switch variant.state {
        case .normal:
            break
        case .accessibilityFirstRequest:
            system.permission = false
            _ = model.refreshPermission()
        case .accessibilityPromptDismissed:
            system.permission = false
            _ = model.refreshPermission()
            model.updateConfiguration { $0.accessibilityPromptRequested = true }
        case .menuBarIconOff:
            model.updateConfiguration { $0.showMenuBarIcon = false }
        case .loginNeedsApproval:
            launch = FakeLaunchAtLogin(.needsApproval)
        }
        let page = SettingsTestFactory.makeGeneralSettingsPage(
            model: model, openSetup: {}, search: "", openShortcuts: {}, openSnapZones: {}, launchAtLogin: launch
        )
        let host = try SettingsSnapshotHost(page, dark: variant.dark, width: variant.width, height: 2400)
        defer { host.close() }
        let bitmap = try host.render()
        #expect(bitmap.pixelsWide >= Int(variant.width))
        #expect(launch.requests.isEmpty, "Rendering must not change Launch at login")
        try write(bitmap, name: "general-\(variant.state.rawValue)-\(variant.dark ? "dark" : "light")-\(Int(variant.width))")
    }

    @Test(arguments: [SettingsDestination.general, .applicationRules], [980.0, 1280])
    func longConfigurationDiagnosticFitsSettings(destination: SettingsDestination, width: Double) throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var path = directory
        for _ in 0 ..< 6 {
            path.append(path: String(repeating: "long-configuration-path-", count: 4))
        }
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let file = path.appending(path: "configuration.json")
        try Data("broken JSON".utf8).write(to: file)
        let system = FakeAppWindowSystem()
        system.permission = false
        system.windows.removeAll()
        let model = makeOffscreenModel(store: ConfigurationStore(fileURL: file), system: system, startRuntime: false)
        defer { model.shutdown() }
        #expect(try #require(model.configurationSaveBlockedReason).count >= 906)
        let view = NSHostingView(rootView: SettingsTestFactory.makeSettingsView(
            model: model, openSetup: {}, selection: destination
        ))
        let bounds = NSRect(x: 0, y: 0, width: width, height: 640)
        let window = OffscreenTestWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        window.setContentSize(bounds.size)
        turnNativeRunLoop(layout: view)
        #expect(view.fittingSize.width > 0 && view.fittingSize.width <= bounds.width)
        #expect(view.intrinsicContentSize.width > 0 && view.intrinsicContentSize.width <= bounds.width)
        #expect(view.fittingSize.height > 0 && view.fittingSize.height <= bounds.height)
        #expect(view.intrinsicContentSize.height > 0 && view.intrinsicContentSize.height <= bounds.height)
        #expect(system.frameWriteCounts.isEmpty)
    }

    @Test(.enabled(if: snapshotDirectory != nil, "Writes window PNGs only when BT_SNAPSHOT_DIR is set."))
    func rendersTheWindowWithSidebarTiles() throws {
        for dark in [false, true] {
            for size in [NSSize(width: 980, height: 640), NSSize(width: 1280, height: 800)] {
                let model = makeModel(system: FakeAppWindowSystem())
                defer { model.shutdown() }
                let host = try SettingsSnapshotHost(SettingsTestFactory.makeSettingsView(model: model, openSetup: {}), dark: dark,
                                                    width: size.width, height: size.height, fitHeight: false)
                defer { host.close() }
                try write(host.render(), name: "window-general-\(dark ? "dark" : "light")-\(Int(size.width))")
            }
        }
    }

    private func write(_ bitmap: NSBitmapImageRep, name: String) throws {
        guard let directory = Self.snapshotDirectory else { return }
        let folder = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: folder.appendingPathComponent(name + ".png"))
    }
}
