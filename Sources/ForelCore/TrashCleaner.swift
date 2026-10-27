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

/// When Forel empties old items out of the Trash on its own. `nil` limits
/// are off; both off means Forel never touches the Trash.
public struct TrashCleanupPolicy: Equatable, Sendable {
    /// Delete items that have been in the Trash longer than this.
    public var maxAgeDays: Int?
    /// Then, if the Trash is still bigger than this, delete the oldest
    /// items until it isn't.
    public var maxSizeBytes: UInt64?

    public init(maxAgeDays: Int? = nil, maxSizeBytes: UInt64? = nil) {
        self.maxAgeDays = maxAgeDays
        self.maxSizeBytes = maxSizeBytes
    }

    public var isEnabled: Bool { maxAgeDays != nil || maxSizeBytes != nil }
}

public struct TrashItem: Equatable, Sendable {
    public let path: String
    /// When the item was put in the Trash (its "Date Added"), falling back
    /// to its modification date on volumes that don't track that.
    public let trashedAt: Date
    public let sizeBytes: UInt64
}

public enum TrashCleanerError: LocalizedError, Equatable, Sendable {
    case cannotReadTrash

    public var errorDescription: String? {
        switch self {
        case .cannotReadTrash:
            return "Forel can't see what's in the Trash. macOS only lets apps with Full Disk Access read it: open System Settings → Privacy & Security → Full Disk Access and turn on Forel."
        }
    }
}

/// Permanently deletes items from the user's Trash according to a
/// `TrashCleanupPolicy` — Hazel's Trash management. Deleting from the Trash
/// can't be undone, so `plan` lets Settings show exactly what would go
/// before anything does.
public enum TrashCleaner {
    public static var userTrashPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".Trash")
    }

    public static func items(trashPath: String = userTrashPath) throws -> [TrashItem] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: trashPath) else {
            throw TrashCleanerError.cannotReadTrash
        }
        return names
            .filter { $0 != ".DS_Store" && $0 != ".localized" }
            .compactMap { name in
                let path = (trashPath as NSString).appendingPathComponent(name)
                guard let attrs = try? fm.attributesOfItem(atPath: path) else { return nil }
                let trashedAt = ConditionEvaluator.dateAdded(path: path)
                    ?? (attrs[.modificationDate] as? Date)
                    ?? Date()
                return TrashItem(path: path, trashedAt: trashedAt, sizeBytes: allocatedSize(path))
            }
    }

    /// Items the policy would delete right now, oldest first.
    public static func plan(_ policy: TrashCleanupPolicy, items: [TrashItem], now: Date = Date()) -> [TrashItem] {
        let oldestFirst = items.sorted { $0.trashedAt < $1.trashedAt }
        var doomed: [TrashItem] = []
        var keep = oldestFirst
        if let days = policy.maxAgeDays, days > 0,
           let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) {
            doomed = keep.filter { $0.trashedAt < cutoff }
            keep.removeAll { $0.trashedAt < cutoff }
        }
        if let limit = policy.maxSizeBytes {
            var total = keep.reduce(UInt64(0)) { $0 + $1.sizeBytes }
            while total > limit, !keep.isEmpty {
                let item = keep.removeFirst()
                doomed.append(item)
                total -= item.sizeBytes
            }
        }
        return doomed
    }

    /// Deletes what `plan` returns and reports each item's outcome.
    public static func clean(_ policy: TrashCleanupPolicy, trashPath: String = userTrashPath, now: Date = Date()) throws -> (deleted: [TrashItem], failed: [(item: TrashItem, message: String)]) {
        guard policy.isEnabled else { return ([], []) }
        let doomed = plan(policy, items: try items(trashPath: trashPath), now: now)
        var deleted: [TrashItem] = []
        var failed: [(item: TrashItem, message: String)] = []
        for item in doomed {
            do {
                try FileManager.default.removeItem(atPath: item.path)
                deleted.append(item)
            } catch {
                failed.append((item: item, message: error.localizedDescription))
            }
        }
        return (deleted, failed)
    }

    /// History entries describing a cleanup, so it shows in Activity.
    public static func historyEntries(deleted: [TrashItem], failed: [(item: TrashItem, message: String)]) -> [HistoryEntry] {
        let batchId = UUID().uuidString
        let ruleName = "Trash cleanup"
        return deleted.map {
            HistoryEntry(batchId: batchId, ruleId: nil, ruleName: ruleName, actionKind: .delete, originalPath: $0.path, resultPath: $0.path, undo: Undo.none.toJSON(), reversible: false)
        } + failed.map {
            HistoryEntry(batchId: batchId, ruleId: nil, ruleName: ruleName, actionKind: .delete, originalPath: $0.item.path, resultPath: $0.item.path, undo: Undo.none.toJSON(), reversible: false, status: .failed, message: $0.message)
        }
    }

    static func allocatedSize(_ path: String) -> UInt64 {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey]
        let values = try? url.resourceValues(forKeys: keys)
        guard values?.isDirectory == true else {
            return UInt64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        var total: UInt64 = 0
        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) {
            for case let child as URL in enumerator {
                let childValues = try? child.resourceValues(forKeys: keys)
                total += UInt64(childValues?.totalFileAllocatedSize ?? childValues?.fileAllocatedSize ?? 0)
            }
        }
        return total
    }
}
