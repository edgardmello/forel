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
import Security

/// API keys for "Generate Code", kept in the login Keychain instead of
/// Forel's database, one per AI service.
enum AIKeychain {
    private static let service = "Forel AI API key"

    static func key(for provider: String) -> String {
        var query = baseQuery(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Saves `key`, or removes the stored one when `key` is empty.
    @discardableResult
    static func setKey(_ key: String, for provider: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        SecItemDelete(baseQuery(provider) as CFDictionary)
        guard !trimmed.isEmpty else { return true }
        var attributes = baseQuery(provider)
        attributes[kSecValueData as String] = Data(trimmed.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    private static func baseQuery(_ provider: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider,
        ]
    }
}
