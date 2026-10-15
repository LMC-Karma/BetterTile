import AppKit
import Foundation
import Testing
@testable import BetterTileApp
@testable import BetterTileCore

/// Leave space for Dock changes the work area, so Bento tiles into the
/// smaller area at once and gets the space back when it is turned off.
@Test @MainActor func leaveSpaceForDockRetilesBentoBothWays() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    system.windows[0].frame = BTRect(x: 0, y: 0, width: 500, height: 800)
    system.windows.append(WindowSnapshot(
        id: WindowID(rawValue: "peer"), processIdentifier: 43,
        frame: BTRect(x: 500, y: 0, width: 500, height: 800), displayID: system.mainDisplay.id
    ))
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    // Bento adopts the two panes as they are.
    try await Task.sleep(for: .milliseconds(300))

    model.updateConfiguration { $0.leavesSpaceForDock = true }
    #expect(system.leavesSpaceForDock)
    #expect(await waitFor { system.windows.allSatisfy { $0.frame.maxY == 720 } }, "\(system.windows.map(\.frame))")

    // Turn it off at human speed, once the work-area settlement stops sampling.
    var samples = -1
    for _ in 0..<20 where samples != system.cachedRefreshCount {
        samples = system.cachedRefreshCount
        try await Task.sleep(for: .milliseconds(150))
    }
    model.updateConfiguration { $0.leavesSpaceForDock = false }
    #expect(await waitFor { system.windows.allSatisfy { $0.frame.maxY == 800 } }, "\(system.windows.map(\.frame))")
}
