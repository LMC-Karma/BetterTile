import AppKit
import Foundation
import Testing
@testable import BetterTileApp
@testable import BetterTileCore

/// The Setup Assistant's starting mode becomes the default and switches
/// every current desktop that still uses the old default.
@Test(.appTestApplication) @MainActor
func startingModeSwitchesEveryDesktopOnTheOldDefault() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let second = DisplaySnapshot(id: DisplayID(rawValue: "second"), frame: BTRect(x: 1000, y: 0, width: 1200, height: 800),
                                 visibleFrame: BTRect(x: 1000, y: 0, width: 1200, height: 800), isMain: false)
    system.availableDisplays = [system.mainDisplay, second]
    system.windows.append(WindowSnapshot(
        id: WindowID(rawValue: "peer"), processIdentifier: 43,
        frame: BTRect(x: 100, y: 100, width: 500, height: 400), displayID: system.mainDisplay.id))
    system.windows.append(WindowSnapshot(
        id: WindowID(rawValue: "far"), processIdentifier: 44,
        frame: BTRect(x: 1100, y: 100, width: 500, height: 400), displayID: second.id))
    let model = makeModel(system: system)
    defer { model.shutdown() }
    #expect(model.configuration.defaultLayoutMode == .manual)

    model.applyStartingMode(.bento)

    #expect(model.configuration.defaultLayoutMode == .bento)
    #expect(model.activeMode(for: system.mainDisplay.id) == .bento)
    #expect(model.activeMode(for: second.id) == .bento)
    // Adaptive arranges the two main-display windows side by side.
    let arranged = await waitFor {
        let frames = system.windows.filter { $0.displayID == system.mainDisplay.id }.map(\.frame)
        return frames.count == 2 && frames[0].intersection(frames[1]) == nil
            && frames.allSatisfy { PlacementBounds.isContained($0, in: system.mainDisplay.visibleFrame) }
    }
    #expect(arranged, "\(system.windows.map { ($0.id, $0.frame) })")
}

/// A desktop the user already moved to another mode keeps that mode.
@Test(.appTestApplication) @MainActor
func startingModeKeepsADesktopTheUserAlreadyChanged() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeMode(for: system.mainDisplay.id) == .tabbed })

    model.applyStartingMode(.bento)

    #expect(model.configuration.defaultLayoutMode == .bento)
    #expect(model.activeMode(for: system.mainDisplay.id) == .tabbed)
}

/// Keeping the current default changes nothing and moves no window.
@Test(.appTestApplication) @MainActor
func startingModeMatchingTheDefaultMovesNothing() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let before = system.windows.map(\.frame)
    let model = makeModel(system: system)
    defer { model.shutdown() }

    model.applyStartingMode(.manual)

    #expect(model.configuration.defaultLayoutMode == .manual)
    #expect(model.activeMode(for: system.mainDisplay.id) ?? .manual == .manual)
    #expect(system.windows.map(\.frame) == before)
}
