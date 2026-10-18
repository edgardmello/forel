// Forel - A native macOS file-automation app
// Copyright (C) 2026  Lab421
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

import Foundation
import ServiceManagement

/// Wraps `SMAppService.mainApp` for the "Start at login" preference.
///
/// The user's *intent* lives in the database (`launch_at_login`); this type
/// only talks to macOS. In a bare dev build (no packaged `.app`) registration
/// isn't possible, so callers persist the intent regardless and it applies
/// once the app runs from a bundle.
///
/// macOS can silently lose the registration — system updates migrate the
/// background-task database and cleaner utilities remove entries from it —
/// so intent and OS state are reconciled at launch, and Settings warns when
/// they disagree instead of showing a toggle that lies.
enum LoginItem {
    /// Whether Forel runs from a packaged `.app` bundle. Only then can
    /// `SMAppService` register anything; a bare dev executable always fails.
    static var isPackagedApp: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registration succeeded but macOS is waiting for the user to allow
    /// Forel under Login Items in System Settings.
    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Result<Void, Error> {
        do {
            switch (enabled, SMAppService.mainApp.status) {
            case (true, let status) where status != .enabled:
                try SMAppService.mainApp.register()
            case (false, .enabled):
                try SMAppService.mainApp.unregister()
            default:
                break
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    /// Drops the user into System Settings' Login Items pane, where a
    /// `.requiresApproval` registration can be allowed.
    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
