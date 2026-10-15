import Foundation

/// Maps a pointer location to exactly one display. The window drag overlay
/// and its release both use it, so they cannot disagree about the display.
public enum PointerDisplay {
    /// The display under `point`. Display frames are half-open, [min, max),
    /// as in CoreGraphics, so a point on an edge that two displays share
    /// belongs to the display that starts there: the right display of a
    /// side-by-side pair and the lower display of a stack. A point on an
    /// outer edge, which no half-open frame holds, belongs to the display
    /// whose closed frame holds it.
    public static func display(at point: BTPoint, in displays: [DisplaySnapshot]) -> DisplaySnapshot? {
        displays.first { holds($0.frame, point) } ?? displays.first { $0.frame.contains(point) }
    }

    private static func holds(_ frame: BTRect, _ point: BTPoint) -> Bool {
        point.x >= frame.minX && point.x < frame.maxX && point.y >= frame.minY && point.y < frame.maxY
    }
}

/// A Bento or Tabbed drop plan that the overlay showed. Release commits this
/// plan as it is and does not plan the drop again.
public struct PreparedLayoutDrop: Equatable, Sendable {
    public enum Plan: Equatable, Sendable {
        /// A Bento reflow, snap, or Focus mode drop.
        case bento(BentoDropPlan)
        /// A Tabbed arrangement: a snap, or the window added to a pane as a tab.
        case tabbed(TabbedLayoutState)
        /// A floating Tabbed window that only moves to the placement's frame.
        case frame
    }

    public let outcome: BentoDragOutcome
    /// The frames the overlay showed. Hidden tabs are not included.
    public let placements: [Placement]
    public let plan: Plan
    /// The drag that prepared the plan. Release rejects a plan from another drag.
    public let dragID: UUID

    public init(outcome: BentoDragOutcome, placements: [Placement], plan: Plan, dragID: UUID) {
        self.outcome = outcome
        self.placements = placements
        self.plan = plan
        self.dragID = dragID
    }

    public var bentoPlan: BentoDropPlan? {
        if case let .bento(plan) = plan { return plan }
        return nil
    }

    public var tabbedState: TabbedLayoutState? {
        if case let .tabbed(state) = plan { return state }
        return nil
    }
}

/// What planning a Bento or Tabbed drop for the overlay produced.
public enum LayoutDropPreview: Equatable, Sendable {
    case ready(PreparedLayoutDrop)
    /// The drop cannot apply. The overlay shows invalid feedback.
    case invalid(reason: String)
}

/// How a Bento or Tabbed window drag ends.
public enum LayoutDragEnd: Equatable, Sendable {
    /// Commit the plan the overlay showed.
    case commit(PreparedLayoutDrop)
    /// The overlay showed no drop. The window returns to where it started.
    case restore
    /// The overlay showed invalid feedback. Nothing applies, the window
    /// returns to where it started, and the result pill shows the reason.
    case failed(reason: String)
}

/// The drop that a window drag's overlay shows. The overlay is the only
/// decision: release commits this value and does not evaluate the release
/// point again. Where the dragged window's body or center is does not matter.
public struct WindowDropTarget: Equatable, Sendable {
    public enum Drop: Equatable, Sendable {
        /// An ordinary snap. The dragged window alone takes the target frame.
        case snap(SnapTarget)
        /// A Bento or Tabbed drop: a snap, a pane insertion, or a swap.
        case layout(PreparedLayoutDrop)
        /// Invalid feedback. Release applies nothing and reports the reason.
        case invalid(reason: String)
    }

    /// The display under the pointer when the overlay showed the drop.
    public let displayID: DisplayID
    public let drop: Drop

    public init(displayID: DisplayID, drop: Drop) {
        self.displayID = displayID
        self.drop = drop
    }

    /// How a Bento or Tabbed drag ends when it is released over this drop.
    public var layoutEnd: LayoutDragEnd {
        switch drop {
        case let .layout(prepared): .commit(prepared)
        case let .invalid(reason): .failed(reason: reason)
        case .snap: .restore
        }
    }
}

/// Where a window drag's release puts its windows.
public struct DropDestination: Hashable, Sendable {
    /// The display the overlay showed the drop on. Only the dragged window is
    /// checked on it: its center can be on the neighbouring display during
    /// the gesture. Every other window keeps its own display.
    public var displayID: DisplayID
    public var sourceWindowID: WindowID
    /// The minimum sizes the overlay planned the drop with. Release checks
    /// each window's frame against them, so a minimum read again at release
    /// cannot veto a drop the overlay showed as valid. A window without an
    /// entry is checked against its current minimum.
    public var minimumSizes: [WindowID: BTSize]

    public init(displayID: DisplayID, sourceWindowID: WindowID, minimumSizes: [WindowID: BTSize] = [:]) {
        self.displayID = displayID
        self.sourceWindowID = sourceWindowID
        self.minimumSizes = minimumSizes
    }
}

public enum SnapFrameFit {
    /// Whether a snap frame holds the window's minimum size. A minimum larger
    /// than the display's visible frame leaves the clamped frame too small.
    public static func holds(_ frame: BTRect, minimumSize: BTSize, tolerance: Double = 0.001) -> Bool {
        frame.size.width + tolerance >= minimumSize.width && frame.size.height + tolerance >= minimumSize.height
    }
}

public enum BentoDropDecision {
    /// At a screen edge the pointer is also on the outer edge of the nearest
    /// pane. The edge's snap area is the user's evident intent; inserting
    /// beside that pane gave a column at its minimum width. A pane center
    /// still competes with the snap area through its hover delay.
    public static func snapWins(_ snapTarget: SnapTarget?, over position: BentoPaneDropPosition) -> Bool {
        snapTarget?.action != nil && position != .center
    }

    public static func outcome(
        candidate: BentoHoverCandidate?,
        isArmed: Bool,
        snapTarget: SnapTarget?
    ) -> BentoDragOutcome {
        if let candidate, let snapTarget, let action = snapTarget.action,
           snapWins(snapTarget, over: candidate.position) {
            return .snap(action: action, frame: snapTarget.frame)
        }
        if let candidate, isArmed {
            return candidate.position == .center
                ? .swap(targetWindowID: candidate.targetWindowID)
                : .insert(targetWindowID: candidate.targetWindowID, edge: candidate.position)
        }
        if let snapTarget, let action = snapTarget.action {
            return .snap(action: action, frame: snapTarget.frame)
        }
        return .restore
    }
}
