import AppKit
import BetterTileCore
import Testing
@testable import BetterTileMacOS

/// Never orders a real window, so the policy tests cannot interrupt a live session.
@MainActor final class ChooserWindow: TabbedChooserPanel {
    var frontOrders = 0
    override func orderFrontRegardless() { frontOrders += 1 }
    override func orderOut(_ sender: Any?) {}
}

@Test(.macOSTestApplication) @MainActor func tabbedPopoverClearsFloatingPanesAndNormalCurtainsWithoutHidingOnDeactivate() {
    _ = NSApplication.shared
    let window = ChooserWindow(contentRect: NSRect(x: 12400, y: 0, width: 364, height: 390),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    defer { window.close() }
    window.isReleasedWhenClosed = false
    window.hidesOnDeactivate = true
    let display = NSRect(x: 12000, y: 0, width: 1210, height: 812)
    let pane = NSRect(x: 12000, y: 0, width: 600, height: 812)
    let presenter = TabbedChooserPresenter(content: NSView(), size: NSSize(width: 364, height: 390), panel: window)
    presenter.present(anchorFrame: NSRect(x: pane.maxX - 20, y: pane.maxY - 20, width: 20, height: 20), paneFrame: pane, screenFrame: display)
    #expect(window.level.rawValue > NSWindow.Level.floating.rawValue)
    #expect(window.level.rawValue > NSWindow.Level.normal.rawValue)
    #expect(!window.hidesOnDeactivate)
    #expect(window.collectionBehavior == [.transient, .ignoresCycle])
    #expect(!window.collectionBehavior.contains(.moveToActiveSpace))
    #expect(!window.collectionBehavior.contains(.canJoinAllSpaces))
    #expect(pane.contains(window.frame))
    #expect(window.frontOrders == 1)
}

@Test(.macOSTestApplication, arguments: [NSSize(width: 320, height: 420), NSSize(width: 364, height: 364)]) @MainActor
func tabbedPopoverClampsBothChooserSizesToThePaneOrOwningDisplay(size: NSSize) {
    let display = NSRect(x: -1210, y: -300, width: 1210, height: 812)
    let left = NSRect(x: -1210, y: -300, width: 602, height: 812)
    // The left-pane + is near the split, so AppKit's centered window crosses the boundary.
    let crossing = NSRect(x: left.maxX - 40, y: display.maxY - 100, width: size.width, height: size.height)
    let clamped = TabbedChooserPresenter.clampedFrame(crossing, paneFrame: left, screenFrame: display)
    #expect(clamped.size == size)
    #expect(left.contains(clamped))
    #expect(clamped.maxX == left.maxX)
    #expect(clamped.maxY == left.maxY)

    let right = NSRect(x: -602, y: -300, width: 602, height: 812)
    let outside = NSRect(x: -50, y: -500, width: size.width, height: size.height)
    let rightFrame = TabbedChooserPresenter.clampedFrame(outside, paneFrame: right, screenFrame: display)
    #expect(right.contains(rightFrame))
    #expect(rightFrame.minY == right.minY)

    let narrow = NSRect(x: -600, y: 100, width: 200, height: 200)
    let fallback = TabbedChooserPresenter.clampedFrame(outside, paneFrame: narrow, screenFrame: display)
    #expect(display.contains(fallback))
    #expect(fallback.size == size)
    #expect(!narrow.contains(fallback))

    let short = NSRect(x: left.minX, y: left.minY, width: left.width, height: 200)
    let partial = TabbedChooserPresenter.clampedFrame(crossing, paneFrame: short, screenFrame: display)
    #expect(partial.minX >= short.minX && partial.maxX <= short.maxX)
    #expect(display.contains(partial))

    let noPane = TabbedChooserPresenter.clampedFrame(outside, paneFrame: nil, screenFrame: display)
    #expect(display.contains(noPane))
}

@Test(.macOSTestApplication) @MainActor func tabbedPopoverUsesFullPaneGeometryRatherThanTheStripPanelFrame() throws {
    _ = NSApplication.shared
    let state = TabbedLayoutState(preset: .columns)
    let bounds = BTRect(x: 12000, y: 20, width: 1210, height: 750)
    let overlay = TabbedOverlayController(panelFactory: {
        ChooserWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    }, orderPanel: { _, _, _ in })
    defer { overlay.hide() }
    overlay.refresh(state: state, bounds: bounds, windows: [])
    let pane = state.panes[0]
    let logical = try #require(state.frames(in: bounds)[pane.id])
    #expect(overlay.paneFrameInAppKit(pane.id) == CoordinateConverter.toAppKit(logical,
        mainScreenFrame: NSScreen.screens.first?.frame ?? .zero))
    #expect(overlay.paneFrameInAppKit(pane.id)?.height == 750)
    #expect(overlay.paneFrameInAppKit(UUID()) == nil)
}


@Test(.macOSTestApplication) @MainActor func tabbedPopoverLevelSurvivesTheAnchorPanesNextRefresh() {
    _ = NSApplication.shared
    let parent = ChooserWindow(contentRect: NSRect(x: 12000, y: 0, width: 600, height: 34),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    let chooser = ChooserWindow(contentRect: NSRect(x: 12000, y: 0, width: 364, height: 390),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    parent.isReleasedWhenClosed = false
    chooser.isReleasedWhenClosed = false
    defer { chooser.parent?.removeChildWindow(chooser); chooser.close(); parent.close() }
    parent.level = .normal
    let presenter = TabbedChooserPresenter(content: NSView(), size: NSSize(width: 364, height: 390), panel: chooser)
    presenter.present(anchorFrame: parent.frame, paneFrame: nil,
        screenFrame: NSRect(x: 12000, y: 0, width: 1210, height: 812))
    #expect(chooser.parent == nil)
    #expect(parent.level == .normal)
    #expect(chooser.level.rawValue > NSWindow.Level.floating.rawValue)
    // Overlay refreshes repeatedly set the anchor's validated or floating fallback level.
    parent.level = .floating
    parent.level = .normal
    #expect(chooser.level.rawValue > NSWindow.Level.floating.rawValue)
}



@Test(.macOSTestApplication, arguments: [GlobalGestureEventKind.leftMouseDown, .leftMouseDragged, .leftMouseUp]) @MainActor
func tabbedChooserOnlyOutsideMouseDownDismisses(kind: GlobalGestureEventKind) {
    _ = NSApplication.shared
    let panel = ChooserWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    let presenter = TabbedChooserPresenter(content: NSView(), size: NSSize(width: 364, height: 364), panel: panel)
    defer { presenter.dismiss() }
    presenter.present(anchorFrame: NSRect(x: -800, y: 500, width: 20, height: 20), paneFrame: nil,
                      screenFrame: NSRect(x: -1200, y: -300, width: 1200, height: 900))
    let main = NSScreen.screens.first?.frame ?? .zero
    func event(_ point: NSPoint, timestamp: UInt64 = 0) -> GlobalGestureEvent {
        GlobalGestureEvent(kind: kind, position: CoordinateConverter.pointToTopLeft(point, mainScreenFrame: main),
                           button: 0, modifiers: [], timestamp: timestamp)
    }
    presenter.handleMouseEvent(event(NSPoint(x: panel.frame.midX, y: panel.frame.midY)))
    #expect(presenter.isPresented)
    let outside = NSPoint(x: panel.frame.maxX + 1, y: panel.frame.midY)
    presenter.handleMouseEvent(event(outside, timestamp: 1)) // Queued opening sample.
    #expect(presenter.isPresented)
    presenter.handleMouseEvent(event(outside))
    #expect(presenter.isPresented == (kind != .leftMouseDown))
}

@Test(.macOSTestApplication, arguments: [NSSize(width: 320, height: 420), NSSize(width: 364, height: 364)]) @MainActor
func tabbedChooserGlobalRightClickUsesFrameAndOpeningTimeAndRemovesMonitors(size: NSSize) throws {
    _ = NSApplication.shared
    let panel = ChooserWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    let presenter = TabbedChooserPresenter(content: NSView(), size: size, panel: panel, now: { 1_000 })
    defer { presenter.dismiss() }
    var rightClick: (@MainActor (NSPoint, TimeInterval) -> Void)?
    let globalToken = NSObject()
    var globalRemovals = 0
    var localRemovals = 0
    var dismissals = 0
    presenter.addGlobalRightMouseMonitor = { rightClick = $0; return globalToken }
    presenter.removeMonitor = { token in
        if token as AnyObject === globalToken { globalRemovals += 1 }
        else { localRemovals += 1; NSEvent.removeMonitor(token) }
    }
    presenter.onDismiss = { dismissals += 1 }
    let beforeOpening = 999.0
    presenter.present(anchorFrame: NSRect(x: -800, y: 500, width: 20, height: 20), paneFrame: nil,
        screenFrame: NSRect(x: -1200, y: -300, width: 1200, height: 900))
    let send = try #require(rightClick)
    let outside = NSPoint(x: panel.frame.maxX + 1, y: panel.frame.midY)
    send(outside, beforeOpening)
    #expect(presenter.isPresented)
    send(NSPoint(x: panel.frame.midX, y: panel.frame.midY), 1_001)
    #expect(presenter.isPresented)
    send(outside, 1_001)
    #expect(!presenter.isPresented)
    #expect(globalRemovals == 1 && localRemovals == 1)
    presenter.dismiss()
    send(outside, 1_001) // A late callback has no owner effects.
    #expect(dismissals == 1)
    #expect(globalRemovals == 1 && localRemovals == 1)
}

@Test(.macOSTestApplication, arguments: ["space", "bounds", "display", "pane", "exit", "apply"]) @MainActor
func tabbedGalleryOwnedPanelClosesWithItsOwner(ending: String) throws {
    _ = NSApplication.shared
    let overlay = TabbedOverlayController(panelFactory: {
        ChooserWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    }, orderPanel: { _, _, _ in })
    defer { overlay.hide() }
    let state = TabbedLayoutState(preset: .columns)
    let bounds = BTRect(x: 12000, y: 0, width: 1000, height: 800)
    overlay.refresh(state: state, bounds: bounds, windows: [])
    let gallery = overlay.makeLayoutGallery(presenterFactory: { content, size in
        TabbedChooserPresenter(content: content, size: size, panel: ChooserWindow(contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false))
    })
    gallery.presenter.present(anchorFrame: .zero, paneFrame: nil,
                              screenFrame: NSRect(x: 12000, y: 0, width: 1000, height: 800))
    gallery.content.select(.grid)
    #expect(overlay.previewedGalleryState != nil)
    switch ending {
    case "space": overlay.prepareForSpaceChange()
    case "bounds": overlay.refresh(state: state, bounds: BTRect(x: 12000, y: 0, width: 900, height: 800), windows: [])
    case "pane": overlay.refresh(state: TabbedLayoutState(preset: .single), bounds: bounds, windows: [])
    case "apply": gallery.content.apply()
    default: overlay.hide() // Display loss and Tabbed exit both tear down the overlay.
    }
    #expect(!gallery.presenter.isPresented)
    #expect(!gallery.presenter.panel.isVisible)
    #expect(overlay.gallery == nil)
    #expect(overlay.previewedGalleryState == nil)
}

/// Records key acquisition without taking focus from the user's live session.
/// Native cross-application keyboard restoration remains a live check.
@MainActor private final class ClickKeyChooserWindow: TabbedChooserPanel {
    private var key = false
    var keyRequests = 0
    override var isKeyWindow: Bool { key }
    override func orderFrontRegardless() {}
    override func makeKey() { keyRequests += 1; key = true }
    override func orderOut(_ sender: Any?) { key = false }
}



// These tests inspect key state or share a real-key fixture; run only while the Mac is unattended.
// Add only reviewed real-key or activation cases; keep all other tests in default suites and update NativeLaneMembership.
@Suite(.enabled(if: NativeFocusTestLane.isEnabled, "Requires an unattended Mac; set BETTERTILE_NATIVE_FOCUS_TESTS=1"), .nativeFocus)
@MainActor struct NativeFocusTabbedPopoverPresentationTests {
    @Test(.macOSTestApplication) @MainActor func tabbedChooserShowDoesNotActivateOrTakeKeyAndEscapeDismissesOnce() throws {
        _ = NSApplication.shared
        let panel = ChooserWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let content = NSView()
        let presenter = TabbedChooserPresenter(content: content, size: NSSize(width: 320, height: 420), panel: panel)
        defer { presenter.dismiss() }
        let active = NSApp.isActive
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let key = NSApp.keyWindow
        var dismissals = 0
        presenter.onDismiss = { dismissals += 1 }
        presenter.present(anchorFrame: NSRect(x: 940, y: 700, width: 20, height: 20),
                          paneFrame: NSRect(x: 0, y: 0, width: 960, height: 900),
                          screenFrame: NSRect(x: 0, y: 0, width: 1920, height: 900))
        #expect(presenter.isPresented)
        #expect(panel.frame.maxX == 960)
        #expect(panel.canBecomeKey && !panel.canBecomeMain && !panel.becomesKeyOnlyIfNeeded)
        #expect(panel.contentView?.acceptsFirstMouse(for: nil) == true)
        #expect(panel.contentView?.layer?.cornerRadius == 12)
        #expect(NSApp.isActive == active)
        #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost)
        #expect(NSApp.keyWindow === key, Comment(rawValue: keyWindowDiagnostics(key)))
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53))
        panel.sendEvent(escape)
        #expect(!presenter.isPresented)
        #expect(dismissals == 1)
        presenter.dismiss()
        #expect(dismissals == 1)
        #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost)
    }

    @Test(.macOSTestApplication, arguments: [NSSize(width: 320, height: 420), NSSize(width: 364, height: 364)],
          [NSEvent.EventType.leftMouseDown, .rightMouseDown]) @MainActor
    func tabbedChooserInsideClickTakesKeyWithoutActivationAndEscapeDismisses(size: NSSize, type: NSEvent.EventType) throws {
        _ = NSApplication.shared
        try #require(!NSApp.isActive)
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let panel = ClickKeyChooserWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        let presenter = TabbedChooserPresenter(content: NSView(), size: size, panel: panel)
        defer { presenter.dismiss(); panel.close() }
        presenter.present(anchorFrame: NSRect(x: 12500, y: 700, width: 20, height: 20), paneFrame: nil,
            screenFrame: NSRect(x: 12000, y: 0, width: 1200, height: 900))
        #expect(!panel.isKeyWindow, Comment(rawValue: keyWindowDiagnostics(panel)))
        let click = try #require(NSEvent.mouseEvent(with: type,
            location: NSPoint(x: size.width / 2, y: size.height / 2), modifierFlags: [],
            timestamp: 0, windowNumber: panel.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        panel.sendEvent(click)
        #expect(panel.isKeyWindow, Comment(rawValue: keyWindowDiagnostics(panel)))
        #expect(panel.keyRequests == 1)
        #expect(!panel.becomesKeyOnlyIfNeeded)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(!NSApp.isActive)
        #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost)
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53))
        panel.sendEvent(escape)
        #expect(!presenter.isPresented)
        #expect(!panel.isKeyWindow, Comment(rawValue: keyWindowDiagnostics(panel)))
        #expect(!NSApp.isActive)
        #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost)
    }
}
