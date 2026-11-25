// Forel - A native macOS file-automation app
// Copyright (C) 2026  Edgard Mello
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

/// Something that keeps Forel from doing its job, shown in the menu bar
/// (a yellow dot) and in the quick panel, so a stopped or blocked Forel
/// doesn't go unnoticed for days.
public struct HealthIssue: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        /// A watched folder that no longer exists (renamed, deleted, or on a
        /// disk that isn't connected).
        case missingFolder(path: String)
        /// Full Disk Access is off, so macOS can block folders one by one.
        case noFullDiskAccess
        /// Actions failed recently.
        case recentFailures(count: Int)
        /// Forel wasn't running for a while; files that arrived then were
        /// checked when it started again.
        case wasNotRunning(from: Date, to: Date, checkedFiles: Int)
    }

    public let kind: Kind

    public init(_ kind: Kind) { self.kind = kind }

    public var id: String {
        switch kind {
        case .missingFolder(let path): return "missing:\(path)"
        case .noFullDiskAccess: return "fda"
        case .recentFailures: return "failures"
        case .wasNotRunning: return "downtime"
        }
    }

    /// Whether the issue needs the user to do something (yellow dot), as
    /// opposed to news that something was already handled.
    public var needsAttention: Bool {
        if case .wasNotRunning = kind { return false }
        return true
    }

    public func message(formatter: DateFormatter = HealthIssue.defaultFormatter) -> String {
        switch kind {
        case .missingFolder(let path):
            return "\((path as NSString).lastPathComponent) can't be found, so its rules aren't running. It may have been renamed, deleted, or be on a disk that isn't connected."
        case .noFullDiskAccess:
            return "Full Disk Access is off, so macOS can stop Forel from reading some folders without telling you."
        case .recentFailures(let count):
            return "\(count) action\(count == 1 ? "" : "s") failed in the last 24 hours."
        case .wasNotRunning(let from, let to, let checked):
            let files = checked == 0 ? "no new files had arrived" : "\(checked) file\(checked == 1 ? "" : "s") that arrived meanwhile \(checked == 1 ? "was" : "were") checked now"
            return "Forel wasn't running from \(formatter.string(from: from)) to \(formatter.string(from: to)); \(files)."
        }
    }

    public static var defaultFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }
}

public enum ForelHealth {
    /// A gap shorter than this between two heartbeats isn't reported: the
    /// Mac was asleep or Forel was restarted.
    public static let downtimeThreshold: TimeInterval = 30 * 60
    /// How often a running Forel records that it's alive.
    public static let heartbeatInterval: TimeInterval = 5 * 60
    public static let lastAliveSetting = "last_alive_at"

    public static func issues(
        folders: [WatchedFolder],
        fullDiskAccess: PermissionStatus,
        recentFailureCount: Int,
        downtime: HealthIssue.Kind? = nil,
        folderExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [HealthIssue] {
        var issues: [HealthIssue] = []
        for folder in folders where folder.enabled && !folderExists(folder.path) {
            issues.append(HealthIssue(.missingFolder(path: folder.path)))
        }
        if fullDiskAccess == .denied, folders.contains(where: \.enabled) {
            issues.append(HealthIssue(.noFullDiskAccess))
        }
        if recentFailureCount > 0 {
            issues.append(HealthIssue(.recentFailures(count: recentFailureCount)))
        }
        if let downtime { issues.append(HealthIssue(downtime)) }
        return issues
    }

    /// The span Forel wasn't running, from the last heartbeat to `now`, when
    /// it's long enough to mention.
    public static func downtime(lastAlive: Date?, now: Date = Date()) -> DateInterval? {
        guard let lastAlive, now.timeIntervalSince(lastAlive) >= downtimeThreshold else { return nil }
        return DateInterval(start: lastAlive, end: now)
    }

    /// When the file at `path` arrived in its folder (Finder's Date Added),
    /// falling back to its creation date.
    public static func arrivalDate(_ path: String) -> Date? {
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey, .creationDateKey])
        return values?.addedToDirectoryDate ?? values?.creationDate
    }
}
