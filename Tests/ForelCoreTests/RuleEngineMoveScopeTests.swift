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

@Suite struct RuleEngineMoveScopeTests {
    // MARK: - A move out of the watched folder ends the pass

    /// Two folders: `watched` holds the file, `elsewhere` is where the first
    /// rule moves it. The second rule matches everything and must not run
    /// on the moved file (it used to, e.g. sorting a moved image into a
    /// dated folder at its new place, or moving it right back).
    private func outsideMoveFixture() -> (watched: TempDir, elsewhere: TempDir, file: String, moved: String, rules: [Rule]) {
        let watched = TempDir()
        let elsewhere = TempDir()
        let file = watched.file("photo.png", contents: "png")
        let moved = (elsewhere.path as NSString).appendingPathComponent("photo.png")
        let first = makeRule(
            name: "images away",
            conditions: [makeCondition(.extension_, .is, "png")],
            actions: [makeAction(.moveToFolder, .object(["destination": .string(elsewhere.path)]))]
        )
        let second = makeRule(
            name: "label everything",
            actions: [makeAction(.setColorLabel, .object(["color": .string("Red")]))]
        )
        return (watched, elsewhere, file, moved, [first, second])
    }

    @Test func runStopsLaterRulesAfterMovingFileOutOfWatchedFolder() throws {
        let fixture = outsideMoveFixture()
        let result = RuleEngine.run(path: fixture.file, depth: 0, rules: fixture.rules, batchId: "out", root: fixture.watched.path)

        #expect(result.matched == ["images away"])
        #expect(result.history.map(\.actionKind) == [.moveToFolder])
        #expect(FileManager.default.fileExists(atPath: fixture.moved))
        #expect(FinderTags.currentColorName(fixture.moved) == "")
    }

    @Test func runWithoutRootStopsLaterRulesAfterMovingFileOutOfItsFolder() throws {
        let fixture = outsideMoveFixture()
        let result = RuleEngine.run(path: fixture.file, depth: 0, rules: fixture.rules, batchId: "out")

        #expect(result.matched == ["images away"])
        #expect(FinderTags.currentColorName(fixture.moved) == "")
    }

    @Test func previewStopsLaterRulesAfterMovingFileOutOfWatchedFolder() throws {
        let fixture = outsideMoveFixture()
        let preview = try #require(RuleEngine.previewFile(path: fixture.file, depth: 0, rules: fixture.rules, root: fixture.watched.path))

        #expect(preview.rules.map(\.ruleName) == ["images away"])
        #expect(FileManager.default.fileExists(atPath: fixture.file))
    }

    @Test func moveOutOfWatchedFolderStillRunsTheRulesLaterActions() throws {
        let watched = TempDir()
        let elsewhere = TempDir()
        let file = watched.file("photo.png", contents: "png")
        let moved = (elsewhere.path as NSString).appendingPathComponent("photo.png")
        let rule = makeRule(
            name: "move then label",
            conditions: [makeCondition(.extension_, .is, "png")],
            actions: [
                makeAction(.moveToFolder, .object(["destination": .string(elsewhere.path)]), position: 0),
                makeAction(.setColorLabel, .object(["color": .string("Red")]), position: 1),
            ]
        )

        let result = RuleEngine.run(path: file, depth: 0, rules: [rule], batchId: "out", root: watched.path)

        #expect(result.history.map(\.actionKind) == [.moveToFolder, .setColorLabel])
        #expect(FinderTags.currentColorName(moved) == "red")
    }

    @Test func moveIntoSubfolderOfWatchedFolderKeepsRunningRulesThatReachIt() throws {
        let watched = TempDir()
        let sub = watched.dir("Images")
        let file = watched.file("photo.png", contents: "png")
        let moved = (sub as NSString).appendingPathComponent("photo.png")
        let first = makeRule(
            name: "into Images",
            conditions: [makeCondition(.extension_, .is, "png")],
            actions: [makeAction(.moveToFolder, .object(["destination": .string(sub)]))]
        )
        let second = makeRule(
            name: "label anywhere",
            actions: [makeAction(.setColorLabel, .object(["color": .string("Red")]))],
            recursionDepth: nil
        )

        let preview = try #require(RuleEngine.previewFile(path: file, depth: 0, rules: [first, second], root: watched.path))
        let result = RuleEngine.run(path: file, depth: 0, rules: [first, second], batchId: "in", root: watched.path)

        #expect(preview.rules.map(\.ruleName) == ["into Images", "label anywhere"])
        #expect(result.matched == ["into Images", "label anywhere"])
        #expect(FinderTags.currentColorName(moved) == "red")
    }
}
