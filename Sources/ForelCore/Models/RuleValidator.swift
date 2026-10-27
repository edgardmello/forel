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

/// Validates rule-level constraints so callers can surface issues before
/// persisting a rule that would silently produce wrong results at run time.
public enum RuleValidator {
    public struct Issue: Equatable {
        public let message: String
        public init(message: String) { self.message = message }
    }

    /// Group-level checks: once a rule has more than one group, an empty
    /// group (vacuously true) is almost certainly a leftover from deleting
    /// its conditions, not an intent — flag it instead of silently changing
    /// how the rule combines.
    public static func validate(groups: [ConditionGroup]) -> [Issue] {
        guard groups.count > 1 else { return [] }
        return groups.contains { $0.conditions.isEmpty }
            ? [Issue(message: "Every condition group needs at least one condition")]
            : []
    }

    public static func validate(_ conditions: [Condition]) -> [Issue] {
        conditions.compactMap { condition in
            if condition.kind == .spotlightMetadata {
                guard let metadata = SpotlightMetadataCondition.parse(condition.value),
                      !metadata.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !metadata.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return Issue(message: "Spotlight metadata needs both a key and a value")
                }
                return nil
            }
            if condition.value.trimmingCharacters(in: .whitespaces).isEmpty {
                return Issue(message: "Condition value cannot be empty")
            }
            if condition.operator == .matchesRegex,
               (try? NSRegularExpression(pattern: condition.value)) == nil {
                return Issue(message: "Regex pattern is invalid")
            }
            return nil
        }
    }

    public static func validate(_ actions: [Action]) -> [Issue] {
        actions.compactMap { action in
            switch action.kind {
            case .moveToFolder, .copyToFolder, .syncToFolder:
                if action.params[ActionParam.destination]?.stringValue?.trimmingCharacters(in: .whitespaces).isEmpty != false {
                    return Issue(message: "Destination path cannot be empty")
                }
            case .sortIntoSubfolder:
                let subfolder = action.params[ActionParam.subfolder]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if subfolder.isEmpty || (subfolder as NSString).isAbsolutePath || subfolder.split(separator: "/").contains("..") {
                    return Issue(message: "Subfolder must be a relative path")
                }
            case .rename:
                if action.params[ActionParam.pattern]?.stringValue?.trimmingCharacters(in: .whitespaces).isEmpty != false {
                    return Issue(message: "Rename pattern cannot be empty")
                }
            case .upload:
                let value = action.params[ActionParam.uploadURL]?.stringValue ?? ""
                if UploadDestination.url(from: value) == nil {
                    return Issue(message: "Upload URL must use FTP, FTPS, SFTP, HTTP, or HTTPS and include a host")
                }
            case .addTag, .removeTag:
                if tags(in: action).isEmpty {
                    return Issue(message: "At least one tag is required")
                }
            case .openApplication:
                if action.params[ActionParam.applicationPath]?.stringValue?.trimmingCharacters(in: .whitespaces).isEmpty != false {
                    return Issue(message: "Application cannot be empty")
                }
            case .addComment:
                if action.params[ActionParam.comment]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                    return Issue(message: "Comment cannot be empty")
                }
            case .makeAlias:
                if action.params[ActionParam.aliasDestination]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                    return Issue(message: "Alias destination cannot be empty")
                }
            case .pause:
                guard case .number(let seconds) = action.params[ActionParam.pauseSeconds],
                      seconds.isFinite, seconds >= 0 else {
                    return Issue(message: "Pause duration must be a non-negative number of seconds")
                }
            case .runAppleScript, .runJavaScript, .runScript:
                if ScriptSource.of(action) == .file {
                    if action.params[ActionParam.scriptPath]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                        return Issue(message: "Choose a script file")
                    }
                } else if action.params[ActionParam.script]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                    return Issue(message: "Script cannot be empty")
                }
            case .convertImage:
                let raw = action.params[ActionParam.maxDimension]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !raw.isEmpty, (Int(raw) ?? 0) <= 0 {
                    return Issue(message: "Maximum size must be a whole number of pixels, or empty to keep the size")
                }
            case .runAutomatorWorkflow:
                if action.params[ActionParam.workflowPath]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                    return Issue(message: "Automator workflow cannot be empty")
                }
            default:
                break
            }
            return nil
        }
    }

    private static func tags(in action: Action) -> [String] {
        if let tags = action.params[ActionParam.tags]?.arrayValue {
            return tags.compactMap(\.stringValue)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        if let tag = action.params["tag"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !tag.isEmpty {
            return [tag]
        }
        return []
    }
}
