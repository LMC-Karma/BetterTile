import BetterTileCore
import Foundation

public struct PaneRequestWindow: Equatable, Identifiable, Sendable {
    public let id: WindowID
    public let title: String
    public init(id: WindowID, title: String) { self.id = id; self.title = title }
}

public struct PaneRequestWindowGroup: Equatable, Sendable {
    public let label: String
    public let windows: [PaneRequestWindow]
    public init(label: String, windows: [PaneRequestWindow]) { self.label = label; self.windows = windows }
}

public enum PaneRequestAction: Equatable, Sendable {
    case cancel, tryAgain, useWindow(WindowID), showApp, chooseAnotherApp, showWindows
}

public struct PaneRequestStatus: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case opening(launching: Bool)
        case placing
        case stillOpening
        case awaitingClick([PaneRequestWindow])
        case noNewWindow([PaneRequestWindow])
        case severalCopies([PaneRequestWindowGroup])
        case timedOut(showingWindows: Bool, windows: [PaneRequestWindow])
        case failed
        case other(message: String, windows: [PaneRequestWindow])
    }
    public let requestID: UUID
    public let paneID: UUID
    public let appName: String
    public let appIconURL: URL?
    public let kind: Kind
    public init(requestID: UUID, paneID: UUID, appName: String, appIconURL: URL? = nil, kind: Kind) {
        self.requestID = requestID
        self.paneID = paneID; self.appName = appName; self.appIconURL = appIconURL; self.kind = kind
    }

    public var headline: String {
        switch kind {
        case .opening: "Opening \(appName)…"
        case .stillOpening: "Still opening \(appName)…"
        case .placing: "Opening \(appName)…"
        case .awaitingClick: "Choose a \(appName) window"
        case .noNewWindow: "\(appName) didn't offer a new window"
        case .severalCopies: "Several copies are running"
        case .timedOut: "\(appName) didn't open a window"
        case .failed: "\(appName) could not be opened"
        case .other: "Choose a \(appName) window"
        }
    }

    public var message: String {
        switch kind {
        case .opening, .stillOpening, .placing: ""
        case .awaitingClick: "Use the window you choose on this desktop."
        case .noNewWindow: "Use a window from this desktop or open \(appName)'s own window."
        case .severalCopies: "BetterTile cannot tell which copy to ask. Choose a window from this desktop."
        case .timedOut:
            "Use a window from this desktop, or try again."
        case .failed:
            "macOS did not start the app. It may be damaged, removed, or blocked in Privacy & Security."
        case let .other(message, _): message
        }
    }

    /// A lone usable window is a direct action rather than a one-row list.
    public var singleWindow: PaneRequestWindow? {
        let windows: [PaneRequestWindow]
        switch kind {
        case let .awaitingClick(entries), let .noNewWindow(entries), let .other(_, entries), let .timedOut(_, entries):
            windows = entries
        case let .severalCopies(groups): windows = groups.flatMap(\.windows)
        default: return nil
        }
        return windows.count == 1 ? windows.first : nil
    }

    public var singleWindowButtonTitle: String? {
        singleWindow.map { "Use “\($0.title.isEmpty ? appName : $0.title)”" }
    }
}
