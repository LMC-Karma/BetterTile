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
/// value it already has. The trailing size write is kept in every case because
/// it is what corrects an application that clamped during the position write.
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
    ///   reading always produces the full three-write sequence.
    public static func plan(
        target: BTRect,
        knownCurrentFrame: BTRect?,
        tolerance: Double = defaultSizeTolerance
    ) -> FrameWritePlan {
        guard let knownCurrentFrame else {
            return FrameWritePlan(writesInitialSize: true, writesPosition: true, writesFinalSize: true)
        }
        let sizeIsUnchanged = abs(knownCurrentFrame.size.width - target.size.width) <= tolerance
            && abs(knownCurrentFrame.size.height - target.size.height) <= tolerance
        return FrameWritePlan(
            writesInitialSize: !sizeIsUnchanged,
            writesPosition: true,
            writesFinalSize: true
        )
    }
}
