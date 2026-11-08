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

/// "Why didn't my rule run?": how each rule of a watched folder judges one
/// file, using the same checks as Dry Run, Run Now and the watcher.
public struct RuleExplanation: Sendable, Identifiable {
    public enum Verdict: Sendable, Equatable {
        /// The rule's conditions match: it runs on this file.
        case matches
        /// The conditions match, but the rule already handled this file and
        /// it hasn't changed since, so automatic runs leave it alone.
        case alreadyHandled
        /// At least one condition fails (see `conditions`).
        case conditionsFail
        case turnedOff
        /// The file is deeper in subfolders than the rule looks.
        case outOfScope
    }

    public var id: String { ruleId }
    public let ruleId: String
    public let ruleName: String
    public let verdict: Verdict
    public let conditions: [ConditionPreview]
}

public struct FileExplanation: Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    /// Set when no rule looks at the file at all, with the reason.
    public let skippedReason: String?
    public let rules: [RuleExplanation]
}

public extension RuleEngine {
    /// Explains each rule of the folder at `root` on `path`. Rules are
    /// judged one by one on the file as it is now; when an earlier rule
    /// moves or renames it, later rules see the result instead.
    static func explain(path: String, rules: [Rule], root: String) -> FileExplanation {
        let name = (path as NSString).lastPathComponent
        guard FileManager.default.fileExists(atPath: path) else {
            return FileExplanation(path: path, skippedReason: "The file no longer exists.", rules: [])
        }
        guard let depth = pathDepth(root: root, path: path) else {
            return FileExplanation(path: path, skippedReason: "The file isn't inside the watched folder \((root as NSString).lastPathComponent).", rules: [])
        }
        if SystemFileFilter.isExcluded(name) {
            return FileExplanation(path: path, skippedReason: "Forel ignores this macOS system file so it never moves or changes it.", rules: [])
        }
        if FileReadiness.isMarkedBusy(path) || FileReadiness.containsBusyItem(path) {
            return FileExplanation(path: path, skippedReason: "The file is still being copied or downloaded; rules run once it's complete.", rules: [])
        }

        let explanations = rules.map { rule -> RuleExplanation in
            guard rule.enabled else {
                return RuleExplanation(ruleId: rule.id, ruleName: rule.name, verdict: .turnedOff, conditions: [])
            }
            guard isInScope(rule, depth: depth) else {
                return RuleExplanation(ruleId: rule.id, ruleName: rule.name, verdict: .outOfScope, conditions: [])
            }
            let preview = previewFile(path: path, depth: depth, rules: [rule], root: root, includeNonMatches: true)
            let rulePreview = preview?.rules.first { $0.ruleId == rule.id }
            let conditions = rulePreview?.conditions ?? []
            guard rulePreview?.matched == true else {
                return RuleExplanation(ruleId: rule.id, ruleName: rule.name, verdict: .conditionsFail, conditions: conditions)
            }
            let handled = RuleMatchMemory.shared.hasMatchedUnchanged(ruleId: rule.id, path: path)
            return RuleExplanation(ruleId: rule.id, ruleName: rule.name, verdict: handled ? .alreadyHandled : .matches, conditions: conditions)
        }
        return FileExplanation(path: path, skippedReason: nil, rules: explanations)
    }
}
