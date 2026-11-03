import AppKit
import BetterTileCore
@testable import BetterTileMacOS
import Foundation
import Testing
@testable import BetterTileApp

/// Operation counts per window event, measured with the fake window system.
/// Each count stands for one live Accessibility or WindowServer read.
@MainActor
private struct OperationCounter {
    let system: FakeAppWindowSystem
    var displays = 0
    var windowNumbers = 0
    private var start: (sweeps: Int, focused: Int, refreshes: Int, observations: Int, writes: Int)

    init(system: FakeAppWindowSystem) {
        self.system = system
        start = (system.completeSweepCount, system.focusedWindowReadCount, system.cachedRefreshCount,
                 system.nativeDesktopRefreshCount, system.frameWriteCounts.values.reduce(0, +))
    }

    func report(_ label: String, events: Int, displays: Int, windowNumbers: Int) -> String {
        let n = Double(events)
        func f(_ value: Int) -> String { String(format: "%.1f", Double(value) / n) }
        return "PERF \(label): per event sweeps=\(f(system.completeSweepCount - start.sweeps))"
            + " focusedReads=\(f(system.focusedWindowReadCount - start.focused))"
            + " cachedRefreshes=\(f(system.cachedRefreshCount - start.refreshes))"
            + " observationRefreshes=\(f(system.nativeDesktopRefreshCount - start.observations))"
            + " displayReads=\(f(displays)) windowNumberReads=\(f(windowNumbers))"
            + " frameWrites=\(f(system.frameWriteCounts.values.reduce(0, +) - start.writes))"
    }
}

@MainActor private func addWindows(_ count: Int, to system: FakeAppWindowSystem, pidBase: Int32) -> [WindowID] {
    (0..<count).map { index in
        let id = WindowID(rawValue: "w\(pidBase)-\(index)")
        system.windows.append(WindowSnapshot(
            id: id, processIdentifier: pidBase + Int32(index), bundleIdentifier: "com.apple.finder", title: "W\(index)",
            frame: BTRect(x: Double(index) * 40, y: 0, width: 400, height: 400), displayID: system.mainDisplay.id
        ))
        return id
    }
}

extension Tag {
    @Tag static var performanceProbe: Self
}

/// Exploratory probes use wall time and may inspect running applications and their icons.
/// Opt in locally with BT_PERF_PROBES=1 swift test --filter PerformanceProbeTests.
@Suite(.appTestApplication, .tags(.performanceProbe),
       .enabled(if: ProcessInfo.processInfo.environment["BT_PERF_PROBES"] == "1",
                "Set BT_PERF_PROBES=1 to run exploratory performance probes."))
@MainActor
struct PerformanceProbeTests {
    @Test @MainActor func probeTabbedFocusEventCost() async throws {
        _ = NSApplication.shared
        let system = FakeAppWindowSystem()
        let ids = addWindows(2, to: system, pidBase: 910_000)
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.configuration.defaultTabbedPreset = .columns
        model.setActiveMode(.tabbed)
        try #require(await waitFor { model.activeTabbedState?.windowIDs.count == system.windows.count })
        try await Task.sleep(for: .milliseconds(800)) // real-time: opt-in probe counts operations over a wall-clock observation interval

        var displays = 0, numbers = 0
        system.onDisplays = { displays += 1 }
        system.onWindowNumbers = { numbers += 1 }
        let counter = OperationCounter(system: system)
        let events = 20
        for index in 0..<events {
            let id = ids[index % ids.count]
            system.focusedID = id
            system.eventHandler?(WindowSystemEvent(kind: .focused, windowID: id, processIdentifier: system.windows.first { $0.id == id }!.processIdentifier))
            try await Task.sleep(for: .milliseconds(150)) // real-time: opt-in probe counts operations over a wall-clock observation interval
        }
        try await Task.sleep(for: .milliseconds(600)) // real-time: opt-in probe counts operations over a wall-clock observation interval
        print(counter.report("tabbed focus", events: events, displays: displays, windowNumbers: numbers))
    }

    @Test @MainActor func probeBentoArrivalCost() async throws {
        _ = NSApplication.shared
        let system = FakeAppWindowSystem()
        _ = addWindows(2, to: system, pidBase: 920_000)
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.setActiveMode(.bento)
        try await Task.sleep(for: .milliseconds(800)) // real-time: opt-in probe counts operations over a wall-clock observation interval

        var displays = 0, numbers = 0
        system.onDisplays = { displays += 1 }
        system.onWindowNumbers = { numbers += 1 }
        let counter = OperationCounter(system: system)
        let events = 4
        for index in 0..<events {
            let id = addWindows(1, to: system, pidBase: 921_000 + Int32(index * 10))[0]
            system.eventHandler?(WindowSystemEvent(kind: .created, windowID: id, processIdentifier: system.windows.last!.processIdentifier))
            try await Task.sleep(for: .milliseconds(1_200)) // real-time: opt-in probe counts operations over a wall-clock observation interval
        }
        print(counter.report("bento arrival", events: events, displays: displays, windowNumbers: numbers))
    }

    @Test @MainActor func probeTabbedIdleCost() async throws {
        _ = NSApplication.shared
        let system = FakeAppWindowSystem()
        _ = addWindows(2, to: system, pidBase: 930_000)
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.setActiveMode(.tabbed)
        try #require(await waitFor { model.activeTabbedState?.windowIDs.count == system.windows.count })
        try await Task.sleep(for: .milliseconds(1_500)) // real-time: opt-in probe counts operations over a wall-clock observation interval
        var displays = 0, numbers = 0
        system.onDisplays = { displays += 1 }
        system.onWindowNumbers = { numbers += 1 }
        let counter = OperationCounter(system: system)
        try await Task.sleep(for: .seconds(3)) // real-time: opt-in probe counts operations over a wall-clock observation interval
        print(counter.report("tabbed idle 3s", events: 1, displays: displays, windowNumbers: numbers))
    }


    /// The focused-window read looks up each candidate application. Before:
    /// one `runningApplications` copy per candidate. After: one copy per read.
    /// Read-only; nothing on the desktop changes.
    @Test @MainActor func benchmarkRunningApplicationLookup() {
        let candidates = Array(NSWorkspace.shared.runningApplications.suffix(13).map(\.processIdentifier).reversed())
        func median(_ body: () -> Void) -> Double {
            var samples: [Double] = []
            for _ in 0..<41 {
                let start = DispatchTime.now().uptimeNanoseconds // real-time: opt-in benchmark measures the execution cost of AppKit calls
                body()
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000) // real-time: opt-in benchmark measures the execution cost of AppKit calls
            }
            return samples.sorted()[samples.count / 2]
        }
        var found = 0
        for count in [1, 4, 13] {
            let pids = Array(candidates.prefix(count))
            let before = median {
                for pid in pids { if NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid }) != nil { found += 1 } }
            }
            let after = median {
                let running = NSWorkspace.shared.runningApplications
                for pid in pids { if running.first(where: { $0.processIdentifier == pid }) != nil { found += 1 } }
            }
            let direct = median {
                for pid in pids { if NSRunningApplication(processIdentifier: pid) != nil { found += 1 } }
            }
            print(String(format: "PERF runningApplications lookup, %d candidates (%d apps): scan-per-candidate %.1f µs, hoisted %.1f µs, by-pid %.1f µs (median of 41)",
                         count, NSWorkspace.shared.runningApplications.count, before, after, direct))
        }
        #expect(found > 0)
    }

    /// Settings rows read an application icon in `body`. Read-only.
    @Test @MainActor func benchmarkApplicationIconRead() {
        let urls = NSWorkspace.shared.runningApplications.compactMap(\.bundleURL).prefix(30)
        var samples: [Double] = []
        for _ in 0..<21 {
            let start = DispatchTime.now().uptimeNanoseconds // real-time: opt-in benchmark measures the execution cost of AppKit calls
            for url in urls { _ = NSWorkspace.shared.icon(forFile: url.path) }
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000) // real-time: opt-in benchmark measures the execution cost of AppKit calls
        }
        print(String(format: "PERF icon(forFile:) for %d apps: median %.1f µs per pass (%.1f µs per icon)",
                     urls.count, samples.sorted()[10], samples.sorted()[10] / Double(max(urls.count, 1))))
    }
}
