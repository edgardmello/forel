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

// MARK: - Result

/// One piece of advice from "Review with AI".
public struct RuleReviewSuggestion: Equatable, Sendable, Identifiable {
    public enum Category: String, Sendable, CaseIterable {
        /// The rule doesn't do what it seems meant to do.
        case problem
        /// The rule could do less work for the same result.
        case efficiency
        /// The same result with fewer or clearer conditions/actions.
        case simplification
        /// A risk of losing or overwriting files.
        case safety
        /// A different, better way to reach the same goal.
        case alternative
        case other
    }

    public let id: Int
    public let category: Category
    public let title: String
    public let detail: String

    public init(id: Int, category: Category, title: String, detail: String) {
        self.id = id
        self.category = category
        self.title = title
        self.detail = detail
    }
}

/// Step 1 of "Review with AI": what the service found in a rule.
public struct RuleReview: Equatable, Sendable {
    public let summary: String
    public let suggestions: [RuleReviewSuggestion]

    public init(summary: String, suggestions: [RuleReviewSuggestion]) {
        self.summary = summary
        self.suggestions = suggestions
    }
}

/// Step 2: the rule rewritten by the service with the suggestions the user
/// accepted, checked against what Forel supports and keeping the original
/// rule's identity, folder, name, state and priority.
public struct RuleEdit: Equatable, Sendable {
    public let rule: Rule
    public let explanation: String?

    public init(rule: Rule, explanation: String?) {
        self.rule = rule
        self.explanation = explanation
    }
}

/// The edited rule names something Forel doesn't have, or doesn't pass the
/// checks Save makes.
public struct RuleEditError: Error, Equatable, CustomStringConvertible {
    public let problems: [String]
    public init(problems: [String]) { self.problems = problems }
    public var description: String {
        "The rule the service wrote can't be used: " + problems.joined(separator: " ") + " Try again."
    }
}

// MARK: - Compact rule format

/// The rule shape exchanged with the AI service: only what decides the
/// rule's behavior, with Forel's own identifiers for kinds and operators
/// and no database IDs. Kinds and operators are plain strings so an answer
/// naming something Forel doesn't have can be explained instead of failing
/// to decode.
struct RuleBlueprint: Codable, Equatable {
    struct Condition: Codable, Equatable {
        var kind: String
        var `operator`: String
        var value: String

        init(kind: String, operator: String, value: String) {
            self.kind = kind
            self.operator = `operator`
            self.value = value
        }

        private enum CodingKeys: String, CodingKey { case kind, `operator`, value }

        /// Models sometimes answer `"value": 10` for a number; accept it.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try c.decode(String.self, forKey: .kind)
            `operator` = try c.decode(String.self, forKey: .operator)
            switch try c.decodeIfPresent(JSONValue.self, forKey: .value) ?? .string("") {
            case .string(let text): value = text
            case .number(let number):
                value = number.rounded() == number && abs(number) < 1e15 ? String(Int64(number)) : String(number)
            case .bool(let flag): value = flag ? "true" : "false"
            default: value = ""
            }
        }
    }

    struct Group: Codable, Equatable {
        var match: String
        var conditions: [Condition]
    }

    struct Action: Codable, Equatable {
        var kind: String
        var params: JSONValue?
    }

    var name: String?
    var enabled: Bool?
    var conditionMatch: String
    /// `nil` means "all subfolders"; see `hasRecursionDepth`.
    var recursionDepth: Int64?
    /// Whether the JSON had a `recursionDepth` key at all: a missing key
    /// keeps the reviewed rule's scope, `null` means every subfolder.
    var hasRecursionDepth: Bool
    var conditionGroups: [Group]
    var actions: [Action]

    private enum CodingKeys: String, CodingKey {
        case name, enabled, conditionMatch, recursionDepth, conditionGroups, actions
    }

    init(_ rule: Rule) {
        name = rule.name
        enabled = rule.enabled
        conditionMatch = rule.conditionMatch.rawValue
        recursionDepth = rule.recursionDepth
        hasRecursionDepth = true
        conditionGroups = rule.conditionGroups.map { group in
            Group(match: group.match.rawValue, conditions: group.conditions.map {
                Condition(kind: $0.kind.rawValue, operator: $0.operator.rawValue, value: $0.value)
            })
        }
        actions = rule.actions.sorted { $0.position < $1.position }.map {
            Action(kind: $0.kind.rawValue, params: RuleReviewer.redacted($0.params, kind: $0.kind))
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        enabled = try? c.decodeIfPresent(Bool.self, forKey: .enabled)
        conditionMatch = (try? c.decodeIfPresent(String.self, forKey: .conditionMatch)) ?? ConditionMatch.all.rawValue
        hasRecursionDepth = c.contains(.recursionDepth)
        if let depth = try? c.decodeIfPresent(Int64.self, forKey: .recursionDepth) {
            recursionDepth = depth
        } else if let depth = try? c.decodeIfPresent(Double.self, forKey: .recursionDepth) {
            recursionDepth = Int64(depth)
        } else {
            recursionDepth = nil
        }
        conditionGroups = try c.decodeIfPresent([Group].self, forKey: .conditionGroups) ?? []
        actions = try c.decodeIfPresent([Action].self, forKey: .actions) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(enabled, forKey: .enabled)
        try c.encode(conditionMatch, forKey: .conditionMatch)
        // Written even when nil: null is meaningful ("all subfolders").
        try c.encode(recursionDepth, forKey: .recursionDepth)
        try c.encode(conditionGroups, forKey: .conditionGroups)
        try c.encode(actions, forKey: .actions)
    }

    /// `base` with this blueprint's scope, conditions and actions, keeping
    /// the base rule's identity, folder, name, state and priority. Returns
    /// the list of problems instead when anything doesn't fit Forel's schema.
    func applied(to base: Rule) -> (rule: Rule?, problems: [String]) {
        var problems: [String] = []

        func match(_ raw: String, allowNone: Bool) -> ConditionMatch? {
            guard let mode = ConditionMatch(rawValue: raw.lowercased()), allowNone || mode != .none else {
                problems.append("Unknown match mode “\(raw)”.")
                return nil
            }
            return mode
        }

        let ruleMatch = match(conditionMatch, allowNone: true) ?? .all
        var groups: [ConditionGroup] = []
        for group in conditionGroups {
            let groupMatch = match(group.match, allowNone: false) ?? .all
            var conditions: [ForelCore.Condition] = []
            for condition in group.conditions {
                guard let kind = ConditionKind(rawValue: condition.kind) else {
                    problems.append("Forel has no “\(condition.kind)” condition.")
                    continue
                }
                guard let op = Operator(rawValue: condition.operator), kind.validOperators.contains(op) else {
                    problems.append("The \(kind.label) condition can't use “\(condition.operator)”.")
                    continue
                }
                conditions.append(ForelCore.Condition(ruleId: base.id, kind: kind, operator: op, value: condition.value))
            }
            groups.append(ConditionGroup(match: groupMatch, conditions: conditions))
        }
        if groups.isEmpty { groups = [ConditionGroup(match: ruleMatch.groupDefault)] }

        var actions: [ForelCore.Action] = []
        for (index, action) in self.actions.enumerated() {
            guard let kind = ActionKind(rawValue: action.kind) else {
                problems.append("Forel has no “\(action.kind)” action.")
                continue
            }
            var params = action.params ?? .object([:])
            if case .object = params {} else { params = .object([:]) }
            params = RuleReviewer.normalizedParams(params, kind: kind)
            actions.append(ForelCore.Action(ruleId: base.id, kind: kind, params: params, position: Int64(index)))
        }
        if actions.isEmpty { problems.append("The proposed version has no actions.") }
        problems += RuleReviewer.unknownTokenProblems(in: actions, conditionGroups: groups, base: base)
        problems += RuleReviewer.paramProblems(in: actions, base: base)

        let depth = hasRecursionDepth ? recursionDepth.map { max(0, $0) } : base.recursionDepth
        var rule = base
        rule.conditionMatch = ruleMatch
        rule.recursionDepth = depth
        rule.conditionGroups = groups
        rule.actions = actions

        let issues = RuleValidator.validate(rule.conditions)
            + RuleValidator.validate(groups: rule.conditionGroups)
            + RuleValidator.validate(rule.actions)
        problems += issues.map(\.message)

        guard problems.isEmpty else {
            var seen = Set<String>()
            return (nil, problems.filter { seen.insert($0).inserted })
        }
        return (rule, [])
    }
}

// MARK: - Reviewer

/// "Review with AI", in two steps. First the rule is analyzed on its own:
/// Forel explains its rule model and catalog to the AI service set up in
/// Settings → AI, which works out what the rule is for and lists concrete
/// improvements. Then the service rewrites the rule with the suggestions
/// the user accepted. What is sent: the rule (its conditions, actions,
/// paths and embedded scripts, with upload passwords removed), the watched
/// folder's path, the user's optional description of the rule's goal, the
/// folder's other rules (analysis only), the user's replies and the macOS
/// version — never file names or contents.
public enum RuleReviewer {
    /// Most other rules of the folder sent along for overlap checks.
    static let maximumSiblingRules = 20

    /// Upload URLs can carry a user name and password; send them without.
    static func redacted(_ params: JSONValue, kind: ActionKind) -> JSONValue {
        guard kind == .upload, case .object(var dict) = params,
              let url = dict[ActionParam.uploadURL]?.stringValue else { return params }
        dict[ActionParam.uploadURL] = .string(UploadDestination.displayString(for: url))
        return .object(dict)
    }

    // MARK: Params

    /// What a param's value must be.
    enum ParamValue: Equatable {
        case text
        case bool
        case number
        /// Text, or a number Forel reads as one.
        case textOrNumber
        /// An array of strings.
        case list
        /// One of these strings.
        case choice([String])
    }

    /// Every param each action reads, and what its value must be. The
    /// prompt's action catalog describes these; a test keeps the two equal.
    static func acceptedParams(_ kind: ActionKind) -> [String: ParamValue] {
        let conflict = ParamValue.choice(MoveConflictResolution.allCases.map(\.rawValue))
        let scriptSource = ParamValue.choice([ScriptSource.embedded.rawValue, ScriptSource.file.rawValue])
        switch kind {
        case .moveToFolder, .copyToFolder, .syncToFolder:
            return [ActionParam.destination: .text, ActionParam.onConflict: conflict]
        case .sortIntoSubfolder:
            return [ActionParam.subfolder: .text, ActionParam.onConflict: conflict]
        case .uncompress:
            return [ActionParam.onConflict: conflict]
        case .syncFolders:
            return [ActionParam.destination: .text,
                    ActionParam.syncDirection: .choice(SyncDirection.allCases.map(\.rawValue)),
                    ActionParam.syncDeletePolicy: .choice(SyncDeletePolicy.allCases.map(\.rawValue))]
        case .rename:
            return [ActionParam.pattern: .text, ActionParam.cleanFileName: .bool]
        case .upload: return [ActionParam.uploadURL: .text]
        case .addTag, .removeTag: return [ActionParam.tags: .list]
        case .setColorLabel:
            return [ActionParam.color: .choice(["", "gray", "green", "purple", "blue", "yellow", "red", "orange"])]
        case .addComment: return [ActionParam.comment: .text]
        case .runScript:
            return [ActionParam.script: .text, ActionParam.scriptSource: scriptSource, ActionParam.scriptPath: .text,
                    ActionParam.shell: .choice(ScriptShell.allCases.map(\.rawValue))]
        case .runAppleScript, .runJavaScript:
            return [ActionParam.script: .text, ActionParam.scriptSource: scriptSource, ActionParam.scriptPath: .text]
        case .runShortcut:
            return [ActionParam.shortcutName: .text,
                    ActionParam.shortcutInputMode: .choice(ShortcutInputMode.allCases.map(\.rawValue))]
        case .openApplication:
            return [ActionParam.applicationPath: .text, ActionParam.passFileToApplication: .bool]
        case .makeAlias: return [ActionParam.aliasDestination: .text]
        case .importToLibrary:
            return [ActionParam.libraryType: .choice(LibraryType.allCases.map(\.rawValue)), ActionParam.targetPlaylist: .text]
        case .pause: return [ActionParam.pauseSeconds: .number]
        case .displayNotification:
            return [ActionParam.notificationTitle: .text, ActionParam.notificationBody: .text]
        case .convertImage:
            return [ActionParam.imageFormat: .choice(ImageFormat.allCases.map(\.rawValue)),
                    ActionParam.maxDimension: .textOrNumber, ActionParam.keepOriginal: .bool]
        case .compressPDF, .makeSearchablePDF:
            return [ActionParam.keepOriginal: .bool]
        case .runAutomatorWorkflow: return [ActionParam.workflowPath: .text]
        case .moveToTrash, .delete, .toggleExtension, .toggleLock, .archive, .open, .showInFinder,
             .runRulesOnFolderContents, .ignore:
            return [:]
        }
    }

    /// Why `value` doesn't fit `expected`, or nil when it does.
    static func paramValueProblem(_ value: JSONValue, _ expected: ParamValue) -> String? {
        switch (expected, value) {
        case (.text, .string), (.bool, .bool), (.number, .number), (.textOrNumber, .string), (.textOrNumber, .number): return nil
        case (.text, _): return "must be text"
        case (.textOrNumber, _): return "must be text or a number"
        case (.bool, _): return "must be true or false"
        case (.number, _): return "must be a number"
        case (.list, .array(let items)):
            return items.allSatisfy { $0.stringValue != nil } ? nil : "must be a list of names"
        case (.list, _): return "must be a list of names"
        case (.choice(let options), .string(let text)) where options.contains(text): return nil
        case (.choice(let options), _):
            return "must be one of " + options.map { $0.isEmpty ? "\"\"" : $0 }.joined(separator: ", ")
        }
    }

    /// Models often quote booleans and numbers ("true", "5"); store them
    /// as the type Forel reads, so they work instead of being rejected.
    static func normalizedParams(_ params: JSONValue, kind: ActionKind) -> JSONValue {
        guard case .object(var dict) = params else { return params }
        for (key, expected) in acceptedParams(kind) {
            guard case .string(let raw)? = dict[key] else { continue }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            switch expected {
            case .bool where ["true", "false"].contains(text.lowercased()):
                dict[key] = .bool(text.lowercased() == "true")
            case .number:
                if let number = Double(text) { dict[key] = .number(number) }
            default: break
            }
        }
        return .object(dict)
    }

    /// A param an action doesn't read is silently ignored, and one with the
    /// wrong kind of value falls back to a default — either way the rule
    /// wouldn't do what the service meant. What the user's own rule already
    /// had on an action of the same kind is left alone.
    static func paramProblems(in actions: [ForelCore.Action], base: Rule) -> [String] {
        var existing: [String: [JSONValue]] = [:]
        for action in base.actions {
            guard case .object(let dict) = action.params else { continue }
            for (key, value) in dict { existing["\(action.kind.rawValue).\(key)", default: []].append(value) }
        }
        var problems: [String] = []
        for action in actions {
            guard case .object(let dict) = action.params else { continue }
            let accepted = acceptedParams(action.kind)
            for key in dict.keys.sorted() {
                guard let value = dict[key] else { continue }
                let had = existing["\(action.kind.rawValue).\(key)"]
                guard let expected = accepted[key] else {
                    if had != nil { continue }
                    let names = accepted.keys.sorted()
                    problems.append("\(action.kind.label) has no “\(key)” param" + (names.isEmpty ? "; it takes none." : "; its params are " + names.joined(separator: ", ") + "."))
                    continue
                }
                if case .null = value { continue }
                if had?.contains(value) == true { continue }
                if let problem = paramValueProblem(value, expected) {
                    problems.append("\(action.kind.label): “\(key)” \(problem).")
                }
            }
        }
        return problems
    }

    // MARK: Tokens

    /// The params of `kind` whose text goes through `TokenExpander`.
    static func tokenParams(_ kind: ActionKind) -> [String] {
        switch kind {
        case .moveToFolder, .copyToFolder: return [ActionParam.destination]
        case .sortIntoSubfolder: return [ActionParam.subfolder]
        case .rename: return [ActionParam.pattern]
        case .addComment: return [ActionParam.comment]
        case .displayNotification: return [ActionParam.notificationTitle, ActionParam.notificationBody]
        default: return []
        }
    }

    /// Named groups of the regex conditions, which become tokens too.
    static func captureNames(_ groups: [ConditionGroup]) -> Set<String> {
        Set(groups.flatMap(\.conditions).filter { $0.operator == .matchesRegex }
            .flatMap { ConditionEvaluator.captureGroupNames(in: $0.value) })
    }

    static func unknownTokens(in actions: [ForelCore.Action], captureNames: Set<String>) -> [(token: String, kind: ActionKind)] {
        actions.flatMap { action in
            tokenParams(action.kind).flatMap { key in
                TokenExpander.unknownTokens(in: action.params[key]?.stringValue ?? "", captureNames: captureNames)
                    .map { (token: $0, kind: action.kind) }
            }
        }
    }

    /// A token Forel doesn't fill in stays in the name as typed — a folder
    /// literally called "{date}". Flags the ones the service introduced;
    /// ones the user's own rule already had are left alone.
    static func unknownTokenProblems(in actions: [ForelCore.Action], conditionGroups: [ConditionGroup], base: Rule) -> [String] {
        let existing = Set(unknownTokens(in: base.actions, captureNames: captureNames(base.conditionGroups)).map(\.token))
        let known = TokenExpander.builtInTokens.map { "{\($0.token)}" }.joined(separator: ", ")
        return unknownTokens(in: actions, captureNames: captureNames(conditionGroups))
            .filter { !existing.contains($0.token) }
            .map { "“\($0.token)” in \($0.kind.label) isn't a Forel token, so it would be used literally. Forel's tokens are \(known), {content:REGEX}, {ai:QUESTION} and named regex groups." }
    }

    static var tokenCatalog: String {
        TokenExpander.builtInTokens.map { "- {\($0.token)}: \($0.meaning)" }.joined(separator: "\n")
    }

    // MARK: Prompt

    static func valueFormat(_ kind: ConditionKind) -> String {
        switch kind.baseValueKind {
        case .text, .regex: return "text"
        case .size: return "a size like \"10 MB\" (units: bytes, KB, MB, GB)"
        case .absoluteDate:
            return "\"YYYY-MM-DD\" with before/after; a duration like \"30 days\" with older_than/within_last (minutes, hours, days, weeks, months, years)"
        case .relativeDate: return "a duration like \"30 days\""
        case .fileKind: return "one of " + FileKindCatalog.all.map(\.value).joined(separator: ", ")
        case .colorLabel: return "one of gray, green, purple, blue, yellow, red, orange"
        case .number: return "a whole number"
        case .spotlightMetadata: return "the Spotlight key and the value joined by the U+001F character, e.g. \"kMDItemAuthors\\u001fAna\""
        case .appPicker: return "the app's name, e.g. \"Safari\""
        case .duplicateScope: return DuplicateScope.allCases.map(\.rawValue).joined(separator: " or ")
        case .timeOfDay: return "a 24-hour time like \"08:30\""
        case .weekday: return "one of " + WeekdayValue.allCases.map(\.rawValue).joined(separator: ", ")
        case .shortDuration: return "a duration like \"10 minutes\" (minutes, hours, days)"
        case .powerSource: return "one of " + PowerSourceValue.allCases.map(\.rawValue).joined(separator: ", ")
        }
    }

    static var conditionCatalog: String {
        RuleSchema.conditionKinds.map { kind in
            var line = "- \(kind.rawValue) (\(kind.label)): operators \(kind.validOperators.map(\.rawValue).joined(separator: ", ")); value: \(valueFormat(kind))"
            if let help = kind.helpText { line += ". \(help)" }
            return line
        }.joined(separator: "\n")
    }

    static func actionParamsHelp(_ kind: ActionKind) -> String {
        let conflict = "on_conflict: " + MoveConflictResolution.allCases.map(\.rawValue).joined(separator: "|") + " (default rename)"
        switch kind {
        case .moveToFolder, .copyToFolder:
            return "destination: absolute folder path, tokens allowed; \(conflict)"
        case .sortIntoSubfolder:
            return "subfolder: path relative to the file's current folder (the watched folder when recursionDepth is 0), tokens allowed, e.g. \"{year}/{month}\" or a fixed name like \"Today\"; \(conflict)"
        case .syncToFolder:
            return "destination: absolute folder path; \(conflict)"
        case .syncFolders:
            return "destination: absolute folder path; sync_direction: " + SyncDirection.allCases.map(\.rawValue).joined(separator: "|")
                + "; sync_delete_policy: " + SyncDeletePolicy.allCases.map(\.rawValue).joined(separator: "|")
        case .rename:
            return "pattern: new name with tokens, extension included, e.g. \"{current_date} {name}.{extension}\"; clean_file_name: bool"
        case .upload: return "upload_url: ftp, ftps, sftp, http or https URL"
        case .addTag, .removeTag: return "tags: array of tag names"
        case .setColorLabel: return "color: gray|green|purple|blue|yellow|red|orange, or \"\" to clear"
        case .addComment: return "comment: text"
        case .runScript:
            return "script: the script; or script_source: \"file\" with script_path; shell: " + ScriptShell.allCases.map(\.rawValue).joined(separator: "|")
                + ". Variables: $FOREL_FILE, $FOREL_NAME, $FOREL_STEM, $FOREL_EXTENSION, $FOREL_DIR, $FOREL_FOLDER, $FOREL_RULE, $FOREL_CAPTURE_<NAME>"
        case .runAppleScript, .runJavaScript:
            return "script: the script (FOREL_FILE holds the file's path); or script_source: \"file\" with script_path"
        case .runShortcut:
            return "shortcut_name: name of a Shortcuts shortcut; shortcut_input_mode: " + ShortcutInputMode.allCases.map(\.rawValue).joined(separator: "|")
        case .openApplication: return "application_path: path of the .app; pass_file_to_application: bool (default true)"
        case .makeAlias: return "alias_destination: absolute folder path"
        case .importToLibrary:
            return "library_type: " + LibraryType.allCases.map(\.rawValue).joined(separator: "|") + "; target_playlist: optional playlist name (Music)"
        case .pause: return "pause_seconds: number"
        case .displayNotification: return "notification_title, notification_body: text, tokens allowed"
        case .convertImage:
            return "image_format: " + ImageFormat.allCases.map(\.rawValue).joined(separator: "|") + "; max_dimension: pixels as text or \"\"; keep_original: bool"
        case .runAutomatorWorkflow: return "workflow_path: path of the .workflow"
        case .uncompress: return conflict
        case .runRulesOnFolderContents: return "no params; runs this folder's rules on the contents of a matched subfolder"
        case .ignore: return "no params; stops later rules from acting on the file"
        case .delete: return "no params; deletes permanently, cannot be undone"
        case .compressPDF, .makeSearchablePDF: return "keep_original: bool (default true)"
        case .moveToTrash, .toggleExtension, .toggleLock, .archive, .open, .showInFinder:
            return "no params"
        }
    }

    static var actionCatalog: String {
        RuleSchema.actionKinds.map { "- \($0.rawValue) (\($0.label)): \(actionParamsHelp($0))" }.joined(separator: "\n")
    }

    /// The language the user's Mac is set to, in English ("Portuguese"),
    /// so the advice comes back in it.
    public static func preferredLanguageName(_ preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        guard let identifier = preferredLanguages.first else { return "English" }
        let code = Locale(identifier: identifier).language.languageCode?.identifier ?? identifier
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? "English"
    }

    /// What every request explains about Forel, so the model reasons about
    /// the rule with Forel's real semantics and only proposes what exists.
    static func forelGuide(macOSVersion: String) -> String {
        """
        Forel is a macOS app (similar to Hazel) on macOS \(macOSVersion) that runs file-automation rules. \
        A rule watches one folder. For each file in scope Forel checks the conditions and, when they match, runs \
        the actions from top to bottom on that file. The same rule runs automatically when files change, from Run Now, \
        and in Dry Run (a preview that runs no scripts).

        How rules work:
        - recursionDepth: 0 = only the watched folder itself, N = N levels of subfolders, null = every subfolder. Subfolders themselves are items too.
        - conditionGroups: conditions inside a group combine by the group's match ("all" or "any"); groups combine by the rule's conditionMatch ("all", "any" or "none"). No conditions matches every file in scope.
        - Text comparisons are case-sensitive, except extension (without the dot) and tags. The name condition compares the name without its extension ("is" also accepts the full name). matches_regex uses ICU regular expressions (add (?i) to ignore case); named groups like (?<year>\\d{4}) become {year} tokens in the actions and $FOREL_CAPTURE_YEAR in scripts.
        - Tokens work only in these params: destination (move_to_folder, copy_to_folder), subfolder, rename pattern, comment, \
        notification_title and notification_body. These are the only tokens; any other {word} is not replaced and ends up \
        literally in the name (a folder called "{date}"), so never invent one:
        \(tokenCatalog)
        - {content:REGEX}: first match of REGEX in the file's text (group 1 if any; suffix |title, |upper, |lower or |padN).
        - {ai:QUESTION}: a value Apple's on-device model reads from the file's text, e.g. {ai:the invoice number}.
        - {NAME}: the named group NAME of a matches_regex condition of this rule.
        - Date tokens use the moment the rule runs, not the file's date: use {date_modified}/{date_created} or a named regex group for that. \
        A folder that should always have the same name (e.g. "Today") is written as that plain name, without tokens.
        - within_last "1 day" means the last 24 hours, not "since midnight". A rule only acts on files that match it, \
        so it can't empty a folder by itself: emptying a "Today" folder of older files needs a second rule that watches that folder.
        - When a file is moved, renamed or copied, the following actions work on the new file. Forel re-checks files it changed, so a rule whose actions leave the file still matching its conditions can act on it again; an "ignore" action or a condition the result no longer meets prevents loops.
        - Rules of a folder run in order; an earlier rule that moves a file away means later rules don't see it.
        - Prefer built-in actions to scripts: they can be undone, show in Dry Run, and are faster. Cheap conditions (name, extension, kind, size, dates) are checked before slow ones (contents, AI, duplicate), but avoiding slow conditions when a cheap one is enough still helps.

        Conditions (kind (label): operators; value):
        \(conditionCatalog)

        Actions (kind (label): params). These are the only params; Forel rejects any other name and values of the wrong type:
        \(actionCatalog)
        """
    }

    /// Step 1: analyze the rule on its own and list concrete improvements.
    public static func reviewSystemPrompt(language: String, macOSVersion: String) -> String {
        """
        You review file-automation rules for Forel. \(forelGuide(macOSVersion: macOSVersion))

        Your job: when the user says what the rule should achieve, judge the rule against that goal; otherwise work out \
        what it is meant to achieve from its name, its folder, its conditions and its actions. Then check it. Look for:
        1. Mistakes: conditions that can never match or match more than intended, wrong order of actions, loops, invalid values.
        2. Safety: permanent deletions, overwriting files, scripts that could lose data.
        3. Efficiency: slow conditions where a cheap one is enough, scripts that a built-in action replaces, redundant steps.
        4. Simplification: the same result with fewer or clearer conditions and actions.
        5. Alternatives: an entirely different and better way to reach the same result with what Forel offers.
        6. Conflicts with the folder's other rules (overlaps, a rule that takes the files first).
        Every suggestion must be a concrete change to this rule that Forel can make with the conditions, actions, params \
        and tokens listed above, specific enough to be applied without asking anything (name the condition, action, value \
        or param). Don't invent features, tokens or params. When the goal names something a condition checks directly \
        (the app or website a file was downloaded with, a kind, a tag), suggest that condition. If the goal needs another \
        rule as well (for example one in a different folder), describe that rule in a suggestion of category "alternative": \
        you can only change this one. If the rule is already good, say so and return few or no suggestions.

        Reply with one JSON object only, no Markdown:
        {"summary": "one or two sentences: what the rule does and how good it is",
         "suggestions": [{"category": "problem|safety|efficiency|simplification|alternative|other", "title": "short title", "detail": "the exact change and why it is better"}]}
        Order suggestions from most to least important; at most 8. Write the summary, titles and details in \(language). \
        Keep kinds, operators and param names in English as listed.
        """
    }

    /// Step 2: rewrite the rule with the suggestions the user accepted.
    public static func editSystemPrompt(language: String, macOSVersion: String) -> String {
        """
        You edit file-automation rules for Forel. \(forelGuide(macOSVersion: macOSVersion))

        Your job: rewrite the rule the user sends so it applies every accepted suggestion, and change nothing else. \
        Keep paths, tag names, names, scripts and the order of untouched actions exactly as they are unless a \
        suggestion changes them. Use only the conditions, operators, actions, params and tokens listed above, with values \
        in the formats listed; Forel rejects a rule with anything else. If two suggestions conflict, follow the first one. \
        A suggestion about another rule can't be applied here: leave it out and say so in the explanation.

        Reply with one JSON object only, no Markdown:
        {"rule": {"conditionMatch": "...", "recursionDepth": ..., "conditionGroups": [...], "actions": [...]},
         "explanation": "what you changed, in a few short sentences"}
        "rule" uses exactly the format of the rule you received. Write the explanation in \(language).
        """
    }

    static func encodedJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// The user's own words on what the rule should achieve, when given.
    static func goalLine(_ goal: String) -> String? {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : "What this rule should achieve, in my words: \(trimmed)"
    }

    public static func reviewUserMessage(rule: Rule, folderPath: String?, otherRules: [Rule], goal: String = "") throws -> String {
        var parts: [String] = []
        if let folderPath, !folderPath.isEmpty { parts.append("Watched folder: \(folderPath)") }
        if let goal = goalLine(goal) { parts.append(goal) }
        parts.append("Rule to review:\n" + (try encodedJSON(RuleBlueprint(rule))))
        let siblings = otherRules.filter { $0.id != rule.id }.prefix(maximumSiblingRules)
        if !siblings.isEmpty {
            parts.append("Other rules of this folder, in the order they run (for context only):\n" + (try encodedJSON(siblings.map(RuleBlueprint.init))))
        }
        return parts.joined(separator: "\n\n")
    }

    public static func editUserMessage(rule: Rule, folderPath: String?, suggestions: [RuleReviewSuggestion], goal: String = "") throws -> String {
        var parts: [String] = []
        if let folderPath, !folderPath.isEmpty { parts.append("Watched folder: \(folderPath)") }
        if let goal = goalLine(goal) { parts.append(goal) }
        parts.append("Rule to edit:\n" + (try encodedJSON(RuleBlueprint(rule))))
        let accepted = suggestions.enumerated().map { index, suggestion in
            "\(index + 1). \(suggestion.title)" + (suggestion.detail.isEmpty ? "" : ": \(suggestion.detail)")
        }
        parts.append("Accepted suggestions:\n" + accepted.joined(separator: "\n"))
        return parts.joined(separator: "\n\n")
    }

    /// The rule in the compact JSON format the AI service reads and writes,
    /// for showing it to the user ("View as JSON") and copying it.
    public static func json(for rule: Rule) -> String {
        (try? encodedJSON(RuleBlueprint(rule))) ?? "{}"
    }

    // MARK: Conversation

    /// The service's first answer from the user message, then each reply,
    /// as a chat-completions message list, so the user can answer the
    /// service with new directions and the service keeps the context.
    public static func reviewConversation(
        rule: Rule,
        folderPath: String?,
        otherRules: [Rule],
        goal: String = "",
        language: String = preferredLanguageName(),
        macOSVersion: String = ProcessInfo.processInfo.operatingSystemVersionString
    ) throws -> RuleReviewConversation {
        RuleReviewConversation(mode: .review, messages: [
            .init(role: "system", content: reviewSystemPrompt(language: language, macOSVersion: macOSVersion)),
            .init(role: "user", content: try reviewUserMessage(rule: rule, folderPath: folderPath, otherRules: otherRules, goal: goal)),
        ])
    }

    public static func editConversation(
        rule: Rule,
        folderPath: String?,
        suggestions: [RuleReviewSuggestion],
        goal: String = "",
        language: String = preferredLanguageName(),
        macOSVersion: String = ProcessInfo.processInfo.operatingSystemVersionString
    ) throws -> RuleReviewConversation {
        guard !suggestions.isEmpty else { throw ScriptGenerationError("Choose at least one suggestion to apply.") }
        return RuleReviewConversation(mode: .edit, messages: [
            .init(role: "system", content: editSystemPrompt(language: language, macOSVersion: macOSVersion)),
            .init(role: "user", content: try editUserMessage(rule: rule, folderPath: folderPath, suggestions: suggestions, goal: goal)),
        ])
    }

    /// The user's answer to the service's last reply, with what the service
    /// must answer in return.
    static func feedbackMessage(_ feedback: String, mode: RuleReviewConversation.Mode) -> String {
        switch mode {
        case .review:
            return """
            My reply to your review: \(feedback)

            Take it into account and answer with the same JSON object as before (summary and the full, updated list of suggestions). \
            If I asked a question, answer it in the summary.
            """
        case .edit:
            return """
            My reply about the rule you wrote: \(feedback)

            If this asks for changes or brings an idea worth applying, change the rule accordingly; if not, keep it as it is. \
            Answer with the same JSON object as before: the complete rule and an explanation that answers me and says what you changed, if anything.
            """
        }
    }

    // MARK: Requests

    /// A `/chat/completions` request with the key and address checks shared
    /// with Generate Code.
    static func chatRequest(messages: [RuleReviewConversation.Message], settings: AISettings, apiKey: String) throws -> URLRequest {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw ScriptGenerationError("Add your \(settings.provider.label) API key in Settings → AI.")
        }
        if let problem = ScriptGenerator.planKeyProblem(settings: settings, apiKey: key) { throw problem }
        let model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw ScriptGenerationError("Choose a model in Settings → AI.") }
        guard let url = ScriptGenerator.endpoint(settings.baseURL) else {
            throw ScriptGenerationError("The service address in Settings → AI isn't a valid https:// URL.")
        }

        var request = URLRequest(url: url, timeoutInterval: 180)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        var body: [String: Any] = [
            "model": model,
            "temperature": 0.2,
            "stream": false,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
        ]
        // DeepSeek and Model Studio both support JSON mode; other services
        // may reject the field, and the prompt already asks for JSON.
        if settings.provider != .custom {
            body["response_format"] = ["type": "json_object"]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    public static func request(for conversation: RuleReviewConversation, settings: AISettings, apiKey: String) throws -> URLRequest {
        try chatRequest(messages: conversation.messages, settings: settings, apiKey: apiKey)
    }

    /// The request analyzing `rule`.
    public static func reviewRequest(
        rule: Rule,
        folderPath: String?,
        otherRules: [Rule],
        goal: String = "",
        settings: AISettings,
        apiKey: String,
        language: String = preferredLanguageName(),
        macOSVersion: String = ProcessInfo.processInfo.operatingSystemVersionString
    ) throws -> URLRequest {
        try Self.request(
            for: reviewConversation(rule: rule, folderPath: folderPath, otherRules: otherRules, goal: goal, language: language, macOSVersion: macOSVersion),
            settings: settings,
            apiKey: apiKey
        )
    }

    /// The request rewriting `rule` with the accepted `suggestions`.
    public static func editRequest(
        rule: Rule,
        folderPath: String?,
        suggestions: [RuleReviewSuggestion],
        goal: String = "",
        settings: AISettings,
        apiKey: String,
        language: String = preferredLanguageName(),
        macOSVersion: String = ProcessInfo.processInfo.operatingSystemVersionString
    ) throws -> URLRequest {
        try Self.request(
            for: editConversation(rule: rule, folderPath: folderPath, suggestions: suggestions, goal: goal, language: language, macOSVersion: macOSVersion),
            settings: settings,
            apiKey: apiKey
        )
    }

    // MARK: Answer

    /// The JSON object in `text`, tolerating Markdown fences or a sentence
    /// around it.
    static func jsonObject(in text: String) -> [String: Any]? {
        let stripped = ScriptGenerator.stripCodeFences(text)
        if let data = stripped.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        guard let start = stripped.firstIndex(of: "{"), let end = stripped.lastIndex(of: "}"), start < end,
              let data = String(stripped[start...end]).data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// The text of a chat-completions answer, or the service's own error.
    static func answerContent(_ data: Data, statusCode: Int) throws -> String {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (200..<300).contains(statusCode) else {
            throw ScriptGenerator.serviceError(statusCode: statusCode, json: json)
        }
        guard let choices = json?["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ScriptGenerationError("The service's answer was empty.")
        }
        return content
    }

    static func object(in content: String) throws -> [String: Any] {
        guard let object = jsonObject(in: content) else {
            throw ScriptGenerationError("The service's answer wasn't in the expected format. Try again, or choose another model in Settings → AI.")
        }
        return object
    }

    private static func text(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The analysis in an answer's text.
    static func review(fromContent content: String) throws -> RuleReview {
        let object = try Self.object(in: content)
        let suggestions = ((object["suggestions"] as? [[String: Any]]) ?? []).enumerated().compactMap { index, entry -> RuleReviewSuggestion? in
            let title = text(entry["title"])
            let detail = text(entry["detail"])
            guard title != nil || detail != nil else { return nil }
            let category = (text(entry["category"])?.lowercased()).flatMap(RuleReviewSuggestion.Category.init(rawValue:)) ?? .other
            return RuleReviewSuggestion(id: index, category: category, title: title ?? detail ?? "", detail: title == nil ? "" : (detail ?? ""))
        }
        let summary = text(object["summary"]) ?? ""
        guard !summary.isEmpty || !suggestions.isEmpty else {
            throw ScriptGenerationError("The service returned an empty review.")
        }
        return RuleReview(summary: summary, suggestions: suggestions)
    }

    /// The analysis in a chat-completions answer.
    public static func review(fromResponse data: Data, statusCode: Int) throws -> RuleReview {
        try review(fromContent: try answerContent(data, statusCode: statusCode))
    }

    /// The edited rule in an answer's text, checked against what Forel
    /// supports and keeping `rule`'s identity, so it can replace the
    /// editor's draft as is. `requireChange` rejects an answer that leaves
    /// `rule` as it was — right for applying suggestions, wrong for a reply
    /// that only asked a question.
    static func edit(fromContent content: String, rule: Rule, requireChange: Bool = true) throws -> RuleEdit {
        let object = try Self.object(in: content)
        guard let raw = object["rule"] ?? object["improvedRule"], !(raw is NSNull),
              let ruleData = try? JSONSerialization.data(withJSONObject: raw),
              let blueprint = try? JSONDecoder().decode(RuleBlueprint.self, from: ruleData) else {
            throw ScriptGenerationError("The service didn't return the edited rule in Forel's format. Try again.")
        }
        let result = blueprint.applied(to: rule)
        guard let candidate = result.rule else {
            throw RuleEditError(problems: result.problems)
        }
        let edited = restoreRedactedUploads(in: candidate, from: rule)
        if requireChange, RuleBlueprint(edited) == RuleBlueprint(rule) {
            throw ScriptGenerationError("The service returned the rule unchanged. Try again, or choose other suggestions.")
        }
        return RuleEdit(rule: edited, explanation: text(object["explanation"]))
    }

    /// The edited rule in a chat-completions answer.
    public static func edit(fromResponse data: Data, statusCode: Int, rule: Rule) throws -> RuleEdit {
        try edit(fromContent: try answerContent(data, statusCode: statusCode), rule: rule)
    }

    /// The service only saw upload URLs without their password; when the
    /// edited rule keeps such a URL, put the original one back.
    static func restoreRedactedUploads(in improved: Rule, from original: Rule) -> Rule {
        let originals = original.actions.compactMap { action -> (shown: String, real: String)? in
            guard action.kind == .upload, let real = action.params[ActionParam.uploadURL]?.stringValue else { return nil }
            return (UploadDestination.displayString(for: real), real)
        }
        guard !originals.isEmpty else { return improved }
        var rule = improved
        rule.actions = improved.actions.map { action in
            guard action.kind == .upload, case .object(var dict) = action.params,
                  let shown = dict[ActionParam.uploadURL]?.stringValue,
                  let match = originals.first(where: { $0.shown == shown }) else { return action }
            dict[ActionParam.uploadURL] = .string(match.real)
            var copy = action
            copy.params = .object(dict)
            return copy
        }
        return rule
    }

    // MARK: Sending

    private static func send(_ conversation: RuleReviewConversation, settings: AISettings, apiKey: String, session: URLSession) async throws -> String {
        let request = try Self.request(for: conversation, settings: settings, apiKey: apiKey)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw ScriptGenerationError("Couldn't reach \(settings.provider.label): \(error.localizedDescription)")
        }
        return try answerContent(data, statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// Analyzes `rule`. The conversation returned lets the user reply.
    public static func review(
        rule: Rule,
        folderPath: String?,
        otherRules: [Rule],
        goal: String = "",
        settings: AISettings,
        apiKey: String,
        session: URLSession = .shared
    ) async throws -> (RuleReview, RuleReviewConversation) {
        var conversation = try reviewConversation(rule: rule, folderPath: folderPath, otherRules: otherRules, goal: goal)
        let content = try await send(conversation, settings: settings, apiKey: apiKey, session: session)
        let result = try Self.review(fromContent: content)
        conversation.messages.append(.init(role: "assistant", content: content))
        return (result, conversation)
    }

    /// Rewrites `rule` with the accepted `suggestions`.
    public static func edit(
        rule: Rule,
        folderPath: String?,
        suggestions: [RuleReviewSuggestion],
        goal: String = "",
        settings: AISettings,
        apiKey: String,
        session: URLSession = .shared
    ) async throws -> (RuleEdit, RuleReviewConversation) {
        var conversation = try editConversation(rule: rule, folderPath: folderPath, suggestions: suggestions, goal: goal)
        let content = try await send(conversation, settings: settings, apiKey: apiKey, session: session)
        let result = try Self.edit(fromContent: content, rule: rule)
        conversation.messages.append(.init(role: "assistant", content: content))
        return (result, conversation)
    }

    /// The conversation with the user's `feedback` added, ready to send.
    public static func appending(_ feedback: String, to conversation: RuleReviewConversation) throws -> RuleReviewConversation {
        let trimmed = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ScriptGenerationError("Write what you'd like the AI to consider.") }
        var next = conversation
        next.messages.append(.init(role: "user", content: feedbackMessage(trimmed, mode: conversation.mode)))
        return next
    }

    /// Sends the user's answer to the service's last reply: new directions
    /// or ideas for the review, or for the rule it wrote. `rule` is the
    /// rule as it was before the service edited it, which an edited rule
    /// keeps the identity of.
    public static func reply(
        _ feedback: String,
        to conversation: RuleReviewConversation,
        rule: Rule,
        settings: AISettings,
        apiKey: String,
        session: URLSession = .shared
    ) async throws -> (RuleReviewReply, RuleReviewConversation) {
        var next = try appending(feedback, to: conversation)
        let content = try await send(next, settings: settings, apiKey: apiKey, session: session)
        let result = try parseReply(content, mode: conversation.mode, rule: rule)
        next.messages.append(.init(role: "assistant", content: content))
        return (result, next)
    }

    static func parseReply(_ content: String, mode: RuleReviewConversation.Mode, rule: Rule) throws -> RuleReviewReply {
        switch mode {
        case .review: return .review(try review(fromContent: content))
        case .edit: return .edit(try edit(fromContent: content, rule: rule, requireChange: false))
        }
    }
}

/// The messages exchanged with the service during one review, so the user
/// can answer it and it keeps the context.
public struct RuleReviewConversation: Equatable, Sendable {
    public enum Mode: Sendable, Equatable {
        /// Analyzing the rule and listing suggestions.
        case review
        /// Writing the rule with the chosen suggestions.
        case edit
    }

    public struct Message: Equatable, Sendable {
        public let role: String
        public let content: String
    }

    public let mode: Mode
    public internal(set) var messages: [Message]
}

/// What the service answered to the user's reply.
public enum RuleReviewReply: Equatable, Sendable {
    case review(RuleReview)
    case edit(RuleEdit)
}
