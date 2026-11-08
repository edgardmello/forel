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

@Suite struct EventLogTests {
    @Test func keepsNewestFirstWithinCapacity() {
        let log = EventLog(capacity: 2)
        log.append(LoggedEvent(kind: .fileArrived, message: "one"))
        log.append(LoggedEvent(kind: .fileArrived, message: "two"))
        log.append(LoggedEvent(kind: .fileArrived, message: "three"))
        #expect(log.entries().map(\.message) == ["three", "two"])
        log.clear()
        #expect(log.entries().isEmpty)
    }

    @Test func outcomeDescribesNoMatchMatchAndFailure() {
        #expect(EventLog.outcome(path: "/a", matched: [], history: []).kind == .noRuleMatched)

        let ok = HistoryEntry(batchId: "b", ruleId: "r", ruleName: "Tidy", actionKind: .addTag, originalPath: "/a", resultPath: "/a", undo: .null, reversible: false, status: .applied)
        let matched = EventLog.outcome(path: "/a", matched: ["Tidy"], history: [ok])
        #expect(matched.kind == .rulesMatched)
        #expect(matched.message == "“Tidy” matched — 1 action applied")
        #expect(!matched.isError)

        var failed = ok
        failed.status = .failed
        #expect(EventLog.outcome(path: "/a", matched: ["Tidy"], history: [failed]).isError)
    }

    @Test func watcherLogsWhatTheRulesMadeOfAFile() throws {
        let db = try Database(path: ":memory:")
        let dir = TempDir()
        let pdf = dir.file("bill.pdf", contents: "x")
        let txt = dir.file("note.txt", contents: "x")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "Tag PDFs")
        rule.conditions = [makeCondition(.extension_, .is, "pdf", ruleId: rule.id)]
        rule.actions = [makeAction(.addTag, .object([ActionParam.tags: .array([.string("Bill")])]), ruleId: rule.id)]
        try db.insertRule(rule)

        let coordinator = WatcherCoordinator(db: db)
        coordinator.handle(path: pdf)
        coordinator.handle(path: txt)

        let events = coordinator.eventLog.entries()
        #expect(events.map(\.kind) == [.noRuleMatched, .rulesMatched])
        #expect(events[1].path == pdf)
        #expect(events[1].ruleNames == ["Tag PDFs"])
        #expect(events[0].path == txt)
    }

    @Test func watcherEventsAreLoggedOnArrival() throws {
        let db = try Database(path: ":memory:")
        let coordinator = WatcherCoordinator(db: db)
        coordinator.enqueue(event: .pathArrived("/tmp/does-not-exist-\(UUID().uuidString).txt"))
        coordinator.enqueue(event: .pathArrived("/tmp/.DS_Store"))
        coordinator.waitForPendingEvents()
        #expect(coordinator.eventLog.entries().map(\.kind) == [.fileArrived])
    }
}
