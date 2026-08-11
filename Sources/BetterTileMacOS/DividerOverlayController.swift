import AppKit
import BetterTileCore

public enum DividerHandleOcclusion {
    public static func isCovered(_ handleFrame: BTRect, by windowFrames: [BTRect]) -> Bool {
        windowFrames.contains { ($0.intersection(handleFrame)?.area ?? 0) > 0 }
    }

    public static func obscuringFrames(
        in windows: [WindowSnapshot],
        excluding managedWindowIDs: Set<WindowID>
    ) -> [BTRect] {
        windows
            .filter { $0.isEligible && !managedWindowIDs.contains($0.id) }
            .map(\.frame)
    }
}

/// Presents one hover-targeted resize handle instead of placing invisible
/// panels over every boundary. Bento gestures update split weights through the
/// tree-aware engine; linked/manual compatibility continues using adjacency.
@MainActor
public final class DividerOverlayController {
    public var configuration: BetterTileConfiguration {
        didSet { updateHover(at: NSEvent.mouseLocation) }
    }
    public var layoutChangedHandler: ((DisplayID, [WindowID: BTRect]) -> Void)?
    public var bentoStateProvider: ((DisplayID) -> BentoLayoutState?)?
    public var bentoStateChangedHandler: ((DisplayID, BentoLayoutState, [WindowID: BTRect], [WindowID: BTRect]) -> Void)?
    public var rollbackFailureHandler: ((DisplayID, String?) -> Void)?
    public var gestureEndedHandler: (() -> Void)?
    public private(set) var isDragging = false

    private let coordinator: WindowCoordinator
    private var boundaries: [BoundaryDescriptor] = []
    private var obscuringFrames: [BTRect] = []
    private var hoveredInteraction: DividerInteraction?
    private var activeInteraction: DividerInteraction?
    private var handlePanel: DividerHandlePanel?
    private let ghosts = GhostFrameOverlayController()
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var escapeMonitor: Any?
    private var ownWindowObservationTask: Task<Void, Never>?

    private var transaction: WindowFrameTransaction?
    private var baselineWindows: [WindowSnapshot] = []
    private var displayBounds: BTRect?
    private var startPoint: BTPoint?
    private var baselineBentoState: BentoLayoutState?
    private var proposedBentoState: BentoLayoutState?
    private var latestPlacements: [Placement] = []
    private var lastLiveUpdate = Date.distantPast
    private var lastGhostUpdate = Date.distantPast

    public init(coordinator: WindowCoordinator, configuration: BetterTileConfiguration) {
        self.coordinator = coordinator
        self.configuration = configuration
        ownWindowObservationTask = Task { @MainActor [weak self] in
            for await notification in NotificationCenter.default.notifications(
                named: NSWindow.didBecomeKeyNotification
            ) {
                guard let self, !Task.isCancelled else { return }
                guard let window = notification.object as? NSWindow,
                      window !== self.handlePanel,
                      !window.ignoresMouseEvents
                else { continue }
                self.updateHover(at: NSEvent.mouseLocation)
            }
        }
    }

    public func refresh(boundaries: [BoundaryDescriptor], obscuringFrames: [BTRect] = []) {
        guard !isDragging else { return }
        self.boundaries = boundaries.filter { !$0.isLocked && $0.spanEnd - $0.spanStart >= 24 }
        self.obscuringFrames = obscuringFrames
        syncHoverMonitoring()
        updateHover(at: NSEvent.mouseLocation)
    }

    public func hideAndCancel() {
        cancelActiveGesture()
        boundaries = []
        obscuringFrames = []
        syncHoverMonitoring()
        hoveredInteraction = nil
        handlePanel?.orderOut(nil)
    }

    private func updateHover(at appKitPoint: CGPoint) {
        guard !isDragging else { return }
        guard !boundaries.isEmpty else {
            hoveredInteraction = nil
            handlePanel?.orderOut(nil)
            return
        }
        let point = topLeftPoint(appKitPoint)
        let hitWidth = max(18, configuration.dividerThickness * 3)
        let candidates = boundaries.filter { $0.hitFrame(width: hitWidth).contains(point) }
        guard !candidates.isEmpty else {
            hoveredInteraction = nil
            handlePanel?.orderOut(nil)
            return
        }

        let vertical = candidates.filter { $0.axis == .vertical }.min { abs($0.coordinate - point.x) < abs($1.coordinate - point.x) }
        let horizontal = candidates.filter { $0.axis == .horizontal }.min { abs($0.coordinate - point.y) < abs($1.coordinate - point.y) }
        let interaction: DividerInteraction
        if let vertical, let horizontal,
           vertical.displayID == horizontal.displayID,
           vertical.branchID != nil, horizontal.branchID != nil,
           vertical.branchID != horizontal.branchID,
           horizontal.spanStart <= vertical.coordinate, vertical.coordinate <= horizontal.spanEnd,
           vertical.spanStart <= horizontal.coordinate, horizontal.coordinate <= vertical.spanEnd,
           abs(point.x - vertical.coordinate) <= 11, abs(point.y - horizontal.coordinate) <= 11 {
            // A four-pane junction can contain two independently weighted
            // horizontal (or vertical) child branches. Move every collinear
            // branch meeting at the junction so all four panes remain joined.
            let verticals = candidates.filter {
                $0.axis == .vertical
                    && $0.branchID != nil
                    && abs($0.coordinate - vertical.coordinate) <= configuration.adjacencyTolerance
                    && $0.spanStart <= horizontal.coordinate
                    && horizontal.coordinate <= $0.spanEnd
            }
            let horizontals = candidates.filter {
                $0.axis == .horizontal
                    && $0.branchID != nil
                    && abs($0.coordinate - horizontal.coordinate) <= configuration.adjacencyTolerance
                    && $0.spanStart <= vertical.coordinate
                    && vertical.coordinate <= $0.spanEnd
            }
            let unique = Dictionary(uniqueKeysWithValues: (verticals + horizontals).map { ($0.id, $0) }).values
            interaction = DividerInteraction(boundaries: Array(unique), mode: .junction)
        } else if let nearest = candidates.min(by: { boundaryDistance($0, point: point) < boundaryDistance($1, point: point) }) {
            interaction = DividerInteraction(boundaries: [nearest], mode: nearest.axis == .vertical ? .vertical : .horizontal)
        } else {
            return
        }

        hoveredInteraction = interaction
        presentHandle(for: interaction, near: point, active: false)
    }

    private func presentHandle(for interaction: DividerInteraction, near point: BTPoint, active: Bool) {
        guard let mainFrame = NSScreen.main?.frame else { return }
        let topLeftFrame = handleFrame(for: interaction, near: point)
        let appKitFrame = CoordinateConverter.toAppKit(topLeftFrame, mainScreenFrame: mainFrame)
        guard active || !isCovered(topLeftFrame: topLeftFrame, appKitFrame: appKitFrame) else {
            hoveredInteraction = nil
            handlePanel?.orderOut(nil)
            return
        }
        let panel: DividerHandlePanel
        if let existing = handlePanel {
            panel = existing
            panel.configure(mode: interaction.mode, thickness: configuration.dividerThickness)
            panel.setFrame(appKitFrame, display: true)
        } else {
            panel = DividerHandlePanel(frame: appKitFrame, mode: interaction.mode, thickness: configuration.dividerThickness)
            panel.onBegin = { [weak self] in self?.beginHoveredGesture() }
            panel.onDrag = { [weak self] point in self?.drag(to: point) }
            panel.onEnd = { [weak self] in self?.end() }
            panel.onExit = { [weak self] in
                guard self?.isDragging == false else { return }
                self?.updateHover(at: NSEvent.mouseLocation)
            }
            handlePanel = panel
        }
        panel.setActive(active)
        panel.orderFrontRegardless()
    }

    private func beginHoveredGesture() {
        guard let interaction = hoveredInteraction,
              let mainFrame = NSScreen.main?.frame,
              let display = coordinator.system.displays().first(where: { $0.id == interaction.displayID }),
              let windows = try? coordinator.system.visibleWindows()
        else { return }
        let point = currentMousePoint()
        let topLeftFrame = handleFrame(for: interaction, near: point)
        let appKitFrame = CoordinateConverter.toAppKit(topLeftFrame, mainScreenFrame: mainFrame)
        guard !isCovered(topLeftFrame: topLeftFrame, appKitFrame: appKitFrame) else {
            hoveredInteraction = nil
            handlePanel?.orderOut(nil)
            return
        }

        let state = bentoStateProvider?(interaction.displayID)
        let affected: Set<WindowID>
        if interaction.isBento, let rootIDs = state?.root?.windowIDs {
            let branchIDs = Set(interaction.boundaries.compactMap(\.branchID))
            affected = Set(rootIDs.filter { id in
                interaction.boundaries.contains { boundary in
                    guard let branchID = boundary.branchID,
                          branchIDs.contains(branchID)
                    else { return false }
                    return boundary.beforeWindowIDs.contains(id) || boundary.afterWindowIDs.contains(id)
                }
            })
        } else {
            affected = interaction.affectedWindowIDs
        }
        guard !affected.isEmpty, case var .started(newTransaction) = coordinator.beginTransaction(windowIDs: affected) else { return }

        activeInteraction = interaction
        isDragging = true
        installEscapeMonitor()
        baselineWindows = windows
        displayBounds = display.visibleFrame
        startPoint = currentMousePoint()
        baselineBentoState = state
        proposedBentoState = state
        latestPlacements = newTransaction.proposedPlacements
        _ = coordinator.preview(transaction: &newTransaction, placements: latestPlacements)
        transaction = newTransaction
        switch configuration.resizeFeedbackMode {
        case .ghost:
            ghosts.show(placements: latestPlacements, windows: windows)
        case .live:
            ghosts.hide()
        }
        if let point = startPoint { presentHandle(for: interaction, near: point, active: true) }
    }

    private func drag(to appKitPoint: CGPoint) {
        guard let interaction = activeInteraction, let startPoint, let displayBounds, var transaction else { return }
        let point = topLeftPoint(appKitPoint)
        let placements: [Placement]

        if interaction.isBento, let baselineBentoState {
            let coordinates = Dictionary(uniqueKeysWithValues: interaction.boundaries.compactMap { boundary -> (UUID, Double)? in
                guard let id = boundary.branchID else { return nil }
                return (id, boundary.axis == .vertical ? point.x : point.y)
            })
            let constraints = Dictionary(uniqueKeysWithValues: baselineWindows.map { ($0.id, $0.constraints) })
            guard let result = BentoResizeEngine().resize(
                state: baselineBentoState,
                branchCoordinates: coordinates,
                in: displayBounds,
                constraints: constraints
            ) else { return }
            let affected = Set(transaction.baselineFrames.keys)
            placements = result.placements.filter { affected.contains($0.windowID) }
            proposedBentoState = result.state
            var movedInteraction = interaction
            for index in movedInteraction.boundaries.indices {
                guard let id = movedInteraction.boundaries[index].branchID,
                      let coordinate = result.appliedCoordinates[id]
                else { continue }
                movedInteraction.boundaries[index].coordinate = coordinate
            }
            presentHandle(for: movedInteraction, near: point, active: true)
        } else {
            guard let boundary = interaction.boundaries.first else { return }
            let delta = boundary.axis == .vertical ? point.x - startPoint.x : point.y - startPoint.y
            guard let result = LinkedResizeEngine(tolerance: configuration.adjacencyTolerance).resize(
                boundary: boundary, delta: delta, windows: baselineWindows, bounds: displayBounds
            ) else { return }
            placements = result.placements
            var moved = boundary
            moved.coordinate += result.appliedDelta
            presentHandle(for: DividerInteraction(boundaries: [moved], mode: interaction.mode), near: point, active: true)
        }

        latestPlacements = placements
        switch configuration.resizeFeedbackMode {
        case .ghost:
            guard case .accepted = coordinator.preview(transaction: &transaction, placements: placements) else { return }
            if Date().timeIntervalSince(lastGhostUpdate) >= 1.0 / 60.0 {
                lastGhostUpdate = Date()
                ghosts.show(placements: placements, windows: baselineWindows)
            }
        case .live:
            ghosts.hide()
            guard Date().timeIntervalSince(lastLiveUpdate) >= 1.0 / 30.0 else { return }
            lastLiveUpdate = Date()
            switch coordinator.applyLive(transaction: &transaction, placements: placements) {
            case .applied:
                break
            case .failed:
                // A transient rejection keeps the gesture alive; the next drag
                // sample proposes fresh placements.
                return
            case .degraded:
                reportRollbackFailure(displayID: interaction.displayID, outcome: coordinator.cancel(transaction: transaction))
                clearGesture()
                return
            }
        }
        self.transaction = transaction
    }

    private func end() {
        guard let interaction = activeInteraction, var transaction else { clearGesture(); return }
        let succeeded: Bool
        switch configuration.resizeFeedbackMode {
        case .ghost:
            let outcome = coordinator.commit(transaction: &transaction, placements: latestPlacements)
            succeeded = outcome.isApplied
            if case .degraded = outcome {
                reportRollbackFailure(displayID: interaction.displayID, outcome: coordinator.cancel(transaction: transaction))
            }
        case .live:
            var appliedFinalPlacement = true
            if Dictionary(uniqueKeysWithValues: latestPlacements.map { ($0.windowID, $0.frame) }) != transaction.lastAppliedFrames {
                appliedFinalPlacement = coordinator.applyLive(transaction: &transaction, placements: latestPlacements).isApplied
            }
            if appliedFinalPlacement {
                coordinator.finishLive(transaction: transaction)
                succeeded = transaction.hasLiveChanges
            } else {
                reportRollbackFailure(displayID: interaction.displayID, outcome: coordinator.cancel(transaction: transaction))
                succeeded = false
            }
        }
        if succeeded {
            let frames = Dictionary(uniqueKeysWithValues: latestPlacements.map { ($0.windowID, $0.frame) })
            if interaction.isBento, let proposedBentoState {
                bentoStateChangedHandler?(interaction.displayID, proposedBentoState, frames, transaction.baselineFrames)
            }
            layoutChangedHandler?(interaction.displayID, frames)
        }
        clearGesture()
    }

    private func cancelActiveGesture() {
        if let transaction {
            let outcome = coordinator.cancel(transaction: transaction)
            if let displayID = activeInteraction?.displayID {
                reportRollbackFailure(displayID: displayID, outcome: outcome)
            }
        }
        clearGesture()
    }

    private func reportRollbackFailure(displayID: DisplayID, outcome: WindowMutationOutcome) {
        guard case let .degraded(reason) = outcome else { return }
        rollbackFailureHandler?(displayID, reason)
    }

    private func clearGesture() {
        let wasDragging = isDragging
        ghosts.hide()
        activeInteraction = nil
        isDragging = false
        transaction = nil
        baselineWindows = []
        displayBounds = nil
        startPoint = nil
        baselineBentoState = nil
        proposedBentoState = nil
        latestPlacements = []
        lastLiveUpdate = .distantPast
        lastGhostUpdate = .distantPast
        handlePanel?.setActive(false)
        removeEscapeMonitor()
        updateHover(at: NSEvent.mouseLocation)
        if wasDragging { gestureEndedHandler?() }
    }

    private func syncHoverMonitoring() {
        if boundaries.isEmpty {
            if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
            if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
            globalMouseMonitor = nil
            localMouseMonitor = nil
            return
        }
        if globalMouseMonitor == nil {
            globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) {
                [weak self] _ in
                Task { @MainActor in self?.updateHover(at: NSEvent.mouseLocation) }
            }
        }
        if localMouseMonitor == nil {
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) {
                [weak self] event in
                Task { @MainActor in self?.updateHover(at: NSEvent.mouseLocation) }
                return event
            }
        }
    }

    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in self?.cancelActiveGesture() }
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }

    private func handleFrame(for interaction: DividerInteraction, near point: BTPoint) -> BTRect {
        let hitWidth = max(18, configuration.dividerThickness * 3)
        if interaction.mode == .junction,
           let vertical = interaction.boundaries.first(where: { $0.axis == .vertical }),
           let horizontal = interaction.boundaries.first(where: { $0.axis == .horizontal }) {
            return BTRect(x: vertical.coordinate - 11, y: horizontal.coordinate - 11, width: 22, height: 22)
        }
        guard let boundary = interaction.boundaries.first else { return .init(x: point.x, y: point.y, width: 1, height: 1) }
        let usableStart = boundary.spanStart + 8
        let usableEnd = boundary.spanEnd - 8
        let length = min(56, max(8, usableEnd - usableStart))
        if boundary.axis == .vertical {
            let center = min(max(point.y, usableStart + length / 2), usableEnd - length / 2)
            return BTRect(x: boundary.coordinate - hitWidth / 2, y: center - length / 2, width: hitWidth, height: length)
        }
        let center = min(max(point.x, usableStart + length / 2), usableEnd - length / 2)
        return BTRect(x: center - length / 2, y: boundary.coordinate - hitWidth / 2, width: length, height: hitWidth)
    }

    private func boundaryDistance(_ boundary: BoundaryDescriptor, point: BTPoint) -> Double {
        boundary.axis == .vertical ? abs(boundary.coordinate - point.x) : abs(boundary.coordinate - point.y)
    }

    private func currentMousePoint() -> BTPoint { topLeftPoint(NSEvent.mouseLocation) }

    private func topLeftPoint(_ point: CGPoint) -> BTPoint {
        guard let mainFrame = NSScreen.main?.frame else { return BTPoint(x: point.x, y: point.y) }
        return CoordinateConverter.pointToTopLeft(point, mainScreenFrame: mainFrame)
    }

    private func isCovered(topLeftFrame: BTRect, appKitFrame: CGRect) -> Bool {
        if DividerHandleOcclusion.isCovered(topLeftFrame, by: obscuringFrames) {
            return true
        }
        guard NSApp.isActive else { return false }
        return NSApp.windows.contains { window in
            if let handlePanel, window === handlePanel { return false }
            return window.isVisible
                && !window.ignoresMouseEvents
                && window.frame.intersects(appKitFrame)
        }
    }
}

private struct DividerInteraction: Equatable {
    var boundaries: [BoundaryDescriptor]
    var mode: DividerHandleMode
    var displayID: DisplayID { boundaries[0].displayID }
    var affectedWindowIDs: Set<WindowID> {
        boundaries.reduce(into: Set<WindowID>()) { result, boundary in
            result.formUnion(boundary.beforeWindowIDs)
            result.formUnion(boundary.afterWindowIDs)
        }
    }
    var isBento: Bool { !boundaries.isEmpty && boundaries.allSatisfy { $0.branchID != nil } }
}

private enum DividerHandleMode: Equatable {
    case vertical
    case horizontal
    case junction
}

@MainActor
private final class DividerHandlePanel: NSPanel {
    var onBegin: (() -> Void)? { didSet { handleView.onBegin = onBegin } }
    var onDrag: ((CGPoint) -> Void)? { didSet { handleView.onDrag = onDrag } }
    var onEnd: (() -> Void)? { didSet { handleView.onEnd = onEnd } }
    var onExit: (() -> Void)? { didSet { handleView.onExit = onExit } }
    private let handleView: DividerHandleView

    init(frame: CGRect, mode: DividerHandleMode, thickness: Double) {
        handleView = DividerHandleView(frame: CGRect(origin: .zero, size: frame.size), mode: mode, thickness: thickness)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.moveToActiveSpace, .transient, .ignoresCycle]
        contentView = handleView
    }

    func configure(mode: DividerHandleMode, thickness: Double) {
        handleView.configure(mode: mode, thickness: thickness)
    }

    func setActive(_ active: Bool) { handleView.setActive(active) }
}

@MainActor
private final class DividerHandleView: NSView {
    var onBegin: (() -> Void)?
    var onDrag: ((CGPoint) -> Void)?
    var onEnd: (() -> Void)?
    var onExit: (() -> Void)?

    private var mode: DividerHandleMode
    private var thickness: CGFloat
    private let material = NSVisualEffectView()
    private var active = false
    private var tracking: NSTrackingArea?

    init(frame: CGRect, mode: DividerHandleMode, thickness: Double) {
        self.mode = mode
        self.thickness = CGFloat(thickness)
        super.init(frame: frame)
        material.material = .hudWindow
        material.blendingMode = .withinWindow
        material.state = .active
        material.wantsLayer = true
        addSubview(material)
        updateAppearance()
    }

    required init?(coder: NSCoder) { nil }

    func configure(mode: DividerHandleMode, thickness: Double) {
        self.mode = mode
        self.thickness = CGFloat(thickness)
        needsLayout = true
        window?.invalidateCursorRects(for: self)
    }

    override func layout() {
        super.layout()
        switch mode {
        case .vertical:
            material.frame = CGRect(x: (bounds.width - thickness) / 2, y: 0, width: thickness, height: bounds.height)
        case .horizontal:
            material.frame = CGRect(x: 0, y: (bounds.height - thickness) / 2, width: bounds.width, height: thickness)
        case .junction:
            let size = min(14, max(10, thickness * 1.7))
            material.frame = CGRect(x: (bounds.width - size) / 2, y: (bounds.height - size) / 2, width: size, height: size)
        }
        material.layer?.cornerRadius = min(material.bounds.width, material.bounds.height) / 2
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func resetCursorRects() {
        let cursor: NSCursor = switch mode {
        case .vertical: .resizeLeftRight
        case .horizontal: .resizeUpDown
        case .junction: .crosshair
        }
        addCursorRect(bounds, cursor: cursor)
    }

    override func mouseExited(with event: NSEvent) {
        guard !active else { return }
        onExit?()
    }

    override func mouseDown(with event: NSEvent) {
        setActive(true)
        onBegin?()
    }

    override func mouseDragged(with event: NSEvent) { onDrag?(NSEvent.mouseLocation) }

    override func mouseUp(with event: NSEvent) {
        onEnd?()
        setActive(false)
    }

    func setActive(_ active: Bool) {
        self.active = active
        updateAppearance()
    }

    private func updateAppearance() {
        material.layer?.backgroundColor = (active
            ? NSColor.controlAccentColor.withAlphaComponent(0.88)
            : NSColor.labelColor.withAlphaComponent(0.20)).cgColor
        material.layer?.borderWidth = active ? 1 : 0.5
        material.layer?.borderColor = NSColor.white.withAlphaComponent(active ? 0.55 : 0.25).cgColor
    }
}

@MainActor
private final class GhostFrameOverlayController {
    private var panels: [WindowID: NSPanel] = [:]

    func show(placements: [Placement], windows: [WindowSnapshot]) {
        guard let mainFrame = NSScreen.main?.frame else { return }
        let snapshots = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        let ids = Set(placements.map(\.windowID))
        let staleIDs = panels.keys.filter { !ids.contains($0) }
        for id in staleIDs {
            panels.removeValue(forKey: id)?.orderOut(nil)
        }
        for placement in placements {
            let frame = CoordinateConverter.toAppKit(placement.frame, mainScreenFrame: mainFrame).insetBy(dx: 3, dy: 3)
            let panel: NSPanel
            if let existing = panels[placement.windowID] {
                panel = existing
                panel.setFrame(frame, display: true)
            } else {
                panel = makePanel(frame: frame, snapshot: snapshots[placement.windowID])
                panels[placement.windowID] = panel
            }
            (panel.contentView as? GhostPreviewView)?.update(
                snapshot: snapshots[placement.windowID],
                size: placement.frame.size
            )
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        for panel in panels.values { panel.orderOut(nil) }
        panels.removeAll()
    }

    private func makePanel(frame: CGRect, snapshot: WindowSnapshot?) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.hasShadow = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.moveToActiveSpace, .transient, .ignoresCycle]
        panel.contentView = GhostPreviewView(frame: CGRect(origin: .zero, size: frame.size), snapshot: snapshot)
        return panel
    }
}

@MainActor
private final class GhostPreviewView: NSVisualEffectView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")

    init(frame: CGRect, snapshot: WindowSnapshot?) {
        super.init(frame: frame)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 2
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.78).cgColor
        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(sizeLabel)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        sizeLabel.textColor = .secondaryLabelColor
        update(snapshot: snapshot, size: BTSize(width: frame.width, height: frame.height))
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let cardWidth = min(300, max(120, bounds.width - 28))
        let x = (bounds.width - cardWidth) / 2
        let y = (bounds.height - 44) / 2
        iconView.frame = CGRect(x: x, y: y + 8, width: 28, height: 28)
        titleLabel.frame = CGRect(x: x + 38, y: y + 22, width: cardWidth - 38, height: 18)
        sizeLabel.frame = CGRect(x: x + 38, y: y + 4, width: cardWidth - 38, height: 16)
    }

    func update(snapshot: WindowSnapshot?, size: BTSize) {
        titleLabel.stringValue = snapshot?.title.isEmpty == false ? snapshot!.title : snapshot?.bundleIdentifier ?? "Window"
        sizeLabel.stringValue = "\(Int(size.width.rounded())) × \(Int(size.height.rounded()))"
        if let pid = snapshot?.processIdentifier {
            iconView.image = NSRunningApplication(processIdentifier: pid)?.icon
        }
    }
}
