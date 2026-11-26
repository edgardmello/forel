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

/// The translation files ship inside the app bundle; a syntax error there
/// makes macOS ignore the whole file and show the app in English.
@Suite struct LocalizationTests {
    private static let localizationRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Localization")

    private func strings(_ language: String) throws -> [String: String] {
        let url = Self.localizationRoot.appendingPathComponent("\(language).lproj/Localizable.strings")
        let data = try Data(contentsOf: url)
        let parsed = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(parsed as? [String: String])
    }

    @Test func portugueseStringsParseAndTranslateEveryKey() throws {
        let table = try strings("pt-BR")
        #expect(table.count > 300)
        #expect(table["Run Now"] == "Executar Agora")
        #expect(table.values.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    @Test func englishStringsFileIsValid() throws {
        #expect(try strings("en")["Forel"] == "Forel")
    }
}
