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

public struct WatchedFolder: Codable, Equatable, Sendable {
    public var id: String
    public var path: String
    public var enabled: Bool
    public var priority: Int64
    public var createdAt: String

    public init(id: String = UUID().uuidString, path: String, enabled: Bool = true, priority: Int64 = 0, createdAt: String = ISO8601DateFormatter.forelUTC.string(from: Date())) {
        self.id = id
        self.path = path
        self.enabled = enabled
        self.priority = priority
        self.createdAt = createdAt
    }
}

/// Last known identity/fingerprint the watcher fully evaluated a path at.
/// See `Database`'s "Watched path state" section for who's allowed to write
/// this and why.
public struct WatchedPathState: Codable, Equatable, Sendable {
    public var path: String
    public var volumeId: Int64?
    public var fileId: Int64?
    public var fingerprint: String?
    public var updatedAt: String

    public init(
        path: String,
        volumeId: Int64? = nil,
        fileId: Int64? = nil,
        fingerprint: String? = nil,
        updatedAt: String = ISO8601DateFormatter.forelUTC.string(from: Date())
    ) {
        self.path = path
        self.volumeId = volumeId
        self.fileId = fileId
        self.fingerprint = fingerprint
        self.updatedAt = updatedAt
    }
}

public enum ConditionMatch: String, Codable, Equatable, Sendable {
    case all
    case any
    case none

    /// How this mode combines when applied to a single group of conditions,
    /// used when migrating a flat condition list into one group. `.none` is
    /// rule-level only ("none of the groups"), so a migrated group keeps
    /// `.any` and the rule keeps the negation.
    var groupDefault: ConditionMatch {
        self == .none ? .any : self
    }
}

/// A set of conditions combined by the group's own `match` mode
/// ("all"/"any"). Groups combine with the rule's `conditionMatch`.
/// A rule with a single group behaves exactly like the flat list that
/// existed before groups.
public struct ConditionGroup: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var match: ConditionMatch
    public var conditions: [Condition]

    public init(id: String = UUID().uuidString, match: ConditionMatch, conditions: [Condition] = []) {
        self.id = id
        self.match = match
        self.conditions = conditions
    }
}

public enum ConditionKind: String, Codable, Equatable, Sendable {
    case name
    case extension_ = "extension"
    case kind
    case sizeBytes = "size_bytes"
    case tags
    case colorLabel = "color_label"
    case contents
    case createdAt = "created_at"
    case dateModified = "date_modified"
    case dateAdded = "date_added"
    case finderComment = "finder_comment"
    case filePath = "file_path"
    case itemCount = "item_count"
    case lastOpened = "last_opened"
    case imageWidth = "image_width"
    case imageHeight = "image_height"
    case photoDateTaken = "photo_date_taken"
    case pdfPageCount = "pdf_page_count"
    case spotlightMetadata = "spotlight_metadata"
    case downloadedFromWebsite = "downloaded_from_website"
    case downloadedWithApp = "downloaded_with_app"
    case rawWhereFromMetadata = "raw_where_from_metadata"

    public init(dbValue: String) {
        self = ConditionKind(rawValue: dbValue) ?? .name
    }
}

public enum Operator: String, Codable, Equatable, Sendable {
    case `is`
    case isNot = "is_not"
    case contains
    case doesNotContain = "does_not_contain"
    case startsWith = "starts_with"
    case endsWith = "ends_with"
    case matchesRegex = "matches_regex"
    case greaterThan = "greater_than"
    case lessThan = "less_than"
    case before
    case after
    case olderThan = "older_than"
    case withinLast = "within_last"

    public init(dbValue: String) {
        self = Operator(rawValue: dbValue) ?? .is
    }
}

public struct Condition: Codable, Equatable, Sendable {
    public var id: String
    public var ruleId: String
    public var kind: ConditionKind
    public var `operator`: Operator
    public var value: String

    public init(id: String = UUID().uuidString, ruleId: String, kind: ConditionKind, operator: Operator, value: String) {
        self.id = id
        self.ruleId = ruleId
        self.kind = kind
        self.operator = `operator`
        self.value = value
    }
}

public enum ActionKind: String, Codable, Equatable, Sendable {
    case moveToFolder = "move_to_folder"
    case copyToFolder = "copy_to_folder"
    case syncFolders = "sync_folders"
    case rename
    case sortIntoSubfolder = "sort_into_subfolder"
    case syncToFolder = "sync_to_folder"
    case upload
    case moveToTrash = "move_to_trash"
    case delete
    case addTag = "add_tag"
    case removeTag = "remove_tag"
    case setColorLabel = "set_color_label"
    case addComment = "add_comment"
    case toggleExtension = "toggle_extension"
    case toggleLock = "toggle_lock"
    case archive
    case runScript = "run_script"
    case runShortcut = "run_shortcut"
    case runAppleScript = "run_applescript"
    case runJavaScript = "run_javascript"
    case runAutomatorWorkflow = "run_automator_workflow"
    case openApplication = "open_application"
    case open
    case showInFinder = "show_in_finder"
    case makeAlias = "make_alias"
    case importToLibrary = "import_to_library"
    case uncompress
    case runRulesOnFolderContents = "run_rules_on_folder_contents"
    case ignore
    case pause
    case displayNotification = "display_notification"
    public init(dbValue: String) {
        self = ActionKind(rawValue: dbValue) ?? .moveToFolder
    }
}

public enum LibraryType: String, CaseIterable, Codable, Equatable, Sendable {
    case music
    case photos
    case tv

    public var label: String {
        switch self {
        case .music: return "Music"
        case .photos: return "Photos"
        case .tv: return "TV"
        }
    }

    public var iconSystemName: String {
        switch self {
        case .music: return "music.note"
        case .photos: return "photo.on.rectangle"
        case .tv: return "tv"
        }
    }
}

/// JSON-encoded parameters specific to each action kind, e.g.
/// `moveToFolder`: {"destination": "/path"}; `rename`: {"pattern": "{name}"}; `addTag`: {"tag": "x"}.
public struct Action: Codable, Equatable, Sendable {
    public var id: String
    public var ruleId: String
    public var kind: ActionKind
    public var params: JSONValue
    public var position: Int64

    public init(id: String = UUID().uuidString, ruleId: String, kind: ActionKind, params: JSONValue, position: Int64) {
        self.id = id
        self.ruleId = ruleId
        self.kind = kind
        self.params = params
        self.position = position
    }
}

public struct Rule: Codable, Equatable, Sendable {
    public var id: String
    public var folderId: String
    public var name: String
    public var enabled: Bool
    /// How the condition groups combine. A rule with a single group keeps
    /// its classic meaning: the group already carries the mode the user
    /// picked, and combining one group with any non-`.none` mode is a no-op.
    public var conditionMatch: ConditionMatch
    /// nil = all subfolders (unlimited), 0 = current folder only, N = N levels deep.
    public var recursionDepth: Int64?
    /// Source of truth for conditions. Order matters: groups are combined
    /// left to right by `conditionMatch`, conditions inside a group by the
    /// group's own `match`.
    public var conditionGroups: [ConditionGroup]
    public var actions: [Action]
    public var priority: Int64
    public var createdAt: String

    /// Flat projection of every condition, in group order. Setting it
    /// collapses the rule back to a single group — the legacy shape.
    public var conditions: [Condition] {
        get { conditionGroups.flatMap(\.conditions) }
        set {
            let match = conditionGroups.count == 1 ? conditionGroups[0].match : conditionMatch.groupDefault
            conditionGroups = [ConditionGroup(match: match, conditions: newValue)]
        }
    }

    public init(
        id: String = UUID().uuidString,
        folderId: String,
        name: String,
        enabled: Bool = false,
        conditionMatch: ConditionMatch = .all,
        recursionDepth: Int64? = 0,
        conditions: [Condition] = [],
        conditionGroups: [ConditionGroup]? = nil,
        actions: [Action] = [],
        priority: Int64 = 0,
        createdAt: String = ISO8601DateFormatter.forelUTC.string(from: Date())
    ) {
        self.id = id
        self.folderId = folderId
        self.name = name
        self.enabled = enabled
        self.conditionMatch = conditionMatch
        self.recursionDepth = recursionDepth
        self.conditionGroups = conditionGroups ?? [ConditionGroup(match: conditionMatch.groupDefault, conditions: conditions)]
        self.actions = actions
        self.priority = priority
        self.createdAt = createdAt
    }
}

public enum HistoryStatus: String, Codable, Equatable, Sendable {
    case applied
    case undone
    case failed
    case skipped
    case needsConfirmation = "needs_confirmation"
}

/// A single executed action, recorded so it can be reviewed (log) and reversed
/// (undo). Entries from one rule run share a `batchId`.
public struct HistoryEntry: Codable, Equatable, Sendable {
    public var id: String
    public var batchId: String
    public var ruleId: String?
    public var ruleName: String
    public var actionKind: ActionKind
    public var originalPath: String
    public var resultPath: String
    /// Serialised `Undo`.
    public var undo: JSONValue
    public var reversible: Bool
    public var status: HistoryStatus
    public var message: String?
    public var createdAt: String
    /// Identity of the file right after this action ran — `nil` for entries
    /// written before this snapshot existed. Lets undo tell a safe rollback
    /// (still the same file) from a dangerous one (something else is there
    /// now).
    public var resultVolumeId: Int64?
    public var resultFileId: Int64?

    public init(
        id: String = UUID().uuidString,
        batchId: String,
        ruleId: String?,
        ruleName: String,
        actionKind: ActionKind,
        originalPath: String,
        resultPath: String,
        undo: JSONValue,
        reversible: Bool,
        status: HistoryStatus = .applied,
        message: String? = nil,
        createdAt: String = ISO8601DateFormatter.forelUTC.string(from: Date()),
        resultVolumeId: Int64? = nil,
        resultFileId: Int64? = nil
    ) {
        self.id = id
        self.batchId = batchId
        self.ruleId = ruleId
        self.ruleName = ruleName
        self.actionKind = actionKind
        self.originalPath = originalPath
        self.resultPath = resultPath
        self.undo = undo
        self.resultVolumeId = resultVolumeId
        self.resultFileId = resultFileId
        self.reversible = reversible
        self.status = status
        self.message = message
        self.createdAt = createdAt
    }
}

/// Success ("applied"/"undone") vs. failed run counts for one rule over a
/// time window, used by the rule list and the menu-bar quick panel.
public struct RuleRunStats: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var ruleName: String
    public var successCount: Int
    public var failedCount: Int

    public init(id: String, ruleName: String, successCount: Int, failedCount: Int) {
        self.id = id
        self.ruleName = ruleName
        self.successCount = successCount
        self.failedCount = failedCount
    }
}
