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
    /// The distance between lengths; nil while the lengths do not show it.
    public var step: Double?
    /// The latest length the window took.
    public var offset: Double
    /// Every length the window took, for a grid whose step is unknown.
    public var known: [Double]

    /// The step is the greatest common difference of the observed lengths,
    /// from 2 to `maximumShortfall` points. A larger one leaves the step
    /// unknown: lengths 60 points apart can be 4, 3, or 2 steps of 15, 20, or
    /// 30, so only those lengths are used until another shows the step.
    /// Nil when the lengths share no step of 2 points or more, so they are no
    /// window's steps.
    /// - Parameter observed: Lengths in the order they were seen.
    public init?(observed: [Double]) {
        let rounded = observed.map { $0.rounded() }
        guard let latest = rounded.last else { return nil }
        offset = latest
        known = Array(Set(rounded)).sorted()
        guard known.count > 1 else { step = nil; return }
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        let common = known.reduce(0) { gcd($0, abs(Int($1 - latest))) }
        guard common >= 2 else { return nil }
        step = Double(common) <= SteppedSizeAcceptance.maximumShortfall ? Double(common) : nil
    }

    public func contains(_ length: Double) -> Bool {
        guard let step else { return known.contains { abs(length - $0) <= 0.5 } }
        let remainder = (length - offset).truncatingRemainder(dividingBy: step)
        return min(abs(remainder), step - abs(remainder)) <= 0.5
    }

    /// Lengths within `distance` of `length`.
    public func lengths(near length: Double, within distance: Double) -> [Double] {
        guard let step else { return known.filter { abs($0 - length) <= distance } }
        let first = ((length - distance - offset) / step).rounded(.up)
        let last = ((length + distance - offset) / step).rounded(.down)
        guard first <= last else { return [] }
        return (Int(first)...Int(last)).map { offset + Double($0) * step }
    }

    /// The length to ask for in a window area `length` long: the largest
    /// length on the grid that fits. Without a step, the largest known length
    /// that fits, with less than one step to spare, or two when two lengths
    /// are known. When the area is smaller than every known length, the smallest
    /// less `maximumShortfall` and a point, which rounds to a lower row and
    /// teaches the step. Nil otherwise.
    public func request(inside length: Double) -> Double? {
        guard let step else {
            if let fits = known.last(where: { $0 <= length + 0.5 }) {
                // Two known lengths can be two rows apart.
                let spare = (SteppedSizeAcceptance.maximumShortfall + 1) * (known.count > 1 ? 2 : 1)
                return length - fits <= spare ? fits : nil
            }
            let below = (known.first ?? offset) - SteppedSizeAcceptance.maximumShortfall - 1
            return below > 0 && below <= length ? below : nil
        }
        return offset + ((length + 0.5 - offset) / step).rounded(.down) * step
    }
}
