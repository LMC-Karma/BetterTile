import AppKit
import ApplicationServices
import Foundation
import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

/// Compares, on the local Mac, the main-thread time of launch discovery with the
/// complete-inventory burst it replaced. Read-only: it reads windows through
/// Accessibility and the window server, and writes nothing. It reads Finder as a
/// stand-in for a launched regular application. Opt in with
/// `BETTERTILE_LAUNCH_DISCOVERY_BENCH=1`; it needs Accessibility permission.
@Test(.macOSTestApplication, .enabled(if: ProcessInfo.processInfo.environment["BETTERTILE_LAUNCH_DISCOVERY_BENCH"] != nil
               && ProcessInfo.processInfo.environment["CI"] == nil,
               "Requires an explicit local benchmark run with Accessibility permission."))
@MainActor func launchDiscoveryCostBenchmark() throws {
    _ = NSApplication.shared
    try #require(AXIsProcessTrusted(), "The benchmark reads windows through Accessibility")
    let target = try #require(NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.finder" })
    let system = AccessibilityWindowSystem()
    defer { system.stopWindowObservation() }

    func milliseconds(_ runs: Int, _ body: () throws -> Void) rethrows -> [Double] {
        try (0..<runs).map { _ in
            let start = DispatchTime.now().uptimeNanoseconds
            try body()
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        }
    }
    func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

    // Warm both paths once, as the running app has before a launch.
    let warm = try system.visibleWindows()
    _ = system.readLaunchedApplication(processIdentifier: target.processIdentifier)
    let sweeps = try milliseconds(41) { _ = try system.visibleWindows() }
    var lastRead: LaunchedApplicationRead = .notReady
    let reads = milliseconds(41) { lastRead = system.readLaunchedApplication(processIdentifier: target.processIdentifier) }

    let sweep = median(sweeps), read = median(reads)
    // 424c072b: complete inventories 8 ms apart for 0.5 s (reconciliation excluded).
    let burstCount = Int((500 / (8 + sweep)).rounded(.up))
    let discoveryCount = LaunchDiscoverySchedule.delays.count
    let result: [String: Any] = [
        "applications_running": NSWorkspace.shared.runningApplications.count,
        "windows_in_inventory": warm.count,
        "complete_inventory_ms_median": sweep,
        "complete_inventory_ms_p90": sweeps.sorted()[Int(Double(sweeps.count) * 0.9)],
        "launched_read_ms_median": read,
        "launched_read_ms_p90": reads.sorted()[Int(Double(reads.count) * 0.9)],
        "launched_read_result": { switch lastRead { case let .windows(w): "windows(\(w.count))"; case .notReady: "notReady"; case .unavailable: "unavailable"; case .needsCompleteInventory: "needsCompleteInventory" } }(),
        "old_burst_inventories": burstCount,
        "old_burst_main_thread_ms": Double(burstCount) * sweep,
        "discovery_reads": discoveryCount,
        "discovery_main_thread_ms": Double(discoveryCount) * read,
        "discovery_bound_s": Double(LaunchDiscoverySchedule.bound.components.seconds),
    ]
    let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
    print("LAUNCH_DISCOVERY_COST " + String(decoding: data, as: UTF8.self))
}
