import AppKit
import BetterTileCore
import SwiftUI
import Testing
@testable import BetterTileApp

@MainActor @Suite(.appTestApplication, .serialized) struct MenuBarWheelSettingsSnapshotTests {
    nonisolated static let snapshotDirectory = ProcessInfo.processInfo.environment["BT_SNAPSHOT_DIR"]

    enum Page: String, CaseIterable {
        case menuBar, layoutWheel
    }

    @Test func rendersEveryPage() throws {
        for page in Page.allCases {
            let states = Self.snapshotDirectory == nil ? ["default"] : states(for: page)
            for state in states {
                for dark in Self.snapshotDirectory == nil ? [false] : [false, true] {
                    for width in Self.snapshotDirectory == nil ? [770.0] : [770.0, 1070.0] {
                        for glass in Self.snapshotDirectory == nil ? [false] : [false, true] {
                            let model = makeModel(system: FakeAppWindowSystem())
                            defer { model.shutdown() }
                            model.updateConfiguration {
                                $0.overlayAppearance.useLiquidGlass = glass
                                switch state {
                                case "few-actions": $0.menuBarActions = [.leftHalf, .rightHalf, .maximize]
                                case "two-levels": $0.layoutWheel.levelCount = .two
                                case "wheel-off": $0.layoutWheel.isEnabled = false
                                case "middle-click": $0.layoutWheel.middleClickTriggerEnabled = true
                                default: break
                                }
                            }
                            let configuration = model.configuration
                            let host = try SettingsSnapshotHost(pageView(page, model: model), dark: dark,
                                                               width: width, height: 1800)
                            defer { host.close() }
                            let bitmap = try host.render()
                            #expect(bitmap.pixelsWide >= Int(width))
                            #expect(host.view.fittingSize.height > 400)
                            #expect(model.configuration == configuration)
                            try write(bitmap, name: "settings-\(page.rawValue)-\(state)-\(dark ? "dark" : "light")-\(Int(width))-\(glass ? "glass" : "solid")")
                        }
                    }
                }
            }
        }
    }

    private func states(for page: Page) -> [String] {
        switch page {
        case .menuBar: ["default", "few-actions"]
        case .layoutWheel: ["default", "two-levels", "wheel-off", "middle-click"]
        }
    }

    private func pageView(_ page: Page, model: BetterTileModel) -> AnyView {
        switch page {
        case .menuBar: AnyView(MenuBarSettings(model: model))
        case .layoutWheel: AnyView(LayoutWheelSettings(model: model))
        }
    }

    private func write(_ bitmap: NSBitmapImageRep, name: String) throws {
        guard let directory = Self.snapshotDirectory else { return }
        let folder = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: folder.appendingPathComponent(name + ".png"))
    }
}
