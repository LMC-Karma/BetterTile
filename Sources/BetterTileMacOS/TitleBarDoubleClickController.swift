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
    private var lifecycleGeneration: UInt64 = 0
    var addGlobalMonitor: (NSEvent.EventTypeMask, @escaping (NSEvent) -> Void) -> Any? = {
        NSEvent.addGlobalMonitorForEvents(matching: $0, handler: $1)
    }
    var removeEventMonitor: (Any) -> Void = { NSEvent.removeMonitor($0) }
    var systemDoubleClickActionIsDisabled: () -> Bool = { macOSDoubleClickActionIsDisabled }
    var pointerLocation: () -> BTPoint? = {
        guard let frame = NSScreen.screens.first?.frame else { return nil }
        return CoordinateConverter.pointToTopLeft(NSEvent.mouseLocation, mainScreenFrame: frame)
    }

    /// Consulted so a double click never places a window the user has asked
    /// BetterTile to leave alone.
    public var applicationRules = ApplicationRuleSet()
    public var isTabbedMember: ((WindowID) -> Bool)?

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
            && isTabbedMember?(window.id) != true
            && window.isEligible
            && window.constraints.isResizable
            && applicationRules.rule(for: window.bundleIdentifier).allowsDirectPlacement
    }

    private func syncMonitoring() {
        if isStarted, isEnabled, systemDoubleClickActionIsDisabled() {
            installMonitor()
        } else {
            removeMonitor()
        }
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        let generation = lifecycleGeneration
        monitor = addGlobalMonitor(.leftMouseUp) { [weak self] event in
            Task { @MainActor in
                guard let self, self.isStarted, self.lifecycleGeneration == generation else { return }
                self.handle(event)
            }
        }
    }

    private func removeMonitor() {
        lifecycleGeneration &+= 1
        if let monitor { removeEventMonitor(monitor) }
        monitor = nil
        lastEventNumber = nil
    }

    private func handle(_ event: NSEvent) {
        guard event.clickCount == 2,
              event.eventNumber != lastEventNumber,
              systemDoubleClickActionIsDisabled(),
              let point = pointerLocation(),
              let window = try? coordinator.system.focusedWindow(),
              allowsDoubleClickPlacement(for: window)
        else { return }

        let titleBarDepth = min(56, window.frame.size.height * 0.2)
        guard window.frame.contains(point), point.y <= window.frame.minY + titleBarDepth else { return }
        lastEventNumber = event.eventNumber

        guard let display = coordinator.system.displays().first(where: { $0.id == window.displayID }) else { return }
        let action: WindowAction = window.frame.approximatelyEquals(display.visibleFrame, tolerance: 2)
            ? .restore
            : .maximize
        guard case let .ready(plan) = coordinator.plan(action) else { return }
        _ = coordinator.perform(plan)
    }

    private static var macOSDoubleClickActionIsDisabled: Bool {
        UserDefaults(suiteName: ".GlobalPreferences")?.string(forKey: "AppleActionOnDoubleClick") == "None"
    }
}
