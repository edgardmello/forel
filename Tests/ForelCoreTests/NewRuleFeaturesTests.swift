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
import AppKit
import PDFKit
@testable import ForelCore

@Suite struct DuplicateConditionTests {
    private func setCreated(_ path: String, daysAgo: Int) throws {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
        try FileManager.default.setAttributes([.creationDate: date], ofItemAtPath: path)
    }

    @Test func newerIdenticalCopyIsTheDuplicateAndTheOldestStays() throws {
        let dir = TempDir()
        let original = dir.file("invoice.pdf", contents: "same bytes")
        let copy = dir.file("invoice (1).pdf", contents: "same bytes")
        try setCreated(original, daysAgo: 2)
        try setCreated(copy, daysAgo: 1)

        let isDuplicate = makeCondition(.duplicate, .is, DuplicateScope.sameFolder.rawValue)
        #expect(ConditionEvaluator.evaluate(isDuplicate, path: copy))
        #expect(!ConditionEvaluator.evaluate(isDuplicate, path: original))
        #expect(ConditionEvaluator.evaluate(makeCondition(.duplicate, .isNot, DuplicateScope.sameFolder.rawValue), path: original))
    }

    @Test func sameSizeDifferentContentIsNotADuplicate() throws {
        let dir = TempDir()
        let a = dir.file("a.txt", contents: "aaaa")
        let b = dir.file("b.txt", contents: "bbbb")
        try setCreated(a, daysAgo: 2)
        try setCreated(b, daysAgo: 1)
        #expect(!ConditionEvaluator.evaluate(makeCondition(.duplicate, .is, DuplicateScope.sameFolder.rawValue), path: b))
    }

    @Test func treeScopeAlsoLooksInSubfolders() throws {
        let dir = TempDir()
        let sub = dir.dir("Archive")
        let archived = (sub as NSString).appendingPathComponent("photo.jpg")
        try "pixels".write(toFile: archived, atomically: true, encoding: .utf8)
        let arrival = dir.file("photo.jpg", contents: "pixels")
        try setCreated(archived, daysAgo: 5)
        try setCreated(arrival, daysAgo: 0)

        #expect(!ConditionEvaluator.evaluate(makeCondition(.duplicate, .is, DuplicateScope.sameFolder.rawValue), path: arrival))
        #expect(ConditionEvaluator.evaluate(makeCondition(.duplicate, .is, DuplicateScope.sameFolderTree.rawValue), path: arrival))
    }

    @Test func foldersAreNeverDuplicates() throws {
        let dir = TempDir()
        let folder = dir.dir("Folder")
        #expect(!ConditionEvaluator.evaluate(makeCondition(.duplicate, .is, DuplicateScope.sameFolder.rawValue), path: folder))
    }
}

@Suite struct NamedCaptureTests {
    @Test func groupNamesAreReadFromThePattern() {
        #expect(ConditionEvaluator.captureGroupNames(in: #"IPTU (?<year>\d{4}) (?<owner>.+)"#) == ["year", "owner"])
        #expect(ConditionEvaluator.captureGroupNames(in: #"(?<=x)(?<!y)\(?<notAGroup>"#).isEmpty)
    }

    @Test func nameCapturesFeedTheRenamePattern() throws {
        let dir = TempDir()
        let file = dir.file("acme-2026.txt", contents: "x")
        var rule = makeRule(name: "captures")
        rule.conditions = [makeCondition(.name, .matchesRegex, #"^(?<client>[a-z]+)-(?<yr>\d{4})$"#, ruleId: rule.id)]
        rule.actions = [makeAction(.rename, .object([ActionParam.pattern: .string("{yr} {client}")]), ruleId: rule.id)]

        let preview = RuleEngine.previewFile(path: file, depth: 0, rules: [rule], root: dir.path)
        #expect(preview?.rules.first?.actions.first?.targetPath == (dir.path as NSString).appendingPathComponent("2026 acme.txt"))

        _ = RuleEngine.run(path: file, depth: 0, rules: [rule], batchId: "b", root: dir.path)
        #expect(FileManager.default.fileExists(atPath: (dir.path as NSString).appendingPathComponent("2026 acme.txt")))
    }

    @Test func contentCapturesFeedTheDestinationFolder() throws {
        let dir = TempDir()
        let file = dir.file("bill.txt", contents: "IPTU 2026\nOwner: Maria")
        var rule = makeRule(name: "by year")
        rule.conditions = [makeCondition(.contents, .matchesRegex, #"IPTU (?<taxyear>\d{4})"#, ruleId: rule.id)]
        let destination = (dir.path as NSString).appendingPathComponent("IPTU/{taxyear}")
        rule.actions = [makeAction(.moveToFolder, .object([ActionParam.destination: .string(destination)]), ruleId: rule.id)]

        _ = RuleEngine.run(path: file, depth: 0, rules: [rule], batchId: "b", root: dir.path)
        #expect(FileManager.default.fileExists(atPath: (dir.path as NSString).appendingPathComponent("IPTU/2026/bill.txt")))
    }

    @Test func capturedSlashesCannotCreateFolders() throws {
        let value = try TokenExpander.$captures.withValue(["when": "12/05"]) {
            try TokenExpander.expand("{when}", path: "/tmp/x.txt")
        }
        #expect(value == "12-05")
    }

    @Test func builtInTokensWinANameClash() throws {
        let value = try TokenExpander.$captures.withValue(["name": "captured"]) {
            try TokenExpander.expand("{name}", path: "/tmp/real.txt")
        }
        #expect(value == "real")
    }
}

@Suite struct ConversionActionTests {
    private func makePNG(at path: String, width: Int, height: Int) {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }

    @Test func convertsBesideTheOriginalAndContinuesWithTheCopy() throws {
        let dir = TempDir()
        let png = (dir.path as NSString).appendingPathComponent("shot.png")
        makePNG(at: png, width: 400, height: 200)
        let action = makeAction(.convertImage, .object([
            ActionParam.imageFormat: .string(ImageFormat.jpeg.rawValue),
            ActionParam.maxDimension: .string("100"),
        ]))

        let plan = try ActionExecutor.plan(action, path: png)
        let jpg = (dir.path as NSString).appendingPathComponent("shot.jpg")
        #expect(plan.status == .wouldRun)
        #expect(plan.finalPath == jpg)

        let applied = try ActionExecutor.execute(action, path: png)
        #expect(applied.newPath == jpg)
        #expect(FileManager.default.fileExists(atPath: png))
        let size = MediaConverter.pixelSize(jpg)
        #expect(size.map { max($0.width, $0.height) } == 100)

        // Run again: the converted file is already there and newer.
        #expect(try ActionExecutor.plan(action, path: png).status == .wouldSkip)
        // And the copy itself needs nothing.
        #expect(try ActionExecutor.plan(action, path: jpg).status == .wouldSkip)
    }

    @Test func nonImagesAreSkipped() throws {
        let dir = TempDir()
        let text = dir.file("notes.txt", contents: "hello")
        for kind in [ActionKind.convertImage, .compressPDF, .makeSearchablePDF] {
            #expect(try ActionExecutor.plan(makeAction(kind, .object([:])), path: text).status == .wouldSkip, "\(kind)")
        }
    }

    @Test func pdfWithTextIsAlreadySearchable() throws {
        let dir = TempDir()
        let pdf = (dir.path as NSString).appendingPathComponent("typed.pdf")
        makeTextPDF(at: pdf, text: "Already has text")
        let plan = try ActionExecutor.plan(makeAction(.makeSearchablePDF, .object([:])), path: pdf)
        #expect(plan.status == .wouldSkip)
        #expect(plan.description == "Already searchable")
    }

    @Test func scannedImageBecomesASearchablePDF() throws {
        let dir = TempDir()
        let png = (dir.path as NSString).appendingPathComponent("scan.png")
        let image = NSImage(size: NSSize(width: 1000, height: 300))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 1000, height: 300).fill()
        ("SCANNED RECEIPT 2026" as NSString).draw(at: NSPoint(x: 40, y: 120), withAttributes: [.font: NSFont.systemFont(ofSize: 64)])
        image.unlockFocus()
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let data = rep.representation(using: .png, properties: [:]) {
            try data.write(to: URL(fileURLWithPath: png))
        }

        let applied = try ActionExecutor.execute(makeAction(.makeSearchablePDF, .object([:])), path: png)
        let pdf = (dir.path as NSString).appendingPathComponent("scan.pdf")
        #expect(applied.newPath == pdf)
        let text = PDFDocument(url: URL(fileURLWithPath: pdf))?.string ?? ""
        // OCR may be unavailable in some headless environments.
        if !text.isEmpty {
            #expect(text.uppercased().contains("RECEIPT"))
        }
    }

    @Test func derivedUndoRoundTripsThroughJSON() {
        let undo = Undo.derived(created: "/a/b.jpg", original: "/a/b.png", backup: "/t/b.png")
        #expect(Undo.fromJSON(undo.toJSON()) == undo)
        let noBackup = Undo.derived(created: "/a/b.jpg", original: "/a/b.png", backup: nil)
        #expect(Undo.fromJSON(noBackup.toJSON()) == noBackup)
    }

    @Test func invalidMaxDimensionIsReported() {
        let action = makeAction(.convertImage, .object([ActionParam.maxDimension: .string("big")]))
        #expect(!RuleValidator.validate([action]).isEmpty)
        let fine = makeAction(.convertImage, .object([ActionParam.maxDimension: .string("")]))
        #expect(RuleValidator.validate([fine]).isEmpty)
    }
}

@Suite struct TrashCleanerTests {
    private func item(_ name: String, daysAgo: Int, size: UInt64) -> TrashItem {
        TrashItem(path: "/trash/\(name)", trashedAt: Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!, sizeBytes: size)
    }

    @Test func ageLimitDeletesOnlyOldItems() {
        let items = [item("old", daysAgo: 40, size: 1), item("new", daysAgo: 2, size: 1)]
        let doomed = TrashCleaner.plan(TrashCleanupPolicy(maxAgeDays: 30), items: items)
        #expect(doomed.map(\.path) == ["/trash/old"])
    }

    @Test func sizeLimitDeletesOldestFirstUntilUnder() {
        let items = [item("a", daysAgo: 1, size: 50), item("b", daysAgo: 3, size: 50), item("c", daysAgo: 2, size: 50)]
        let doomed = TrashCleaner.plan(TrashCleanupPolicy(maxSizeBytes: 100), items: items)
        #expect(doomed.map(\.path) == ["/trash/b"])
    }

    @Test func noLimitsDeleteNothing() throws {
        let dir = TempDir()
        _ = dir.file("kept.txt", contents: "x")
        let result = try TrashCleaner.clean(TrashCleanupPolicy(), trashPath: dir.path)
        #expect(result.deleted.isEmpty)
        #expect(FileManager.default.fileExists(atPath: (dir.path as NSString).appendingPathComponent("kept.txt")))
    }

    @Test func cleanDeletesFromTheGivenTrashAndReportsHistory() throws {
        let dir = TempDir()
        let big = dir.file("big.bin", contents: String(repeating: "x", count: 100_000))
        let result = try TrashCleaner.clean(TrashCleanupPolicy(maxSizeBytes: 1), trashPath: dir.path)
        #expect(result.deleted.map(\.path) == [big])
        #expect(!FileManager.default.fileExists(atPath: big))
        let history = TrashCleaner.historyEntries(deleted: result.deleted, failed: result.failed)
        #expect(history.count == 1)
        #expect(history.first?.ruleName == "Trash cleanup")
    }

    @Test func unreadableTrashExplainsFullDiskAccess() {
        #expect(throws: TrashCleanerError.cannotReadTrash) {
            _ = try TrashCleaner.items(trashPath: "/nonexistent-\(UUID().uuidString)")
        }
    }
}

@Suite struct ForelURLCommandTests {
    @Test func parsesEverySupportedLink() {
        #expect(ForelURLCommand(url: URL(string: "forel://run?folder=/Users/me/Downloads/")!) == .runFolder(path: "/Users/me/Downloads"))
        #expect(ForelURLCommand(url: URL(string: "forel://run?rule=Invoices%20by%20year")!) == .runRule(nameOrId: "Invoices by year"))
        #expect(ForelURLCommand(url: URL(string: "forel://recheck")!) == .recheck)
        #expect(ForelURLCommand(url: URL(string: "forel://pause")!) == .pause)
        #expect(ForelURLCommand(url: URL(string: "forel://resume")!) == .resume)
        #expect(ForelURLCommand(url: URL(string: "forel://open")!) == .open)
        for example in ForelURLCommand.examples {
            #expect(ForelURLCommand(url: URL(string: example.url)!) != nil, "\(example.url)")
        }
    }

    @Test func rejectsUnknownLinks() {
        #expect(ForelURLCommand(url: URL(string: "forel://delete-everything")!) == nil)
        #expect(ForelURLCommand(url: URL(string: "forel://run")!) == nil)
        #expect(ForelURLCommand(url: URL(string: "https://example.com/run")!) == nil)
    }
}

@Suite struct LocalAITests {
    @Test func unavailableModelNeverMatchesEitherWay() {
        guard LocalAI.unavailableReason != nil else { return }
        let dir = TempDir()
        let file = dir.file("bill.txt", contents: "Boleto bancário")
        #expect(!ConditionEvaluator.evaluate(makeCondition(.aiClassification, .is, "a bank slip"), path: file))
        #expect(!ConditionEvaluator.evaluate(makeCondition(.aiClassification, .isNot, "a bank slip"), path: file))
    }

    @Test func aiTokensPreviewAsPlaceholders() {
        #expect(TokenExpander.previewExpand("{ai:the owner's name}.{extension}") == "ai.txt")
    }
}
