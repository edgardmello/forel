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

extension RuleEngine {
    /// "Coming Up": the files in `root` that rules waiting on time ("Date
    /// Added is older than 1 day", a time-of-day window…) will act on within
    /// `lookahead`, but not yet. Lets a daily inbox show what tomorrow's
    /// sorting will do before it happens. Changes nothing.
    ///
    /// Each file is previewed twice with the same rules: now, and with the
    /// clock moved ahead. Only rules whose outcome can change with time are
    /// looked at, and a file is listed when one of them acts on it later but
    /// none does now.
    public static func upcoming(
        root: String,
        rules: [Rule],
        lookahead: TimeInterval,
        now: Date = Date(),
        nestedRoots: Set<String> = [],
        matchLimit: Int? = nil,
        isCancelled: () -> Bool = { false }
    ) -> PreviewResult {
        let timed = rules.filter { $0.enabled && isTimeDependent($0) }
        guard !timed.isEmpty else { return PreviewResult(filesScanned: 0, matches: [], lookahead: lookahead) }
        let enabled = rules.filter(\.enabled)
        let timedIds = Set(timed.map(\.id))
        var scanned = 0
        var matches: [FilePreview] = []
        var reachedLimit = false
        forEachEntry(root: root, maxDepth: maxRuleDepth(timed), skipping: nestedRoots) { entry in
            guard !reachedLimit, !isCancelled() else { return }
            scanned += 1
            let current = ScheduleConditions.$clock.withValue(now) {
                previewFile(path: entry.path, depth: entry.depth, rules: enabled, root: root, nestedRoots: nestedRoots)
            }
            if let current, current.rules.contains(where: { timedIds.contains($0.ruleId) }) { return }
            let later = ScheduleConditions.$clock.withValue(now.addingTimeInterval(lookahead)) {
                previewFile(path: entry.path, depth: entry.depth, rules: enabled, root: root, nestedRoots: nestedRoots)
            }
            guard let later, later.rules.contains(where: { timedIds.contains($0.ruleId) }) else { return }
            matches.append(later)
            if let matchLimit, matches.count >= matchLimit { reachedLimit = true }
        }
        return PreviewResult(filesScanned: scanned, matches: matches, matchLimit: matchLimit, reachedMatchLimit: reachedLimit, lookahead: lookahead)
    }
}
