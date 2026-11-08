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

/// Finds rules by what they do, not just by their name: a query is matched
/// against the rule's name, every condition ("Extension is pdf") and every
/// action with its settings ("Move to folder ~/Documents/Invoices").
public enum RuleSearch {
    public enum Field: String, Sendable, Equatable {
        case name
        case condition
        case action
    }

    /// Why a rule matched: the first condition or action the query was found
    /// in, so the result can show it ("Action · Move to folder ~/Invoices").
    public struct Match: Sendable, Equatable {
        public let field: Field
        public let text: String
    }

    /// The text a rule can be found by, in display order: name first, then
    /// conditions, then actions.
    public static func searchableTerms(of rule: Rule) -> [(field: Field, text: String)] {
        var terms: [(Field, String)] = [(.name, rule.name)]
        for condition in rule.conditions {
            let text = [condition.kind.label, condition.operator.label, condition.value]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            terms.append((.condition, text))
        }
        for action in rule.actions.sorted(by: { $0.position < $1.position }) {
            let values = strings(in: action.params)
            terms.append((.action, ([action.kind.label] + values).joined(separator: " ")))
        }
        return terms.map { (field: $0.0, text: $0.1) }
    }

    /// Returns how `rule` matches `query`, or nil when it doesn't. Every
    /// word of the query must appear somewhere in the rule, ignoring case
    /// and accents. An empty query matches every rule by name.
    public static func match(_ rule: Rule, query: String) -> Match? {
        let tokens = query
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        let terms = searchableTerms(of: rule)
        guard !tokens.isEmpty else { return Match(field: .name, text: rule.name) }

        for token in tokens where !terms.contains(where: { contains($0.text, token) }) {
            return nil
        }
        // A rule whose name holds the whole query is a name match; otherwise
        // point at the first condition or action that holds any word of it.
        if tokens.allSatisfy({ contains(rule.name, $0) }) {
            return Match(field: .name, text: rule.name)
        }
        let hit = terms.first { term in
            term.field != .name && tokens.contains { contains(term.text, $0) }
        } ?? terms[0]
        return Match(field: hit.field, text: hit.text)
    }

    /// Filters `rules` by `query`, keeping their order.
    public static func filter(_ rules: [Rule], query: String) -> [Rule] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return rules }
        return rules.filter { match($0, query: trimmed) != nil }
    }

    private static func contains(_ text: String, _ token: String) -> Bool {
        text.range(of: token, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private static func strings(in value: JSONValue) -> [String] {
        switch value {
        case .string(let string):
            return string.isEmpty ? [] : [string]
        case .array(let values):
            return values.flatMap(strings(in:))
        case .object(let dict):
            return dict.keys.sorted().flatMap { strings(in: dict[$0]!) }
        case .number, .bool, .null:
            return []
        }
    }
}
