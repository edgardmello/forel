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

@Suite struct RuleDiagnosticsTests {
    private func move(_ destination: String) -> Action {
        makeAction(.moveToFolder, .object([ActionParam.destination: .string(destination)]))
    }

    private func folder(_ id: String, _ path: String) -> WatchedFolder {
        WatchedFolder(id: id, path: path)
    }

    private func kinds(_ diagnostics: [RuleDiagnostic]) -> [RuleDiagnostic.Kind] {
        diagnostics.map(\.kind)
    }

    @Test func specificityRanksContentAboveTypeAboveAge() {
        let content = makeRule(name: "c", conditions: [makeCondition(.contents, .contains, "Nota Fiscal")])
        let regexName = makeRule(name: "r", conditions: [makeCondition(.name, .matchesRegex, "(?i)chatgpt")])
        let type = makeRule(name: "t", conditions: [makeCondition(.extension_, .is, "pdf")])
        let age = makeRule(name: "a", conditions: [
            makeCondition(.dateAdded, .withinLast, "1 day"),
            makeCondition(.kind, .isNot, "folder"),
        ])
        let dupes = makeRule(name: "d", conditions: [makeCondition(.duplicate, .is, "same_folder_tree")])

        #expect(RuleDiagnostics.specificity(content) == .precise)
        #expect(RuleDiagnostics.specificity(regexName) == .precise)
        #expect(RuleDiagnostics.specificity(type) == .byType)
        #expect(RuleDiagnostics.specificity(age) == .catchAll)
        #expect(RuleDiagnostics.specificity(makeRule(name: "empty")) == .catchAll)
        #expect(RuleDiagnostics.specificity(dupes) == .cleanup)
    }

    @Test func suggestedOrderPutsCleanupAndTaggingFirstThenMostSpecificMoves() {
        let today = makeRule(name: "Today", conditions: [makeCondition(.dateAdded, .withinLast, "1 day")], actions: [
            makeAction(.sortIntoSubfolder, .object([ActionParam.subfolder: .string("{year}-{month}-{day}")])),
        ])
        let documents = makeRule(name: "Documents", conditions: [makeCondition(.extension_, .is, "pdf")], actions: [move("/tmp/Docs")])
        let invoices = makeRule(name: "Invoices", conditions: [makeCondition(.contents, .contains, "DANFE")], actions: [move("/tmp/Notas")])
        let old = makeRule(name: "Mark old", conditions: [makeCondition(.createdAt, .olderThan, "30 days")], actions: [
            makeAction(.addTag, .object([ActionParam.tags: .stringArray(["old"])])),
        ])
        let dupes = makeRule(name: "Duplicates", conditions: [makeCondition(.duplicate, .is, "same_folder_tree")], actions: [makeAction(.moveToTrash, .object([:]))])

        let order = RuleDiagnostics.suggestedOrder([today, documents, invoices, old, dupes]).map(\.name)

        #expect(order == ["Duplicates", "Mark old", "Invoices", "Documents", "Today"])
    }

    @Test func flagsCatchAllRuleAboveMoreSpecificMovingRules() throws {
        let downloads = folder("dl", "/Users/me/Downloads")
        let today = makeRule(folderId: "dl", name: "Today", conditions: [
            makeCondition(.dateAdded, .withinLast, "1 day"),
            makeCondition(.kind, .isNot, "folder"),
        ], actions: [makeAction(.sortIntoSubfolder, .object([ActionParam.subfolder: .string("{year}-{month}-{day}")]))])
        let documents = makeRule(folderId: "dl", name: "Documents", conditions: [makeCondition(.extension_, .is, "pdf")], actions: [move("/Users/me/Downloads/Documentos")])

        let diagnostics = RuleDiagnostics.analyze(folders: [downloads], rulesByFolder: ["dl": [today, documents]], folderExists: { _ in true })

        let catchAll = try #require(diagnostics.first { $0.kind == .catchAllAboveOthers })
        #expect(catchAll.ruleIds == [today.id, documents.id])
        #expect(kinds(diagnostics).contains(.datedSubfoldersNeverRevisited))
        // Same rules, catch-all last: nothing to report about order.
        let reordered = RuleDiagnostics.analyze(folders: [downloads], rulesByFolder: ["dl": [documents, today]], folderExists: { _ in true })
        #expect(!kinds(reordered).contains(.catchAllAboveOthers))
    }

    @Test func datedFoldersAreFineWhenTheRulesLookIntoThem() {
        let downloads = folder("dl", "/Users/me/Downloads")
        let today = makeRule(folderId: "dl", name: "Today", conditions: [makeCondition(.extension_, .is, "png")], actions: [
            makeAction(.sortIntoSubfolder, .object([ActionParam.subfolder: .string("{year}-{month}-{day}")])),
        ])
        let deep = makeRule(folderId: "dl", name: "Deep", conditions: [makeCondition(.extension_, .is, "pdf")], actions: [move("/tmp/x")], recursionDepth: nil)

        let diagnostics = RuleDiagnostics.analyze(folders: [downloads], rulesByFolder: ["dl": [today, deep]], folderExists: { _ in true })

        #expect(!kinds(diagnostics).contains(.datedSubfoldersNeverRevisited))
    }

    @Test func flagsMissingFolderRuleWithoutConditionsAndDefaultName() {
        let inbox = folder("in", "/Users/me/Downloads/_Hoje")
        let sweep = makeRule(folderId: "in", name: "New Rule", actions: [move("/Users/me/Downloads/{current_date}")])

        let diagnostics = RuleDiagnostics.analyze(folders: [inbox], rulesByFolder: ["in": [sweep]], folderExists: { _ in false })

        #expect(Set(kinds(diagnostics)).isSuperset(of: [.folderMissing, .noConditions, .untitled]))
    }

    @Test func reportsChainsIntoWatchedFoldersAndLoops() {
        let desktop = folder("desk", "/Users/me/Desktop")
        let downloads = folder("dl", "/Users/me/Downloads")
        let toDownloads = makeRule(folderId: "desk", name: "To Downloads", conditions: [makeCondition(.kind, .is, "image")], actions: [move("/Users/me/Downloads")])
        let toDesktop = makeRule(folderId: "dl", name: "Back to Desktop", conditions: [makeCondition(.kind, .is, "image")], actions: [move("/Users/me/Desktop/Images")])

        let oneWay = RuleDiagnostics.analyze(folders: [desktop, downloads], rulesByFolder: ["desk": [toDownloads], "dl": []], folderExists: { _ in true })
        #expect(kinds(oneWay) == [.chainIntoWatchedFolder])

        let loop = RuleDiagnostics.analyze(folders: [desktop, downloads], rulesByFolder: ["desk": [toDownloads], "dl": [toDesktop]], folderExists: { _ in true })
        #expect(kinds(loop).filter { $0 == .chainLoop }.count == 1)
        #expect(kinds(loop).filter { $0 == .chainIntoWatchedFolder }.count == 2)
    }

    @Test func movingIntoAnOwnSubfolderIsNotAChain() {
        let downloads = folder("dl", "/Users/me/Downloads")
        let documents = makeRule(folderId: "dl", name: "Documents", conditions: [makeCondition(.extension_, .is, "pdf")], actions: [move("/Users/me/Downloads/Documentos")])

        let diagnostics = RuleDiagnostics.analyze(folders: [downloads], rulesByFolder: ["dl": [documents]], folderExists: { _ in true })

        #expect(diagnostics.isEmpty)
    }

    @Test func movingIntoANestedWatchedFolderIsAChain() {
        let downloads = folder("dl", "/Users/me/Downloads")
        let inbox = folder("in", "/Users/me/Downloads/_Hoje")
        let intake = makeRule(folderId: "dl", name: "To inbox", conditions: [makeCondition(.kind, .isNot, "folder")], actions: [move("/Users/me/Downloads/_Hoje")])

        let diagnostics = RuleDiagnostics.analyze(folders: [downloads, inbox], rulesByFolder: ["dl": [intake], "in": []], folderExists: { _ in true })

        #expect(kinds(diagnostics).contains(.chainIntoWatchedFolder))
    }

    @Test func flagsSameConditionsWithDifferentActionsAcrossFolders() {
        let desktop = folder("desk", "/Users/me/Desktop")
        let downloads = folder("dl", "/Users/me/Downloads")
        let shots = [makeCondition(.name, .startsWith, "Screenshot")]
        let a = makeRule(folderId: "desk", name: "Screenshots", conditions: shots, actions: [move("/Drive/Screenshots/{year}")])
        let b = makeRule(folderId: "dl", name: "Screenshots", conditions: shots, actions: [move("/Drive/Screenshots")])

        let diagnostics = RuleDiagnostics.analyze(folders: [desktop, downloads], rulesByFolder: ["desk": [a], "dl": [b]], folderExists: { _ in true })

        #expect(kinds(diagnostics).contains(.duplicatedAcrossFolders))
    }

    @Test func shadowingCountsFilesAnEarlierRuleTakesFromALaterOne() throws {
        let dir = TempDir()
        _ = dir.file("a.pdf", contents: "a")
        _ = dir.file("b.pdf", contents: "b")
        _ = dir.file("c.txt", contents: "c")
        let watched = folder("f", dir.path)
        let everything = makeRule(folderId: "f", name: "Everything", conditions: [makeCondition(.kind, .isNot, "folder")], actions: [move("/tmp/elsewhere")])
        let pdfs = makeRule(folderId: "f", name: "PDFs", conditions: [makeCondition(.extension_, .is, "pdf")], actions: [move("/tmp/pdf")])

        let diagnostics = RuleDiagnostics.shadowing(folder: watched, rules: [everything, pdfs])

        let shadowed = try #require(diagnostics.first)
        #expect(diagnostics.count == 1)
        #expect(shadowed.kind == .shadowed)
        #expect(shadowed.ruleIds == [pdfs.id, everything.id])
        #expect(shadowed.message.hasPrefix("2 files"))
        #expect(FileManager.default.fileExists(atPath: (dir.path as NSString).appendingPathComponent("a.pdf")))
        #expect(RuleDiagnostics.shadowing(folder: watched, rules: [pdfs, everything]).isEmpty)
    }

    @Test func competitionNamesTheFirstRuleThatTakesTheFile() throws {
        let dir = TempDir()
        let file = dir.file("a.pdf", contents: "a")
        let tag = makeRule(name: "Tag", conditions: [makeCondition(.extension_, .is, "pdf")], actions: [
            makeAction(.addTag, .object([ActionParam.tags: .stringArray(["x"])])),
        ])
        let pdfs = makeRule(name: "PDFs", conditions: [makeCondition(.extension_, .is, "pdf")], actions: [move("/tmp/pdf")])
        let txt = makeRule(name: "Text", conditions: [makeCondition(.extension_, .is, "txt")], actions: [move("/tmp/txt")])

        let result = RuleDiagnostics.competition(path: file, depth: 0, rules: [tag, pdfs, txt])

        #expect(result.matchingRuleIds == [tag.id, pdfs.id])
        #expect(result.winnerRuleId == pdfs.id)
    }
}
