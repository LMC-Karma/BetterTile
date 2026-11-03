import BetterTileCore
import Foundation
import Testing
@testable import BetterTileApp

/// The proportions control sets one pane's share of its split. Every pane must keep the editor's
/// minimum size, and the shares must stay a valid layout (each above 0 and below 1, summing to 1).
@Suite(.appTestApplication) @MainActor struct SavedLayoutProportionTests {
    private func editor(_ layout: SavedLayoutNode, gap: Double = 0) -> SavedLayoutEditor {
        let editor = SavedLayoutEditor(files: SavedLayoutFiles(directory: FileManager.default.temporaryDirectory
            .appending(path: "SavedLayoutProportionTests-" + UUID().uuidString)))
        editor.newLayout()
        #expect(editor.edit { $0 = SavedLayoutDocument(name: "Test", mode: .bento, layout: layout, slots: [], paneGap: gap) })
        return editor
    }

    private func ratios(_ editor: SavedLayoutEditor, at path: [Int] = []) -> [Double] {
        guard let root = editor.document?.layout, case let .split(_, ratios, _)? = SavedLayoutCanvas.node(at: path, in: root)
        else { return [] }
        return ratios
    }

    private func valid(_ values: [Double]) -> Bool {
        values.allSatisfy { $0.isFinite && $0 > 0 && $0 < 1 } && abs(values.reduce(0, +) - 1) < 1e-9
    }

    @Test(arguments: [1.0, 0.999_999, 2.0])
    func fullShareStopsAtTheMinimumOfTheOtherPane(share: Double) {
        let editor = editor(.split(axis: .vertical, ratios: [0.5, 0.5], children: [.empty, .empty]))
        editor.setRatio(path: [], child: 0, ratio: share)
        let values = ratios(editor)
        #expect(valid(values))
        #expect(abs(values[1] - SavedLayoutCanvas.minimumWidth) < 1e-9)
        #expect(editor.message == nil)
    }

    @Test(arguments: [0.0, -1.0, .nan])
    func zeroShareStopsAtTheMinimum(share: Double) {
        let editor = editor(.split(axis: .vertical, ratios: [0.5, 0.5], children: [.empty, .empty]))
        editor.setRatio(path: [], child: 0, ratio: share)
        let values = ratios(editor)
        #expect(valid(values))
        if share.isNaN { #expect(values == [0.5, 0.5]) } else { #expect(abs(values[0] - SavedLayoutCanvas.minimumWidth) < 1e-9) }
    }

    @Test func otherPanesKeepTheirProportionsAndMinimums() {
        let editor = editor(.split(axis: .vertical, ratios: [0.5, 0.3, 0.2], children: [.empty, .empty, .empty]))
        editor.setRatio(path: [], child: 0, ratio: 0.2)
        var values = ratios(editor)
        #expect(valid(values))
        #expect(abs(values[0] - 0.2) < 1e-9 && abs(values[1] - 0.48) < 1e-9 && abs(values[2] - 0.32) < 1e-9)
        // The largest share leaves each other pane exactly its minimum.
        editor.setRatio(path: [], child: 1, ratio: 0.95)
        values = ratios(editor)
        #expect(valid(values))
        #expect(abs(values[1] - 0.8) < 1e-9)
        #expect(values.enumerated().allSatisfy { $0.offset == 1 || abs($0.element - 0.1) < 1e-9 })
    }

    @Test func nearZeroSiblingsShareTheRestEqually() {
        let editor = editor(.split(axis: .horizontal, ratios: [0.999_998, 0.000_001, 0.000_001],
                                   children: [.empty, .empty, .empty]))
        editor.setRatio(path: [], child: 0, ratio: 0.5)
        let values = ratios(editor)
        #expect(valid(values))
        #expect(abs(values[1] - 0.25) < 1e-9 && abs(values[2] - 0.25) < 1e-9)
    }

    @Test func nestedSplitUsesItsOwnSizeForTheMinimum() {
        // The right column is 40 % wide; its two rows split the full height.
        let editor = editor(.split(axis: .vertical, ratios: [0.6, 0.4], children: [
            .empty, .split(axis: .horizontal, ratios: [0.5, 0.5], children: [.empty, .empty]),
        ]))
        editor.setRatio(path: [1], child: 0, ratio: 1)
        let values = ratios(editor, at: [1])
        #expect(valid(values))
        #expect(abs(values[1] - SavedLayoutCanvas.minimumHeight) < 1e-9)
        #expect(ratios(editor) == [0.6, 0.4])
    }
}


/// "Added Calculator as a tab." must name the app, even before the canvas has looked the new app up.
@Test(.appTestApplication) @MainActor func savedLayoutCanvasNamesAnAppAddedFromThePaletteBeforeItsLookup() {
    let calculator = ApplicationChoice(bundleIdentifier: "com.apple.calculator", name: "Calculator",
                                       url: URL(filePath: "/System/Applications/Calculator.app"))
    #expect(SavedLayoutCanvasView.appName("com.apple.calculator", resolved: [:], palette: [calculator], lookupFinished: true)
            == "Calculator")
    #expect(SavedLayoutCanvasView.appName("org.example.Gone", resolved: [:], palette: [calculator], lookupFinished: true)
            == "An app that is not installed")
    #expect(SavedLayoutCanvasView.appName("org.example.Gone", resolved: [:], palette: [], lookupFinished: false) == "")
}
