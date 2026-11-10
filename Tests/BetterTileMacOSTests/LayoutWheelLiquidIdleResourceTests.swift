import AppKit
import BetterTileTestSupport
import Metal
import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

@MainActor @Suite(.macOSTestApplication, .serialized, .timeLimit(.minutes(1))) struct LayoutWheelLiquidIdleResourceTests {
    private let content = LayoutWheelLiquidDefaults.content(
        configuration: .init(style: .grouped, levelCount: .two), currentMode: .manual)

    private func expire(_ renderer: LayoutWheelLiquidPresenter, clock: ManualClock) async throws {
        let release = try #require(renderer.idleReleaseTaskForTesting)
        // Policy time is virtual; finish the real one-pixel warm-up first.
        let commands = try #require(LayoutWheelLiquidPipeline.current?.queue.makeCommandBuffer())
        #expect(LayoutWheelLiquidPipeline.commitAndWait(commands))
        try #require(await clock.waitForSleepers(count: 1, timeout: .seconds(45)))
        clock.advance(by: LayoutWheelLiquidPresenter.resourceIdleDelay)
        await release.value
    }

    @Test(.liquidPipeline) func cancelledHoldReleasesResourcesAfterIdle() async throws {
        let clock = ManualClock()
        let renderer = LayoutWheelLiquidPresenter(frameSource: LayoutWheelLiquidDisplayLink(), resourceClock: clock.clock)
        weak var atlas: LayoutWheelLiquidAtlas?
        weak var layer: CAMetalLayer?
        weak var blur: NSVisualEffectView?
        autoreleasepool {
            #expect(renderer.prepareToOpen(content))
            atlas = renderer.atlasForTesting
            #expect(atlas != nil)
            layer = renderer.metalLayerForTesting
            blur = renderer.blurViewForTesting
            renderer.close()
        }
        try await expire(renderer, clock: clock)
        #expect(renderer.atlasForTesting != nil)
        #expect(atlas?.setPurgeableState(.keepCurrent) == .empty)
        CATransaction.flush()
        #expect(layer != nil && blur != nil)
        #expect(renderer.idleAtlasBytesForTesting > 0)
        #expect(renderer.retainedImageBytesForTesting == 0)
        #expect(renderer.hasEncoderForTesting)
        #expect(renderer.labelImageForTesting == nil)
        #expect(renderer.contentForTesting == nil)
        #expect(!renderer.isOpen && !renderer.isVisible)
        renderer.releaseResources()
        #expect(renderer.atlasForTesting == nil && renderer.idleAtlasBytesForTesting == 0)
    }

    @Test(.liquidPipeline) func anotherHoldCancelsExpiryAndKeepsItsPreparedResources() async throws {
        let clock = ManualClock()
        let renderer = LayoutWheelLiquidPresenter(frameSource: LayoutWheelLiquidDisplayLink(), resourceClock: clock.clock)
        #expect(renderer.prepareToOpen(content))
        let atlas = try #require(renderer.atlasForTesting)
        renderer.close()
        let release = try #require(renderer.idleReleaseTaskForTesting)
        try #require(await clock.waitForSleepers(count: 1, timeout: .seconds(45)))
        clock.advance(by: .seconds(4))
        #expect(renderer.atlasForTesting === atlas)
        #expect(renderer.prepareToOpen(content))
        clock.advance(by: .seconds(10))
        await release.value
        #expect(renderer.idleReleaseTaskForTesting == nil)
        #expect(renderer.atlasForTesting === atlas)
        #expect(renderer.hasEncoderForTesting)
        renderer.releaseResources()
    }

    @Test(.liquidPipeline) func idleReopenRestoresTheSnapshotWithoutRasterizingIcons() async throws {
        let clock = ManualClock()
        let renderer = LayoutWheelLiquidPresenter(frameSource: LayoutWheelLiquidDisplayLink(), resourceClock: clock.clock)
        #expect(renderer.prepareToOpen(content))
        renderer.close()
        try await expire(renderer, clock: clock)
        let original = renderer.atlasForTesting
        renderer.imageFailure = { _ in true } // A cold raster preparation would fail.
        #expect(renderer.prepareToOpen(content))
        #expect(renderer.atlasForTesting === original && renderer.hasEncoderForTesting)
        #expect(renderer.idleAtlasBytesForTesting > 0)
        #expect(renderer.retainedImageBytesForTesting < 32_768) // Only the centre label, no icon bitmaps.
        renderer.makeIdleSnapshot = { _ in Issue.record("The same atlas must not compress again"); return nil }
        renderer.close()
        try await expire(renderer, clock: clock)
        #expect(renderer.atlasForTesting?.setPurgeableState(.keepCurrent) == .empty)
        #expect(renderer.idleAtlasBytesForTesting > 0)
        renderer.releaseResources()
    }

    @Test(.liquidPipeline) func changedContentCannotRestoreThePreviousIcons() async throws {
        let clock = ManualClock()
        let renderer = LayoutWheelLiquidPresenter(frameSource: LayoutWheelLiquidDisplayLink(), resourceClock: clock.clock)
        #expect(renderer.prepareToOpen(content))
        renderer.close()
        try await expire(renderer, clock: clock)
        var configuration = content.configuration
        configuration.setGroup(.init(quickAction: .windowAction(.center), options: [.windowAction(.restore)]), at: .top)
        let changed = LayoutWheelLiquidDefaults.content(configuration: configuration, currentMode: .manual)
        renderer.imageFailure = { _ in true }
        #expect(!renderer.prepareToOpen(changed))
        #expect(renderer.atlasForTesting == nil)
        renderer.imageFailure = { _ in false }
        #expect(renderer.prepareToOpen(changed))
        #expect(renderer.contentForTesting == changed)
        #expect(renderer.idleAtlasBytesForTesting == 0)
        renderer.releaseResources()
    }

    @Test(.liquidPipeline) func compressionFailureKeepsTheWarmAtlas() async throws {
        let clock = ManualClock()
        let renderer = LayoutWheelLiquidPresenter(frameSource: LayoutWheelLiquidDisplayLink(), resourceClock: clock.clock)
        #expect(renderer.prepareToOpen(content))
        let atlas = try #require(renderer.atlasForTesting)
        renderer.makeIdleSnapshot = { _ in nil }
        renderer.close()
        try await expire(renderer, clock: clock)
        #expect(renderer.atlasForTesting === atlas)
        #expect(renderer.idleAtlasBytesForTesting == 0)
        #expect(renderer.idleReleaseTaskForTesting == nil)
        #expect(renderer.prepareToOpen(content))
        renderer.releaseResources()
    }

    @Test(.liquidPipeline) func restoreFailureRefusesPreparationAndCanRetryTheSameSnapshot() async throws {
        let clock = ManualClock()
        let renderer = LayoutWheelLiquidPresenter(frameSource: LayoutWheelLiquidDisplayLink(), resourceClock: clock.clock)
        #expect(renderer.prepareToOpen(content))
        renderer.close()
        try await expire(renderer, clock: clock)
        renderer.atlasForTesting?.setPurgeableState(.empty)
        let restore = renderer.restoreAtlas
        renderer.restoreAtlas = { _, _, _ in nil }
        #expect(!renderer.prepareToOpen(content))
        #expect(renderer.atlasForTesting == nil && !renderer.isOpen)
        #expect(renderer.idleAtlasBytesForTesting > 0)
        renderer.restoreAtlas = restore
        #expect(renderer.prepareToOpen(content))
        #expect(renderer.atlasForTesting != nil)
        renderer.releaseResources()
    }

    @Test(.liquidPipeline) func explicitReleaseCancelsExpiryAndDiscardsTheSnapshot() async throws {
        let clock = ManualClock()
        let renderer = LayoutWheelLiquidPresenter(frameSource: LayoutWheelLiquidDisplayLink(), resourceClock: clock.clock)
        #expect(renderer.prepareToOpen(content))
        renderer.close()
        let release = try #require(renderer.idleReleaseTaskForTesting)
        try #require(await clock.waitForSleepers(count: 1, timeout: .seconds(45)))
        renderer.releaseResources()
        clock.advance(by: .seconds(10))
        await release.value
        #expect(renderer.idleReleaseTaskForTesting == nil)
        #expect(renderer.atlasForTesting == nil && renderer.idleAtlasBytesForTesting == 0)
        #expect(clock.pendingSleepCount == 0)
        // A later explicit disable also drops an already compressed snapshot.
        #expect(renderer.prepareToOpen(content))
        renderer.close()
        try await expire(renderer, clock: clock)
        #expect(renderer.idleAtlasBytesForTesting > 0)
        renderer.releaseResources()
        #expect(renderer.idleAtlasBytesForTesting == 0)
    }

    @Test(.liquidPipeline) func idleWaitDoesNotRetainThePresenter() async throws {
        let clock = ManualClock()
        weak var owner: LayoutWheelLiquidPresenter?
        let release = try autoreleasepool {
            let renderer = LayoutWheelLiquidPresenter(frameSource: LayoutWheelLiquidDisplayLink(), resourceClock: clock.clock)
            #expect(renderer.prepareToOpen(content))
            renderer.close()
            owner = renderer
            return try #require(renderer.idleReleaseTaskForTesting)
        }
        await release.value
        #expect(owner == nil)
        #expect(clock.pendingSleepCount == 0)
    }

}

@MainActor @Suite(.macOSTestApplication, .serialized, .timeLimit(.minutes(1))) struct LayoutWheelLiquidAtlasSnapshotTests {
    private func pixels(_ atlas: LayoutWheelLiquidAtlas) -> Data {
        let texture = atlas.texture
        var result = Data(count: texture.width * texture.height * 4)
        result.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 4,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return result
    }

    @Test(.liquidPipeline, arguments: [LayoutWheelStyle.custom, .grouped], [LayoutWheelLevelCount.one, .two])
    func snapshotsRestoreExactPixelsAndSpriteGeometry(style: LayoutWheelStyle, levels: LayoutWheelLevelCount) throws {
        let pipeline = try #require(LayoutWheelLiquidPipeline.prepare())
        let content = LayoutWheelLiquidDefaults.content(configuration: .init(style: style, levelCount: levels))
        for dark in [false, true] {
            for names in [LayoutWheelLiquidPresenter.Names.centre, .underIcons] {
                let renderer = LayoutWheelLiquidPresenter()
                renderer.dark = dark
                renderer.names = names
                #expect(renderer.prepareToOpen(content))
                defer { renderer.releaseResources() }
                let original = try #require(renderer.atlasForTesting)
                let snapshot = try #require(original.snapshot())
                #expect(snapshot.pixels.count < original.texture.width * original.texture.height * 4)
                let restored = try #require(LayoutWheelLiquidAtlas(device: pipeline.device, snapshot: snapshot))
                #expect(pixels(restored) == pixels(original))
                #expect(restored.entries.keys == original.entries.keys)
                for (key, entry) in original.entries {
                    #expect(restored.entries[key]?.uv == entry.uv)
                    #expect(restored.entries[key]?.size == entry.size)
                }
            }
        }
    }

    @Test(.liquidPipeline) func textureDiscardWaitsForEveryFramePermitAndReturnsThem() throws {
        let pipeline = try #require(LayoutWheelLiquidPipeline.prepare())
        let encoder = try #require(LayoutWheelLiquidEncoder(pipeline: pipeline))
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
            bytesPerRow: 32, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        let image = try #require(context.makeImage())
        let atlas = try #require(LayoutWheelLiquidAtlas(device: pipeline.device, images: [(.chevron, image)], scale: 1))
        // Each failed probe must return all the permits it temporarily takes.
        for held in 1...LayoutWheelLiquidEncoder.framesInFlight {
            var releases: [() -> Void] = []
            for _ in 0..<held { releases.append(try #require(encoder.reserveFrameForTesting())) }
            #expect(!encoder.discardAtlasContentsIfIdle(atlas))
            #expect(atlas.setPurgeableState(.keepCurrent) == .nonVolatile)
            for release in releases { release() }
        }
        #expect(encoder.discardAtlasContentsIfIdle(atlas))
        #expect(atlas.setPurgeableState(.keepCurrent) == .empty)
        #expect(encoder.discardAtlasContentsIfIdle(atlas))
    }

    @Test(.liquidPipeline) func invalidSnapshotCannotCreateAnAtlas() throws {
        let device = try #require(LayoutWheelLiquidPipeline.prepare()?.device)
        let corrupt = LayoutWheelLiquidAtlas.Snapshot(pixels: Data([1, 2, 3]),
            width: 1024, height: 1, entries: [:])
        #expect(LayoutWheelLiquidAtlas(device: device, snapshot: corrupt) == nil)
        let renderer = LayoutWheelLiquidPresenter()
        #expect(renderer.prepareToOpen(LayoutWheelLiquidDefaults.content(configuration: .init())))
        defer { renderer.releaseResources() }
        let atlas = try #require(renderer.atlasForTesting)
        let snapshot = try #require(atlas.snapshot())
        let wrongSize = LayoutWheelLiquidAtlas.Snapshot(pixels: snapshot.pixels,
            width: snapshot.width, height: snapshot.height + 1, entries: snapshot.entries)
        #expect(LayoutWheelLiquidAtlas(device: device, snapshot: wrongSize) == nil)
    }
}
