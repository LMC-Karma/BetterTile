import AppKit
import BetterTileCore
import Testing
@testable import BetterTileMacOS

// Observe the exact objects passed through production registration, never a
// bridged String copy that could keep the native owner alive itself.
@MainActor private final class TooltipObservation {
    weak var owner: AnyObject?
    let tag: NSView.ToolTipTag
    let rect: NSRect
    let characters: [unichar]
    let isHeapString: Bool

    init(owner: AnyObject, tag: NSView.ToolTipTag, rect: NSRect) {
        self.owner = owner
        self.tag = tag
        self.rect = rect
        let string = owner as! NSString
        characters = (0..<string.length).map { string.character(at: $0) }
        isHeapString = !String(describing: type(of: owner)).contains("TaggedPointer")
    }

    var text: String { String(utf16CodeUnits: characters, count: characters.count) }
}

@MainActor private final class TooltipLifetimeView: TabbedPaneContentView {
    var observations: [TooltipObservation] = []
    var removalCount = 0
    var ownersAliveAtRemoval: [Bool] = []

    override func addToolTip(_ rect: NSRect, owner: Any, userData data: UnsafeMutableRawPointer?) -> NSView.ToolTipTag {
        let tag = super.addToolTip(rect, owner: owner, userData: data)
        observations.append(TooltipObservation(owner: owner as AnyObject, tag: tag, rect: rect))
        return tag
    }

    override func removeAllToolTips() {
        ownersAliveAtRemoval.append(contentsOf: observations.map { $0.owner != nil })
        removalCount += 1
        super.removeAllToolTips()
        observations.removeAll()
    }
}

@MainActor private func registerTooltipFixture(_ view: TooltipLifetimeView, generation: Int, tabCount: Int) -> [NSRect] {
    let ids = (0..<tabCount).map { WindowID(rawValue: "tooltip-\(generation)-\($0)") }
    var pane = TabbedPane()
    pane.tabs = ids
    pane.selected = ids.first
    view.pane = pane
    // Inline Swift strings bridge to separate heap NSStrings. The title-width
    // cache can keep the Swift values without retaining those native owners.
    view.titles = ids.indices.map { String(decoding: Array("Title-\(generation)-\($0)-heap".utf8), as: UTF8.self) }
    let strip = view.strip
    var rects = [NSRect(x: 0, y: 0, width: 32, height: view.presentation.barHeight), strip.menuFrame]
    for slot in strip.visibleRange {
        var label = strip.tabFrame(slot)
        label.size.width -= 24
        rects += [label, strip.closeFrame(slot)]
    }
    view.updateToolTips()
    view.titles = []
    return rects
}

@Test(.macOSTestApplication, arguments: TabbedStripPresentation.allCases, [0, 2, 9]) @MainActor
func tabbedTooltipOwnersSurviveRegistrationAndReleaseAfterRemoval(presentation: TabbedStripPresentation, tabCount: Int) {
    let view = TooltipLifetimeView(frame: NSRect(x: 0, y: 0, width: 330, height: presentation.barHeight))
    view.presentation = presentation
    var previous: [TooltipObservation] = []
    for generation in 0..<4 {
        let rects = autoreleasepool { registerTooltipFixture(view, generation: generation, tabCount: tabCount) }
        autoreleasepool {
            #expect(previous.allSatisfy { !$0.isHeapString || $0.owner == nil })
            let current = view.observations
            #expect(current.map(\.rect) == rects)
            #expect(current.allSatisfy { $0.owner != nil })
            #expect(current[0].isHeapString)
            #expect(current[0].text == "Use this pane for new windows")
            if tabCount == 9 {
                #expect(current[1].isHeapString)
                #expect(current[1].text.contains("more tabs. Show all tabs and layout actions"))
            } else {
                #expect(current[1].text == "Show all tabs and layout actions")
            }
            for pair in stride(from: 2, to: current.count, by: 2) {
                #expect(current[pair].isHeapString)
                #expect(current[pair + 1].isHeapString)
                #expect(current[pair].text.hasPrefix("Title-\(generation)-"))
                #expect(current[pair + 1].text == "Close \(current[pair].text)")
            }
            previous = current
        }
    }
    autoreleasepool { view.removeAllToolTips() }
    #expect(previous.allSatisfy { !$0.isHeapString || $0.owner == nil })
    #expect(view.ownersAliveAtRemoval.allSatisfy { $0 })
    #expect(view.observations.isEmpty)
    #expect(view.removalCount == 5)
}

@Test(.macOSTestApplication) @MainActor func tabbedTooltipOwnerReleasesAfterIndividualRemoval() throws {
    let view = TooltipLifetimeView(frame: NSRect(x: 0, y: 0, width: 330, height: 34))
    autoreleasepool { view.updateToolTips() }
    let pane = try #require(view.observations.first)
    autoreleasepool {
        #expect(pane.isHeapString)
        #expect(pane.owner != nil)
    }
    autoreleasepool { view.removeToolTip(pane.tag) }
    #expect(pane.owner == nil)
    view.observations.removeFirst()
    view.removeAllToolTips()
}

@Test(.macOSTestApplication, arguments: [0, 9]) @MainActor func tabbedTooltipOwnersReleaseOnContentTeardown(tabCount: Int) {
    var view: TooltipLifetimeView?
    autoreleasepool {
        view = TooltipLifetimeView(frame: NSRect(x: 0, y: 0, width: 330, height: 34))
        _ = registerTooltipFixture(view!, generation: 0, tabCount: tabCount)
    }
    let observations = view?.observations ?? []
    #expect(observations.count >= 2)
    autoreleasepool { #expect(observations.allSatisfy { $0.owner != nil }) }
    weak var weakView = view
    autoreleasepool { view = nil }
    #expect(weakView == nil)
    #expect(observations.allSatisfy { !$0.isHeapString || $0.owner == nil })
}
