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

/// Keeps a second Forel from running against the same database: two
/// instances would watch the same folders and run every rule twice.
///
/// An exclusive `flock` on a file next to the database rather than a check of
/// running apps by bundle identifier, so a dev build launched straight from
/// `.build` (no bundle identifier) is caught too. The kernel drops the lock
/// when the process exits, even after a crash, so it can never go stale.
public final class InstanceLock: @unchecked Sendable {
    private let descriptor: Int32

    /// Takes the lock, or returns `nil` when another process holds it.
    /// The holder's PID is written into the file so the losing instance can
    /// find it and bring it forward.
    public init?(path: String) {
        let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        self.descriptor = descriptor
        let pid = Data("\(getpid())\n".utf8)
        ftruncate(descriptor, 0)
        _ = pid.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    /// The PID written by the instance holding the lock at `path`, if any.
    public static func holderPID(path: String) -> pid_t? {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
