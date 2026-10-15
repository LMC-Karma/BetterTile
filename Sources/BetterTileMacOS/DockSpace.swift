import AppKit
@preconcurrency import ApplicationServices
import BetterTileCore

public enum DockEdge: String, Hashable, Sendable {
    case left
    case right
    case bottom
}

/// The strip of one display that a shown Dock covers.
public struct DockFootprint: Hashable, Sendable {
    /// Measured on macOS 26 at several icon sizes: a Dock that never hides
    /// reserves the thickness of its Accessibility list plus 6 points. The
    /// list is rounded to whole points, so a side Dock can differ by one.
    static let listMargin = 6.0

    public var displayID: DisplayID
    public var edge: DockEdge
    public var thickness: Double

    public init(displayID: DisplayID, edge: DockEdge, thickness: Double) {
        self.displayID = displayID
        self.edge = edge
        self.thickness = max(0, thickness)
    }

    /// The footprint of the Dock list at `frame`, shown or hidden. A hidden
    /// Dock keeps its list size and moves the list just past the display edge.
    public init?(dockList frame: BTRect, edge: DockEdge, displays: [(id: DisplayID, frame: BTRect)]) {
        guard frame.size.width >= 16, frame.size.height >= 16 else { return nil }
        func distance(to display: BTRect) -> Double? {
            switch edge {
            case .bottom:
                (display.minX...display.maxX).contains(frame.midX) ? abs(frame.midY - display.maxY) : nil
            case .left:
                (display.minY...display.maxY).contains(frame.midY) ? abs(frame.midX - display.minX) : nil
            case .right:
                (display.minY...display.maxY).contains(frame.midY) ? abs(frame.midX - display.maxX) : nil
            }
        }
        let nearest = displays
            .compactMap { display in distance(to: display.frame).map { (display.id, $0) } }
            .min { $0.1 < $1.1 }
        guard let nearest else { return nil }
        let listThickness = edge == .bottom ? frame.size.height : frame.size.width
        self.init(displayID: nearest.0, edge: edge, thickness: listThickness + Self.listMargin)
    }

    /// The display's work area with this strip kept free. AppKit already
    /// leaves out a Dock that never hides, so the strip is never taken twice.
    public func workArea(fullFrame: BTRect, appKitVisibleFrame: BTRect) -> BTRect {
        switch edge {
        case .left:
            let minX = max(appKitVisibleFrame.minX, fullFrame.minX + thickness)
            return BTRect(x: minX, y: appKitVisibleFrame.minY, width: max(0, appKitVisibleFrame.maxX - minX), height: appKitVisibleFrame.size.height)
        case .right:
            let maxX = min(appKitVisibleFrame.maxX, fullFrame.maxX - thickness)
            return BTRect(x: appKitVisibleFrame.minX, y: appKitVisibleFrame.minY, width: max(0, maxX - appKitVisibleFrame.minX), height: appKitVisibleFrame.size.height)
        case .bottom:
            let maxY = min(appKitVisibleFrame.maxY, fullFrame.maxY - thickness)
            return BTRect(x: appKitVisibleFrame.minX, y: appKitVisibleFrame.minY, width: appKitVisibleFrame.size.width, height: max(0, maxY - appKitVisibleFrame.minY))
        }
    }
}

/// Reads the Dock's footprint through Accessibility, at most once a second.
/// Keeps the last reading while the Dock restarts and reports no list.
///
/// A Dock not shown since it started, as after login, reports an empty list.
/// Until it is shown, the thickness last measured on its edge, kept across
/// launches, stands in on the main display.
@MainActor
final class DockSpaceReader {
    private let defaults: UserDefaults
    private let readPreferences: @MainActor () -> (edge: DockEdge, autohides: Bool)
    private let readList: @MainActor () -> BTRect?
    private var footprint: DockFootprint?
    private var autohides = true
    private var lastRead = -Double.infinity
    private var lastWhileHidden: Bool?

    init(
        defaults: UserDefaults = .standard,
        readPreferences: @escaping @MainActor () -> (edge: DockEdge, autohides: Bool) = DockSpaceReader.readPreferences,
        readList: @escaping @MainActor () -> BTRect? = DockSpaceReader.dockListFrame
    ) {
        self.defaults = defaults
        self.readPreferences = readPreferences
        self.readList = readList
    }

    /// The strip to keep free, or nil. A Dock that hides gets one only when
    /// `whileHidden` is true. A Dock that never hides always gets one: macOS
    /// reserves the same strip, but AppKit can report it late on a secondary
    /// display after the Dock moves. `displays` lists the main display first.
    func footprint(
        displays: [(id: DisplayID, frame: BTRect)],
        whileHidden: Bool,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> DockFootprint? {
        if now - lastRead >= 1 || whileHidden != lastWhileHidden {
            lastRead = now
            lastWhileHidden = whileHidden
            read(displays: displays, whileHidden: whileHidden)
        }
        return whileHidden || !autohides ? footprint : nil
    }

    private func read(displays: [(id: DisplayID, frame: BTRect)], whileHidden: Bool) {
        let preferences = readPreferences()
        autohides = preferences.autohides
        // With nothing to keep free, a hiding Dock is not read at all.
        guard whileHidden || !autohides else { return }
        let edge = preferences.edge
        let key = "dockThickness.\(edge.rawValue)"
        if let list = readList(), let read = DockFootprint(dockList: list, edge: edge, displays: displays) {
            footprint = read
            if defaults.double(forKey: key) != read.thickness { defaults.set(read.thickness, forKey: key) }
        } else if footprint?.edge != edge {
            let remembered = defaults.double(forKey: key)
            footprint = remembered > 0
                ? displays.first.map { DockFootprint(displayID: $0.id, edge: edge, thickness: remembered) }
                : nil
        }
    }

    private static func readPreferences() -> (edge: DockEdge, autohides: Bool) {
        let dock = UserDefaults(suiteName: "com.apple.dock")
        let edge = dock?.string(forKey: "orientation").flatMap(DockEdge.init(rawValue:)) ?? .bottom
        return (edge, dock?.bool(forKey: "autohide") ?? false)
    }

    private static func dockListFrame() -> BTRect? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(dock.processIdentifier), kAXChildrenAttribute as CFString, &children
        ) == .success, let children = children as? [AXUIElement] else { return nil }
        for child in children {
            var role: CFTypeRef?
            var position: CFTypeRef?
            var size: CFTypeRef?
            guard AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role) == .success,
                  role as? String == kAXListRole,
                  AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &position) == .success,
                  AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &size) == .success,
                  let position, let size,
                  CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
            else { continue }
            var point = CGPoint.zero
            var extent = CGSize.zero
            guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
                  AXValueGetValue(size as! AXValue, .cgSize, &extent)
            else { continue }
            return BTRect(x: point.x, y: point.y, width: extent.width, height: extent.height)
        }
        return nil
    }
}
