// Forel - A native macOS file-automation app
// Copyright (C) 2026  Lab421

import Foundation
import Testing
@testable import ForelCore

@Suite struct RuleTransferTests {
    @Test func nativeExportRoundTripsRulesWithFreshIdentifiers() throws {
        let sourceId = UUID().uuidString
        let source = Rule(
            id: sourceId,
            folderId: "source-folder",
            name: "Invoices",
            enabled: true,
            conditionMatch: .any,
            recursionDepth: nil,
            conditions: [Condition(ruleId: sourceId, kind: .name, operator: .contains, value: "Invoice")],
            actions: [Action(ruleId: sourceId, kind: .addTag, params: .object([ActionParam.tags: .stringArray(["Filed"])]), position: 0)]
        )

        let data = try RuleTransfer.exportForel([source])
        let result = try RuleTransfer.importRules(from: data, folderId: "destination-folder")

        #expect(result.issues.isEmpty)
        #expect(result.rules.count == 1)
        #expect(result.rules[0].id != source.id)
        #expect(result.rules[0].folderId == "destination-folder")
        #expect(result.rules[0].conditionMatch == .any)
        #expect(result.rules[0].conditions[0].ruleId == result.rules[0].id)
        #expect(result.rules[0].actions[0].ruleId == result.rules[0].id)
    }

    @Test func hazelImportMapsSupportedPartsAndDisablesIncompleteRules() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: hazelFixture(), format: .binary, options: 0)
        let result = try RuleTransfer.importRules(from: data, folderId: "folder")

        #expect(result.rules.count == 2)
        #expect(result.rules[0].name == "Archive G-code")
        #expect(result.rules[0].enabled)
        #expect(result.rules[0].conditions.map(\.kind) == [.extension_])
        #expect(result.rules[0].actions.map(\.kind) == [.moveToTrash])
        #expect(!result.rules[1].enabled)
        #expect(result.issues.contains { $0.ruleName == "Needs review" })
    }

    @Test func cyclicHazelArchivesAreRejected() throws {
        let fixture: [String: Any] = [
            "$archiver": "NSKeyedArchiver",
            "$top": ["root": ["CF$UID": 1]],
            "$objects": ["$null", ["$class": ["CF$UID": 2], "rules": ["CF$UID": 1]], ["$classname": "HazelRuleSet"]],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: fixture, format: .binary, options: 0)

        #expect(throws: RuleTransferError.self) {
            try RuleTransfer.importRules(from: data, folderId: "folder")
        }
    }

    @Test func unsupportedNativeVersionsAreRejected() throws {
        let data = Data(#"{"format":"forel-rules","version":999,"rules":[]}"#.utf8)

        #expect(throws: RuleTransferError.self) {
            try RuleTransfer.importRules(from: data, folderId: "folder")
        }
    }

    private func hazelFixture() -> [String: Any] {
        let uid: (Int) -> [String: Any] = { ["CF$UID": $0] }
        return [
            "$archiver": "NSKeyedArchiver",
            "$top": ["root": uid(1)],
            "$objects": [
                "$null",
                ["$class": uid(2), "rules": uid(3)],
                ["$classname": "HazelRuleSet"],
                ["$class": uid(4), "NS.objects": [uid(5), uid(11)]],
                ["$classname": "NSArray"],
                [
                    "$class": uid(6), "description": "Archive G-code", "predicateType": 1,
                    "criteria": uid(7), "actions": uid(9),
                ],
                ["$classname": "HazelRule"],
                ["$class": uid(4), "NS.objects": [uid(8)]],
                [
                    "NSLeftExpression": ["NSKeyPath": "displayExtensions"],
                    "NSRightExpression": ["NSConstantValue": ".gcode"],
                    "NSPredicateOperator": ["NSOperatorType": 4],
                ],
                ["$class": uid(4), "NS.objects": [uid(10)]],
                ["$class": uid(16)],
                [
                    "$class": uid(12), "description": "Needs review", "predicateType": 1,
                    "criteria": uid(7), "actions": uid(13),
                ],
                ["$classname": "HazelRule"],
                ["$class": uid(4), "NS.objects": [uid(14)]],
                ["$class": uid(15)],
                ["$classname": "HazelUnsupportedAction"],
                ["$classname": "HazelTrashAction"],
            ],
        ]
    }
}

// MARK: - Condition groups

@Test func groupedRulesRoundTripThroughTheNativeFormat() throws {
    let original = makeRule(
        name: "grouped",
        conditionMatch: .any,
        conditionGroups: [
            ConditionGroup(match: .any, conditions: [
                makeCondition(.extension_, .is, "pdf"),
                makeCondition(.extension_, .is, "doc"),
            ]),
            ConditionGroup(match: .all, conditions: [
                makeCondition(.name, .contains, "report"),
            ]),
        ],
        actions: [makeAction(.addTag, .object([ActionParam.tags: .stringArray(["Hit"])]))]
    )

    let data = try RuleTransfer.exportForel([original])
    let result = try RuleTransfer.importRules(from: data, folderId: "folder-2")

    let imported = try #require(result.rules.first)
    #expect(imported.conditionMatch == .any)
    #expect(imported.conditionGroups.count == 2)
    #expect(imported.conditionGroups.map(\.match) == [.any, .all])
    #expect(imported.conditionGroups[0].conditions.map(\.value) == ["pdf", "doc"])
    #expect(imported.conditionGroups[0].conditions.allSatisfy { $0.ruleId == imported.id })
}

@Test func legacyFlatExportsStillImportIntoASingleGroup() throws {
    // Hand-written version-1 export in the pre-groups shape.
    let json = """
    {
      "format" : "forel-rules",
      "version" : 1,
      "rules" : [
        {
          "id" : "r9",
          "folderId" : "old-folder",
          "name" : "legacy",
          "enabled" : true,
          "conditionMatch" : "any",
          "recursionDepth" : 0,
          "conditions" : [
            { "id" : "c1", "ruleId" : "r9", "kind" : "extension", "operator" : "is", "value" : "pdf" },
            { "id" : "c2", "ruleId" : "r9", "kind" : "extension", "operator" : "is", "value" : "doc" }
          ],
          "actions" : [],
          "priority" : 0,
          "createdAt" : "2026-01-01T00:00:00Z"
        }
      ]
    }
    """
    let result = try RuleTransfer.importRules(from: Data(json.utf8), folderId: "folder-2")

    let imported = try #require(result.rules.first)
    #expect(imported.conditionMatch == .any)
    #expect(imported.conditionGroups.count == 1)
    #expect(imported.conditionGroups[0].match == .any)
    #expect(imported.conditionGroups[0].conditions.map(\.value) == ["pdf", "doc"])
    #expect(imported.conditionGroups[0].conditions.allSatisfy { $0.ruleId == imported.id })
}
