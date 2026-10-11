import AppKit
import BetterTileCore

/// A complete drawing sample, independent of the stationary input window.
struct DividerHandleDrawing: Equatable {
    var frame: CGRect
    var mode: DividerHandleMode
    var thickness: Double
    var progress: Double
    var trackRoom: [DividerHandleArm: Double]
    var limit: DragLimit
    var tint: NSColor
    var dark: Bool
    var frost: Double
    var surface: DividerHandleSurface
    var gripColor: NSColor
    var increaseContrast: Bool
    var scale: CGFloat
    var useLiquidGlass: Bool
}

/// Every visible part of a ghost gesture shares this stable, click-through
/// window. The controller batches previews and knob in one disabled transaction.
@MainActor
final class DividerDragOverlay {
    private(set) var panel: NSPanel?
    private let content: DividerDragOverlayView
    private var snapshots: [WindowID: WindowSnapshot] = [:]
    private(set) var previewViews: [WindowID: GhostPreviewView] = [:]
    private(set) var limitedWindowIDs: Set<WindowID> = []
    private(set) var orderedBelowWindowNumber: Int?
    private(set) var orderCallCount = 0
    private(set) var frameSetCallCount = 0
    private(set) var drawing: DividerHandleDrawing?
    private var geometry: DividerLensGeometry?
    var lensLayers: DividerLensLayers { content.lensLayers }
    var isVisible: Bool { panel?.isVisible == true }
    var showsFrost: Bool { !content.frost.isHidden }
    var knobRects: [CGRect] {
        (geometry?.capsules ?? []).map { $0.offsetBy(dx: content.knob.frame.minX, dy: content.knob.frame.minY) }
    }
    var overlayAppearance = OverlayAppearance() {
        didSet {
            guard oldValue != overlayAppearance else { return }
            for view in previewViews.values { view.overlayAppearance = overlayAppearance }
        }
    }

    init(lensLayers: DividerLensLayers = DividerLensLayers()) {
        content = DividerDragOverlayView(lensLayers: lensLayers)
    }

    /// A fade that finishes after a new gesture began must not hide it.
    private var presentationGeneration = 0

    func begin(displayFrame: BTRect, below handle: NSWindow, appearance: OverlayAppearance, windows: [WindowSnapshot]) {
        guard let mainFrame = NSScreen.screens.first?.frame else { return }
        presentationGeneration &+= 1
        panel?.alphaValue = 1
        content.knob.isHidden = false
        content.decoration.isHidden = false
        let frame = CoordinateConverter.toAppKit(displayFrame, mainScreenFrame: mainFrame)
        let panel: NSPanel
        if let existing = self.panel {
            panel = existing
            if panel.frame != frame { panel.setFrame(frame, display: false); frameSetCallCount += 1 }
        } else {
            panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .floating
            panel.ignoresMouseEvents = true
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.collectionBehavior = [.moveToActiveSpace, .transient, .ignoresCycle]
            panel.animationBehavior = .none
            panel.isReleasedWhenClosed = false
            panel.contentView = content
            self.panel = panel
        }
        overlayAppearance = appearance
        snapshots = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        content.updateScale()
        panel.order(.below, relativeTo: handle.windowNumber)
        orderedBelowWindowNumber = handle.windowNumber
        orderCallCount += 1
    }

    func update(previews placements: [Placement], limitedWindowIDs: Set<WindowID> = []) {
        guard let panel, let mainFrame = NSScreen.screens.first?.frame else { return }
        self.limitedWindowIDs = limitedWindowIDs
        let ids = Set(placements.map(\.windowID))
        for id in previewViews.keys where !ids.contains(id) { previewViews.removeValue(forKey: id)?.removeFromSuperview() }
        for placement in placements {
            let frame = CoordinateConverter.toAppKit(placement.frame, mainScreenFrame: mainFrame)
                .offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY).insetBy(dx: 3, dy: 3)
            let view: GhostPreviewView
            if let existing = previewViews[placement.windowID] {
                view = existing
                if view.frame != frame { view.frame = frame }
            } else {
                view = GhostPreviewView(frame: frame, snapshot: snapshots[placement.windowID])
                view.overlayAppearance = overlayAppearance
                content.previews.addSubview(view)
                previewViews[placement.windowID] = view
            }
            view.update(snapshot: snapshots[placement.windowID], size: placement.frame.size,
                        limited: limitedWindowIDs.contains(placement.windowID))
            view.layoutSubtreeIfNeeded()
        }
    }

    func update(knob drawing: DividerHandleDrawing) {
        guard let panel else { return }
        var drawing = drawing
        if drawing.surface == .glass, !lensLayers.isAvailable { drawing.surface = .frost }
        var previous = self.drawing
        previous?.frame = drawing.frame
        previous?.trackRoom = drawing.trackRoom
        self.drawing = drawing
        let frame = drawing.frame.offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY)
        let margins = drawing.mode.decorationMargins
        if content.knob.frame != frame { content.knob.frame = frame }
        let decorationFrame = frame.insetBy(dx: -margins.x, dy: -margins.y)
        if content.decoration.frame != decorationFrame { content.decoration.frame = decorationFrame }
        let geometry = DividerLensGeometry(bounds: CGRect(origin: .zero, size: frame.size), mode: drawing.mode,
                                            thickness: drawing.thickness, progress: drawing.progress,
                                            trackRoom: drawing.trackRoom, useLiquidGlass: drawing.useLiquidGlass, cached: geometry)
        let unchanged = previous == drawing && self.geometry?.capsules == geometry.capsules
            && self.geometry?.trackRects == geometry.trackRects
        self.geometry = geometry
        guard !unchanged else { return }
        lensLayers.handleLayer.isHidden = drawing.surface != .glass
        lensLayers.decorationLayer.isHidden = drawing.surface != .glass
        content.frost.isHidden = drawing.surface != .frost
        content.solid.isHidden = drawing.surface != .opaque
        switch drawing.surface {
        case .glass:
            lensLayers.apply(geometry: geometry, margins: margins, tint: drawing.tint, dark: drawing.dark,
                             strength: drawing.frost, limited: drawing.limit.isLimited, p: drawing.progress)
        case .frost:
            if content.frost.frame != content.knob.bounds { content.frost.frame = content.knob.bounds }
            content.frost.update(outline: geometry.outline, color: drawing.gripColor,
                                 progress: drawing.progress, scale: drawing.scale)
        case .opaque:
            let path = CGMutablePath()
            for rect in geometry.capsules { path.addPath(capsulePath(rect)) }
            content.solid.path = path
            content.solid.fillColor = drawing.gripColor.withAlphaComponent(1).cgColor
            content.solid.strokeColor = drawing.tint.withAlphaComponent(drawing.increaseContrast ? 1 : 0.45).cgColor
            content.solid.lineWidth = drawing.increaseContrast ? 1.5 : 0.7
        }
    }

    /// After a committed release the handle draws its own knob again; the
    /// previews stay until the windows reach them.
    func releaseKnob() {
        content.knob.isHidden = true
        content.decoration.isHidden = true
    }

    /// Fades the previews out once the windows have landed.
    func fadeOut(duration: TimeInterval = 0.12) {
        guard let panel, panel.isVisible else { end(); return }
        let generation = presentationGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            panel.animator().alphaValue = 0
        }
        // End after the fade on the main actor; animation completion
        // handlers are not guaranteed to run promptly.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self, self.presentationGeneration == generation else { return }
            self.end()
        }
    }

    func end() {
        panel?.alphaValue = 1
        content.knob.isHidden = false
        content.decoration.isHidden = false
        if panel?.isVisible == true { panel?.orderOut(nil) }
        for view in previewViews.values { view.removeFromSuperview() }
        previewViews = [:]
        snapshots = [:]
        limitedWindowIDs = []
        drawing = nil
    }
}

@MainActor
private final class DividerDragOverlayView: NSView {
    let previews = NSView()
    let lensLayers: DividerLensLayers
    let decoration: DividerLensDecorationView
    let knob = NSView()
    let frost = DividerFrostView()
    let solid = CAShapeLayer()

    init(lensLayers: DividerLensLayers) {
        self.lensLayers = lensLayers
        decoration = DividerLensDecorationView(frame: .zero, lensLayers: lensLayers)
        super.init(frame: .zero)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        previews.autoresizingMask = [.width, .height]
        knob.wantsLayer = true
        knob.layer?.addSublayer(lensLayers.handleLayer)
        knob.layer?.addSublayer(solid)
        frost.isHidden = true
        frost.autoresizingMask = [.width, .height]
        knob.addSubview(frost)
        for view in [previews, decoration, knob] {
            view.setAccessibilityElement(false)
            addSubview(view)
        }
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() { super.layout(); previews.frame = bounds }
    func updateScale() {
        let scale = window?.backingScaleFactor ?? 1
        lensLayers.setContentsScale(scale)
        solid.contentsScale = scale
    }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); updateScale() }
}
