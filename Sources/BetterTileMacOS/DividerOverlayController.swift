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

public enum DividerHandleArm: String, CaseIterable, Hashable, Sendable {
    case up, down, left, right
}

public enum DividerHandleGeometry {
    public static let restingStraightLength = 56.0
    public static let activeStraightMultiplier = 3.0
    public static let restingJunctionArmLength = 12.0
    public static let activeJunctionArmLength = 36.0
    public static let junctionAcquisitionSize = 32.0

    static func renderedThickness(_ thickness: Double, useLiquidGlass: Bool) -> Double {
        useLiquidGlass ? thickness + 4 : thickness
    }

    public static func straightLength(span: ClosedRange<Double>, active: Bool) -> Double {
        let usable = max(8, span.upperBound - span.lowerBound)
        let resting = min(restingStraightLength, usable)
        return min(active ? resting * activeStraightMultiplier : resting, usable)
    }

    public static func junctionAcquisitionFrame(center: BTPoint) -> BTRect {
        BTRect(
            x: center.x - junctionAcquisitionSize / 2,
            y: center.y - junctionAcquisitionSize / 2,
            width: junctionAcquisitionSize,
            height: junctionAcquisitionSize
        )
    }

    public static func junctionArmLengths(
        center: BTPoint,
        boundaries: [BoundaryDescriptor],
        active: Bool,
        thickness: Double
    ) -> [DividerHandleArm: Double] {
        let requested = active ? activeJunctionArmLength : restingJunctionArmLength
        let half = max(1, thickness / 2)
        return junctionTrackRoom(center: center, boundaries: boundaries).reduce(into: [:]) { result, entry in
            result[entry.key] = min(requested, max(0, entry.value - half))
        }
    }

    static func junctionTrackRoom(
        center: BTPoint, boundaries: [BoundaryDescriptor]
    ) -> [DividerHandleArm: Double] {
        var available: [DividerHandleArm: Double] = [:]
        for boundary in boundaries {
            switch boundary.axis {
            case .vertical:
                if boundary.spanStart < center.y {
                    available[.up] = max(available[.up] ?? 0, center.y - boundary.spanStart)
                }
                if boundary.spanEnd > center.y {
                    available[.down] = max(available[.down] ?? 0, boundary.spanEnd - center.y)
                }
            case .horizontal:
                if boundary.spanStart < center.x {
                    available[.left] = max(available[.left] ?? 0, center.x - boundary.spanStart)
                }
                if boundary.spanEnd > center.x {
                    available[.right] = max(available[.right] ?? 0, boundary.spanEnd - center.x)
                }
            }
        }
        return available
    }

    public static func junctionFrame(
        center: BTPoint,
        armLengths: [DividerHandleArm: Double],
        thickness: Double
    ) -> BTRect {
        let half = max(1, thickness / 2)
        let acquisition = junctionAcquisitionFrame(center: center)
        let minX = min(acquisition.minX, center.x - (armLengths[.left] ?? 0) - half)
        let maxX = max(acquisition.maxX, center.x + (armLengths[.right] ?? 0) + half)
        let minY = min(acquisition.minY, center.y - (armLengths[.up] ?? 0) - half)
        let maxY = max(acquisition.maxY, center.y + (armLengths[.down] ?? 0) + half)
        return BTRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

enum DividerInteractionResolver {
    static func resolve(
        at point: BTPoint,
        in boundaries: [BoundaryDescriptor],
        hitWidth: Double,
        adjacencyTolerance: Double,
        paneGap: Double = 0
    ) -> DividerInteraction? {
        let eligible = boundaries.filter { !$0.isLocked && $0.spanEnd - $0.spanStart >= 24 }
        let radius = DividerHandleGeometry.junctionAcquisitionSize / 2
        var junctions: [(
            center: BTPoint,
            boundaries: [BoundaryDescriptor],
            verticalBranchID: UUID,
            horizontalBranchID: UUID,
            key: String
        )] = []
        let verticals = eligible.filter { $0.axis == .vertical && $0.branchID != nil }
        let horizontals = eligible.filter { $0.axis == .horizontal && $0.branchID != nil }
        let gapReach = max(0, paneGap) / 2 + 0.001
        func reaches(_ boundary: BoundaryDescriptor, _ coordinate: Double) -> Bool {
            boundary.spanStart - gapReach <= coordinate && coordinate <= boundary.spanEnd + gapReach
        }
        func participants(_ boundary: BoundaryDescriptor) -> Set<WindowID> {
            boundary.beforeWindowIDs.union(boundary.afterWindowIDs)
        }

        for vertical in verticals {
            for horizontal in horizontals
                where vertical.displayID == horizontal.displayID
                    && vertical.branchID != horizontal.branchID
                    && reaches(horizontal, vertical.coordinate)
                    && reaches(vertical, horizontal.coordinate) {
                let exactIntersection = horizontal.spanStart <= vertical.coordinate
                    && vertical.coordinate <= horizontal.spanEnd
                    && vertical.spanStart <= horizontal.coordinate
                    && horizontal.coordinate <= vertical.spanEnd
                // Bridge only the configured half-gap, and only between Bento
                // branches sharing participants. Proximity alone is not topology.
                guard exactIntersection || !participants(vertical).isDisjoint(with: participants(horizontal)) else { continue }
                let center = BTPoint(x: vertical.coordinate, y: horizontal.coordinate)
                guard abs(point.x - center.x) <= radius, abs(point.y - center.y) <= radius else { continue }
                let junctionWindows = participants(vertical).union(participants(horizontal))
                let meeting = eligible.filter { boundary in
                    guard boundary.displayID == vertical.displayID, boundary.branchID != nil else { return false }
                    let crossing = boundary.axis == .vertical ? center.y : center.x
                    let needsGapBridge = crossing < boundary.spanStart || crossing > boundary.spanEnd
                    guard !needsGapBridge || !participants(boundary).isDisjoint(with: junctionWindows) else { return false }
                    switch boundary.axis {
                    case .vertical:
                        return abs(boundary.coordinate - center.x) <= adjacencyTolerance
                            && reaches(boundary, center.y)
                    case .horizontal:
                        return abs(boundary.coordinate - center.y) <= adjacencyTolerance
                            && reaches(boundary, center.x)
                    }
                }
                // A wide gap may split one branch into several observed
                // segments. Acquire and resize that branch exactly once.
                let unique = Dictionary(grouping: meeting, by: \.branchID).compactMap { _, segments in
                    guard var merged = segments.sorted(by: { $0.id < $1.id }).first else { return nil as BoundaryDescriptor? }
                    merged.spanStart = segments.map(\.spanStart).min()!
                    merged.spanEnd = segments.map(\.spanEnd).max()!
                    return merged
                }
                    .sorted { $0.id < $1.id }
                guard let referenceVertical = unique.first(where: { $0.axis == .vertical }),
                      let referenceHorizontal = unique.first(where: { $0.axis == .horizontal }),
                      let verticalBranchID = referenceVertical.branchID,
                      let horizontalBranchID = referenceHorizontal.branchID
                else { continue }
                junctions.append((
                    center,
                    unique,
                    verticalBranchID,
                    horizontalBranchID,
                    unique.map(\.id).joined(separator: "|")
                ))
            }
        }

        if let junction = junctions.min(by: { lhs, rhs in
            let leftDistance = hypot(lhs.center.x - point.x, lhs.center.y - point.y)
            let rightDistance = hypot(rhs.center.x - point.x, rhs.center.y - point.y)
            if leftDistance != rightDistance { return leftDistance < rightDistance }
            if lhs.center.x != rhs.center.x { return lhs.center.x < rhs.center.x }
            if lhs.center.y != rhs.center.y { return lhs.center.y < rhs.center.y }
            return lhs.key < rhs.key
        }) {
            return DividerInteraction(
                boundaries: junction.boundaries,
                kind: .junction(
                    verticalBranchID: junction.verticalBranchID,
                    horizontalBranchID: junction.horizontalBranchID
                )
            )
        }

        let candidates = eligible.filter { $0.hitFrame(width: hitWidth).contains(point) }
        guard let nearest = candidates.min(by: { lhs, rhs in
            let leftDistance = boundaryDistance(lhs, point: point)
            let rightDistance = boundaryDistance(rhs, point: point)
            return leftDistance == rightDistance ? lhs.id < rhs.id : leftDistance < rightDistance
        }) else { return nil }
        return DividerInteraction(
            boundaries: [nearest],
            kind: nearest.axis == .vertical ? .vertical : .horizontal
        )
    }

    private static func boundaryDistance(_ boundary: BoundaryDescriptor, point: BTPoint) -> Double {
        boundary.axis == .vertical ? abs(boundary.coordinate - point.x) : abs(boundary.coordinate - point.y)
    }
}

@MainActor
final class ResizeDisplayLink: NSObject {
    private let automatic: Bool
    private var link: CADisplayLink?
    private var tickHandler: (() -> Void)?

    init(automatic: Bool = true) {
        self.automatic = automatic
    }

    func start(
        on view: NSView? = nil,
        screen: NSScreen? = nil,
        maximumFramesPerSecond: Int? = nil,
        tick: @escaping () -> Void
    ) {
        stop()
        tickHandler = tick
        guard automatic else { return }
        let displayLink = view?.displayLink(target: self, selector: #selector(handleTick(_:)))
            ?? screen?.displayLink(target: self, selector: #selector(handleTick(_:)))
        guard let displayLink else { return }
        link = displayLink
        if let maximumFramesPerSecond {
            let displayMaximum = (view?.window?.screen ?? screen)?.maximumFramesPerSecond ?? maximumFramesPerSecond
            let preferred = Float(max(1, min(displayMaximum, maximumFramesPerSecond)))
            displayLink.preferredFrameRateRange = CAFrameRateRange(
                minimum: min(20, preferred),
                maximum: preferred,
                preferred: preferred
            )
        }
        displayLink.add(to: .main, forMode: .common)
        displayLink.add(to: .main, forMode: .eventTracking)
    }

    func fire() {
        tickHandler?()
    }

    func stop() {
        link?.invalidate()
        link = nil
        tickHandler = nil
    }

    @objc private func handleTick(_ link: CADisplayLink) {
        tickHandler?()
    }
}

/// Presents one hover-targeted resize handle instead of placing invisible
/// panels over every boundary. Bento gestures update split weights through the
/// tree-aware engine; linked/manual compatibility continues using adjacency.
@MainActor
public final class DividerOverlayController {
    public var configuration: BetterTileConfiguration {
        didSet {
            if dragOverlay.isVisible {
                updateGhostPresentation { refreshConfiguration(from: oldValue) }
            } else {
                refreshConfiguration(from: oldValue)
            }
        }
    }

    private func refreshConfiguration(from oldValue: BetterTileConfiguration) {
        handlePanel?.overlayAppearance = configuration.overlayAppearance
        dragOverlay.overlayAppearance = configuration.overlayAppearance
        let previousWidth = DividerHandleGeometry.renderedThickness(
            oldValue.dividerThickness, useLiquidGlass: oldValue.overlayAppearance.useLiquidGlass
        )
        if isDragging, previousWidth != renderedDividerThickness,
           let interaction = activeInteraction,
           let point = latestDragPoint.map({ topLeftPoint($0) }) ?? startPoint {
            presentHandle(for: interaction, near: point, active: true)
        } else {
            updateHover(at: NSEvent.mouseLocation)
        }
    }

    public var layoutChangedHandler: ((DisplayID, [WindowID: BTRect]) -> Void)?
    /// Tabbed panels are layout chrome, not floating windows that hide a grip.
    public var nonOccludingWindowNumbersProvider: (() -> Set<Int>)?
    public var bentoStateProvider: ((DisplayID) -> BentoLayoutState?)?
    public var bentoStateChangedHandler: ((DisplayID, BentoLayoutState, [WindowID: BTRect], [WindowID: BTRect]) -> Void)?
    /// Runs with the tree of each accepted Bento drag sample, and with the
    /// starting tree when the drag ends without a commit. Tabbed moves its
    /// tab strips with it.
    public var bentoStateLiveHandler: ((DisplayID, BentoLayoutState, BTRect) -> Void)?
    public var rollbackFailureHandler: ((DisplayID, String?) -> Void)?
    public var gestureEndedHandler: (() -> Void)?
    /// Runs before the gesture reads its windows, so it sees fresh minimums.
    public var gestureWillBeginHandler: (() -> Void)?
    public private(set) var isDragging = false
    var dragLimit: DragLimit { handlePanel?.limit ?? DragLimit() }
    var limitedGhostWindowIDs: Set<WindowID> { dragOverlay.limitedWindowIDs }
    var visibleHandleView: DividerHandleView? { handlePanel?.contentView as? DividerHandleView }
    private var renderedDividerThickness: Double {
        DividerHandleGeometry.renderedThickness(
            configuration.dividerThickness, useLiquidGlass: configuration.overlayAppearance.useLiquidGlass
        )
    }

    private let coordinator: WindowCoordinator
    private let displayTicks: ResizeDisplayLink
    private var boundaries: [BoundaryDescriptor] = []
    private var obscuringFrames: [BTRect] = []
    private var hoveredInteraction: DividerInteraction?
    private var activeInteraction: DividerInteraction?
    private var baselineInteraction: DividerInteraction?
    private var isRetracting = false
    private var handlePanel: DividerHandlePanel?
    let dragOverlay = DividerDragOverlay()
    private var isUpdatingGhostPresentation = false
    private(set) var ghostPresentationCount = 0
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private let addGlobalKeyMonitor: (@escaping @MainActor (UInt16) -> Void) -> Any?
    private let addLocalKeyMonitor: (@escaping @MainActor (UInt16) -> Bool) -> Any?
    private let removeKeyMonitor: (Any) -> Void
    private var ownWindowObservationTask: Task<Void, Never>?

    private var transaction: WindowFrameTransaction?
    private var baselineWindows: [WindowSnapshot] = []
    private var displayBounds: BTRect?
    private var startPoint: BTPoint?
    private var baselineBentoState: BentoLayoutState?
    private var proposedBentoState: BentoLayoutState?
    private var latestPlacements: [Placement] = []
    private var reportedLiveBentoState = false
    private var latestDragPoint: CGPoint?
    private var hasPendingDisplayUpdate = false
    /// Consecutive live ticks on which a window held its size while asked to
    /// shrink. One tick is not proof: an application can apply a write late.
    private var heldSizeTicks: [WindowID: (size: BTSize, widthCount: Int, heightCount: Int)] = [:]

    public convenience init(coordinator: WindowCoordinator, configuration: BetterTileConfiguration) {
        self.init(coordinator: coordinator, configuration: configuration, displayTicks: ResizeDisplayLink())
    }

    init(
        coordinator: WindowCoordinator,
        configuration: BetterTileConfiguration,
        displayTicks: ResizeDisplayLink,
        addGlobalKeyMonitor: @escaping (@escaping @MainActor (UInt16) -> Void) -> Any? = { handler in
            NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
                let keyCode = event.keyCode
                MainActor.assumeIsolated { handler(keyCode) }
            }
        },
        addLocalKeyMonitor: @escaping (@escaping @MainActor (UInt16) -> Bool) -> Any? = { handler in
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let keyCode = event.keyCode
                let consumed = MainActor.assumeIsolated { handler(keyCode) }
                return consumed ? nil : event
            }
        },
        removeKeyMonitor: @escaping (Any) -> Void = { NSEvent.removeMonitor($0) }
    ) {
        self.coordinator = coordinator
        self.configuration = configuration
        self.displayTicks = displayTicks
        self.addGlobalKeyMonitor = addGlobalKeyMonitor
        self.addLocalKeyMonitor = addLocalKeyMonitor
        self.removeKeyMonitor = removeKeyMonitor
        observeOwnWindows()
    }

    private func observeOwnWindows() {
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
        // Commit callbacks can refresh while the final gesture is still active.
        // Retain those edges for hover after shrink, without moving the grip.
        self.boundaries = boundaries.filter { !$0.isLocked && $0.spanEnd - $0.spanStart >= 24 }
        self.obscuringFrames = obscuringFrames
        if isDragging {
            // A participant can close while the pointer is still, so a
            // window-list refresh must end the gesture without another sample.
            if !activeParticipantsArePresent() { cancelActiveGesture() }
            return
        }
        syncHoverMonitoring()
        updateHover(at: NSEvent.mouseLocation)
    }

    public func hideAndCancel() {
        cancelActiveGesture()
        isRetracting = false
        handlePanel?.setActive(false, animated: false)
        boundaries = []
        obscuringFrames = []
        syncHoverMonitoring()
        hoveredInteraction = nil
        handlePanel?.orderOut(nil)
    }

    private func updateHover(at appKitPoint: CGPoint) {
        guard !isDragging, !isRetracting else { return }
        guard !boundaries.isEmpty else {
            hoveredInteraction = nil
            handlePanel?.orderOut(nil)
            return
        }
        let point = topLeftPoint(appKitPoint)
        let hitWidth = max(18, configuration.dividerThickness * 3)
        guard let interaction = DividerInteractionResolver.resolve(
            at: point,
            in: boundaries,
            hitWidth: hitWidth,
            adjacencyTolerance: configuration.adjacencyTolerance,
            paneGap: configuration.bentoInnerGap
        ) else {
            hoveredInteraction = nil
            handlePanel?.orderOut(nil)
            return
        }

        hoveredInteraction = interaction
        presentHandle(for: interaction, near: point, active: false)
    }

    private func presentHandle(for interaction: DividerInteraction, near point: BTPoint, active: Bool) {
        guard let mainFrame = NSScreen.screens.first?.frame else { return }
        let topLeftFrame = handleFrame(for: interaction, near: point, active: active)
        let appKitFrame = CoordinateConverter.toAppKit(topLeftFrame, mainScreenFrame: mainFrame)
        guard active || !isCovered(topLeftFrame: topLeftFrame, appKitFrame: appKitFrame) else {
            hoveredInteraction = nil
            handlePanel?.orderOut(nil)
            return
        }
        let panel: DividerHandlePanel
        let mode = handleMode(
            for: interaction,
            topLeftFrame: topLeftFrame,
            mainScreenFrame: mainFrame
        )
        let trackRoom = handleTrackRoom(for: interaction, topLeftFrame: topLeftFrame)
        if let existing = handlePanel {
            panel = existing
            panel.configure(mode: mode, thickness: configuration.dividerThickness, trackRoom: trackRoom)
            if panel.overlayAppearance != configuration.overlayAppearance {
                panel.overlayAppearance = configuration.overlayAppearance
            }
            // The accepted divider coordinate moves immediately. Only the
            // decoration inside this frame animates its length.
            if dragOverlay.isVisible {
                panel.setDrawingFrame(appKitFrame)
            } else {
                panel.setFrame(appKitFrame, display: false)
            }
        } else {
            panel = DividerHandlePanel(frame: appKitFrame, mode: mode, thickness: configuration.dividerThickness)
            panel.configure(mode: mode, thickness: configuration.dividerThickness, trackRoom: trackRoom)
            if panel.overlayAppearance != configuration.overlayAppearance {
                panel.overlayAppearance = configuration.overlayAppearance
            }
            panel.onBegin = { [weak self] in self?.beginHoveredGesture() }
            panel.onDrag = { [weak self] point in self?.drag(to: point) }
            panel.onEnd = { [weak self] in self?.end(at: NSEvent.mouseLocation) }
            panel.onExit = { [weak self] in
                guard self?.isDragging == false else { return }
                self?.updateHover(at: NSEvent.mouseLocation)
            }
            handlePanel = panel
        }
        panel.setActive(
            active,
            animated: panel.isActive != active
                && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        if !panel.isVisible || !active { panel.orderFrontRegardless() }
        panel.ignoresMouseEvents = false
    }

    private func beginHoveredGesture() {
        guard let interaction = hoveredInteraction else { return }
        beginGesture(interaction: interaction, at: currentMousePoint())
    }

    func beginGesture(interaction: DividerInteraction, at point: BTPoint) {
        gestureWillBeginHandler?()
        guard let mainFrame = NSScreen.screens.first?.frame,
              let display = coordinator.system.displays().first(where: { $0.id == interaction.displayID }),
              let windows = try? coordinator.system.visibleWindows()
        else {
            handlePanel?.setActive(false, animated: false)
            return
        }
        let topLeftFrame = handleFrame(for: interaction, near: point, active: false)
        let appKitFrame = CoordinateConverter.toAppKit(topLeftFrame, mainScreenFrame: mainFrame)
        guard !isCovered(topLeftFrame: topLeftFrame, appKitFrame: appKitFrame) else {
            hoveredInteraction = nil
            handlePanel?.setActive(false, animated: false)
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
        guard !affected.isEmpty,
              case var .started(newTransaction) = coordinator.beginTransaction(windowIDs: affected)
        else {
            handlePanel?.setActive(false, animated: false)
            return
        }

        activeInteraction = interaction
        baselineInteraction = interaction
        isDragging = true
        installEscapeMonitor()
        baselineWindows = windows
        displayBounds = display.visibleFrame
        startPoint = point
        baselineBentoState = state
        proposedBentoState = state
        latestPlacements = newTransaction.proposedPlacements
        guard case .accepted = coordinator.preview(
            transaction: &newTransaction,
            placements: latestPlacements
        ) else {
            clearGesture()
            return
        }
        transaction = newTransaction
        if let startPoint { presentHandle(for: interaction, near: startPoint, active: true) }
        displayTicks.start(
            on: handlePanel?.contentView,
            maximumFramesPerSecond: configuration.resizeFeedbackMode == .live ? 60 : nil
        ) { [weak self] in
            self?.displayTick()
        }
        switch configuration.resizeFeedbackMode {
        case .ghost:
            beginGhostPresentation()
            updateGhostPresentation { dragOverlay.update(previews: latestPlacements) }
        case .live:
            endGhostPresentation()
        }
    }

    private func beginGhostPresentation() {
        guard !dragOverlay.isVisible, let handlePanel, let displayBounds, let view = visibleHandleView else { return }
        dragOverlay.begin(displayFrame: displayBounds, below: handlePanel,
                          appearance: configuration.overlayAppearance, windows: baselineWindows)
        handlePanel.setDrawingFrame(handlePanel.frame)
        handlePanel.setLensHidden(true)
        view.drawingSink = { [weak self] _ in
            guard let self, !self.isUpdatingGhostPresentation else { return }
            self.updateGhostPresentation {}
        }
    }

    /// A pointer tick, stretch step, or settings update publishes one complete
    /// drawing sample. Sinks during the batch wait for its final limit and frame.
    private func updateGhostPresentation(_ updates: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        isUpdatingGhostPresentation = true
        updates()
        if let drawing = visibleHandleView?.drawingState { dragOverlay.update(knob: drawing) }
        isUpdatingGhostPresentation = false
        ghostPresentationCount += 1
        CATransaction.commit()
    }

    private func endGhostPresentation() {
        guard dragOverlay.isVisible else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        handlePanel?.restoreDrawingFrame()
        dragOverlay.end()
        CATransaction.commit()
    }

    func drag(to appKitPoint: CGPoint) {
        latestDragPoint = appKitPoint
        hasPendingDisplayUpdate = true
    }

    func displayTick() {
        guard hasPendingDisplayUpdate, let latestDragPoint else { return }
        hasPendingDisplayUpdate = false
        applyDrag(to: latestDragPoint, validateParticipants: false)
    }

    private func applyDrag(to appKitPoint: CGPoint, validateParticipants: Bool, minimumCorrections: Int = 0) {
        guard let interaction = baselineInteraction, let startPoint, let displayBounds, var transaction else { return }
        guard configuration.resizeFeedbackMode == .live || activeParticipantsArePresent() else {
            cancelActiveGesture()
            return
        }
        let point = topLeftPoint(appKitPoint)
        let placements: [Placement]
        let proposedInteraction: DividerInteraction
        var proposedState = proposedBentoState
        var limit = DragLimit()

        if interaction.isBento, let baselineBentoState {
            let coordinates = interaction.branchCoordinates(from: startPoint, to: point)
            let constraints = Dictionary(uniqueKeysWithValues: baselineWindows.map { ($0.id, $0.constraints) })
            guard let result = BentoResizeEngine().resize(
                state: baselineBentoState,
                branchCoordinates: coordinates,
                in: displayBounds,
                constraints: constraints
            ) else { return }
            let affected = Set(transaction.baselineFrames.keys)
            placements = result.placements.filter { affected.contains($0.windowID) }
            let updatedBoundaries = result.state.boundaries(
                in: displayBounds,
                displayID: interaction.displayID
            )
            let byBranch = Dictionary(uniqueKeysWithValues: updatedBoundaries.compactMap { boundary in
                boundary.branchID.map { ($0, boundary) }
            })
            let participating = interaction.boundaries.compactMap { boundary in
                boundary.branchID.flatMap { byBranch[$0] }
            }
            guard participating.count == interaction.boundaries.count else {
                cancelActiveGesture()
                return
            }
            proposedInteraction = DividerInteraction(
                boundaries: participating.sorted { $0.id < $1.id },
                kind: interaction.kind
            )
            proposedState = result.state
            for boundary in participating {
                guard let branchID = boundary.branchID, let requested = coordinates[branchID],
                      abs(requested - boundary.coordinate) > 0.5 else { continue }
                if boundary.axis == .vertical { limit.width = true } else { limit.height = true }
                limit.blockedTowardPositive = requested > boundary.coordinate
            }
        } else {
            guard let boundary = interaction.boundaries.first else { return }
            let delta = boundary.axis == .vertical ? point.x - startPoint.x : point.y - startPoint.y
            guard let result = LinkedResizeEngine(tolerance: configuration.adjacencyTolerance).resize(
                boundary: boundary, delta: delta, windows: baselineWindows, bounds: displayBounds
            ) else { return }
            placements = result.placements
            if abs(result.appliedDelta - delta) > 0.5 {
                if boundary.axis == .vertical { limit.width = true } else { limit.height = true }
                limit.blockedTowardPositive = delta > result.appliedDelta
            }
            var moved = boundary
            moved.coordinate += result.appliedDelta
            proposedInteraction = DividerInteraction(boundaries: [moved], kind: interaction.kind)
        }

        switch configuration.resizeFeedbackMode {
        case .ghost:
            guard case .accepted = coordinator.preview(
                transaction: &transaction,
                placements: placements
            ) else {
                self.transaction = transaction
                return
            }
            latestPlacements = placements
            proposedBentoState = proposedState
            self.transaction = transaction
            activeInteraction = proposedInteraction
            reportLiveBentoState(interaction)
            beginGhostPresentation()
            updateGhostPresentation {
                presentHandle(for: proposedInteraction, near: point, active: true)
                handlePanel?.setLimit(limit)
                dragOverlay.update(
                    previews: placements,
                    limitedWindowIDs: ResizeLimits.windowsAtMinimum(
                        placements, windows: baselineWindows, widthLimited: limit.width, heightLimited: limit.height
                    )
                )
            }
        case .live:
            endGhostPresentation()
            switch coordinator.applyLive(
                transaction: &transaction,
                placements: placements,
                validateParticipants: validateParticipants
            ) {
            case .applied:
                latestPlacements = placements
                proposedBentoState = proposedState
                activeInteraction = proposedInteraction
                self.transaction = transaction
                reportLiveBentoState(interaction)
                let refused = recordRefusedMinimums(placements)
                if refused.width || refused.height {
                    if validateParticipants {
                        // Correcting one axis can establish the other axis's
                        // minimum. Allow two new-constraint solves at release;
                        // further changes restore the gesture checkpoint.
                        guard minimumCorrections < 2 else {
                            cancelActiveGesture()
                            return
                        }
                        applyDrag(to: appKitPoint, validateParticipants: true, minimumCorrections: minimumCorrections + 1)
                        return
                    }
                    // The application held its size: the next sample uses that
                    // minimum and the handle turns orange.
                    limit.width = limit.width || refused.width
                    limit.height = limit.height || refused.height
                    limit.blockedTowardPositive = refused.width ? point.x > startPoint.x : point.y > startPoint.y
                }
                if validateParticipants, minimumCorrections > 0 {
                    // A final correction may first cross another limit before
                    // two samples can establish it. Do not commit that overlap.
                    guard let targeted = coordinator.system as? any TargetedWindowSystem,
                          let actual = try? targeted.windowSnapshots(ids: Set(placements.map(\.windowID))),
                          placements.allSatisfy({ placement in
                              actual.contains { $0.id == placement.windowID && $0.frame.approximatelyEquals(placement.frame, tolerance: 2) }
                          }) else {
                        cancelActiveGesture()
                        return
                    }
                }
                presentHandle(for: proposedInteraction, near: point, active: true)
                handlePanel?.setLimit(limit)
            case .failed:
                if minimumCorrections > 0 {
                    cancelActiveGesture()
                    return
                }
                // A transient rejection keeps the gesture alive; the next drag
                // sample proposes fresh placements.
                self.transaction = transaction
                if !activeParticipantsArePresent() { cancelActiveGesture() }
                return
            case .degraded:
                reportRollbackFailure(displayID: interaction.displayID, outcome: coordinator.cancel(transaction: transaction))
                clearGesture()
                return
            }
        }
    }

    func end(at releasePoint: CGPoint? = nil) {
        // Release bypasses display coalescing and applies the exact pointer.
        if let point = releasePoint ?? latestDragPoint, isDragging {
            latestDragPoint = point
            hasPendingDisplayUpdate = false
            applyDrag(to: point, validateParticipants: true)
        }
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
        clearGesture(committed: succeeded)
    }

    private func reportLiveBentoState(_ interaction: DividerInteraction) {
        guard interaction.isBento, let proposedBentoState, let displayBounds else { return }
        reportedLiveBentoState = true
        bentoStateLiveHandler?(interaction.displayID, proposedBentoState, displayBounds)
    }

    /// Learns a held size only after that axis actually shrank from its
    /// gesture baseline. An unchanged window can mean ignored AX writes.
    /// Two held ticks establish a minimum for this gesture only.
    private func recordRefusedMinimums(_ placements: [Placement]) -> (width: Bool, height: Bool) {
        let baseline = Dictionary(baselineWindows.map { ($0.id, $0.frame.size) }, uniquingKeysWith: { first, _ in first })
        let shrinking = placements.filter { placement in
            guard let start = baseline[placement.windowID] else { return false }
            return placement.frame.size.width < start.width - 2 || placement.frame.size.height < start.height - 2
        }
        let shrinkingIDs = Set(shrinking.map(\.windowID))
        heldSizeTicks = heldSizeTicks.filter { shrinkingIDs.contains($0.key) }
        guard !shrinking.isEmpty,
              let targeted = coordinator.system as? any TargetedWindowSystem,
              let actual = try? targeted.windowSnapshots(ids: shrinkingIDs)
        else {
            heldSizeTicks = [:]
            return (false, false)
        }
        let actualSizes = Dictionary(actual.map { ($0.id, $0.frame.size) }, uniquingKeysWith: { first, _ in first })
        var refused = (width: false, height: false)
        for placement in shrinking {
            guard let size = actualSizes[placement.windowID] else {
                heldSizeTicks[placement.windowID] = nil
                continue
            }
            guard let start = baseline[placement.windowID] else { continue }
            let heldWidth = size.width < start.width - 2 && size.width > placement.frame.size.width + 2
            let heldHeight = size.height < start.height - 2 && size.height > placement.frame.size.height + 2
            guard heldWidth || heldHeight else {
                heldSizeTicks[placement.windowID] = nil
                continue
            }
            let previous = heldSizeTicks[placement.windowID]
            // A junction can keep shrinking one axis while the other grows.
            // Refusal evidence belongs to each axis, not the complete size.
            let widthCount = heldWidth ? (previous.map { abs($0.size.width - size.width) <= 1 ? $0.widthCount + 1 : 1 } ?? 1) : 0
            let heightCount = heldHeight ? (previous.map { abs($0.size.height - size.height) <= 1 ? $0.heightCount + 1 : 1 } ?? 1) : 0
            heldSizeTicks[placement.windowID] = (size, widthCount, heightCount)
            guard let index = baselineWindows.firstIndex(where: { $0.id == placement.windowID }) else { continue }
            var minimum = baselineWindows[index].constraints.minimumSize
            let learnedWidth = widthCount >= 2 && size.width > minimum.width
            let learnedHeight = heightCount >= 2 && size.height > minimum.height
            if learnedWidth { minimum.width = size.width }
            if learnedHeight { minimum.height = size.height }
            baselineWindows[index].constraints.minimumSize = minimum
            refused.width = refused.width || learnedWidth
            refused.height = refused.height || learnedHeight
        }
        return refused
    }

    func cancelActiveGesture() {
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

    private func clearGesture(committed: Bool = false) {
        let wasDragging = isDragging
        if reportedLiveBentoState, !committed, let baselineBentoState, let displayBounds,
           let displayID = baselineInteraction?.displayID {
            bentoStateLiveHandler?(displayID, baselineBentoState, displayBounds)
        }
        reportedLiveBentoState = false
        endGhostPresentation()
        activeInteraction = nil
        baselineInteraction = nil
        isDragging = false
        transaction = nil
        baselineWindows = []
        displayBounds = nil
        startPoint = nil
        baselineBentoState = nil
        proposedBentoState = nil
        latestPlacements = []
        latestDragPoint = nil
        hasPendingDisplayUpdate = false
        heldSizeTicks = [:]
        handlePanel?.setLimit(DragLimit())
        displayTicks.stop()
        removeEscapeMonitor()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        isRetracting = wasDragging && !reduceMotion && handlePanel != nil
        handlePanel?.ignoresMouseEvents = true
        handlePanel?.setActive(
            false,
            animated: wasDragging && !reduceMotion
        ) { [weak self] in
            self?.isRetracting = false
            self?.updateHover(at: NSEvent.mouseLocation)
        }
        if handlePanel == nil { updateHover(at: NSEvent.mouseLocation) }
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
        guard globalKeyMonitor == nil, localKeyMonitor == nil else { return }
        globalKeyMonitor = addGlobalKeyMonitor { [weak self] keyCode in
            guard keyCode == 53 else { return }
            self?.cancelActiveGesture()
        }
        localKeyMonitor = addLocalKeyMonitor { [weak self] keyCode in
            guard keyCode == 53 else { return false }
            self?.cancelActiveGesture()
            return true
        }
    }

    private func removeEscapeMonitor() {
        if let globalKeyMonitor { removeKeyMonitor(globalKeyMonitor) }
        if let localKeyMonitor { removeKeyMonitor(localKeyMonitor) }
        globalKeyMonitor = nil
        localKeyMonitor = nil
    }

    func handleFrame(
        for interaction: DividerInteraction,
        near point: BTPoint,
        active: Bool
    ) -> BTRect {
        let hitWidth = max(18, configuration.dividerThickness * 3)
        if let center = junctionCenter(for: interaction) {
            let arms = DividerHandleGeometry.junctionArmLengths(
                center: center,
                boundaries: interaction.boundaries,
                active: active,
                thickness: renderedDividerThickness
            )
            return DividerHandleGeometry.junctionFrame(
                center: center,
                armLengths: arms,
                thickness: renderedDividerThickness
            )
        }
        guard let boundary = interaction.boundaries.first else { return .init(x: point.x, y: point.y, width: 1, height: 1) }
        let usableStart = boundary.spanStart + 8
        let usableEnd = boundary.spanEnd - 8
        let length = DividerHandleGeometry.straightLength(
            span: usableStart...usableEnd,
            active: active
        )
        if boundary.axis == .vertical {
            let center = min(max(point.y, usableStart + length / 2), usableEnd - length / 2)
            return BTRect(x: boundary.coordinate - hitWidth / 2, y: center - length / 2, width: hitWidth, height: length)
        }
        let center = min(max(point.x, usableStart + length / 2), usableEnd - length / 2)
        return BTRect(x: center - length / 2, y: boundary.coordinate - hitWidth / 2, width: length, height: hitWidth)
    }

    func handleTrackRoom(
        for interaction: DividerInteraction, topLeftFrame: BTRect
    ) -> [DividerHandleArm: Double] {
        if let center = junctionCenter(for: interaction) {
            let room = DividerHandleGeometry.junctionTrackRoom(center: center, boundaries: interaction.boundaries)
            return Dictionary(uniqueKeysWithValues: DividerHandleArm.allCases.map { ($0, room[$0] ?? 0) })
        }
        guard let boundary = interaction.boundaries.first else { return [:] }
        if boundary.axis == .vertical {
            return [.up: topLeftFrame.midY - (boundary.spanStart + 8),
                    .down: boundary.spanEnd - 8 - topLeftFrame.midY]
        }
        return [.left: topLeftFrame.midX - (boundary.spanStart + 8),
                .right: boundary.spanEnd - 8 - topLeftFrame.midX]
    }

    func handleMode(
        for interaction: DividerInteraction,
        topLeftFrame: BTRect,
        mainScreenFrame: CGRect
    ) -> DividerHandleMode {
        switch interaction.kind {
        case .vertical:
            let boundary = interaction.boundaries[0]
            let span = (boundary.spanStart + 8) ... (boundary.spanEnd - 8)
            return .vertical(
                restingLength: DividerHandleGeometry.straightLength(span: span, active: false),
                activeLength: DividerHandleGeometry.straightLength(span: span, active: true)
            )
        case .horizontal:
            let boundary = interaction.boundaries[0]
            let span = (boundary.spanStart + 8) ... (boundary.spanEnd - 8)
            return .horizontal(
                restingLength: DividerHandleGeometry.straightLength(span: span, active: false),
                activeLength: DividerHandleGeometry.straightLength(span: span, active: true)
            )
        case .junction:
            guard let center = junctionCenter(for: interaction) else {
                return .junction(center: .zero, resting: [:], active: [:])
            }
            let appKitCenter = CGPoint(
                x: center.x,
                y: mainScreenFrame.maxY - center.y
            )
            let appKitFrame = CoordinateConverter.toAppKit(
                topLeftFrame,
                mainScreenFrame: mainScreenFrame
            )
            return .junction(
                center: CGPoint(
                    x: appKitCenter.x - appKitFrame.minX,
                    y: appKitCenter.y - appKitFrame.minY
                ),
                resting: DividerHandleGeometry.junctionArmLengths(
                    center: center,
                    boundaries: interaction.boundaries,
                    active: false,
                    thickness: renderedDividerThickness
                ),
                active: DividerHandleGeometry.junctionArmLengths(
                    center: center,
                    boundaries: interaction.boundaries,
                    active: true,
                    thickness: renderedDividerThickness
                )
            )
        }
    }

    private func junctionCenter(for interaction: DividerInteraction) -> BTPoint? {
        guard case let .junction(verticalBranchID, horizontalBranchID) = interaction.kind,
              let vertical = interaction.boundaries.first(where: { $0.branchID == verticalBranchID }),
              let horizontal = interaction.boundaries.first(where: { $0.branchID == horizontalBranchID })
        else { return nil }
        return BTPoint(x: vertical.coordinate, y: horizontal.coordinate)
    }

    private func activeParticipantsArePresent() -> Bool {
        guard let transaction else { return false }
        let expected = Set(transaction.baselineFrames.keys)
        do {
            let windows: [WindowSnapshot]
            if let targeted = coordinator.system as? any TargetedWindowSystem {
                windows = try targeted.windowSnapshots(ids: expected)
            } else {
                windows = try coordinator.system.visibleWindows().filter { expected.contains($0.id) }
            }
            return Set(windows.filter(\.isEligible).map(\.id)) == expected
        } catch {
            return false
        }
    }

    private func currentMousePoint() -> BTPoint { topLeftPoint(NSEvent.mouseLocation) }

    private func topLeftPoint(_ point: CGPoint) -> BTPoint {
        guard let mainFrame = NSScreen.screens.first?.frame else { return BTPoint(x: point.x, y: point.y) }
        return CoordinateConverter.pointToTopLeft(point, mainScreenFrame: mainFrame)
    }

    private func isCovered(topLeftFrame: BTRect, appKitFrame: CGRect) -> Bool {
        if DividerHandleOcclusion.isCovered(topLeftFrame, by: obscuringFrames) {
            return true
        }
        guard NSApp.isActive else { return false }
        return Self.ownWindowCoversHandle(
            appKitFrame, windows: NSApp.windows,
            excluding: (nonOccludingWindowNumbersProvider?() ?? [])
                .union(handlePanel.map { [$0.windowNumber] } ?? [])
        )
    }

    static func ownWindowCoversHandle(
        _ handleFrame: CGRect, windows: [NSWindow], excluding windowNumbers: Set<Int>
    ) -> Bool {
        windows.contains { window in
            !windowNumbers.contains(window.windowNumber)
                && window.isVisible && !window.ignoresMouseEvents && window.frame.intersects(handleFrame)
        }
    }
}

struct DividerInteraction: Equatable {
    var boundaries: [BoundaryDescriptor]
    var kind: DividerInteractionKind
    var displayID: DisplayID { boundaries[0].displayID }
    var affectedWindowIDs: Set<WindowID> {
        boundaries.reduce(into: Set<WindowID>()) { result, boundary in
            result.formUnion(boundary.beforeWindowIDs)
            result.formUnion(boundary.afterWindowIDs)
        }
    }
    var isBento: Bool { !boundaries.isEmpty && boundaries.allSatisfy { $0.branchID != nil } }

    func branchCoordinates(from start: BTPoint, to point: BTPoint) -> [UUID: Double] {
        boundaries.reduce(into: [:]) { coordinates, boundary in
            guard let id = boundary.branchID else { return }
            let delta = boundary.axis == .vertical ? point.x - start.x : point.y - start.y
            coordinates[id] = boundary.coordinate + delta
        }
    }
}

enum DividerInteractionKind: Equatable {
    case vertical
    case horizontal
    case junction(verticalBranchID: UUID, horizontalBranchID: UUID)
}

/// Which axes of a divider drag reached a window's minimum size, and on
/// which side, in top-left coordinates.
struct DragLimit: Equatable {
    var width = false
    var height = false
    var blockedTowardPositive = false
    var isLimited: Bool { width || height }
}

enum DividerHandleMode: Equatable {
    case vertical(restingLength: Double, activeLength: Double)
    case horizontal(restingLength: Double, activeLength: Double)
    case junction(
        center: CGPoint,
        resting: [DividerHandleArm: Double],
        active: [DividerHandleArm: Double]
    )
}

@MainActor
final class DividerHandlePanel: NSPanel {
    var onBegin: (() -> Void)? { didSet { handleView.onBegin = onBegin } }
    var onDrag: ((CGPoint) -> Void)? { didSet { handleView.onDrag = onDrag } }
    var onEnd: (() -> Void)? { didSet { handleView.onEnd = onEnd } }
    var onExit: (() -> Void)? { didSet { handleView.onExit = onExit } }
    var overlayAppearance = OverlayAppearance() {
        didSet { if oldValue != overlayAppearance { handleView.overlayAppearance = overlayAppearance } }
    }
    private let handleView: DividerHandleView
    let decorationWindow: NSPanel
    private var decorationMargins: CGPoint
    private(set) var isActive = false
    private(set) var frameSetCallCount = 0
    private(set) var orderCallCount = 0

    init(frame: CGRect, mode: DividerHandleMode, thickness: Double) {
        handleView = DividerHandleView(frame: CGRect(origin: .zero, size: frame.size), mode: mode, thickness: thickness)
        decorationMargins = mode.decorationMargins
        decorationWindow = NSPanel(contentRect: frame.insetBy(dx: -decorationMargins.x, dy: -decorationMargins.y),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.moveToActiveSpace, .transient, .ignoresCycle]
        contentView = handleView
        decorationWindow.level = level
        decorationWindow.ignoresMouseEvents = true
        decorationWindow.isOpaque = false
        decorationWindow.backgroundColor = .clear
        decorationWindow.hasShadow = false
        decorationWindow.collectionBehavior = collectionBehavior
        let decoration = DividerLensDecorationView(frame: CGRect(origin: .zero, size: decorationWindow.frame.size),
                                                   lensLayers: handleView.lensLayers)
        decorationWindow.contentView = decoration
        handleView.decorationView = decoration
        addChildWindow(decorationWindow, ordered: .below)
        handleView.layoutSubtreeIfNeeded()
    }

    func configure(mode: DividerHandleMode, thickness: Double, trackRoom: [DividerHandleArm: Double] = [:]) {
        guard !handleView.matches(mode: mode, thickness: thickness, trackRoom: trackRoom) else { return }
        decorationMargins = mode.decorationMargins
        handleView.configure(mode: mode, thickness: thickness, trackRoom: trackRoom)
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        frameSetCallCount += 1
        if frame != frameRect { super.setFrame(frameRect, display: false) }
        let decorationFrame = frameRect.insetBy(dx: -decorationMargins.x, dy: -decorationMargins.y)
        if decorationWindow.frame != decorationFrame { decorationWindow.setFrame(decorationFrame, display: false) }
        handleView.layoutSubtreeIfNeeded()
    }

    override func orderOut(_ sender: Any?) {
        decorationWindow.orderOut(sender)
        super.orderOut(sender)
    }

    override func orderFrontRegardless() {
        orderCallCount += 1
        super.orderFrontRegardless()
        if handleView.drawsLens { decorationWindow.order(.below, relativeTo: windowNumber) }
    }

    func setDrawingFrame(_ frame: CGRect) {
        handleView.drawingFrame = frame
        handleView.layoutSubtreeIfNeeded()
    }

    func setLensHidden(_ hidden: Bool) {
        handleView.drawsLens = !hidden
        if hidden { decorationWindow.orderOut(nil) }
        else if isVisible { decorationWindow.order(.below, relativeTo: windowNumber) }
    }

    func restoreDrawingFrame() {
        let finalFrame = handleView.drawingFrame
        handleView.drawingSink = nil
        handleView.drawingFrame = nil
        if let finalFrame { setFrame(finalFrame, display: false) }
        setLensHidden(false)
    }

    func setLimit(_ limit: DragLimit) { handleView.setLimit(limit) }
    var limit: DragLimit { handleView.limit }

    func setActive(
        _ active: Bool,
        animated: Bool,
        completion: (() -> Void)? = nil
    ) {
        isActive = active
        handleView.setActive(active, animated: animated, completion: completion)
    }
}

@MainActor
final class DividerHandleView: NSView {
    var onBegin: (() -> Void)?
    var onDrag: ((CGPoint) -> Void)?
    var onEnd: (() -> Void)?
    var onExit: (() -> Void)?

    private var mode: DividerHandleMode
    private var thickness: CGFloat
    let lensLayers: DividerLensLayers
    private let solidLayer = CAShapeLayer()
    weak var decorationView: DividerLensDecorationView?
    private(set) var trackRoom: [DividerHandleArm: Double] = [:]
    private(set) var knobRects: [CGRect] = []
    private(set) var knobOutline: CGPath?
    private(set) var trackRects: [CGRect] = []
    private(set) var lensTint = NSColor.controlAccentColor
    var drawingFrame: CGRect? { didSet { updateAppearance() } }
    private(set) var drawingState: DividerHandleDrawing?
    var drawingSink: ((DividerHandleDrawing) -> Void)?
    var drawsLens = true {
        didSet {
            guard oldValue != drawsLens else { return }
            if drawsLens { lastAppearance = nil; updateAppearance() }
            else {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                lensLayers.handleLayer.isHidden = true
                lensLayers.decorationLayer.isHidden = true
                solidLayer.isHidden = true
                CATransaction.commit()
            }
        }
    }
    var showsSolid: Bool { !solidLayer.isHidden }
    var overlayAppearance = OverlayAppearance() {
        didSet { if oldValue != overlayAppearance { updateAppearance() } }
    }
    var displayOptions: () -> (reduceTransparency: Bool, increaseContrast: Bool) = {
        (NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
         NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
    } { didSet { updateAppearance() } }
    var showsGlass: Bool { !lensLayers.handleLayer.isHidden }
    var renderedThickness: CGFloat {
        CGFloat(DividerHandleGeometry.renderedThickness(Double(thickness), useLiquidGlass: overlayAppearance.useLiquidGlass))
    }
    private var active = false
    /// A neighbor is at its minimum size: the handle turns orange and the
    /// cursor shows only the direction the divider can still move.
    private(set) var limit = DragLimit()
    private(set) var stretchProgress = 0.0
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var animationTask: Task<Void, Never>?
    private var tracking: NSTrackingArea?
    private var geometry: DividerLensGeometry?
    private(set) var outlineBuildCount = 0
    private(set) var appearanceUpdateCount = 0
    private struct AppearanceState: Equatable {
        var size: CGSize
        var mode: DividerHandleMode
        var thickness: CGFloat
        var progress: Double
        var trackRoom: [DividerHandleArm: Double]
        var appearance: OverlayAppearance
        var dark: Bool
        var solid: Bool
        var contrast: Bool
        var limit: DragLimit
        var tint: NSColor
        var scale: CGFloat
    }
    private var lastAppearance: AppearanceState?

    init(frame: CGRect, mode: DividerHandleMode, thickness: Double,
         lensLayers: DividerLensLayers = DividerLensLayers()) {
        self.mode = mode
        self.thickness = CGFloat(thickness)
        self.lensLayers = lensLayers
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(lensLayers.handleLayer)
        layer?.addSublayer(solidLayer)
        updateAppearance()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(updateAppearance),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(updateAppearance), name: NSColor.systemColorsDidChangeNotification, object: nil
        )
    }

    required init?(coder: NSCoder) { nil }

    func matches(mode: DividerHandleMode, thickness: Double, trackRoom: [DividerHandleArm: Double]) -> Bool {
        self.mode == mode && self.thickness == thickness && self.trackRoom == trackRoom
    }

    func configure(mode: DividerHandleMode, thickness: Double, trackRoom: [DividerHandleArm: Double] = [:]) {
        guard !matches(mode: mode, thickness: thickness, trackRoom: trackRoom) else { return }
        self.mode = mode
        self.thickness = CGFloat(thickness)
        self.trackRoom = trackRoom
        needsLayout = true
        window?.invalidateCursorRects(for: self)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }

    override func layout() {
        super.layout()
        updateAppearance()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    func setLimit(_ limit: DragLimit) {
        guard self.limit != limit else { return }
        self.limit = limit
        updateAppearance()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    /// macOS 15 divider cursors. At a limit, only the open direction shows.
    var cursor: NSCursor {
        switch mode {
        case .vertical:
            guard limit.width else { return .columnResize }
            return .columnResize(directions: limit.blockedTowardPositive ? .left : .right)
        case .horizontal:
            guard limit.height else { return .rowResize }
            // Top-left coordinates: positive movement is downward.
            return .rowResize(directions: limit.blockedTowardPositive ? .up : .down)
        case let .junction(_, resting, active):
            // A T-junction is the end of one divider: point the corner cursor
            // at that end. A plus junction uses the top-left diagonal.
            let arms = Set(resting.merging(active) { max($0, $1) }.filter { $0.value > 0 }.keys)
            let atBottom = arms.contains(.up) && !arms.contains(.down)
            let atRight = arms.contains(.left) && !arms.contains(.right)
            let position: NSCursor.FrameResizePosition = switch (atBottom, atRight) {
            case (true, true): .bottomRight
            case (true, false): .bottomLeft
            case (false, true): .topRight
            case (false, false): .topLeft
            }
            return .frameResize(position: position, directions: limit.isLimited ? .inward : .all)
        }
    }

    override func mouseExited(with event: NSEvent) {
        guard !active else { return }
        onExit?()
    }

    override func mouseDown(with event: NSEvent) {
        onBegin?()
    }

    override func mouseDragged(with event: NSEvent) { onDrag?(NSEvent.mouseLocation) }

    override func mouseUp(with event: NSEvent) {
        onEnd?()
    }

    func setActive(
        _ active: Bool,
        animated: Bool,
        completion: (() -> Void)? = nil
    ) {
        guard self.active != active else {
            completion?()
            return
        }
        animationTask?.cancel()
        self.active = active
        let target = active ? 1.0 : 0.0
        guard animated, !reduceMotion(), stretchProgress != target else {
            stretchProgress = target
            needsDisplay = true
            needsLayout = true
            updateAppearance()
            completion?()
            return
        }
        let start = stretchProgress
        let began = CACurrentMediaTime()
        animationTask = Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(for: .milliseconds(8))
                guard let self, !Task.isCancelled else { return }
                // Elapsed time keeps a delayed main-actor frame from slowing
                // the whole transition. Geometry updates never restart it.
                let fraction = min(1, (CACurrentMediaTime() - began) / 0.18)
                let eased = 1 - pow(1 - fraction, 3)
                self.stretchProgress = start + (target - start) * eased
                self.needsDisplay = true
                self.needsLayout = true
                self.updateAppearance()
                if fraction == 1 { break }
            }
            self?.animationTask = nil
            completion?()
        }
    }

    @objc private func updateAppearance() {
        let drawingBounds = CGRect(origin: .zero, size: drawingFrame?.size ?? bounds.size)
        guard drawingBounds.width > 0, drawingBounds.height > 0 else { return }
        let options = displayOptions()
        let solid = !overlayAppearance.useLiquidGlass || options.reduceTransparency || options.increaseContrast
            || !lensLayers.isAvailable
        var tint = NSColor.controlAccentColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            tint = (limit.isLimited ? NSColor.systemOrange : NSColor.controlAccentColor).usingColorSpace(.deviceRGB)
                ?? (limit.isLimited ? .systemOrange : .controlAccentColor)
        }
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        var solidColor = NSColor.secondaryLabelColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            solidColor = gripColor.usingColorSpace(.deviceRGB) ?? gripColor
        }
        drawingState = DividerHandleDrawing(frame: drawingFrame ?? window?.frame ?? frame, mode: mode,
                                            thickness: thickness, progress: stretchProgress, trackRoom: trackRoom,
                                            limit: limit, tint: tint, dark: dark, frost: overlayAppearance.strength,
                                            solid: solid, solidColor: solidColor, increaseContrast: options.increaseContrast,
                                            scale: window?.backingScaleFactor ?? 1, useLiquidGlass: overlayAppearance.useLiquidGlass)
        defer { if let drawingState { drawingSink?(drawingState) } }
        let state = AppearanceState(size: drawingBounds.size, mode: mode, thickness: thickness, progress: stretchProgress,
                                    trackRoom: trackRoom, appearance: overlayAppearance, dark: dark, solid: solid,
                                    contrast: options.increaseContrast, limit: limit, tint: tint,
                                    scale: window?.backingScaleFactor ?? 1)
        guard state != lastAppearance else { return }
        let nextGeometry = DividerLensGeometry(
            bounds: drawingBounds, mode: mode, thickness: thickness, progress: stretchProgress,
            trackRoom: trackRoom, useLiquidGlass: overlayAppearance.useLiquidGlass, cached: geometry
        )
        // Available room changes as the seam moves, but often neither end of
        // the fading track reaches that boundary. Keep the existing layers in
        // that case as well as for a repeated input sample.
        var previous = lastAppearance
        previous?.trackRoom = state.trackRoom
        let unchanged = previous == state && geometry?.capsules == nextGeometry.capsules
            && geometry?.trackRects == nextGeometry.trackRects
        lastAppearance = state
        guard !unchanged else { return }
        appearanceUpdateCount += 1
        if geometry?.capsules != nextGeometry.capsules { outlineBuildCount += 1 }
        geometry = nextGeometry
        knobRects = nextGeometry.capsules
        knobOutline = nextGeometry.outline
        trackRects = nextGeometry.trackRects
        lensTint = tint
        guard drawsLens else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lensLayers.handleLayer.isHidden = solid
        lensLayers.decorationLayer.isHidden = solid
        solidLayer.isHidden = !solid
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if solid {
                let path = CGMutablePath()
                for rect in nextGeometry.capsules { path.addPath(capsulePath(rect)) }
                solidLayer.path = path
                solidLayer.fillColor = gripColor.withAlphaComponent(1).cgColor
                solidLayer.strokeColor = lensTint.withAlphaComponent(options.increaseContrast ? 1 : 0.45).cgColor
                solidLayer.lineWidth = options.increaseContrast ? 1.5 : 0.7
            } else {
                lensLayers.apply(geometry: nextGeometry, margins: mode.decorationMargins, tint: lensTint, dark: dark,
                                 strength: overlayAppearance.strength, limited: limit.isLimited, p: stretchProgress)
            }
        }
        updateContentsScale()
        CATransaction.commit()
    }

    private var gripColor: NSColor {
        if limit.isLimited { return .systemOrange }
        return NSColor.secondaryLabelColor.blended(
            withFraction: stretchProgress, of: NSColor.controlAccentColor.withAlphaComponent(0.88)
        ) ?? .controlAccentColor
    }

    private func updateContentsScale() {
        let scale = window?.backingScaleFactor ?? 1
        lensLayers.setContentsScale(scale)
        solidLayer.contentsScale = scale
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentsScale()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
        needsDisplay = true
    }
}

@MainActor
final class GhostPreviewView: OverlayGlassView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")

    init(frame: CGRect, snapshot: WindowSnapshot?) {
        super.init(frame: frame)
        cornerRadius = 12
        tint = .controlAccentColor
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

    private(set) var isLimited = false

    func update(snapshot: WindowSnapshot?, size: BTSize, limited: Bool = false) {
        titleLabel.stringValue = snapshot?.title.isEmpty == false ? snapshot!.title : snapshot?.bundleIdentifier ?? "Window"
        sizeLabel.stringValue = "\(Int(size.width.rounded())) × \(Int(size.height.rounded()))"
        if isLimited != limited {
            isLimited = limited
            let color: NSColor = limited ? .systemOrange : .controlAccentColor
            tint = color
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer?.borderColor = color.withAlphaComponent(limited ? 0.95 : 0.78).cgColor
            }
            sizeLabel.textColor = limited ? .systemOrange : .secondaryLabelColor
        }
        if let pid = snapshot?.processIdentifier {
            iconView.image = NSRunningApplication(processIdentifier: pid)?.icon
        }
    }
}
