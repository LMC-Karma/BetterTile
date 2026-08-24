import AppKit
@preconcurrency import ApplicationServices
import BetterTileCore
import CoreGraphics
import Foundation
import os

struct StageManagerGroupObservation: Equatable {
    var windowIDs: [CGWindowID]
    var windowManagerPID: pid_t
}

/// Reads only the bounded WindowManager group → list → button path. The path
/// was informed by Rectangle's MIT-licensed `StageUtil.swift`. Any
/// hierarchy or attribute change returns nil and leaves ordinary hit-testing
/// authoritative.
@MainActor
final class StageManagerGroupResolver {
    private nonisolated static let log = Logger(
        subsystem: "com.lmckarma.BetterTile",
        category: "StageManager"
    )
    private static let bundleIdentifier = "com.apple.WindowManager"
    private static let windowIDsAttribute = "AXWindowIDs"
    private let disabled: Bool
    private var loggedAvailable = false
    private var loggedFallback = false
    private var loggedValidationFallback = false
    private var loggedExposureFallback = false

    init(disabled: Bool) {
        self.disabled = disabled
        if disabled {
            Self.log.notice("stage manager group observation disabled by user default")
        }
    }

    var isEnabled: Bool { !disabled }

    func observation(at point: BTPoint) -> StageManagerGroupObservation? {
        guard !disabled else { return nil }
        guard let application = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == Self.bundleIdentifier
        }) else {
            logFallbackOnce()
            return nil
        }

        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        let groups: [AXUIElement] = value(kAXChildrenAttribute, from: applicationElement) ?? []
        for group in groups.prefix(8) {
            guard role(of: group) == kAXGroupRole,
                  frame(of: group)?.contains(point) == true
            else { continue }
            let lists: [AXUIElement] = value(kAXChildrenAttribute, from: group) ?? []
            for list in lists.prefix(4) where role(of: list) == kAXListRole {
                let buttons: [AXUIElement] = value(kAXChildrenAttribute, from: list) ?? []
                for button in buttons.prefix(20) {
                    guard Self.rolePathIsValid([
                        role(of: group), role(of: list), role(of: button),
                    ]),
                    frame(of: button)?.contains(point) == true,
                    let rawWindowIDs: Any = value(Self.windowIDsAttribute, from: button),
                    let windowIDs = Self.windowIDs(from: rawWindowIDs)
                    else { continue }
                    if !loggedAvailable {
                        loggedAvailable = true
                        Self.log.notice("stage manager group observation available")
                    }
                    return StageManagerGroupObservation(
                        windowIDs: windowIDs,
                        windowManagerPID: application.processIdentifier
                    )
                }
            }
        }
        logFallbackOnce()
        return nil
    }

    nonisolated static func rolePathIsValid(_ roles: [String?]) -> Bool {
        roles.count == 3
            && roles[0] == kAXGroupRole
            && roles[1] == kAXListRole
            && roles[2] == kAXButtonRole
    }

    nonisolated static func windowIDs(from rawValue: Any?) -> [CGWindowID]? {
        guard let values = rawValue as? [Any], !values.isEmpty else { return nil }
        let windowIDs = values.compactMap { rawValue -> CGWindowID? in
            guard let number = rawValue as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID()
            else { return nil }
            let encoding = String(cString: number.objCType)
            let rawWindowID: UInt64?
            if ["C", "S", "I", "L", "Q"].contains(encoding) {
                rawWindowID = number.uint64Value
            } else if ["c", "s", "i", "l", "q"].contains(encoding),
                      number.int64Value > 0 {
                rawWindowID = UInt64(number.int64Value)
            } else {
                rawWindowID = nil
            }
            guard let rawWindowID,
                  rawWindowID > 0,
                  rawWindowID <= UInt64(UInt32.max)
            else { return nil }
            return CGWindowID(rawWindowID)
        }
        guard windowIDs.count == values.count,
              Set(windowIDs).count == windowIDs.count
        else { return nil }
        return windowIDs
    }

    nonisolated static func frontmostValidWindowID(
        groupWindowIDs: [CGWindowID],
        targetedRecords: [WindowServerRecord],
        frontToBackWindowIDs: [CGWindowID],
        rejectedOwnerPIDs: Set<pid_t>,
        knownOwnerPIDs: Set<pid_t>
    ) -> CGWindowID? {
        let recordsByID = Dictionary(grouping: targetedRecords, by: \.windowID)
        let validWindowIDs = Set(groupWindowIDs.filter { windowID in
            guard let records = recordsByID[windowID], records.count == 1,
                  let record = records.first,
                  !rejectedOwnerPIDs.contains(record.processIdentifier),
                  record.layer == 0,
                  knownOwnerPIDs.contains(record.processIdentifier)
            else { return false }
            return true
        })
        return frontToBackWindowIDs.first(where: validWindowIDs.contains)
    }

    func logValidationFallbackOnce() {
        guard !loggedValidationFallback else { return }
        loggedValidationFallback = true
        Self.log.notice(
            "stage manager member validation failed; using ordinary hit-testing"
        )
    }

    func logExposureFallbackOnce() {
        guard !loggedExposureFallback else { return }
        loggedExposureFallback = true
        Self.log.notice(
            "stage manager member was not exposed through Accessibility; ending thumbnail drag"
        )
    }

    private func role(of element: AXUIElement) -> String? {
        value(kAXRoleAttribute, from: element)
    }

    private func frame(of element: AXUIElement) -> BTRect? {
        guard let position: CGPoint = axValue(kAXPositionAttribute, from: element, type: .cgPoint),
              let size: CGSize = axValue(kAXSizeAttribute, from: element, type: .cgSize),
              position.x.isFinite, position.y.isFinite,
              size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0
        else { return nil }
        return BTRect(
            x: position.x,
            y: position.y,
            width: size.width,
            height: size.height
        )
    }

    private func value<T>(_ attribute: String, from element: AXUIElement) -> T? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &rawValue
        ) == .success else { return nil }
        return rawValue as? T
    }

    private func axValue<T>(
        _ attribute: String,
        from element: AXUIElement,
        type: AXValueType
    ) -> T? {
        guard let value: AXValue = value(attribute, from: element),
              AXValueGetType(value) == type
        else { return nil }
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard AXValueGetValue(value, type, pointer) else { return nil }
        return pointer.pointee
    }

    private func logFallbackOnce() {
        guard !loggedFallback else { return }
        loggedFallback = true
        Self.log.notice(
            "stage manager AX hierarchy or window IDs unavailable; using ordinary hit-testing"
        )
    }
}
