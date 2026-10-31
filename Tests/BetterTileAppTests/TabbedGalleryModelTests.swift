import AppKit
import BetterTileCore
import Testing
@testable import BetterTileMacOS
@testable import BetterTileApp

@MainActor private func galleryModel(_ system: FakeAppWindowSystem) async throws -> BetterTileModel {
    _ = NSApplication.shared
    for index in 1..<5 {
        var window = system.windows[0]
        window.id = WindowID(rawValue: "gallery-\(index)")
        window.processIdentifier += Int32(index)
        system.windows.append(window)
    }
    let model = makeModel(system: system)
    model.configuration.defaultTabbedPreset = .single
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 5 && !model.hasPendingTabbedPlacement })
    return model
}

@MainActor private func galleryOverlay(_ model: BetterTileModel, system: FakeAppWindowSystem) throws -> TabbedOverlayController {
    let overlay = TabbedOverlayController(panelFactory: OffscreenTestWindows.tabbedPanel)
    overlay.refresh(state: try #require(model.activeTabbedState),
                    bounds: BTRect(x: 12000, y: 0, width: 1000, height: 800), windows: system.windows)
    overlay.onIntent = { [weak model] in model?.performTabbed($0) }
    return overlay
}

@Test(.appTestApplication, arguments: [TabbedPreset.columns, .grid], TabbedPresetGrouping.allCases) @MainActor
func tabbedGalleryApplyRoutesGroupingAndOneUndo(preset: TabbedPreset, grouping: TabbedPresetGrouping) async throws {
    let system = FakeAppWindowSystem()
    let model = try await galleryModel(system)
    defer { model.shutdown() }
    let original = try #require(model.activeTabbedState)
    let frames = system.windows.map(\.frame)
    let ordered = original.panes.flatMap(\.tabs)
    let overlay = try galleryOverlay(model, system: system)
    defer { overlay.hide() }
    let chooser = overlay.makeLayoutGallery()
    chooser.content.select(preset)
    chooser.content.setGrouping(grouping)
    chooser.content.apply()
    try #require(await waitFor { model.activeTabbedState?.panes.count == preset.paneCount && !model.hasPendingTabbedPlacement })
    let applied = try #require(model.activeTabbedState)
    if grouping == .keepTabGroups {
        #expect(applied.panes[0].tabs == ordered)
        #expect(applied.panes.dropFirst().allSatisfy { $0.tabs.isEmpty })
    } else {
        for (index, pane) in applied.panes.enumerated() {
            #expect(pane.tabs == ordered.enumerated().filter { $0.offset % preset.paneCount == index }.map(\.element))
        }
    }
    #expect(overlay.previewedGalleryState == nil)
    model.performTabbed(.undo)
    try #require(await waitFor { model.activeTabbedState == original && !model.hasPendingTabbedPlacement })
    #expect(system.windows.map(\.frame) == frames)
    let writes = system.frameWriteCounts
    model.performTabbed(.undo)
    #expect(!model.hasPendingTabbedPlacement)
    #expect(model.activeTabbedState == original)
    #expect(system.frameWriteCounts == writes)
}

@Test(.appTestApplication, arguments: ["cancel", "escape", "outside", "hide", "busy"]) @MainActor
func tabbedGalleryPreviewAndCancelWriteNothing(ending: String) async throws {
    let system = FakeAppWindowSystem()
    let model = try await galleryModel(system)
    defer { model.shutdown() }
    let original = try #require(model.activeTabbedState)
    let writes = system.frameWriteCounts
    let frames = system.windows.map(\.frame)
    let raises = system.raiseRequests.count
    let overlay = try galleryOverlay(model, system: system)
    defer { overlay.hide() }
    let chooser = overlay.makeLayoutGallery()
    chooser.content.choices[1].onPreview?(true) // Hover or keyboard focus.
    #expect(overlay.previewedGalleryState?.panes.count == 2)
    chooser.content.select(.grid)
    chooser.content.setGrouping(.distributeWindows)
    #expect(overlay.previewedGalleryState?.panes.filter { !$0.tabs.isEmpty }.count == 4)
    switch ending {
    case "escape": chooser.content.cancelOperation(nil)
    case "outside": chooser.presenter.dismiss()
    case "hide": overlay.hide()
    case "busy": overlay.acceptsTabDrags = false
    default: chooser.cancel()
    }
    #expect(overlay.previewedGalleryState == nil)
    #expect(overlay.gallery == nil)
    chooser.content.apply() // A dismissed chooser cannot commit later.
    #expect(overlay.state == original)
    #expect(model.activeTabbedState == original)
    #expect(system.windows.map(\.frame) == frames)
    #expect(system.frameWriteCounts == writes)
    #expect(system.raiseRequests.count == raises)
    model.performTabbed(.undo)
    #expect(!model.hasPendingTabbedPlacement) // Preview did not create Undo.
    #expect(system.frameWriteCounts == writes)
}

@Test(.appTestApplication) @MainActor func tabbedGalleryRejectedDistributionPreservesStateAndUndo() async throws {
    let system = FakeAppWindowSystem()
    let model = try await galleryModel(system)
    defer { model.shutdown() }
    let original = try #require(model.activeTabbedState)
    model.performTabbed(.preset(.rows))
    try #require(await waitFor { model.activeTabbedState?.panes.count == 2 && !model.hasPendingTabbedPlacement })
    let before = try #require(model.activeTabbedState)
    let frames = system.windows.map(\.frame)
    for index in system.windows.indices { system.windows[index].constraints.minimumSize.width = 800 }
    let writes = system.frameWriteCounts
    model.statusMessage = nil
    model.performTabbed(.preset(.columns, grouping: .distributeWindows))
    try #require(await waitFor { model.statusMessage != nil && !model.hasPendingTabbedPlacement })
    #expect(model.activeTabbedState == before)
    #expect(system.windows.map(\.frame) == frames)
    #expect(system.frameWriteCounts == writes)
    model.performTabbed(.undo)
    try #require(await waitFor { model.activeTabbedState == original && !model.hasPendingTabbedPlacement })
}

/// The current shape cannot be applied again unchanged, but Distribute windows can re-spread windows over it.
@Test(.appTestApplication) @MainActor func tabbedGalleryCurrentSelectionAppliesOnlyToRedistribute() {
    _ = NSApplication.shared
    let gallery = TabbedLayoutGalleryView(current: .columns)
    var applications = 0
    gallery.onApply = { _, _ in applications += 1 }
    gallery.setGrouping(.keepTabGroups)
    #expect(!gallery.applyButton.isEnabled)
    gallery.apply()
    #expect(applications == 0)
    gallery.setGrouping(.distributeWindows)
    #expect(gallery.applyButton.isEnabled)
    gallery.apply()
    #expect(applications == 1)
    gallery.setGrouping(.keepTabGroups)
    gallery.select(.rows)
    #expect(gallery.applyButton.isEnabled)
    gallery.apply()
    #expect(applications == 2)
}
