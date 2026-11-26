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

/// A plain-text snapshot for bug reports: versions, watched folders, what
/// the health check sees, recent events and recent failures. Paths under the
/// home folder are shortened to `~` so the report doesn't carry the user's
/// account name; no rule contents, file contents or passwords go in.
public enum DiagnosticsReport {
    public struct FolderSummary: Sendable, Equatable {
        public var path: String
        public var enabled: Bool
        public var ruleCount: Int
        public var enabledRuleCount: Int

        public init(path: String, enabled: Bool, ruleCount: Int, enabledRuleCount: Int) {
            self.path = path
            self.enabled = enabled
            self.ruleCount = ruleCount
            self.enabledRuleCount = enabledRuleCount
        }
    }

    public struct Input: Sendable {
        public var appVersion: String
        public var build: String
        public var systemVersion: String
        public var schemaVersion: Int64
        public var isPaused: Bool
        public var folders: [FolderSummary]
        public var issues: [HealthIssue]
        public var events: [LoggedEvent]
        public var failures: [HistoryEntry]
        public var homeDirectory: String
        public var generatedAt: Date

        public init(
            appVersion: String,
            build: String,
            systemVersion: String = ProcessInfo.processInfo.operatingSystemVersionString,
            schemaVersion: Int64 = Database.currentSchemaVersion,
            isPaused: Bool,
            folders: [FolderSummary],
            issues: [HealthIssue],
            events: [LoggedEvent],
            failures: [HistoryEntry],
            homeDirectory: String = NSHomeDirectory(),
            generatedAt: Date = Date()
        ) {
            self.appVersion = appVersion
            self.build = build
            self.systemVersion = systemVersion
            self.schemaVersion = schemaVersion
            self.isPaused = isPaused
            self.folders = folders
            self.issues = issues
            self.events = events
            self.failures = failures
            self.homeDirectory = homeDirectory
            self.generatedAt = generatedAt
        }
    }

    /// How many recent events and failures go into the report.
    public static let eventLimit = 200
    public static let failureLimit = 50

    public static func make(_ input: Input) -> String {
        let stamp = ISO8601DateFormatter.forelUTC
        func shorten(_ text: String) -> String {
            let home = (input.homeDirectory as NSString).standardizingPath
            guard home.count > 1 else { return text }
            return text.replacingOccurrences(of: home + "/", with: "~/")
                .replacingOccurrences(of: home, with: "~")
        }

        var lines: [String] = []
        lines.append("Forel diagnostics")
        lines.append("Generated: \(stamp.string(from: input.generatedAt))")
        lines.append("Forel: \(input.appVersion) (\(input.build))")
        lines.append("macOS: \(input.systemVersion)")
        lines.append("Database schema: \(input.schemaVersion)")
        lines.append("Watching: \(input.isPaused ? "paused" : "on")")

        lines.append("")
        lines.append("Watched folders (\(input.folders.count))")
        if input.folders.isEmpty { lines.append("  none") }
        for folder in input.folders {
            let state = folder.enabled ? "on" : "off"
            lines.append("  [\(state)] \(shorten(folder.path)): \(folder.enabledRuleCount) of \(folder.ruleCount) rules enabled")
        }

        lines.append("")
        lines.append("Health")
        if input.issues.isEmpty { lines.append("  no problems found") }
        for issue in input.issues {
            lines.append("  - \(shorten(issue.message()))")
        }

        let failures = input.failures.prefix(failureLimit)
        lines.append("")
        lines.append("Recent failures (\(failures.count))")
        if failures.isEmpty { lines.append("  none") }
        for entry in failures {
            let reason = entry.message.map { ": \(shorten($0))" } ?? ""
            lines.append("  \(entry.createdAt) \(entry.actionKind.rawValue) via “\(entry.ruleName)” on \(shorten(entry.originalPath))\(reason)")
        }

        let events = input.events.prefix(eventLimit)
        lines.append("")
        lines.append("Recent events (\(events.count), newest first)")
        if events.isEmpty { lines.append("  none") }
        for event in events {
            let path = event.path.map { " \(shorten($0))" } ?? ""
            let flag = event.isError ? " [error]" : ""
            lines.append("  \(stamp.string(from: event.date)) \(event.kind.label)\(flag)\(path): \(shorten(event.message))")
        }

        return lines.joined(separator: "\n") + "\n"
    }
}
