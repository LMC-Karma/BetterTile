// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma

import Foundation

public enum DisplayTriggerDocument {
    public static func isValidLayoutFile(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 255 && !name.hasPrefix(".") && name.lowercased().hasSuffix(".json")
            && !name.contains("/") && !name.contains(":") && !name.unicodeScalars.contains { $0.value < 32 }
    }
}
