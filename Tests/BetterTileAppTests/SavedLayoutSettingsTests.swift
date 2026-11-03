import AppKit
import BetterTileCore
import BetterTileTestSupport
import SwiftUI
import Testing
@testable import BetterTileApp

/// Hosts the Saved Layouts page on its own, not inside the Settings shell, so changes to the shell's
/// header or padding cannot move the canvas. Tests find the stage through `SavedLayoutStageAnchorView`.
@MainActor private final class SavedLayoutUIHarness {
    final class PaletteState { var loaded = false }
    let paletteState = PaletteState()
    let paletteClock = ManualClock()
    final class InputClock {
        var time: TimeInterval = 1000
        var now: Date { Date(timeIntervalSince1970: time) }
    }
    let inputClock = InputClock()
    static let size = NSSize(width: 760, height: 1300)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SavedLayoutUI-" + UUID().uuidString)
    let editor: SavedLayoutEditor
    let model: BetterTileModel
    let window: NSWindow
    let host: NSHostingView<AnyView>
    weak var foundAnchor: SavedLayoutStageAnchorView?

    init(state: String = "populated", appearance: NSAppearance.Name = .aqua,
         badgeActivated: (() -> Void)? = nil, chooser: Bool = false, paletteDelay: Duration = .zero) throws {
        _ = NSApplication.shared
        editor = SavedLayoutEditor(files: .init(directory: directory.appendingPathComponent("layouts")))
        model = makeOffscreenModel(store: .init(fileURL: directory.appendingPathComponent("configuration.json")),
                                system: FakeAppWindowSystem(), startRuntime: false)
        model.hasAccessibilityPermission = false
        if state != "empty" {
            editor.newLayout()
            #expect(editor.edit { document in
                document = SavedLayoutDocument(name: "Writing", mode: .bento,
                    layout: .split(axis: .vertical, ratios: [0.63, 0.37], children: [.slot("editor"),
                        .split(axis: .horizontal, ratios: [0.5, 0.5], children: [.slot("browser"), .empty])]),
                    slots: [.init(id: "editor", bundleID: "com.apple.dt.Xcode"), .init(id: "browser", bundleID: "com.apple.Safari")], paneGap: 6)
            })
            editor.selectedPane = "0"
        }
        if state == "long" {
            #expect(editor.edit {
                $0.name = "Research, writing, and review for the autumn product launch across the international team"
                $0.slots[0].prefer = [.app("org.example.International-Research-Workspace-Experimental-Edition-2026")]
            })
        }
        if state == "tabbed" {
            editor.setMode(.tabbed)
            let document = try #require(editor.document)
            let pane = try #require(SavedLayoutCanvasGeometry.panes(document).first)
            editor.assign(bundleID: "com.apple.Notes", pane: pane)
            editor.selectedPane = pane.id
        }
        if state == "manual" {
            editor.setMode(.manual)
            editor.selectedRectangle = "editor"
        }
        if state == "invalid" {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let bad = directory.appendingPathComponent("invalid.json")
            try Data("{\"version\":2,\"name\":\"Invalid\",\"mode\":\"bento\",\"slots\":[],\"layout\":{\"slot\":\"unknown\"}}".utf8).write(to: bad)
            #expect(!editor.load(bad, importing: true))
        }
        if ["narrow", "small", "short"].contains(state) {
            #expect(editor.edit {
                $0.layout = .split(axis: state == "short" ? .horizontal : .vertical,
                    ratios: state == "narrow" ? [0.01, 0.99] : [0.15, 0.85], children: [.slot("editor"), .slot("browser")])
                $0.paneGap = 0
            })
        }
        if state == "float" {
            #expect(editor.edit {
                $0.slots.append(.init(id: "notes", bundleID: "com.apple.Notes"))
                $0.floats = [.init(slot: "notes", rect: .init(x: 0.65, y: 0.05, width: 0.15, height: 0.6))]
            })
            editor.selectedPane = nil
            editor.selectedRectangle = "notes"
        }
        let apps = [ApplicationChoice(bundleIdentifier: "com.apple.Safari", name: "Safari", url: URL(filePath: "/Applications/Safari.app")),
                    ApplicationChoice(bundleIdentifier: "com.apple.Notes", name: "Notes", url: URL(filePath: "/System/Applications/Notes.app"))]
        let paletteState = self.paletteState
        let paletteClock = self.paletteClock
        let palette = SavedLayoutPaletteSource(installed: {
            if paletteDelay > .zero { try? await paletteClock.sleep(for: paletteDelay) }
            paletteState.loaded = true
            return apps
        }, running: { [] },
                                               recent: RecentApplications(defaults: MemoryDefaults()))
        let inputClock = self.inputClock
        let interaction = CanvasInteractionSource(keys: .init(secondsSinceKeyDown: { .infinity }), now: { inputClock.now })
        editor.clock = { inputClock.time }
        let content: AnyView
        if let badgeActivated {
            content = AnyView(SavedLayoutCanvasView(editor: editor, document: try #require(editor.document),
                staging: .init(hoveredPane: "0"), paletteSource: palette,
                paneBadge: { $0.id == "0" ? .init(text: "Choose window", tone: .warning, chooses: true) : nil },
                badgeChooser: { _ in chooser ? AnyView(Text("Fixture window choice").onAppear(perform: badgeActivated)) : nil },
                badgeAction: { _ in chooser ? nil : badgeActivated }, interaction: interaction))
        } else {
            content = AnyView(SavedLayoutSettings(editor: editor, model: model,
                                                paletteSource: palette, canvasInteraction: interaction, editing: true))
        }
        host = NSHostingView(rootView: AnyView(content.environment(\.accessibilityEnabled, true)
            .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)))
        window = OffscreenTestWindow(contentRect: NSRect(origin: NSPoint(x: 12000, y: 0), size: Self.size),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        host.appearance = window.appearance
        window.contentView = host
        window.setContentSize(Self.size)
        window.acceptsMouseMovedEvents = true
        window.makeFirstResponder(host)
    }

    func settle(ordered: Bool = false) async throws {
        var previousFrame: CGRect?
        // The first condition that blocked the last poll, so a failed settle says what never arrived.
        var blocked = "no poll ran"
        func block(_ reason: String) -> Bool { blocked = reason; previousFrame = nil; return false }
        do {
            try await waitForSettingsUI("the current canvas revision and stable stage geometry", in: host) {
                guard editor.document != nil else {
                    blocked = "host size \(host.bounds.size)"
                    return host.bounds.size == Self.size
                }
                guard let anchor = stageAnchor() else { return block("no stage anchor") }
                guard let presentation = anchor.presentation else { return block("no stage presentation") }
                guard presentation.document == editor.displayDocument else { return block("an older canvas document") }
                guard presentation.selectedPane == editor.selectedPane,
                      presentation.selectedRectangle == editor.selectedRectangle else {
                    return block("selection \(String(describing: presentation.selectedPane)), "
                        + "\(String(describing: presentation.selectedRectangle)) instead of "
                        + "\(String(describing: editor.selectedPane)), \(String(describing: editor.selectedRectangle))")
                }
                guard presentation.applicationsResolved else { return block("page applications not resolved") }
                guard paletteState.loaded else { return block("palette not loaded") }
                guard presentation.installedIDs == ["com.apple.Safari", "com.apple.Notes"] else {
                    return block("installed apps \(presentation.installedIDs)")
                }
                // AppKit rounds the anchor view to whole backing pixels; SwiftUI keeps fractional geometry.
                // At 1x a 299.375-point stage has a 299-point anchor, so allow up to one backing pixel.
                let pixel = 1 / max(window.backingScaleFactor, 1)
                guard abs(presentation.stageFrame.width - anchor.bounds.width) <= pixel,
                      abs(presentation.stageFrame.height - anchor.bounds.height) <= pixel else {
                    return block("stage frame \(presentation.stageFrame.size) and anchor \(anchor.bounds.size) differ")
                }
                let frame = host.convert(anchor.bounds, from: anchor)
                guard frame.width > 300, frame.height > 150 else { return block("stage \(frame.size) too small") }
                defer { previousFrame = frame }
                blocked = previousFrame == nil ? "first stable-geometry sample \(frame)"
                    : "stage moved from \(previousFrame!) to \(frame)"
                return previousFrame == frame
            }
        } catch {
            Issue.record("The Saved Layouts page did not settle; the last poll was blocked by: \(blocked)")
            throw error
        }
        #expect(window.isVisible == ordered)
        #expect(!window.isKeyWindow, Comment(rawValue: keyWindowDiagnostics(window)))
        #expect(host.bounds.size == Self.size)
    }

    func nodes() -> [(object: NSObject, label: String, role: String)] {
        func attribute(_ object: NSObject, _ selector: Selector) -> Any? {
            guard object.responds(to: selector) else { return nil }
            return object.perform(selector)?.takeUnretainedValue()
        }
        var seen: Set<ObjectIdentifier> = []
        func walk(_ element: Any) -> [(NSObject, String, String)] {
            guard let object = element as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return [] }
            let labels = [#selector(NSAccessibilityProtocol.accessibilityLabel),
                          #selector(NSAccessibilityProtocol.accessibilityTitle),
                          #selector(NSAccessibilityProtocol.accessibilityValue)].compactMap { attribute(object, $0) as? String }
            let label = labels.first { !$0.isEmpty } ?? ""
            let role = attribute(object, #selector(NSAccessibilityProtocol.accessibilityRole)) as? String ?? ""
            let children = attribute(object, #selector(NSAccessibilityProtocol.accessibilityChildren)) as? [Any]
                ?? object.accessibilityAttributeValue(.children) as? [Any] ?? []
            let contents = attribute(object, #selector(NSAccessibilityProtocol.accessibilityContents)) as? [Any] ?? []
            let navigation = attribute(object, #selector(NSAccessibilityProtocol.accessibilityChildrenInNavigationOrder)) as? [Any] ?? []
            return [(object, label, role)] + (children + contents + navigation).flatMap(walk)
        }
        return walk(host)
    }

    func capture(_ url: URL) throws {
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        window.appearance?.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }

    func close() {
        model.shutdown(); window.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

extension SavedLayoutUIHarness {
    /// Keeps the anchor found last while it is still in the page, so settling polls do not search the whole view
    /// tree every time. A replaced anchor leaves the page, and the next call finds the new one.
    fileprivate func stageAnchor() -> SavedLayoutStageAnchorView? {
        if let anchor = foundAnchor, anchor.isDescendant(of: host) { return anchor }
        func find(_ view: NSView) -> SavedLayoutStageAnchorView? {
            if let anchor = view as? SavedLayoutStageAnchorView { return anchor }
            return view.subviews.lazy.compactMap(find).first
        }
        foundAnchor = find(host)
        return foundAnchor
    }

    /// The canvas stage in host coordinates (top-left origin), read from the stage's AppKit anchor view.
    fileprivate func stage() throws -> CGRect {
        let anchor = try #require(stageAnchor())
        let frame = host.convert(anchor.bounds, from: anchor)
        #expect(host.isFlipped)
        #expect(frame.width > 300 && frame.height > 150)
        return frame
    }
}

/// Hidden SwiftUI ScrollViews expose native text but omit virtual button nodes
/// on this SDK. Full canvas VoiceOver traversal needs a later visible UI check.
@Test(.appTestApplication, .settingsUI) @MainActor func savedLayoutSettingsAccessibleTextKeepsLastValidNameAndValidationError() async throws {
    let harness = try SavedLayoutUIHarness(state: "invalid")
    defer { harness.close() }
    try await harness.settle()
    let nodes = harness.nodes()
    #expect(nodes.contains { $0.label == "Writing" })
    #expect(nodes.contains { $0.label.contains("unknown") && $0.label.contains("Couldn’t read") })
    #expect(harness.editor.document?.name == "Writing")
    #expect(harness.editor.hasInvalidSource)
}

@Test(.appTestApplication, .settingsUI) @MainActor func savedLayoutSettingsCommandSSavesAnExistingDraftOffscreen() async throws {
    let harness = try SavedLayoutUIHarness()
    defer { harness.close() }
    #expect(harness.editor.save(as: "Before"))
    #expect(harness.editor.edit { $0.name = "Keyboard save" })
    try await harness.settle()
    let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
        timestamp: 1000, windowNumber: harness.window.windowNumber,
        context: nil, characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1))
    #expect(try withNativeEventLoop { harness.window.performKeyEquivalent(with: event) })
    try await harness.settle()
    #expect(!harness.editor.isDirty)
    let file = try #require(harness.editor.url)
    #expect(try SavedLayoutValidator.decode(harness.editor.files.read(file)).name == "Keyboard save")
}

@Test(.appTestApplication, .settingsUI, .enabled(if: ProcessInfo.processInfo.environment["BETTERTILE_SAVED_LAYOUT_PREVIEW_DIR"] != nil,
               "Requires an explicit offscreen preview output directory."))
@MainActor func savedLayoutSettingsVisualPreviews() async throws {
    let output = try #require(ProcessInfo.processInfo.environment["BETTERTILE_SAVED_LAYOUT_PREVIEW_DIR"])
    for state in ["populated", "empty", "long", "tabbed", "manual", "invalid", "narrow", "small", "short", "float"] {
        for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let previousAppearance = NSApplication.shared.appearance
            NSApplication.shared.appearance = NSAppearance(named: appearance)
            let harness = try SavedLayoutUIHarness(state: state, appearance: appearance)
            defer { harness.close(); NSApplication.shared.appearance = previousAppearance }
            try await harness.settle()
            let url = URL(fileURLWithPath: output).appendingPathComponent("saved-layouts-\(state)-\(theme).png")
            try harness.capture(url)
            try harness.nodes().map { "\($0.role): \($0.label)" }.joined(separator: "\n").write(
                to: url.deletingPathExtension().appendingPathExtension("txt"), atomically: true, encoding: .utf8)
        }
    }
}

@Test(.appTestApplication, .settingsUI) @MainActor func savedLayoutSettingsOffsetPaneContentStaysVisibleOffscreen() async throws {
    let harness = try SavedLayoutUIHarness(state: "populated", appearance: .aqua)
    defer { harness.close() }
    try await harness.settle()
    let stage = try harness.stage()
    let bitmap = try #require(harness.host.bitmapImageRepForCachingDisplay(in: harness.host.bounds))
    harness.window.appearance?.performAsCurrentDrawingAppearance {
        harness.host.cacheDisplay(in: harness.host.bounds, to: bitmap)
    }
    // The Safari icon is centered above its name in the top-right pane. Sample the icon itself,
    // relative to the stage anchor, so a chip left at the old top-left position fails this check.
    let region = CGRect(x: stage.minX + stage.width * (0.63 + 0.37 / 2) - 16,
                        y: stage.minY + stage.height * 0.25 - 28, width: 32, height: 32)
    let sx = Double(bitmap.pixelsWide) / harness.host.bounds.width
    let sy = Double(bitmap.pixelsHigh) / harness.host.bounds.height
    var nonwhite = 0
    for y in Int(region.minY * sy)..<Int(region.maxY * sy) {
        for x in Int(region.minX * sx)..<Int(region.maxX * sx) {
            if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
               min(color.redComponent, min(color.greenComponent, color.blueComponent)) < 0.94 {
                nonwhite += 1
            }
        }
    }
    #expect(nonwhite > 100)
}

/// A 15% pane on the interactive canvas keeps its surface and outline (the earlier canvas lost them when small).
@Test(.appTestApplication, .settingsUI, arguments: [false, true], [false, true]) @MainActor
func savedLayoutSettingsSmallPaneKeepsFillAndOutlineOffscreen(dark: Bool, short: Bool) async throws {
    let harness = try SavedLayoutUIHarness(state: short ? "short" : "small", appearance: dark ? .darkAqua : .aqua)
    defer { harness.close() }
    for selected in [true, false] {
        harness.editor.selectedPane = selected ? "0" : "1"
        try await harness.settle()
        let stage = try harness.stage()
        if let output = ProcessInfo.processInfo.environment["BETTERTILE_SAVED_LAYOUT_PREVIEW_DIR"] {
            try harness.capture(URL(fileURLWithPath: output).appendingPathComponent(
                "small-pane-\(short ? "short" : "narrow")-\(selected ? "selected" : "unselected")-\(dark ? "dark" : "light").png"))
        }
        let bitmap = try #require(harness.host.bitmapImageRepForCachingDisplay(in: harness.host.bounds))
        harness.window.appearance?.performAsCurrentDrawingAppearance {
            harness.host.cacheDisplay(in: harness.host.bounds, to: bitmap)
        }
        // The first pane is drawn 3 points inside its 15% share. Sample its fill and outer edge.
        let interior = short ? CGRect(x: stage.minX + stage.width * 0.3, y: stage.minY + stage.height * 0.15 * 0.3,
                                      width: stage.width * 0.4, height: max(15, stage.height * 0.15 * 0.4))
                             : CGRect(x: stage.minX + stage.width * 0.15 * 0.25, y: stage.minY + stage.height * 0.35,
                                      width: stage.width * 0.15 * 0.5, height: stage.height * 0.4)
        let edge = short ? CGRect(x: interior.minX, y: stage.minY + 2, width: interior.width, height: 3)
                         : CGRect(x: stage.minX + 2, y: interior.minY, width: 3, height: interior.height)
        let sx = Double(bitmap.pixelsWide) / harness.host.bounds.width
        let sy = Double(bitmap.pixelsHigh) / harness.host.bounds.height
        let center = try #require(bitmap.colorAt(x: Int(interior.midX * sx), y: Int(interior.midY * sy))?.usingColorSpace(.deviceRGB))
        var filled = 0
        var outlined = 0
        for y in Int(interior.minY * sy)..<Int(interior.maxY * sy) {
            for x in Int(interior.minX * sx)..<Int(interior.maxX * sx) {
                let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                if color.blueComponent - color.redComponent > 0.05 { filled += 1 }
            }
        }
        for y in Int(edge.minY * sy)..<Int(edge.maxY * sy) {
            for x in Int(edge.minX * sx)..<Int(edge.maxX * sx) {
                let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                if max(abs(color.redComponent - center.redComponent),
                       abs(color.greenComponent - center.greenComponent),
                       abs(color.blueComponent - center.blueComponent)) > 0.03 { outlined += 1 }
            }
        }
        print("SMALL PANE dark=\(dark) short=\(short) selected=\(selected) fill=\(filled) outline=\(outlined)")
        if selected { #expect(filled > 100) }
        #expect(outlined > 100)
    }
}

/// Dispatch through the production SwiftUI buttons, never AXPress or editor selection actions.
/// An unordered hidden host does not dispatch pointer events on this SDK.
@Suite(.appTestApplication, .serialized, .settingsUI) @MainActor struct SavedLayoutCanvasHitTests {
    @Test(.timeLimit(.minutes(1))) func settlementWaitsForAsyncCanvasContent() async throws {
        let harness = try SavedLayoutUIHarness(paletteDelay: .milliseconds(500))
        defer { harness.close() }
        let settlement = Task { try await harness.settle() }
        await harness.paletteClock.waitForSleepers(count: 1)
        #expect(!harness.paletteState.loaded)
        harness.paletteClock.advance(by: .milliseconds(500))
        try await settlement.value
        #expect(harness.paletteState.loaded)
        _ = try harness.stage()
    }

    private func click(_ point: CGPoint, in harness: SavedLayoutUIHarness) async throws {
        // Every call is a separate single click. Fast condition-based waits must not turn two
        // divider probes into an accidental double-click that equalizes the layout.
        harness.inputClock.time += NSEvent.doubleClickInterval + 1
        let location = harness.host.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: harness.inputClock.time, windowNumber: harness.window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            try withNativeEventLoop { harness.window.sendEvent(event) }
        }
        try await harness.settle(ordered: true)
    }

    // The host is offscreen, so seed hover; dispatch real pointer clicks through the production buttons.
    /// The chooser=true case is local-only: AppKit constrains SwiftUI's native
    /// popover onto a connected screen even with an offscreen anchor window.
    @Test(arguments: OffscreenTestWindows.localWindowTestsEnabled ? [false, true] : [false])
    func hoveredRemoveAndChoosingBadgeHaveSeparatePointerTargets(chooser: Bool) async throws {
        var badgeClicks = 0
        let harness = try SavedLayoutUIHarness(badgeActivated: { badgeClicks += 1 }, chooser: chooser)
        defer { harness.close() }
        let initial = try #require(harness.editor.document)
        #expect(initial.mode == .bento && initial.groups.isEmpty && initial.floats.isEmpty)
        #expect(try SavedLayoutCanvas.node(at: [0], in: #require(initial.layout)) == .slot("editor"))
        harness.window.orderFront(nil)
        try await harness.settle(ordered: true)
        let stage = try harness.stage()
        let right = stage.minX + stage.width * 0.63 - 3
        let remove = CGPoint(x: right - SettingsSpacing.s1 - SettingsSpacing.s6 / 2,
                             y: stage.minY + 3 + SettingsSpacing.s1 + SettingsSpacing.s6 / 2)
        let badge = CGPoint(x: right - 6 - SettingsSpacing.s8 - 50, y: stage.minY + 3 + 6 + 10)
        try await click(badge, in: harness)
        try await waitForSettingsUI("the badge action or chooser", in: harness.host) { badgeClicks == 1 }
        #expect(badgeClicks == 1)
        #expect(harness.editor.document?.slots.contains { $0.id == "editor" } == true)
        // Close the popover before testing the adjacent Remove target.
        if chooser { harness.window.endEditing(for: nil); try await click(CGPoint(x: stage.minX + 20, y: stage.maxY - 20), in: harness) }
        try await click(remove, in: harness)
        #expect(harness.editor.document?.slots.first { $0.id == "editor" }?.prefer == [])
        #expect(harness.editor.document?.slots.contains { $0.id == "browser" } == true)
        #expect(badgeClicks == 1)
    }

    @Test func draggingSecondaryTabbedChipMovesItsWholePane() async throws {
        let harness = try SavedLayoutUIHarness(state: "tabbed")
        defer { harness.close() }
        harness.window.orderFront(nil)
        try await harness.settle(ordered: true)
        let document = try #require(harness.editor.document)
        let layout = try #require(document.layout)
        let leaves = SavedLayoutCanvas.leaves(layout, paneGap: document.paneGap)
        let source = try #require(leaves.first)
        let destination = try #require(leaves.last)
        let stage = try harness.stage()
        // Two content-sized stacks: the secondary icon is to the right of the pane centre.
        let start = CGPoint(x: stage.minX + stage.width * (source.rect.x + source.rect.width / 2) + 40,
                            y: stage.minY + stage.height * (source.rect.y + source.rect.height / 2) - 10)
        let end = CGPoint(x: stage.minX + stage.width * (destination.rect.x + destination.rect.width / 2),
                          y: stage.minY + stage.height * (destination.rect.y + destination.rect.height / 2))
        func send(_ type: NSEvent.EventType, _ point: CGPoint) throws {
            let event = try #require(NSEvent.mouseEvent(with: type, location: harness.host.convert(point, to: nil),
                modifierFlags: [], timestamp: harness.inputClock.time, windowNumber: harness.window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
            try withNativeEventLoop { harness.window.sendEvent(event) }
        }
        try send(.leftMouseDown, start)
        for step in 1...12 {
            let fraction = Double(step) / 12
            let point = CGPoint(x: start.x + (end.x - start.x) * fraction,
                                y: start.y + (end.y - start.y) * fraction)
            harness.inputClock.time += 0.02
            try send(.leftMouseDragged, point)
            try await waitForSettingsUI("drag sample \(step)", in: harness.host) {
                guard let drag = harness.stageAnchor()?.presentation?.dragPoint else { return false }
                return abs(drag.x - (point.x - stage.minX)) < 1 && abs(drag.y - (point.y - stage.minY)) < 1
            }
        }
        try send(.leftMouseUp, end)
        try await harness.settle(ordered: true)
        let updated = try #require(harness.editor.document?.layout)
        let moved = SavedLayoutCanvas.leaves(updated, paneGap: document.paneGap)
        #expect(moved.first?.node == destination.node)
        #expect(moved.last?.node == source.node)
        #expect(harness.editor.document?.slots == document.slots)
    }

    /// Panes on the interactive canvas are hit where they are drawn. The divider's 18-point grab strip sits on top of
    /// the boundary, so a click there starts a divider gesture and selects nothing. In a 1% pane the strip covers the
    /// whole drawn tile: it cannot be selected with the pointer (the keyboard still reaches it).
    @Test(arguments: [false, true], [false, true])
    func smallAndThinPanePointerHitsTheDrawnPane(short: Bool, dark: Bool) async throws {
        let harness = try SavedLayoutUIHarness(appearance: dark ? .darkAqua : .aqua)
        defer { harness.close() }
        func use(_ first: Double) async throws -> CGRect {
            #expect(harness.editor.edit {
                $0.layout = .split(axis: short ? .horizontal : .vertical, ratios: [first, 1 - first],
                                  children: [.slot("editor"), .slot("browser")])
                $0.paneGap = 0
            })
            harness.window.orderFront(nil)
            try await harness.settle(ordered: true)
            return try harness.stage()
        }
        func point(_ stage: CGRect, along fraction: Double, across: Double = 0.5) -> CGPoint {
            short ? CGPoint(x: stage.minX + stage.width * across, y: stage.minY + stage.height * fraction)
                  : CGPoint(x: stage.minX + stage.width * fraction, y: stage.minY + stage.height * across)
        }
        func clicked(_ at: CGPoint, from initial: String?) async throws -> String? {
            harness.editor.selectedPane = initial
            harness.editor.selectedRectangle = nil
            try await harness.settle(ordered: true)
            try await click(at, in: harness)
            #expect(harness.editor.selectedRectangle == nil)
            return harness.editor.selectedPane
        }
        // Small panes (15%): the centre of each pane selects it; the divider strip selects neither.
        let stage = try await use(0.15)
        // Click away from the centered app chip and the divider strip.
        let across = 0.6
        for initial in [nil, "0", "1"] as [String?] {
            #expect(try await clicked(point(stage, along: 0.075, across: across), from: initial) == "0")
            #expect(try await clicked(point(stage, along: 0.15 + 0.425, across: across), from: initial) == "1")
            #expect(try await clicked(point(stage, along: 0.15, across: across), from: initial) == initial)
        }
        // Thin pane (1%): the strip covers it, and the neighbour is selectable away from the boundary only.
        let thin = try await use(0.99)
        for initial in [nil, "0", "1"] as [String?] {
            #expect(try await clicked(point(thin, along: 0.5, across: across), from: initial) == "0")
            #expect(try await clicked(point(thin, along: 0.99, across: across), from: initial) == initial)
            #expect(try await clicked(point(thin, along: 0.995, across: across), from: initial) == initial)
        }
    }

    /// Manual window rectangles are hit where they are drawn, including a thin one offset inside the stage.
    @Test(arguments: [false, true])
    func offsetThinRectanglePointerRespectsAllEdges(short: Bool) async throws {
        let harness = try SavedLayoutUIHarness()
        defer { harness.close() }
        let rect = NormalizedRect(x: 0.65, y: 0.35, width: short ? 0.2 : 0.01, height: short ? 0.01 : 0.3)
        #expect(harness.editor.edit {
            $0.mode = .manual
            $0.layout = nil
            $0.windows = [.init(slot: "editor", rect: .init(x: 0, y: 0, width: 1, height: 1)), .init(slot: "browser", rect: rect)]
            $0.floats = []
            $0.paneGap = 0
        })
        harness.window.orderFront(nil)
        try await harness.settle(ordered: true)
        let canvas = try harness.stage()
        let frame = CGRect(x: canvas.minX + canvas.width * rect.x + 1,
                           y: canvas.minY + canvas.height * rect.y + 1,
                           width: max(1, canvas.width * rect.width - 2),
                           height: max(1, canvas.height * rect.height - 2))
        let outside = [CGPoint(x: frame.minX - 3, y: frame.midY), CGPoint(x: frame.maxX + 3, y: frame.midY),
                       CGPoint(x: frame.midX, y: frame.minY - 3), CGPoint(x: frame.midX, y: frame.maxY + 3)]
        for selected in [false, true] {
            for point in outside {
                harness.editor.selectedPane = nil
                harness.editor.selectedRectangle = selected ? "browser" : nil
                try await harness.settle(ordered: true)
                try await click(point, in: harness)
                #expect(harness.editor.selectedPane == nil)
                #expect(harness.editor.selectedRectangle == "editor")
                try await click(CGPoint(x: frame.midX, y: frame.midY), in: harness)
                #expect(harness.editor.selectedRectangle == "browser")
                #expect(harness.editor.selectedPane == nil)
            }
        }
    }
}
