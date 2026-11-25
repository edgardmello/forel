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

/// Upload passwords live in the Keychain, never in the database or on
/// curl's command line. These tests swap the Keychain for a dictionary.
@Suite(.serialized) struct UploadPasswordTests {
    private func withStore<T>(_ body: (InMemoryUploadPasswordStore) throws -> T) rethrows -> T {
        let previous = UploadPasswords.store
        let store = InMemoryUploadPasswordStore()
        UploadPasswords.store = store
        defer { UploadPasswords.store = previous }
        return try body(store)
    }

    @Test func separatesPasswordFromURL() throws {
        let split = try #require(UploadDestination.separatingPassword("sftp://alice:s%40cret@Example.com:2222/in/"))
        #expect(split.value == "sftp://alice@Example.com:2222/in/")
        #expect(split.account == "sftp://alice@example.com:2222")
        #expect(split.password == "s@cret")
        #expect(UploadDestination.separatingPassword("sftp://alice@example.com/in/") == nil)
        #expect(UploadDestination.separatingPassword("https://example.com/in/") == nil)
    }

    @Test func savingARuleKeepsThePasswordOutOfTheDatabase() throws {
        try withStore { store in
            let db = try Database(path: ":memory:")
            let folder = WatchedFolder(path: "/tmp/uploads")
            try db.insertFolder(folder)
            var rule = makeRule(folderId: folder.id, name: "upload")
            rule.actions = [makeAction(.upload, .object([ActionParam.uploadURL: .string("sftp://alice:secret@example.com/in/")]), ruleId: rule.id)]
            try db.insertRule(rule)

            let saved = try #require(try db.listRules(folderId: folder.id).first?.actions.first)
            #expect(saved.params[ActionParam.uploadURL]?.stringValue == "sftp://alice@example.com/in/")
            #expect(store.password(for: "sftp://alice@example.com") == "secret")
        }
    }

    @Test func passwordStaysInURLWhenTheKeychainRefuses() throws {
        final class RefusingStore: UploadPasswordStore {
            func password(for account: String) -> String? { nil }
            func setPassword(_ password: String, for account: String) -> Bool { false }
        }
        let previous = UploadPasswords.store
        UploadPasswords.store = RefusingStore()
        defer { UploadPasswords.store = previous }
        let action = makeAction(.upload, .object([ActionParam.uploadURL: .string("ftp://bob:pw@host.test/")]))
        #expect(Database.paramsKeepingSecretsOut(action) == action.params)
    }

    @Test func existingPasswordsMoveOutOnOpen() throws {
        try withStore { store in
            let dir = TempDir()
            let path = (dir.path as NSString).appendingPathComponent("forel.db")
            let folder = WatchedFolder(path: "/tmp/uploads")
            var rule = makeRule(folderId: folder.id, name: "upload")
            rule.actions = [makeAction(.upload, .object([ActionParam.uploadURL: .string("ftp://bob:pw@host.test/")]), ruleId: rule.id)]
            do {
                // Simulate an older build: written with the password inline.
                UploadPasswords.store = RefusingStoreForSetup()
                let db = try Database(path: path)
                try db.insertFolder(folder)
                try db.insertRule(rule)
                UploadPasswords.store = store
            }
            #expect(store.password(for: "ftp://bob@host.test") == nil)

            let reopened = try Database(path: path)
            let saved = try #require(try reopened.listRules(folderId: folder.id).first?.actions.first)
            #expect(saved.params[ActionParam.uploadURL]?.stringValue == "ftp://bob@host.test/")
            #expect(store.password(for: "ftp://bob@host.test") == "pw")
        }
    }

    @Test func curlGetsCredentialsOnStandardInputNotTheCommandLine() throws {
        let destination = try #require(UploadDestination.url(from: "sftp://alice@example.com/in/"))
        let command = UploadDestination.curlCommand(sourcePath: "/tmp/a.txt", destination: destination, password: "se\"cr\\et")
        #expect(!command.arguments.joined(separator: " ").contains("se\"cr"))
        #expect(!command.arguments.contains { $0.contains("alice") })
        #expect(command.arguments.suffix(2) == ["--", "sftp://example.com/in/"])
        #expect(command.arguments.contains("--config"))
        #expect(command.standardInput == "user = \"alice:se\\\"cr\\\\et\"\n")
        #expect(command.arguments.contains("--max-time"))
    }

    @Test func userWithoutPasswordStaysForNetrc() throws {
        let destination = try #require(UploadDestination.url(from: "sftp://alice@example.com/in/"))
        let command = UploadDestination.curlCommand(sourcePath: "/tmp/a.txt", destination: destination, password: nil)
        #expect(command.standardInput == nil)
        #expect(command.arguments.last == "sftp://alice@example.com/in/")
    }
}

private final class RefusingStoreForSetup: UploadPasswordStore {
    func password(for account: String) -> String? { nil }
    func setPassword(_ password: String, for account: String) -> Bool { false }
}
