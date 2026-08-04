import AppKit
import BetterTileCore
import Foundation

/// Supplies native-style maximize/restore when macOS's own title-bar
/// double-click action is set to Do Nothing. A passive event monitor cannot
/// safely override another macOS-selected action such as Minimize.
@MainActor
public final class TitleBarDoubleClickController {
    public var isEnabled: Bool {
        didSet { syncMonitoring() }
    }

    private let coordinator: WindowCoordinator
    private var monitor: Any?
    private var lastEventNumber: Int?
    private var isStarted = false

    /// Consulted so a double click never places a window the user has asked
    /// BetterTile to leave alone.
    public var applicationRules = ApplicationRuleSet()

    public init(coordinator: WindowCoordinator, isEnabled: Bool = true) {
        self.coordinator = coordinator
        self.isEnabled = isEnabled
    }

    public func start() {
        isStarted = true
        syncMonitoring()
    }

    public func refreshSystemPolicy() {
        syncMonitoring()
    }

    public func stop() {
        isStarted = false
        removeMonitor()
    }

    func allowsDoubleClickPlacement(for window: WindowSnapshot) -> Bool {
        isEnabled
            && window.processIdentifier != ProcessInfo.processInfo.processIdentifier
            && window.isEligible
            && window.constraints.isResizable
            && applicationRules.rule(for: window.bundleIdentifier).allowsDirectPlacement
    }

    private func syncMonitoring() {
        if isStarted, isEnabled, Self.macOSDoubleClickActionIsDisabled {
            installMonitor()
        } else {
            removeMonitor()
        }
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        lastEventNumber = nil
    }

    private func handle(_ event: NSEvent) {
        guard event.clickCount == 2,
              event.eventNumber != lastEventNumber,
              Self.macOSDoubleClickActionIsDisabled,
              let mainFrame = NSScreen.main?.frame,
              let window = try? coordinator.system.focusedWindow(),
              allowsDoubleClickPlacement(for: window)
        else { return }

        let point = CoordinateConverter.pointToTopLeft(NSEvent.mouseLocation, mainScreenFrame: mainFrame)
        let titleBarDepth = min(56, window.frame.size.height * 0.2)
        guard window.frame.contains(point), point.y <= window.frame.minY + titleBarDepth else { return }
        lastEventNumber = event.eventNumber

        guard let display = coordinator.system.displays().first(where: { $0.id == window.displayID }) else { return }
        if window.frame.approximatelyEquals(display.visibleFrame, tolerance: 2) {
            _ = coordinator.perform(.restore)
        } else {
            _ = coordinator.perform(.maximize)
        }
    }

    private static var macOSDoubleClickActionIsDisabled: Bool {
        UserDefaults(suiteName: ".GlobalPreferences")?.string(forKey: "AppleActionOnDoubleClick") == "None"
    }
}
