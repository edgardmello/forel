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

import Foundation
import Security

/// Where upload passwords are kept. The app sets the Keychain store at
/// launch, before opening the database; anything else (tests, tools) keeps
/// them in memory so it never writes to the user's Keychain.
public protocol UploadPasswordStore: Sendable {
    func password(for account: String) -> String?
    /// Returns whether the password was saved.
    func setPassword(_ password: String, for account: String) -> Bool
}

public enum UploadPasswords {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: UploadPasswordStore = InMemoryUploadPasswordStore()

    public static var store: UploadPasswordStore {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }
}

/// Upload passwords in the login Keychain, one item per
/// `scheme://user@host[:port]`.
public struct KeychainUploadPasswordStore: UploadPasswordStore {
    static let service = "Forel upload password"

    public init() {}

    public func password(for account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public func setPassword(_ password: String, for account: String) -> Bool {
        SecItemDelete(baseQuery(account) as CFDictionary)
        var attributes = baseQuery(account)
        attributes[kSecValueData as String] = Data(password.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// Upload passwords held in memory, for tests.
public final class InMemoryUploadPasswordStore: UploadPasswordStore, @unchecked Sendable {
    private let lock = NSLock()
    private var passwords: [String: String] = [:]

    public init() {}

    public func password(for account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return passwords[account]
    }

    public func setPassword(_ password: String, for account: String) -> Bool {
        lock.lock(); passwords[account] = password; lock.unlock()
        return true
    }
}
