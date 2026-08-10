import Foundation

public struct WindowID: RawRepresentable, Codable, Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
    public static func < (lhs: WindowID, rhs: WindowID) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct DisplayID: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func < (lhs: DisplayID, rhs: DisplayID) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct WindowConstraints: Codable, Hashable, Sendable {
    public var minimumSize: BTSize
    public var maximumSize: BTSize?
    public var isMovable: Bool
    public var isResizable: Bool

    public init(
        minimumSize: BTSize = BTSize(width: 120, height: 80),
        maximumSize: BTSize? = nil,
        isMovable: Bool = true,
        isResizable: Bool = true
    ) {
        self.minimumSize = minimumSize
        self.maximumSize = maximumSize
        self.isMovable = isMovable
        self.isResizable = isResizable
    }
}

public struct WindowSnapshot: Codable, Hashable, Sendable {
    public var id: WindowID
    public var processIdentifier: Int32
    public var bundleIdentifier: String?
    public var title: String
    public var frame: BTRect
    public var displayID: DisplayID
    public var constraints: WindowConstraints
    public var isMinimized: Bool
    public var isFullScreen: Bool
    public var isHidden: Bool
    public var isFloating: Bool

    public init(
        id: WindowID,
        processIdentifier: Int32,
        bundleIdentifier: String? = nil,
        title: String = "",
        frame: BTRect,
        displayID: DisplayID,
        constraints: WindowConstraints = WindowConstraints(),
        isMinimized: Bool = false,
        isFullScreen: Bool = false,
        isHidden: Bool = false,
        isFloating: Bool = false
    ) {
        self.id = id
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.title = title
        self.frame = frame
        self.displayID = displayID
        self.constraints = constraints
        self.isMinimized = isMinimized
        self.isFullScreen = isFullScreen
        self.isHidden = isHidden
        self.isFloating = isFloating
    }

    public var isEligible: Bool {
        !isMinimized && !isFullScreen && !isHidden && constraints.isMovable
    }
}

public struct DisplaySnapshot: Codable, Hashable, Sendable {
    public var id: DisplayID
    public var frame: BTRect
    public var visibleFrame: BTRect
    public var scaleFactor: Double
    public var isMain: Bool

    public init(id: DisplayID, frame: BTRect, visibleFrame: BTRect, scaleFactor: Double = 1, isMain: Bool = false) {
        self.id = id
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.scaleFactor = scaleFactor
        self.isMain = isMain
    }
}

public struct DesktopContext: Codable, Hashable, Sendable {
    public var displays: [DisplaySnapshot]
    public var activeDisplayID: DisplayID?

    public init(displays: [DisplaySnapshot], activeDisplayID: DisplayID? = nil) {
        self.displays = displays
        self.activeDisplayID = activeDisplayID
    }

    public func display(id: DisplayID) -> DisplaySnapshot? { displays.first { $0.id == id } }
}

public struct Placement: Codable, Hashable, Sendable {
    public var windowID: WindowID
    public var frame: BTRect

    public init(windowID: WindowID, frame: BTRect) {
        self.windowID = windowID
        self.frame = frame
    }
}

public enum LayoutMode: String, Codable, CaseIterable, Sendable {
    case manual
    case linked
    case bento

    /// Modes currently available in the product UI. Linked mode remains
    /// decodable so older configuration files and runtime tests stay valid.
    public static let availableModes: [LayoutMode] = [.manual, .bento]

    public var availableMode: LayoutMode {
        switch self {
        case .linked: .manual
        case .manual, .bento: self
        }
    }

    public var title: String {
        switch self {
        case .manual: "Native"
        case .linked: "Linked"
        case .bento: "Bento"
        }
    }
}

@MainActor
public protocol WindowSystem: AnyObject {
    func requestAccessibilityPermission(prompt: Bool) -> Bool
    func focusedWindow() throws -> WindowSnapshot?
    func visibleWindows() throws -> [WindowSnapshot]
    func displays() -> [DisplaySnapshot]
    /// - Parameter knownCurrentFrame: The caller's freshest reading of the
    ///   window's frame, when it has one. Implementations may use it to skip
    ///   redundant Accessibility writes; passing `nil` always performs the full
    ///   write sequence. See `FrameWritePlanner`.
    func setFrame(_ frame: BTRect, knownCurrentFrame: BTRect?, for windowID: WindowID) throws
    func setMinimized(_ minimized: Bool, for windowID: WindowID) throws
}

public extension WindowSystem {
    func setFrame(_ frame: BTRect, for windowID: WindowID) throws {
        try setFrame(frame, knownCurrentFrame: nil, for: windowID)
    }
}

@MainActor
public protocol TargetedWindowSystem: WindowSystem {
    func windowSnapshots(ids: Set<WindowID>) throws -> [WindowSnapshot]
}

public struct WindowSystemEvent: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case moved
        case resized
        case created
        case destroyed
        case minimized
        case restored
        case focused
    }

    public var kind: Kind
    public var windowID: WindowID?
    public var processIdentifier: Int32

    public init(kind: Kind, windowID: WindowID?, processIdentifier: Int32) {
        self.kind = kind
        self.windowID = windowID
        self.processIdentifier = processIdentifier
    }
}

/// Optional event capability implemented by real and deterministic fake window
/// systems. Keeping it separate preserves simple WindowSystem adapters.
@MainActor
public protocol WindowEventSource: AnyObject {
    func setWindowEventHandler(_ handler: (@MainActor (WindowSystemEvent) -> Void)?)
    func startWindowObservation()
    func stopWindowObservation()
}

public enum WindowSystemError: Error, LocalizedError, Equatable {
    case accessibilityPermissionRequired
    case windowNotFound(WindowID)
    case unsupportedWindow(WindowID)
    case operationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .accessibilityPermissionRequired: "Accessibility permission is required."
        case let .windowNotFound(id): "Window \(id) is no longer available."
        case let .unsupportedWindow(id): "Window \(id) cannot be moved or resized."
        case let .operationFailed(message): message
        }
    }
}
