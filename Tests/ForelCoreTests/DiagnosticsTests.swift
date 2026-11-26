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

/// Folders a scan can't list are reported (once) instead of silently
/// skipped, on every path that walks a folder.
@Suite(.serialized) struct UnreadableFolderTests {
    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [LoggedEvent] = []
        func add(_ event: LoggedEvent) { lock.lock(); stored.append(event); lock.unlock() }
        var events: [LoggedEvent] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    private func lockedFolder() -> (TempDir, String) {
        let temp = TempDir()
        _ = temp.file("visible.txt", contents: "v")
        let locked = temp.dir("Locked")
        _ = try? "x".write(toFile: (locked as NSString).appendingPathComponent("hidden.txt"), atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        return (temp, locked)
    }

    private func unlock(_ path: String) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    @Test func scanReportsAnUnreadableSubfolderOnceAndKeepsGoing() {
        UnreadableFolders.reset()
        let collector = Collector()
        UnreadableFolders.setHandler { collector.add($0) }
        defer { UnreadableFolders.setHandler(nil); UnreadableFolders.reset() }
        let (temp, locked) = lockedFolder()
        defer { unlock(locked) }

        // Dry Run and Run Now both walk the folder this way.
        let paths = RuleEngine.walkEntries(root: temp.path, maxDepth: nil).map(\.path)
        #expect(paths.contains((temp.path as NSString).appendingPathComponent("visible.txt")))
        #expect(collector.events.count == 1)
        #expect(collector.events.first?.kind == .folderUnreadable)
        #expect(collector.events.first?.path == locked)
        #expect(collector.events.first?.isError == true)

        // A second pass within the quiet period doesn't repeat it.
        _ = RuleEngine.walkEntries(root: temp.path, maxDepth: nil)
        #expect(collector.events.count == 1)
    }

    @Test func watcherScanReportsTheUnreadableSubfolderToo() throws {
        UnreadableFolders.reset()
        let collector = Collector()
        UnreadableFolders.setHandler { collector.add($0) }
        defer { UnreadableFolders.setHandler(nil); UnreadableFolders.reset() }
        let (temp, locked) = lockedFolder()
        defer { unlock(locked) }
        let db = try Database(path: ":memory:")
        let folder = WatchedFolder(path: temp.path)
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "any", recursionDepth: nil)
        rule.conditions = [makeCondition(.name, .contains, "e", ruleId: rule.id)]
        try db.insertRule(rule)

        WatcherCoordinator(db: db).handle(event: .rescanSubtree(temp.path))
        #expect(collector.events.map(\.path) == [locked])
    }

    @Test func reportsAgainAfterTheQuietPeriod() {
        UnreadableFolders.reset()
        let collector = Collector()
        UnreadableFolders.setHandler { collector.add($0) }
        defer { UnreadableFolders.setHandler(nil); UnreadableFolders.reset() }
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        let start = Date()
        UnreadableFolders.report(path: "/x", error: error, now: start)
        UnreadableFolders.report(path: "/x", error: error, now: start.addingTimeInterval(60))
        UnreadableFolders.report(path: "/x", error: error, now: start.addingTimeInterval(UnreadableFolders.quietPeriod + 1))
        #expect(collector.events.count == 2)
        #expect(collector.events.first?.message.contains("isn't allowed") == true)
    }
}

@Suite struct DiagnosticsReportTests {
    @Test func reportShortensHomePathsAndListsEachSection() {
        let failure = HistoryEntry(batchId: "b", ruleId: nil, ruleName: "Move PDFs", actionKind: .moveToFolder, originalPath: "/Users/ana/Downloads/a.pdf", resultPath: "/Users/ana/Downloads/a.pdf", undo: .null, reversible: false, status: .failed, message: "Destination missing")
        let report = DiagnosticsReport.make(DiagnosticsReport.Input(
            appVersion: "1.4.0",
            build: "42",
            systemVersion: "Version 15.1",
            isPaused: false,
            folders: [.init(path: "/Users/ana/Downloads", enabled: true, ruleCount: 3, enabledRuleCount: 2)],
            issues: [],
            events: [LoggedEvent(kind: .folderUnreadable, path: "/Users/ana/Downloads/Locked", message: "skipped", isError: true)],
            failures: [failure],
            homeDirectory: "/Users/ana"
        ))
        #expect(report.contains("Forel: 1.4.0 (42)"))
        #expect(report.contains("Database schema: \(Database.currentSchemaVersion)"))
        #expect(report.contains("[on] ~/Downloads: 2 of 3 rules enabled"))
        #expect(report.contains("no problems found"))
        #expect(report.contains("“Move PDFs” on ~/Downloads/a.pdf: Destination missing"))
        #expect(report.contains("Folder can't be read [error] ~/Downloads/Locked: skipped"))
        #expect(!report.contains("/Users/ana"))
    }
}

/// A coarse guard against the folder scan getting dramatically slower:
/// walking and previewing a few thousand files must stay well within
/// seconds on any Mac that runs the tests.
@Suite struct LargeFolderPerformanceTests {
    @Test func walkingAndPreviewingThreeThousandFilesStaysFast() {
        let temp = TempDir()
        for dirIndex in 0..<30 {
            let dir = temp.dir("dir\(dirIndex)")
            for fileIndex in 0..<100 {
                FileManager.default.createFile(atPath: (dir as NSString).appendingPathComponent("file\(fileIndex).txt"), contents: Data("x".utf8))
            }
        }
        let rule = makeRule(name: "txt", conditions: [makeCondition(.name, .contains, "file")], recursionDepth: nil)

        let clock = ContinuousClock()
        var previewed = 0
        let elapsed = clock.measure {
            RuleEngine.forEachEntry(root: temp.path, maxDepth: nil) { entry in
                if RuleEngine.previewFile(path: entry.path, depth: entry.depth, rules: [rule], root: temp.path) != nil {
                    previewed += 1
                }
            }
        }
        #expect(previewed == 3000)
        #expect(elapsed < .seconds(20), "Scanning 3,000 files took \(elapsed)")
    }
}
