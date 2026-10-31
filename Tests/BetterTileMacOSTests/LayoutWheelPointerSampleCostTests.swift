import AppKit
import Metal
import Testing
@_spi(LiquidWheelPrototype) @testable import BetterTileCore
@_spi(LiquidWheelPrototype) @testable import BetterTileMacOS

/// Opt-in measurement: the cost of one pointer sample over an open wheel, on the overlay path (the
/// adapter) and on the preview path (the state the representable builds). Set
/// `BT_WHEEL_SAMPLE_COST_REPORT` to a file path to run it.
@MainActor @Suite(.macOSTestApplication, .serialized) struct LayoutWheelPointerSampleCostTests {
    @Test func pointerSampleCost() throws {
        guard let path = ProcessInfo.processInfo.environment["BT_WHEEL_SAMPLE_COST_REPORT"] else { return }
        try #require(MTLCreateSystemDefaultDevice() != nil)
        let now = { ProcessInfo.processInfo.systemUptime } // real-time: this opt-in benchmark reports actual cost
        var wheel = LayoutWheelConfiguration(style: .grouped, levelCount: .two)
        wheel.appearance.liquid.look.actionTint = true
        let flow = OverlayFlow(wheel: wheel)
        defer { flow.stop() }
        let layout = flow.content.layout
        let radius = try #require(layout.iconRadii.last)
        let angle = layout.slotAngle(LayoutWheelSector.top.rawValue)
        flow.move(.init(x: cos(angle) * radius, y: sin(angle) * radius))
        var presentation = try #require(flow.presentation)
        let adapter = flow.spy.adapter
        let samples = 20_000
        func overlayNanoseconds() -> Double {
            let began = now()
            for index in 0..<samples {
                presentation.pointer = BTPoint(x: 100 + Double(index % 97), y: -80 + Double(index % 53))
                adapter.update(presentation)
            }
            return (now() - began) / Double(samples) * 1e9
        }
        func previewNanoseconds() -> Double {
            let began = now()
            var sink = 0
            for index in 0..<samples {
                let pointer = BTPoint(x: 100 + Double(index % 97), y: -80 + Double(index % 53))
                let state = LayoutWheelLiquidScene.state(selection: presentation.selection, fan: presentation.fan, pointer: pointer)
                sink &+= state.aimedOption ?? 0
            }
            _ = sink
            return (now() - began) / Double(samples) * 1e9
        }
        _ = overlayNanoseconds(); _ = previewNanoseconds()
        let overlay = (0..<5).map { _ in overlayNanoseconds() }.sorted()
        let preview = (0..<5).map { _ in previewNanoseconds() }.sorted()
        let report = ["samplesPerRun": samples, "overlayNsPerSampleMedian": overlay[2], "overlayNsMin": overlay[0],
                      "overlayNsMax": overlay[4], "previewStateNsPerSampleMedian": preview[2],
                      "previewStateNsMin": preview[0], "previewStateNsMax": preview[4]] as [String: Any]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(filePath: path))
    }
}
