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
    /// What happened in each "Review with AI" session — the goal, the
    /// suggestions and which ones the user took, their replies and the rule
    /// they ended up saving — so later reviews can learn from it. The
    /// session itself is a JSON document, so what is remembered can grow
    /// without another migration; the columns are only what lookups need.
    func migrateV11AddRuleReviewMemory() throws {
        try exec(
            """
            CREATE TABLE IF NOT EXISTS rule_review_memory (
                id          TEXT PRIMARY KEY,
                rule_id     TEXT,
                folder_path TEXT,
                outcome     TEXT NOT NULL,
                record      TEXT NOT NULL,
                created_at  TEXT NOT NULL,
                updated_at  TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_rule_review_memory_updated ON rule_review_memory(updated_at);
            """
        )
    }
}
