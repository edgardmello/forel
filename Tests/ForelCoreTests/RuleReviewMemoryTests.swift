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
import Testing
@testable import ForelCore

struct RuleReviewMemoryTests {
    private func invoiceRule(id: String = UUID().uuidString, name: String = "Invoices") -> Rule {
        var rule = Rule(id: id, folderId: "folder-1", name: name, enabled: true, conditionMatch: .all, recursionDepth: 0)
        rule.conditions = [Condition(ruleId: rule.id, kind: .extension_, operator: .is, value: "pdf")]
        rule.actions = [
            Action(ruleId: rule.id, kind: .moveToFolder, params: .object([ActionParam.destination: .string("/Users/me/Invoices")]), position: 0),
            Action(ruleId: rule.id, kind: .upload, params: .object([ActionParam.uploadURL: .string("sftp://me:secret@host.test/in/")]), position: 1),
        ]
        return rule
    }

    private let review = RuleReview(summary: "Moves PDFs.", suggestions: [
        RuleReviewSuggestion(id: 0, category: .efficiency, title: "Sort by year", detail: "Use {year}."),
        RuleReviewSuggestion(id: 1, category: .safety, title: "Drop the upload", detail: "Risky."),
    ])

    private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + seconds) }

    /// A review where the first suggestion was applied, the second turned
    /// down, and the result saved.
    private func savedRecord(rule: Rule, folderPath: String? = "/Users/me/Downloads", goal: String = "file invoices by year", time: TimeInterval = 0) throws -> RuleReviewRecord {
        var record = RuleReviewRecord(rule: rule, folderPath: folderPath, goal: goal, review: review, now: at(time))
        record.addReply("keep the upload, it's my accountant", now: at(time + 1))
        var edited = rule
        edited.actions[0].params = .object([ActionParam.destination: .string("/Users/me/Invoices/{year}")])
        record.propose(RuleEdit(rule: edited, explanation: "Added the year."), chosen: [review.suggestions[0]], now: at(time + 2))
        record.finish(.saved, savedRule: edited, now: at(time + 3))
        return record
    }

    @Test func recordFollowsTheSessionWithoutUploadPasswords() throws {
        let rule = invoiceRule()
        let record = try savedRecord(rule: rule)
        #expect(record.ruleId == rule.id)
        #expect(record.goal == "file invoices by year")
        #expect(record.suggestions.map(\.accepted) == [true, false])
        #expect(record.replies == ["keep the upload, it's my accountant"])
        #expect(record.outcome == .saved)
        #expect(record.actionKinds == ["move_to_folder", "upload"].sorted())
        for json in [record.originalRule, record.proposedRule ?? "", record.savedRule ?? ""] {
            #expect(!json.contains("secret"))
        }
        #expect(record.savedRule?.contains("{year}") == true)
    }

    @Test func longTextsAreClipped() {
        var record = RuleReviewRecord(rule: invoiceRule(), folderPath: nil, goal: String(repeating: "g", count: 5_000), review: review)
        for index in 0..<30 { record.addReply("reply \(index)") }
        #expect(record.goal.count == RuleReviewRecord.maximumText + 1)
        #expect(record.replies.count == RuleReviewRecord.maximumReplies)
        #expect(record.replies.last == "reply 29")
    }

    @Test func relevanceFavorsTheSameRuleAndSimilarRulesAndSkipsEmptySessions() throws {
        let rule = invoiceRule()
        let sameRule = try savedRecord(rule: rule, time: 0)
        let similar = try savedRecord(rule: invoiceRule(name: "Bills"), folderPath: "/Users/me/Desktop", goal: "invoices by year", time: 100)
        var unrelated = RuleReviewRecord(
            rule: Rule(folderId: "f2", name: "Screenshots", enabled: true), folderPath: "/Users/me/Pictures", goal: "tidy screenshots", review: review, now: at(200)
        )
        unrelated.finish(.undone, now: at(201))
        // Viewed and closed: says nothing about what the user wants.
        let untouched = RuleReviewRecord(rule: rule, folderPath: "/Users/me/Downloads", goal: "", review: review, now: at(300))

        let chosen = RuleReviewMemory.relevant(
            [untouched, unrelated, similar, sameRule], for: rule, folderPath: "/Users/me/Downloads", goal: "file invoices"
        )
        #expect(chosen.map(\.id) == [sameRule.id, similar.id])
        #expect(RuleReviewMemory.relevant([sameRule], for: rule, folderPath: nil, goal: "", excluding: sameRule.id).isEmpty)
    }

    @Test func promptSectionTellsWhatWasAppliedTurnedDownSaidAndSaved() throws {
        let rule = invoiceRule()
        let record = try savedRecord(rule: rule)
        let section = try #require(RuleReviewMemory.promptSection([record], currentRuleId: rule.id))
        #expect(section.contains("this same rule"))
        #expect(section.contains("- My goal: file invoices by year"))
        #expect(section.contains("- I applied: Sort by year"))
        #expect(section.contains("- I turned down: Drop the upload"))
        #expect(section.contains("- I told the AI: keep the upload, it's my accountant"))
        #expect(section.contains("- I saved the AI's rule."))
        #expect(section.contains("/Users/me/Invoices/{year}"))
        #expect(!section.contains("secret"))

        var changed = record
        var own = rule
        own.name = "Mine"
        own.actions.removeLast()
        changed.finish(.saved, savedRule: own)
        #expect(RuleReviewMemory.promptSection([changed], currentRuleId: rule.id)?.contains("after changing it myself") == true)

        #expect(RuleReviewMemory.promptSection([], currentRuleId: rule.id) == nil)
    }

    @Test func promptSectionStaysWithinItsBudget() throws {
        let rule = invoiceRule()
        let records = try (0..<20).map { index -> RuleReviewRecord in
            var record = try savedRecord(rule: rule, time: TimeInterval(index * 10))
            for reply in 0..<10 { record.addReply(String(repeating: "word ", count: 150) + "\(reply)") }
            return record
        }
        let section = try #require(RuleReviewMemory.promptSection(records, currentRuleId: rule.id))
        #expect(section.count < RuleReviewMemory.maximumPromptCharacters + 600)
    }

    @Test func reviewMessageCarriesPastReviewsOnlyWhenGiven() throws {
        let rule = invoiceRule()
        let record = try savedRecord(rule: rule)
        let with = try RuleReviewer.reviewUserMessage(rule: rule, folderPath: nil, otherRules: [], pastReviews: [record])
        #expect(with.contains("What I decided in earlier reviews"))
        #expect(with.contains("- I turned down: Drop the upload"))
        let without = try RuleReviewer.reviewUserMessage(rule: rule, folderPath: nil, otherRules: [])
        #expect(!without.contains("earlier reviews"))
    }

    @Test func databaseKeepsUpdatesForgetsTheOldestAndClears() throws {
        let db = try Database(path: ":memory:")
        let rule = invoiceRule()
        var record = RuleReviewRecord(rule: rule, folderPath: "/Users/me/Downloads", goal: "goal", review: review, now: at(0))
        try db.saveReviewRecord(record)
        record.finish(.undone, now: at(5))
        try db.saveReviewRecord(record)
        #expect(try db.countReviewRecords() == 1)
        #expect(try db.getReviewRecord(id: record.id) == record)

        for index in 0..<(RuleReviewMemory.maximumStoredRecords + 5) {
            try db.saveReviewRecord(RuleReviewRecord(rule: rule, folderPath: nil, goal: "\(index)", review: review, now: at(TimeInterval(10 + index))))
        }
        #expect(try db.countReviewRecords() == RuleReviewMemory.maximumStoredRecords)
        #expect(try db.getReviewRecord(id: record.id) == nil)
        let newest = try db.getReviewRecords()
        #expect(newest.first?.goal == "\(RuleReviewMemory.maximumStoredRecords + 4)")

        try db.deleteAllReviewRecords()
        #expect(try db.countReviewRecords() == 0)
    }
}
