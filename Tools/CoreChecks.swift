import Foundation

@main
enum CoreChecks {
    static func main() throws {
        let displayID = DisplayID(rawValue: "main")
        let bounds = BTRect(x: 0, y: 0, width: 1200, height: 800)
        let display = DisplaySnapshot(id: displayID, frame: bounds, visibleFrame: bounds, isMain: true)
        let window = WindowSnapshot(
            id: WindowID(rawValue: "window"), processIdentifier: 1,
            frame: BTRect(x: 200, y: 100, width: 600, height: 500), displayID: displayID
        )

        require(StandardActionEngine().targetFrame(for: .leftHalf, window: window, display: display) == BTRect(x: 0, y: 0, width: 600, height: 800), "standard action")

        var history = FrameHistory(capacity: 2)
        history.record(window.frame, for: window.id)
        require(history.restore(for: window.id) == window.frame, "history")

        let right = WindowSnapshot(
            id: WindowID(rawValue: "right"), processIdentifier: 2,
            frame: BTRect(x: 600, y: 0, width: 600, height: 800), displayID: displayID
        )
        let left = WindowSnapshot(
            id: WindowID(rawValue: "left"), processIdentifier: 3,
            frame: BTRect(x: 0, y: 0, width: 600, height: 800), displayID: displayID
        )
        let linked = LinkedResizeEngine().resize(windowID: left.id, edge: .right, delta: 80, windows: [left, right], bounds: bounds)
        require(linked?.appliedDelta == 80, "linked resize")

        var bento = BentoLayoutState()
        for id in [left.id, right.id, window.id] { bento.insert(id, in: bounds) }
        let tiledArea = bento.placements(in: bounds).reduce(0) { $0 + $1.frame.area }
        require(abs(tiledArea - bounds.area) < 0.01, "Bento coverage")

        let configuration = try BetterTileConfiguration().validated()
        let data = try JSONEncoder().encode(configuration)
        let decoded = try ConfigurationStore.decode(data)
        require(decoded == configuration, "configuration round-trip")

        print("BetterTile core checks passed")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else {
            FileHandle.standardError.write(Data("Core check failed: \(name)\n".utf8))
            exit(1)
        }
    }
}
