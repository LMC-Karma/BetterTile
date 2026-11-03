import BetterTileCore
import Foundation

/// Acknowledges the gesture only. Execution feedback belongs to the command's
/// existing result path. No terminal state contains a command or input handler.
enum LayoutWheelAcknowledgment: CaseIterable, Equatable, Sendable {
    case commit, cancel
}

struct LayoutWheelExitPresentation {
    let acknowledgment: LayoutWheelAcknowledgment
    private(set) var elapsed = 0.0
    var duration: Double { acknowledgment == .commit ? 0.20 : 0.15 }
    var isComplete: Bool { elapsed >= duration }
    var opacity: Double {
        let hold = acknowledgment == .commit ? 0.12 : 0.05
        return 1 - min(1, max(0, (elapsed - hold) / (duration - hold)))
    }
    var collapse: Double { acknowledgment == .cancel ? min(1, elapsed / 0.10) : 0 }
    var pulse: Double { acknowledgment == .commit ? sin(.pi * min(1, elapsed / 0.12)) : 0 }

    mutating func advance(_ elapsed: Double) {
        guard elapsed.isFinite, elapsed > 0 else { return }
        self.elapsed = min(duration, self.elapsed + elapsed)
    }
}

/// Cosmetic state only. Neither a spring nor a frame can acquire a command.
struct LayoutWheelSpring {
    private(set) var value: Double = 0
    private(set) var velocity: Double = 0
    var target: Double = 0

    var isAtRest: Bool { abs(value - target) < 0.001 && abs(velocity) < 0.01 }

    mutating func snap() { value = target; velocity = 0 }

    mutating func advance(_ elapsed: Double) {
        guard elapsed.isFinite, elapsed > 0 else { return }
        // Bound wake/suspension intervals, and integrate velocity first. All
        // channels use normalized units (angles use radians).
        let duration = min(elapsed, 0.05)
        let steps = max(1, Int(ceil(duration * 240)))
        let dt = duration / Double(steps)
        // At 60/120 Hz a unit reveal reaches the strict rest thresholds
        // within 120 ms, matching the previous fan's complete easing window.
        let frequency = 2 * Double.pi / 0.06
        for _ in 0..<steps {
            velocity += (-frequency * frequency * (value - target) - 2 * 0.84 * frequency * velocity) * dt
            value += velocity * dt
        }
        if isAtRest { snap() }
    }
}

enum LayoutWheelItemID: Hashable {
    case sector(LayoutWheelSelection)
    case option(LayoutWheelSector, Int)
}

struct LayoutWheelMotion {
    private(set) var highlights: [LayoutWheelItemID: LayoutWheelSpring] = [:]
    private(set) var reveals = Array(repeating: LayoutWheelSpring(), count: 8)
    private(set) var angle = LayoutWheelSpring()
    private(set) var strength = LayoutWheelSpring()
    private(set) var lean = LayoutWheelSpring()
    private var hasAim = false

    var isAtRest: Bool {
        angle.isAtRest && strength.isAtRest && lean.isAtRest && reveals.allSatisfy(\.isAtRest)
            && highlights.values.allSatisfy(\.isAtRest)
    }

    /// `openParent` is the icon that owns the open submenu. It stays highlighted while the
    /// submenu is open, also when an option is aimed or no ring icon is selected.
    mutating func retarget(selection: LayoutWheelSelection?, fan: LayoutWheelFanState,
                           geometry: LayoutWheelFanGeometry, reduceMotion: Bool, suppressLean: Bool = false,
                           openParent: LayoutWheelSelection? = nil) {
        var selected: Set<LayoutWheelItemID> = []
        if let sector = fan.openSector {
            if let owner = openParent ?? selection { selected.insert(.sector(owner)) }
            if let option = fan.optionIndex { selected.insert(.option(sector, option)) }
        } else if let selection {
            selected.insert(.sector(selection))
        }
        for id in Array(highlights.keys) { highlights[id]?.target = selected.contains(id) ? 1 : 0 }
        for id in selected where highlights[id] == nil {
            var spring = LayoutWheelSpring()
            spring.target = 1
            highlights[id] = spring
        }
        for sector in LayoutWheelSector.allCases {
            reveals[sector.rawValue].target = fan.openSector == sector ? 1 : 0
        }
        if let selection {
            let aim = if let sector = fan.openSector, let option = fan.optionIndex {
                geometry.angle(sector: sector, option: option) - Double.pi / 2
            } else { selection.sector.drawnCenterAngle.radians }
            angle.target = angle.value + atan2(sin(aim - angle.value), cos(aim - angle.value))
            if !hasAim { angle.snap(); hasAim = true }
        }
        strength.target = selection == nil ? 0 : (selection?.ring == .inner ? 0.35 : 1)
        lean.target = selection == nil || suppressLean ? 0 : 1
        if reduceMotion { snap() }
    }

    mutating func snap() {
        angle.snap(); strength.snap(); lean.snap()
        for id in Array(highlights.keys) { highlights[id]?.snap() }
        for index in reveals.indices { reveals[index].snap() }
    }

    mutating func advance(_ elapsed: Double) {
        angle.advance(elapsed); strength.advance(elapsed); lean.advance(elapsed)
        for id in Array(highlights.keys) { highlights[id]?.advance(elapsed) }
        for index in reveals.indices { reveals[index].advance(elapsed) }
    }
}
