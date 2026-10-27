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

/// What a `forel://` link asks Forel to do. Lets Shortcuts ("Open URLs"),
/// Raycast, Alfred or a shell script (`open "forel://run?folder=…"`)
/// drive Forel without its window.
public enum ForelURLCommand: Equatable, Sendable {
    /// Run Now on the watched folder at this path.
    case runFolder(path: String)
    /// Run one rule, found by name (case-insensitive) or id, on its folder.
    case runRule(nameOrId: String)
    /// Re-check time-dependent rules on every folder now.
    case recheck
    case pause
    case resume
    case open

    public static let scheme = "forel"

    /// Every supported link, for the help shown in Settings.
    public static let examples: [(url: String, summary: String)] = [
        ("forel://run?folder=/Users/you/Downloads", "Run Now on a watched folder"),
        ("forel://run?rule=Invoices", "Run one rule, by name"),
        ("forel://recheck", "Re-check rules that depend on time"),
        ("forel://pause", "Pause automatic watching"),
        ("forel://resume", "Resume automatic watching"),
        ("forel://open", "Open the Forel window"),
    ]

    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme else { return nil }
        let command = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            query.first { $0.name.lowercased() == name }?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        switch command {
        case "run":
            if let folder = value("folder"), !folder.isEmpty {
                self = .runFolder(path: ((folder as NSString).expandingTildeInPath as NSString).standardizingPath)
            } else if let rule = value("rule"), !rule.isEmpty {
                self = .runRule(nameOrId: rule)
            } else {
                return nil
            }
        case "recheck": self = .recheck
        case "pause": self = .pause
        case "resume": self = .resume
        case "open", "": self = .open
        default: return nil
        }
    }
}
