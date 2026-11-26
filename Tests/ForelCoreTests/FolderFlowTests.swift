// Forel - A native macOS file-automation app
// Copyright (C) 2026  Edgard Mello
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

@Suite struct FolderFlowTests {
    private func move(_ destination: String, ruleId: String) -> Action {
        Action(ruleId: ruleId, kind: .moveToFolder, params: .object([ActionParam.destination: .string(destination)]), position: 0)
    }

    @Test func mapsHandOffsElsewhereTrashAndLoops() {
        let downloads = WatchedFolder(path: "/Users/me/Downloads")
        let inbox = WatchedFolder(path: "/Users/me/Downloads/_Hoje")
        let documents = WatchedFolder(path: "/Users/me/Documents")
        let folders = [downloads, inbox, documents]

        var intake = makeRule(folderId: downloads.id, name: "to inbox")
        intake.actions = [move(inbox.path, ruleId: intake.id)]
        var tidy = makeRule(folderId: downloads.id, name: "tidy")
        tidy.actions = [Action(ruleId: tidy.id, kind: .sortIntoSubfolder, params: .object([ActionParam.subfolder: .string("{year}")]), position: 0)]
        var pdfs = makeRule(folderId: inbox.id, name: "pdfs")
        pdfs.actions = [move("/Users/me/Documents/PDFs/{year}", ruleId: pdfs.id)]
        var back = makeRule(folderId: documents.id, name: "back")
        back.actions = [move(inbox.path, ruleId: back.id)]
        var old = makeRule(folderId: documents.id, name: "old", enabled: false)
        old.actions = [Action(ruleId: old.id, kind: .moveToTrash, params: .object([:]), position: 0)]
        var away = makeRule(folderId: inbox.id, name: "away")
        away.actions = [move("/Volumes/Backup/Archive", ruleId: away.id)]

        let nodes = FolderFlow.map(folders: folders, rulesByFolder: [
            downloads.id: [intake, tidy], inbox.id: [pdfs, away], documents.id: [back, old],
        ])
        let byId = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })

        // Sorting into a subfolder stays in Downloads; the move into the
        // nested inbox is a hand-off.
        #expect(byId[downloads.id]?.outgoing.map(\.destination) == [.watched(folderId: inbox.id)])
        #expect(byId[downloads.id]?.outgoing.first?.inLoop == false)
        // Inbox → Documents → Inbox is a loop; the backup is elsewhere.
        let inboxSteps = byId[inbox.id]?.outgoing ?? []
        #expect(inboxSteps.first { $0.ruleName == "pdfs" }?.destination == .watched(folderId: documents.id))
        #expect(inboxSteps.first { $0.ruleName == "pdfs" }?.inLoop == true)
        #expect(inboxSteps.first { $0.ruleName == "away" }?.destination == .elsewhere(path: "/Volumes/Backup/Archive"))
        #expect(byId[documents.id]?.outgoing.first { $0.ruleName == "old" }?.destination == .trash)
        #expect(Set(byId[inbox.id]?.incomingFrom ?? []) == [downloads.id, documents.id])
    }
}
