import Foundation
import Testing
@testable import BetterTileCore

private let bounds = BTRect(x: 0, y: 0, width: 1920, height: 983)

private func inset(_ rect: BTRect, by margin: Double) -> BTRect {
    BTRect(
        x: rect.minX + margin,
        y: rect.minY + margin,
        width: rect.size.width - margin * 2,
        height: rect.size.height - margin * 2
    )
}

private func halves() -> (left: BTRect, right: BTRect) {
    (
        BTRect(x: 0, y: 0, width: 960, height: 983),
        BTRect(x: 960, y: 0, width: 960, height: 983)
    )
}

// MARK: - Recognising the margin

@Test(arguments: [4.0, 7.0, 10.0, 16.0])
func aUniformInsetIsRecognisedAsATilingMargin(margin: Double) {
    let (left, right) = halves()
    let observed = [inset(left, by: margin), inset(right, by: margin)]
    let inferred = TiledMargin.infer(observed, in: bounds)
    #expect(inferred != nil)
    #expect(abs((inferred ?? 0) - margin) <= 0.001)
}

@Test func agaplessArrangementHasNoMargin() {
    let (left, right) = halves()
    #expect(TiledMargin.infer([left, right], in: bounds) == nil)
}

/// A gap on one side is a gap the user made, not a tiling margin. Adopting it
/// as one would silently discard their arrangement.
@Test func aOneSidedGapIsNotAMargin() {
    let observed = [
        BTRect(x: 200, y: 0, width: 760, height: 983),
        BTRect(x: 960, y: 0, width: 960, height: 983),
    ]
    #expect(TiledMargin.infer(observed, in: bounds) == nil)
}

@Test func anInsetTooWideToBeAMarginIsRejected() {
    let (left, right) = halves()
    let observed = [inset(left, by: 40), inset(right, by: 40)]
    #expect(TiledMargin.infer(observed, in: bounds) == nil)
}

@Test func aSingleFilledWindowCarriesTheMarginToo() {
    let inferred = TiledMargin.infer([inset(bounds, by: 7)], in: bounds)
    #expect(abs((inferred ?? 0) - 7) <= 0.001)
}

@Test func removingTheMarginRestoresTheUnderlyingFrame() {
    let (left, _) = halves()
    #expect(TiledMargin.removing(7, from: inset(left, by: 7)).approximatelyEquals(left, tolerance: 0.001))
}

@Test func degenerateBoundsInferNoMargin() {
    #expect(TiledMargin.infer([bounds], in: BTRect(x: 0, y: 0, width: 0, height: 0)) == nil)
    #expect(TiledMargin.infer([], in: bounds) == nil)
}

// MARK: - Adopting a macOS-tiled desktop

private let a = WindowID(rawValue: "a")
private let b = WindowID(rawValue: "b")
private let c = WindowID(rawValue: "c")

/// The behaviour the whole margin story exists for: a desktop tiled by macOS,
/// at the default margin setting, is recognised rather than rearranged.
@Test(arguments: [0.0, 4.0, 7.0, 10.0])
func aMacOSTiledPairIsAdopted(margin: Double) throws {
    let (left, right) = halves()
    let observed: [WindowID: BTRect] = margin == 0
        ? [a: left, b: right]
        : [a: inset(left, by: margin), b: inset(right, by: margin)]

    let state = try #require(
        BentoLayoutAdopter(tolerance: 6).adopt(frames: observed, in: bounds),
        "a macOS-tiled pair at margin \(margin) was not adopted"
    )
    let placed = Dictionary(uniqueKeysWithValues: state.placements(in: bounds).map { ($0.windowID, $0.frame) })
    #expect(placed[a]?.approximatelyEquals(left, tolerance: 1) == true)
    #expect(placed[b]?.approximatelyEquals(right, tolerance: 1) == true)
}

/// Recognised, then discarded. The adopted layout uses the gaps the user
/// configured, not the ones macOS happened to apply.
@Test func themacOSMarginIsNotPreservedInTheAdoptedLayout() throws {
    let (left, right) = halves()
    let observed: [WindowID: BTRect] = [a: inset(left, by: 7), b: inset(right, by: 7)]

    let gapless = try #require(BentoLayoutAdopter().adopt(frames: observed, in: bounds))
    #expect(gapless.metrics.paneGap == 0)
    let placed = gapless.placements(in: bounds)
    #expect(placed.contains { $0.frame.approximatelyEquals(left, tolerance: 1) })

    let withUserGap = try #require(
        BentoLayoutAdopter().adopt(frames: observed, in: bounds, metrics: BentoLayoutMetrics(paneGap: 12))
    )
    #expect(withUserGap.metrics.paneGap == 12, "the user's gap replaces macOS's margin")
}

@Test func aMacOSTiledQuartetIsAdopted() throws {
    let quarters: [WindowID: BTRect] = [
        a: BTRect(x: 0, y: 0, width: 960, height: 491.5),
        b: BTRect(x: 960, y: 0, width: 960, height: 491.5),
        c: BTRect(x: 0, y: 491.5, width: 960, height: 491.5),
        WindowID(rawValue: "d"): BTRect(x: 960, y: 491.5, width: 960, height: 491.5),
    ]
    let observed = quarters.mapValues { inset($0, by: 7) }
    let state = try #require(BentoLayoutAdopter(tolerance: 6).adopt(frames: observed, in: bounds))
    let placed = Dictionary(uniqueKeysWithValues: state.placements(in: bounds).map { ($0.windowID, $0.frame) })
    for (id, expected) in quarters {
        #expect(placed[id]?.approximatelyEquals(expected, tolerance: 1) == true, "\(id) was not adopted")
    }
}

/// An arrangement that does not actually tile the display must still be
/// refused, margin or not. Adoption stays strict.
@Test func anOverlappingArrangementIsStillRefused() {
    let observed: [WindowID: BTRect] = [
        a: BTRect(x: 7, y: 7, width: 946, height: 969),
        b: BTRect(x: 400, y: 7, width: 946, height: 969),
    ]
    #expect(BentoLayoutAdopter(tolerance: 6).adopt(frames: observed, in: bounds) == nil)
}

@Test func anArrangementLeavingAHoleIsStillRefused() {
    let observed: [WindowID: BTRect] = [
        a: BTRect(x: 7, y: 7, width: 500, height: 969),
        b: BTRect(x: 967, y: 7, width: 946, height: 969),
    ]
    #expect(BentoLayoutAdopter(tolerance: 6).adopt(frames: observed, in: bounds) == nil)
}
