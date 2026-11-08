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

/// `forel://import?rules=…` links that carry whole rules, so a rule can be
/// shared in a message or on a web page and imported with one click. The
/// link holds the same JSON as a `.forelrules` file, base64url-encoded.
public enum RuleShareLink {
    public static let host = "import"
    public static let queryName = "rules"

    public static func url(for rules: [Rule]) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try RuleTransfer.exportForel(rules, encoder: encoder)
        var components = URLComponents()
        components.scheme = ForelURLCommand.scheme
        components.host = host
        components.queryItems = [URLQueryItem(name: queryName, value: base64URL(data))]
        guard let url = components.url else { throw RuleTransferError.invalidNativeFile }
        return url
    }

    /// The `.forelrules` data inside a link's `rules` value.
    public static func data(fromValue value: String) -> Data? {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Actions in shared rules that run code, delete, or send files
    /// elsewhere: named before importing so a link can't slip them in.
    public static let riskyActionKinds: Set<ActionKind> = [
        .delete, .moveToTrash, .runScript, .runAppleScript, .runJavaScript, .runAutomatorWorkflow,
        .runShortcut, .openApplication, .upload, .syncFolders, .syncToFolder,
    ]

    /// "Rule name: Run shell script, Delete" for each rule with risky actions.
    public static func warnings(for rules: [Rule]) -> [String] {
        rules.compactMap { rule in
            let risky = rule.actions.sorted { $0.position < $1.position }
                .filter { riskyActionKinds.contains($0.kind) }
                .map(\.kind.label)
            guard !risky.isEmpty else { return nil }
            return "\(rule.name): \(risky.joined(separator: ", "))"
        }
    }
}
