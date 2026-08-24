import BetterTileCore
import ColorSync
import CoreGraphics
import Darwin
import Foundation
import os

/// Converts SkyLight's untyped property-list values into the only native
/// desktop topology BetterTile will trust. Any malformed topology value rejects
/// the complete observation instead of leaking partial private-API state.
enum NativeDesktopObservationParser {
    static func topology(
        from rawValue: Any,
        expectedDisplayIDs: Set<DisplayID>,
        displayAliases: [String: DisplayID]
    ) -> NativeDesktopObservation? {
        guard let rawDisplays = rawValue as? [Any] else { return nil }
        var currentSpaceByDisplay: [DisplayID: NativeSpaceID] = [:]
        var knownSpacesByDisplay: [DisplayID: Set<NativeSpaceID>] = [:]
        var fullscreenSpaceIDs: Set<NativeSpaceID> = []

        for rawDisplay in rawDisplays {
            guard let display = rawDisplay as? [String: Any],
                  let identifier = display["Display Identifier"] as? String,
                  let displayID = displayAliases[identifier],
                  currentSpaceByDisplay[displayID] == nil,
                  let rawCurrent = display["Current Space"] as? [String: Any],
                  let currentSpaceID = spaceID(from: rawCurrent["id64"]),
                  let rawSpaces = display["Spaces"] as? [Any],
                  !rawSpaces.isEmpty
            else { return nil }

            var knownSpaceIDs: Set<NativeSpaceID> = []
            for rawSpace in rawSpaces {
                guard let space = rawSpace as? [String: Any],
                      let spaceID = spaceID(from: space["id64"]),
                      knownSpaceIDs.insert(spaceID).inserted,
                      let type = integer(from: space["type"])
                else { return nil }
                if type == 4 { fullscreenSpaceIDs.insert(spaceID) }
            }
            guard knownSpaceIDs.contains(currentSpaceID) else { return nil }
            currentSpaceByDisplay[displayID] = currentSpaceID
            knownSpacesByDisplay[displayID] = knownSpaceIDs
        }

        // With “Displays have separate Spaces” disabled, SkyLight reports one
        // global `Main` record. Normalize that single validated topology onto
        // every AppKit display so downstream code still has complete coverage.
        if rawDisplays.count == 1,
           currentSpaceByDisplay.count == 1,
           let mainDisplayID = displayAliases["Main"],
           let currentSpaceID = currentSpaceByDisplay[mainDisplayID],
           let knownSpaceIDs = knownSpacesByDisplay[mainDisplayID] {
            for displayID in expectedDisplayIDs {
                currentSpaceByDisplay[displayID] = currentSpaceID
                knownSpacesByDisplay[displayID] = knownSpaceIDs
            }
        }

        guard Set(currentSpaceByDisplay.keys) == expectedDisplayIDs,
              Set(knownSpacesByDisplay.keys) == expectedDisplayIDs
        else { return nil }
        return NativeDesktopObservation(
            currentSpaceByDisplay: currentSpaceByDisplay,
            knownSpacesByDisplay: knownSpacesByDisplay,
            fullscreenSpaceIDs: fullscreenSpaceIDs
        )
    }

    static func membership(
        from rawValue: Any,
        knownSpaceIDs: Set<NativeSpaceID>
    ) -> Set<NativeSpaceID>? {
        guard let rawSpaceIDs = rawValue as? [Any] else { return nil }
        let spaceIDs = rawSpaceIDs.compactMap(spaceID(from:))
        guard spaceIDs.count == rawSpaceIDs.count else { return nil }
        let membership = Set(spaceIDs)
        guard membership.isSubset(of: knownSpaceIDs) else { return nil }
        return membership
    }

    private static func spaceID(from rawValue: Any?) -> NativeSpaceID? {
        guard let number = rawValue as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let encoding = String(cString: number.objCType)
        let rawSpaceID: UInt64?
        if ["C", "S", "I", "L", "Q"].contains(encoding) {
            rawSpaceID = number.uint64Value
        } else if ["c", "s", "i", "l", "q"].contains(encoding), number.int64Value > 0 {
            rawSpaceID = UInt64(number.int64Value)
        } else {
            rawSpaceID = nil
        }
        guard let rawSpaceID, rawSpaceID > 0 else { return nil }
        return NativeSpaceID(rawValue: rawSpaceID)
    }

    private static func integer(from rawValue: Any?) -> Int? {
        guard let number = rawValue as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let encoding = String(cString: number.objCType)
        if ["C", "S", "I", "L", "Q"].contains(encoding) {
            return Int(exactly: number.uint64Value)
        }
        guard ["c", "s", "i", "l", "q"].contains(encoding) else { return nil }
        return Int(exactly: number.int64Value)
    }
}

@MainActor
final class NativeDesktopObservationProvider {
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopySpacesForWindows = @convention(c) (
        Int32,
        Int32,
        CFArray
    ) -> Unmanaged<CFArray>?

    private nonisolated static let log = Logger(
        subsystem: "com.lmckarma.BetterTile",
        category: "NativeDesktop"
    )
    private let frameworkHandle: UnsafeMutableRawPointer?
    private let mainConnectionID: MainConnectionID?
    private let copyManagedDisplaySpaces: CopyManagedDisplaySpaces?
    private let copySpacesForWindows: CopySpacesForWindows?
    private var loggedObservationFailure = false

    var isAvailable: Bool {
        mainConnectionID != nil && copyManagedDisplaySpaces != nil && copySpacesForWindows != nil
    }

    init(disabled: Bool) {
        guard !disabled else {
            frameworkHandle = nil
            mainConnectionID = nil
            copyManagedDisplaySpaces = nil
            copySpacesForWindows = nil
            Self.log.notice("native desktop observation disabled by user default")
            return
        }
        let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY | RTLD_LOCAL
        )
        frameworkHandle = handle
        mainConnectionID = Self.resolve("SLSMainConnectionID", in: handle)
        copyManagedDisplaySpaces = Self.resolve("SLSCopyManagedDisplaySpaces", in: handle)
        copySpacesForWindows = Self.resolve("SLSCopySpacesForWindows", in: handle)
        Self.log.notice(
            "native desktop observation \(self.isAvailable ? "available" : "unavailable", privacy: .public)"
        )
    }

    func observation(
        displays: [DisplaySnapshot],
        exactWindowIDs: [WindowID: CGWindowID]
    ) -> NativeDesktopObservation? {
        guard let mainConnectionID,
              let copyManagedDisplaySpaces,
              let copySpacesForWindows,
              !displays.isEmpty,
              let aliases = displayAliases(for: displays)
        else {
            logObservationFailureOnce()
            return nil
        }
        let connectionID = mainConnectionID()
        guard let managedSpaces = copyManagedDisplaySpaces(connectionID)?.takeRetainedValue(),
              var observation = NativeDesktopObservationParser.topology(
                  from: managedSpaces as NSArray,
                  expectedDisplayIDs: Set(displays.map(\.id)),
                  displayAliases: aliases
              )
        else {
            logObservationFailureOnce()
            return nil
        }

        let knownSpaceIDs = observation.knownSpacesByDisplay.values.reduce(into: Set<NativeSpaceID>()) {
            $0.formUnion($1)
        }
        var membership: [WindowID: Set<NativeSpaceID>] = [:]
        for (windowID, exactWindowID) in exactWindowIDs {
            let rawWindowIDs = [NSNumber(value: exactWindowID)] as CFArray
            guard let rawSpaces = copySpacesForWindows(
                connectionID,
                0x7,
                rawWindowIDs
            )?.takeRetainedValue() else {
                // The API provides no membership for stale or inaccessible
                // windows. That window stays unknown; the topology is valid.
                continue
            }
            guard let spaces = NativeDesktopObservationParser.membership(
                from: rawSpaces as NSArray,
                knownSpaceIDs: knownSpaceIDs
            ) else {
                logObservationFailureOnce()
                return nil
            }
            if !spaces.isEmpty { membership[windowID] = spaces }
        }
        observation.windowMembership = membership
        return observation
    }

    private func displayAliases(for displays: [DisplaySnapshot]) -> [String: DisplayID]? {
        var aliases: [String: DisplayID] = [:]
        for display in displays {
            guard let rawDisplayID = UInt32(display.id.rawValue),
                  let uuid = CGDisplayCreateUUIDFromDisplayID(rawDisplayID)?.takeRetainedValue()
            else { return nil }
            let uuidString = CFUUIDCreateString(nil, uuid) as String
            aliases[display.id.rawValue] = display.id
            aliases[uuidString] = display.id
            aliases[uuidString.lowercased()] = display.id
            if display.isMain { aliases["Main"] = display.id }
        }
        return aliases
    }

    private func logObservationFailureOnce() {
        guard !loggedObservationFailure else { return }
        loggedObservationFailure = true
        Self.log.notice("native desktop observation was invalid; using public-API inference")
    }

    private static func resolve<Function>(
        _ symbol: String,
        in handle: UnsafeMutableRawPointer?
    ) -> Function? {
        guard let handle, let pointer = dlsym(handle, symbol) else { return nil }
        return unsafeBitCast(pointer, to: Function.self)
    }
}
