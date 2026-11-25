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

@Suite struct DailyInboxTests {
    private let wait = "1 day"

    private func move(_ destination: String) -> Action {
        makeAction(.moveToFolder, .object([ActionParam.destination: .string(destination)]))
    }

    @Test func defaultChoicesKeepCleanupTurnOffSweepsAndMoveSorters() {
        let dupes = makeRule(name: "Dupes", conditions: [makeCondition(.duplicate, .is, "same_folder_tree")], actions: [makeAction(.moveToTrash, .object([:]))])
        let today = makeRule(name: "Today", conditions: [makeCondition(.dateAdded, .withinLast, "1 day")], actions: [
            makeAction(.sortIntoSubfolder, .object([ActionParam.subfolder: .string("{year}-{month}-{day}")])),
        ])
        let docs = makeRule(name: "Docs", conditions: [makeCondition(.extension_, .is, "pdf")], actions: [move("/tmp/docs")])
        let tagOnly = makeRule(name: "Tag", conditions: [makeCondition(.createdAt, .olderThan, "30 days")], actions: [
            makeAction(.addTag, .object([ActionParam.tags: .stringArray(["old"])])),
        ])
        var off = docs
        off.enabled = false

        #expect(DailyInbox.defaultChoice(for: dupes) == .keepHere)
        #expect(DailyInbox.defaultChoice(for: today) == .turnOff)
        #expect(DailyInbox.defaultChoice(for: docs) == .moveToInbox)
        #expect(DailyInbox.defaultChoice(for: tagOnly) == .keepHere)
        #expect(DailyInbox.defaultChoice(for: off) == .keepHere)
    }

    @Test func waitingAddsAGroupToAnAllRule() throws {
        let rule = makeRule(name: "Docs", conditions: [makeCondition(.extension_, .is, "pdf")], actions: [move("/tmp/docs")])

        let waiting = try #require(DailyInbox.waiting(rule, days: 1, inFolder: "inbox"))

        #expect(waiting.folderId == "inbox")
        #expect(waiting.id == rule.id)
        #expect(waiting.conditionMatch == .all)
        #expect(waiting.conditionGroups.count == 2)
        #expect(waiting.conditionGroups[1].conditions.map(\.kind) == [.dateAdded])
        #expect(waiting.conditionGroups[1].conditions[0].operator == .olderThan)
        #expect(waiting.conditionGroups[1].conditions[0].value == wait)
    }

    @Test func waitingTurnsASingleAnyGroupRuleIntoAll() throws {
        let rule = makeRule(name: "Docs", conditionMatch: .any, conditionGroups: [
            ConditionGroup(match: .any, conditions: [
                makeCondition(.extension_, .is, "pdf"),
                makeCondition(.extension_, .is, "docx"),
            ]),
        ], actions: [move("/tmp/docs")])

        let waiting = try #require(DailyInbox.waiting(rule, days: 2, inFolder: "inbox"))

        #expect(waiting.conditionMatch == .all)
        #expect(waiting.conditionGroups[0].match == .any)
        #expect(waiting.conditionGroups[1].conditions[0].value == "2 days")
    }

    @Test func waitingAddsTheWaitToEachGroupOfAnAnyRule() throws {
        let rule = makeRule(name: "AI images", conditionMatch: .any, conditionGroups: [
            ConditionGroup(match: .all, conditions: [makeCondition(.name, .matchesRegex, "gemini"), makeCondition(.kind, .is, "image")]),
            ConditionGroup(match: .all, conditions: [makeCondition(.downloadedFromWebsite, .contains, "gemini"), makeCondition(.kind, .is, "image")]),
        ], actions: [move("/tmp/ai")])

        let waiting = try #require(DailyInbox.waiting(rule, days: 1, inFolder: "inbox"))

        #expect(waiting.conditionMatch == .any)
        #expect(waiting.conditionGroups.count == 2)
        #expect(waiting.conditionGroups.allSatisfy { $0.conditions.last?.kind == .dateAdded })
    }

    @Test func waitingRefusesRulesItCannotGateSafely() {
        let none = makeRule(name: "Not these", conditionMatch: .none, conditions: [makeCondition(.extension_, .is, "tmp")], actions: [move("/tmp/x")])
        let anyOfAnys = makeRule(name: "Mixed", conditionMatch: .any, conditionGroups: [
            ConditionGroup(match: .any, conditions: [makeCondition(.extension_, .is, "a"), makeCondition(.extension_, .is, "b")]),
            ConditionGroup(match: .all, conditions: [makeCondition(.extension_, .is, "c")]),
        ], actions: [move("/tmp/x")])

        #expect(DailyInbox.waiting(none, days: 1, inFolder: "inbox") == nil)
        #expect(DailyInbox.waiting(anyOfAnys, days: 1, inFolder: "inbox") == nil)
    }

    @Test func waitingRuleOnlyMatchesFilesAddedLongEnoughAgo() throws {
        let dir = TempDir()
        let file = dir.file("report.pdf", contents: "x")
        let rule = makeRule(name: "Docs", conditions: [makeCondition(.extension_, .is, "pdf")], actions: [move("/tmp/docs")])
        let waiting = try #require(DailyInbox.waiting(rule, days: 1, inFolder: "inbox"))

        // Just added: the original rule matches, the waiting one doesn't yet.
        #expect(RuleEngine.ruleMatches(rule, path: file, depth: 0))
        #expect(!RuleEngine.ruleMatches(waiting, path: file, depth: 0))
    }

    @Test func intakeRuleMovesEveryFileButFoldersIntoTheInbox() throws {
        let dir = TempDir()
        let inbox = dir.dir("_Hoje")
        let file = dir.file("photo.png", contents: "png")
        let intake = DailyInbox.intakeRule(sourceFolderId: "dl", inboxPath: inbox)

        #expect(intake.enabled)
        #expect(intake.name == "Send new files to _Hoje")
        #expect(!RuleEngine.ruleMatches(intake, path: inbox, depth: 0))

        let result = RuleEngine.run(path: file, depth: 0, rules: [intake], batchId: "intake", root: dir.path)

        #expect(result.history.first?.status == .applied)
        #expect(FileManager.default.fileExists(atPath: (inbox as NSString).appendingPathComponent("photo.png")))
    }
}
