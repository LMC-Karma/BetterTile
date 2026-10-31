import AppKit
import BetterTileCore
import Testing
@testable import BetterTileMacOS

@Test(.macOSTestApplication, arguments: TabbedPreset.allCases, TabbedStripPresentation.allCases) @MainActor
func tabbedGalleryMarksTheCurrentPresetAndLabelsEveryChoice(preset: TabbedPreset, presentation: TabbedStripPresentation) throws {
    _ = NSApplication.shared
    let gallery = TabbedLayoutGallery(state: TabbedLayoutState(preset: preset, presentation: presentation), onPreview: { _, _ in }, onApply: { _, _ in })
    defer { gallery.cancel() }
    #expect(gallery.content.current == preset)
    #expect(gallery.content.selected == preset)
    #expect(!gallery.content.applyButton.isEnabled)
    #expect(gallery.content.grouping == .keepTabGroups)
    #expect(gallery.content.choices.count == 5)
    for choice in gallery.content.choices {
        #expect(choice.accessibilityLabel() == choice.preset.title + (choice.preset == preset ? ", current layout" : ""))
        #expect(choice.acceptsFirstResponder)
        #expect(choice.nextKeyView != nil)
        #expect(choice.current == (choice.preset == preset))
    }
    gallery.content.setGrouping(.distributeWindows)
    #expect(gallery.content.applyButton.isEnabled) // Redistribution can use the current preset.
}

@Test(.macOSTestApplication, .macOSUI) @MainActor func tabbedGalleryRecognizesCustomGeometryAndKeyboardFocusPreviews() throws {
    _ = NSApplication.shared
    var state = TabbedLayoutState(preset: .columns)
    let bounds = BTRect(x: 0, y: 0, width: 1000, height: 800)
    let branch = try #require(state.dividers(in: bounds).first?.branchID)
    let adjusted = state.adjustDivider(branch, by: 0.1, in: bounds)
    #expect(adjusted)
    #expect(TabbedLayoutGallery.currentPreset(for: state) == nil)
    var previews: [TabbedPreset?] = []
    let gallery = TabbedLayoutGallery(state: state, onPreview: { preset, _ in previews.append(preset) }, onApply: { _, _ in })
    defer { gallery.cancel() }
    #expect(gallery.content.selected == nil)
    #expect(!gallery.content.applyButton.isEnabled)
    let window = NSWindow(contentRect: NSRect(x: 12000, y: 0, width: 366, height: 402),
                          styleMask: [.titled], backing: .buffered, defer: false)
    defer { window.orderOutForTesting() }
    window.contentView = gallery.content
    #expect(window.makeFirstResponder(gallery.content.choices[1]))
    #expect(previews.last == .columns)
    #expect(gallery.content.selected == nil) // Focusing previews without selecting.
    let arrow = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil,
                                            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124))
    gallery.content.choices[1].keyDown(with: arrow)
    #expect(window.firstResponder === gallery.content.choices[2])
    #expect(previews.last == .rows)
    try performNativeClick(gallery.content.choices[2])
    #expect(gallery.content.selected == .rows)
    #expect(gallery.content.applyButton.isEnabled)
}

@Test(.macOSTestApplication, arguments: TabbedStripPresentation.allCases) @MainActor func tabbedGalleryEntryPointsKeepLocalPaneActionsSeparate(presentation: TabbedStripPresentation) throws {
    _ = NSApplication.shared
    let overlay = TabbedOverlayController()
    defer { overlay.hide() }
    let state = TabbedLayoutState(preset: .columns, presentation: presentation)
    overlay.refresh(state: state, bounds: BTRect(x: 12000, y: 0, width: 1000, height: 800), windows: [])
    let pane = state.panes[0]
    let menu = overlay.menu(pane: pane, windowID: nil)
    let entry = try #require(menu.items.first { $0.title == "Layout Gallery…" })
    #expect(entry.submenu == nil)
    #expect(entry.action != nil)
    #expect(menu.items.contains { $0.title == "Remove Empty Pane" })
    #expect(!menu.items.contains { $0.title == "Change Layout" })
    let view = try #require(NSApp.windows.compactMap(\.contentView).compactMap { $0 as? TabbedPaneView }.first { $0.pane.id == pane.id })
    view.layoutSubtreeIfNeeded()
    #expect(!view.content.galleryButton.isHidden)
    #expect(view.content.galleryButton.title == "Choose Layout")
    #expect(view.content.galleryButton.frame.minY >= TabbedLayoutState.headerHeight)
    #expect(view.content.galleryButton.frame.maxY <= view.bounds.maxY)
    #expect(view.accessibilityChildren()?.contains { ($0 as? NSButton) === view.content.galleryButton } == true)
}

@Test(.macOSTestApplication) @MainActor func tabbedGalleryControlsFitThePopover() throws {
    _ = NSApplication.shared
    let gallery = TabbedLayoutGallery(state: TabbedLayoutState(preset: .focus), onPreview: { _, _ in }, onApply: { _, _ in })
    defer { gallery.cancel() }
    let window = NSWindow(contentRect: NSRect(x: 12000, y: 0, width: 366, height: 402),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    defer { window.orderOutForTesting() }
    window.contentView = gallery.content
    gallery.content.layoutSubtreeIfNeeded()
    for control in gallery.content.subviews {
        #expect(gallery.content.bounds.contains(control.frame))
    }
    for choice in gallery.content.choices {
        #expect(!choice.frame.intersects(gallery.content.applyButton.frame))
    }
}


@Test(.macOSTestApplication) @MainActor func tabbedGalleryDoesNotUseActivationSensitiveTransientDismissal() {
    _ = NSApplication.shared
    let gallery = TabbedLayoutGallery(state: TabbedLayoutState(preset: .columns),
                                      onPreview: { _, _ in }, onApply: { _, _ in })
    defer { gallery.cancel() }
    #expect(gallery.presenter.panel.styleMask.contains(.nonactivatingPanel))
    #expect(gallery.content.acceptsFirstMouse(for: nil))
    #expect(gallery.content.choices.allSatisfy { $0.acceptsFirstMouse(for: nil) })
}
