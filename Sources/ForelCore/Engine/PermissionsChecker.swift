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
#if canImport(Photos)
import Photos
#endif

/// Read-only status of a system permission Forel depends on. Surfaced in
/// Settings so the user can see at a glance what's granted and what still
/// needs attention, instead of discovering a missing permission only when a
/// rule silently fails.
public enum PermissionStatus: Equatable, Sendable {
    case granted
    case denied
    case restricted
    /// The user hasn't been asked yet (Photos), or the status simply hasn't
    /// been probed this session (Music/TV automation — see
    /// `PermissionsChecker.checkAutomationAccessNow`, the only way to learn it
    /// without guessing, and it requires an explicit user action).
    case unknown
}

/// Centralizes the permission checks `ActionExecutor` already performs as a
/// side effect of running rules, so Settings can show them proactively
/// instead of the user only finding out when an action fails.
public enum PermissionsChecker {
    // MARK: - Photos

    /// Current Photos authorization, queried without prompting.
    public static func photosAccessStatus() -> PermissionStatus {
        #if canImport(Photos)
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .unknown
        @unknown default: return .unknown
        }
        #else
        return .denied
        #endif
    }

    /// Triggers the system Photos permission prompt if the user hasn't been
    /// asked yet. Only call this from an explicit user action (a "Request
    /// Access" button) — it does nothing but report status if access has
    /// already been decided.
    @discardableResult
    public static func requestPhotosAccess() -> PermissionStatus {
        #if canImport(Photos)
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined else {
            return photosAccessStatus()
        }
        let semaphore = DispatchSemaphore(value: 0)
        let box = PhotosAuthStatusBox()
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            box.status = status
            semaphore.signal()
        }
        semaphore.wait()
        switch box.status {
        case .authorized, .limited: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        default: return .unknown
        }
        #else
        return .denied
        #endif
    }

    // MARK: - Full Disk Access

    /// Files only readable by apps with Full Disk Access. Reading one is the
    /// standard, prompt-free way to learn the status; there is no public API.
    public static var fullDiskAccessProbePaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/Library/Application Support/com.apple.TCC/TCC.db",
            "\(home)/Library/Safari/Bookmarks.plist",
            "/Library/Application Support/com.apple.TCC/TCC.db",
        ]
    }

    /// Whether Forel has Full Disk Access. With it, macOS never asks for
    /// per-folder access (Desktop, Documents, Downloads, external and network
    /// volumes) again — as long as the app keeps the same code signature.
    /// Never prompts. Probes that don't exist on this Mac are ignored; if
    /// none exists the status is `.unknown`.
    public static func fullDiskAccessStatus(probePaths: [String] = fullDiskAccessProbePaths) -> PermissionStatus {
        let fm = FileManager.default
        var sawProtectedFile = false
        for path in probePaths where fm.fileExists(atPath: path) {
            sawProtectedFile = true
            if let handle = FileHandle(forReadingAtPath: path) {
                try? handle.close()
                return .granted
            }
        }
        return sawProtectedFile ? .denied : .unknown
    }

    // MARK: - Automation (Music / TV)

    /// Whether `app` ("Music" or "TV") already has a running process —
    /// checked via System Events so merely asking doesn't launch it.
    public static func isAppRunning(_ app: String) -> Bool {
        ActionExecutor.isAppRunning(app)
    }

    /// Live automation-permission probe for `app`. This talks to the app over
    /// AppleScript, which **launches it** if it isn't already running —
    /// there's no API to learn Apple Events automation status without
    /// actually attempting one. Only call this from an explicit "Check
    /// Access" button, never from a passive status read (e.g. on a view
    /// simply appearing), so Forel never launches Music or TV as a surprise
    /// side effect of opening Settings.
    public static func checkAutomationAccessNow(app: String) -> PermissionStatus {
        do {
            // Must use the same probe as the real import path's gate — see
            // `ActionExecutor.automationProbeScript`'s doc comment for why a
            // trivial command like `get name` would always report granted.
            _ = try ActionExecutor.runAppleScript(ActionExecutor.automationProbeScript(app: app))
            return .granted
        } catch {
            return .denied
        }
    }
}

#if canImport(Photos)
/// Thread-safe holder for the authorization result delivered on an arbitrary
/// queue; the surrounding semaphore establishes the happens-before ordering.
private final class PhotosAuthStatusBox: @unchecked Sendable {
    var status: PHAuthorizationStatus = .denied
}
#endif
