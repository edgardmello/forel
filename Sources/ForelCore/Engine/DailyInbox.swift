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

/// Builds a "daily inbox": new files in a folder go to one inbox folder,
/// and the folder's sorting rules move to that inbox with a wait, so files
/// stay at hand for a while before going to their final place.
public enum DailyInbox {
    public enum Choice: String, Sendable, CaseIterable, Identifiable {
        /// The rule moves to the inbox and waits before acting.
        case moveToInbox
        /// The rule stays in the source folder and acts right away.
        case keepHere
        /// The rule stays in the source folder, turned off.
        case turnOff

        public var id: String { rawValue }
    }

    /// What the assistant proposes for `rule` of the source folder.
    public static func defaultChoice(for rule: Rule) -> Choice {
        guard rule.enabled else { return .keepHere }
        guard RuleDiagnostics.takesFileAway(rule) else { return .keepHere }
        switch RuleDiagnostics.specificity(rule) {
        case .cleanup:
            return .keepHere
        case .catchAll:
            // A rule that sweeps every new file somewhere (often into dated
            // folders) is what the inbox replaces.
            return .turnOff
        case .precise, .byType:
            return canWait(rule) ? .moveToInbox : .keepHere
        }
    }

    /// The "Date Added is older than N days" condition the inbox rules wait on.
    public static func waitCondition(days: Int, ruleId: String) -> Condition {
        let n = max(1, days)
        return Condition(ruleId: ruleId, kind: .dateAdded, operator: .olderThan, value: "\(n) \(n == 1 ? "day" : "days")")
    }

    /// True when a wait can be added to the rule's conditions without
    /// changing what they mean.
    public static func canWait(_ rule: Rule) -> Bool {
        waiting(rule, days: 1, inFolder: rule.folderId) != nil
    }

    /// `rule` moved to `folderId` and changed to act only on files added
    /// more than `days` days ago. Nil when its conditions can't take the
    /// extra requirement (e.g. "none of these groups").
    public static func waiting(_ rule: Rule, days: Int, inFolder folderId: String) -> Rule? {
        var result = rule
        result.folderId = folderId
        let wait = waitCondition(days: days, ruleId: rule.id)
        if result.conditionGroups.allSatisfy({ $0.conditions.isEmpty }) {
            result.conditionMatch = .all
            result.conditionGroups = [ConditionGroup(match: .all, conditions: [wait])]
            return result
        }

        switch result.conditionMatch {
        case .none:
            return nil
        case .all:
            result.conditionGroups.append(ConditionGroup(match: .all, conditions: [wait]))
            return result
        case .any:
            if result.conditionGroups.count == 1 {
                // One group: "any" between groups means nothing yet, so
                // switching to "all" keeps the rule's meaning.
                result.conditionMatch = .all
                result.conditionGroups.append(ConditionGroup(match: .all, conditions: [wait]))
                return result
            }
            // (A or B) and wait == (A and wait) or (B and wait), as long as
            // each group requires all of its conditions.
            var groups: [ConditionGroup] = []
            for var group in result.conditionGroups {
                if group.conditions.count <= 1 { group.match = .all }
                guard group.match == .all else { return nil }
                group.conditions.append(waitCondition(days: days, ruleId: rule.id))
                groups.append(group)
            }
            result.conditionGroups = groups
            return result
        }
    }

    /// The rule that sends every new file of the source folder to the inbox.
    public static func intakeRule(sourceFolderId: String, inboxPath: String) -> Rule {
        let id = UUID().uuidString
        let name = (inboxPath as NSString).lastPathComponent
        return Rule(
            id: id,
            folderId: sourceFolderId,
            name: "Send new files to \(name)",
            enabled: true,
            conditionMatch: .all,
            recursionDepth: 0,
            conditionGroups: [ConditionGroup(match: .all, conditions: [
                Condition(ruleId: id, kind: .kind, operator: .isNot, value: "folder"),
            ])],
            actions: [
                Action(ruleId: id, kind: .moveToFolder, params: .object([
                    ActionParam.destination: .string(inboxPath),
                    ActionParam.onConflict: .string("rename"),
                ]), position: 0),
            ]
        )
    }
}
