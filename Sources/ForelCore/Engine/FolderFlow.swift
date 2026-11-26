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

/// Where each watched folder's rules send files: to another watched folder
/// (whose rules then run on them), somewhere else, the Trash, or away for
/// good. Shown as the folder flow map; built from the rules alone, without
/// looking at any file.
public enum FolderFlow {
    public enum Destination: Hashable, Sendable {
        /// Another watched folder, whose rules take over.
        case watched(folderId: String)
        /// A folder Forel doesn't watch (literal part of the destination).
        case elsewhere(path: String)
        case trash
        /// Deleted or uploaded: the file leaves the Mac or stops existing.
        case removed
    }

    public struct Step: Hashable, Sendable, Identifiable {
        public var ruleId: String
        public var ruleName: String
        public var ruleEnabled: Bool
        public var action: ActionKind
        public var destination: Destination
        /// Part of a loop of watched folders (A → B → A).
        public var inLoop: Bool

        public var id: String { "\(ruleId)|\(action.rawValue)|\(destination)" }
    }

    public struct Node: Sendable, Identifiable {
        public var folder: WatchedFolder
        public var outgoing: [Step]
        /// Folders whose rules send files here.
        public var incomingFrom: [String]
        public var id: String { folder.id }
    }

    public static func map(folders: [WatchedFolder], rulesByFolder: [String: [Rule]]) -> [Node] {
        var outgoing: [String: [Step]] = [:]
        for folder in folders {
            for rule in rulesByFolder[folder.id] ?? [] {
                for action in rule.actions.sorted(by: { $0.position < $1.position }) {
                    guard let destination = destination(of: action, from: folder, folders: folders) else { continue }
                    let step = Step(ruleId: rule.id, ruleName: rule.name, ruleEnabled: rule.enabled, action: action.kind, destination: destination, inLoop: false)
                    if !(outgoing[folder.id] ?? []).contains(where: { $0.id == step.id }) {
                        outgoing[folder.id, default: []].append(step)
                    }
                }
            }
        }

        // Loops over enabled rules only: those are the ones that can move a
        // file around and around.
        var edges: [String: Set<String>] = [:]
        for (from, steps) in outgoing {
            for step in steps where step.ruleEnabled {
                if case .watched(let to) = step.destination { edges[from, default: []].insert(to) }
            }
        }
        func reaches(_ start: String, _ goal: String) -> Bool {
            var seen: Set<String> = [start]
            var queue = [start]
            while let node = queue.popLast() {
                for next in edges[node] ?? [] {
                    if next == goal { return true }
                    if seen.insert(next).inserted { queue.append(next) }
                }
            }
            return false
        }
        for (from, steps) in outgoing {
            outgoing[from] = steps.map { step in
                var step = step
                if step.ruleEnabled, case .watched(let to) = step.destination { step.inLoop = reaches(to, from) }
                return step
            }
        }

        return folders.map { folder in
            let incoming = folders.filter { other in
                (outgoing[other.id] ?? []).contains { $0.destination == .watched(folderId: folder.id) }
            }.map(\.id)
            return Node(folder: folder, outgoing: outgoing[folder.id] ?? [], incomingFrom: incoming)
        }
    }

    /// Where `action` takes a file from `folder`, or nil when the file stays
    /// in the folder (rename, tag, a subfolder its own rules look into…).
    static func destination(of action: Action, from folder: WatchedFolder, folders: [WatchedFolder]) -> Destination? {
        switch action.kind {
        case .moveToTrash:
            return .trash
        case .delete, .upload:
            return .removed
        case .moveToFolder, .copyToFolder, .syncToFolder:
            let raw = action.params[ActionParam.destination]?.stringValue ?? ""
            let path = RuleDiagnostics.literalPrefix(raw)
            guard !raw.trimmingCharacters(in: .whitespaces).isEmpty, path.hasPrefix("/") else { return nil }
            if let target = RuleDiagnostics.watchedFolder(containing: path, in: folders, excluding: folder) {
                // A destination inside this folder that isn't a nested watched
                // folder stays here.
                return .watched(folderId: target.id)
            }
            if RuleEngine.pathDepth(root: folder.path, path: path + "/x") != nil { return nil }
            return .elsewhere(path: path)
        default:
            return nil
        }
    }
}
