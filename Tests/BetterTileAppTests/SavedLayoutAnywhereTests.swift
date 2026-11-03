import AppKit
import SwiftUI
import Testing
import BetterTileCore
@testable import BetterTileMacOS
@testable import BetterTileApp

@MainActor private final class ActionWheelPresenter: LayoutWheelPresenting {
    var presentations: [LayoutWheelPresentation] = []
    func open(_ value: LayoutWheelPresentation) { presentations.append(value) }
    func update(_ value: LayoutWheelPresentation) { presentations.append(value) }
    func showPlacements(_ placements: [Placement]) {}
    func hidePlacements() {}
    func close() {}
}

@Suite(.appTestApplication) @MainActor struct SavedLayoutAnywhereTests {
    @Test func aCancelledWheelAndOwnActivationNeverGrantFallbackProvenance() throws {
        let f = try SavedLayoutActionFixture(); defer { f.close() }
        let presenter = ActionWheelPresenter()
        let controller = controller(f, presenter)
        defer { controller.stop() }
        activate(controller)
        controller.handleKey(.escape)
        f.system.focusedWindowIsAbsent = true
        f.model.handleApplicationActivation(fromManagedApplication: false)
        #expect(!f.model.applySavedLayoutAction(f.url.lastPathComponent))
        #expect(f.model.statusMessage == "Focus an app window to apply a layout.")
        #expect(f.system.frameWriteCounts.isEmpty)
    }
    @Test func realWheelCallbacksCategoryAndMoreOpenNoApplyAndLayoutReleaseUsesFocus() async throws {
        let f = try SavedLayoutActionFixture(); defer { f.close() }
        for n in 1...9 {
            var document = f.document; document.name = "Layout \(n)"
            let url = try f.files.create(SavedLayoutValidator.encode(document))
            f.model.savedLayoutActions.refresh()
            #expect(f.model.setSavedLayoutActions(url.lastPathComponent, .init(showInWheel: true)))
        }
        let presenter = ActionWheelPresenter()
        let wheel = controller(f, presenter); defer { wheel.stop() }
        wheel.savedLayouts = f.model.savedLayoutActions.wheelEntries.map { .init(file: $0.file, name: $0.name) }
        var chooser: [SavedLayoutActionEntry] = []
        f.model.showSavedLayoutChooser = { chooser = $0 }
        let applier = try #require(f.model.savedLayoutApplier)
        let snapshot = applier.snapshot; var inventories = 0
        applier.snapshot = { inventories += 1; return try snapshot() }
        activate(wheel); aimCategory(wheel)
        wheel.handleModifiers([])
        #expect(applier.lastDocument == nil && inventories == 0 && chooser.isEmpty)
        activate(wheel, generation: 2); aimCategory(wheel); wheel.handleKey(.outerRing)
        for _ in 0..<6 { wheel.handleKey(.nextSector) }
        wheel.handleModifiers([])
        #expect(chooser.count == 4)
        #expect(applier.lastDocument == nil && inventories == 0)
        activate(wheel, generation: 3); aimCategory(wheel); wheel.handleKey(.outerRing)
        for _ in 0..<6 { wheel.handleKey(.nextSector) }
        #expect(inventories == 0) // Every Saved slice was aimed through the real preview callback.
        wheel.handleKey(.previousSector) // Fifth actual layout, not More.
        wheel.handleModifiers([])
        await f.finish()
        #expect(inventories > 0 && applier.lastRun?.result.placed == 1)
        #expect(applier.lastDesktop?.displayID == f.other.id)
        #expect(f.model.savedLayoutActionTargetName == "Studio")
    }
    @Test func bodyRenderingDoesNotResolveFocusOrReadInventory() throws {
        let f = try SavedLayoutActionFixture(); defer { f.close() }
        let applier = try #require(f.model.savedLayoutApplier)
        let before = f.system.focusedWindowReadCount
        var inventories = 0; let snapshot = applier.snapshot
        applier.snapshot = { inventories += 1; return try snapshot() }
        let group = SavedLayoutAnywhereSettings(model: f.model, file: f.url.lastPathComponent)
        let panel = SavedLayoutPanelSection(model: f.model)
        for _ in 0..<20 { _ = group.body; _ = panel.body }
        #expect(f.system.focusedWindowReadCount == before && inventories == 0)
    }
    @Test func resultBlockShowsOneSummaryAndKeepsDistinctErrors() async throws {
        let f = try SavedLayoutActionFixture(); defer { f.close() }
        let applier = try #require(f.model.savedLayoutApplier); applier.observesKeyboard = false
        _ = await applier.apply(f.document, displayID: f.other.id, layoutFileID: f.url.lastPathComponent)
        var run = try #require(applier.lastRun)
        let originalDetails = try #require(run.planPresentation).lines
        let text = SavedLayoutPanelRunText(run: run, message: applier.message)
        let lines = [text.title] + [text.summary].compactMap { $0 } + text.details + [text.message].compactMap { $0 }
        #expect(lines.filter { $0 == run.presentation.title }.count == 1)
        #expect(lines.filter { $0.contains(run.presentation.summary) }.count == 1)
        #expect(text.summary == nil && text.message == nil)
        #expect(text.details == originalDetails)
        #expect(f.model.lastActionFeedback?.message == run.presentation.title)
        #expect(run.offersUndo && applier.canUndo)
        let error = "Couldn’t undo. Try again when the desktop is ready."
        #expect(SavedLayoutPanelRunText(run: run, message: error).message == error)
        // A distinct summary remains useful for results whose title does not contain it.
        run.planPresentation = nil
        let legacy = SavedLayoutPanelRunText(run: run, message: nil)
        #expect(legacy.summary == run.presentation.summary)
        #expect(legacy.message == nil)
        // The title already carries the floating-app suffix; do not repeat it below.
        var plan = try #require(applier.lastRun?.planPresentation)
        plan.summary = "1 arranged · Music not in layout"
        plan.title = "Writing · " + plan.summary
        run.planPresentation = plan
        let floating = SavedLayoutPanelRunText(run: run, message: run.presentation.title)
        #expect(floating.title == "Writing · 1 arranged · Music not in layout")
        #expect(floating.summary == nil && floating.message == nil)
        #expect(floating.details == originalDetails)
    }

    private func controller(_ f: SavedLayoutActionFixture, _ presenter: ActionWheelPresenter) -> LayoutWheelController {
        let controller = LayoutWheelController(configuration: .init(layoutWheel: .init(style: .grouped)), presenter: presenter,
            pointerProvider: { .init(x: 1500, y: 400) }, addGlobalMonitor: { _, _ in NSObject() },
            addLocalMonitor: { _, _ in NSObject() }, removeMonitor: { _ in })
        // Identical model callbacks to production, not fixed-display stubs.
        controller.captureHandler = { f.model.captureLayoutWheelTarget(pointer: $0) }
        controller.previewHandler = { f.model.previewLayoutWheel($0, for: $1) }
        controller.commitHandler = { f.model.performLayoutWheel($0, for: $1) }
        controller.savedLayoutNavigationHandler = { f.model.navigateSavedLayoutWheel($0, target: $1) }
        controller.start()
        return controller
    }
    private func activate(_ controller: LayoutWheelController, generation: Int = 1) {
        controller.handleModifiers([.control, .option, .shift])
        controller.handleActivationDeadline(generation: generation)
    }
    private func aimCategory(_ wheel: LayoutWheelController) {
        for _ in 0..<6 { wheel.handleKey(.nextSector) }
        wheel.handleKey(.outerRing)
        for _ in 0..<6 { wheel.handleKey(.nextSector) }
    }
}

/// Export only in this dedicated snapshot suite; normal validation never writes captures.
@Suite(.appTestApplication, .settingsUI, .serialized) @MainActor struct SavedLayoutAnywhereSnapshotTests {
    @Test func directionCNativeOffscreenStates() async throws {
        guard let folder = ProcessInfo.processInfo.environment["BT_SNAPSHOT_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let f = try SavedLayoutActionFixture(); defer { f.close() }
        for n in 1...6 {
            var document = f.document; document.name = ["Coding", "Design review", "Focus", "Mail + Calendar", "Research", "Writing"][n-1]
            let url = try f.files.create(SavedLayoutValidator.encode(document)); f.model.savedLayoutActions.refresh()
            #expect(f.model.setSavedLayoutActions(url.lastPathComponent, .init(showInMenuBar: true, showInWheel: true)))
        }
        f.model.handleApplicationActivation()
        for dark in [false, true] {
            try capture(SavedLayoutAnywhereSettings(model: f.model, file: f.url.lastPathComponent).padding(20),
                dark: dark, width: 620, name: "c-settings", folder: folder)
            try capture(MenuPanelContent(model: f.model, availableHeight: 1000, actions: {
                HStack { Text("Existing window actions"); Spacer() }.frame(height: 60)
            }, notice: { EmptyView() }), dark: dark, width: 332, name: "c-panel-overflow", folder: folder)
            f.model.savedLayoutActions.message = "Conflicts with Maximize. Choose another shortcut."
            try capture(SavedLayoutAnywhereSettings(model: f.model, file: f.url.lastPathComponent).padding(20),
                dark: dark, width: 620, name: "c-settings-conflict", folder: folder)
            f.model.savedLayoutActions.message = nil
            for level in [LayoutWheelLevelCount.one, .two] {
                for browsing in [false, true] {
                    var configuration = LayoutWheelConfiguration(style: .grouped, levelCount: level)
                    configuration.savedLayouts = f.model.savedLayoutActions.wheelEntries.map { .init(file: $0.file, name: $0.name) }
                    configuration.savedLayouts.append(.init(file: "extra.json", name: "Xcode + Safari"))
                    configuration.browsingSavedLayouts = browsing
                    var fan = LayoutWheelFanState()
                    if browsing { fan.openCatalog(configuration: configuration) }
                    else {
                        let geometry = LayoutWheelMetrics.grouped.fanGeometry(for: configuration)
                        let point = BTPoint(x: -100, y: 100)
                        fan.update(vector: point, at: 0, geometry: geometry)
                        fan.update(vector: point, at: 0.3, geometry: geometry)
                    }
                    let input = LayoutWheelSceneInput(configuration: configuration, appearance: .init(useLiquidGlass: false),
                        selection: fan.selection, fan: fan)
                    try capture(LayoutWheelNativeSurface(input: input, reduceMotion: true, reduceTransparency: false,
                        increasedContrast: false).frame(width: input.diameter, height: input.diameter), dark: dark, width: 660, height: 640,
                        name: "c-wheel-\(level.rawValue)-\(browsing ? "saved" : "category")", folder: folder)
                }
            }
        }
        #expect(f.system.frameWriteCounts.isEmpty)
        #expect(f.model.applySavedLayoutAction(f.url.lastPathComponent))
        await f.finish()
        for entry in f.model.savedLayoutActions.entries {
            #expect(f.model.setSavedLayoutActions(entry.file, .init()))
        }
        for dark in [false, true] {
            try capture(MenuPanelContent(model: f.model, availableHeight: 760, actions: {
                HStack { Text("Existing window actions"); Spacer() }.frame(height: 60)
            }, notice: { EmptyView() }), dark: dark, width: 332, name: "c-panel-result-no-marked-layouts", folder: folder)
        }
    }
    @Test(arguments: [false, true], [false, true])
    func pendingPanelAndWheelApplyShowApplyingInsteadOfThePreviousResult(wheel: Bool, dark: Bool) async throws {
        let f = try SavedLayoutActionFixture(); defer { f.close() }
        let applier = try #require(f.model.savedLayoutApplier)
        #expect(f.model.applySavedLayoutAction(f.url.lastPathComponent))
        try await waitForSavedLayoutState("The first outside Apply did not complete.") { !applier.isBusy && applier.lastRun != nil }
        let previous = try #require(applier.lastRun)
        let before = f.system.frameWriteCounts
        let snapshot = applier.snapshot
        var inventories = 0
        applier.snapshot = { inventories += 1; return try snapshot() }
        if wheel {
            let target = try #require(f.model.captureLayoutWheelTarget())
            f.model.performLayoutWheel(.savedLayout(file: f.url.lastPathComponent, name: f.document.name), for: target)
        } else {
            #expect(f.model.applySavedLayoutAction(f.url.lastPathComponent))
        }
        #expect(applier.isApplying && !applier.isRunning)
        #expect(applier.lastRun?.date == previous.date)
        #expect(!f.model.applySavedLayoutAction(f.url.lastPathComponent))
        #expect(f.model.savedLayoutActions.message == "Another layout is applying. Try again when it finishes.")
        #expect(f.system.frameWriteCounts == before)
        // Native offscreen render: the panel must show the handoff, never the previous result or Undo.
        let pendingBody = SavedLayoutPanelRun(model: f.model).body
        #expect(inventories == 0)
        let actual = try SettingsSnapshotHost(pendingBody, dark: dark, width: 300, height: 80, fitHeight: false)
        defer { actual.close() }
        let expected = try SettingsSnapshotHost(VStack(alignment: .leading, spacing: 6) {
            Text("Applying…").fontWeight(.semibold)
        }.font(SettingsFont.caption), dark: dark, width: 300, height: 80, fitHeight: false)
        defer { expected.close() }
        let actualPNG = try #require(actual.render().representation(using: .png, properties: [:]))
        let expectedPNG = try #require(expected.render().representation(using: .png, properties: [:]))
        #expect(actualPNG == expectedPNG)
        try await waitForSavedLayoutState("The pending outside Apply did not finish.") {
            !applier.isBusy && applier.lastRun?.date != previous.date
        }
        #expect(applier.lastRun?.result.placed == 1)
        #expect(applier.canUndo)
    }

    @Test(arguments: [false, true], [false, true])
    func followingCardInMenuPanel(following: Bool, dark: Bool) async throws {
        let f = try SavedLayoutActionFixture(); defer { f.close() }
        let applier = try #require(f.model.savedLayoutApplier); applier.observesKeyboard = false
        let document = SavedLayoutDocument(name: "Writing", mode: .bento, layout: .slot("one"),
            slots: [.init(id: "one", bundleID: "com.example.Test")], keepForNewWindows: true)
        try SavedLayoutValidator.encode(document).write(to: f.url)
        f.model.savedLayoutActions.refresh()
        #expect(f.model.setSavedLayoutActions(f.url.lastPathComponent, .init(showInMenuBar: true)))
        _ = await applier.apply(document, displayID: f.other.id, layoutFileID: f.url.lastPathComponent)
        f.model.handleApplicationActivation()
        #expect(f.model.followedSavedLayout?.layoutName == "Writing")
        if !following { f.model.stopFollowingSavedLayout() }
        #expect((f.model.followedSavedLayout != nil) == following)
        let writes = f.system.frameWriteCounts
        let content = MenuPanelContent(model: f.model, availableHeight: 760, actions: {
            HStack { Text("Existing window actions"); Spacer() }.frame(height: 60)
        }, notice: { EmptyView() })
        let host = try SettingsSnapshotHost(content, dark: dark, width: 332, height: 760)
        defer { host.close() }
        #expect(!host.window.isVisible)
        let bitmap = try host.render()
        #expect(f.system.frameWriteCounts == writes)
        if let folder = ProcessInfo.processInfo.environment["BT_SNAPSHOT_DIR"] {
            try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                URL(filePath: folder).appending(path: "int-r2-panel-\(following ? "following" : "without-following")-\(dark ? "dark" : "light").png"))
        }
    }

    private func capture(_ content: some View, dark: Bool, width: Double, height: Double = 1300, name: String, folder: String) throws {
        let host = try SettingsSnapshotHost(content, dark: dark, width: width, height: height)
        defer { host.close() }
        #expect(!host.window.isVisible)
        let bitmap = try host.render()
        try #require(bitmap.representation(using: .png, properties: [:])).write(to:
            URL(filePath: folder).appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
    }
}
