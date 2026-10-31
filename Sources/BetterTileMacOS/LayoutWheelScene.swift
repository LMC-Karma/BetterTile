import AppKit
import BetterTileCore
import SwiftUI

struct LayoutWheelSceneInput: Equatable {
    var configuration: LayoutWheelConfiguration
    var appearance: OverlayAppearance = .init()
    var selection: LayoutWheelSelection?
    var unavailableCommands: Set<LayoutWheelCommand> = []
    var fan: LayoutWheelFanState = .init()
    var layoutAvailable = true
    /// The target desktop's mode, used to draw the Mode parent's icon.
    var currentMode: LayoutMode?
    var reservesFanSpace = true
    var customMetrics: LayoutWheelMetrics = .standard

    var metrics: LayoutWheelMetrics {
        (configuration.style == .grouped ? .grouped : customMetrics).scaled(by: configuration.scale)
    }
    var diameter: Double {
        configuration.style == .grouped && reservesFanSpace ? metrics.groupedPresentationDiameter
            : metrics.presentationDiameter(for: configuration.effectiveLevelCount)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.configuration == rhs.configuration && lhs.appearance == rhs.appearance
            && lhs.selection == rhs.selection && lhs.unavailableCommands == rhs.unavailableCommands
            && lhs.fan == rhs.fan && lhs.layoutAvailable == rhs.layoutAvailable
            && lhs.currentMode == rhs.currentMode
            && lhs.reservesFanSpace == rhs.reservesFanSpace
            && lhs.customMetrics.signature == rhs.customMetrics.signature
    }

    init(configuration: LayoutWheelConfiguration, appearance: OverlayAppearance = .init(),
         selection: LayoutWheelSelection? = nil, unavailableCommands: Set<LayoutWheelCommand> = [],
         fan: LayoutWheelFanState = .init(), layoutAvailable: Bool = true,
         currentMode: LayoutMode? = nil,
         reservesFanSpace: Bool = true, customMetrics: LayoutWheelMetrics = .standard) {
        self.configuration = configuration; self.appearance = appearance; self.selection = selection
        self.unavailableCommands = unavailableCommands; self.fan = fan; self.layoutAvailable = layoutAvailable
        self.currentMode = currentMode
        self.reservesFanSpace = reservesFanSpace; self.customMetrics = customMetrics
    }

    init(_ presentation: LayoutWheelPresentation) {
        self.init(configuration: presentation.configuration, appearance: presentation.overlayAppearance,
                  selection: presentation.selection, unavailableCommands: presentation.unavailableCommands,
                  fan: presentation.fan, layoutAvailable: presentation.layoutAvailable,
                  currentMode: presentation.currentMode)
    }

    func slot(_ id: LayoutWheelItemID) -> LayoutWheelSlot {
        switch id {
        case let .option(sector, index):
            let options = configuration.group(at: sector).options
            let command = options.indices.contains(index) ? options[index] : nil
            return .init(command: command, isAvailable: command.map { !unavailableCommands.contains($0) } ?? false)
        case let .sector(selection):
            if configuration.style == .grouped, selection.ring == configuration.groupRing {
                let group = LayoutWheelGroup.at(selection.sector)
                let contents = configuration.group(at: selection.sector)
                let commands = contents.options.compactMap { $0 } + (contents.quickAction.map { [$0] } ?? [])
                let available = commands.contains {
                    if case .chooseLayout = $0, !layoutAvailable { return false }
                    return !unavailableCommands.contains($0)
                }

                if let command = contents.quickAction { return .init(command: command, isAvailable: available) }
                return .init(label: group.title, symbolName: group.symbolName,
                             glyph: group.glyph(currentMode: currentMode), isEmpty: false,
                             isAvailable: available)
            }
            let command = configuration.command(at: selection)
            return .init(command: command, isAvailable: command.map { !unavailableCommands.contains($0) } ?? false)
        }
    }
}

private extension LayoutWheelMetrics {
    var signature: [Double] {
        [geometry.hubRadius, geometry.innerRingOuterRadius, geometry.outerRingInnerRadius,
         outerRingOuterRadius, oneLevelInnerRingOuterRadius]
    }
}

@MainActor protocol LayoutWheelFrameClock: AnyObject {
    var isRunning: Bool { get }
    func start(on view: NSView, tick: @escaping (Double) -> Void)
    func stop()
}

/// Public AppKit display link, with no timer or callback left installed at rest.
@MainActor final class LayoutWheelDisplayClock: NSObject, LayoutWheelFrameClock {
    private var link: CADisplayLink?
    private var tick: ((Double) -> Void)?
    var isRunning: Bool { link != nil }

    func start(on view: NSView, tick: @escaping (Double) -> Void) {
        guard link == nil else { return }
        self.tick = tick
        let link = view.displayLink(target: self, selector: #selector(frame(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        self.link = link
        link.add(to: .main, forMode: .common)
        link.add(to: .main, forMode: .eventTracking)
    }
    func stop() { link?.invalidate(); link = nil; tick = nil }
    @objc private func frame(_ link: CADisplayLink) { tick?(link.timestamp) }
}
