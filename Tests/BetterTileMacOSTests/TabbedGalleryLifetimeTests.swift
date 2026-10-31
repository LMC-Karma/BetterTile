import AppKit
import BetterTileCore
import Testing
@testable import BetterTileMacOS

@MainActor private func waitForGalleryCollapse(_ view: TabbedPaneView, advance: (Double) -> Void) async throws -> Bool {
    // Full-suite AppKit work can delay visibility callbacks past the leave deadline.
    for _ in 0..<100 {
        if view.collapsed && view.window?.frame.height == 6 { return true }
        advance(0.02)
        await Task.yield()
    }
    return view.collapsed && view.window?.frame.height == 6
}

@MainActor private func galleryFixture() throws -> (TabbedOverlayController, TabbedPaneView, () -> Bool, (Double) -> Void) {
    _ = NSApplication.shared
    var now = 1000.0
    var local: ((UInt16) -> Bool)?
    let overlay = TabbedOverlayController(addGlobalKeyMonitor: { _ in NSObject() },
        addLocalKeyMonitor: { handler in local = handler; return NSObject() }, removeMonitor: { _ in }, visibilityClock: { now }, automaticallyAdvanceVisibility: false)
    var state = TabbedLayoutState(presentation: .autoHide)
    let id = WindowID(rawValue: "integration-gallery")
    state.reconcile(windowIDs: [id], removed: [], focused: id)
    overlay.refresh(state: state, bounds: BTRect(x: 40000, y: 0, width: 900, height: 700), windows: [])
    let view = try #require(NSApp.windows.compactMap(\.contentView).compactMap { $0 as? TabbedPaneView }.first { $0.pane.id == state.activePaneID })
    return (overlay, view, { local?(53) ?? false }, { elapsed in
        now += elapsed
        overlay.advanceBarVisibility()
    })
}

@Test(.macOSTestApplication, .macOSUI) @MainActor func galleryEscapeCancelsPreviewInAutoHide() throws {
    let (overlay, view, escape, _) = try galleryFixture()
    defer { overlay.hide() }
    let menu = overlay.menu(pane: view.pane, windowID: nil)
    overlay.menuWillOpen(menu)
    overlay.menuDidClose(menu)
    // This is the same factory showLayoutGallery calls after menu tracking ends.
    // Omit panel presentation to keep all synthetic windows off screen.
    let gallery = overlay.makeLayoutGallery()
    gallery.content.select(.rows)
    #expect(overlay.previewedGalleryState != nil)
    #expect(escape())
    #expect(overlay.gallery == nil)
    #expect(overlay.previewedGalleryState == nil)
}

@Test(.macOSTestApplication, .macOSUI) @MainActor func galleryHoldsAutoHideAnchorUntilDismissal() async throws {
    let (overlay, view, _, advance) = try galleryFixture()
    defer { overlay.hide() }
    let menu = overlay.menu(pane: view.pane, windowID: nil)
    overlay.menuWillOpen(menu)
    overlay.menuDidClose(menu)
    let gallery = overlay.makeLayoutGallery()
    #expect(!view.collapsed)
    advance(0.65)
    #expect(overlay.gallery === gallery)
    #expect(!view.collapsed)
    #expect(view.window?.frame.height == 34)
    gallery.cancel()
    #expect(try await waitForGalleryCollapse(view, advance: advance))
}

@Test(.macOSTestApplication, .macOSUI, arguments: ["cancel", "apply", "outside", "hide", "busy", "resize", "work-area",
                  "presentation", "source-disappearance", "replacement"]) @MainActor
func gallerySourceHoldEndsWithItsLifetime(ending: String) async throws {
    let (overlay, _, _, advance) = try galleryFixture()
    defer { overlay.hide() }
    let bounds = BTRect(x: 40000, y: 0, width: 900, height: 700)
    var state = overlay.state
    let first = try #require(state.activeWindowID)
    state.reconcile(windowIDs: [first, WindowID(rawValue: "gallery-second")], removed: [], focused: first)
    state.applyPreset(.columns, grouping: .distributeWindows)
    overlay.refresh(state: state, bounds: bounds, windows: [])
    let source = try #require(state.panes.first { $0.id != state.activePaneID })
    let views = NSApp.windows.compactMap(\.contentView).compactMap { $0 as? TabbedPaneView }
    let sourceView = try #require(views.first { $0.pane.id == source.id })
    let activeView = try #require(views.first { $0.pane.id == state.activePaneID })
    #expect(!source.tabs.isEmpty)
    var applications = 0
    overlay.onIntent = { if case .preset = $0 { applications += 1 } }
    let gallery = overlay.makeLayoutGallery(paneID: source.id)
    gallery.content.select(.rows)
    advance(0.65)
    #expect(!sourceView.collapsed)
    #expect(sourceView.window?.frame.height == 34)
    #expect(activeView.collapsed)

    switch ending {
    case "apply": gallery.content.apply()
    case "outside": gallery.presenter.dismiss()
    // Space and mode exits both use this production teardown path.
    case "hide": overlay.hide()
    case "busy": overlay.acceptsTabDrags = false
    case "resize": overlay.refreshResize(state: state, bounds: bounds)
    case "work-area": overlay.refresh(state: state, bounds: BTRect(x: 40000, y: 0, width: 850, height: 700), windows: [])
    case "presentation":
        var changed = state
        changed.setPresentation(.alwaysVisible)
        overlay.refresh(state: changed, bounds: bounds, windows: [])
    case "source-disappearance":
        var changed = state
        for id in source.tabs { changed.move(id, to: state.activePaneID) }
        changed.removeEmptyPane(source.id)
        overlay.refresh(state: changed, bounds: bounds, windows: [])
        #expect(sourceView.window?.isVisible == false)
    case "replacement":
        let replacement = overlay.makeLayoutGallery()
        gallery.cancel() // A late close from the old chooser must not clear the new hold.
        #expect(overlay.gallery === replacement)
        #expect(try await waitForGalleryCollapse(sourceView, advance: advance))
        #expect(!activeView.collapsed)
        replacement.cancel()
    default: gallery.cancel()
    }
    #expect(overlay.gallery == nil)
    #expect(overlay.previewedGalleryState == nil)
    #expect(applications == (ending == "apply" ? 1 : 0))
    gallery.content.apply()
    #expect(applications == (ending == "apply" ? 1 : 0))
    overlay.acceptsTabDrags = true
    overlay.refresh(state: state, bounds: bounds, windows: [])
    let restoredSource = try #require(NSApp.windows.filter { overlay.windowNumbers.contains($0.windowNumber) }.compactMap(\.contentView)
        .compactMap { $0 as? TabbedPaneView }.first { $0.pane.id == source.id })
    #expect(try await waitForGalleryCollapse(restoredSource, advance: advance))
    #expect(try await waitForGalleryCollapse(activeView, advance: advance))
}
