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

/// One thing that happened while Forel was running: a file the watcher
/// noticed, what the rules made of it, a Run Now or a Dry Run.
public struct LoggedEvent: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable, CaseIterable {
        /// The watcher saw a file appear or change.
        case fileArrived
        /// The watcher saw a file go away.
        case fileRemoved
        /// macOS asked for a whole folder to be looked at again.
        case folderRescanned
        /// One or more rules matched a file.
        case rulesMatched
        /// A file was checked and no rule matched it.
        case noRuleMatched
        /// A manual Run Now.
        case runNow
        /// A Dry Run preview.
        case dryRun
        /// A destination disk or share wasn't connected.
        case volumeUnavailable
        /// Watching was paused or resumed.
        case watching

        public var label: String {
            switch self {
            case .fileArrived: return "File changed"
            case .fileRemoved: return "File removed"
            case .folderRescanned: return "Folder rescanned"
            case .rulesMatched: return "Rules matched"
            case .noRuleMatched: return "No rule matched"
            case .runNow: return "Run Now"
            case .dryRun: return "Dry Run"
            case .volumeUnavailable: return "Disk not connected"
            case .watching: return "Watching"
            }
        }

        public var iconSystemName: String {
            switch self {
            case .fileArrived: return "doc.badge.plus"
            case .fileRemoved: return "doc.badge.ellipsis"
            case .folderRescanned: return "arrow.triangle.2.circlepath"
            case .rulesMatched: return "checkmark.seal"
            case .noRuleMatched: return "minus.circle"
            case .runNow: return "play.circle"
            case .dryRun: return "eye"
            case .volumeUnavailable: return "externaldrive.badge.exclamationmark"
            case .watching: return "eye.circle"
            }
        }
    }

    public let id: UUID
    public let date: Date
    public let kind: Kind
    public let path: String?
    public let message: String
    public let ruleNames: [String]
    public let isError: Bool

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        kind: Kind,
        path: String? = nil,
        message: String,
        ruleNames: [String] = [],
        isError: Bool = false
    ) {
        self.id = id
        self.date = date
        self.kind = kind
        self.path = path
        self.message = message
        self.ruleNames = ruleNames
        self.isError = isError
    }
}

/// The recent events of this session, newest first. Kept in memory only
/// (like Console's live stream): it starts empty at launch and keeps the
/// last `capacity` events, so it never grows the database.
public final class EventLog: @unchecked Sendable {
    public let capacity: Int
    private let lock = NSLock()
    private var events: [LoggedEvent] = []
    private var changeHandler: (@Sendable () -> Void)?

    public init(capacity: Int = 1000) {
        self.capacity = max(capacity, 1)
    }

    /// Called after every change, on whichever thread made it.
    public func setChangeHandler(_ handler: (@Sendable () -> Void)?) {
        lock.lock()
        changeHandler = handler
        lock.unlock()
    }

    public func append(_ event: LoggedEvent) {
        lock.lock()
        events.append(event)
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
        let handler = changeHandler
        lock.unlock()
        handler?()
    }

    /// Newest first.
    public func entries() -> [LoggedEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events.reversed()
    }

    public func clear() {
        lock.lock()
        events.removeAll()
        let handler = changeHandler
        lock.unlock()
        handler?()
    }

    /// What the rules made of one file, as an event.
    public static func outcome(path: String, matched: [String], history: [HistoryEntry]) -> LoggedEvent {
        guard !matched.isEmpty || !history.isEmpty else {
            return LoggedEvent(kind: .noRuleMatched, path: path, message: "No rule matched")
        }
        let names = matched.isEmpty ? Array(Set(history.map(\.ruleName))).sorted() : matched
        let failed = history.contains { $0.status == .failed }
        let summary = RunSummary.message(for: history)
            .replacingOccurrences(of: "Run complete — ", with: "")
        let ruleText = names.count == 1 ? "“\(names[0])”" : "\(names.count) rules"
        let message = history.isEmpty ? "\(ruleText) matched" : "\(ruleText) matched — \(summary)"
        return LoggedEvent(kind: .rulesMatched, path: path, message: message, ruleNames: names, isError: failed)
    }
}
