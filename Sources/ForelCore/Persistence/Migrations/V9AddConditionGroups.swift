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

extension Database {
    /// Moves every rule's flat condition list into one condition group,
    /// preserving the matching mode the rule already had: the group takes
    /// the mode (`.none` becomes `.any` inside the group — the negation
    /// stays at the rule level), and `rules.condition_match` is unchanged,
    /// so a single-group rule evaluates exactly as before.
    func migrateV9AddConditionGroups() throws {
        try exec(
            """
            CREATE TABLE IF NOT EXISTS condition_groups (
                id        TEXT PRIMARY KEY,
                rule_id   TEXT NOT NULL REFERENCES rules(id) ON DELETE CASCADE,
                position  INTEGER NOT NULL DEFAULT 0,
                match     TEXT NOT NULL DEFAULT 'all'
            );
            """
        )
        if !(try tableHasColumn("conditions", "group_id")) {
            try exec("ALTER TABLE conditions ADD COLUMN group_id TEXT REFERENCES condition_groups(id) ON DELETE CASCADE;")
        }

        let rules = try statement(
            """
            SELECT id, condition_match FROM rules
            WHERE EXISTS (SELECT 1 FROM conditions WHERE conditions.rule_id = rules.id AND conditions.group_id IS NULL)
            """
        )
        var pending: [(ruleId: String, groupMatch: String)] = []
        while try rules.step() {
            let ruleId = rules.columnText(0)
            let match = ConditionMatch(rawValue: rules.columnText(1)) ?? .all
            pending.append((ruleId, match.groupDefault.rawValue))
        }

        for entry in pending {
            let groupId = UUID().uuidString
            let insert = try statement(
                "INSERT INTO condition_groups (id, rule_id, position, match) VALUES (?1,?2,0,?3)"
            )
            insert.bind(1, groupId)
            insert.bind(2, entry.ruleId)
            insert.bind(3, entry.groupMatch)
            try insert.runToCompletion()

            let update = try statement(
                "UPDATE conditions SET group_id=?1 WHERE rule_id=?2 AND group_id IS NULL"
            )
            update.bind(1, groupId)
            update.bind(2, entry.ruleId)
            try update.runToCompletion()
        }
    }
}
