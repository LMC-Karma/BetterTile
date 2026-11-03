import AppKit
import BetterTileCore
import BetterTileMacOS
import SwiftUI
import Testing
@testable import BetterTileApp

@MainActor @Suite(.appTestApplication, .serialized) struct LayoutWheelGroupedSnapshotTests {
    @Test func groupedOfflineSnapshots() throws {
        let directory = ProcessInfo.processInfo.environment["BT_SNAPSHOT_DIR"]
        let themes = directory == nil ? [false] : [false, true]
        for dark in themes {
            for state in ["idle", "fan-open", "fan-move", "fan-thirds", "fan-sixths", "disabled-layout"] {
                var fan = LayoutWheelFanState()
                let geometry = LayoutWheelMetrics.grouped.fanGeometry
                var selection: LayoutWheelSelection?
                if state.hasPrefix("fan-") {
                    let sector: LayoutWheelSector = switch state {
                    case "fan-move": .topLeft
                    case "fan-thirds": .topRight
                    case "fan-sixths": .left
                    default: .top
                    }
                    let angle = Double(sector.rawValue) * .pi / 4
                    let parent = BTPoint(x: sin(angle) * 124, y: -cos(angle) * 124)
                    fan.update(vector: parent, at: 0, geometry: geometry)
                    fan.update(vector: parent, at: 0.2, geometry: geometry)
                    fan.update(vector: geometry.point(sector: sector, option: 1), at: 0.3, geometry: geometry)
                    selection = fan.selection
                } else if state == "disabled-layout" {
                    selection = .init(ring: .outer, sector: .bottomLeft)
                }
                let view = LayoutWheelView(configuration: .init(style: .grouped, levelCount: .two), overlayAppearance: .init(useLiquidGlass: false),
                    selection: selection, fan: fan, layoutAvailable: state != "disabled-layout")
                let host = try SettingsSnapshotHost(view, dark: dark, width: 560, height: 540)
                defer { host.close() }
                let bitmap = try host.render()
                #expect(bitmap.pixelsWide >= 560)
                try write(bitmap, directory: directory, name: "grouped-\(state)-\(dark ? "dark" : "light")")
            }
            let model = makeModel(system: FakeAppWindowSystem())
            defer { model.shutdown() }
            model.updateConfiguration { $0.layoutWheel.style = .grouped }
            let before = model.configuration
            let host = try SettingsSnapshotHost(LayoutWheelSettings(model: model), dark: dark, width: 1070, height: 1400)
            defer { host.close() }
            try write(host.render(), directory: directory, name: "grouped-settings-\(dark ? "dark" : "light")")
            #expect(model.configuration == before)
        }
    }

    private func write(_ bitmap: NSBitmapImageRep, directory: String?, name: String) throws {
        guard let directory else { return }
        let folder = URL(filePath: directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: folder.appendingPathComponent(name + ".png"))
    }
}
