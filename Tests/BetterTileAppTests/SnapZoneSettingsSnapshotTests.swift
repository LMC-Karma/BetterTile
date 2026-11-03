import AppKit
import BetterTileCore
import SwiftUI
import Testing
@testable import BetterTileApp

@MainActor @Suite(.appTestApplication, .serialized) struct SnapZoneSettingsSnapshotTests {
    nonisolated static let snapshotDirectory = ProcessInfo.processInfo.environment["BT_SNAPSHOT_DIR"]

    enum State: String, CaseIterable {
        case standard, narrow, custom, reachLimit

        var activation: SnapZoneActivation {
            switch self {
            case .standard: SnapZonePreset.standard.activation
            case .narrow: SnapZonePreset.narrow.activation
            case .custom: .init(edge: 12, cornerExtension: 84)
            case .reachLimit: SnapZoneActivation(edge: 31, cornerExtension: 16).settingEdge(40)
            }
        }
    }

    struct Variant: CustomTestStringConvertible {
        var state: State
        var dark: Bool
        var width: Double
        var acknowledged: Bool
        var testDescription: String {
            "\(state.rawValue)-\(dark ? "dark" : "light")-\(Int(width))-\(acknowledged ? "acknowledged" : "notice")"
        }
    }

    nonisolated static var variants: [Variant] {
        guard snapshotDirectory != nil else {
            return [Variant(state: .standard, dark: false, width: 770, acknowledged: true)]
        }
        return State.allCases.flatMap { state in
            [false, true].flatMap { dark in
                [770.0, 980, 1280].flatMap { width in
                    [false, true].map { Variant(state: state, dark: dark, width: width, acknowledged: $0) }
                }
            }
        }
    }

    @Test(arguments: variants)
    func rendersEveryState(variant: Variant) throws {
        let model = makeModel(system: FakeAppWindowSystem())
        defer { model.shutdown() }
        model.updateConfiguration {
            $0.snapEdgeActivationDistance = variant.state.activation.edge
            $0.snapCornerActivationSize = variant.state.activation.cornerExtension
            $0.macOSTilingRecommendationAcknowledged = variant.acknowledged
        }
        let host = try SettingsSnapshotHost(pageView(variant.state, model: model), dark: variant.dark,
                                            width: variant.width, height: 1400, fitHeight: false)
        defer { host.close() }
        let bitmap = try host.render()
        #expect(bitmap.pixelsWide >= Int(variant.width))
        #expect(bitmap.pixelsHigh >= 1400)
        #expect(model.configuration.snapEdgeActivationDistance == variant.state.activation.edge)
        #expect(model.configuration.snapCornerActivationSize == variant.state.activation.cornerExtension)
        guard let directory = Self.snapshotDirectory else { return }
        let folder = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: folder.appendingPathComponent("snap-zones-\(variant.testDescription).png"))
    }

    private func pageView(_ state: State, model: BetterTileModel) -> some View {
        ZoneSettings(model: model, showsCustomActivation: state == .custom || state == .reachLimit,
                     reachAdjustment: state == .reachLimit ? "Reach rose to 56 pt." : nil)
    }
}
