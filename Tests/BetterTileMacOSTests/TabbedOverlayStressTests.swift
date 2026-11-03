import AppKit
import BetterTileCore
import Testing
@testable import BetterTileMacOS

/// Records ordering without showing a real window or taking focus.
@MainActor private final class StressPanel: NSPanel {
    var shown = false
    override var isVisible: Bool { shown }
    override var isKeyWindow: Bool { false }
    override func orderFrontRegardless() { shown = true }
    override func orderOut(_ sender: Any?) { shown = false }
    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) { shown = place != .out }
    override func makeKey() {}
}

@MainActor private final class StressChooserPanel: TabbedChooserPanel {
    var shown = false
    override var isVisible: Bool { shown }
    override func orderFrontRegardless() { shown = true }
    override func orderOut(_ sender: Any?) { shown = false }
    override func makeKey() {}
}

private struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func int(_ bound: Int) -> Int { Int(next() % UInt64(max(1, bound))) }
    mutating func bool() -> Bool { next() & 1 == 0 }
    mutating func element<T>(_ values: [T]) -> T? { values.isEmpty ? nil : values[int(values.count)] }
}

/// Drives one overlay through random lifecycle steps and checks its surfaces after each.
@MainActor private final class TabbedOverlayStress {
    var rng: SplitMix64
    let seed: UInt64
    var now = 0.0
    var pointer: BTPoint?
    var panels: [StressPanel] = []
    var choosers: [StressChooserPanel] = []
    var liveMonitors: Set<ObjectIdentifier> = []
    var state = TabbedLayoutState(preset: .columns)
    var bounds = BTRect(x: 40000, y: 0, width: 1200, height: 800)
    var nextWindow = 0
    var visible = true
    var suspended = false
    var requestPane: UUID?
    var pickerPane: UUID?
    var log: [String] = []
    var overlay: TabbedOverlayController!

    init(seed: UInt64) {
        self.seed = seed
        rng = SplitMix64(state: seed)
        _ = NSApplication.shared
        overlay = TabbedOverlayController(panelFactory: { [unowned self] in
            let panel = StressPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panels.append(panel)
            return panel
        }, addGlobalKeyMonitor: { [unowned self] _ in addMonitor() },
        addLocalKeyMonitor: { [unowned self] _ in addMonitor() },
        removeMonitor: { [unowned self] token in liveMonitors.remove(ObjectIdentifier(token as AnyObject)) },
        primaryButtonIsPressed: { false }, observesAutoHidePointer: false,
        visibilityClock: { [unowned self] in now }, automaticallyAdvanceVisibility: false,
        pointerLocation: { [unowned self] in pointer })
        // Mirrors BetterTileModel.cancelPaneApplicationRequest.
        overlay.onDismissApplicationPicker = { [unowned self] in cancelRequest() }
        overlay.onIntent = { [unowned self] _ in overlay.completeDrop() }
    }

    func addMonitor() -> Any {
        let token = NSObject()
        liveMonitors.insert(ObjectIdentifier(token))
        return token
    }

    func cancelRequest() {
        guard let pane = requestPane ?? pickerPane else { return }
        requestPane = nil
        pickerPane = nil
        overlay.revealRequestWindow(number: nil)
        overlay.setPaneRequestStatus(nil)
        overlay.holdApplicationPicker(pane, enabled: false)
    }

    func refresh() {
        let selected = state.selectedWindowIDs
        var numbers: [WindowID: Int] = [:]
        if rng.bool() { for (index, id) in selected.enumerated() { numbers[id] = 1000 + index } }
        // Mirrors BetterTileModel: an idle display accepts tab drags before each refresh.
        overlay.acceptsTabDrags = true
        let frames = state.frames(in: bounds)
        // Pane order is stable across runs; dictionary order and UUID sorting are not.
        let orderedFrames = state.panes.compactMap { frames[$0.id] }
        let obscuring = rng.int(4) == 0 ? rng.element(orderedFrames).map { [$0] } ?? [] : []
        overlay.refresh(state: state, bounds: bounds, windows: [], obscuringFrames: obscuring, canUndo: rng.bool(),
                        selectedWindowNumbers: numbers, curtainAnchorWindowNumber: numbers.values.min())
        visible = true
        suspended = false
    }

    func step() {
        let action = rng.int(22)
        switch action {
        case 0, 1:
            nextWindow += 1
            let id = WindowID(rawValue: "w\(nextWindow)")
            state.reconcile(windowIDs: state.windowIDs.sorted { $0.rawValue < $1.rawValue } + [id], removed: [],
                            focused: rng.bool() ? id : nil)
            if let pane = rng.element(state.panes) { state.move(id, to: pane.id) }
            log.append("open \(id.rawValue)")
            refresh()
        case 2, 3:
            guard let id = rng.element(Array(state.windowIDs).sorted { $0.rawValue < $1.rawValue }) else { return }
            state.removeClosedWindow(id)
            if rng.bool(), visible { overlay.removeUnavailableWindows([id]); log.append("close \(id.rawValue) retained") }
            else { log.append("close \(id.rawValue)"); refresh() }
        case 4:
            guard let id = rng.element(Array(state.windowIDs).sorted { $0.rawValue < $1.rawValue }),
                  let pane = rng.element(state.panes) else { return }
            state.move(id, to: pane.id)
            log.append("move \(id.rawValue)")
            refresh()
        case 5:
            let preset = rng.element(TabbedPreset.allCases)!
            state.applyPreset(preset, grouping: rng.element(TabbedPresetGrouping.allCases)!)
            log.append("preset \(preset)")
            refresh()
        case 6:
            guard let pane = rng.element(state.panes.filter(\.tabs.isEmpty)), state.panes.count > 1 else { return }
            state.removeEmptyPane(pane.id)
            log.append("remove pane")
            refresh()
        case 7:
            let presentation = rng.element(TabbedStripPresentation.allCases)!
            state.setPresentation(presentation)
            log.append("presentation \(presentation)")
            refresh()
        case 8:
            guard visible, !suspended, let pane = rng.element(state.panes) else { return }
            let chooser = StressChooserPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                             backing: .buffered, defer: false)
            choosers.append(chooser)
            let gallery = overlay.makeLayoutGallery(paneID: pane.id) { content, size in
                let presenter = TabbedChooserPresenter(content: content, size: size, panel: chooser)
                presenter.addGlobalRightMouseMonitor = { [unowned self] _ in addMonitor() }
                presenter.removeMonitor = { [unowned self] token in liveMonitors.remove(ObjectIdentifier(token as AnyObject)) }
                return presenter
            }
            gallery.presenter.present(anchorFrame: NSRect(x: 40100, y: 700, width: 20, height: 20),
                                      paneFrame: nil, screenFrame: NSRect(x: 40000, y: 0, width: 1200, height: 800))
            log.append("gallery")
        case 9:
            guard let gallery = overlay.gallery else { return }
            let frame = gallery.presenter.panel.frame
            let inside = rng.bool()
            let point = NSPoint(x: inside ? frame.midX : frame.maxX + 50, y: frame.midY)
            overlay.handleChooserMouseEvent(GlobalGestureEvent(kind: .leftMouseDown,
                position: CoordinateConverter.pointToTopLeft(point, mainScreenFrame: NSScreen.screens.first?.frame ?? .zero),
                button: 0, modifiers: [], timestamp: 0))
            #expect((overlay.gallery != nil) == inside, "chooser outside click seed \(seed)")
            log.append("chooser click inside=\(inside)")
        case 10:
            overlay.prepareForSpaceChange()
            suspended = true
            log.append("space away")
        case 11:
            bounds = BTRect(x: 40000, y: rng.bool() ? 0 : 25, width: Double(600 + rng.int(1200)), height: Double(500 + rng.int(500)))
            log.append("display \(bounds)")
            refresh()
        case 12, 13, 14:
            // Hide removes the pointer monitor, so no pointer samples follow it.
            let frames = state.frames(in: bounds)
            guard visible, let pane = rng.element(state.panes), let frame = frames[pane.id] else { return }
            let x = frame.minX + Double(rng.int(Int(frame.size.width)))
            let y = frame.minY + Double(rng.int(rng.bool() ? 8 : 80))
            pointer = BTPoint(x: x, y: y)
            overlay.updateAutoHidePointer(at: pointer!)
            log.append("pointer \(x),\(y)")
        case 15, 16:
            guard visible else { return }
            now += [0.01, 0.05, 0.08, 0.3, 1.0][rng.int(5)]
            overlay.advanceBarVisibility()
            log.append("tick \(now)")
        case 17:
            guard visible, !suspended, let pane = rng.element(state.panes) else { return }
            cancelRequest()
            pickerPane = pane.id
            overlay.holdApplicationPicker(pane.id, enabled: true)
            log.append("picker open")
        case 18:
            guard let pane = pickerPane ?? requestPane else { return }
            pickerPane = nil
            requestPane = pane
            let kinds: [PaneRequestStatus.Kind] = [.opening(launching: rng.bool()), .placing, .failed,
                .timedOut(showingWindows: rng.bool(), windows: []), .awaitingClick([])]
            overlay.setPaneRequestStatus(PaneRequestStatus(requestID: UUID(), paneID: pane, appName: "App",
                                                           kind: rng.element(kinds)!))
            overlay.revealRequestWindow(number: rng.bool() ? 2000 + rng.int(3) : nil)
            // The model keeps the picker hold until the request ends.
            log.append("request status")
        case 19:
            cancelRequest()
            log.append("request cancel")
        case 20:
            overlay.hide()
            visible = false
            log.append("hide")
        default:
            if visible, !suspended { _ = overlay.showTabBar() }
            log.append("show tab bar")
        }
    }

    func check() {
        let context = "seed \(seed): \(log.suffix(6).joined(separator: " | "))"
        let views = panels.compactMap { panel in (panel.contentView as? TabbedPaneView).map { (panel, $0) } }
        let shownStrips = views.filter { $0.0.shown }
        // No orphan strips: every shown strip belongs to a current pane, once.
        let paneIDs = Set(state.panes.map(\.id))
        for (_, view) in shownStrips {
            #expect(paneIDs.contains(view.pane.id), "orphan strip \(context)")
        }
        #expect(Set(shownStrips.map(\.1.pane.id)).count == shownStrips.count, "duplicate strip \(context)")
        // No window in two panes.
        let tabs = state.panes.flatMap(\.tabs)
        #expect(Set(tabs).count == tabs.count, "window in two panes \(context)")
        // Shown choosers belong to the current gallery.
        for chooser in choosers where chooser.shown {
            #expect(overlay.gallery?.presenter.panel === chooser, "orphan chooser \(context)")
        }
        guard visible else {
            #expect(shownStrips.isEmpty, "strip after hide \(context)")
            #expect(panels.allSatisfy { !$0.shown }, "panel after hide \(context)")
            #expect(overlay.gallery == nil, "gallery after hide \(context)")
            #expect(liveMonitors.isEmpty, "monitor after hide \(context)")
            return
        }
        if suspended {
            #expect(overlay.gallery == nil, "gallery after Space change \(context)")
            #expect(liveMonitors.isEmpty, "monitor after Space change \(context)")
        }
        if overlay.gallery == nil, !overlay.isInteracting {
            // Escape monitors exist only while an auto-hidden bar is revealed.
            if state.presentation != .autoHide { #expect(liveMonitors.isEmpty, "monitor without reveal \(context)") }
        }
        let frames = state.frames(in: bounds)
        let main = NSScreen.screens.first?.frame ?? .zero
        for (panel, view) in views {
            guard let frame = frames[view.pane.id], let pane = state.panes.first(where: { $0.id == view.pane.id }),
                  shownStrips.contains(where: { $0.0 === panel }) || suspended else { continue }
            #expect(view.pane == pane, "stale pane value \(context)")
            if pane.tabs.isEmpty { #expect(!panel.ignoresMouseEvents, "empty pane ignores mouse \(context)") }
            if view.content.requestStatusView != nil, !suspended {
                #expect(!view.content.isHidden, "hidden request status \(context)")
            }
            let expected = CoordinateConverter.toAppKit(frame, mainScreenFrame: main)
            #expect(abs(panel.frame.minX - expected.minX) <= 1 && abs(panel.frame.maxX - expected.maxX) <= 1,
                    "strip width \(panel.frame) vs \(expected) \(context)")
            #expect(abs(panel.frame.maxY - expected.maxY) <= 1, "strip top \(context)")
        }
    }
}

private func stressCount(_ variable: String, default fallback: Int) -> Int {
    guard let value = ProcessInfo.processInfo.environment[variable], let count = Int(value), count > 0 else {
        return fallback
    }
    return count
}

// The default is a short lifecycle sweep. Restore the full exploration with:
// BT_STRESS_SEEDS=40 BT_STRESS_STEPS=400 swift test --filter tabbedOverlayRandomLifecycle
@Test(.macOSTestApplication, arguments: (1...stressCount("BT_STRESS_SEEDS", default: 6)).map { UInt64($0) }) @MainActor
func tabbedOverlayRandomLifecycleKeepsSurfacesConsistent(seed: UInt64) async {
    let stress = TabbedOverlayStress(seed: seed)
    stress.refresh()
    for _ in 0..<stressCount("BT_STRESS_STEPS", default: 100) {
        stress.step()
        stress.check()
        // Keep each transition and its checks together, then let queued main-actor work run.
        await Task.yield()
    }
    stress.overlay.hide()
    stress.visible = false
    stress.check()
}
