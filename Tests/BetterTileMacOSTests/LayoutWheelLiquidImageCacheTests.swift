import AppKit
import Testing
@_spi(LiquidWheelPrototype) @testable import BetterTileCore
@_spi(LiquidWheelPrototype) @testable import BetterTileMacOS

@Suite(.macOSTestApplication)
@MainActor struct LayoutWheelLiquidImageCacheTests {
    @Test func leastRecentlyUsedImagesAreEvictedAndOversizeImagesAreNotStored() throws {
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
                                             bytesPerRow: 32, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let cost = image.bytesPerRow * image.height
        var cache = LayoutWheelLiquidImageCache(limit: 2 * cost)
        cache["a"] = image; cache["b"] = image
        let touched = cache["a"]
        #expect(touched === image)
        cache["c"] = image
        let evicted = cache["b"]
        #expect(evicted == nil && cache.count == 2 && cache.bytes == 2 * cost)
        cache["a"] = image
        #expect(cache.count == 2 && cache.bytes == 2 * cost)
        cache["a"] = nil
        #expect(cache.count == 1 && cache.bytes == cost)
        var tooSmall = LayoutWheelLiquidImageCache(limit: cost - 1)
        tooSmall["large"] = image
        #expect(tooSmall.count == 0 && tooSmall.bytes == 0)
        var smallImages = LayoutWheelLiquidImageCache(limit: 1_048_576)
        for index in 0..<1_000 { smallImages[String(index)] = image }
        #expect(smallImages.count == smallImages.maximumCount)
    }

    @Test func cachedPixelsDoNotRetainTheSourceProvider() throws {
        final class Owner: Sendable {}
        weak var weakOwner: Owner?
        let copied: CGImage? = try autoreleasepool {
            let owner = Owner()
            weakOwner = owner
            let bytes = UnsafeMutableRawPointer.allocate(byteCount: 256, alignment: 16)
            bytes.initializeMemory(as: UInt8.self, repeating: 255, count: 256)
            // Two different rows catch an accidental vertical flip.
            bytes.storeBytes(of: UInt32(0xFF0000FF), as: UInt32.self)
            bytes.advanced(by: 224).storeBytes(of: UInt32(0xFF00FF00), as: UInt32.self)
            let source = CGDataProvider(dataInfo: Unmanaged.passRetained(owner).toOpaque(),
                                                       data: bytes, size: 256, releaseData: { info, bytes, _ in
                UnsafeMutableRawPointer(mutating: bytes).deallocate()
                Unmanaged<Owner>.fromOpaque(info!).release()
            })
            let provider = try #require(source)
            let image = try #require(CGImage(width: 8, height: 8, bitsPerComponent: 8, bitsPerPixel: 32,
                                             bytesPerRow: 32, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                                                                      | CGBitmapInfo.byteOrder32Big.rawValue),
                                             provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
            let result = LayoutWheelLiquidImages.rasterize(image)
            let original = NSBitmapImageRep(cgImage: image)
            let copy = NSBitmapImageRep(cgImage: try #require(result))
            for point in [(0, 0), (0, 7), (4, 3)] {
                let a = try #require(original.colorAt(x: point.0, y: point.1)?.usingColorSpace(.sRGB))
                let b = try #require(copy.colorAt(x: point.0, y: point.1)?.usingColorSpace(.sRGB))
                #expect(abs(a.redComponent - b.redComponent) < 0.005)
                #expect(abs(a.greenComponent - b.greenComponent) < 0.005)
                #expect(abs(a.blueComponent - b.blueComponent) < 0.005)
                #expect(a.alphaComponent == b.alphaComponent)
            }
            return result
        }
        #expect(copied != nil)
        #expect(weakOwner == nil)
    }

    @Test func nativeIconsUpdateTheirArtworkAndInk() throws {
        var images = LayoutWheelLiquidImages()
        let left = images.icon(.init(command: .windowAction(.leftHalf)), symbol: 18, color: .white,
                               dark: true, scale: 2)
        let right = images.icon(.init(command: .windowAction(.rightHalf)), symbol: 18, color: .black,
                                dark: false, scale: 2)
        let first = try #require(left)
        let second = try #require(right)
        #expect(first.dataProvider?.data != second.dataProvider?.data)
        let sameInk = images.icon(.init(command: .windowAction(.rightHalf)), symbol: 18, color: .white,
                                  dark: true, scale: 2)
        #expect(first.dataProvider?.data != sameInk?.dataProvider?.data)
        let cached = images.icon(.init(command: .windowAction(.leftHalf)), symbol: 18, color: .white,
                                 dark: true, scale: 2)
        #expect(cached === first)
    }

    @Test func clearingBothImageStoresReleasesTheirOwnedBitmap() {
        weak var bitmap: CGImage?
        autoreleasepool {
            var images = LayoutWheelLiquidImages()
            bitmap = images.icon(.init(command: .windowAction(.leftHalf)), symbol: 18,
                                 color: .white, dark: true, scale: 2)
            #expect(bitmap != nil)
        }
        GlyphMaskStore.removeCachedImages()
        #expect(bitmap == nil)
    }

    @Test func finishingPreparationKeepsTheNativeBitmap() throws {
        var images = LayoutWheelLiquidImages()
        let image = images.icon(.init(command: .windowAction(.leftHalf)), symbol: 18,
                                color: .white, dark: true, scale: 2)
        let bitmap = try #require(image)
        images.finishIconRendering()
        let cached = images.icon(.init(command: .windowAction(.leftHalf)), symbol: 18,
                                 color: .white, dark: true, scale: 2)
        #expect(cached === bitmap)
    }

    @Test func changingNamesCannotRetainEveryImage() throws {
        var images = LayoutWheelLiquidImages()
        let content = LayoutWheelLiquidContent(configuration: .init(style: .grouped), levelCount: .two)
        for index in 0..<400 {
            let image = images.caption("Action \(index)", layout: content.layout, color: .white, scale: 2)
            #expect(image != nil)
        }
        #expect(images.retainedImageBytes <= 1_048_576)
        let image = images.caption("Action 399", layout: content.layout, color: .white, scale: 2)
        let last = try #require(image)
        let reused = images.caption("Action 399", layout: content.layout, color: .white, scale: 2)
        #expect(reused === last)
    }
}
