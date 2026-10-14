import Foundation

/// Some applications resize in steps, such as Terminal's character cells.
/// They settle slightly smaller than a requested size and never reach it.
/// A frame at the requested origin that falls short by less than one step
/// is the application's nearest size, not a refusal.
public enum SteppedSizeAcceptance {
    /// The largest shortfall treated as one resize step, in points.
    public static let maximumShortfall = 24.0

    public enum Verdict: Equatable, Sendable {
        /// Within the ordinary write tolerance.
        case exact
        /// Short of the request by less than one step in at least one axis,
        /// or past it when growth is allowed.
        case stepped
        case rejected
    }

    /// - Parameter allowsGrowth: Also accept a frame up to one step larger,
    ///   for a caller that then fits the layout to it.
    public static func evaluate(
        requested: BTRect, actual: BTRect, tolerance: Double = 2, allowsGrowth: Bool = false
    ) -> Verdict {
        guard abs(actual.minX - requested.minX) <= tolerance,
              abs(actual.minY - requested.minY) <= tolerance else { return .rejected }
        let widthShortfall = requested.size.width - actual.size.width
        let heightShortfall = requested.size.height - actual.size.height
        let largest = allowsGrowth ? maximumShortfall : tolerance
        guard widthShortfall >= -largest, heightShortfall >= -largest,
              widthShortfall <= maximumShortfall, heightShortfall <= maximumShortfall else { return .rejected }
        return abs(widthShortfall) <= tolerance && abs(heightShortfall) <= tolerance ? .exact : .stepped
    }
}

/// The lengths a window that resizes in steps takes on one axis, learned
/// from the lengths it settled at. Terminal's heights, for example, are
/// 4 + 15·k points for its font.
public struct SteppedGrid: Equatable, Sendable {
    /// The distance between lengths; nil while only one length is known.
    public var step: Double?
    /// One length the window takes.
    public var offset: Double

    /// Nil when the lengths share no step from 2 to `maximumShortfall`
    /// points, so they are not one window's steps.
    public init?(observed: [Double]) {
        let lengths = Array(Set(observed.map { $0.rounded() })).sorted()
        guard let first = lengths.first else { return nil }
        offset = first
        guard lengths.count > 1 else { step = nil; return }
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        let common = lengths.dropFirst().reduce(0) { gcd($0, Int($1 - first)) }
        // Two lengths two rows apart differ by twice the step.
        guard let divisor = (1...max(1, common)).first(where: {
            common % $0 == 0 && Double(common / $0) <= SteppedSizeAcceptance.maximumShortfall
        }), common / divisor >= 2 else { return nil }
        step = Double(common / divisor)
    }

    public init(step: Double?, offset: Double) {
        self.step = step
        self.offset = offset
    }

    public func contains(_ length: Double) -> Bool {
        guard let step else { return abs(length - offset) <= 0.5 }
        let remainder = (length - offset).truncatingRemainder(dividingBy: step)
        return min(abs(remainder), step - abs(remainder)) <= 0.5
    }

    /// Lengths within `distance` of `length`.
    public func lengths(near length: Double, within distance: Double) -> [Double] {
        guard let step else { return abs(offset - length) <= distance ? [offset] : [] }
        let first = ((length - distance - offset) / step).rounded(.up)
        let last = ((length + distance - offset) / step).rounded(.down)
        guard first <= last else { return [] }
        return (Int(first)...Int(last)).map { offset + Double($0) * step }
    }

    /// The length to ask for in a window area `length` long: the largest
    /// length on the grid that fits. With one known length, that length when
    /// the area holds it with less than a step to spare. When the area is
    /// smaller, the known length less `maximumShortfall` and a point, which
    /// rounds to a lower row and teaches the step. Nil otherwise.
    public func request(inside length: Double) -> Double? {
        guard let step else {
            let gap = length - offset
            let below = offset - SteppedSizeAcceptance.maximumShortfall - 1
            if gap < -0.5 { return below > 0 && below <= length ? below : nil }
            return gap <= SteppedSizeAcceptance.maximumShortfall + 1 ? offset : nil
        }
        return offset + ((length + 0.5 - offset) / step).rounded(.down) * step
    }
}
