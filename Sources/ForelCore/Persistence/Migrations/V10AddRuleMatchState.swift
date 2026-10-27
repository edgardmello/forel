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
    /// Remembers, per rule and per file, when the rule last matched it and
    /// how often — backing the "Date last matched" and "Times matched"
    /// conditions, and letting the periodic re-check skip files a rule has
    /// already handled. Files are keyed by on-disk identity (volume +
    /// inode), so a rename or a move on the same disk keeps its record.
    func migrateV10AddRuleMatchState() throws {
        try exec(
            """
            CREATE TABLE IF NOT EXISTS rule_match_state (
                rule_id          TEXT NOT NULL REFERENCES rules(id) ON DELETE CASCADE,
                file_key         TEXT NOT NULL,
                last_matched_at  TEXT NOT NULL,
                match_count      INTEGER NOT NULL DEFAULT 0,
                fingerprint      TEXT,
                PRIMARY KEY (rule_id, file_key)
            );
            """
        )
    }
}
