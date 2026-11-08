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

@Suite struct HistorySearchTests {
    private func entry(_ rule: String, _ kind: ActionKind, _ path: String, message: String? = nil) -> HistoryEntry {
        HistoryEntry(batchId: "b", ruleId: nil, ruleName: rule, actionKind: kind, originalPath: path, resultPath: path, undo: .null, reversible: false, message: message)
    }

    private func makeDB() throws -> Database {
        let db = try Database(path: ":memory:")
        try db.insertHistoryEntries([
            entry("Invoices", .moveToFolder, "/Users/me/Downloads/bill_01.pdf"),
            entry("Screenshots", .moveToTrash, "/Users/me/Desktop/shot.png"),
            entry("Tag", .addTag, "/Users/me/Downloads/notes.txt", message: "Added Receipt"),
        ])
        return db
    }

    @Test func matchesRulePathMessageAndActionLabel() throws {
        let db = try makeDB()
        #expect(try db.listHistory(matching: "invoices").map(\.ruleName) == ["Invoices"])
        #expect(try db.listHistory(matching: "shot.png").map(\.ruleName) == ["Screenshots"])
        #expect(try db.listHistory(matching: "receipt").map(\.ruleName) == ["Tag"])
        #expect(try db.listHistory(matching: "trash").map(\.ruleName) == ["Screenshots"])
        #expect(try db.countHistory(matching: "  ") == 3)
    }

    @Test func everyWordMustMatchAndUnderscoresAreLiteral() throws {
        let db = try makeDB()
        #expect(try db.listHistory(matching: "downloads tag").map(\.ruleName) == ["Tag"])
        #expect(try db.countHistory(matching: "bill_") == 1)
        #expect(try db.countHistory(matching: "l_0") == 1)
        #expect(try db.countHistory(matching: "s_") == 0)
    }

    @Test func combinesWithTheDirectoryFilter() throws {
        let db = try makeDB()
        #expect(try db.countHistory(directoryPath: "/Users/me/Downloads", matching: "move") == 1)
        #expect(try db.countHistory(directoryPath: "/Users/me/Desktop", matching: "move") == 1)
        #expect(try db.countHistory(directoryPath: "/Users/me/Desktop", matching: "invoices") == 0)
        #expect(try db.listHistory(limit: 10, offset: 0, directoryPath: "/Users/me/Downloads").count == 2)
    }
}
