import AppKit
import BetterTileCore
import BetterTileTestSupport
import SwiftUI
import Testing
@testable import BetterTileApp

/// Hosts the canvas at fixed sizes. With `BT_SNAPSHOT_DIR` set, each case also writes a PNG there.
/// Without it, the cases only check that the canvas renders and that its controls are reachable.
@Suite(.appTestApplication, .settingsUI) @MainActor struct SavedLayoutCanvasSnapshotTests {
    enum Scene: String, CaseIterable, CustomTestStringConvertible {
        case empty, selected, longAppNames = "long-app-names", longTabbedNames = "long-tabbed-names", dividerDrag = "divider-drag", edgeDrop = "edge-drop", invalidDrop = "invalid-drop", tabbed, manyTabs = "many-tabs", smallPanes = "small-panes", manual
        /// Only for the header-height test: six apps in uneven columns, so the shape starts as Custom.
        case customGrid = "custom-grid"
        var testDescription: String { rawValue }
    }
    private static let apps = ["com.apple.dt.Xcode", "com.apple.Safari", "com.apple.Terminal", "com.apple.mail", "com.apple.Notes"]

    private struct Host {
        var view: NSHostingView<AnyView>
        var window: NSWindow
        var editor: SavedLayoutEditor
        var palette: PaletteState
    }

    private final class PaletteState {
        var loaded = false
    }

    private func makeEditor(for scene: Scene) throws -> (SavedLayoutEditor, SavedLayoutCanvasStaging?) {
        let editor = SavedLayoutEditor(files: SavedLayoutFiles(directory: FileManager.default.temporaryDirectory
            .appending(path: "SavedLayoutCanvasSnapshots-" + UUID().uuidString)))
        editor.newLayout()
        func seed(_ document: SavedLayoutDocument) { #expect(editor.edit { $0 = document }) }
        func slots(_ count: Int) -> [SavedLayoutSlot] {
            (0..<count).map { .init(id: "slot-\($0)", bundleID: Self.apps[$0 % Self.apps.count]) }
        }
        let writing = SavedLayoutDocument(name: "Writing", mode: .bento,
            layout: .split(axis: .vertical, ratios: [0.63, 0.37], children: [.slot("slot-0"),
                .split(axis: .horizontal, ratios: [0.5, 0.5], children: [.slot("slot-1"), .slot("slot-2")])]),
            slots: slots(3), paneGap: 6)
        switch scene {
        case .empty:
            return (editor, nil)
        case .longAppNames:
            var document = writing
            document.slots = document.slots.map { .init(id: $0.id, bundleID: "org.example.LongAppName") }
            seed(document)
            return (editor, nil)
        case .longTabbedNames:
            editor.newLayout(mode: .tabbed)
            editor.setPreset(.focus)
            for bundle in ["org.example.LongAppName"] + Self.apps.prefix(3) {
                let tabbedDocument = try #require(editor.document)
                let pane = try #require(SavedLayoutCanvasGeometry.panes(tabbedDocument).first)
                editor.assign(bundleID: bundle, pane: pane)
            }
            return (editor, nil)
        case .selected:
            seed(writing); editor.select(path: [1, 0])
            return (editor, nil)
        case .dividerDrag:
            seed(writing)
            let address = SavedLayoutDividerAddress(path: [], index: 0)
            #expect(editor.beginResize(address))
            editor.updateResize(share: 2.0 / 3)
            return (editor, .init(activeDivider: address, snap: SavedLayoutCanvas.snapPoints[3]))
        case .edgeDrop:
            seed(writing)
            let plan = try #require(editor.plan(.app(bundleID: "com.apple.Safari"), onto: .paneEdge([1, 1], .right), names: { _ in "Safari" }))
            return (editor, .init(drag: .init(bundleID: "com.apple.Safari", point: CGPoint(x: 0.93, y: 0.78), plan: plan)))
        case .invalidDrop:
            let columns: [SavedLayoutNode] = (0..<3).map { column in
                .split(axis: .horizontal, ratios: [0.5, 0.5], children: [.slot("slot-\(column * 2)"), .slot("slot-\(column * 2 + 1)")])
            }
            seed(SavedLayoutDocument(name: "Full", mode: .bento,
                layout: .split(axis: .vertical, ratios: [1.0 / 3, 1.0 / 3, 1.0 / 3], children: columns), slots: slots(6)))
            let plan = try #require(editor.plan(.app(bundleID: "com.apple.Notes"), onto: .paneEdge([1, 0], .bottom), names: { _ in "Notes" }))
            return (editor, .init(drag: .init(bundleID: "com.apple.Notes", point: CGPoint(x: 0.5, y: 0.45), plan: plan)))
        case .smallPanes:
            seed(SavedLayoutDocument(name: "Small panes", mode: .bento,
                layout: .split(axis: .vertical, ratios: [0.08, 0.92], children: [.slot("slot-0"),
                    .split(axis: .horizontal, ratios: [0.12, 0.88], children: [.slot("slot-1"), .slot("slot-2")])]),
                slots: slots(3)))
            return (editor, nil)
        case .manual:
            seed(writing)
            editor.setMode(.manual)
            return (editor, nil)
        case .customGrid:
            let columns: [SavedLayoutNode] = (0..<3).map { column in
                .split(axis: .horizontal, ratios: [0.5, 0.5], children: [.slot("slot-\(column * 2)"), .slot("slot-\(column * 2 + 1)")])
            }
            seed(SavedLayoutDocument(name: "Grid", mode: .bento,
                layout: .split(axis: .vertical, ratios: [0.3, 0.3, 0.4], children: columns), slots: slots(6)))
            return (editor, nil)
        case .tabbed, .manyTabs:
            editor.newLayout(mode: .tabbed)
            editor.setPreset(.focus)
            for (bundle, target) in zip(Self.apps, scene == .manyTabs ? [0, 0, 0, 0, 0] : [0, 0, 1, 2, 2]) {
                let panes = SavedLayoutCanvasGeometry.panes(try #require(editor.document))
                editor.assign(bundleID: bundle, pane: panes[target])
            }
            editor.select(path: [0])
            return (editor, nil)
        }
    }

    private func makeHost(_ scene: Scene, dark: Bool, glass: Bool, width: Double,
                          paletteWait: @escaping @MainActor () async -> Void = {},
                          hosted: (Host) -> Void = { _ in }) async throws -> Host {
        _ = NSApplication.shared
        let (editor, staging) = try makeEditor(for: scene)
        let document = try #require(editor.displayDocument)
        let palette = PaletteState()
        let content = SavedLayoutCanvasView(editor: editor, document: document,
                                            overlayAppearance: .init(useLiquidGlass: glass), staging: staging,
                                            paletteSource: .init(installed: { await paletteWait(); palette.loaded = true; return [] }, running: {
                                                guard scene == .longAppNames || scene == .longTabbedNames else { return [] }
                                                return [.init(bundleIdentifier: "org.example.LongAppName",
                                                       name: "International Research Workspace Experimental Edition for Professional Projects 2026 "
                                                        + String(repeating: "with shared research notes, team planning, and review across international departments ", count: 4),
                                                       url: URL(filePath: "/System/Applications/TextEdit.app"))]
                                            },
                                                                 recent: RecentApplications(defaults: MemoryDefaults())))
            .padding(16)
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color(nsColor: .controlBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
        let view = NSHostingView(rootView: AnyView(content))
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.appearance = appearance
        view.frame = NSRect(x: 0, y: 0, width: width, height: 800)
        let window = OffscreenTestWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        window.contentView = view
        hosted(Host(view: view, window: window, editor: editor, palette: palette))
        try await waitForSavedLayoutSnapshot(in: view) { Self.contentIsReady(view, editor: editor, palette: palette) }
        let fitted = view.fittingSize
        window.setContentSize(NSSize(width: width, height: max(200, fitted.height)))
        view.frame = NSRect(origin: .zero, size: window.contentLayoutRect.size)
        try await waitForSavedLayoutSnapshot(in: view) { Self.contentIsReady(view, editor: editor, palette: palette) }
        return Host(view: view, window: window, editor: editor, palette: palette)
    }

    private static func contentIsReady(_ view: NSView, editor: SavedLayoutEditor, palette: PaletteState) -> Bool {
        func anchor(_ node: NSView) -> SavedLayoutStageAnchorView? {
            (node as? SavedLayoutStageAnchorView) ?? node.subviews.lazy.compactMap(anchor).first
        }
        guard let presentation = anchor(view)?.presentation else { return false }
        return palette.loaded && presentation.applicationsResolved
            && presentation.document == editor.displayDocument && presentation.selectedPane == editor.selectedPane
    }

    @Test(.timeLimit(.minutes(1))) func snapshotWaitsForContentAfterGeometryHasSettled() async throws {
        let clock = ManualClock()
        var probe: Host?
        var completed = false
        let snapshot = Task {
            let result = try await makeHost(.selected, dark: false, glass: false, width: 900,
                paletteWait: { try? await clock.sleep(for: .seconds(1)) }, hosted: { probe = $0 })
            completed = true
            return result
        }
        defer { snapshot.cancel(); probe?.window.close() }
        await clock.waitForSleepers(count: 1)
        let host = try #require(probe)
        // Observe stable geometry across both sizing passes while the palette is suspended.
        // Geometry alone must not let makeHost return a snapshot of the pre-task content.
        for _ in 0..<3 { try await waitForSavedLayoutSnapshot(in: host.view) }
        #expect(!host.palette.loaded && !completed)
        #expect(!Self.contentIsReady(host.view, editor: host.editor, palette: host.palette))
        clock.advance(by: .seconds(1))
        let ready = try await snapshot.value
        #expect(completed && Self.contentIsReady(ready.view, editor: ready.editor, palette: ready.palette))
    }

    private func render(_ view: NSView) throws -> NSBitmapImageRep {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    private func distinctColors(_ bitmap: NSBitmapImageRep) -> Int {
        var seen = Set<UInt32>()
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 3) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let packed = UInt32(color.redComponent * 63) << 12 | UInt32(color.greenComponent * 63) << 6 | UInt32(color.blueComponent * 63)
                seen.insert(packed)
            }
        }
        return seen.count
    }

    struct Variant: CustomTestStringConvertible {
        var dark: Bool, glass: Bool, width: Double
        var testDescription: String { "\(dark ? "dark" : "light") \(glass ? "glass" : "solid") \(Int(width))" }
    }
    /// The full matrix runs only when writing PNGs; a plain test run renders one variant so it does not hold up the main actor.
    nonisolated static let variants: [Variant] = ProcessInfo.processInfo.environment["BT_SNAPSHOT_DIR"] == nil
        ? [Variant(dark: false, glass: true, width: 560)]
        : [false, true].flatMap { dark in
            [false, true].flatMap { glass in [980.0, 1280.0].map { Variant(dark: dark, glass: glass, width: $0) } }
        }

    @Test(arguments: Scene.allCases.filter { $0 != .customGrid }, variants)
    func rendersEveryStateAtBothWidths(scene: Scene, variant: Variant) async throws {
        let (dark, glass, width) = (variant.dark, variant.glass, variant.width)
        let host = try await makeHost(scene, dark: dark, glass: glass, width: width)
        defer { host.window.close() }
        let bitmap = try render(host.view)
        #expect(bitmap.pixelsWide >= Int(width))
        #expect(host.view.fittingSize.height > 300)
        #expect(distinctColors(bitmap) > 12)
        if let directory = ProcessInfo.processInfo.environment["BT_SNAPSHOT_DIR"] {
            let folder = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = "canvas-\(scene.rawValue)-\(dark ? "dark" : "light")-\(glass ? "glass" : "solid")-\(Int(width)).png"
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: folder.appendingPathComponent(name))
        }
    }

    private func dividerViews(_ view: NSView) -> [CanvasDividerView] {
        view.subviews.flatMap { ($0 as? CanvasDividerView).map { [$0] } ?? dividerViews($0) }
    }

    @Test func dividersAreSplittersWithValuesAndAnAdjustableAction() async throws {
        let host = try await makeHost(.selected, dark: false, glass: true, width: 900)
        defer { host.window.close() }
        let dividers = dividerViews(host.view)
        #expect(dividers.count == 2)
        let main = try #require(dividers.first { $0.axis == .vertical })
        #expect(main.isAccessibilityElement())
        #expect(main.accessibilityRole() == .splitter)
        #expect(main.accessibilityLabel()?.hasPrefix("Divider between") == true)
        #expect(main.accessibilityValueDescription()?.contains("63%") == true)
        #expect(main.accessibilityOrientation() == .vertical)
        #expect((main.accessibilityMinValue() as? Double) ?? 0 > 0)
        #expect((main.accessibilityMaxValue() as? Double) ?? 0 > (main.accessibilityMinValue() as? Double) ?? 0)
        func share() -> Double { if case let .split(_, ratios, _)? = host.editor.document?.layout { ratios[0] } else { 0 } }
        #expect(abs(share() - 0.63) < 1e-9)
        #expect(main.accessibilityPerformIncrement())
        #expect(abs(share() - 0.64) < 1e-9)
        #expect(main.accessibilityPerformDecrement())
        #expect(abs(share() - 0.63) < 1e-9)
    }

    @Test func dividersMoveWithTheKeyboard() async throws {
        let host = try await makeHost(.selected, dark: false, glass: false, width: 900)
        defer { host.window.close() }
        let main = try #require(dividerViews(host.view).first { $0.axis == .vertical })
        func press(_ code: UInt16, shift: Bool = false) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [], timestamp: 0,
                                         windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                         isARepeat: false, keyCode: code)
            if let event { main.keyDown(with: event) }
        }
        func share() -> Double { if case let .split(_, ratios, _)? = host.editor.document?.layout { ratios[0] } else { 0 } }
        press(124); #expect(abs(share() - 0.64) < 1e-9)
        press(124, shift: true); #expect(abs(share() - 0.69) < 1e-9)
        press(123); #expect(abs(share() - 0.68) < 1e-9)
        press(36); #expect(abs(share() - 0.5) < 1e-9)
        press(115); #expect(abs(share() - 0.1) < 1e-9)
        press(119); #expect(abs(share() - 0.9) < 1e-9)
        press(126) // Up does nothing on a column divider.
        #expect(abs(share() - 0.9) < 1e-9)
        host.editor.undo()
        #expect(host.editor.canRedo)
    }

    /// The header is the only part of the page whose content depends on the shape. Custom → 3×2 Grid adds a long
    /// readout ("… · 3 columns, 2 rows"); a header that chose its rows by content would wrap and move the canvas.
    @Test func theHeaderKeepsItsHeightWhileTheShapeAndReadoutChange() async throws {
        // Hosting widths around the 560 pt canvas: an old, content-driven header wraps differently at 520–550.
        for width in [520.0, 550.0, 560.0, 900.0] {
            let host = try await makeHost(.customGrid, dark: false, glass: true, width: width)
            defer { host.window.close() }
            func shapeName() -> String { SavedLayoutCanvas.shape(host.editor.document?.layout ?? .empty).name }
            func height() async throws -> Double {
                try await waitForSavedLayoutSnapshot(in: host.view) { Self.contentIsReady(host.view, editor: host.editor, palette: host.palette) }
                return host.view.fittingSize.height
            }
            #expect(shapeName() == "Custom")
            let custom = try await height()
            #expect(host.editor.nudge(.init(path: [], index: 0), by: 0, to: 1.0 / 3))
            #expect(host.editor.nudge(.init(path: [], index: 1), by: 0, to: 2.0 / 3))
            #expect(shapeName() == "3×2 Grid")
            #expect(try await height() == custom)
            #expect(host.editor.nudge(.init(path: [], index: 0), by: 0.1))
            #expect(shapeName() == "Custom")
            #expect(try await height() == custom)
        }
    }

    @Test func historyKeysAreCommandZShiftCommandZAndControlY() {
        #expect(CanvasHistoryKey.action(modifiers: .command, characters: "z") == .undo)
        #expect(CanvasHistoryKey.action(modifiers: .command, characters: "Z") == .undo)
        #expect(CanvasHistoryKey.action(modifiers: [.command, .shift], characters: "z") == .redo)
        #expect(CanvasHistoryKey.action(modifiers: .control, characters: "y") == .redo)
        #expect(CanvasHistoryKey.action(modifiers: [], characters: "z") == nil)
        #expect(CanvasHistoryKey.action(modifiers: [.command, .option], characters: "z") == nil)
    }

    /// Records the order in which Tab visits the AppKit views that accept focus. SwiftUI's own focusable
    /// panes, toolbar buttons and chips are inside the hosting view and are not NSViews.
    @Test func keyViewLoopOrderIsRecorded() async throws {
        let host = try await makeHost(.selected, dark: false, glass: false, width: 900)
        defer { host.window.close() }
        host.window.recalculateKeyViewLoop()
        var order: [String] = []
        var current: NSView? = host.view
        for _ in 0..<60 {
            guard let next = current?.nextKeyView, next !== host.view else { break }
            order.append(String(describing: type(of: next)) + " at x\(Int(next.convert(next.bounds, to: host.view).minX)) y\(Int(next.convert(next.bounds, to: host.view).minY))")
            current = next
        }
        print("dividers in hierarchy", dividerViews(host.view).count, "hosting accepts first responder", host.view.acceptsFirstResponder)
        print("KEYLOOP", order)
        #expect(dividerViews(host.view).count == 2)
    }
}
