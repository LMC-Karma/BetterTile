import AppKit
import Foundation
import Testing
@testable import BetterTileApp
@testable import BetterTileCore

/// A Dock that moves to a side narrows the work area while it settles, so
/// Tabbed can ask for a width that is still too wide for the screen. AppKit
/// keeps a window that is too wide for its screen rather than apply another
/// width that is still too wide. That kept width is no application minimum,
/// and the work area that settles during that placement is not another
/// desktop: Tabbed must fit the windows to it.
@Test @MainActor func tabbedFitsAWorkAreaThatSettlesDuringAPlacement() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    system.measuresOnWrite = true
    system.windows.append(WindowSnapshot(
        id: WindowID(rawValue: "peer"), processIdentifier: 43,
        frame: BTRect(x: 500, y: 0, width: 500, height: 800), displayID: system.mainDisplay.id
    ))
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = .single
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 2 })
    try await Task.sleep(for: .milliseconds(300))
    try #require(system.windows.allSatisfy { $0.frame.size.width == 1000 })

    // The Dock is still moving: macOS reports 920 points, the screen settles
    // at 918 while the placement for 920 is still running.
    system.appKitWidthLimit = 918
    for window in system.windows { system.frameApplicationDelays[window.id] = .milliseconds(300) }
    system.availableDisplays[0].visibleFrame.size.width = 920
    model.watchdog()
    try await Task.sleep(for: .milliseconds(50))
    try #require(model.hasPendingTabbedPlacement)
    system.availableDisplays[0].visibleFrame.size.width = 918
    model.watchdog()

    let selected = try #require(model.activeTabbedState?.panes.first?.selected)
    #expect(await waitFor {
        system.windows.first { $0.id == selected }.map { $0.frame.maxX <= 918 } == true
    }, "\(system.windows.map { ($0.id, $0.frame, $0.constraints.minimumSize) })")
}

/// The width AppKit kept for a window too wide for its screen is no minimum.
/// Learned as one, it would make every later pane too small for the window.
@Test @MainActor func aWidthAppKitKeptIsNoTabbedMinimum() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    system.measuresOnWrite = true
    system.windows.append(WindowSnapshot(
        id: WindowID(rawValue: "peer"), processIdentifier: 43,
        frame: BTRect(x: 500, y: 0, width: 500, height: 800), displayID: system.mainDisplay.id
    ))
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultTabbedPreset = .single
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 2 })
    try await Task.sleep(for: .milliseconds(300))

    system.appKitWidthLimit = 918
    system.availableDisplays[0].visibleFrame.size.width = 920
    model.watchdog()
    try #require(await waitFor { !model.hasPendingTabbedPlacement })
    // A later read sees the kept width after the confirmation delay.
    try await Task.sleep(for: .milliseconds(400))
    _ = try system.visibleWindows()
    #expect(system.windows.allSatisfy { $0.constraints.minimumSize.width < 918 },
            "\(system.windows.map { ($0.id, $0.constraints.minimumSize) })")

    system.availableDisplays[0].visibleFrame.size.width = 918
    model.watchdog()
    let selected = try #require(model.activeTabbedState?.panes.first?.selected)
    #expect(await waitFor {
        system.windows.first { $0.id == selected }.map { $0.frame.maxX <= 918 } == true
    }, "\(system.windows.map { ($0.id, $0.frame, $0.constraints.minimumSize) })")
}
