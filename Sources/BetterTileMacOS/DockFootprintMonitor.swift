import AppKit
@preconcurrency import ApplicationServices
import BetterTileCore
import CoreGraphics
import os

public enum DockEdge: String, Hashable, Sendable {
    case left
    case right
    case bottom
}

public struct DockFootprint: Hashable, Sendable {
    public var edge: DockEdge
    public var thickness: Double

    public init(edge: DockEdge, thickness: Double) {
        self.edge = edge
        self.thickness = max(0, thickness)
    }

    func approximatelyEquals(_ other: DockFootprint, tolerance: Double = 2) -> Bool {
        edge == other.edge && abs(thickness - other.thickness) <= tolerance
    }
}

public struct DockFootprintStabilizer: Sendable {
    public private(set) var visible: [DisplayID: DockFootprint] = [:]

    private var pending: [DisplayID: (footprint: DockFootprint, firstSeen: TimeInterval)] = [:]
    private var missingSince: [DisplayID: TimeInterval] = [:]

    public init() {}

    public mutating func sample(_ detected: [DisplayID: DockFootprint], timestamp: TimeInterval) {
        let ids = Set(visible.keys).union(detected.keys).union(pending.keys)
        for id in ids {
            if let footprint = detected[id] {
                missingSince.removeValue(forKey: id)
                if let candidate = pending[id], candidate.footprint.approximatelyEquals(footprint) {
                    if timestamp - candidate.firstSeen >= 0.1 {
                        visible[id] = footprint
                    }
                } else {
                    pending[id] = (footprint, timestamp)
                }
            } else {
                pending.removeValue(forKey: id)
                guard visible[id] != nil else { continue }
                if let since = missingSince[id] {
                    if timestamp - since >= 0.5 {
                        visible.removeValue(forKey: id)
                        missingSince.removeValue(forKey: id)
                    }
                } else {
                    missingSince[id] = timestamp
                }
            }
        }
    }

    public func effectiveFrame(
        displayID: DisplayID,
        fullFrame: BTRect,
        appKitVisibleFrame: BTRect
    ) -> BTRect {
        let footprint = visible[displayID]
        guard let footprint else { return appKitVisibleFrame }
        switch footprint.edge {
        case .left:
            let minX = max(appKitVisibleFrame.minX, fullFrame.minX + footprint.thickness)
            return BTRect(x: minX, y: appKitVisibleFrame.minY, width: max(0, appKitVisibleFrame.maxX - minX), height: appKitVisibleFrame.size.height)
        case .right:
            let maxX = min(appKitVisibleFrame.maxX, fullFrame.maxX - footprint.thickness)
            return BTRect(x: appKitVisibleFrame.minX, y: appKitVisibleFrame.minY, width: max(0, maxX - appKitVisibleFrame.minX), height: appKitVisibleFrame.size.height)
        case .bottom:
            let maxY = min(appKitVisibleFrame.maxY, fullFrame.maxY - footprint.thickness)
            return BTRect(x: appKitVisibleFrame.minX, y: appKitVisibleFrame.minY, width: appKitVisibleFrame.size.width, height: max(0, maxY - appKitVisibleFrame.minY))
        }
    }
}

public struct DockSamplingLease: Sendable {
    public private(set) var isActive = false

    private var minimumEnd = 0.0
    private var deadline = 0.0
    private var stableSamples = 0

    public init() {}

    public mutating func trigger(at timestamp: TimeInterval) {
        if !isActive {
            deadline = timestamp + 2
        }
        isActive = true
        stableSamples = 0
        minimumEnd = min(deadline, max(minimumEnd, timestamp + 0.7))
    }

    public mutating func recordSample(changed: Bool, at timestamp: TimeInterval) {
        guard isActive else { return }
        if timestamp >= deadline {
            isActive = false
            return
        }
        if changed {
            stableSamples = 0
            minimumEnd = max(minimumEnd, min(deadline, timestamp + 0.3))
        } else {
            stableSamples += 1
        }
        if timestamp >= minimumEnd, stableSamples >= 3 {
            isActive = false
        }
    }
}

private final class DockPointerGate: @unchecked Sendable {
    private let lock = NSLock()
    private var regions: [CGRect] = []
    private var wasNearDock = false

    func update(regions: [CGRect]) {
        lock.lock()
        self.regions = regions
        lock.unlock()
    }

    func shouldTrigger(at point: CGPoint) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let isNearDock = regions.contains { $0.contains(point) }
        guard isNearDock != wasNearDock else { return false }
        wasNearDock = isNearDock
        return true
    }
}

@MainActor
public final class DockFootprintMonitor {
    private static let signposter = OSSignposter(
        subsystem: "com.lmckarma.BetterTile",
        category: "DockFootprint"
    )

    private var stabilizer = DockFootprintStabilizer()
    private var lastAccessibilityFootprints: [DisplayID: DockFootprint] = [:]
    private var lastAXSample = Date.distantPast
    private var samplingLease = DockSamplingLease()
    private var burstTimer: Timer?
    private var recoveryTimer: Timer?
    private var pointerMonitor: Any?
    private var onChange: (() -> Void)?
    private let pointerGate = DockPointerGate()

    public init() {}

    public func start(onChange: @escaping () -> Void) {
        guard recoveryTimer == nil else {
            self.onChange = onChange
            return
        }
        self.onChange = onChange
        updatePointerRegions()
        pointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) {
            [weak self, pointerGate] event in
            guard pointerGate.shouldTrigger(at: event.locationInWindow) else { return }
            Task { @MainActor in self?.triggerTransitionCheck() }
        }
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runRecoverySample() }
        }
        timer.tolerance = 2.5
        RunLoop.main.add(timer, forMode: .common)
        recoveryTimer = timer
        triggerTransitionCheck()
    }

    public func triggerTransitionCheck() {
        updatePointerRegions()
        samplingLease.trigger(at: ProcessInfo.processInfo.systemUptime)
        if burstTimer == nil {
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.runBurstSample() }
            }
            timer.tolerance = 0.02
            RunLoop.main.add(timer, forMode: .common)
            burstTimer = timer
        }
        runBurstSample()
    }

    public func stop() {
        burstTimer?.invalidate()
        burstTimer = nil
        recoveryTimer?.invalidate()
        recoveryTimer = nil
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
        pointerMonitor = nil
        onChange = nil
        samplingLease = DockSamplingLease()
    }

    /// Returns true only when the effective work area changed after
    /// stabilization, not for every frame of the Dock animation.
    private func sample() -> Bool {
        let interval = Self.signposter.beginInterval("sample")
        defer { Self.signposter.endInterval("sample", interval) }
        let screens = screenGeometry()
        let before = effectiveSignature(screens)
        let dockPID = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.dock" })?.processIdentifier
        if Date().timeIntervalSince(lastAXSample) >= 0.5, let dockPID {
            lastAccessibilityFootprints = accessibilityFootprints(dockPID: dockPID, screens: screens)
            lastAXSample = Date()
        }
        var detected = dockPID.map { visibleFootprints(dockPID: $0, screens: screens) } ?? [:]
        detected.merge(lastAccessibilityFootprints) { graphics, _ in graphics }
        stabilizer.sample(
            detected,
            timestamp: ProcessInfo.processInfo.systemUptime
        )
        return before != effectiveSignature(screens)
    }

    public func effectiveFrame(displayID: DisplayID, fullFrame: BTRect, appKitVisibleFrame: BTRect) -> BTRect {
        stabilizer.effectiveFrame(
            displayID: displayID,
            fullFrame: fullFrame,
            appKitVisibleFrame: appKitVisibleFrame
        )
    }

    private func screenGeometry() -> [DisplayID: (full: BTRect, visible: BTRect)] {
        let screens = NSScreen.screens
        guard let mainFrame = screens.first?.frame else { return [:] }
        return Dictionary(uniqueKeysWithValues: screens.map { screen in
            let id = displayID(for: screen)
            return (id, (
                CoordinateConverter.toTopLeft(screen.frame, mainScreenFrame: mainFrame),
                CoordinateConverter.toTopLeft(screen.visibleFrame, mainScreenFrame: mainFrame)
            ))
        })
    }

    private func effectiveSignature(_ screens: [DisplayID: (full: BTRect, visible: BTRect)]) -> String {
        screens.sorted { $0.key < $1.key }.map { id, frames in
            let frame = effectiveFrame(displayID: id, fullFrame: frames.full, appKitVisibleFrame: frames.visible)
            return "\(id.rawValue):\(frame.minX):\(frame.minY):\(frame.size.width):\(frame.size.height)"
        }.joined(separator: "|")
    }

    private func visibleFootprints(
        dockPID: pid_t,
        screens: [DisplayID: (full: BTRect, visible: BTRect)]
    ) -> [DisplayID: DockFootprint] {
        let interval = Self.signposter.beginInterval("windowServerScan")
        defer { Self.signposter.endInterval("windowServerScan", interval) }
        guard let items = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[CFString: Any]] else { return [:] }
        var result: [DisplayID: DockFootprint] = [:]
        for item in items {
            guard (item[kCGWindowOwnerPID] as? NSNumber)?.int32Value == dockPID,
                  ((item[kCGWindowAlpha] as? NSNumber)?.doubleValue ?? 1) > 0.01,
                  let frame = windowFrame(item),
                  let match = footprint(for: frame, screens: screens)
            else { continue }
            if result[match.0].map({ $0.thickness < match.1.thickness }) ?? true {
                result[match.0] = match.1
            }
        }
        return result
    }

    private func accessibilityFootprints(
        dockPID: pid_t,
        screens: [DisplayID: (full: BTRect, visible: BTRect)]
    ) -> [DisplayID: DockFootprint] {
        let interval = Self.signposter.beginInterval("accessibilityScan")
        defer { Self.signposter.endInterval("accessibilityScan", interval) }
        let application = AXUIElementCreateApplication(dockPID)
        var queue: [(AXUIElement, Int)] = [(application, 0)]
        var index = 0
        var result: [DisplayID: DockFootprint] = [:]
        while index < queue.count, index < 160 {
            let (element, depth) = queue[index]
            index += 1
            if let frame = axFrame(element), let match = footprint(for: frame, screens: screens),
               result[match.0].map({ $0.thickness < match.1.thickness }) ?? true {
                result[match.0] = match.1
            }
            guard depth < 4 else { continue }
            var rawChildren: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &rawChildren) == .success,
               let children = rawChildren as? [AXUIElement] {
                queue.append(contentsOf: children.map { ($0, depth + 1) })
            }
        }
        return result
    }

    private func footprint(
        for frame: BTRect,
        screens: [DisplayID: (full: BTRect, visible: BTRect)]
    ) -> (DisplayID, DockFootprint)? {
        guard frame.size.width >= 24, frame.size.height >= 24 else { return nil }
        let display = screens.max { lhs, rhs in
            (lhs.value.full.intersection(frame)?.area ?? 0) < (rhs.value.full.intersection(frame)?.area ?? 0)
        }
        guard let display, (display.value.full.intersection(frame)?.area ?? 0) > 0 else { return nil }
        let full = display.value.full
        let tolerance = 20.0
        let candidate: DockFootprint?
        if abs(frame.maxY - full.maxY) <= tolerance,
           frame.size.width >= 80,
           frame.size.width > frame.size.height {
            candidate = DockFootprint(edge: .bottom, thickness: full.maxY - frame.minY)
        } else if abs(frame.minX - full.minX) <= tolerance,
                  frame.size.height >= 80,
                  frame.size.height > frame.size.width {
            candidate = DockFootprint(edge: .left, thickness: frame.maxX - full.minX)
        } else if abs(frame.maxX - full.maxX) <= tolerance,
                  frame.size.height >= 80,
                  frame.size.height > frame.size.width {
            candidate = DockFootprint(edge: .right, thickness: full.maxX - frame.minX)
        } else {
            candidate = nil
        }
        guard let candidate, (18...240).contains(candidate.thickness), frame.area < full.area * 0.45 else { return nil }
        return (display.key, candidate)
    }

    private func windowFrame(_ item: [CFString: Any]) -> BTRect? {
        guard let bounds = item[kCGWindowBounds] as? [String: Any],
              let x = (bounds["X"] as? NSNumber)?.doubleValue,
              let y = (bounds["Y"] as? NSNumber)?.doubleValue,
              let width = (bounds["Width"] as? NSNumber)?.doubleValue,
              let height = (bounds["Height"] as? NSNumber)?.doubleValue
        else { return nil }
        return BTRect(x: x, y: y, width: width, height: height)
    }

    private func axFrame(_ element: AXUIElement) -> BTRect? {
        var rawPosition: CFTypeRef?
        var rawSize: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &rawPosition) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &rawSize) == .success,
              rawPosition != nil,
              rawSize != nil
        else { return nil }
        let positionValue = rawPosition as! AXValue
        let sizeValue = rawSize as! AXValue
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position), AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return BTRect(x: position.x, y: position.y, width: size.width, height: size.height)
    }

    private func displayID(for screen: NSScreen) -> DisplayID {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return DisplayID(rawValue: number?.stringValue ?? String(screen.hash))
    }

    private func runBurstSample() {
        guard samplingLease.isActive else {
            burstTimer?.invalidate()
            burstTimer = nil
            return
        }
        let changed = sample()
        if changed { onChange?() }
        samplingLease.recordSample(
            changed: changed,
            at: ProcessInfo.processInfo.systemUptime
        )
        if !samplingLease.isActive {
            burstTimer?.invalidate()
            burstTimer = nil
        }
    }

    private func runRecoverySample() {
        updatePointerRegions()
        guard sample() else { return }
        onChange?()
        triggerTransitionCheck()
    }

    private func updatePointerRegions() {
        let edge = UserDefaults(suiteName: "com.apple.dock")?
            .string(forKey: "orientation")
            .flatMap(DockEdge.init(rawValue:)) ?? .bottom
        let thickness = 10.0
        pointerGate.update(regions: NSScreen.screens.map { screen in
            switch edge {
            case .left:
                CGRect(
                    x: screen.frame.minX,
                    y: screen.frame.minY,
                    width: thickness,
                    height: screen.frame.height
                )
            case .right:
                CGRect(
                    x: screen.frame.maxX - thickness,
                    y: screen.frame.minY,
                    width: thickness,
                    height: screen.frame.height
                )
            case .bottom:
                CGRect(
                    x: screen.frame.minX,
                    y: screen.frame.minY,
                    width: screen.frame.width,
                    height: thickness
                )
            }
        })
    }
}
