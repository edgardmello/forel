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

    @Test func requestSendsTheRuleItsFolderAndSiblingsWithoutUploadPasswords() throws {
        let rule = sampleRule()
        let sibling = Rule(folderId: "folder-1", name: "Screenshots", enabled: true)
        let request = try RuleReviewer.request(
            rule: rule,
            folderPath: "/Users/me/Downloads",
            otherRules: [rule, sibling],
            goal: "file my invoices",
            settings: AISettings(enabled: true, provider: .deepseek),
            apiKey: "sk-test",
            language: "Portuguese",
            macOSVersion: "26.0"
        )
        #expect(request.url?.absoluteString == "https://api.deepseek.com/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        let body = try #require(request.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect((body["response_format"] as? [String: String])?["type"] == "json_object")
        let messages = try #require(body["messages"] as? [[String: String]])
        let system = try #require(messages.first?["content"])
        #expect(system.contains("in Portuguese"))
        let user = try #require(messages.last?["content"])
        #expect(user.contains("Watched folder: /Users/me/Downloads"))
        #expect(user.contains("file my invoices"))
        #expect(user.contains("\"kind\" : \"extension\""))
        #expect(user.contains("/Users/me/Invoices"))
        #expect(user.contains("Screenshots"))
        #expect(!user.contains("secret"))
        // The reviewed rule isn't repeated among the other rules.
        #expect(user.components(separatedBy: "\"Invoices\"").count == 2)
    }

    @Test func customServicesDontGetJSONModeAndMissingSettingsAreExplained() throws {
        let rule = sampleRule()
        let custom = AISettings(enabled: true, provider: .custom, baseURL: "http://localhost:11434/v1", model: "llama")
        let request = try RuleReviewer.request(rule: rule, folderPath: nil, otherRules: [], goal: "", settings: custom, apiKey: "k")
        let body = try #require(request.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(body["response_format"] == nil)

        #expect(throws: ScriptGenerationError.self) {
            try RuleReviewer.request(rule: rule, folderPath: nil, otherRules: [], goal: "", settings: AISettings(enabled: true), apiKey: " ")
        }
        #expect(throws: ScriptGenerationError.self) {
            try RuleReviewer.request(rule: rule, folderPath: nil, otherRules: [], goal: "", settings: AISettings(enabled: true, provider: .alibabaSingapore), apiKey: "sk-sp-abc")
        }
    }

    @Test func promptListsEveryConditionAndAction() {
        let prompt = RuleReviewer.systemPrompt(language: "English", macOSVersion: "26.0")
        for kind in RuleSchema.conditionKinds {
            #expect(prompt.contains("- \(kind.rawValue) ("), "missing condition \(kind.rawValue)")
        }
        for kind in RuleSchema.actionKinds {
            #expect(prompt.contains("- \(kind.rawValue) ("), "missing action \(kind.rawValue)")
        }
    }

    @Test func improvedRuleKeepsTheRulesIdentityAndRestoresTheUploadURL() throws {
        let rule = sampleRule()
        let content = """
        ```json
        {"summary": "Moves invoices.", "suggestions": [
          {"category": "efficiency", "title": "Use kind", "detail": "Check the cheap condition first."},
          {"category": "nonsense", "title": "Other idea"}],
         "improvedRule": {"conditionMatch": "all", "recursionDepth": null,
           "conditionGroups": [{"match": "all", "conditions": [
             {"kind": "kind", "operator": "is", "value": "pdf"},
             {"kind": "size_bytes", "operator": "less_than", "value": 10}]}],
           "actions": [
             {"kind": "rename", "params": {"pattern": "{current_date} {name}.{extension}"}},
             {"kind": "move_to_folder", "params": {"destination": "/Users/me/Invoices", "on_conflict": "skip"}},
             {"kind": "upload", "params": {"upload_url": "sftp://host.test/in/"}}]},
         "improvedRuleExplanation": "Adds a date to the name."}
        ```
        """
        let review = try RuleReviewer.review(fromResponse: answer(content), statusCode: 200, rule: rule)
        #expect(review.summary == "Moves invoices.")
        #expect(review.suggestions.map(\.category) == [.efficiency, .other])
        #expect(review.suggestions[1].title == "Other idea")
        #expect(review.improvedRuleExplanation == "Adds a date to the name.")
        #expect(review.improvedRuleProblems.isEmpty)

        let improved = try #require(review.improvedRule)
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

    @Test func unusableImprovedRuleIsExplainedAndSuggestionsSurvive() throws {
        let rule = sampleRule()
        let content = """
        Here is my review:
        {"summary": "OK.", "suggestions": [{"category": "problem", "title": "Loop", "detail": "It renames forever."}],
         "improvedRule": {"conditionMatch": "all", "conditionGroups": [{"match": "all", "conditions": [
             {"kind": "file_color", "operator": "is", "value": "red"},
             {"kind": "extension", "operator": "greater_than", "value": "pdf"}]}],
           "actions": [{"kind": "teleport", "params": {}}, {"kind": "rename", "params": {"pattern": ""}}]}}
        Hope it helps.
        """
        let review = try RuleReviewer.review(fromResponse: answer(content), statusCode: 200, rule: rule)
        #expect(review.suggestions.count == 1)
        #expect(review.improvedRule == nil)
        #expect(review.improvedRuleProblems.contains { $0.contains("file_color") })
        #expect(review.improvedRuleProblems.contains { $0.contains("greater_than") })
        #expect(review.improvedRuleProblems.contains { $0.contains("teleport") })
        #expect(review.improvedRuleProblems.contains("Rename pattern cannot be empty"))
    }

    @Test func missingScopeKeepsTheRulesAndAnUnchangedVersionIsDropped() throws {
        let rule = sampleRule()
        let blueprint = RuleBlueprint(rule)
        var data = try JSONEncoder().encode(blueprint)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "recursionDepth")
        data = try JSONSerialization.data(withJSONObject: ["summary": "Already good.", "suggestions": [], "improvedRule": object])
        let review = try RuleReviewer.review(fromResponse: answer(String(decoding: data, as: UTF8.self)), statusCode: 200, rule: rule)
        #expect(review.summary == "Already good.")
        #expect(review.improvedRule == nil)
        #expect(review.improvedRuleProblems.isEmpty)

        object["recursionDepth"] = 2
        let changed = try JSONSerialization.data(withJSONObject: ["summary": "Deeper.", "improvedRule": object])
        let deeper = try RuleReviewer.review(fromResponse: answer(String(decoding: changed, as: UTF8.self)), statusCode: 200, rule: rule)
        #expect(deeper.improvedRule?.recursionDepth == 2)
    }

    @Test func errorsAndUnreadableAnswersAreExplained() {
        let rule = sampleRule()
        let refused = Data(#"{"error":{"message":"Invalid key"}}"#.utf8)
        #expect(throws: ScriptGenerationError.self) {
            try RuleReviewer.review(fromResponse: refused, statusCode: 401, rule: rule)
        }
        #expect(throws: ScriptGenerationError.self) {
            try RuleReviewer.review(fromResponse: answer("I can't help with that."), statusCode: 200, rule: rule)
        }
        #expect(throws: ScriptGenerationError.self) {
            try RuleReviewer.review(fromResponse: answer("{}"), statusCode: 200, rule: rule)
        }
    }

    @Test func languageComesFromThePreferredLanguages() {
        #expect(RuleReviewer.preferredLanguageName(["pt-BR"]) == "Portuguese")
        #expect(RuleReviewer.preferredLanguageName(["en-US"]) == "English")
        #expect(RuleReviewer.preferredLanguageName([]) == "English")
    }
}
