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

@Suite struct RuleTemplateTests {
    @Test func everyTemplateIsOffNamedAndSavesWithItsOwnIds() throws {
        let db = try Database(path: ":memory:")
        let folder = WatchedFolder(path: TempDir().path)
        try db.insertFolder(folder)
        for template in RuleTemplate.allCases {
            let rule = template.rule(folderId: folder.id, home: "/Users/test")
            #expect(!rule.enabled, "\(template) should start turned off")
            #expect(rule.name == template.title)
            #expect(!rule.actions.isEmpty)
            #expect(rule.actions.allSatisfy { $0.ruleId == rule.id })
            #expect(rule.conditionGroups.flatMap(\.conditions).allSatisfy { $0.ruleId == rule.id })
            #expect(!rule.actions.contains { $0.kind == .delete })
            try db.insertRule(rule)
        }
        #expect(try db.listRules(folderId: folder.id).count == RuleTemplate.allCases.count)
    }

    @Test func templatesMatchTheFilesTheyAreFor() {
        let dir = TempDir()
        let pdf = dir.file("invoice.pdf", contents: "%PDF")
        let shot = dir.file("Screenshot 2026-11-25 at 10.00.00.png", contents: "png")
        let dmg = dir.file("Installer.dmg", contents: "dmg")
        let zip = dir.file("photos.zip", contents: "zip")

        func matches(_ template: RuleTemplate, _ path: String) -> Bool {
            var rule = template.rule(folderId: "f", home: dir.path)
            rule.enabled = true
            return RuleEngine.ruleMatches(rule, path: path, depth: 0)
        }
        #expect(matches(.pdfsToDocuments, pdf))
        #expect(!matches(.pdfsToDocuments, shot))
        #expect(matches(.screenshots, shot))
        #expect(matches(.unzipArchives, zip))
        // Just added: the waiting templates leave the file alone for now.
        #expect(!matches(.oldInstallersToTrash, dmg))
        #expect(!matches(.tagOldFiles, pdf))
    }

    /// Same template through Dry Run's preview and Run Now's run.
    @Test func screenshotTemplatePreviewsAndRunsTheSameMove() throws {
        let home = TempDir()
        let downloads = home.dir("Downloads")
        let shot = (downloads as NSString).appendingPathComponent("Screenshot 1.png")
        try "png".write(toFile: shot, atomically: true, encoding: .utf8)
        var rule = RuleTemplate.screenshots.rule(folderId: "f", home: home.path)
        rule.enabled = true
        let target = (home.path as NSString).appendingPathComponent("Pictures/Screenshots/Screenshot 1.png")

        let preview = try #require(RuleEngine.previewFile(path: shot, depth: 0, rules: [rule], root: downloads))
        #expect(preview.rules.map(\.ruleName) == [rule.name])
        #expect(FileManager.default.fileExists(atPath: shot))

        let result = RuleEngine.run(path: shot, depth: 0, rules: [rule], batchId: "t", root: downloads)
        #expect(result.history.first?.status == .applied)
        #expect(FileManager.default.fileExists(atPath: target))
    }
}
