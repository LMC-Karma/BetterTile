import Foundation

/// How BetterTile treats an application's `AXEnhancedUserInterface` attribute
/// while writing a window frame.
///
/// AppKit and Chromium reinterpret window geometry writes while enhanced
/// accessibility is active, so a naive size/position write lands in the wrong
/// place. Disabling the attribute for the duration of the write is the standard
/// remedy. Restoring it afterwards is correct for assistive technology but makes
/// Chromium rebuild its full accessibility tree, which is measurably expensive,
/// so the restore is a user-visible choice.
public enum EnhancedUserInterfacePolicy: String, Codable, CaseIterable, Sendable {
    /// Disable before the write and restore afterwards. Correct default.
    case disableAndRestore
    /// Disable before the write and leave it disabled. Faster for
    /// Chromium-based applications, at the cost of degrading other assistive
    /// technology until the application is relaunched.
    case disableOnly

    public var title: String {
        switch self {
        case .disableAndRestore: "Restore After Moving"
        case .disableOnly: "Leave Disabled"
        }
    }

    public var explanation: String {
        switch self {
        case .disableAndRestore:
            "Recommended. Enhanced accessibility is turned back on after each window change."
        case .disableOnly:
            "Faster for Chromium-based apps, which rebuild their accessibility tree when it is restored."
        }
    }
}

/// The framework-independent decision for one frame write.
public struct EnhancedUserInterfaceDecision: Hashable, Sendable {
    public var shouldDisableBeforeWrite: Bool
    public var shouldRestoreAfterWrite: Bool

    public init(shouldDisableBeforeWrite: Bool, shouldRestoreAfterWrite: Bool) {
        self.shouldDisableBeforeWrite = shouldDisableBeforeWrite
        self.shouldRestoreAfterWrite = shouldRestoreAfterWrite
    }

    /// Leaves the attribute alone entirely.
    public static let untouched = EnhancedUserInterfaceDecision(
        shouldDisableBeforeWrite: false,
        shouldRestoreAfterWrite: false
    )
}

public enum EnhancedUserInterfaceCoordinator {
    /// An application that never enabled enhanced accessibility is never
    /// touched, under any policy. BetterTile only ever restores a value it
    /// disabled itself.
    public static func decision(
        policy: EnhancedUserInterfacePolicy,
        isCurrentlyEnabled: Bool
    ) -> EnhancedUserInterfaceDecision {
        guard isCurrentlyEnabled else { return .untouched }
        return EnhancedUserInterfaceDecision(
            shouldDisableBeforeWrite: true,
            shouldRestoreAfterWrite: policy == .disableAndRestore
        )
    }
}

/// Which of the three Accessibility writes a frame change actually requires.
///
/// The size/position/size sequence exists because several applications clamp a
/// requested position against their current size. When the size is not changing
/// the leading size write is provably redundant: it asks the window for the
/// value it already has. The trailing size write corrects an application that
/// clamped during the position write. Intermediate samples of a continuous
/// gesture skip it: the next sample or the release corrects any clamp, and a
/// size write costs several position writes.
public struct FrameWritePlan: Hashable, Sendable {
    public var writesInitialSize: Bool
    public var writesPosition: Bool
    public var writesFinalSize: Bool

    public init(writesInitialSize: Bool, writesPosition: Bool, writesFinalSize: Bool) {
        self.writesInitialSize = writesInitialSize
        self.writesPosition = writesPosition
        self.writesFinalSize = writesFinalSize
    }

    public var writeCount: Int {
        (writesInitialSize ? 1 : 0) + (writesPosition ? 1 : 0) + (writesFinalSize ? 1 : 0)
    }
}

public enum FrameWritePlanner {
    public static let defaultSizeTolerance: Double = 0.5

    /// - Parameter knownCurrentFrame: The caller's most recent reading of the
    ///   window's frame, or `nil` when the caller has no fresh reading. A `nil`
    ///   reading writes size and position. It also writes the final size when
    ///   `correctsClamping` is `true`.
    public static func plan(
        target: BTRect,
        knownCurrentFrame: BTRect?,
        tolerance: Double = defaultSizeTolerance,
        correctsClamping: Bool = true
    ) -> FrameWritePlan {
        guard let knownCurrentFrame else {
            return FrameWritePlan(writesInitialSize: true, writesPosition: true, writesFinalSize: correctsClamping)
        }
        let sizeIsUnchanged = abs(knownCurrentFrame.size.width - target.size.width) <= tolerance
            && abs(knownCurrentFrame.size.height - target.size.height) <= tolerance
        return FrameWritePlan(
            writesInitialSize: !sizeIsUnchanged,
            writesPosition: true,
            writesFinalSize: correctsClamping
        )
    }
}

/// Decides whether a final size write that kept a larger size is worth a
/// clamp confirmation. The confirmation adds a position nudge and its restore,
/// so it runs only for a clamp the learned minimum does not already explain.
/// Live gesture ticks never confirm; they write through
/// `setIntermediateFrames`.
public enum WriteReadbackPolicy {
    /// True when the window stayed at the requested origin, larger than
    /// requested on an axis the learned minimum does not already explain.
    public static func confirmsClamp(
        requested: BTRect,
        actual: BTRect,
        learnedMinimum: BTSize?,
        tolerance: Double = 2
    ) -> Bool {
        guard abs(actual.minX - requested.minX) <= tolerance,
              abs(actual.minY - requested.minY) <= tolerance else { return false }
        let known = learnedMinimum ?? .zero
        let widthIsNew = actual.size.width > requested.size.width + tolerance
            && actual.size.width > known.width + tolerance
        let heightIsNew = actual.size.height > requested.size.height + tolerance
            && actual.size.height > known.height + tolerance
        return widthIsNew || heightIsNew
    }

    /// True when a readback proves that the application processed the
    /// write: the window moved to the requested origin, or its size changed.
    /// A frame that ignored the write proves nothing.
    public static func readbackProvesWrite(
        requested: BTRect,
        previous: BTRect?,
        actual: BTRect,
        tolerance: Double = 2
    ) -> Bool {
        let movedToRequest = previous.map {
            abs($0.minX - requested.minX) > tolerance || abs($0.minY - requested.minY) > tolerance
        } ?? false
        let atRequestedOrigin = abs(actual.minX - requested.minX) <= tolerance
            && abs(actual.minY - requested.minY) <= tolerance
        let sizeChanged = previous.map {
            abs($0.size.width - actual.size.width) > tolerance || abs($0.size.height - actual.size.height) > tolerance
        } ?? false
        return (movedToRequest && atRequestedOrigin) || sizeChanged
    }

    /// True when a final write needs the position nudge. The readback must
    /// show a clamp that the learned minimum does not explain, and that the
    /// readback alone cannot prove. A single-window write and a batched
    /// committed write use this same rule.
    public static func needsClampConfirmation(
        requested: BTRect,
        previous: BTRect?,
        actual: BTRect,
        learnedMinimum: BTSize?
    ) -> Bool {
        confirmsClamp(requested: requested, actual: actual, learnedMinimum: learnedMinimum)
            && !readbackProvesWrite(requested: requested, previous: previous, actual: actual)
    }

    /// True when a 1 pt position nudge proves that the application handles
    /// writes at once. The window must follow the nudge and then return to
    /// its position. A window left at the nudged position is no proof.
    public static func nudgeConfirmsSynchronousWrites(
        nudged: BTPoint,
        observed: BTPoint?,
        returned: Bool,
        tolerance: Double = 0.5
    ) -> Bool {
        guard returned, let observed else { return false }
        return abs(observed.x - nudged.x) <= tolerance
    }
}

/// Applications whose Accessibility call just waited out its messaging
/// timeout, which usually means the application is hung. Every call to a hung
/// application blocks the main thread until its timeout, and one gesture makes
/// many reads and writes, so a single divider drag froze BetterTile for about
/// five seconds. Calls to a held application fail at once, as a timed-out call
/// would, until the hold ends; a call that completes ends it sooner.
public struct UnresponsiveApplicationGate: Sendable {
    /// A `cannotComplete` that took this long waited out its timeout. The
    /// shortest timeout BetterTile sets is 0.35 s.
    public static let stallSeconds = 0.3
    public static let holdSeconds = 2.0

    private var holdsUntil: [Int32: Double] = [:]

    public init() {}

    public func isHeld(_ processIdentifier: Int32, now: Double) -> Bool {
        (holdsUntil[processIdentifier] ?? -.infinity) > now
    }

    /// Records one call. A quick `cannotComplete` is an answer from a busy
    /// application, not a hang, so it neither starts nor ends a hold.
    public mutating func record(_ processIdentifier: Int32, cannotComplete: Bool, elapsed: Double, now: Double) {
        if !cannotComplete {
            holdsUntil.removeValue(forKey: processIdentifier)
        } else if elapsed >= Self.stallSeconds {
            holdsUntil[processIdentifier] = now + Self.holdSeconds
        }
    }
}
