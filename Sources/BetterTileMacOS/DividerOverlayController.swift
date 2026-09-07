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
        adjacencyTolerance: Double
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

        for vertical in verticals {
            for horizontal in horizontals
                where vertical.displayID == horizontal.displayID
                    && vertical.branchID != horizontal.branchID
                    && horizontal.spanStart <= vertical.coordinate
                    && vertical.coordinate <= horizontal.spanEnd
                    && vertical.spanStart <= horizontal.coordinate
                    && horizontal.coordinate <= vertical.spanEnd {
                let center = BTPoint(x: vertical.coordinate, y: horizontal.coordinate)
                guard abs(point.x - center.x) <= radius, abs(point.y - center.y) <= radius else { continue }
                let meeting = eligible.filter { boundary in
                    guard boundary.displayID == vertical.displayID, boundary.branchID != nil else { return false }
                    switch boundary.axis {
                    case .vertical:
                        return abs(boundary.coordinate - center.x) <= adjacencyTolerance
                            && boundary.spanStart <= center.y && center.y <= boundary.spanEnd
                    case .horizontal:
                        return abs(boundary.coordinate - center.y) <= adjacencyTolerance
                            && boundary.spanStart <= center.x && center.x <= boundary.spanEnd
                    }
                }
                let unique = Dictionary(grouping: meeting, by: \.id).compactMap { $0.value.first }
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
        if isDragging {
            if !activeParticipantsArePresent() { cancelActiveGesture() }
            return
        }
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
        guard let interaction = DividerInteractionResolver.resolve(
            at: point,
            in: boundaries,
            hitWidth: hitWidth,
            adjacencyTolerance: configuration.adjacencyTolerance
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
            panel.onEnd = { [weak self] in self?.end() }
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
    }

    private func beginHoveredGesture() {
        guard let interaction = hoveredInteraction,
              let mainFrame = NSScreen.screens.first?.frame,
              let display = coordinator.system.displays().first(where: { $0.id == interaction.displayID }),
              let windows = try? coordinator.system.visibleWindows()
        else {
            handlePanel?.setActive(false, animated: false)
            return
        }
        let point = currentMousePoint()
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
        isDragging = true
        installEscapeMonitor()
        baselineWindows = windows
        displayBounds = display.visibleFrame
        startPoint = currentMousePoint()
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
        switch configuration.resizeFeedbackMode {
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

    private func drag(to appKitPoint: CGPoint) {
        guard let interaction = activeInteraction, let startPoint, let displayBounds, var transaction else { return }
        guard activeParticipantsArePresent() else {
            cancelActiveGesture()
            return
        }
        let point = topLeftPoint(appKitPoint)
        let placements: [Placement]
        let proposedInteraction: DividerInteraction
        var proposedState = proposedBentoState

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
            if Date().timeIntervalSince(lastGhostUpdate) >= 1.0 / 60.0 {
                lastGhostUpdate = Date()
                activeInteraction = proposedInteraction
                ghosts.show(
                    placements: placements,
                    windows: baselineWindows,
                    below: handlePanel
                )
                presentHandle(for: proposedInteraction, near: point, active: true)
            }
        case .live:
            ghosts.hide()
            guard Date().timeIntervalSince(lastLiveUpdate) >= 1.0 / 30.0 else { return }
            lastLiveUpdate = Date()
            switch coordinator.applyLive(transaction: &transaction, placements: placements) {
            case .applied:
                latestPlacements = placements
                proposedBentoState = proposedState
                activeInteraction = proposedInteraction
                self.transaction = transaction
                presentHandle(for: proposedInteraction, near: point, active: true)
            case .failed:
                // A transient rejection keeps the gesture alive; the next drag
                // sample proposes fresh placements.
                self.transaction = transaction
                return
            case .degraded:
                reportRollbackFailure(displayID: interaction.displayID, outcome: coordinator.cancel(transaction: transaction))
                clearGesture()
                return
            }
        }
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
        removeEscapeMonitor()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        handlePanel?.setActive(
            false,
            animated: wasDragging && !reduceMotion
        ) { [weak self] in
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
}

enum DividerInteractionKind: Equatable {
    case vertical
    case horizontal
    case junction(verticalBranchID: UUID, horizontalBranchID: UUID)
}

private enum DividerHandleMode: Equatable {
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
private final class DividerHandleView: NSView {
    var onBegin: (() -> Void)?
    var onDrag: ((CGPoint) -> Void)?
    var onEnd: (() -> Void)?
    var onExit: (() -> Void)?

    private var mode: DividerHandleMode
    private var thickness: CGFloat
    private let material = NSVisualEffectView()
    private var active = false
    private var stretchProgress = 0.0
    private var animationTask: Task<Void, Never>?
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
        case let .vertical(resting, expanded):
            let length = interpolated(resting, expanded)
            material.frame = CGRect(
                x: (bounds.width - thickness) / 2,
                y: (bounds.height - length) / 2,
                width: thickness,
                height: length
            )
        case let .horizontal(resting, expanded):
            let length = interpolated(resting, expanded)
            material.frame = CGRect(
                x: (bounds.width - length) / 2,
                y: (bounds.height - thickness) / 2,
                width: length,
                height: thickness
            )
        case let .junction(center, _, _):
            let size = min(14, max(10, thickness * 1.7))
            material.frame = CGRect(
                x: center.x - size / 2,
                y: center.y - size / 2,
                width: size,
                height: size
            )
        }
        material.layer?.cornerRadius = min(material.bounds.width, material.bounds.height) / 2
    }

    override func draw(_ dirtyRect: NSRect) {
        guard case let .junction(center, resting, expanded) = mode else { return }
        let color = (active ? NSColor.controlAccentColor : NSColor.labelColor)
            .withAlphaComponent(active ? 0.88 : 0.20)
        color.setStroke()
        for arm in Set(resting.keys).union(expanded.keys) {
            let length = interpolated(resting[arm] ?? 0, expanded[arm] ?? 0)
            let end: CGPoint
            switch arm {
            case .left: end = CGPoint(x: center.x - length, y: center.y)
            case .right: end = CGPoint(x: center.x + length, y: center.y)
            case .up: end = CGPoint(x: center.x, y: center.y + length)
            case .down: end = CGPoint(x: center.x, y: center.y - length)
            }
            let path = NSBezierPath()
            path.move(to: center)
            path.line(to: end)
            path.lineWidth = thickness
            path.lineCapStyle = .round
            path.stroke()
        }
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
        animationTask?.cancel()
        self.active = active
        updateAppearance()
        let target = active ? 1.0 : 0.0
        guard animated, stretchProgress != target else {
            stretchProgress = target
            needsDisplay = true
            needsLayout = true
            completion?()
            return
        }
        let start = stretchProgress
        animationTask = Task { @MainActor [weak self] in
            for step in 1 ... 11 {
                try? await Task.sleep(for: .milliseconds(16))
                guard let self, !Task.isCancelled else { return }
                let fraction = Double(step) / 11
                let eased = fraction * fraction * (3 - 2 * fraction)
                self.stretchProgress = start + (target - start) * eased
                self.needsDisplay = true
                self.needsLayout = true
            }
            self?.animationTask = nil
            completion?()
        }
    }

    private func interpolated(_ resting: Double, _ expanded: Double) -> CGFloat {
        CGFloat(resting + (expanded - resting) * stretchProgress)
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
final class GhostFrameOverlayController {
    private var panels: [WindowID: NSPanel] = [:]
    var windowNumbers: Set<Int> { Set(panels.values.map(\.windowNumber)) }
    private(set) var relativeOrderTargets: [WindowID: Int] = [:]

    func show(
        placements: [Placement],
        windows: [WindowSnapshot],
        below handle: NSWindow?
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
                panel.setFrame(frame, display: true)
            } else {
                panel = makePanel(frame: frame, snapshot: snapshots[placement.windowID])
                panels[placement.windowID] = panel
            }
            (panel.contentView as? GhostPreviewView)?.update(
                snapshot: snapshots[placement.windowID],
                size: placement.frame.size
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

    func hide() {
        for panel in panels.values { panel.orderOut(nil) }
        panels.removeAll()
        relativeOrderTargets.removeAll()
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
