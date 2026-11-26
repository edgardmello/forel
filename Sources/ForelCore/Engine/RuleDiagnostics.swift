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

/// A problem (or a likely surprise) in how a folder's rules work together:
/// a rule that never gets files because one above it takes them first,
/// files that bounce between watched folders, and so on.
public struct RuleDiagnostic: Sendable, Identifiable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        /// Files this rule would handle are taken first by a rule above it
        /// (found by checking the folder's actual files).
        case shadowed
        /// A rule that matches almost anything sits above rules that move
        /// files, so those rules only ever see what it leaves behind.
        case catchAllAboveOthers
        /// Files go into a new dated subfolder of the watched folder that
        /// none of its rules look into, so they stay there for good.
        case datedSubfoldersNeverRevisited
        /// The rule moves files into another watched folder, whose rules
        /// then run on them too.
        case chainIntoWatchedFolder
        /// Watched folders move files around in a circle.
        case chainLoop
        /// The same conditions appear in several folders with different
        /// destinations, so where a file ends up depends on where it landed.
        case duplicatedAcrossFolders
        /// The rule has no conditions and moves or deletes every file.
        case noConditions
        /// The watched folder doesn't exist on disk.
        case folderMissing
        /// The rule still has its default name.
        case untitled
    }

    public enum Severity: Int, Sendable, Comparable {
        case note
        case warning

        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var id: String { "\(kind.rawValue):\(folderId):\(ruleIds.joined(separator: ","))" }
    public let kind: Kind
    public let severity: Severity
    public let folderId: String
    /// The rules involved; the first is the one to look at.
    public let ruleIds: [String]
    public let title: String
    public let message: String

    public init(kind: Kind, severity: Severity, folderId: String, ruleIds: [String], title: String, message: String) {
        self.kind = kind
        self.severity = severity
        self.folderId = folderId
        self.ruleIds = ruleIds
        self.title = title
        self.message = message
    }
}

/// How one file is judged by every rule of its folder at once: which rules
/// match it and which one gets it first.
public struct RuleCompetition: Sendable, Equatable {
    public let path: String
    /// Enabled rules whose conditions match the file, in folder order.
    public let matchingRuleIds: [String]
    /// The first matching rule that moves, deletes or ignores the file;
    /// rules after it never see the file in this folder.
    public let winnerRuleId: String?
}

public enum RuleDiagnostics {
    // MARK: - Rule traits

    /// True when the rule takes the file away from the folder (or stops
    /// later rules): move, sort into subfolder, trash, delete, ignore.
    public static func takesFileAway(_ rule: Rule) -> Bool {
        rule.actions.contains { removingActionKinds.contains($0.kind) }
    }

    static let removingActionKinds: Set<ActionKind> = [.moveToFolder, .sortIntoSubfolder, .moveToTrash, .delete, .ignore]

    /// Condition kinds that pick out files by what they are or where they
    /// came from, not just by type or age.
    static let preciseConditionKinds: Set<ConditionKind> = [
        .contents, .aiClassification, .downloadedFromWebsite, .downloadedWithApp,
        .rawWhereFromMetadata, .spotlightMetadata, .finderComment, .tags, .colorLabel,
        .filePath, .duplicate, .photoDateTaken, .pdfPageCount, .imageWidth, .imageHeight,
    ]

    /// Condition kinds that only look at age, size, time or the machine's
    /// state: on their own they match most files.
    static let broadConditionKinds: Set<ConditionKind> = [
        .createdAt, .dateModified, .dateAdded, .lastOpened, .sizeBytes, .timeOfDay,
        .dayOfWeek, .ruleLastRan, .powerSource, .dateLastMatched, .timesMatched, .itemCount,
    ]

    /// How narrowly a rule picks files, used to suggest an order:
    /// lower tiers should run first.
    public enum Specificity: Int, Sendable, Comparable {
        /// Ignore rules and duplicate cleanup: run before anything else.
        case cleanup
        /// Content, origin, tags, or a name pattern.
        case precise
        /// A file type or extension, or a plain name check.
        case byType
        /// Only age, size or time — or no conditions at all.
        case catchAll

        public static func < (lhs: Specificity, rhs: Specificity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public static func specificity(_ rule: Rule) -> Specificity {
        let conditions = rule.conditions
        if rule.actions.contains(where: { $0.kind == .ignore }) || conditions.contains(where: { $0.kind == .duplicate }) {
            return .cleanup
        }
        if conditions.isEmpty { return .catchAll }
        // Negations ("is not a folder", "doesn't contain") narrow almost nothing.
        let narrowing = conditions.filter { ![.isNot, .doesNotContain].contains($0.operator) }
        if narrowing.contains(where: { preciseConditionKinds.contains($0.kind) }) { return .precise }
        if narrowing.contains(where: { $0.kind == .name && $0.operator == .matchesRegex }) { return .precise }
        if narrowing.contains(where: { $0.kind == .name || $0.kind == .extension_ || $0.kind == .kind }) { return .byType }
        return .catchAll
    }

    // MARK: - Suggested order

    /// The folder's rules in a suggested order: cleanup first, then rules
    /// that only tag or label (they don't take the file away, so they must
    /// run before rules that do), then rules that move files from the most
    /// to the least specific. Rules keep their relative order within a step.
    public static func suggestedOrder(_ rules: [Rule]) -> [Rule] {
        rules.enumerated().sorted { lhs, rhs in
            let l = orderKey(lhs.element), r = orderKey(rhs.element)
            if l != r { return l < r }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func orderKey(_ rule: Rule) -> Int {
        let tier = specificity(rule)
        if tier == .cleanup { return 0 }
        guard takesFileAway(rule) else { return 1 }
        return 1 + tier.rawValue
    }

    // MARK: - Static checks

    /// Checks every folder's rules without reading any file (only whether
    /// the watched folders exist). `rulesByFolder` is keyed by folder id and
    /// lists each folder's rules in order.
    public static func analyze(
        folders: [WatchedFolder],
        rulesByFolder: [String: [Rule]],
        folderExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [RuleDiagnostic] {
        var diagnostics: [RuleDiagnostic] = []
        let enabledFolders = folders.filter(\.enabled)

        for folder in folders {
            let rules = rulesByFolder[folder.id] ?? []
            if folder.enabled, !folderExists(folder.path) {
                diagnostics.append(RuleDiagnostic(
                    kind: .folderMissing, severity: .warning, folderId: folder.id, ruleIds: rules.map(\.id),
                    title: "Watched folder is missing",
                    message: "\(folder.path) doesn't exist, so its \(rules.count == 1 ? "rule never runs" : "\(rules.count) rules never run"). Create the folder again or remove it from Forel."
                ))
            }
            diagnostics += checkRules(rules, in: folder)
        }

        diagnostics += checkChains(folders: enabledFolders, rulesByFolder: rulesByFolder)
        diagnostics += checkDuplicates(folders: folders, rulesByFolder: rulesByFolder)
        return diagnostics
    }

    private static func checkRules(_ rules: [Rule], in folder: WatchedFolder) -> [RuleDiagnostic] {
        var diagnostics: [RuleDiagnostic] = []
        let enabled = rules.filter(\.enabled)

        for (index, rule) in enabled.enumerated() {
            let trimmed = rule.name.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == "New Rule" {
                diagnostics.append(RuleDiagnostic(
                    kind: .untitled, severity: .note, folderId: folder.id, ruleIds: [rule.id],
                    title: "Rule has no name",
                    message: "Give it a name that says what it does, so it's easy to find in Activity and in this list."
                ))
            }

            if rule.conditions.isEmpty, takesFileAway(rule) {
                diagnostics.append(RuleDiagnostic(
                    kind: .noConditions, severity: .warning, folderId: folder.id, ruleIds: [rule.id],
                    title: "“\(rule.name)” acts on every file",
                    message: "It has no conditions, so it moves, deletes or ignores everything in the folder, and no rule below it ever runs."
                ))
            } else if specificity(rule) == .catchAll, takesFileAway(rule) {
                let later = enabled[(index + 1)...].filter { takesFileAway($0) && specificity($0) < .catchAll }
                if !later.isEmpty {
                    let names = later.prefix(3).map { "“\($0.name)”" }.joined(separator: ", ")
                    let more = later.count > 3 ? " and \(later.count - 3) more" : ""
                    diagnostics.append(RuleDiagnostic(
                        kind: .catchAllAboveOthers, severity: .warning, folderId: folder.id, ruleIds: [rule.id] + later.map(\.id),
                        title: "“\(rule.name)” takes files before more specific rules",
                        message: "Its conditions only look at age, size or “is not”, so it matches most files and takes them first. \(names)\(more) only get what it leaves behind. Move it below them, or narrow its conditions."
                    ))
                }
            }

            for action in rule.actions {
                guard let subfolder = datedSubfolder(action, folder: folder) else { continue }
                let movers = enabled.filter { takesFileAway($0) && $0.id != rule.id }
                let reaching = movers.filter { mover in mover.recursionDepth.map { $0 >= Int64(subfolder.depth) } ?? true }
                guard reaching.count * 2 < max(1, movers.count) else { continue }
                let reach = reaching.isEmpty
                    ? "none of the folder's other rules look that deep"
                    : "only \(reaching.count) of the folder's \(movers.count) other rules look that deep"
                diagnostics.append(RuleDiagnostic(
                    kind: .datedSubfoldersNeverRevisited, severity: .warning, folderId: folder.id, ruleIds: [rule.id],
                    title: "“\(rule.name)” creates dated folders that aren't sorted further",
                    message: "It puts files into a new “\(subfolder.template)” folder inside \((folder.path as NSString).lastPathComponent), but \(reach), so those files stay there for good. To hold files for a while before sorting them, use an inbox folder whose rules wait with “Date Added is older than”."
                ))
            }
        }
        return diagnostics
    }

    /// A move/sort action whose destination is a date-stamped folder inside
    /// the watched folder; returns its template and the depth files land at.
    private static func datedSubfolder(_ action: Action, folder: WatchedFolder) -> (template: String, depth: Int)? {
        let dateTokens = ["{year", "{month", "{day", "{current_date", "{date_", "{yyyy", "{dd"]
        switch action.kind {
        case .sortIntoSubfolder:
            let template = action.params[ActionParam.subfolder]?.stringValue ?? ""
            guard dateTokens.contains(where: template.contains) else { return nil }
            let levels = template.split(separator: "/").count
            return (template, levels)
        case .moveToFolder:
            let destination = action.params[ActionParam.destination]?.stringValue ?? ""
            guard dateTokens.contains(where: destination.contains) else { return nil }
            let literal = literalPrefix(destination)
            guard let literalDepth = RuleEngine.pathDepth(root: folder.path, path: literal + "/x") else { return nil }
            let remaining = (destination as NSString).pathComponents.count - (literal as NSString).pathComponents.count
            let relative = String(destination.dropFirst(folder.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return (relative, literalDepth + max(0, remaining))
        default:
            return nil
        }
    }

    /// The part of a destination template before its first token, as a
    /// folder path ("/a/b/{year}" → "/a/b").
    static func literalPrefix(_ template: String) -> String {
        guard let brace = template.firstIndex(of: "{") else { return (template as NSString).standardizingPath }
        let head = String(template[..<brace])
        let folder = head.hasSuffix("/") ? head : (head as NSString).deletingLastPathComponent
        return (folder as NSString).standardizingPath
    }

    /// The watched folder (other than `source`) a destination lands in.
    static func watchedFolder(containing destination: String, in folders: [WatchedFolder], excluding source: WatchedFolder) -> WatchedFolder? {
        folders
            .filter { $0.id != source.id && RuleEngine.pathDepth(root: $0.path, path: destination + "/x") != nil }
            .max { $0.path.count < $1.path.count }
    }

    private static func checkChains(folders: [WatchedFolder], rulesByFolder: [String: [Rule]]) -> [RuleDiagnostic] {
        var diagnostics: [RuleDiagnostic] = []
        var edges: [String: Set<String>] = [:]
        var edgeRule: [String: String] = [:]

        for folder in folders {
            for rule in (rulesByFolder[folder.id] ?? []) where rule.enabled {
                for action in rule.actions where action.kind == .moveToFolder {
                    let destination = literalPrefix(action.params[ActionParam.destination]?.stringValue ?? "")
                    guard !destination.isEmpty,
                          RuleEngine.pathDepth(root: folder.path, path: destination + "/x") == nil
                            || isNested(destination, inOtherWatchedFolderOf: folder, folders: folders),
                          let target = watchedFolder(containing: destination, in: folders, excluding: folder) else { continue }
                    edges[folder.id, default: []].insert(target.id)
                    edgeRule["\(folder.id)>\(target.id)"] = rule.id
                    diagnostics.append(RuleDiagnostic(
                        kind: .chainIntoWatchedFolder, severity: .note, folderId: folder.id, ruleIds: [rule.id],
                        title: "“\(rule.name)” hands files to \((target.path as NSString).lastPathComponent)",
                        message: "It moves files into \(target.path), which Forel also watches, so that folder's rules run on them next. Check that they don't send the files somewhere else."
                    ))
                }
            }
        }

        // Cycles: A → B → … → A.
        var reported = Set<String>()
        for start in folders.map(\.id) {
            var stack: [(String, [String])] = [(start, [start])]
            while let (node, path) = stack.popLast() {
                for next in edges[node] ?? [] {
                    if next == start {
                        let key = path.sorted().joined(separator: ",")
                        guard reported.insert(key).inserted else { continue }
                        let names = (path + [start]).compactMap { id in folders.first { $0.id == id }.map { ($0.path as NSString).lastPathComponent } }
                        let ruleIds = zip(path, path.dropFirst() + [start]).compactMap { edgeRule["\($0)>\($1)"] }
                        diagnostics.append(RuleDiagnostic(
                            kind: .chainLoop, severity: .warning, folderId: start, ruleIds: ruleIds,
                            title: "Files can go around in a circle",
                            message: "Rules move files \(names.joined(separator: " → ")). A file matching all of them keeps moving. Narrow one of these rules so it skips files the next folder sends back."
                        ))
                    } else if !path.contains(next) {
                        stack.append((next, path + [next]))
                    }
                }
            }
        }
        return diagnostics
    }

    /// True when `destination` is inside `folder` but also inside another
    /// watched folder nested in it (e.g. Downloads → Downloads/_Inbox).
    private static func isNested(_ destination: String, inOtherWatchedFolderOf folder: WatchedFolder, folders: [WatchedFolder]) -> Bool {
        folders.contains { other in
            other.id != folder.id
                && other.path.count > folder.path.count
                && RuleEngine.pathDepth(root: folder.path, path: other.path) != nil
                && RuleEngine.pathDepth(root: other.path, path: destination + "/x") != nil
        }
    }

    private static func checkDuplicates(folders: [WatchedFolder], rulesByFolder: [String: [Rule]]) -> [RuleDiagnostic] {
        var bySignature: [String: [(WatchedFolder, Rule)]] = [:]
        for folder in folders {
            for rule in (rulesByFolder[folder.id] ?? []) where rule.enabled && takesFileAway(rule) && !rule.conditions.isEmpty {
                bySignature[conditionSignature(rule), default: []].append((folder, rule))
            }
        }
        var diagnostics: [RuleDiagnostic] = []
        for group in bySignature.values where Set(group.map(\.0.id)).count > 1 {
            let destinations = Set(group.map { actionSignature($0.1) })
            guard destinations.count > 1 else { continue }
            let first = group[0]
            let folderNames = group.map { ($0.0.path as NSString).lastPathComponent }.joined(separator: ", ")
            diagnostics.append(RuleDiagnostic(
                kind: .duplicatedAcrossFolders, severity: .note, folderId: first.0.id, ruleIds: group.map(\.1.id),
                title: "“\(first.1.name)” is repeated with different actions",
                message: "The same conditions are in \(folderNames), but each copy does something different, so where a file ends up depends on which folder it landed in. Make them do the same thing, or share one rule across those folders."
            ))
        }
        return diagnostics
    }

    private static func conditionSignature(_ rule: Rule) -> String {
        let groups = rule.conditionGroups.map { group in
            group.match.rawValue + "[" + group.conditions
                .map { "\($0.kind.rawValue)|\($0.operator.rawValue)|\($0.value.lowercased())" }
                .sorted().joined(separator: ";") + "]"
        }
        return rule.conditionMatch.rawValue + groups.sorted().joined()
    }

    private static func actionSignature(_ rule: Rule) -> String {
        rule.actions.sorted { $0.position < $1.position }
            .map { "\($0.kind.rawValue)\($0.params)" }
            .joined(separator: ";")
    }

    // MARK: - Checking real files

    /// Judges `path` against every rule of its folder at once.
    public static func competition(path: String, depth: Int, rules: [Rule]) -> RuleCompetition {
        var matching: [String] = []
        var winner: String?
        for rule in rules where rule.enabled {
            guard RuleEngine.ruleMatches(rule, path: path, depth: depth) else { continue }
            matching.append(rule.id)
            if winner == nil, takesFileAway(rule) { winner = rule.id }
        }
        return RuleCompetition(path: path, matchingRuleIds: matching, winnerRuleId: winner)
    }

    /// Looks at up to `fileLimit` files in `folder` and reports rules whose
    /// files are taken first by a rule above them. Reads file contents for
    /// content conditions, so run it off the main thread.
    public static func shadowing(
        folder: WatchedFolder,
        rules: [Rule],
        fileLimit: Int = 300,
        skipping nested: Set<String> = [],
        isCancelled: () -> Bool = { false }
    ) -> [RuleDiagnostic] {
        let enabled = rules.filter(\.enabled)
        guard enabled.count > 1 else { return [] }
        // pair "winner>loser" → files
        var counts: [String: Int] = [:]
        var order: [String] = []
        var scanned = 0
        RuleEngine.forEachEntry(root: folder.path, maxDepth: RuleEngine.maxRuleDepth(enabled), skipping: nested) { entry in
            guard scanned < fileLimit, !isCancelled() else { return }
            guard !SystemFileFilter.isExcluded((entry.path as NSString).lastPathComponent) else { return }
            scanned += 1
            let result = competition(path: entry.path, depth: entry.depth, rules: enabled)
            guard let winner = result.winnerRuleId,
                  let winnerIndex = result.matchingRuleIds.firstIndex(of: winner) else { return }
            guard let winnerRule = enabled.first(where: { $0.id == winner }) else { return }
            let winnerSpecificity = specificity(winnerRule)
            for loser in result.matchingRuleIds[(winnerIndex + 1)...] {
                // A broader rule further down is meant to get only what's
                // left over, so losing these files to a narrower rule is fine.
                guard let rule = enabled.first(where: { $0.id == loser }), takesFileAway(rule),
                      specificity(rule) <= winnerSpecificity else { continue }
                let key = "\(winner)>\(loser)"
                if counts[key] == nil { order.append(key) }
                counts[key, default: 0] += 1
            }
        }

        return order.compactMap { key -> RuleDiagnostic? in
            let ids = key.split(separator: ">").map(String.init)
            guard ids.count == 2,
                  let winner = enabled.first(where: { $0.id == ids[0] }),
                  let loser = enabled.first(where: { $0.id == ids[1] }),
                  let count = counts[key] else { return nil }
            let files = count == 1 ? "1 file" : "\(count) files"
            return RuleDiagnostic(
                kind: .shadowed, severity: .warning, folderId: folder.id, ruleIds: [loser.id, winner.id],
                title: "“\(winner.name)” takes files meant for “\(loser.name)”",
                message: "\(files) here match both, and “\(winner.name)” runs first, so “\(loser.name)” never gets \(count == 1 ? "it" : "them"). Move “\(loser.name)” above it, or narrow “\(winner.name)”."
            )
        }
    }
}
