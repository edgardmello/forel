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
import os

/// Folders a scan couldn't list (no permission, gone mid-scan, a broken
/// network share). Every scan path (Dry Run, Run Now, the watcher) walks
/// folders through the same code, which reports here instead of silently
/// skipping. Each folder is reported at most once per `quietPeriod`, so a
/// watcher re-checking the same locked folder doesn't flood the Event Log.
public enum UnreadableFolders {
    public static let logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "scan")
    public static let quietPeriod: TimeInterval = 10 * 60

    private static let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var handler: (@Sendable (LoggedEvent) -> Void)?
        var lastReported: [String: Date] = [:]
    }

    /// Where reports go besides the system log. The app points this at its
    /// Event Log.
    public static func setHandler(_ handler: (@Sendable (LoggedEvent) -> Void)?) {
        state.withLock { $0.handler = handler }
    }

    /// Forget which folders were already reported (for tests).
    public static func reset() {
        state.withLock { $0.lastReported.removeAll() }
    }

    public static func report(path: String, error: Error, now: Date = Date()) {
        let reason = message(for: error)
        let (isNew, handler) = state.withLock { state -> (Bool, (@Sendable (LoggedEvent) -> Void)?) in
            if let last = state.lastReported[path], now.timeIntervalSince(last) < quietPeriod { return (false, nil) }
            state.lastReported[path] = now
            return (true, state.handler)
        }
        guard isNew else { return }
        logger.error("Couldn't list \(path, privacy: .private): \(reason, privacy: .public)")
        handler?(LoggedEvent(date: now, kind: .folderUnreadable, path: path, message: reason, isError: true))
    }

    /// A plain-language reason, without the Cocoa error boilerplate.
    public static func message(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileReadNoPermissionError:
                return "Forel isn't allowed to look inside this folder, so its files were skipped. Check Full Disk Access or the folder's permissions."
            case NSFileReadNoSuchFileError, NSFileNoSuchFileError:
                return "The folder disappeared while it was being checked, so its files were skipped."
            default:
                break
            }
        }
        return "Forel couldn't look inside this folder, so its files were skipped (\(nsError.localizedDescription))."
    }
}
