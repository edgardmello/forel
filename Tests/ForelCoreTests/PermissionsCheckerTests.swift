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
import Testing
@testable import ForelCore

@Suite struct FullDiskAccessStatusTests {
    @Test func readableProtectedFileMeansGranted() {
        let dir = TempDir()
        let probe = dir.file("TCC.db", contents: "x")
        #expect(PermissionsChecker.fullDiskAccessStatus(probePaths: [probe]) == .granted)
    }

    @Test func existingButUnreadableFileMeansDenied() throws {
        let dir = TempDir()
        let probe = dir.file("TCC.db", contents: "x")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: probe)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: probe) }
        // Root can read anything, so the check only means something as a normal user.
        guard getuid() != 0 else { return }
        #expect(PermissionsChecker.fullDiskAccessStatus(probePaths: [probe]) == .denied)
    }

    @Test func missingProbesAreSkipped() {
        let dir = TempDir()
        let readable = dir.file("Bookmarks.plist", contents: "x")
        let missing = (dir.path as NSString).appendingPathComponent("absent.db")
        #expect(PermissionsChecker.fullDiskAccessStatus(probePaths: [missing]) == .unknown)
        #expect(PermissionsChecker.fullDiskAccessStatus(probePaths: [missing, readable]) == .granted)
    }
}
