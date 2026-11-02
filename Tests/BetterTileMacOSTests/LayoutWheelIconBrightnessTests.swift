import AppKit
import Metal
import SwiftUI
import Testing
@_spi(LiquidWheelPrototype) @testable import BetterTileCore
@_spi(LiquidWheelPrototype) @testable import BetterTileMacOS

/// Icon brightness and highlight for each slice, in each state of a gesture:
///
/// - open, nothing aimed: every icon is bright;
/// - a submenu open: the other icons dim, and the icon that owns the submenu stays bright and highlighted;
/// - submenu closed: every icon is bright again.
///
/// Custom has no submenu, so its icons never dim.
@MainActor @Suite(.macOSTestApplication, .serialized) struct LayoutWheelIconBrightnessTests {
    enum Phase: String, CaseIterable, Sendable {
        case open, hovering, submenuOpen, childAimed, submenuOpenWithoutSelection, closedAgain
    }

    struct Case: Sendable, CustomStringConvertible {
        var style: LayoutWheelStyle
        var levels: LayoutWheelLevelCount
        var phase: Phase
        var description: String { "\(style) \(levels) \(phase)" }
    }

    nonisolated static let cases: [Case] = [LayoutWheelStyle.custom, .grouped].flatMap { style in
        [LayoutWheelLevelCount.one, .two].flatMap { levels in
            Phase.allCases.filter { style == .grouped || [.open, .hovering].contains($0) }
                .map { Case(style: style, levels: levels, phase: $0) }
        }
    }

    private static let sector = LayoutWheelSector.top

    private func configuration(_ item: Case) -> LayoutWheelConfiguration {
        LayoutWheelConfiguration(style: item.style, levelCount: item.levels)
    }

    private func parent(_ configuration: LayoutWheelConfiguration) -> LayoutWheelSelection {
        .init(ring: configuration.groupRing, sector: Self.sector)
    }

    /// The state the gesture reports for a phase.
    private func state(_ item: Case) -> LayoutWheelLiquidState {
        let configuration = configuration(item)
        let top = parent(configuration)
        switch item.phase {
        case .open, .closedAgain: return .init()
        case .hovering: return .init(selection: top)
        case .submenuOpen: return .init(selection: top, openSector: Self.sector)
        case .childAimed: return .init(selection: top, openSector: Self.sector, aimedOption: 0)
        case .submenuOpenWithoutSelection: return .init(selection: nil, openSector: Self.sector, aimedOption: 0)
        }
    }

    /// Whether the phase has a submenu open, and which icon owns it.
    private func openParent(_ item: Case) -> LayoutWheelSelection? {
        switch item.phase {
        case .submenuOpen, .childAimed, .submenuOpenWithoutSelection: parent(configuration(item))
        default: nil
        }
    }

    /// The icon the pointer or the submenu singles out, if any.
    private func highlighted(_ item: Case) -> LayoutWheelSelection? {
        openParent(item) ?? (item.phase == .hovering ? parent(configuration(item)) : nil)
    }

    // MARK: Liquid renderer

    @Test(.liquidPipeline, arguments: cases) func liquidIconsFollowTheBrightnessRules(item: Case) throws {
        try #require(MTLCreateSystemDefaultDevice() != nil)
        let presenter = LayoutWheelLiquidPresenter(clock: WheelTestClock())
        presenter.dark = true
        let configuration = configuration(item)
        let content = LayoutWheelLiquidContent(configuration: configuration, levelCount: item.levels)
        #expect(presenter.prepareToOpen(content))
        let atlas = try #require(presenter.atlasForTesting)
        var model = LayoutWheelLiquid(layout: content.layout)
        model.open()
        func settle(_ state: LayoutWheelLiquidState) {
            model.update(content.liquidInput(state))
            for _ in 0..<480 where !model.isAtRest { model.advance(1 / 120) }
        }
        if item.phase == .closedAgain {
            // The submenu opened, then closed.
            settle(.init(selection: parent(configuration), openSector: Self.sector, aimedOption: 0))
        }
        let current = state(item)
        settle(current)
        var sprites: [SIMD4<Float>] = []
        LayoutWheelLiquidPresenter.fillSprites(&sprites, model: model, content: content, state: current, atlas: atlas)
        for (ringIndex, ring) in content.rings.enumerated() {
            for sector in LayoutWheelSector.allCases {
                let key = LayoutWheelLiquidAtlas.Key.ring(ringIndex, sector.rawValue)
                let uv = try #require(atlas.entries[key]).uv
                let sprite = try #require(stride(from: 0, to: sprites.count, by: 3).first { sprites[$0 + 1] == uv })
                let opacity = Double(sprites[sprite + 2].y), tint = Double(sprites[sprite + 2].z)
                let selection = LayoutWheelSelection(ring: ring.ring, sector: sector)
                let base = ring.slots[sector.rawValue].isAvailable ? 1.0 : 0.35
                let isOwner = openParent(item) == selection
                let dims = openParent(item) != nil && !isOwner
                let name = "\(item) \(ring.ring) \(sector)"
                #expect(abs(opacity - base * (dims ? 0.5 : 1)) < 1e-6, "brightness \(name): \(opacity)")
                #expect(abs(tint - (highlighted(item) == selection ? 1 : 0)) < 1e-6, "highlight \(name): \(tint)")
            }
        }
    }

    // MARK: Glass (panel) renderer

    private func glass(_ item: Case) -> (LayoutWheelSceneInput, LayoutWheelMotion) {
        let configuration = configuration(item)
        var input = LayoutWheelSceneInput(configuration: configuration)
        let geometry = input.metrics.fanGeometry
        var motion = LayoutWheelMotion()
        func settle() {
            motion.retarget(selection: input.selection, fan: input.fan, geometry: geometry, reduceMotion: false,
                            openParent: input.fan.openSector.map { .init(ring: configuration.groupRing, sector: $0) })
            for _ in 0..<240 { motion.advance(1 / 120) }
        }
        let top = parent(configuration)
        let toParent = BTPoint(x: 0, y: -124 * configuration.scale)
        switch item.phase {
        case .open: break
        case .hovering:
            input.selection = top
        case .submenuOpen, .childAimed, .submenuOpenWithoutSelection, .closedAgain:
            input.fan.update(vector: toParent, at: 0, geometry: geometry)
            input.fan.update(vector: toParent, at: 0.2, geometry: geometry)
            if item.phase != .submenuOpen, item.phase != .closedAgain {
                input.fan.update(vector: geometry.point(sector: .top, option: 0), at: 0.21, geometry: geometry)
            }
            input.selection = input.fan.selection
            if item.phase == .closedAgain {
                settle()
                input.fan.cancel()
                input.selection = nil
            }
        }
        settle()
        return (input, motion)
    }

    @Test(arguments: cases.filter { $0.phase != .submenuOpenWithoutSelection })
    func glassIconsFollowTheBrightnessRules(item: Case) {
        let (input, motion) = glass(item)
        let view = LayoutWheelGlassView(input: input, motion: motion)
        let owner = input.fan.openSector.map { LayoutWheelSelection(ring: input.configuration.groupRing, sector: $0) }
        #expect((owner != nil) == (openParent(item) != nil), "\(item): the fan is \(owner == nil ? "closed" : "open")")
        for ring in input.configuration.activeRings {
            for sector in LayoutWheelSector.allCases {
                let selection = LayoutWheelSelection(ring: ring, sector: sector)
                let slot = input.slot(.sector(selection))
                let base = slot.isAvailable ? 1.0 : 0.35
                let dims = owner != nil && owner != selection
                let name = "\(item) \(ring) \(sector)"
                #expect(abs(view.iconOpacity(slot: slot, selection: selection) - base * (dims ? 0.42 : 1)) < 1e-9,
                        "brightness \(name)")
                let highlight = motion.highlights[.sector(selection)]?.value ?? 0
                #expect(abs(highlight - (highlighted(item) == selection ? 1 : 0)) < 1e-6, "highlight \(name): \(highlight)")
            }
        }
    }
}
