import Synchronization
import Testing

/// Where a test helper sends a failure that it detected.
///
/// Real callers use `.issue`: the helper records an Issue, as it always did. A helper's own self-test
/// passes `.collecting(into:)`. The self-test can then check that the helper reported the failure, with
/// its message and source location, and the test run keeps no known-issue record.
public enum HelperFailureReporter: Sendable {
    case issue
    case collecting(into: HelperFailureLog)

    /// Report the failure and let the helper continue.
    public func record(_ comment: Comment, sourceLocation: SourceLocation) {
        switch self {
        case .issue: Issue.record(comment, sourceLocation: sourceLocation)
        case let .collecting(log): log.append(comment, at: sourceLocation)
        }
    }

    /// Report the failure and stop the caller, as a failed `#require` does.
    public func require(_ comment: Comment, sourceLocation: SourceLocation) throws {
        switch self {
        case .issue:
            try #require(Bool(false), comment, sourceLocation: sourceLocation)
        case let .collecting(log):
            log.append(comment, at: sourceLocation)
            throw HelperFailureLog.Stopped()
        }
    }
}

/// The failures that a helper reported to a collecting reporter, in order.
public final class HelperFailureLog: Sendable {
    public struct Entry: Sendable, Equatable {
        public var message: String
        public var sourceLocation: SourceLocation

        public init(message: String, sourceLocation: SourceLocation) {
            self.message = message
            self.sourceLocation = sourceLocation
        }
    }

    /// Thrown where the `.issue` reporter stops the caller with a failed `#require`.
    public struct Stopped: Error {}

    private let entries = Mutex<[Entry]>([])

    public init() {}

    public var reported: [Entry] { entries.withLock { $0 } }
    public var messages: [String] { reported.map(\.message) }

    fileprivate func append(_ comment: Comment, at sourceLocation: SourceLocation) {
        entries.withLock { $0.append(Entry(message: comment.rawValue, sourceLocation: sourceLocation)) }
    }
}
