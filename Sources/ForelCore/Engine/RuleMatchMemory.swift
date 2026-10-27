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

/// What Forel remembers about one rule matching one file.
public struct RuleMatchRecord: Equatable, Sendable {
    public let ruleId: String
    public let fileKey: String
    public let lastMatchedAt: Date
    public let matchCount: Int
    /// The file's fingerprint right after the rule's actions ran, so a
    /// later look can tell whether the file changed since.
    public let fingerprint: String?

    public init(ruleId: String, fileKey: String, lastMatchedAt: Date, matchCount: Int, fingerprint: String?) {
        self.ruleId = ruleId
        self.fileKey = fileKey
        self.lastMatchedAt = lastMatchedAt
        self.matchCount = matchCount
        self.fingerprint = fingerprint
    }
}

/// Per-rule, per-file match history shared by every execution path: Run Now
/// and the watcher record matches through `RuleEngine.run`, while Dry Run
/// only reads it (through the "Date last matched"/"Times matched"
/// conditions). Without an attached database — unit tests, previews — it
/// remembers nothing and every file counts as never matched.
public final class RuleMatchMemory: @unchecked Sendable {
    public static let shared = RuleMatchMemory()

    private let lock = NSLock()
    private var database: Database?

    public init(database: Database? = nil) {
        self.database = database
    }

    public func attach(_ database: Database?) {
        lock.lock()
        self.database = database
        lock.unlock()
    }

    private var db: Database? {
        lock.lock()
        defer { lock.unlock() }
        return database
    }

    /// Volume + inode, so the record follows the file through renames and
    /// moves on the same disk. Falls back to the path for files `stat`
    /// can't identify.
    static func fileKey(_ path: String) -> String {
        if let identity = FileFingerprint.identity(path) {
            return "\(identity.volumeId):\(identity.fileId)"
        }
        return "path:\(path)"
    }

    public func record(ruleId: String, path: String) -> RuleMatchRecord? {
        guard let db else { return nil }
        let key = Self.fileKey(path)
        return db.withLock { db in try? db.getRuleMatchRecord(ruleId: ruleId, fileKey: key) }
    }

    /// Records a match. `fileKey` must be taken before the rule's actions
    /// ran (a move to another disk changes the identity); the fingerprint
    /// is read from wherever the file ended up.
    func recordMatch(ruleId: String, fileKey: String, finalPath: String, at date: Date = Date()) {
        guard let db else { return }
        let fingerprint = FileFingerprint.current(finalPath)
        db.withLock { db in
            try? db.recordRuleMatch(ruleId: ruleId, fileKey: fileKey, matchedAt: date, fingerprint: fingerprint)
        }
    }

    /// True when `ruleId` already matched this file and the file hasn't
    /// changed since — the periodic re-check leaves such pairs alone, the
    /// same way Hazel runs a rule on a file only once until it changes.
    public func hasMatchedUnchanged(ruleId: String, path: String) -> Bool {
        guard let record = record(ruleId: ruleId, path: path) else { return false }
        return record.fingerprint != nil && record.fingerprint == FileFingerprint.current(path)
    }
}
