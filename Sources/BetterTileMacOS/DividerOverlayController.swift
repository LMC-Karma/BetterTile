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
        return available.reduce(into: [:]) { result, entry in
            result[entry.key] = min(requested, max(0, entry.value - half))
        }
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
        didSet { updateHover(at: NSEvent.mouseLocation) }
    }
    public var layoutChangedHandler: ((DisplayID, [WindowID: BTRect]) -> Void)?
    public var bentoStateProvider: ((DisplayID) -> BentoLayoutState?)?
    public var bentoStateChangedHandler: ((DisplayID, BentoLayoutState, [WindowID: BTRect], [WindowID: BTRect]) -> Void)?
    public var rollbackFailureHandler: ((DisplayID, String?) -> Void)?
    public var gestureEndedHandler: (() -> Void)?
    public private(set) var isDragging = false
    /// Debug experiment. The handle only draws: the click reaches the real
    /// window edge, macOS resizes that window natively, and the other
    /// participants show ghosts until release commits the whole layout.
    public var nativeLedResize = false {
        didSet {
            guard nativeLedResize != oldValue, !isDragging else { return }
            syncHoverMonitoring()
            updateHover(at: NSEvent.mouseLocation)
        }
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
    private let ghosts = GhostFrameOverlayController()
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
    private var latestDragPoint: CGPoint?
    private var hasPendingDisplayUpdate = false
    private var nativeMouseMonitors: [Any] = []
    private var isNativeGesture = false
    private(set) var nativeSourceID: WindowID?
    /// Frames to restore at mouse-up after a cancelled native gesture. The
    /// application keeps resizing its window until the button is released.
    private(set) var pendingNativeRestore: [WindowID: BTRect]?

    /// A native gesture always uses ghosts: only the grabbed window is live,
    /// and the application moves that one itself.
    private var feedbackMode: ResizeFeedbackMode {
        isNativeGesture ? .ghost : configuration.resizeFeedbackMode
    }

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
        if let existing = handlePanel {
            panel = existing
            panel.configure(mode: mode, thickness: configuration.dividerThickness)
            // The accepted divider coordinate moves immediately. Only the
            // decoration inside this frame animates its length.
            panel.setFrame(appKitFrame, display: true)
        } else {
            panel = DividerHandlePanel(frame: appKitFrame, mode: mode, thickness: configuration.dividerThickness)
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
        panel.ignoresMouseEvents = nativeLedResize
    }

    private func beginHoveredGesture() {
        guard let interaction = hoveredInteraction else { return }
        beginGesture(interaction: interaction, at: currentMousePoint())
    }

    func beginGesture(interaction: DividerInteraction, at point: BTPoint, native: Bool = false) {
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
        isNativeGesture = native
        nativeSourceID = nil
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
            maximumFramesPerSecond: feedbackMode == .live ? 60 : nil
        ) { [weak self] in
            self?.displayTick()
        }
        switch feedbackMode {
        case .ghost:
            ghosts.show(
                placements: latestPlacements,
                windows: windows,
                below: handlePanel
            )
        case .live:
            ghosts.hide()
        }
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

    private func applyDrag(to appKitPoint: CGPoint, validateParticipants: Bool) {
        guard let interaction = baselineInteraction, let startPoint, let displayBounds, var transaction else { return }
        guard feedbackMode == .live || activeParticipantsArePresent() else {
            cancelActiveGesture()
            return
        }
        let point = topLeftPoint(appKitPoint)
        let placements: [Placement]
        let proposedInteraction: DividerInteraction
        var proposedState = proposedBentoState

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
        } else {
            guard let boundary = interaction.boundaries.first else { return }
            let delta = boundary.axis == .vertical ? point.x - startPoint.x : point.y - startPoint.y
            guard let result = LinkedResizeEngine(tolerance: configuration.adjacencyTolerance).resize(
                boundary: boundary, delta: delta, windows: baselineWindows, bounds: displayBounds
            ) else { return }
            placements = result.placements
            var moved = boundary
            moved.coordinate += result.appliedDelta
            proposedInteraction = DividerInteraction(boundaries: [moved], kind: interaction.kind)
        }

        switch feedbackMode {
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
            if isNativeGesture { identifyNativeSource() }
            let limited = limitedWindowIDs(in: placements)
            ghosts.show(
                placements: placements.filter { $0.windowID != nativeSourceID },
                windows: baselineWindows,
                below: handlePanel,
                limitedWindowIDs: limited
            )
            presentHandle(for: proposedInteraction, near: point, active: true)
            handlePanel?.setLimited(!limited.isEmpty)
        case .live:
            ghosts.hide()
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
                presentHandle(for: proposedInteraction, near: point, active: true)
                handlePanel?.setLimited(!limitedWindowIDs(in: placements).isEmpty)
            case .failed:
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
        switch feedbackMode {
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
        } else if isNativeGesture {
            // The application already moved the grabbed window. A rejected
            // commit must not leave it overlapping the unchanged neighbors.
            restore(transaction.baselineFrames)
        }
        clearGesture()
    }

    func cancelActiveGesture() {
        if isNativeGesture, let transaction {
            pendingNativeRestore = transaction.baselineFrames
        }
        // Ghosts retract to the frames the windows keep.
        ghosts.hide(retractingTo: transaction?.baselineFrames)
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
        isNativeGesture = false
        nativeSourceID = nil
        handlePanel?.setLimited(false)
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
        syncNativeMouseMonitoring()
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

    private func syncNativeMouseMonitoring() {
        let needed = (nativeLedResize && !boundaries.isEmpty) || isNativeGesture || pendingNativeRestore != nil
        if !needed {
            nativeMouseMonitors.forEach(NSEvent.removeMonitor)
            nativeMouseMonitors = []
            return
        }
        guard nativeMouseMonitors.isEmpty else { return }
        // Global monitors see the click because the handle ignores it; the
        // application under the pointer receives and handles the edge drag.
        nativeMouseMonitors = [NSEvent.EventTypeMask.leftMouseDown, .leftMouseDragged, .leftMouseUp].compactMap { mask in
            NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
                let type = event.type
                let location = NSEvent.mouseLocation
                Task { @MainActor in self?.receiveNativeMouse(type, at: location) }
            }
        }
    }

    func receiveNativeMouse(_ type: NSEvent.EventType, at location: CGPoint) {
        switch type {
        case .leftMouseDown:
            guard nativeLedResize, !isDragging, pendingNativeRestore == nil else { return }
            updateHover(at: location)
            guard let interaction = hoveredInteraction else { return }
            beginGesture(interaction: interaction, at: topLeftPoint(location), native: true)
            syncNativeMouseMonitoring()
        case .leftMouseDragged:
            if isNativeGesture { drag(to: location) }
        case .leftMouseUp:
            if let frames = pendingNativeRestore {
                pendingNativeRestore = nil
                restore(frames)
                syncHoverMonitoring()
            } else if isNativeGesture {
                end(at: location)
                syncHoverMonitoring()
            }
        default:
            break
        }
    }

    /// The window that changed from its baseline is the one the application
    /// is resizing. Reads stop once it is known.
    private func identifyNativeSource() {
        guard nativeSourceID == nil, let transaction else { return }
        let ids = Set(transaction.baselineFrames.keys)
        let current: [WindowSnapshot]? = if let targeted = coordinator.system as? any TargetedWindowSystem {
            try? targeted.windowSnapshots(ids: ids)
        } else {
            try? coordinator.system.visibleWindows().filter { ids.contains($0.id) }
        }
        nativeSourceID = current?.first { snapshot in
            transaction.baselineFrames[snapshot.id].map { !snapshot.frame.approximatelyEquals($0, tolerance: 1) } ?? false
        }?.id
    }

    private func limitedWindowIDs(in placements: [Placement]) -> Set<WindowID> {
        ResizeLimits.windowsAtMinimum(
            placements,
            windows: baselineWindows,
            baselineFrames: transaction?.baselineFrames ?? [:]
        )
    }

    private func restore(_ frames: [WindowID: BTRect]) {
        _ = coordinator.applyPlacements(
            frames.map { Placement(windowID: $0.key, frame: $0.value) }.sorted { $0.windowID < $1.windowID },
            recordHistory: false
        )
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

    private func handleFrame(
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
                thickness: configuration.dividerThickness
            )
            return DividerHandleGeometry.junctionFrame(
                center: center,
                armLengths: arms,
                thickness: configuration.dividerThickness
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

    private func handleMode(
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
                    thickness: configuration.dividerThickness
                ),
                active: DividerHandleGeometry.junctionArmLengths(
                    center: center,
                    boundaries: interaction.boundaries,
                    active: true,
                    thickness: configuration.dividerThickness
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
        return NSApp.windows.contains { window in
            if let handlePanel, window === handlePanel { return false }
            return window.isVisible
                && !window.ignoresMouseEvents
                && window.frame.intersects(appKitFrame)
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
private final class DividerHandlePanel: NSPanel {
    var onBegin: (() -> Void)? { didSet { handleView.onBegin = onBegin } }
    var onDrag: ((CGPoint) -> Void)? { didSet { handleView.onDrag = onDrag } }
    var onEnd: (() -> Void)? { didSet { handleView.onEnd = onEnd } }
    var onExit: (() -> Void)? { didSet { handleView.onExit = onExit } }
    private let handleView: DividerHandleView
    private(set) var isActive = false

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

    func setLimited(_ limited: Bool) { handleView.setLimited(limited) }
    var isLimited: Bool { handleView.isLimited }

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
    private var active = false
    /// A neighbor reached its minimum size; the active handle turns orange.
    private(set) var isLimited = false
    private(set) var stretchProgress = 0.0
    private var animationTask: Task<Void, Never>?
    private var tracking: NSTrackingArea?

    init(frame: CGRect, mode: DividerHandleMode, thickness: Double) {
        self.mode = mode
        self.thickness = CGFloat(thickness)
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { nil }

    func configure(mode: DividerHandleMode, thickness: Double) {
        self.mode = mode
        self.thickness = CGFloat(thickness)
        needsLayout = true
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    func setLimited(_ limited: Bool) {
        guard isLimited != limited else { return }
        isLimited = limited
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // The shared capsule leaves room at each end for its glow.
        let width = ResizeHandleStyle.capsuleWidth(thickness: thickness, progress: stretchProgress)
        switch mode {
        case let .vertical(resting, expanded):
            let length = max(width, interpolated(resting, expanded) - 8)
            ResizeHandleStyle.drawCapsule(
                CGRect(x: bounds.midX - width / 2, y: bounds.midY - length / 2, width: width, height: length),
                progress: stretchProgress, baseline: .hover, limited: isLimited
            )
            return
        case let .horizontal(resting, expanded):
            let length = max(width, interpolated(resting, expanded) - 8)
            ResizeHandleStyle.drawCapsule(
                CGRect(x: bounds.midX - length / 2, y: bounds.midY - width / 2, width: length, height: width),
                progress: stretchProgress, baseline: .hover, limited: isLimited
            )
            return
        case .junction:
            break
        }
        guard case let .junction(center, resting, expanded) = mode else { return }
        let color = gripColor
        color.setFill()
        let path = NSBezierPath()
        for arm in Set(resting.keys).union(expanded.keys) {
            let length = interpolated(resting[arm] ?? 0, expanded[arm] ?? 0)
            let end: CGPoint
            switch arm {
            case .left: end = CGPoint(x: center.x - length, y: center.y)
            case .right: end = CGPoint(x: center.x + length, y: center.y)
            case .up: end = CGPoint(x: center.x, y: center.y + length)
            case .down: end = CGPoint(x: center.x, y: center.y - length)
            }
            let rect = CGRect(
                x: min(center.x, end.x) - thickness / 2,
                y: min(center.y, end.y) - thickness / 2,
                width: abs(end.x - center.x) + thickness,
                height: abs(end.y - center.y) + thickness
            )
            path.append(NSBezierPath(roundedRect: rect, xRadius: thickness / 2, yRadius: thickness / 2))
        }
        path.fill()
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
        case .vertical: ResizeHandleStyle.cursor(verticalDivider: true)
        case .horizontal: ResizeHandleStyle.cursor(verticalDivider: false)
        case .junction: ResizeHandleStyle.junctionCursor
        }
        addCursorRect(bounds, cursor: cursor)
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
        guard animated, stretchProgress != target else {
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

    private func interpolated(_ resting: Double, _ expanded: Double) -> CGFloat {
        CGFloat(resting + (expanded - resting) * stretchProgress)
    }

    private func updateAppearance() {
        needsDisplay = true
    }

    private var gripColor: NSColor {
        NSColor.secondaryLabelColor.blended(
            withFraction: stretchProgress,
            of: NSColor.controlAccentColor.withAlphaComponent(0.88)
        ) ?? .controlAccentColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
        needsDisplay = true
    }
}

@MainActor
final class GhostFrameOverlayController {
    private var panels: [WindowID: NSPanel] = [:]
    /// Panels still fading or retracting after their gesture ended.
    private var departing: [NSPanel] = []
    var windowNumbers: Set<Int> { Set(panels.values.map(\.windowNumber)) }
    var ghostedWindowIDs: Set<WindowID> { Set(panels.keys) }
    private(set) var relativeOrderTargets: [WindowID: Int] = [:]

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func show(
        placements: [Placement],
        windows: [WindowSnapshot],
        below handle: NSWindow?,
        limitedWindowIDs: Set<WindowID> = []
    ) {
        guard let mainFrame = NSScreen.screens.first?.frame else { return }
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
                // Frames follow the pointer on every display tick; animating
                // them would only add lag.
                panel.setFrame(frame, display: true)
            } else {
                panel = makePanel(frame: frame, snapshot: snapshots[placement.windowID])
                panels[placement.windowID] = panel
                fadeIn(panel)
            }
            (panel.contentView as? GhostPreviewView)?.update(
                snapshot: snapshots[placement.windowID],
                size: placement.frame.size,
                limited: limitedWindowIDs.contains(placement.windowID)
            )
            if let handle, handle.windowNumber > 0 {
                panel.order(.below, relativeTo: handle.windowNumber)
                relativeOrderTargets[placement.windowID] = handle.windowNumber
            } else {
                panel.orderFrontRegardless()
                relativeOrderTargets[placement.windowID] = nil
            }
        }
    }

    /// Ends the preview. Committed ghosts fade out over the windows that
    /// now occupy their frames. Cancelled ghosts first retract to the
    /// frames the windows kept, so the cancellation is visible.
    func hide(retractingTo baselineFrames: [WindowID: BTRect]? = nil) {
        let ending = panels
        panels.removeAll()
        relativeOrderTargets.removeAll()
        guard !reduceMotion, let mainFrame = NSScreen.screens.first?.frame else {
            for panel in ending.values { panel.orderOut(nil) }
            return
        }
        departing.append(contentsOf: ending.values)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = baselineFrames == nil ? 0.14 : 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for (id, panel) in ending {
                if let frame = baselineFrames?[id] {
                    panel.animator().setFrame(
                        CoordinateConverter.toAppKit(frame, mainScreenFrame: mainFrame).insetBy(dx: 3, dy: 3),
                        display: true
                    )
                }
                panel.animator().alphaValue = 0
            }
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                for panel in ending.values { panel.orderOut(nil) }
                self?.departing.removeAll { panel in ending.values.contains { $0 === panel } }
            }
        }
    }

    private func fadeIn(_ panel: NSPanel) {
        guard !reduceMotion else { return }
        panel.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
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
