import Foundation
import BetterTileCore
@testable import BetterTileMacOS
import Testing

private let mainID = DisplayID(rawValue: "main")
private let main = BTRect(x: 0, y: 0, width: 2560, height: 1440)

/// Frames measured on macOS 26 with 52-point icons. The same display reserves
/// 78 points when the Dock never hides, so the auto-hidden Dock must too,
/// whether it is shown or hidden at the moment of the read.
@Test func shownAndHiddenDockReserveWhatAPermanentDockReserves() throws {
    let shown = try #require(DockFootprint(
        dockList: BTRect(x: 671, y: 1358, width: 1218, height: 72), edge: .bottom, displays: [(mainID, main)]
    ))
    let hidden = try #require(DockFootprint(
        dockList: BTRect(x: 671, y: 1440, width: 1218, height: 72), edge: .bottom, displays: [(mainID, main)]
    ))
    #expect(shown == hidden)
    #expect(shown == DockFootprint(displayID: mainID, edge: .bottom, thickness: 78))

    let autoHideVisible = BTRect(x: 0, y: 30, width: 2560, height: 1410)
    let permanentDockVisible = BTRect(x: 0, y: 30, width: 2560, height: 1332)
    #expect(shown.workArea(fullFrame: main, appKitVisibleFrame: autoHideVisible) == permanentDockVisible)
    // With auto-hide off AppKit already leaves the Dock out; nothing more is taken.
    #expect(shown.workArea(fullFrame: main, appKitVisibleFrame: permanentDockVisible) == permanentDockVisible)
}

@Test func dockListBelongsToTheDisplayWhoseEdgeItSitsOn() {
    let rightID = DisplayID(rawValue: "right")
    let below = DisplayID(rawValue: "below")
    let displays: [(id: DisplayID, frame: BTRect)] = [
        (mainID, main),
        (rightID, BTRect(x: 2560, y: 0, width: 1920, height: 1080)),
        (below, BTRect(x: 0, y: 1440, width: 2560, height: 1440)),
    ]
    // Hidden just past the right display's bottom edge, which is not the
    // display it overlaps.
    #expect(DockFootprint(
        dockList: BTRect(x: 3000, y: 1080, width: 1000, height: 72), edge: .bottom, displays: displays
    )?.displayID == rightID)
    // Hidden at the seam between two stacked displays: the top display's
    // bottom edge, not the lower display it overlaps.
    #expect(DockFootprint(
        dockList: BTRect(x: 671, y: 1440, width: 1218, height: 72), edge: .bottom, displays: displays
    )?.displayID == mainID)
    #expect(DockFootprint(
        dockList: BTRect(x: 671, y: 2798, width: 1218, height: 72), edge: .bottom, displays: displays
    )?.displayID == below)
    #expect(DockFootprint(
        dockList: BTRect(x: 4480, y: 300, width: 72, height: 500), edge: .right, displays: displays
    ) == DockFootprint(displayID: rightID, edge: .right, thickness: 78))
    #expect(DockFootprint(
        dockList: BTRect(x: -72, y: 300, width: 72, height: 500), edge: .left, displays: displays
    ) == DockFootprint(displayID: mainID, edge: .left, thickness: 78))
}

/// A restarting Dock reports an empty list. That is no reading at all.
@Test func emptyDockListHasNoFootprint() {
    #expect(DockFootprint(dockList: BTRect(x: 0, y: 0, width: 0, height: 0), edge: .bottom, displays: [(mainID, main)]) == nil)
}

@Test func footprintsReserveBottomAndSideWorkAreas() {
    let full = BTRect(x: 0, y: 0, width: 1200, height: 800)
    let appKitVisible = BTRect(x: 0, y: 24, width: 1200, height: 776)
    #expect(DockFootprint(displayID: mainID, edge: .bottom, thickness: 80).workArea(
        fullFrame: full, appKitVisibleFrame: appKitVisible
    ) == BTRect(x: 0, y: 24, width: 1200, height: 696))
    #expect(DockFootprint(displayID: mainID, edge: .left, thickness: 80).workArea(
        fullFrame: full, appKitVisibleFrame: appKitVisible
    ) == BTRect(x: 80, y: 24, width: 1120, height: 776))
    #expect(DockFootprint(displayID: mainID, edge: .right, thickness: 80).workArea(
        fullFrame: full, appKitVisibleFrame: appKitVisible
    ) == BTRect(x: 0, y: 24, width: 1120, height: 776))
}

/// After login the Dock reports no list until it is first shown. The
/// thickness measured on that edge in an earlier launch stands in on the
/// main display, and a restarting Dock keeps the last reading.
@Test @MainActor func unshownDockUsesTheThicknessLastMeasuredOnItsEdge() {
    let defaults = MemoryDefaults()
    let other = DisplayID(rawValue: "other")
    let displays: [(id: DisplayID, frame: BTRect)] = [(mainID, main), (other, BTRect(x: 2560, y: 0, width: 1920, height: 1080))]
    var edge = DockEdge.bottom
    var list: BTRect? = BTRect(x: 3000, y: 1080, width: 1000, height: 72)
    func reader() -> DockSpaceReader {
        DockSpaceReader(defaults: defaults, readPreferences: { (edge, true) }, readList: { list })
    }
    let earlier = reader()
    #expect(earlier.footprint(displays: displays, whileHidden: true, now: 0) == DockFootprint(displayID: other, edge: .bottom, thickness: 78))
    list = nil
    #expect(earlier.footprint(displays: displays, whileHidden: true, now: 1) == DockFootprint(displayID: other, edge: .bottom, thickness: 78))

    let afterLogin = reader()
    #expect(afterLogin.footprint(displays: displays, whileHidden: true, now: 0) == DockFootprint(displayID: mainID, edge: .bottom, thickness: 78))
    edge = .left
    #expect(afterLogin.footprint(displays: displays, whileHidden: true, now: 1) == nil)
}

/// With the setting off, a Dock that hides is not read at all. A Dock that
/// never hides still keeps its strip: macOS reserves it too, but AppKit can
/// report a secondary display's work area late after the Dock moves there.
@Test @MainActor func settingOffKeepsOnlyADockThatNeverHides() {
    var autohides = true
    var listReads = 0
    let reader = DockSpaceReader(
        defaults: MemoryDefaults(),
        readPreferences: { (.right, autohides) },
        readList: {
            listReads += 1
            return BTRect(x: 2488, y: 100, width: 72, height: 1200)
        }
    )
    let strip = DockFootprint(displayID: mainID, edge: .right, thickness: 78)
    #expect(reader.footprint(displays: [(mainID, main)], whileHidden: false, now: 0) == nil)
    #expect(listReads == 0)
    // Turning the setting on reads at once, without waiting for the next second.
    #expect(reader.footprint(displays: [(mainID, main)], whileHidden: true, now: 0.1) == strip)
    #expect(reader.footprint(displays: [(mainID, main)], whileHidden: false, now: 0.2) == nil)
    autohides = false
    #expect(reader.footprint(displays: [(mainID, main)], whileHidden: false, now: 2) == strip)
}

/// Keeps values in memory, so the test leaves no preferences file behind.
private final class MemoryDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Double] = [:]
    override func double(forKey key: String) -> Double { values[key] ?? 0 }
    override func set(_ value: Double, forKey key: String) { values[key] = value }
}
