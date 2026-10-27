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

@Suite struct InstanceLockTests {
    private func lockPath() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("InstanceLockTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("forel.lock").path
    }

    @Test func secondLockIsRefusedWhileTheFirstIsHeld() throws {
        let path = try lockPath()
        let first = InstanceLock(path: path)
        #expect(first != nil)
        // flock locks belong to the open file, so a second open in the same
        // process is refused just like another process would be.
        #expect(InstanceLock(path: path) == nil)
        withExtendedLifetime(first) {}
    }

    @Test func lockCanBeTakenAgainOnceReleased() throws {
        let path = try lockPath()
        var first = InstanceLock(path: path)
        #expect(first != nil)
        first = nil
        #expect(InstanceLock(path: path) != nil)
    }

    @Test func holderPIDIsReadableByTheLosingInstance() throws {
        let path = try lockPath()
        let lock = InstanceLock(path: path)
        #expect(InstanceLock(path: path) == nil)
        #expect(InstanceLock.holderPID(path: path) == getpid())
        withExtendedLifetime(lock) {}
    }

    @Test func leftoverLockFileFromAnEarlierRunDoesNotBlock() throws {
        let path = try lockPath()
        try "99999\n".write(toFile: path, atomically: true, encoding: .utf8)
        let lock = InstanceLock(path: path)
        #expect(lock != nil)
        #expect(InstanceLock.holderPID(path: path) == getpid())
        withExtendedLifetime(lock) {}
    }
}
