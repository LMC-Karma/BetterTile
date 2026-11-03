// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma

import ServiceManagement

/// Whether macOS opens BetterTile at login. macOS owns this state, not BetterTile's configuration:
/// the user can also change it in System Settings › General › Login Items.
enum LaunchAtLoginState: Equatable {
    case on
    case off
    /// Registered, but the user must allow it in Login Items.
    case needsApproval
    /// macOS cannot register this copy, for example a build that is not an installed app.
    case unavailable
}

@MainActor protocol LaunchAtLoginService: AnyObject {
    var state: LaunchAtLoginState { get }
    func setEnabled(_ enabled: Bool) throws
    func openLoginItemsSettings()
}

/// Registers the main app as a login item with the public `SMAppService.mainApp` API.
/// No helper, daemon or new permission is involved.
@MainActor final class SystemLaunchAtLogin: LaunchAtLoginService {
    static let shared = SystemLaunchAtLogin()

    var state: LaunchAtLoginState {
        switch SMAppService.mainApp.status {
        case .enabled: .on
        case .requiresApproval: .needsApproval
        case .notRegistered: .off
        case .notFound: .unavailable
        @unknown default: .off
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
