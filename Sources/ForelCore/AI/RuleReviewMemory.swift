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

// MARK: - Record

/// What happened in one "Review with AI" session, kept on this Mac so later
/// reviews can learn from it: what the user asked for, what the AI
/// suggested, which suggestions they took or left, what they replied, and
/// the rule they finally saved — or that they went back to their own.
/// Rules are stored in the compact JSON the AI service reads, with upload
/// passwords removed, and every text is clipped so the memory stays small.
public struct RuleReviewRecord: Codable, Equatable, Sendable, Identifiable {
    public enum Outcome: String, Codable, Sendable {
        /// The AI reviewed the rule; nothing was applied (yet).
        case reviewed
        /// The AI wrote the rule with the chosen suggestions; it wasn't used (yet).
        case proposed
        /// The written rule was loaded into the editor; not saved yet.
        case used
        /// The user saved the rule the AI wrote, possibly after changing it.
        case saved
        /// The user undid the AI's version and kept their own rule.
        case undone
        /// The user closed the editor without saving the AI's version.
        case discarded
    }

    public struct Suggestion: Codable, Equatable, Sendable {
        public var category: String
        public var title: String
        public var detail: String
        /// Whether the user applied it; nil while they haven't chosen.
        public var accepted: Bool?
    }

    public let id: String
    public let createdAt: Date
    public var updatedAt: Date
    public var ruleId: String
    public var ruleName: String
    public var folderPath: String?
    public var goal: String
    /// The rule as it was when the review started.
    public var originalRule: String
    /// Condition and action kinds of the original rule, for finding similar cases.
    public var conditionKinds: [String]
    public var actionKinds: [String]
    public var summary: String
    public var suggestions: [Suggestion]
    /// What the user answered the AI, in order.
    public var replies: [String]
    public var proposedRule: String?
    public var explanation: String?
    /// The rule as the user saved it, when they did.
    public var savedRule: String?
    public var outcome: Outcome

    static let maximumText = 1_000
    static let maximumRuleJSON = 20_000
    static let maximumReplies = 20

    static func clip(_ text: String, _ limit: Int = maximumText) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= limit ? trimmed : String(trimmed.prefix(limit)) + "…"
    }

    static func ruleJSON(_ rule: Rule) -> String {
        clip(RuleReviewer.json(for: rule), maximumRuleJSON)
    }

    /// A new record for the review the AI just returned.
    public init(id: String = UUID().uuidString, rule: Rule, folderPath: String?, goal: String, review: RuleReview, now: Date = Date()) {
        self.id = id
        createdAt = now
        updatedAt = now
        ruleId = rule.id
        ruleName = Self.clip(rule.name, 200)
        self.folderPath = folderPath
        self.goal = Self.clip(goal)
        originalRule = Self.ruleJSON(rule)
        conditionKinds = Array(Set(rule.conditionGroups.flatMap(\.conditions).map(\.kind.rawValue))).sorted()
        actionKinds = Array(Set(rule.actions.map(\.kind.rawValue))).sorted()
        summary = ""
        suggestions = []
        replies = []
        outcome = .reviewed
        update(with: review, now: now)
    }

    /// The AI's latest list of suggestions, after the first analysis or a reply.
    public mutating func update(with review: RuleReview, now: Date = Date()) {
        summary = Self.clip(review.summary, 2_000)
        suggestions = review.suggestions.map {
            Suggestion(category: $0.category.rawValue, title: Self.clip($0.title, 300), detail: Self.clip($0.detail), accepted: nil)
        }
        updatedAt = now
    }

    public mutating func addReply(_ reply: String, now: Date = Date()) {
        let text = Self.clip(reply)
        guard !text.isEmpty else { return }
        replies.append(text)
        if replies.count > Self.maximumReplies { replies.removeFirst(replies.count - Self.maximumReplies) }
        updatedAt = now
    }

    /// The AI wrote the rule with `chosen` (the suggestions applied) or
    /// changed it after a reply.
    public mutating func propose(_ edit: RuleEdit, chosen: [RuleReviewSuggestion]? = nil, now: Date = Date()) {
        if let chosen {
            let titles = Set(chosen.map { Self.clip($0.title, 300) })
            for index in suggestions.indices { suggestions[index].accepted = titles.contains(suggestions[index].title) }
        }
        proposedRule = Self.ruleJSON(edit.rule)
        explanation = edit.explanation.map { Self.clip($0, 2_000) }
        outcome = .proposed
        updatedAt = now
    }

    /// How the session ended in the editor; `rule` is what was saved.
    public mutating func finish(_ outcome: Outcome, savedRule rule: Rule? = nil, now: Date = Date()) {
        self.outcome = outcome
        savedRule = rule.map(Self.ruleJSON)
        updatedAt = now
    }

    /// Whether the session says anything about what the user wants: they
    /// replied, chose suggestions, or decided what to do with the AI's rule.
    var isInformative: Bool {
        !replies.isEmpty || outcome != .reviewed || suggestions.contains { $0.accepted != nil }
    }
}

// MARK: - Using it in reviews

/// Picks the earlier reviews that matter for a new one and turns them into
/// the part of the prompt that lets the AI learn from them: follow what the
/// user asked for before, not repeat what they turned down, and reuse rules
/// they saved for similar goals.
public enum RuleReviewMemory {
    /// Most past reviews sent along with a new one.
    public static let maximumCases = 4
    /// Most characters of past reviews in one prompt.
    static let maximumPromptCharacters = 6_000
    /// A saved rule longer than this is described, not quoted.
    static let maximumQuotedRule = 2_500
    /// Reviews kept on disk; older ones are forgotten first.
    public static let maximumStoredRecords = 200

    /// Lowercased words of four letters or more, without accents.
    static func words(_ text: String) -> Set<String> {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return Set(folded.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 4 })
    }

    static func score(_ record: RuleReviewRecord, rule: Rule, folderPath: String?, goal: String) -> Int {
        var score = 0
        if record.ruleId == rule.id { score += 6 }
        if let folderPath, !folderPath.isEmpty, record.folderPath == folderPath { score += 3 }
        let actionKinds = Set(rule.actions.map(\.kind.rawValue))
        let conditionKinds = Set(rule.conditionGroups.flatMap(\.conditions).map(\.kind.rawValue))
        score += min(3, actionKinds.intersection(record.actionKinds).count)
        score += min(2, conditionKinds.intersection(record.conditionKinds).count)
        let goalWords = words(goal + " " + rule.name)
        score += min(3, goalWords.intersection(words(record.goal + " " + record.ruleName)).count)
        if record.outcome == .saved || record.outcome == .undone || !record.replies.isEmpty { score += 1 }
        return score
    }

    /// The past reviews worth sending with a review of `rule`, most
    /// relevant first. `excluding` is the review in progress.
    public static func relevant(
        _ records: [RuleReviewRecord],
        for rule: Rule,
        folderPath: String?,
        goal: String,
        excluding: String? = nil,
        limit: Int = maximumCases
    ) -> [RuleReviewRecord] {
        var scored: [(record: RuleReviewRecord, score: Int)] = []
        for record in records where record.id != excluding && record.isInformative {
            let value = score(record, rule: rule, folderPath: folderPath, goal: goal)
            if value >= 3 { scored.append((record, value)) }
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.record.updatedAt > rhs.record.updatedAt
        }
        return Array(scored.prefix(limit).map { $0.record })
    }

    static func outcomeLine(_ record: RuleReviewRecord) -> String? {
        switch record.outcome {
        case .reviewed: return nil
        case .proposed: return "The AI wrote the rule, but I didn't use it."
        case .used: return "I loaded the AI's rule into the editor."
        case .saved:
            return record.savedRule != nil && record.savedRule != record.proposedRule
                ? "I saved the AI's rule after changing it myself."
                : "I saved the AI's rule."
        case .undone: return "I undid the AI's rule and kept my own."
        case .discarded: return "I closed the editor without saving the AI's rule."
        }
    }

    static func describe(_ record: RuleReviewRecord, number: Int, currentRuleId: String) -> String {
        let day = ISO8601DateFormatter.forelUTC.string(from: record.updatedAt).prefix(10)
        var lines = ["Review \(number) (\(day)" + (record.ruleId == currentRuleId ? ", this same rule" : ", rule “\(record.ruleName)”")
            + (record.folderPath.map { " in \($0)" } ?? "") + "):"]
        if !record.goal.isEmpty { lines.append("- My goal: \(record.goal)") }
        let accepted = record.suggestions.filter { $0.accepted == true }.map(\.title)
        let rejected = record.suggestions.filter { $0.accepted == false }.map(\.title)
        if !accepted.isEmpty { lines.append("- I applied: " + accepted.joined(separator: "; ")) }
        if !rejected.isEmpty { lines.append("- I turned down: " + rejected.joined(separator: "; ")) }
        if accepted.isEmpty, rejected.isEmpty, !record.suggestions.isEmpty, record.outcome == .reviewed {
            lines.append("- I applied none of: " + record.suggestions.map(\.title).joined(separator: "; "))
        }
        for reply in record.replies { lines.append("- I told the AI: \(reply)") }
        if let outcome = outcomeLine(record) { lines.append("- \(outcome)") }
        if record.outcome == .saved, let saved = record.savedRule ?? record.proposedRule {
            lines.append(saved.count <= maximumQuotedRule ? "- The rule I saved:\n\(saved)" : "- (The saved rule is too long to quote.)")
        }
        return lines.joined(separator: "\n")
    }

    /// The prompt section for `records` (already chosen with `relevant`),
    /// within `maximumPromptCharacters`; nil when there's nothing to say.
    static func promptSection(_ records: [RuleReviewRecord], currentRuleId: String) -> String? {
        var cases: [String] = []
        var used = 0
        for record in records {
            let text = describe(record, number: cases.count + 1, currentRuleId: currentRuleId)
            guard used + text.count <= maximumPromptCharacters else { continue }
            cases.append(text)
            used += text.count
        }
        guard !cases.isEmpty else { return nil }
        return """
        What I decided in earlier reviews of similar rules (most relevant first, for context). Follow the preferences \
        I stated there, don't suggest again what I turned down unless this rule makes it important (then say why), and \
        reuse approaches from rules I saved when they fit this one:

        """ + cases.joined(separator: "\n\n")
    }
}
