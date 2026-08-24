import ApplicationServices
import BetterTileCore
import Darwin
import Foundation
import os

struct ApplicationLaunchInstance: Hashable {
    var processIdentifier: pid_t
    var generation: UInt64
}

struct WindowIdentityRecord: Equatable {
    var windowID: WindowID
    var application: ApplicationLaunchInstance
    var accessibilityHashes: Set<CFHashCode>
    var exactWindowID: CGWindowID?
}

struct WindowIdentityRegistry {
    private struct ElementKey: Hashable {
        var application: ApplicationLaunchInstance
        var accessibilityHash: CFHashCode
    }

    private struct ExactKey: Hashable {
        var application: ApplicationLaunchInstance
        var exactWindowID: CGWindowID
    }

    private(set) var records: [WindowID: WindowIdentityRecord] = [:]
    private var elementIDs: [ElementKey: WindowID] = [:]
    private var exactIDs: [ExactKey: WindowID] = [:]
    private var nextWindowSequence: UInt64 = 0

    mutating func resolve(
        application: ApplicationLaunchInstance,
        accessibilityHash: CFHashCode,
        exactWindowID: CGWindowID?
    ) -> WindowID {
        let elementKey = ElementKey(
            application: application,
            accessibilityHash: accessibilityHash
        )
        if let existing = elementIDs[elementKey] {
            bind(exactWindowID, to: existing)
            return existing
        }

        if let exactWindowID,
           let existing = exactIDs[ExactKey(
               application: application,
               exactWindowID: exactWindowID
           )] {
            elementIDs[elementKey] = existing
            records[existing]?.accessibilityHashes.insert(accessibilityHash)
            return existing
        }

        nextWindowSequence &+= 1
        let windowID = WindowID(
            rawValue: "\(application.processIdentifier):\(application.generation):\(nextWindowSequence)"
        )
        records[windowID] = WindowIdentityRecord(
            windowID: windowID,
            application: application,
            accessibilityHashes: [accessibilityHash],
            exactWindowID: nil
        )
        elementIDs[elementKey] = windowID
        bind(exactWindowID, to: windowID)
        return windowID
    }

    func windowID(
        application: ApplicationLaunchInstance,
        accessibilityHash: CFHashCode
    ) -> WindowID? {
        elementIDs[ElementKey(
            application: application,
            accessibilityHash: accessibilityHash
        )]
    }

    func exactWindowID(for windowID: WindowID) -> CGWindowID? {
        records[windowID]?.exactWindowID
    }

    func windowID(forExactWindowID exactWindowID: CGWindowID) -> WindowID? {
        records.values.first { $0.exactWindowID == exactWindowID }?.windowID
    }

    @discardableResult
    mutating func remove(_ windowID: WindowID) -> WindowIdentityRecord? {
        guard let record = records.removeValue(forKey: windowID) else { return nil }
        for hash in record.accessibilityHashes {
            elementIDs.removeValue(forKey: ElementKey(
                application: record.application,
                accessibilityHash: hash
            ))
        }
        if let exactWindowID = record.exactWindowID {
            exactIDs.removeValue(forKey: ExactKey(
                application: record.application,
                exactWindowID: exactWindowID
            ))
        }
        return record
    }

    mutating func remove(processIdentifier: pid_t) -> Set<WindowID> {
        let removed = Set(records.values.compactMap {
            $0.application.processIdentifier == processIdentifier ? $0.windowID : nil
        })
        for windowID in removed { remove(windowID) }
        return removed
    }

    mutating func removeAll() {
        records.removeAll()
        elementIDs.removeAll()
        exactIDs.removeAll()
    }

    private mutating func bind(_ exactWindowID: CGWindowID?, to windowID: WindowID) {
        guard let exactWindowID, var record = records[windowID] else { return }
        let key = ExactKey(application: record.application, exactWindowID: exactWindowID)
        guard exactIDs[key] == nil || exactIDs[key] == windowID else { return }
        if let previous = record.exactWindowID, previous != exactWindowID {
            exactIDs.removeValue(forKey: ExactKey(
                application: record.application,
                exactWindowID: previous
            ))
        }
        record.exactWindowID = exactWindowID
        records[windowID] = record
        exactIDs[key] = windowID
    }
}

@MainActor
final class ExactWindowIDResolver {
    private typealias Function = @convention(c) (
        AXUIElement,
        UnsafeMutablePointer<CGWindowID>
    ) -> AXError

    private nonisolated static let log = Logger(
        subsystem: "com.lmckarma.BetterTile",
        category: "PrivateAPI"
    )
    private let frameworkHandle: UnsafeMutableRawPointer?
    private let function: Function?
    private var loggedCallFailure = false

    var isAvailable: Bool { function != nil }

    init(disabled: Bool = UserDefaults.standard.bool(forKey: "disablePrivateAPIs")) {
        guard !disabled else {
            frameworkHandle = nil
            function = nil
            Self.log.notice("private window identity disabled by user default")
            return
        }
        // ApplicationServices is already a public dependency. Search its loaded
        // images without adding a private framework or symbol as a launch link.
        let handle = dlopen(nil, RTLD_LAZY | RTLD_LOCAL)
        frameworkHandle = handle
        if let symbol = handle.flatMap({ dlsym($0, "_AXUIElementGetWindow") }) {
            function = unsafeBitCast(symbol, to: Function.self)
            Self.log.notice("private window identity available")
        } else {
            function = nil
            Self.log.notice("private window identity unavailable; using frame correlation")
        }
    }

    func windowID(for element: AXUIElement) -> CGWindowID? {
        guard let function else { return nil }
        var windowID = kCGNullWindowID
        let error = function(element, &windowID)
        guard error == .success, windowID != kCGNullWindowID else {
            if !loggedCallFailure {
                loggedCallFailure = true
                Self.log.notice(
                    "private window identity returned no usable ID; using frame correlation"
                )
            }
            return nil
        }
        return windowID
    }
}

struct WindowServerRecord: Equatable {
    var windowID: CGWindowID
    var processIdentifier: pid_t
    var layer: Int
    var frame: BTRect
    var isOnscreen: Bool
}

struct WindowServerIndex {
    private var recordsByID: [CGWindowID: WindowServerRecord]
    private var framesByPID: [pid_t: [BTRect]]

    init(records: [WindowServerRecord]) {
        recordsByID = records.reduce(into: [:]) { result, record in
            if result[record.windowID] == nil { result[record.windowID] = record }
        }
        framesByPID = Dictionary(grouping: records.filter { $0.layer == 0 && $0.isOnscreen }) {
            $0.processIdentifier
        }.mapValues { $0.map(\.frame) }
    }

    var isEmpty: Bool { framesByPID.isEmpty }

    func contains(_ snapshot: WindowSnapshot, exactWindowID: CGWindowID?) -> Bool {
        if let exactWindowID {
            guard let record = recordsByID[exactWindowID] else { return false }
            return record.processIdentifier == snapshot.processIdentifier
                && record.layer == 0
                && record.isOnscreen
        }
        return framesByPID[pid_t(snapshot.processIdentifier), default: []].contains {
            OnscreenWindowMatcher.matches(
                accessibilityFrame: snapshot.frame,
                windowServerFrame: $0
            )
        }
    }
}

struct WindowSnapshotCache {
    private(set) var snapshots: [WindowID: WindowSnapshot]?

    mutating func recordFullSweep(_ windows: [WindowSnapshot]) {
        snapshots = windows.reduce(into: [:]) { $0[$1.id] = $1 }
    }

    mutating func merge(
        _ refreshed: [WindowSnapshot],
        expectedWindowIDs: Set<WindowID>
    ) -> [WindowSnapshot]? {
        guard var snapshots,
              Set(refreshed.map(\.id)) == expectedWindowIDs
        else {
            invalidate()
            return nil
        }
        for window in refreshed { snapshots[window.id] = window }
        self.snapshots = snapshots
        return snapshots.values.sorted { $0.id < $1.id }
    }

    mutating func invalidate() {
        snapshots = nil
    }
}

enum MinimumSizeHintValidator {
    static func merged(
        defaultSize: BTSize,
        hints: [BTSize],
        displaySize: BTSize
    ) -> BTSize {
        hints.reduce(defaultSize) { result, hint in
            guard hint.width.isFinite, hint.height.isFinite,
                  hint.width > 0, hint.height > 0,
                  hint.width <= displaySize.width,
                  hint.height <= displaySize.height
            else { return result }
            return BTSize(
                width: max(result.width, hint.width),
                height: max(result.height, hint.height)
            )
        }
    }
}

enum WindowFloatingClassifier {
    private static let floatingSubroles: Set<String> = [
        kAXDialogSubrole,
        kAXSystemDialogSubrole,
        kAXFloatingWindowSubrole,
        kAXSystemFloatingWindowSubrole,
    ]

    static func isFloating(subrole: String?) -> Bool {
        subrole.map(floatingSubroles.contains) ?? false
    }
}
