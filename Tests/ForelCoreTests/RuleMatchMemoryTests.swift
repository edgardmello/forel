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

import Testing
import Foundation
@testable import ForelCore

/// "Date last matched", "Times matched" and the periodic re-check all share
/// `RuleMatchMemory.shared`, so these tests attach their own database to it
/// one at a time.
@Suite(.serialized) struct RuleMatchMemoryTests {
    private func withMemory(_ body: (Database) throws -> Void) throws {
        let db = try Database(path: ":memory:")
        RuleMatchMemory.shared.attach(db)
        defer { RuleMatchMemory.shared.attach(nil) }
        try body(db)
    }

    @Test func timesMatchedZeroMatchesOnlyTheFirstTime() throws {
        try withMemory { db in
            let dir = TempDir()
            let file = dir.file("report.txt", contents: "x")
            let folder = WatchedFolder(path: dir.path)
            try db.insertFolder(folder)
            var rule = makeRule(folderId: folder.id, name: "first time")
            rule.conditions = [makeCondition(.timesMatched, .is, "0", ruleId: rule.id)]
            rule.actions = [makeAction(.addTag, .object([ActionParam.tags: .stringArray(["seen"])]), ruleId: rule.id)]
            try db.insertRule(rule)

            let first = RuleEngine.run(path: file, depth: 0, rules: [rule], batchId: "b1", root: dir.path)
            #expect(first.matched == ["first time"])
            let second = RuleEngine.run(path: file, depth: 0, rules: [rule], batchId: "b2", root: dir.path)
            #expect(second.matched.isEmpty)

            let record = RuleMatchMemory.shared.record(ruleId: rule.id, path: file)
            #expect(record?.matchCount == 1)
            #expect(ConditionEvaluator.evaluate(makeCondition(.timesMatched, .greaterThan, "0", ruleId: rule.id), path: file))
            #expect(ConditionEvaluator.evaluate(makeCondition(.dateLastMatched, .withinLast, "1 days", ruleId: rule.id), path: file))
            #expect(!ConditionEvaluator.evaluate(makeCondition(.dateLastMatched, .olderThan, "1 days", ruleId: rule.id), path: file))
        }
    }

    @Test func neverMatchedCountsAsMatchedLongAgo() throws {
        try withMemory { _ in
            let dir = TempDir()
            let file = dir.file("new.txt", contents: "x")
            #expect(ConditionEvaluator.evaluate(makeCondition(.dateLastMatched, .olderThan, "30 days"), path: file))
            #expect(ConditionEvaluator.evaluate(makeCondition(.dateLastMatched, .before, "2020-01-01"), path: file))
            #expect(!ConditionEvaluator.evaluate(makeCondition(.dateLastMatched, .withinLast, "30 days"), path: file))
            #expect(!ConditionEvaluator.evaluate(makeCondition(.dateLastMatched, .after, "2020-01-01"), path: file))
            #expect(ConditionEvaluator.evaluate(makeCondition(.timesMatched, .is, "0"), path: file))
        }
    }

    @Test func matchRecordFollowsARename() throws {
        try withMemory { db in
            let dir = TempDir()
            let file = dir.file("draft.txt", contents: "x")
            let folder = WatchedFolder(path: dir.path)
            try db.insertFolder(folder)
            var rule = makeRule(folderId: folder.id, name: "rename")
            rule.conditions = [makeCondition(.name, .is, "draft", ruleId: rule.id)]
            rule.actions = [makeAction(.rename, .object([ActionParam.pattern: .string("final")]), ruleId: rule.id)]
            try db.insertRule(rule)

            _ = RuleEngine.run(path: file, depth: 0, rules: [rule], batchId: "b", root: dir.path)
            let renamed = (dir.path as NSString).appendingPathComponent("final.txt")
            #expect(FileManager.default.fileExists(atPath: renamed))
            #expect(RuleMatchMemory.shared.record(ruleId: rule.id, path: renamed)?.matchCount == 1)
        }
    }

    @Test func dryRunDoesNotRecordMatches() throws {
        try withMemory { db in
            let dir = TempDir()
            let file = dir.file("a.txt", contents: "x")
            let folder = WatchedFolder(path: dir.path)
            try db.insertFolder(folder)
            var rule = makeRule(folderId: folder.id, name: "tag")
            rule.actions = [makeAction(.addTag, .object([ActionParam.tags: .stringArray(["t"])]), ruleId: rule.id)]
            try db.insertRule(rule)

            #expect(RuleEngine.previewFile(path: file, depth: 0, rules: [rule], root: dir.path) != nil)
            #expect(RuleMatchMemory.shared.record(ruleId: rule.id, path: file) == nil)
        }
    }

    @Test func deletingARuleForgetsItsMatches() throws {
        try withMemory { db in
            let dir = TempDir()
            let file = dir.file("a.txt", contents: "x")
            let folder = WatchedFolder(path: dir.path)
            try db.insertFolder(folder)
            let rule = makeRule(folderId: folder.id, name: "any")
            try db.insertRule(rule)
            _ = RuleEngine.run(path: file, depth: 0, rules: [rule], batchId: "b", root: dir.path)
            #expect(RuleMatchMemory.shared.record(ruleId: rule.id, path: file) != nil)
            try db.deleteRule(rule.id)
            #expect(RuleMatchMemory.shared.record(ruleId: rule.id, path: file) == nil)
        }
    }

    // MARK: - Periodic re-check

    @Test func recheckRunsTimeDependentRulesOnceAndSkipsOthers() throws {
        try withMemory { db in
            let dir = TempDir()
            let old = dir.file("old.txt", contents: "x")
            let tenDaysAgo = Calendar.current.date(byAdding: .day, value: -10, to: Date())!
            try FileManager.default.setAttributes([.modificationDate: tenDaysAgo], ofItemAtPath: old)
            let fresh = dir.file("fresh.txt", contents: "x")

            let folder = WatchedFolder(path: dir.path)
            try db.insertFolder(folder)
            var timeRule = makeRule(folderId: folder.id, name: "stale")
            timeRule.conditions = [makeCondition(.dateModified, .olderThan, "5 days", ruleId: timeRule.id)]
            timeRule.actions = [makeAction(.addTag, .object([ActionParam.tags: .stringArray(["stale"])]), ruleId: timeRule.id)]
            try db.insertRule(timeRule)
            var plainRule = makeRule(folderId: folder.id, name: "plain")
            plainRule.conditions = [makeCondition(.extension_, .is, "txt", ruleId: plainRule.id)]
            plainRule.actions = [makeAction(.addTag, .object([ActionParam.tags: .stringArray(["plain"])]), ruleId: plainRule.id)]
            try db.insertRule(plainRule)

            let coordinator = WatcherCoordinator(db: db, settleInterval: 0)
            coordinator.performRecheck()

            #expect(FinderTags.read(old).contains("stale"))
            #expect(!FinderTags.read(fresh).contains("stale"))
            // Not time-dependent: the watcher handles it when files change.
            #expect(!FinderTags.read(old).contains("plain"))
            let afterFirst = try db.listHistory().count
            #expect(afterFirst == 1)

            // Nothing changed about the file, so the rule doesn't repeat.
            coordinator.performRecheck()
            #expect(try db.listHistory().count == afterFirst)
        }
    }

    @Test func timeDependenceIsDetectedFromRelativeDatesAndMatchHistory() {
        var rule = makeRule(name: "r")
        rule.conditions = [makeCondition(.dateAdded, .before, "2026-01-01")]
        #expect(!RuleEngine.isTimeDependent(rule))
        rule.conditions = [makeCondition(.dateAdded, .withinLast, "7 days")]
        #expect(RuleEngine.isTimeDependent(rule))
        rule.conditions = [makeCondition(.dateLastMatched, .after, "2026-01-01")]
        #expect(RuleEngine.isTimeDependent(rule))
    }
}
