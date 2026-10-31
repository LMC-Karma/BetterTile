import AppKit
import Metal
import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

@MainActor @Suite(.macOSTestApplication, .serialized) struct LayoutWheelLiquidResourceTests {
    private let configuration = LayoutWheelConfiguration(style: .grouped, levelCount: .two)

    @Test func theDefaultDefersImagesUntilTheHold() throws {
        try #require(MTLCreateSystemDefaultDevice() != nil)
        let adapter = LayoutWheelLiquidAdapter()
        adapter.prewarm(configuration: configuration, appearance: .init())
        #expect(adapter.renderer.atlasForTesting == nil)
        adapter.prepareToOpen(configuration: configuration, appearance: .init())
        #expect(adapter.renderer.atlasForTesting != nil)
        adapter.discardPreparation()
    }

    @Test func closedResourcesStayReadyForTheNextHold() throws {
        try #require(MTLCreateSystemDefaultDevice() != nil)
        let adapter = LayoutWheelLiquidAdapter()
        adapter.prewarm(configuration: configuration, appearance: .init())
        adapter.prepareToOpen(configuration: configuration, appearance: .init())
        let atlas = try #require(adapter.renderer.atlasForTesting)
        adapter.discardPreparation()
        adapter.close()
        adapter.prewarm(configuration: configuration, appearance: .init())
        adapter.prepareToOpen(configuration: configuration, appearance: .init())
        #expect(adapter.renderer.atlasForTesting === atlas)
        adapter.discardPreparation()
    }

    @Test func configurationChangesWaitForTheNextHold() throws {
        try #require(MTLCreateSystemDefaultDevice() != nil)
        let adapter = LayoutWheelLiquidAdapter()
        adapter.prepareToOpen(configuration: configuration, appearance: .init())
        let atlas = try #require(adapter.renderer.atlasForTesting)
        adapter.discardPreparation()
        var edited = configuration
        edited.setGroup(.init(quickAction: .windowAction(.center), options: [.windowAction(.restore)]), at: .top)
        adapter.prewarm(configuration: edited, appearance: .init())
        #expect(adapter.renderer.atlasForTesting === atlas)
        adapter.prepareToOpen(configuration: edited, appearance: .init())
        #expect(adapter.renderer.atlasForTesting != nil)
        #expect(adapter.renderer.atlasForTesting !== atlas)
        adapter.discardPreparation()
    }

    @Test(arguments: [true, false])
    func disablingTheWheelOrItsTriggersDropsImages(disableWheel: Bool) throws {
        try #require(MTLCreateSystemDefaultDevice() != nil)
        let adapter = LayoutWheelLiquidAdapter()
        adapter.prepareToOpen(configuration: configuration, appearance: .init())
        #expect(adapter.renderer.atlasForTesting != nil)
        adapter.discardPreparation()
        var disabled = configuration
        if disableWheel { disabled.isEnabled = false }
        else { disabled.triggers.keyboardEnabled = false; disabled.triggers.mouse = .off }
        adapter.prewarm(configuration: disabled, appearance: .init())
        #expect(adapter.renderer.atlasForTesting == nil)
    }

    @Test func preparedResourcesDoNotRetainAdapterRendererOrPanel() throws {
        try #require(MTLCreateSystemDefaultDevice() != nil)
        weak var weakAdapter: LayoutWheelLiquidAdapter?
        weak var weakRenderer: LayoutWheelLiquidPresenter?
        weak var weakPanel: NSPanel?
        autoreleasepool {
            let adapter = LayoutWheelLiquidAdapter()
            adapter.prepareToOpen(configuration: configuration, appearance: .init())
            adapter.discardPreparation()
            weakAdapter = adapter; weakRenderer = adapter.renderer; weakPanel = adapter.renderer.panelForTesting
        }
        #expect(weakAdapter == nil)
        #expect(weakRenderer == nil)
        #expect(weakPanel == nil)
    }
}
