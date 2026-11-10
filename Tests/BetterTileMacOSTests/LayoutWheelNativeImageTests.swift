import AppKit
import SwiftUI
import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

@MainActor @Suite(.macOSTestApplication, .serialized, .timeLimit(.minutes(1)))
struct LayoutWheelNativeImageTests {
    private var slots: [LayoutWheelSlot] {
        WindowAction.allCases.map { LayoutWheelSlot(command: .windowAction($0)) }
        + LayoutGlyph.all.map { .init(label: $0.title, symbolName: "", glyph: $0, isEmpty: false, isAvailable: true) }
        + [LayoutWheelCommand.repairBento, .savedLayouts, .savedLayout(file: "Fixture.json", name: "Fixture"),
           .moreSavedLayouts, .moreLayoutChoices].map { .init(command: $0) }
        + [.init(label: "Grid", symbolName: "rectangle.split.3x2", isEmpty: false, isAvailable: true), .empty]
    }

    // The exact artwork matrix now lives in GlyphMaskStoreTests and calls the
    // real LayoutWheelLiquidImages.icon path with N=20 reference membership.

    @Test func missingArtworkDoesNotBecomeASelectableBlankIcon() {
        var images = LayoutWheelLiquidImages()
        let slot = LayoutWheelSlot(label: "Missing fixture", symbolName: "bettert ile.missing.fixture", isEmpty: false, isAvailable: true)
        let image = images.icon(slot, symbol: 18, color: .white, dark: true, scale: 2)
        #expect(image == nil)
        #expect(images.retainedImageBytes == 0)
    }

    @Test func nativeSymbolsKeepTheMeasuredCentreLabelSpace() throws {
        for symbol in [12.8, 14.4, 16.0, 18.0, 19.2, 21.6] {
            for slot in slots where slot.glyph == nil
                && slot.symbolName != "rectangle.split.3x2"
                && slot.windowAction.flatMap({ WindowActionPartitionGlyph.actions[$0] }) == nil {
                try autoreleasepool {
                    let reference = ImageRenderer(content: Image(systemName: slot.symbolName)
                        .font(.system(size: symbol, weight: .semibold)).symbolRenderingMode(.monochrome)
                        .foregroundStyle(.white).fixedSize().padding(4))
                    reference.scale = 4
                    let bitmap = try #require(reference.cgImage)
                    let bytes = alpha(bitmap)
                    var minX = bitmap.width, minY = bitmap.height, maxX = -1, maxY = -1
                    for y in 0..<bitmap.height { for x in 0..<bitmap.width where bytes[y * bitmap.width + x] > 0 {
                        minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
                    } }
                    let size = LayoutWheelLabelSpace.iconSize(slot, frame: 35 / 18 * symbol, symbol: symbol)
                    #expect(abs(size.width - Double(maxX - minX + 1) / 4) <= 0.5, "\(slot.symbolName) width")
                    #expect(abs(size.height - Double(maxY - minY + 1) / 4) <= 0.5, "\(slot.symbolName) height")
                }
            }
        }
    }

    private func alpha(_ image: CGImage) -> [UInt8] {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        return stride(from: 3, to: image.width * image.height * 4, by: 4).map { bytes[$0] }
    }

}
