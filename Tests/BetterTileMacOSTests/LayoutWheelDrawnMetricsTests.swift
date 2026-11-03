import AppKit
import Testing
import SwiftUI
@testable import BetterTileCore
@testable import BetterTileMacOS

@Suite(.macOSTestApplication) struct LayoutWheelDrawnMetricsTests {
    enum HoverCase: CaseIterable, Sendable {
        case customOne, customTwoInner, customTwoOuter, groupedTwoInner, groupedTwoOuter

        var configuration: LayoutWheelConfiguration {
            .init(style: self == .groupedTwoInner || self == .groupedTwoOuter ? .grouped : .custom,
                  levelCount: self == .customOne ? .one : .two)
        }
        var ring: LayoutWheelRing {
            self == .customTwoOuter || self == .groupedTwoOuter ? .outer : .inner
        }
        var bulge: Double { ring == .inner && self != .customOne ? 5 : 8 }
    }

    @MainActor @Test(arguments: HoverCase.allCases, [0.8, 1.0, 1.2])
    func settledHoverReachesSpecifiedBulgeAndLean(hoverCase: HoverCase, scale: Double) {
        var configuration = hoverCase.configuration
        configuration.scale = scale
        let selection = LayoutWheelSelection(ring: hoverCase.ring, sector: .right)
        let input = LayoutWheelSceneInput(configuration: configuration, selection: selection)
        var motion = LayoutWheelMotion()
        motion.retarget(selection: selection, fan: input.fan, geometry: input.metrics.fanGeometry, reduceMotion: false)
        for _ in 0..<120 { motion.advance(1 / 120) }
        #expect(motion.isAtRest)
        let view = LayoutWheelGlassView(input: input, motion: motion)
        #expect(abs(view.bulge - hoverCase.bulge * scale) < 0.0001)
        #expect(abs(hypot(view.lean.x, view.lean.y) - 4 * scale) < 0.0001)
        let reduced = LayoutWheelGlassView(input: input, motion: motion, reduceMotion: true)
        #expect(reduced.bulge == 0 && reduced.lean == .init(x: 0, y: 0))
    }

    @MainActor @Test(arguments: HoverCase.allCases, [0.8, 1.0, 1.2])
    func oppositeSectorLensFramesNeverIntersectTheFixedWell(hoverCase: HoverCase, scale: Double) {
        var configuration = hoverCase.configuration
        configuration.scale = scale
        for hz in [60.0, 120.0] {
            for sector in LayoutWheelSector.allCases {
                let start = LayoutWheelSelection(ring: hoverCase.ring, sector: sector)
                let opposite = LayoutWheelSector.allCases[(sector.rawValue + 4) % 8]
                let end = LayoutWheelSelection(ring: hoverCase.ring, sector: opposite)
                var input = LayoutWheelSceneInput(configuration: configuration, selection: start)
                let drawn = LayoutWheelDrawnMetrics(input)
                var motion = LayoutWheelMotion()
                motion.retarget(selection: start, fan: input.fan, geometry: input.metrics.fanGeometry, reduceMotion: false)
                for _ in 0..<Int(hz) { motion.advance(1 / hz) }
                #expect(motion.isAtRest)
                input.selection = end
                motion.retarget(selection: end, fan: input.fan, geometry: input.metrics.fanGeometry, reduceMotion: false)
                for _ in 0...Int(hz / 4) {
                    let view = LayoutWheelGlassView(input: input, motion: motion)
                    for selection in [start, end] where (motion.highlights[.sector(selection)]?.value ?? 0) > 0.001 {
                        let center = drawn.iconPoint(selection, lean: view.lean)
                        let radius = view.lensRadius(selection)
                        // Include the lens's centred 1 pt outline, not just its fill.
                        #expect(hypot(center.x, center.y) - radius - 0.5 >= drawn.wellRadius - 0.0001)
                        #expect(radius > 0 && radius <= drawn.lensRadius(selection.ring))
                    }
                    motion.advance(1 / hz)
                }
                #expect(motion.isAtRest)
            }
        }
    }

    private func inputs() -> [LayoutWheelSceneInput] {
        [0.8, 1.0, 1.2].flatMap { scale in
            [(LayoutWheelStyle.custom, LayoutWheelLevelCount.one), (.custom, .two), (.grouped, .two)].map { style, level in
                var configuration = LayoutWheelConfiguration(style: style, levelCount: level)
                configuration.scale = scale
                return .init(configuration: configuration)
            }
        }
    }

    @MainActor @Test func iconCentersMapToTheirSectorsAtEveryHoverFrame() {
        for input in inputs() {
            let drawn = LayoutWheelDrawnMetrics(input)
            let geometry = input.metrics.geometry(for: drawn.levelCount)
            for ring in input.configuration.activeRings {
                for sector in LayoutWheelSector.allCases {
                    let selection = LayoutWheelSelection(ring: ring, sector: sector)
                    for symbol in ["rectangle.lefthalf.filled", "arrow.left", "arrow.right", "arrow.up", "arrow.down"] {
                        for frame in 0...30 {
                            var motion = LayoutWheelMotion()
                            motion.retarget(selection: selection, fan: .init(), geometry: input.metrics.fanGeometry, reduceMotion: false)
                            for _ in 0..<frame { motion.advance(1 / 120) }
                            var selectedInput = input
                            selectedInput.selection = selection
                            let view = LayoutWheelGlassView(input: selectedInput, motion: motion)
                            let lean = view.lean
                            let point = drawn.iconPoint(selection, symbol: symbol,
                                hover: motion.highlights[.sector(selection)]?.value ?? 0, lean: lean)
                            #expect(geometry.selection(for: point, levelCount: drawn.levelCount) == selection)
                            // Every icon shares the lean, including those opposite
                            // the selected sector. The selected point is not enough.
                            for otherRing in input.configuration.activeRings {
                                for otherSector in LayoutWheelSector.allCases {
                                    let other = LayoutWheelSelection(ring: otherRing, sector: otherSector)
                                    let otherPoint = drawn.iconPoint(other, symbol: symbol, lean: lean)
                                    #expect(geometry.selection(for: otherPoint, levelCount: drawn.levelCount) == other)
                                }
                            }
                            #expect(view.bulge <= 8 * drawn.scale)
                        }
                    }
                }
            }
        }
    }

    @Test func separatorsRemainInsideTheHitBandsAndClearAllEdges() {
        for input in inputs() {
            let drawn = LayoutWheelDrawnMetrics(input)
            #expect(drawn.separators.count == (drawn.levelCount == .two ? 16 : 8))
            for separator in drawn.separators {
                #expect(separator.startRadius >= drawn.wellRadius + 4 * drawn.scale - 0.0001)
                #expect(separator.endRadius <= drawn.outerRadius - 4 * drawn.scale + 0.0001)
                if let step = drawn.stepRadius {
                    #expect(separator.endRadius <= step - 4 * drawn.scale || separator.startRadius >= step + 4 * drawn.scale)
                    #expect(separator.endRadius < input.metrics.geometry.innerRingOuterRadius
                        || separator.startRadius > input.metrics.geometry.outerRingInnerRadius)
                }
                for fraction in [0.0, 0.1, 0.5, 0.9, 1.0] {
                    let radius = separator.startRadius + fraction * (separator.endRadius - separator.startRadius)
                    let point = drawn.point(radius: radius, angle: separator.angle)
                    #expect(input.metrics.geometry(for: drawn.levelCount).selection(for: point, levelCount: drawn.levelCount) != nil)
                }
            }
            #expect(drawn.separatorWidth == 1 && drawn.edgeWidth == 1.2)
        }
    }

    @Test func lensesFitEvenTheShallowCustomInnerBand() {
        for input in inputs() {
            let drawn = LayoutWheelDrawnMetrics(input)
            for ring in input.configuration.activeRings {
                let center = input.metrics.iconRadius(for: ring, levelCount: drawn.levelCount)
                #expect(center - drawn.lensRadius(ring) >= input.metrics.innerRadius(for: ring) + drawn.scale - 0.0001)
                #expect(center + drawn.lensRadius(ring) <= input.metrics.outerRadius(for: ring, levelCount: drawn.levelCount) - drawn.scale + 0.0001)
            }
            if input.configuration.style == .custom && drawn.levelCount == .two {
                #expect(abs(drawn.lensRadius(.inner) - 17 * drawn.scale) < 0.0001)
            }
        }
    }

    @Test func wellAndCancelCircleAgreeAtEverySize() {
        for input in inputs() {
            let drawn = LayoutWheelDrawnMetrics(input)
            let geometry = input.metrics.geometry(for: drawn.levelCount)
            #expect(abs(drawn.wellRadius - 32 * input.configuration.scale) < 0.0001)
            for sector in LayoutWheelSector.allCases {
                #expect(geometry.selection(for: drawn.point(radius: 31.9 * drawn.scale,
                    angle: sector.drawnCenterAngle.radians), levelCount: drawn.levelCount) == nil)
                #expect(geometry.selection(for: drawn.point(radius: 32.1 * drawn.scale,
                    angle: sector.drawnCenterAngle.radians), levelCount: drawn.levelCount)?.sector == sector)
            }
        }
    }

    @Test func opticalArrowTableShiftsAwayFromTheHeadOnly() {
        let shifts = ["arrow.left": BTPoint(x: 0.6, y: 0), "arrow.right": BTPoint(x: -0.6, y: 0),
                      "arrow.up": BTPoint(x: 0, y: 0.6), "arrow.down": BTPoint(x: 0, y: -0.6)]
        for (name, expected) in shifts { #expect(LayoutWheelDrawnMetrics.opticalShift(name, symbolSize: 18) == expected) }
        #expect(LayoutWheelDrawnMetrics.opticalShift("rectangle.lefthalf.filled", symbolSize: 18) == .init(x: 0, y: 0))
    }

    @Test func everyFallbackAndSeparatorOpacity() {
        for glass in [false, true] {
            for transparency in [false, true] {
                for contrast in [false, true] {
                    let treatment = LayoutWheelGlassTreatment(useLiquidGlass: glass, reduceTransparency: transparency, increasedContrast: contrast)
                    #expect(treatment.useGlass == (glass && !transparency && !contrast))
                    for dark in [false, true] {
                        let base = treatment.useGlass ? (dark ? 0.12 : 0.10) : (dark ? 0.16 : 0.14)
                        #expect(treatment.separatorOpacity(dark: dark, fanOpen: false) == base * (contrast ? 2 : 1))
                        #expect(treatment.separatorOpacity(dark: dark, fanOpen: true) == base * (contrast ? 2 : 1) / 2)
                    }
                }
            }
        }
        #expect(LayoutWheelGlassTreatment.strength == 0.3)
    }

    @Test func bodyHoleStaysOnTheCancelCircleDuringLean() {
        let input = LayoutWheelSceneInput(configuration: .init())
        let drawn = LayoutWheelDrawnMetrics(input)
        for sector in LayoutWheelSector.allCases {
            let lean = drawn.lean(angle: sector.drawnCenterAngle.radians, strength: 1, reduceMotion: false)
            let shape = LayoutWheelBodyShape(innerRadius: drawn.wellRadius, outerRadius: drawn.outerRadius,
                                            wellOffset: .init(width: -lean.x, height: -lean.y))
            let path = shape.path(in: .init(x: lean.x, y: lean.y, width: 300, height: 300))
            // Probe off the lines through the well centre. The hole's arc
            // segments join on those lines. For the same path, macOS 26 and
            // macOS 27 return different `contains` results on them.
            func probe(_ radius: Double) -> CGPoint {
                .init(x: 150 + cos(0.3) * radius, y: 150 + sin(0.3) * radius)
            }
            #expect(!path.contains(probe(1)), "\(sector)")
            #expect(!path.contains(probe(31.9)), "\(sector)")
            #expect(path.contains(probe(32.1)), "\(sector)")
            // The wheel fills this shape. The filled pixels must leave the
            // well open and cover the ring.
            #expect(!filled(path, x: 150, y: 150), "\(sector)")
            #expect(filled(path, x: 210, y: 150), "\(sector)")
            #expect(drawn.lean(angle: 0, strength: 1, reduceMotion: true) == .init(x: 0, y: 0))
            #expect(drawn.bulge(fanOpen: true, inner: false, strength: 1, reduceMotion: true) == 0)
        }
    }

    /// Fills `path` with the nonzero rule into a 300-point bitmap and reads one pixel.
    private func filled(_ path: Path, x: Int, y: Int) -> Bool {
        guard let context = CGContext(data: nil, width: 300, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
        context.setFillColor(gray: 1, alpha: 1)
        context.addPath(path.cgPath)
        context.fillPath(using: .winding)
        // Bitmap memory starts at the top row; user space starts at the bottom.
        let offset = (299 - y) * context.bytesPerRow + x
        return context.data.map { $0.load(fromByteOffset: offset, as: UInt8.self) > 127 } ?? false
    }
}
