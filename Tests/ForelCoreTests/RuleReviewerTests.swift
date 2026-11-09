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

struct RuleReviewerTests {
    private func sampleRule() -> Rule {
        var rule = Rule(folderId: "folder-1", name: "Invoices", enabled: true, conditionMatch: .all, recursionDepth: 0)
        rule.conditions = [
            Condition(ruleId: rule.id, kind: .extension_, operator: .is, value: "pdf"),
            Condition(ruleId: rule.id, kind: .name, operator: .contains, value: "invoice"),
        ]
        rule.actions = [
            Action(ruleId: rule.id, kind: .moveToFolder, params: .object([ActionParam.destination: .string("/Users/me/Invoices")]), position: 0),
            Action(ruleId: rule.id, kind: .upload, params: .object([ActionParam.uploadURL: .string("sftp://me:secret@host.test/in/")]), position: 1),
        ]
        rule.priority = 3
        return rule
    }

    private func answer(_ content: String) -> Data {
        let body: [String: Any] = ["choices": [["message": ["role": "assistant", "content": content]]]]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        try #require(request.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
    }

    @Test func analysisNeedsNoInputAndSendsTheRuleItsFolderAndSiblingsWithoutUploadPasswords() throws {
        let rule = sampleRule()
        let sibling = Rule(folderId: "folder-1", name: "Screenshots", enabled: true)
        let request = try RuleReviewer.reviewRequest(
            rule: rule,
            folderPath: "/Users/me/Downloads",
            otherRules: [rule, sibling],
            settings: AISettings(enabled: true, provider: .deepseek),
            apiKey: "sk-test",
            language: "Portuguese",
            macOSVersion: "26.0"
        )
        #expect(request.url?.absoluteString == "https://api.deepseek.com/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        let body = try body(request)
        #expect((body["response_format"] as? [String: String])?["type"] == "json_object")
        let messages = try #require(body["messages"] as? [[String: String]])
        let system = try #require(messages.first?["content"])
        #expect(system.contains("in Portuguese"))
        #expect(system.contains("work out what the rule is meant to achieve"))
        let user = try #require(messages.last?["content"])
        #expect(user.contains("Watched folder: /Users/me/Downloads"))
        #expect(user.contains("\"kind\" : \"extension\""))
        #expect(user.contains("/Users/me/Invoices"))
        #expect(user.contains("Screenshots"))
        #expect(!user.contains("secret"))
        // The reviewed rule isn't repeated among the other rules.
        #expect(user.components(separatedBy: "\"Invoices\"").count == 2)
    }

    @Test func editRequestCarriesOnlyTheChosenSuggestions() throws {
        let rule = sampleRule()
        let chosen = [
            RuleReviewSuggestion(id: 2, category: .efficiency, title: "Check the kind first", detail: "Use kind is pdf."),
            RuleReviewSuggestion(id: 4, category: .safety, title: "Skip existing files", detail: ""),
        ]
        let request = try RuleReviewer.editRequest(
            rule: rule, folderPath: "/Users/me/Downloads", suggestions: chosen,
            settings: AISettings(enabled: true, provider: .deepseek), apiKey: "sk-test",
            language: "Portuguese", macOSVersion: "26.0"
        )
        let messages = try #require(try body(request)["messages"] as? [[String: String]])
        #expect(messages[0]["content"]?.contains("applies every accepted suggestion, and change nothing else") == true)
        let user = try #require(messages[1]["content"])
        #expect(user.contains("1. Check the kind first: Use kind is pdf."))
        #expect(user.contains("2. Skip existing files"))
        #expect(!user.contains("secret"))

        #expect(throws: ScriptGenerationError.self) {
            try RuleReviewer.editRequest(rule: rule, folderPath: nil, suggestions: [], settings: AISettings(enabled: true), apiKey: "k")
        }
    }

    @Test func customServicesDontGetJSONModeAndMissingSettingsAreExplained() throws {
        let rule = sampleRule()
        let custom = AISettings(enabled: true, provider: .custom, baseURL: "http://localhost:11434/v1", model: "llama")
        let request = try RuleReviewer.reviewRequest(rule: rule, folderPath: nil, otherRules: [], settings: custom, apiKey: "k")
        #expect(try body(request)["response_format"] == nil)

        #expect(throws: ScriptGenerationError.self) {
            try RuleReviewer.reviewRequest(rule: rule, folderPath: nil, otherRules: [], settings: AISettings(enabled: true), apiKey: " ")
        }
        #expect(throws: ScriptGenerationError.self) {
            try RuleReviewer.reviewRequest(rule: rule, folderPath: nil, otherRules: [], settings: AISettings(enabled: true, provider: .alibabaSingapore), apiKey: "sk-sp-abc")
        }
    }

    @Test func promptsListEveryConditionAndAction() {
        for prompt in [RuleReviewer.reviewSystemPrompt(language: "English", macOSVersion: "26.0"),
                       RuleReviewer.editSystemPrompt(language: "English", macOSVersion: "26.0")] {
            for kind in RuleSchema.conditionKinds {
                #expect(prompt.contains("- \(kind.rawValue) ("), "missing condition \(kind.rawValue)")
            }
            for kind in RuleSchema.actionKinds {
                #expect(prompt.contains("- \(kind.rawValue) ("), "missing action \(kind.rawValue)")
            }
        }
    }

    @Test func reviewReadsSuggestionsInAnyWrapping() throws {
        let content = """
        Here is my review:
        ```json
        {"summary": "Moves invoices.", "suggestions": [
          {"category": "efficiency", "title": "Use kind", "detail": "Check the cheap condition first."},
          {"category": "nonsense", "title": "Other idea"},
          {"category": "problem"}]}
        ```
        """
        let review = try RuleReviewer.review(fromResponse: answer(content), statusCode: 200)
        #expect(review.summary == "Moves invoices.")
        #expect(review.suggestions.map(\.category) == [.efficiency, .other])
        #expect(review.suggestions.map(\.id) == [0, 1])
        #expect(review.suggestions[1].title == "Other idea")
        #expect(review.suggestions[1].detail.isEmpty)

        let good = try RuleReviewer.review(fromResponse: answer(#"{"summary": "Already good.", "suggestions": []}"#), statusCode: 200)
        #expect(good.suggestions.isEmpty)
    }

    @Test func editedRuleKeepsTheRulesIdentityAndRestoresTheUploadURL() throws {
        let rule = sampleRule()
        let content = """
        {"rule": {"conditionMatch": "all", "recursionDepth": null,
           "conditionGroups": [{"match": "all", "conditions": [
             {"kind": "kind", "operator": "is", "value": "pdf"},
             {"kind": "size_bytes", "operator": "less_than", "value": 10}]}],
           "actions": [
             {"kind": "rename", "params": {"pattern": "{current_date} {name}.{extension}"}},
             {"kind": "move_to_folder", "params": {"destination": "/Users/me/Invoices", "on_conflict": "skip"}},
             {"kind": "upload", "params": {"upload_url": "sftp://host.test/in/"}}]},
         "explanation": "Adds a date to the name."}
        """
        let edit = try RuleReviewer.edit(fromResponse: answer(content), statusCode: 200, rule: rule)
        #expect(edit.explanation == "Adds a date to the name.")
        let improved = edit.rule
        #expect(improved.id == rule.id)
        #expect(improved.folderId == rule.folderId)
        #expect(improved.name == rule.name)
        #expect(improved.enabled == rule.enabled)
        #expect(improved.priority == rule.priority)
        #expect(improved.recursionDepth == nil)
        #expect(improved.conditions.map(\.kind) == [.kind, .sizeBytes])
        #expect(improved.conditions[1].value == "10")
        #expect(improved.conditions.allSatisfy { $0.ruleId == rule.id })
        #expect(improved.actions.map(\.kind) == [.rename, .moveToFolder, .upload])
        #expect(improved.actions.map(\.position) == [0, 1, 2])
        #expect(improved.actions[2].params[ActionParam.uploadURL]?.stringValue == "sftp://me:secret@host.test/in/")
    }

    @Test func unusableEditedRuleIsExplained() throws {
        let rule = sampleRule()
        let content = """
        {"rule": {"conditionMatch": "all", "conditionGroups": [{"match": "all", "conditions": [
             {"kind": "file_color", "operator": "is", "value": "red"},
             {"kind": "extension", "operator": "greater_than", "value": "pdf"}]}],
           "actions": [{"kind": "teleport", "params": {}}, {"kind": "rename", "params": {"pattern": ""}}]}}
        """
        do {
            _ = try RuleReviewer.edit(fromResponse: answer(content), statusCode: 200, rule: rule)
            Issue.record("expected the edit to be rejected")
        } catch let error as RuleEditError {
            #expect(error.problems.contains { $0.contains("file_color") })
            #expect(error.problems.contains { $0.contains("greater_than") })
            #expect(error.problems.contains { $0.contains("teleport") })
            #expect(error.problems.contains("Rename pattern cannot be empty"))
        }
        #expect(throws: ScriptGenerationError.self) {
            try RuleReviewer.edit(fromResponse: answer(#"{"explanation": "done"}"#), statusCode: 200, rule: rule)
        }
    }

    @Test func missingScopeKeepsTheRulesAndAnUnchangedEditIsRejected() throws {
        let rule = sampleRule()
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(RuleBlueprint(rule))) as? [String: Any])
        object.removeValue(forKey: "recursionDepth")
        let unchanged = try JSONSerialization.data(withJSONObject: ["rule": object])
        #expect(throws: ScriptGenerationError.self) {
            try RuleReviewer.edit(fromResponse: answer(String(decoding: unchanged, as: UTF8.self)), statusCode: 200, rule: rule)
        }

        object["recursionDepth"] = 2
        let changed = try JSONSerialization.data(withJSONObject: ["rule": object])
        let deeper = try RuleReviewer.edit(fromResponse: answer(String(decoding: changed, as: UTF8.self)), statusCode: 200, rule: rule)
        #expect(deeper.rule.recursionDepth == 2)
        #expect(deeper.rule.actions[1].params[ActionParam.uploadURL]?.stringValue == "sftp://me:secret@host.test/in/")
    }

    @Test func errorsAndUnreadableAnswersAreExplained() {
        let refused = Data(#"{"error":{"message":"Invalid key"}}"#.utf8)
        #expect(throws: ScriptGenerationError.self) {
            try RuleReviewer.review(fromResponse: refused, statusCode: 401)
        }
        #expect(throws: ScriptGenerationError.self) {
            try RuleReviewer.review(fromResponse: answer("I can't help with that."), statusCode: 200)
        }
        #expect(throws: ScriptGenerationError.self) {
            try RuleReviewer.review(fromResponse: answer("{}"), statusCode: 200)
        }
    }

    @Test func jsonViewShowsTheCompactRuleWithoutIDsOrUploadPasswords() throws {
        let rule = sampleRule()
        let json = RuleReviewer.json(for: rule)
        #expect(json.contains("\"kind\" : \"move_to_folder\""))
        #expect(json.contains("/Users/me/Invoices"))
        #expect(json.contains("\"recursionDepth\" : 0"))
        #expect(!json.contains(rule.id))
        #expect(!json.contains("secret"))
        // It's the same format an edit is read back from.
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        var changed = object
        changed["recursionDepth"] = 1
        let content = String(decoding: try JSONSerialization.data(withJSONObject: ["rule": changed]), as: UTF8.self)
        #expect(try RuleReviewer.edit(fromContent: content, rule: rule).rule.recursionDepth == 1)
    }

    @Test func repliesContinueTheConversationInOrder() throws {
        let rule = sampleRule()
        let settings = AISettings(enabled: true, provider: .deepseek)
        var review = try RuleReviewer.reviewConversation(rule: rule, folderPath: nil, otherRules: [], language: "English", macOSVersion: "26.0")
        review.messages.append(.init(role: "assistant", content: #"{"summary": "OK", "suggestions": []}"#))
        let next = try RuleReviewer.appending("  keep the upload, but only for PDFs  ", to: review)
        #expect(next.mode == .review)
        #expect(next.messages.map(\.role) == ["system", "user", "assistant", "user"])
        let last = try #require(next.messages.last?.content)
        #expect(last.contains("My reply to your review: keep the upload, but only for PDFs"))
        #expect(last.contains("full, updated list of suggestions"))

        let request = try RuleReviewer.request(for: next, settings: settings, apiKey: "sk-test")
        let messages = try #require(try body(request)["messages"] as? [[String: String]])
        #expect(messages.map { $0["role"] ?? "" } == ["system", "user", "assistant", "user"])
        #expect(messages[2]["content"] == #"{"summary": "OK", "suggestions": []}"#)

        let suggestion = RuleReviewSuggestion(id: 0, category: .other, title: "x", detail: "")
        let edit = try RuleReviewer.editConversation(rule: rule, folderPath: nil, suggestions: [suggestion])
        let editReply = try RuleReviewer.appending("why skip?", to: edit)
        #expect(editReply.messages.last?.content.contains("My reply about the rule you wrote: why skip?") == true)

        #expect(throws: ScriptGenerationError.self) { try RuleReviewer.appending("   ", to: review) }
    }

    @Test func repliesAreReadInTheConversationsMode() throws {
        let rule = sampleRule()
        let reviewed = try RuleReviewer.parseReply(#"{"summary": "Better now.", "suggestions": [{"title": "Add a tag"}]}"#, mode: .review, rule: rule)
        guard case .review(let review) = reviewed else { Issue.record("expected a review"); return }
        #expect(review.suggestions.map(\.title) == ["Add a tag"])

        // A reply about the written rule may keep it as it is: that's an
        // answer, not a failure.
        let unchanged = #"{"rule": \#(RuleReviewer.json(for: rule)), "explanation": "Skipping avoids overwriting."}"#
        let answered = try RuleReviewer.parseReply(unchanged, mode: .edit, rule: rule)
        guard case .edit(let edit) = answered else { Issue.record("expected an edit"); return }
        #expect(edit.explanation == "Skipping avoids overwriting.")
        #expect(edit.rule.actions[1].params[ActionParam.uploadURL]?.stringValue == "sftp://me:secret@host.test/in/")
    }

    @Test func theUsersGoalGuidesTheAnalysisAndTheEdit() throws {
        let rule = sampleRule()
        let settings = AISettings(enabled: true, provider: .deepseek)
        let withGoal = try RuleReviewer.reviewRequest(
            rule: rule, folderPath: nil, otherRules: [], goal: "  file invoices by year, never delete  ",
            settings: settings, apiKey: "sk-test"
        )
        let messages = try #require(try body(withGoal)["messages"] as? [[String: String]])
        #expect(messages[0]["content"]?.contains("judge the rule against that goal") == true)
        #expect(messages[1]["content"]?.contains("What this rule should achieve, in my words: file invoices by year, never delete") == true)

        let without = try RuleReviewer.reviewUserMessage(rule: rule, folderPath: nil, otherRules: [], goal: "   ")
        #expect(!without.contains("What this rule should achieve"))

        let suggestion = RuleReviewSuggestion(id: 0, category: .other, title: "x", detail: "")
        let edit = try RuleReviewer.editUserMessage(rule: rule, folderPath: nil, suggestions: [suggestion], goal: "file invoices")
        #expect(edit.contains("What this rule should achieve, in my words: file invoices"))
    }

    @Test func languageComesFromThePreferredLanguages() {
        #expect(RuleReviewer.preferredLanguageName(["pt-BR"]) == "Portuguese")
        #expect(RuleReviewer.preferredLanguageName(["en-US"]) == "English")
        #expect(RuleReviewer.preferredLanguageName([]) == "English")
    }
}
