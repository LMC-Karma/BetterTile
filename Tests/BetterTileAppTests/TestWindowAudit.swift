import AppKit
import BetterTileTestSupport
import Testing

/// Samples only windows owned by this test process. Enable JSON evidence with
/// BETTERTILE_TEST_WINDOW_AUDIT; it never requests a global window inventory.
@MainActor enum TestWindowAudit {
    private static var timer: Timer?
    private static var records: [Int: [String: Any]] = [:]
    private static var reported: Set<ObjectIdentifier> = []

    static func start(displayFrames: @escaping @MainActor () -> [NSRect] = { NSScreen.screens.map(\.frame) }) {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated { sample(displays: displayFrames()) }
        }
    }

    static func sample(displays suppliedDisplays: [NSRect]? = nil,
                       enforceOffscreen: Bool = !OffscreenTestWindows.localWindowTestsEnabled,
                       reporter: HelperFailureReporter = .issue) {
        guard let app = NSApp else { return }
        let actualDisplays = NSScreen.screens.map(\.frame)
        if enforceOffscreen {
            for violation in displayViolations(on: suppliedDisplays ?? actualDisplays)
            where reported.insert(ObjectIdentifier(violation.window)).inserted {
                reporter.record(Comment(rawValue: violation.message), sourceLocation: #_sourceLocation)
            }
        }
        guard let path = ProcessInfo.processInfo.environment["BETTERTILE_TEST_WINDOW_AUDIT"] else { return }
        var changed = false
        for window in app.windows {
            let number = window.windowNumber
            guard number > 0 else { continue }
            let intersects = window.isVisible && !window.frame.isEmpty && actualDisplays.contains { $0.intersects(window.frame) }
            let previous = records[number]
            if previous == nil || (intersects && previous?["intersectedDisplay"] as? Bool != true) {
                records[number] = ["number": number, "class": NSStringFromClass(type(of: window)),
                    "frame": NSStringFromRect(window.frame), "level": window.level.rawValue,
                    "width": window.frame.width, "height": window.frame.height,
                    "intersectedDisplay": intersects || previous?["intersectedDisplay"] as? Bool == true]
                changed = true
            }
        }
        if changed, let data = try? JSONSerialization.data(withJSONObject: [
            "pid": getpid(), "displays": actualDisplays.map(NSStringFromRect),
            "windows": Array(records.values)
        ], options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(filePath: path), options: .atomic)
        }
    }

    /// The visible windows of this process that intersect `displays`, each with the failure `sample` reports for it.
    /// This reads state only: it does not record an Issue or mark a window as reported.
    static func displayViolations(on displays: [NSRect]) -> [(window: NSWindow, message: String)] {
        guard let app = NSApp else { return [] }
        return app.windows.filter(\.isVisible).compactMap { window in
            guard !window.frame.isEmpty, displays.contains(where: { $0.intersects(window.frame) }) else { return nil }
            return (window, "Visible test window \(type(of: window)) intersects a display: \(window.frame)")
        }
    }
}
