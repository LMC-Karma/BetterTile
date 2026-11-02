import AppKit
import BetterTileCore
import SwiftUI
import Testing
@testable import BetterTileApp

@Suite(.appTestApplication, .settingsUI) @MainActor struct SettingsFeedbackRowsTests {
    @Test func twoLineRuleListRowsAre44Points() async throws {
        let model = makeModel(system: FakeAppWindowSystem())
        defer { model.shutdown() }
        for index in 0..<6 {
            model.configuration.applicationRules.set(.excludeFromBento, for: "com.example.app-\(index)")
        }
        let host = try SettingsSnapshotHost(ApplicationRuleSettings(model: model), dark: false,
                                            width: 980, height: 640, fitHeight: false)
        defer { host.close() }
        func tables(in view: NSView) -> [NSTableView] {
            (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap { tables(in: $0) }
        }
        let table = try #require(tables(in: host.view).first { $0.numberOfRows == 6 })
        // The page looks up each rule's app after its first drawing. Until then a row is neutral and its summary is
        // the rule title, which can wrap. Measure the rows in their looked-up state.
        try await waitForSettingsUI("the looked-up rule rows", in: host.view) {
            (0..<table.numberOfRows).allSatisfy { table.rect(ofRow: $0).height == 44 }
        }
        for row in 0..<table.numberOfRows {
            #expect(table.rect(ofRow: row).height == 44)
        }
        let bitmap = try host.render()
        let selected = try #require(table.selectedRowIndexes.first)
        let row = table.convert(table.rect(ofRow: selected), to: host.view)
        let scale = CGFloat(bitmap.pixelsWide) / host.view.bounds.width
        func brightness(_ x: CGFloat) throws -> CGFloat {
            let color = try #require(bitmap.colorAt(x: Int((row.minX + x) * scale), y: Int(row.midY * scale))?.usingColorSpace(.deviceRGB))
            return (color.redComponent + color.greenComponent + color.blueComponent) / 3
        }
        // Native plain List selection used to fill the edge behind the rounded highlight.
        #expect(try brightness(2) > brightness(10) + 0.02)
        #expect(try brightness(row.width - 2) > brightness(row.width - 10) + 0.02)
    }
}
