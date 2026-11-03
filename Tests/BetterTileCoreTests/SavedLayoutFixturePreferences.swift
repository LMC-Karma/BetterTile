@testable import BetterTileCore

extension SavedLayoutSlot {
    /// The first direct app preference used by fixture assertions.
    var preferredAppForFixture: String? {
        prefer.compactMap { if case let .app(id) = $0 { id } else { nil } }.first
    }
}
