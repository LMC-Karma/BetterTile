import AppKit
import BetterTileCore
import SwiftUI
import Testing
@testable import BetterTileApp
@testable import BetterTileMacOS

@MainActor @Suite(.appTestApplication, .serialized) struct WindowActionGlyphInkTests {
    private enum Site: String, CaseIterable { case menu, wheel }
    private enum State: String, CaseIterable { case available, unavailable, selected }
    private struct Measurement: Encodable {
        let site: String
        let state: String
        let theme: String
        let action: String
        let native: [Int]
        let actual: [Int]
    }

    @Test func actionInkMatchesNativeSymbolsInEverySurfaceAndState() throws {
        var measurements: [Measurement] = []
        let actions = [.topLeftQuarter] + WindowAction.allCases.filter { WindowActionPartitionGlyph.actions[$0] != nil }
        for site in Site.allCases {
            for state in State.allCases {
                for dark in [false, true] {
                    let native = try ink(action: .leftHalf, site: site, state: state, dark: dark)
                    for action in actions {
                        let actual = try ink(action: action, site: site, state: state, dark: dark)
                        measurements.append(.init(site: site.rawValue, state: state.rawValue, theme: dark ? "dark" : "light",
                                                  action: action.rawValue, native: native, actual: actual))
                        #expect(zip(actual, native).allSatisfy { abs($0 - $1) <= 5 },
                                "\(site.rawValue), \(state.rawValue), \(dark ? "dark" : "light"), \(action): \(actual), native \(native)")
                    }
                }
            }
        }
        if let path = ProcessInfo.processInfo.environment["BT_ACTION_INK_REPORT"] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(measurements).write(to: URL(filePath: path))
        }
    }

    private func ink(action: WindowAction, site: Site, state: State, dark: Bool) throws -> [Int] {
        let background = Color(white: dark ? 0.12 : 0.97)
        let content: AnyView
        let box: CGRect
        switch site {
        case .menu:
            if state == .selected {
                // A menu tile has no persistent selection. Model its pressed
                // plate without sending pointer events: the same glyph and
                // primary style, over the style's card plus 20% accent.
                content = AnyView(HStack {
                    WindowActionGlyph(action: action)
                    Spacer()
                }.padding(.horizontal, 8).frame(width: 156, height: MenuPanelMetrics.tileHeight)
                    .foregroundStyle(.primary)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(PanelSurface.card(for: dark ? .dark : .light))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .fill(Color.accentColor.opacity(0.2)))))
            } else {
                content = AnyView(MenuPanelActionButton(action: action, shortcut: nil, isEnabled: state != .unavailable) {}
                    .frame(width: 156))
            }
            box = CGRect(x: 8, y: (MenuPanelMetrics.tileHeight - 26) / 2, width: 30, height: 26)
        case .wheel:
            var configuration = LayoutWheelConfiguration(levelCount: .two)
            configuration.innerSlots[0] = .windowAction(action)
            let selection = LayoutWheelSelection(ring: .inner, sector: .top)
            let input = LayoutWheelSceneInput(configuration: configuration,
                selection: state == .selected ? selection : nil,
                unavailableCommands: state == .unavailable ? [.windowAction(action)] : [])
            var motion = LayoutWheelMotion()
            motion.retarget(selection: input.selection, fan: input.fan, geometry: input.metrics.fanGeometry, reduceMotion: true)
            content = AnyView(LayoutWheelGlassView(input: input, motion: motion, reduceMotion: true)
                .environment(\.layoutWheelGlassStandIn, .init(body: Color(white: dark ? 0.20 : 0.87), well: background))
                .frame(width: 300, height: 300))
            let point = LayoutWheelDrawnMetrics(input).iconPoint(selection)
            box = CGRect(x: 150 + point.x - 12, y: 150 + point.y - 10, width: 24, height: 20)
        }
        let renderer = ImageRenderer(content: content.background(background)
            .environment(\.colorScheme, dark ? .dark : .light).environment(\.displayScale, 2))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bitmap = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
        var result = [Int](repeating: dark ? 0 : 255, count: 3)
        for y in Int(box.minY * 2) ..< Int(box.maxY * 2) {
            for x in Int(box.minX * 2) ..< Int(box.maxX * 2) {
                let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                let channels = [color.redComponent, color.greenComponent, color.blueComponent]
                for channel in 0 ..< 3 {
                    let value = Int((channels[channel] * 255).rounded())
                    result[channel] = dark ? max(result[channel], value) : min(result[channel], value)
                }
            }
        }
        return result
    }
}
