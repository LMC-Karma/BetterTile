import Foundation

public enum WindowAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case leftThird, centerThird, rightThird
    case leftTwoThirds, rightTwoThirds
    case topLeftQuarter, topRightQuarter, bottomLeftQuarter, bottomRightQuarter
    case topLeftSixth, topCenterSixth, topRightSixth
    case bottomLeftSixth, bottomCenterSixth, bottomRightSixth
    case maximize, almostMaximize, center, centerResize
    case previousDisplay, nextDisplay
    case moveLeft, moveRight, moveUp, moveDown
    case growWidth, shrinkWidth, growHeight, shrinkHeight
    case restore

    public var id: String { rawValue }

    public var title: String {
        rawValue
            .reduce(into: "") { result, character in
                if character.isUppercase { result.append(" ") }
                result.append(character)
            }
            .capitalized
    }

    public var isDisplayTransfer: Bool { self == .previousDisplay || self == .nextDisplay }
    public var isRestore: Bool { self == .restore }
}

public struct CustomZone: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var rect: NormalizedRect

    public init(id: UUID = UUID(), name: String, rect: NormalizedRect) {
        self.id = id
        self.name = name
        self.rect = rect
    }
}

public struct StandardActionEngine: Sendable {
    public var movementIncrement: Double
    public var resizeIncrement: Double
    public var almostMaximizeInset: Double
    public var centerResizeFraction: Double

    public init(
        movementIncrement: Double = 40,
        resizeIncrement: Double = 40,
        almostMaximizeInset: Double = 24,
        centerResizeFraction: Double = 0.8
    ) {
        self.movementIncrement = movementIncrement
        self.resizeIncrement = resizeIncrement
        self.almostMaximizeInset = almostMaximizeInset
        self.centerResizeFraction = centerResizeFraction
    }

    public func targetFrame(for action: WindowAction, window: WindowSnapshot, display: DisplaySnapshot) -> BTRect? {
        let bounds = display.visibleFrame
        let normalized: NormalizedRect? = switch action {
        case .leftHalf: .init(x: 0, y: 0, width: 0.5, height: 1)
        case .rightHalf: .init(x: 0.5, y: 0, width: 0.5, height: 1)
        case .topHalf: .init(x: 0, y: 0, width: 1, height: 0.5)
        case .bottomHalf: .init(x: 0, y: 0.5, width: 1, height: 0.5)
        case .leftThird: .init(x: 0, y: 0, width: 1.0 / 3, height: 1)
        case .centerThird: .init(x: 1.0 / 3, y: 0, width: 1.0 / 3, height: 1)
        case .rightThird: .init(x: 2.0 / 3, y: 0, width: 1.0 / 3, height: 1)
        case .leftTwoThirds: .init(x: 0, y: 0, width: 2.0 / 3, height: 1)
        case .rightTwoThirds: .init(x: 1.0 / 3, y: 0, width: 2.0 / 3, height: 1)
        case .topLeftQuarter: .init(x: 0, y: 0, width: 0.5, height: 0.5)
        case .topRightQuarter: .init(x: 0.5, y: 0, width: 0.5, height: 0.5)
        case .bottomLeftQuarter: .init(x: 0, y: 0.5, width: 0.5, height: 0.5)
        case .bottomRightQuarter: .init(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        case .topLeftSixth: .init(x: 0, y: 0, width: 1.0 / 3, height: 0.5)
        case .topCenterSixth: .init(x: 1.0 / 3, y: 0, width: 1.0 / 3, height: 0.5)
        case .topRightSixth: .init(x: 2.0 / 3, y: 0, width: 1.0 / 3, height: 0.5)
        case .bottomLeftSixth: .init(x: 0, y: 0.5, width: 1.0 / 3, height: 0.5)
        case .bottomCenterSixth: .init(x: 1.0 / 3, y: 0.5, width: 1.0 / 3, height: 0.5)
        case .bottomRightSixth: .init(x: 2.0 / 3, y: 0.5, width: 1.0 / 3, height: 0.5)
        default: nil
        }

        if let normalized {
            return normalized.frame(in: bounds).clamped(to: bounds, minimumSize: window.constraints.minimumSize)
        }

        let current = window.frame
        let result: BTRect?
        switch action {
        case .maximize:
            result = bounds
        case .almostMaximize:
            result = bounds.insetBy(dx: almostMaximizeInset, dy: almostMaximizeInset)
        case .center:
            result = BTRect(x: bounds.midX - current.size.width / 2, y: bounds.midY - current.size.height / 2, width: current.size.width, height: current.size.height)
        case .centerResize:
            let width = bounds.size.width * centerResizeFraction
            let height = bounds.size.height * centerResizeFraction
            result = BTRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
        case .moveLeft:
            result = current.offsetBy(dx: -movementIncrement, dy: 0)
        case .moveRight:
            result = current.offsetBy(dx: movementIncrement, dy: 0)
        case .moveUp:
            result = current.offsetBy(dx: 0, dy: -movementIncrement)
        case .moveDown:
            result = current.offsetBy(dx: 0, dy: movementIncrement)
        case .growWidth:
            result = BTRect(x: current.minX, y: current.minY, width: current.size.width + resizeIncrement, height: current.size.height)
        case .shrinkWidth:
            result = BTRect(x: current.minX, y: current.minY, width: current.size.width - resizeIncrement, height: current.size.height)
        case .growHeight:
            result = BTRect(x: current.minX, y: current.minY, width: current.size.width, height: current.size.height + resizeIncrement)
        case .shrinkHeight:
            result = BTRect(x: current.minX, y: current.minY, width: current.size.width, height: current.size.height - resizeIncrement)
        default:
            result = nil
        }
        return result?.clamped(to: bounds, minimumSize: window.constraints.minimumSize)
    }

    public func transferFrame(_ frame: BTRect, from source: DisplaySnapshot, to destination: DisplaySnapshot) -> BTRect {
        NormalizedRect(frame: frame, in: source.visibleFrame)
            .frame(in: destination.visibleFrame)
            .clamped(to: destination.visibleFrame)
    }
}
