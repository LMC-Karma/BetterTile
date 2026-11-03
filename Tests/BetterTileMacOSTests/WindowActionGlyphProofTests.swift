import AppKit
import SwiftUI
import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

/// Optional offscreen evidence. This never creates a window or an app model.
@MainActor @Suite(.macOSTestApplication, .serialized) struct WindowActionGlyphProofTests {
    static let comparison: [WindowAction] = [.leftHalf, .topLeftQuarter, .leftThird, .leftTwoThirds, .topLeftSixth]
    static let family: [WindowAction] = [.leftThird, .centerThird, .rightThird, .leftTwoThirds, .rightTwoThirds,
        .topLeftSixth, .topCenterSixth, .topRightSixth, .bottomLeftSixth, .bottomCenterSixth, .bottomRightSixth]

    private func image<V: View>(_ view: V, scale: CGFloat) throws -> CGImage {
        let renderer = ImageRenderer(content: view.environment(\.displayScale, scale))
        renderer.scale = scale
        return try #require(renderer.cgImage)
    }

    private func write<V: View>(_ view: V, name: String, scale: CGFloat, to folder: URL) throws {
        let rendered = try image(view, scale: scale)
        try #require(NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:]))
            .write(to: folder.appending(path: name + ".png"))
    }

    private func bounds(_ image: CGImage) -> CGRect {
        let bitmap = NSBitmapImageRep(cgImage: image)
        var result = CGRect.null
        for y in 0 ..< bitmap.pixelsHigh {
            for x in 0 ..< bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                result = result.union(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return result
    }

    @Test func newFramesMatchTheNativeHalfAndQuarter() throws {
        for size: CGFloat in [13, 16, 18, 24] {
            for weight in [LayoutGlyphWeight.regular, .semibold] {
                // Measure at 16x to separate geometry from 1x coverage rounding.
                var boxes: [CGRect] = []
                for action in Self.comparison {
                    let rendered = try image(LayoutWheelActionGlyph(action: action, tint: .black, fontSize: size, weight: weight)
                        .frame(width: 64, height: 64), scale: 16)
                    let box = bounds(rendered)
                    boxes.append(CGRect(x: box.minX / 16, y: box.minY / 16, width: box.width / 16, height: box.height / 16))
                }
                for box in boxes.dropFirst() {
                    #expect(abs(box.minX - boxes[0].minX) <= 0.5, "\(size) \(weight): \(box), native \(boxes[0])")
                    #expect(abs(box.maxX - boxes[0].maxX) <= 0.5)
                    #expect(abs(box.minY - boxes[0].minY) <= 0.5)
                    #expect(abs(box.maxY - boxes[0].maxY) <= 0.5)
                }
            }
        }
    }

    @Test func renderNativeProofMatrix() throws {
        guard let directory = ProcessInfo.processInfo.environment["BT_ACTION_PROOF_DIR"] else { return }
        let folder = URL(filePath: directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for dark in [false, true] {
            let scheme: ColorScheme = dark ? .dark : .light
            let background = Color(white: dark ? 0.12 : 0.97)
            let theme = dark ? "dark" : "light"
            for scale: CGFloat in [1, 2] {
                for weight in [LayoutGlyphWeight.regular, .semibold] {
                    let weightName = weight == .regular ? "regular" : "semibold"
                    for size: CGFloat in [13, 16, 18, 24] {
                        let row = HStack(spacing: 0) {
                            ForEach(Self.comparison) { action in
                                LayoutWheelActionGlyph(action: action, fontSize: size, weight: weight)
                                    .frame(width: 88, height: 56)
                            }
                        }.background(background).environment(\.colorScheme, scheme)
                        try write(row, name: "comparison-\(Int(size))-\(Int(scale))x-\(weightName)-\(theme)", scale: scale, to: folder)
                    }
                    for size: CGFloat in [16, 24] {
                        let row = HStack(spacing: 0) {
                            ForEach(Self.family) { action in
                                LayoutWheelActionGlyph(action: action, fontSize: size, weight: weight)
                                    .frame(width: 64, height: 56)
                            }
                        }.background(background).environment(\.colorScheme, scheme)
                        try write(row, name: "family-\(Int(size))-\(Int(scale))x-\(weightName)-\(theme)", scale: scale, to: folder)
                    }
                }
                var configuration = LayoutWheelConfiguration(levelCount: .two)
                for (sector, action) in zip(LayoutWheelSector.allCases, Self.comparison + [.topCenterSixth, .topRightSixth, .bottomRightSixth]) {
                    configuration.innerSlots[sector.rawValue] = .windowAction(action)
                }
                let input = LayoutWheelSceneInput(configuration: configuration)
                var motion = LayoutWheelMotion()
                motion.retarget(selection: nil, fan: input.fan, geometry: input.metrics.fanGeometry, reduceMotion: true)
                let wheel = LayoutWheelGlassView(input: input, motion: motion, reduceMotion: true)
                    .environment(\.layoutWheelGlassStandIn, .init(body: Color(white: dark ? 0.20 : 0.87), well: background))
                    .frame(width: 300, height: 300).background(background).environment(\.colorScheme, scheme)
                try write(wheel, name: "wheel-medium-\(Int(scale))x-\(theme)", scale: scale, to: folder)
            }
        }
    }
}
