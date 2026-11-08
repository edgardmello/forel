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

@Suite struct RuleSearchTests {
    private func invoiceRule() -> Rule {
        var rule = makeRule(name: "Invoices")
        rule.conditions = [makeCondition(.extension_, .is, "pdf", ruleId: rule.id)]
        rule.actions = [makeAction(.moveToFolder, .object([ActionParam.destination: .string("/Users/me/Documents/Contas")]), ruleId: rule.id)]
        return rule
    }

    @Test func matchesByName() {
        #expect(RuleSearch.match(invoiceRule(), query: "invo")?.field == .name)
    }

    @Test func matchesConditionKindAndValue() {
        let match = RuleSearch.match(invoiceRule(), query: "extension pdf")
        #expect(match?.field == .condition)
        #expect(match?.text == "Extension is pdf")
    }

    @Test func matchesActionSettingsIgnoringCaseAndAccents() {
        let match = RuleSearch.match(invoiceRule(), query: "CONTÁS")
        #expect(match?.field == .action)
        #expect(match?.text == "Move to folder /Users/me/Documents/Contas")
    }

    @Test func everyWordMustAppearSomewhere() {
        #expect(RuleSearch.match(invoiceRule(), query: "invoices move") != nil)
        #expect(RuleSearch.match(invoiceRule(), query: "invoices trash") == nil)
    }

    @Test func filterKeepsOrderAndEmptyQueryKeepsAll() {
        let a = invoiceRule()
        var b = makeRule(name: "Screenshots")
        b.actions = [makeAction(.moveToTrash, .object([:]), ruleId: b.id)]
        #expect(RuleSearch.filter([a, b], query: "  ").map(\.name) == ["Invoices", "Screenshots"])
        #expect(RuleSearch.filter([a, b], query: "trash").map(\.name) == ["Screenshots"])
    }

    @Test func searchesConditionsInsideEveryGroup() {
        var rule = makeRule(name: "Grouped")
        rule.conditionGroups = [
            ConditionGroup(match: .all, conditions: [makeCondition(.name, .contains, "scan", ruleId: rule.id)]),
            ConditionGroup(match: .any, conditions: [makeCondition(.tags, .contains, "Receipt", ruleId: rule.id)]),
        ]
        #expect(RuleSearch.match(rule, query: "receipt")?.text == "Tags contains Receipt")
    }
}
