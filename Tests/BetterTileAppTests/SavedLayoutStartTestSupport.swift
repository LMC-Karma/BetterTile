import Testing
@testable import BetterTileApp

struct SavedLayoutStateWaitError: Error, CustomStringConvertible {
    let message: String
    let sourceLocation: SourceLocation
    var description: String { "\(message) at \(sourceLocation.fileID):\(sourceLocation.line)" }
}

/// Match Settings UI waits: preserve observation opportunities after a main-actor stall.
@MainActor
func waitForSavedLayoutState(_ message: String, timeout: Duration = .seconds(30),
                             sourceLocation: SourceLocation = #_sourceLocation,
                             _ condition: () -> Bool) async throws {
    guard await waitFor(timeout: timeout, condition) else {
        throw SavedLayoutStateWaitError(message: "Exhausted observation opportunities: \(message)",
                                       sourceLocation: sourceLocation)
    }
}

/// Wait until the session releases its startup guard.
@MainActor
func waitForApplyStart(_ session: SavedLayoutApplySession,
                       sourceLocation: SourceLocation = #_sourceLocation) async throws {
    try await waitForSavedLayoutState("The Apply start guard did not clear.", sourceLocation: sourceLocation) {
        !session.isStartingForTesting
    }
}
