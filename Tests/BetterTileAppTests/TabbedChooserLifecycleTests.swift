import AppKit
import BetterTileCore
import Testing
@testable import BetterTileMacOS
@testable import BetterTileApp

/// Records presentation without ordering a real window or taking keyboard focus.
@MainActor private final class LifecycleChooserPanel: OffscreenChooserTestPanel {
    var shown = false
    var keyRequests = 0
    var mouseDowns = 0
    override var isVisible: Bool { shown }
    override func orderFrontRegardless() { shown = true }
    override func orderOut(_ sender: Any?) { shown = false }
    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) { shown = place != .out }
    override func makeKey() { keyRequests += 1 }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown { mouseDowns += 1 }
        else { super.sendEvent(event) }
    }
}

@MainActor private func lifecyclePresenter(_ content: NSView, _ size: NSSize) -> TabbedChooserPresenter {
    TabbedChooserPresenter(content: content, size: size, panel: LifecycleChooserPanel(contentRect: .zero,
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false), now: { 1_000 })
}

@MainActor private func presentForLifecycle(_ presenter: TabbedChooserPresenter) {
    presenter.present(anchorFrame: NSRect(x: 12500, y: 700, width: 24, height: 24),
        paneFrame: NSRect(x: 12000, y: 0, width: 600, height: 800),
        screenFrame: NSRect(x: 12000, y: 0, width: 1200, height: 800))
}

@MainActor private func chooserDown(_ presenter: TabbedChooserPresenter, inside: Bool) -> GlobalGestureEvent {
    let frame = presenter.panel.frame
    let point = NSPoint(x: inside ? frame.midX : frame.maxX + 1, y: frame.midY)
    return GlobalGestureEvent(kind: .leftMouseDown,
        position: CoordinateConverter.pointToTopLeft(point, mainScreenFrame: NSScreen.screens.first?.frame ?? .zero),
        button: 0, modifiers: [], timestamp: 0)
}

/// Receives synthetic in-process clicks without dispatching them to real controls.
@MainActor private final class ChooserClickWindow: NSPanel {
    var onClick: (() -> Void)?
    var clicks = 0
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            clicks += 1
            onClick?()
        }
    }
}

@Test(.appTestApplication, .settingsUI, arguments: ["picker", "gallery"], [NSEvent.EventType.leftMouseDown, .rightMouseDown]) @MainActor
func tabbedChooserOwnWindowClicksDismissOutsideAndKeepInsideAndOpener(chooser: String, type: NSEvent.EventType) throws {
    _ = NSApplication.shared
    let request = PaneApplicationRequest(paneID: UUID(), paneNumber: 1,
        displayID: DisplayID(rawValue: "own-click"), sessionID: DesktopSessionID(rawValue: UUID()),
        spaceID: nil, generation: 0, workArea: BTRect(x: 12000, y: 0, width: 1200, height: 800))
    let picker = PaneApplicationPopover(request: request, recentApplications: RecentApplications(defaults: MemoryDefaults()),
        presenterFactory: lifecyclePresenter)
    let gallery = TabbedLayoutGallery(state: TabbedLayoutState(preset: .columns), onPreview: { _, _ in },
        onApply: { _, _ in }, presenterFactory: lifecyclePresenter)
    let presenter = chooser == "picker" ? picker.presenter : gallery.presenter
    let previous = chooser == "picker" ? gallery.presenter : picker.presenter
    defer { picker.close(); gallery.cancel() }
    let ownWindow = ChooserClickWindow(contentRect: NSRect(x: 14000, y: 0, width: 600, height: 800),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    ownWindow.isReleasedWhenClosed = false
    defer { ownWindow.close() }
    func click(at screenPoint: NSPoint, in window: NSWindow) throws {
        let event = try #require(NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: screenPoint),
            modifierFlags: [], timestamp: 1_001, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        NSApp.sendEvent(event)
    }
    // Local monitors run before the target window handles the opening click.
    // Replacing the other chooser must dismiss that one without closing the new one.
    presentForLifecycle(previous)
    ownWindow.onClick = {
        #expect(!previous.isPresented)
        presentForLifecycle(presenter)
    }
    try click(at: NSPoint(x: ownWindow.frame.midX, y: ownWindow.frame.midY), in: ownWindow)
    #expect(presenter.isPresented)
    ownWindow.onClick = nil
    try click(at: NSPoint(x: presenter.panel.frame.midX, y: presenter.panel.frame.midY), in: presenter.panel)
    #expect(presenter.isPresented)
    #expect((presenter.panel as? LifecycleChooserPanel)?.mouseDowns == 1)
    try click(at: NSPoint(x: ownWindow.frame.midX, y: ownWindow.frame.midY), in: ownWindow)
    #expect(!presenter.isPresented)
    #expect(ownWindow.clicks == 2) // Observation never consumes the target's click.
}

@Test(.appTestApplication, .settingsUI, arguments: ["outside", "escape", "pane", "space", "display", "exit"]) @MainActor
func paneApplicationOwnedPanelDismissesThroughModel(ending: String) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.panes.count == 2 && !model.hasPendingTabbedPlacement })
    let pane = try #require(model.activeTabbedState?.panes.last?.id)
    let request = try #require(model.beginPaneApplicationPicker(paneID: pane, on: system.mainDisplay.id))
    let picker = PaneApplicationPopover(request: request, recentApplications: RecentApplications(defaults: MemoryDefaults()),
                                        presenterFactory: lifecyclePresenter)
    picker.onDismiss = { [weak model] in model?.dismissPaneApplicationPicker(requestID: request.id) }
    model.paneApplicationPopover = picker
    presentForLifecycle(picker.presenter)
    model.receiveTabbedChooserMouseEvent(chooserDown(picker.presenter, inside: true))
    #expect(picker.presenter.isPresented)
    switch ending {
    case "outside": model.receiveTabbedChooserMouseEvent(chooserDown(picker.presenter, inside: false))
    case "escape": picker.presenter.panel.cancelOperation(nil)
    case "pane":
        model.performTabbed(.removePane(pane))
        try #require(await waitFor { !model.hasPendingTabbedPlacement && model.activeTabbedState?.panes.count == 1 })
        model.advancePaneApplicationRequest()
    case "space": model.beginActiveSpaceStabilization()
    case "display":
        system.availableDisplays.removeAll()
        model.handleApplicationTopologyChange()
        model.advancePaneApplicationRequest()
    default: model.setActiveMode(.manual)
    }
    #expect(!picker.presenter.isPresented)
    #expect(!picker.presenter.panel.isVisible)
    #expect(model.paneApplicationRequest == nil)
    #expect(model.paneApplicationPopover == nil)
    #expect((picker.presenter.panel as? LifecycleChooserPanel)?.keyRequests == 0)
}

@Test(.appTestApplication, .settingsUI) @MainActor func tabbedGalleryOwnedPanelSurvivesAnotherAppFrontmostThenOutsideClickClosesIt() async throws {
    _ = NSApplication.shared
    UserDefaults.standard.register(defaults: ["disableSharedGestureEvents": true])
    let system = FakeAppWindowSystem()
    let model = makeOffscreenModel(store: ConfigurationStore(fileURL: URL(filePath: "/tmp/BetterTileChooser-\(UUID().uuidString)/configuration.json")),
                                system: system, startRuntime: false, presentsTabbedChrome: true)
    model.primaryButtonIsPressed = { false }
    defer { model.shutdown() }
    var overlays: [TabbedOverlayController] = []
    model.tabbedOverlayFactory = {
        let overlay = TabbedOverlayController(panelFactory: {
            LifecycleChooserPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        }, addGlobalKeyMonitor: { _ in NSObject() }, addLocalKeyMonitor: { _ in NSObject() },
           removeMonitor: { _ in }, orderPanel: { panel, mode, anchor in panel.order(mode, relativeTo: anchor) })
        overlays.append(overlay)
        return overlay
    }
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState != nil && !model.hasPendingTabbedPlacement && !overlays.isEmpty })
    let overlay = try #require(overlays.last)
    let gallery = overlay.makeLayoutGallery(presenterFactory: lifecyclePresenter)
    // The fake window system makes an unrelated app focused before opening.
    var other = system.windows[0]
    other.id = WindowID(rawValue: "frontmost-other-app")
    other.processIdentifier = 9001
    other.bundleIdentifier = "example.Other"
    other.isFloating = true
    system.windows.append(other)
    system.focusedID = other.id
    let raises = system.raiseRequests.count
    let focusRequests = system.focusRequests.count
    // The model receives this provider through its injected window system.
    let frontmostApplication = { system.frontmostProcessIdentifier }
    let frontmost = frontmostApplication()
    presentForLifecycle(gallery.presenter)
    model.handleApplicationActivation()
    await model.tabbedFocusTask?.value
    #expect(gallery.presenter.isPresented)
    #expect(gallery.presenter.panel.isVisible)
    #expect(!gallery.presenter.panel.hidesOnDeactivate)
    #expect(system.focusedID == other.id)
    #expect(system.raiseRequests.count == raises)
    // The model asks the window system for focus whenever it activates an app.
    // `NSApp.activate` itself is not observable here, and real frontmost state is machine state.
    #expect(system.focusRequests.count == focusRequests, "BetterTile must not take focus for the gallery")
    #expect(system.applicationActivations.isEmpty, "BetterTile must not activate an application for the gallery")
    #expect(frontmostApplication() == frontmost)
    #expect((gallery.presenter.panel as? LifecycleChooserPanel)?.keyRequests == 0)
    model.receiveTabbedChooserMouseEvent(chooserDown(gallery.presenter, inside: true))
    #expect(gallery.presenter.isPresented)
    model.receiveTabbedChooserMouseEvent(chooserDown(gallery.presenter, inside: false))
    #expect(!gallery.presenter.isPresented)
    #expect(!gallery.presenter.panel.isVisible)
    #expect(overlay.gallery == nil)
    #expect(system.focusedID == other.id)
    #expect(system.focusRequests.count == focusRequests, "Closing the gallery must not take focus either")
    #expect(system.applicationActivations.isEmpty, "Closing the gallery must not activate an application either")
}
