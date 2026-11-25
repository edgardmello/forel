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

/// A watched folder inside another one (Downloads and Downloads/_Hoje) owns
/// its files: the outer folder's rules never act on them, whichever way the
/// outer folder is run. Checked on every path that scans a folder: Dry Run,
/// Run Now, the rule test, and the watcher's rescan, re-check and catch-up.
@Suite struct NestedWatchedFolderTests {
    private struct Fixture {
        let db: Database
        let outer: TempDir
        let outerFolder: WatchedFolder
        let inbox: String
        let outerFile: String
        let inboxFile: String
        let rules: [Rule]
        var nested: Set<String> { RuleEngine.nestedWatchedFolders(under: outer.path, in: (try? db.listFolders()) ?? []) }
    }

    /// Outer folder with one rule that labels every file at any depth
    /// ("modified within the last day" makes it time-dependent, so the re-check runs
    /// it too). The inbox inside it is watched, with no rules of its own.
    private func fixture() throws -> Fixture {
        let db = try Database(path: ":memory:")
        let outer = TempDir()
        let inbox = outer.dir("_Hoje")
        let outerFile = outer.file("outer.txt", contents: "o")
        let inboxFile = (inbox as NSString).appendingPathComponent("inbox.txt")
        try "i".write(toFile: inboxFile, atomically: true, encoding: .utf8)
        let outerFolder = WatchedFolder(path: outer.path)
        try db.insertFolder(outerFolder)
        try db.insertFolder(WatchedFolder(path: inbox))
        var rule = makeRule(folderId: outerFolder.id, name: "label everything", recursionDepth: nil)
        rule.conditions = [makeCondition(.dateModified, .withinLast, "1 day", ruleId: rule.id)]
        rule.actions = [makeAction(.setColorLabel, .object(["color": .string("Red")]), ruleId: rule.id)]
        try db.insertRule(rule)
        return Fixture(db: db, outer: outer, outerFolder: outerFolder, inbox: inbox, outerFile: outerFile, inboxFile: inboxFile, rules: try db.listRules(folderId: outerFolder.id))
    }

    @Test func nestedWatchedFoldersListsOnlyEnabledFoldersInside() {
        let folders = [
            WatchedFolder(path: "/Users/me/Downloads"),
            WatchedFolder(path: "/Users/me/Downloads/_Hoje"),
            WatchedFolder(path: "/Users/me/Downloads/Off", enabled: false),
            WatchedFolder(path: "/Users/me/Downloads2"),
            WatchedFolder(path: "/Users/me/Desktop"),
        ]
        #expect(RuleEngine.nestedWatchedFolders(under: "/Users/me/Downloads", in: folders) == ["/Users/me/Downloads/_Hoje"])
        #expect(RuleEngine.nestedWatchedFolders(under: "/Users/me/Downloads/_Hoje", in: folders).isEmpty)
    }

    @Test func scanSkipsNestedWatchedFolderAndEverythingInIt() throws {
        let f = try fixture()
        let paths = RuleEngine.walkEntries(root: f.outer.path, maxDepth: nil, skipping: f.nested).map(\.path)
        #expect(paths.contains(f.outerFile))
        #expect(!paths.contains(f.inbox))
        #expect(!paths.contains(f.inboxFile))
        // Without the skip list the inbox is walked, as before.
        #expect(RuleEngine.walkEntries(root: f.outer.path, maxDepth: nil).map(\.path).contains(f.inboxFile))
    }

    /// The same fixture through each path; each must label only the outer
    /// folder's own file.
    @Test func dryRunRunNowAndWatcherAgreeOnNestedFolders() throws {
        // Dry Run / rule test: walk + preview.
        let dry = try fixture()
        var previewed: [String] = []
        RuleEngine.forEachEntry(root: dry.outer.path, maxDepth: nil, skipping: dry.nested) { entry in
            if RuleEngine.previewFile(path: entry.path, depth: entry.depth, rules: dry.rules, root: dry.outer.path, nestedRoots: dry.nested) != nil {
                previewed.append(entry.path)
            }
        }
        #expect(previewed == [dry.outerFile])

        // Run Now: walk + run.
        let manual = try fixture()
        for entry in RuleEngine.walkEntries(root: manual.outer.path, maxDepth: nil, skipping: manual.nested) {
            _ = RuleEngine.run(path: entry.path, depth: entry.depth, rules: manual.rules, batchId: "now", root: manual.outer.path, nestedRoots: manual.nested)
        }
        #expect(FinderTags.currentColorName(manual.outerFile) == "Red")
        #expect(FinderTags.currentColorName(manual.inboxFile) == "")

        // Watcher: a rescan of the outer folder (dropped events).
        let rescan = try fixture()
        WatcherCoordinator(db: rescan.db).handle(event: .rescanSubtree(rescan.outer.path))
        #expect(FinderTags.currentColorName(rescan.outerFile) == "Red")
        #expect(FinderTags.currentColorName(rescan.inboxFile) == "")

        // Watcher: the scheduled re-check of time-dependent rules.
        let recheck = try fixture()
        WatcherCoordinator(db: recheck.db).performRecheck()
        #expect(FinderTags.currentColorName(recheck.outerFile) == "Red")
        #expect(FinderTags.currentColorName(recheck.inboxFile) == "")

        // Watcher: catching up after the disk comes back.
        let catchUp = try fixture()
        WatcherCoordinator(db: catchUp.db).performCatchUp(root: catchUp.outer.path)
        #expect(FinderTags.currentColorName(catchUp.outerFile) == "Red")
        #expect(FinderTags.currentColorName(catchUp.inboxFile) == "")
    }

    @Test func liveEventInNestedFolderUsesOnlyThatFoldersRules() throws {
        let f = try fixture()
        WatcherCoordinator(db: f.db).handle(path: f.inboxFile)
        #expect(FinderTags.currentColorName(f.inboxFile) == "")
    }

    // MARK: - A move into a nested watched folder ends the pass

    private func moveIntoInboxFixture() -> (outer: TempDir, inbox: String, file: String, moved: String, rules: [Rule]) {
        let outer = TempDir()
        let inbox = outer.dir("_Hoje")
        let file = outer.file("report.txt", contents: "r")
        let moved = (inbox as NSString).appendingPathComponent("report.txt")
        let toInbox = makeRule(
            name: "to inbox",
            actions: [makeAction(.moveToFolder, .object(["destination": .string(inbox)]))]
        )
        let label = makeRule(
            name: "label everything",
            recursionDepth: nil,
            actions: [makeAction(.setColorLabel, .object(["color": .string("Red")]))]
        )
        return (outer, inbox, file, moved, [toInbox, label])
    }

    @Test func runStopsAfterMovingIntoNestedWatchedFolder() {
        let f = moveIntoInboxFixture()
        let result = RuleEngine.run(path: f.file, depth: 0, rules: f.rules, batchId: "inbox", root: f.outer.path, nestedRoots: [f.inbox])
        #expect(result.matched == ["to inbox"])
        #expect(FileManager.default.fileExists(atPath: f.moved))
        #expect(FinderTags.currentColorName(f.moved) == "")
    }

    @Test func previewStopsAfterMovingIntoNestedWatchedFolder() throws {
        let f = moveIntoInboxFixture()
        let preview = try #require(RuleEngine.previewFile(path: f.file, depth: 0, rules: f.rules, root: f.outer.path, nestedRoots: [f.inbox]))
        #expect(preview.rules.map(\.ruleName) == ["to inbox"])
    }

    @Test func moveIntoPlainSubfolderStillContinues() {
        let f = moveIntoInboxFixture()
        let result = RuleEngine.run(path: f.file, depth: 0, rules: f.rules, batchId: "plain", root: f.outer.path)
        #expect(result.matched == ["to inbox", "label everything"])
        #expect(FinderTags.currentColorName(f.moved) == "Red")
    }
}
