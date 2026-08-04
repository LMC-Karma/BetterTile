import Foundation

public struct BTPoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct BTSize: Codable, Hashable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public static let zero = BTSize(width: 0, height: 0)
}

/// A logical-point rectangle in BetterTile's canonical top-left coordinate system.
public struct BTRect: Codable, Hashable, Sendable {
    public var origin: BTPoint
    public var size: BTSize

    public init(x: Double, y: Double, width: Double, height: Double) {
        origin = BTPoint(x: x, y: y)
        size = BTSize(width: width, height: height)
    }

    public init(origin: BTPoint, size: BTSize) {
        self.origin = origin
        self.size = size
    }

    public var minX: Double { origin.x }
    public var minY: Double { origin.y }
    public var maxX: Double { origin.x + size.width }
    public var maxY: Double { origin.y + size.height }
    public var midX: Double { origin.x + size.width / 2 }
    public var midY: Double { origin.y + size.height / 2 }
    public var area: Double { max(0, size.width) * max(0, size.height) }
    public var center: BTPoint { BTPoint(x: midX, y: midY) }
    public var isEmpty: Bool { size.width <= 0 || size.height <= 0 }

    public func insetBy(dx: Double, dy: Double) -> BTRect {
        BTRect(
            x: minX + dx,
            y: minY + dy,
            width: max(0, size.width - dx * 2),
            height: max(0, size.height - dy * 2)
        )
    }

    public func offsetBy(dx: Double, dy: Double) -> BTRect {
        BTRect(x: minX + dx, y: minY + dy, width: size.width, height: size.height)
    }

    public func contains(_ point: BTPoint) -> Bool {
        point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }

    public func intersection(_ other: BTRect) -> BTRect? {
        let x1 = max(minX, other.minX)
        let y1 = max(minY, other.minY)
        let x2 = min(maxX, other.maxX)
        let y2 = min(maxY, other.maxY)
        guard x2 > x1, y2 > y1 else { return nil }
        return BTRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
    }

    public func clamped(to bounds: BTRect, minimumSize: BTSize = .zero) -> BTRect {
        let width = min(bounds.size.width, max(minimumSize.width, size.width))
        let height = min(bounds.size.height, max(minimumSize.height, size.height))
        let x = min(max(origin.x, bounds.minX), bounds.maxX - width)
        let y = min(max(origin.y, bounds.minY), bounds.maxY - height)
        return BTRect(x: x, y: y, width: width, height: height)
    }

    public func approximatelyEquals(_ other: BTRect, tolerance: Double = 1) -> Bool {
        abs(minX - other.minX) <= tolerance
            && abs(minY - other.minY) <= tolerance
            && abs(size.width - other.size.width) <= tolerance
            && abs(size.height - other.size.height) <= tolerance
    }
}

public struct NormalizedRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(frame: BTRect, in bounds: BTRect) {
        guard bounds.size.width > 0, bounds.size.height > 0 else {
            self.init(x: 0, y: 0, width: 1, height: 1)
            return
        }
        self.init(
            x: (frame.minX - bounds.minX) / bounds.size.width,
            y: (frame.minY - bounds.minY) / bounds.size.height,
            width: frame.size.width / bounds.size.width,
            height: frame.size.height / bounds.size.height
        )
    }

    public func frame(in bounds: BTRect) -> BTRect {
        BTRect(
            x: bounds.minX + x * bounds.size.width,
            y: bounds.minY + y * bounds.size.height,
            width: width * bounds.size.width,
            height: height * bounds.size.height
        )
    }

    public func validated() throws -> NormalizedRect {
        guard [x, y, width, height].allSatisfy(\.isFinite),
              x >= 0, y >= 0, width > 0, height > 0,
              x + width <= 1.000_001, y + height <= 1.000_001
        else { throw GeometryError.invalidNormalizedRect }
        return self
    }
}

public enum GeometryError: Error, Equatable {
    case invalidNormalizedRect
}

public extension BTRect {
    /// Compact form for diagnostics: `x,y wxh` rounded to whole points.
    var debugText: String {
        "\(Int(minX.rounded())),\(Int(minY.rounded())) \(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
    }
}
