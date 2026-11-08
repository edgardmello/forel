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

struct RuleShareLinkTests {
    @Test func aLinkRoundTripsRulesAndImportsThemDisabled() throws {
        var rule = makeRule(name: "Invoices → Finance")
        rule.conditions = [makeCondition(.name, .contains, "invoice+total/2026", ruleId: rule.id)]
        rule.actions = [
            makeAction(.moveToFolder, .object([ActionParam.destination: .string("~/Finance")]), position: 0, ruleId: rule.id),
            makeAction(.runScript, .object([ActionParam.script: .string("echo hi")]), position: 1, ruleId: rule.id),
        ]
        let url = try RuleShareLink.url(for: [rule])
        #expect(url.scheme == "forel")
        #expect(url.host == "import")

        guard case .importRules(let data) = ForelURLCommand(url: url) else {
            Issue.record("link wasn't recognised")
            return
        }
        let result = try RuleTransfer.importRules(from: data, folderId: "target", disabled: true)
        #expect(result.rules.count == 1)
        let imported = try #require(result.rules.first)
        #expect(imported.name == "Invoices → Finance")
        #expect(imported.enabled == false)
        #expect(imported.folderId == "target")
        #expect(imported.id != rule.id)
        #expect(imported.conditions.first?.value == "invoice+total/2026")
        #expect(RuleShareLink.warnings(for: result.rules) == ["Invoices → Finance: Run shell script"])
    }

    @Test func brokenLinksAreRejected() {
        #expect(ForelURLCommand(url: URL(string: "forel://import")!) == nil)
        #expect(ForelURLCommand(url: URL(string: "forel://import?rules=%%%")!) == nil)
        if case .importRules(let data) = ForelURLCommand(url: URL(string: "forel://import?rules=bm9wZQ")!) {
            #expect(throws: (any Error).self) { try RuleTransfer.importRules(from: data, folderId: "f", disabled: true) }
        } else {
            Issue.record("valid base64 should parse as an import link")
        }
    }
}
