// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma

import AppKit
import BetterTileCore
import CoreGraphics

/// A connected display and its stored-form identity.
public struct LiveDisplay: Equatable, Sendable {
    public var id: DisplayID
    public var fingerprint: DisplayFingerprint

    public init(id: DisplayID, fingerprint: DisplayFingerprint) {
        self.id = id
        self.fingerprint = fingerprint
    }
}

/// Reads display identity from public CoreGraphics and AppKit calls only. It never touches a window.
public enum DisplayFingerprintReader {
    /// One display as the system reports it, before filtering.
    public struct Raw: Equatable, Sendable {
        public var id: UInt32
        public var uuid: String
        public var vendor: UInt32
        public var model: UInt32
        public var serial: UInt32
        public var builtIn: Bool
        public var name: String
        public var bounds: BTRect
        public var mirrorsDisplay: Bool

        public init(id: UInt32, uuid: String, vendor: UInt32, model: UInt32, serial: UInt32, builtIn: Bool,
                    name: String, bounds: BTRect, mirrorsDisplay: Bool) {
            self.id = id; self.uuid = uuid; self.vendor = vendor; self.model = model; self.serial = serial
            self.builtIn = builtIn; self.name = name; self.bounds = bounds; self.mirrorsDisplay = mirrorsDisplay
        }
    }

    /// Mirrored displays count once: a display that mirrors another is skipped.
    public static func liveDisplays(from raws: [Raw]) -> [LiveDisplay] {
        raws.filter { !$0.mirrorsDisplay && !$0.uuid.isEmpty }.map {
            LiveDisplay(id: DisplayID(rawValue: String($0.id)),
                        fingerprint: .init(uuid: $0.uuid, vendor: $0.vendor, model: $0.model, serial: $0.serial,
                                           builtIn: $0.builtIn, name: $0.name, frame: $0.bounds))
        }
    }

    @MainActor public static func current() -> [LiveDisplay] {
        liveDisplays(from: NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = number.uint32Value
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
            let bounds = CGDisplayBounds(id)
            return Raw(id: id, uuid: CFUUIDCreateString(nil, uuid) as String,
                       vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id), serial: CGDisplaySerialNumber(id),
                       builtIn: CGDisplayIsBuiltin(id) != 0, name: screen.localizedName,
                       bounds: BTRect(x: bounds.origin.x, y: bounds.origin.y, width: bounds.width, height: bounds.height),
                       mirrorsDisplay: CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay)
        })
    }
}
