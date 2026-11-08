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


import SwiftUI
import AppKit
import ForelCore

/// ⌘K: finds any rule in any watched folder by its name, conditions or
/// actions, and offers to start a new rule named after what was typed.
/// Arrow keys move, Return opens, Escape closes — like Spotlight.
struct RulePaletteView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var highlighted = 0
    @State private var library: [(folder: WatchedFolder, rule: Rule)] = []
    @State private var keyMonitor: Any?
    @FocusState private var isFieldFocused: Bool

    private enum Item: Identifiable {
        case rule(WatchedFolder, Rule, RuleSearch.Match)
        case newRule(WatchedFolder)

        var id: String {
            switch self {
            case .rule(_, let rule, _): return "rule-\(rule.id)"
            case .newRule(let folder): return "new-\(folder.id)"
            }
        }
    }

    private static let resultLimit = 50

    private var ruleItems: [Item] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return library.lazy.compactMap { entry -> Item? in
            RuleSearch.match(entry.rule, query: trimmed).map { .rule(entry.folder, entry.rule, $0) }
        }
        .prefix(Self.resultLimit)
        .map { $0 }
    }

    /// The selected folder first, so Return on an empty result list creates
    /// the rule where the user is working.
    private var newRuleItems: [Item] {
        let folders = model.folders.sorted { lhs, _ in lhs.id == model.selectedFolderId }
        let shown = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Array(folders.prefix(1)) : folders
        return shown.map { .newRule($0) }
    }

    private var items: [Item] { ruleItems + newRuleItems }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(ForelTheme.secondaryText)
                TextField("Search rules, conditions and actions", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($isFieldFocused)
                    .onSubmit(openHighlighted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider().overlay(ForelTheme.divider)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let rules = ruleItems
                        if !rules.isEmpty {
                            sectionHeader("Rules")
                            ForEach(Array(rules.enumerated()), id: \.element.id) { index, item in
                                row(item, index: index)
                            }
                        } else if !library.isEmpty {
                            Text("No rule matches “\(query)”.")
                                .font(.system(size: 12))
                                .foregroundStyle(ForelTheme.secondaryText)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                        }

                        let newRules = newRuleItems
                        if !newRules.isEmpty {
                            sectionHeader("New Rule")
                            ForEach(Array(newRules.enumerated()), id: \.element.id) { offset, item in
                                row(item, index: rules.count + offset)
                            }
                        } else if model.folders.isEmpty {
                            Text("Add a watched folder first to create rules.")
                                .font(.system(size: 12))
                                .foregroundStyle(ForelTheme.secondaryText)
                                .padding(14)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .onChange(of: highlighted) { index in
                    let all = items
                    guard all.indices.contains(index) else { return }
                    proxy.scrollTo(all[index].id)
                }
            }

            Divider().overlay(ForelTheme.divider)

            HStack(spacing: 14) {
                keyHint("arrow.up.arrow.down", "move")
                keyHint("return", "open")
                keyHint("escape", "close")
                Spacer()
                let count = ruleItems.count
                Text("\(count == Self.resultLimit ? "\(count)+" : "\(count)") rule\(count == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundStyle(ForelTheme.secondaryText)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(width: 580, height: 420)
        .background(ForelTheme.background)
        .onAppear {
            library = model.allRules()
            isFieldFocused = true
            installKeyMonitor()
        }
        .onDisappear(perform: removeKeyMonitor)
        .onChange(of: query) { _ in highlighted = 0 }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(ForelTheme.secondaryText)
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    private func row(_ item: Item, index: Int) -> some View {
        let isHighlighted = index == highlighted
        return HStack(spacing: 8) {
            switch item {
            case .rule(let folder, let rule, let match):
                Circle()
                    .fill(rule.enabled ? ForelTheme.success : ForelTheme.secondaryText.opacity(0.5))
                    .frame(width: 7, height: 7)
                    .help(rule.enabled ? "Enabled" : "Disabled")
                Text(rule.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ForelTheme.primaryText)
                    .lineLimit(1)
                if match.field != .name {
                    Text("\(match.field == .condition ? "If" : "Then") \(match.text)")
                        .font(.system(size: 11))
                        .foregroundStyle(ForelTheme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text(folderName(folder))
                    .font(.system(size: 11))
                    .foregroundStyle(ForelTheme.secondaryText)
                    .lineLimit(1)
            case .newRule(let folder):
                Image(systemName: "plus.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(ForelTheme.accent)
                Text(newRuleTitle)
                    .font(.system(size: 13))
                    .foregroundStyle(ForelTheme.primaryText)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(ForelTheme.secondaryText)
                Text(folderName(folder))
                    .font(.system(size: 13))
                    .foregroundStyle(ForelTheme.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 8)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(isHighlighted ? ForelTheme.accent.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
        .onHover { if $0 { highlighted = index } }
        .onTapGesture { open(item) }
        .id(item.id)
    }

    private var newRuleTitle: String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "New rule" : "New rule “\(trimmed)”"
    }

    private func keyHint(_ symbol: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(ForelTheme.surface))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(ForelTheme.surfaceBorder))
            Text(label)
        }
        .font(.system(size: 11))
        .foregroundStyle(ForelTheme.secondaryText)
    }

    private func folderName(_ folder: WatchedFolder) -> String {
        (folder.path as NSString).lastPathComponent
    }

    private func openHighlighted() {
        let all = items
        guard all.indices.contains(highlighted) else { return }
        open(all[highlighted])
    }

    private func open(_ item: Item) {
        switch item {
        case .rule(let folder, let rule, _):
            model.reveal(ruleId: rule.id, inFolder: folder.id)
        case .newRule(let folder):
            model.startNewRule(named: query, inFolder: folder.id)
        }
        dismiss()
    }

    /// The text field keeps ↑/↓ for itself; a local monitor moves the
    /// highlight instead, and Escape closes the palette.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 125: // down
                highlighted = min(highlighted + 1, max(items.count - 1, 0))
                return nil
            case 126: // up
                highlighted = max(highlighted - 1, 0)
                return nil
            case 53: // escape
                dismiss()
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}
