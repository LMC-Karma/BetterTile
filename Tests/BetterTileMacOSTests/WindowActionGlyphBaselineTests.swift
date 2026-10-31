import AppKit
import SwiftUI
import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

/// Native halves and quarters captured before the partition artwork changed.
@MainActor @Suite(.macOSTestApplication, .serialized) struct WindowActionGlyphBaselineTests {
    static let actions: [WindowAction] = [
        .leftHalf, .rightHalf, .topHalf, .bottomHalf,
        .topLeftQuarter, .topRightQuarter, .bottomLeftQuarter, .bottomRightQuarter,
    ]
    private static let originalSymbols: [WindowAction: String] = [
        .leftHalf: "rectangle.lefthalf.filled", .rightHalf: "rectangle.righthalf.filled",
        .topHalf: "rectangle.tophalf.filled", .bottomHalf: "rectangle.bottomhalf.filled",
        .topLeftQuarter: "rectangle.inset.topleft.filled", .topRightQuarter: "rectangle.inset.topright.filled",
        .bottomLeftQuarter: "rectangle.inset.bottomleft.filled", .bottomRightQuarter: "rectangle.inset.bottomright.filled",
    ]

    static func atlas(scale: CGFloat, reference: Bool = false) throws -> CGImage {
        let renderer = ImageRenderer(content:
            VStack(spacing: 0) {
                ForEach([13, 16, 18, 24], id: \.self) { size in
                    HStack(spacing: 0) {
                        ForEach(actions) { action in
                            Group {
                                if reference {
                                    // Preserve the native branch of the original renderer.
                                    Image(systemName: originalSymbols[action]!)
                                        .font(.system(size: CGFloat(size), weight: .semibold))
                                        .symbolRenderingMode(.monochrome)
                                        .foregroundStyle(.black)
                                } else {
                                    LayoutWheelActionGlyph(action: action, tint: .black, fontSize: CGFloat(size))
                                }
                            }.frame(width: 48, height: 48)
                        }
                    }
                }
            }
        )
        renderer.scale = scale
        return try #require(renderer.cgImage)
    }

    @Test func halvesAndQuartersKeepTheirNativePixels() throws {
        let directory = try #require(Bundle.module.resourceURL).appending(path: "ActionGlyphs")
        for scale: CGFloat in [1, 2] {
            let rendered = try Self.atlas(scale: scale)
            let nativeReference = try Self.atlas(scale: scale, reference: true)
            let currentPixels = try pixels(rendered), originalPixels = try pixels(nativeReference)
            #expect(currentPixels == originalPixels, "Exact comparison with the preserved native renderer")
            // SF Symbols can change with the OS. Compare the recorded bitmap
            // on its original host, and the frozen native branch on every OS.
            guard ProcessInfo.processInfo.operatingSystemVersionString == "Version 27.0.1 (Build 26A434)" else { continue }
            let url = directory.appending(path: "native-neighbours-\(Int(scale))x.png")
            let reference = try #require(NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let actual = try pixels(rendered), expected = try pixels(reference)
            // The system symbol cache can round edge coverage by 1/255
            // between processes. The same-process reference above stays exact.
            #expect(actual.count == expected.count)
            #expect(zip(actual, expected).allSatisfy { abs(Int($0) - Int($1)) <= 1 },
                    "Recorded native pixels at \(scale)x")
            if let directory = ProcessInfo.processInfo.environment["BT_ACTION_PROOF_DIR"] {
                try #require(NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:]))
                    .write(to: URL(filePath: directory).appending(path: "current-neighbours-\(Int(scale))x.png"))
            }
        }
    }

    private func pixels(_ image: CGImage) throws -> Data {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try #require(context.data), count: image.height * context.bytesPerRow)
    }
}
