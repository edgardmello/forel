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

@Suite struct AppIdentityTests {
    @Test func releasesComeOnlyFromThisRepository() {
        #expect(AppIdentity.repository == "edgardmello/forel")
        #expect(AppIdentity.repositoryURL.absoluteString == "https://github.com/edgardmello/forel")
        #expect(!AppIdentity.bundleIdentifier.contains("lab421"))
    }

    @Test func forkLabelIsNotAPrerelease() {
        #expect(ReleaseVersion.compare("1.3.5-fork", "1.3.5") == .orderedSame)
        #expect(ReleaseVersion.isNewer("v1.3.6", than: "1.3.5-fork"))
        #expect(!ReleaseVersion.isNewer("1.3.5", than: "1.3.5-fork"))
        #expect(!ReleaseVersion.isNewer("v1.3.4", than: "1.3.5-fork"))
    }

    @Test func prereleasesStillOrderCorrectly() {
        #expect(ReleaseVersion.isNewer("2.0.0", than: "2.0.0-beta.1"))
        #expect(ReleaseVersion.isNewer("2.0.0-beta.1", than: "2.0.0-alpha.8"))
        #expect(ReleaseVersion.isNewer("2.0.0-beta.10", than: "2.0.0-beta.2"))
        #expect(ReleaseVersion.compare("v1.4", "1.4.0") == .orderedSame)
    }

    @Test func firstLaunchCopiesNewestLegacyDataFolder() throws {
        let root = TempDir()
        let lab = (root.path as NSString).appendingPathComponent("com.lab421.forel")
        let older = (root.path as NSString).appendingPathComponent("com.forel.app")
        try FileManager.default.createDirectory(atPath: lab, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: older, withIntermediateDirectories: true)
        try "rules".write(toFile: lab + "/forel.db", atomically: true, encoding: .utf8)
        try "123".write(toFile: lab + "/forel.lock", atomically: true, encoding: .utf8)
        try "old".write(toFile: older + "/forel.db", atomically: true, encoding: .utf8)

        let directory = try AppIdentity.prepareAppSupportDirectory(root: URL(fileURLWithPath: root.path))

        #expect(directory.lastPathComponent == AppIdentity.bundleIdentifier)
        #expect(try String(contentsOfFile: directory.path + "/forel.db", encoding: .utf8) == "rules")
        #expect(!FileManager.default.fileExists(atPath: directory.path + "/forel.lock"))
        // The old folder stays for older builds.
        #expect(FileManager.default.fileExists(atPath: lab + "/forel.db"))
    }

    @Test func existingDataFolderIsNeverOverwritten() throws {
        let root = TempDir()
        let rootURL = URL(fileURLWithPath: root.path)
        let lab = (root.path as NSString).appendingPathComponent("com.lab421.forel")
        try FileManager.default.createDirectory(atPath: lab, withIntermediateDirectories: true)
        try "legacy".write(toFile: lab + "/forel.db", atomically: true, encoding: .utf8)
        let current = AppIdentity.appSupportDirectory(root: rootURL)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try "current".write(toFile: current.path + "/forel.db", atomically: true, encoding: .utf8)

        _ = try AppIdentity.prepareAppSupportDirectory(root: rootURL)

        #expect(try String(contentsOfFile: current.path + "/forel.db", encoding: .utf8) == "current")
    }

    @Test func freshInstallCreatesAnEmptyFolder() throws {
        let root = TempDir()
        let directory = try AppIdentity.prepareAppSupportDirectory(root: URL(fileURLWithPath: root.path))
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir) && isDir.boolValue)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
}
