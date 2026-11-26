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

/// Ready-made starting points offered when a folder has no rules yet. A
/// template only fills in the editor: the rule is saved (and turned on)
/// only when the user does so, and none of them deletes anything for good.
public enum RuleTemplate: String, CaseIterable, Sendable, Identifiable {
    case pdfsToDocuments
    case imagesByMonth
    case screenshots
    case unzipArchives
    case oldInstallersToTrash
    case tagOldFiles

    public var id: String { rawValue }

    /// English UI text; the app translates it.
    public var title: String {
        switch self {
        case .pdfsToDocuments: return "Move PDFs to Documents"
        case .imagesByMonth: return "Sort images into monthly folders"
        case .screenshots: return "Collect screenshots in Pictures"
        case .unzipArchives: return "Unzip ZIP archives"
        case .oldInstallersToTrash: return "Move installers older than a week to the Trash"
        case .tagOldFiles: return "Tag files added more than 30 days ago"
        }
    }

    public var systemImage: String {
        switch self {
        case .pdfsToDocuments: return "doc.richtext"
        case .imagesByMonth: return "photo.on.rectangle"
        case .screenshots: return "camera.viewfinder"
        case .unzipArchives: return "doc.zipper"
        case .oldInstallersToTrash: return "shippingbox"
        case .tagOldFiles: return "tag"
        }
    }

    /// The rule for `folderId`, with destinations under `home`.
    public func rule(folderId: String, home: String = NSHomeDirectory()) -> Rule {
        let id = UUID().uuidString
        func condition(_ kind: ConditionKind, _ op: Operator, _ value: String) -> Condition {
            Condition(ruleId: id, kind: kind, operator: op, value: value)
        }
        func action(_ kind: ActionKind, _ params: [String: JSONValue] = [:], position: Int64 = 0) -> Action {
            Action(ruleId: id, kind: kind, params: .object(params), position: position)
        }
        func inHome(_ path: String) -> String {
            (home as NSString).appendingPathComponent(path)
        }

        switch self {
        case .pdfsToDocuments:
            return Rule(id: id, folderId: folderId, name: title,
                        conditions: [condition(.kind, .is, "pdf")],
                        actions: [action(.moveToFolder, [ActionParam.destination: .string(inHome("Documents/PDFs"))])])
        case .imagesByMonth:
            return Rule(id: id, folderId: folderId, name: title,
                        conditions: [condition(.kind, .is, "image")],
                        actions: [action(.sortIntoSubfolder, [ActionParam.subfolder: .string("Images/{year}-{month}")])])
        case .screenshots:
            return Rule(id: id, folderId: folderId, name: title, conditionMatch: .any,
                        conditions: [
                            condition(.name, .startsWith, "Screenshot"),
                            condition(.name, .startsWith, "Captura de Tela"),
                        ],
                        actions: [action(.moveToFolder, [ActionParam.destination: .string(inHome("Pictures/Screenshots"))])])
        case .unzipArchives:
            return Rule(id: id, folderId: folderId, name: title,
                        conditions: [condition(.extension_, .is, "zip")],
                        actions: [action(.uncompress)])
        case .oldInstallersToTrash:
            return Rule(id: id, folderId: folderId, name: title, conditionMatch: .all,
                        conditionGroups: [
                            ConditionGroup(match: .any, conditions: [
                                condition(.extension_, .is, "dmg"),
                                condition(.extension_, .is, "pkg"),
                            ]),
                            ConditionGroup(match: .all, conditions: [condition(.dateAdded, .olderThan, "7 days")]),
                        ],
                        actions: [action(.moveToTrash)])
        case .tagOldFiles:
            return Rule(id: id, folderId: folderId, name: title,
                        conditions: [condition(.dateAdded, .olderThan, "30 days")],
                        actions: [action(.addTag, [ActionParam.tags: .stringArray(["Old"])])])
        }
    }
}
