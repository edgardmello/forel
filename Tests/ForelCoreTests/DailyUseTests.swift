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

import Testing
import Foundation
@testable import ForelCore

/// Health, downtime catch-up, "Coming Up", shared-rule counts and review
/// size estimates.
@Suite struct DailyUseTests {
    // MARK: - Health

    @Test func healthListsMissingFoldersFullDiskAccessAndFailures() {
        let folders = [
            WatchedFolder(path: "/gone"),
            WatchedFolder(path: "/here"),
            WatchedFolder(path: "/off", enabled: false),
        ]
        let issues = ForelHealth.issues(
            folders: folders,
            fullDiskAccess: .denied,
            recentFailureCount: 3,
            folderExists: { $0 == "/here" }
        )
        #expect(issues.map(\.id) == ["missing:/gone", "fda", "failures"])
        #expect(issues.allSatisfy { $0.needsAttention })
        #expect(issues[2].message().hasPrefix("3 actions failed"))
    }

    @Test func healthIsQuietWhenAllIsWell() {
        let issues = ForelHealth.issues(
            folders: [WatchedFolder(path: "/here")],
            fullDiskAccess: .granted,
            recentFailureCount: 0,
            folderExists: { _ in true }
        )
        #expect(issues.isEmpty)
        // Without enabled folders, Full Disk Access doesn't matter yet.
        #expect(ForelHealth.issues(folders: [], fullDiskAccess: .denied, recentFailureCount: 0).isEmpty)
    }

    @Test func downtimeIsReportedOnlyWhenLongEnough() throws {
        let now = Date()
        #expect(ForelHealth.downtime(lastAlive: nil, now: now) == nil)
        #expect(ForelHealth.downtime(lastAlive: now.addingTimeInterval(-10 * 60), now: now) == nil)
        let gap = ForelHealth.downtime(lastAlive: now.addingTimeInterval(-3 * 3600), now: now)
        let duration = try #require(gap?.duration)
        #expect(abs(duration - 3 * 3600) < 1)
        let issue = HealthIssue(.wasNotRunning(from: now.addingTimeInterval(-3600), to: now, checkedFiles: 2))
        #expect(!issue.needsAttention)
        #expect(issue.message().contains("2 files that arrived meanwhile were checked"))
    }

    @Test func failedHistoryIsCountedSinceADate() throws {
        let db = try Database(path: ":memory:")
        let old = ISO8601DateFormatter.forelUTC.string(from: Date().addingTimeInterval(-3 * 86400))
        try db.insertHistoryEntries([
            HistoryEntry(batchId: "a", ruleId: nil, ruleName: "r", actionKind: .moveToFolder, originalPath: "/a", resultPath: "/a", undo: .null, reversible: false, status: .failed),
            HistoryEntry(batchId: "b", ruleId: nil, ruleName: "r", actionKind: .moveToFolder, originalPath: "/b", resultPath: "/b", undo: .null, reversible: false, status: .failed, createdAt: old),
            HistoryEntry(batchId: "c", ruleId: nil, ruleName: "r", actionKind: .moveToFolder, originalPath: "/c", resultPath: "/c", undo: .null, reversible: false),
        ])
        let since = ISO8601DateFormatter.forelUTC.string(from: Date().addingTimeInterval(-86400))
        #expect(try db.countFailedHistory(since: since) == 1)
    }

    // MARK: - Catching up after Forel wasn't running

    @Test func catchUpAfterDowntimeRunsOnlyFilesThatArrivedMeanwhile() throws {
        let db = try Database(path: ":memory:")
        let dir = TempDir()
        let file = dir.file("arrived.txt", contents: "x")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "tag")
        rule.actions = [makeAction(.addTag, .object([ActionParam.tags: .stringArray(["Caught"])]), ruleId: rule.id)]
        try db.insertRule(rule)
        let coordinator = WatcherCoordinator(db: db)

        // Stopped after the file arrived: it was there already, leave it.
        #expect(coordinator.performCatchUp(root: dir.path, arrivedAfter: Date().addingTimeInterval(60)) == 0)
        #expect(!FinderTags.read(file).contains("Caught"))

        // Stopped before it arrived: run it.
        #expect(coordinator.performCatchUp(root: dir.path, arrivedAfter: Date().addingTimeInterval(-3600)) == 1)
        #expect(FinderTags.read(file).contains("Caught"))
    }

    // MARK: - Coming Up

    @Test func comingUpListsFilesATimedRuleWillTakeLater() throws {
        let dir = TempDir()
        let file = dir.file("new.pdf", contents: "x")
        var rule = makeRule(name: "sort after a day", conditions: [makeCondition(.dateModified, .olderThan, "1 day")])
        rule.actions = [makeAction(.addTag, .object([ActionParam.tags: .stringArray(["Old"])]))]

        let ahead: TimeInterval = 25 * 3600
        let result = RuleEngine.upcoming(root: dir.path, rules: [rule], lookahead: ahead)
        #expect(result.lookahead == .some(ahead))
        #expect(result.matches.map(\.path) == [file])
        // Nothing changed.
        #expect(!FinderTags.read(file).contains("Old"))

        // Within an hour nothing turns a day old.
        #expect(RuleEngine.upcoming(root: dir.path, rules: [rule], lookahead: 3600).matches.isEmpty)
    }

    @Test func comingUpSkipsFilesAlreadyDueAndRulesThatDontWait() throws {
        let dir = TempDir()
        _ = dir.file("a.pdf", contents: "x")
        let untimed = makeRule(name: "pdfs", conditions: [makeCondition(.extension_, .is, "pdf")], actions: [makeAction(.addTag, .object([ActionParam.tags: .stringArray(["P"])]))])
        #expect(RuleEngine.upcoming(root: dir.path, rules: [untimed], lookahead: 86400).matches.isEmpty)

        let dueNow = makeRule(name: "recent", conditions: [makeCondition(.dateModified, .withinLast, "1 week")], actions: [makeAction(.addTag, .object([ActionParam.tags: .stringArray(["R"])]))])
        #expect(RuleEngine.upcoming(root: dir.path, rules: [dueNow], lookahead: 86400).matches.isEmpty)
    }

    // MARK: - Shared rules

    @Test func linkedFolderCountsCountOtherFolders() throws {
        let db = try Database(path: ":memory:")
        let a = WatchedFolder(path: "/a"), b = WatchedFolder(path: "/b"), c = WatchedFolder(path: "/c")
        for folder in [a, b, c] { try db.insertFolder(folder) }
        var shared = makeRule(folderId: a.id, name: "shared")
        shared.conditions = [makeCondition(.extension_, .is, "pdf", ruleId: shared.id)]
        try db.saveRule(shared, sharingWith: [b.id, c.id])
        let alone = makeRule(folderId: a.id, name: "alone")
        try db.insertRule(alone)

        let counts = try db.linkedFolderCounts(folderId: a.id)
        #expect(counts[shared.id] == 2)
        #expect(counts[alone.id] == nil)
    }

    // MARK: - Review with AI

    @Test func reviewSizeIsEstimatedBeforeSending() throws {
        let rule = makeRule(name: "pdfs", conditions: [makeCondition(.extension_, .is, "pdf")])
        let conversation = try RuleReviewer.reviewConversation(rule: rule, folderPath: "/tmp", otherRules: [])
        let characters = conversation.messages.reduce(0) { $0 + $1.content.count }
        #expect(conversation.estimatedTokens == (characters + 3) / 4)
        #expect(RuleReviewer.serviceHost(AISettings(provider: .deepseek)).contains("deepseek"))
    }
}
