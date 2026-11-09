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
import ForelCore

/// The rules of the selected folder as a sortable-looking, scannable table
/// with an inspector on the right — the compact counterpart of the card
/// list. Selecting rows enables the bulk actions; double-click edits.
struct RuleTableView: View {
    @EnvironmentObject var model: AppModel
    let rules: [Rule]
    let orderById: [String: Int]
    let matchHints: [String: String]
    @Binding var selection: Set<String>
    @Binding var showsInspector: Bool
    let onEdit: (Rule) -> Void
    let onReview: (Rule) -> Void
    let onDelete: ([Rule]) -> Void

    private var selectedRules: [Rule] {
        rules.filter { selection.contains($0.id) }
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(spacing: 0) {
                selectionBar
                Divider().overlay(ForelTheme.divider)
                table
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(ForelTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ForelTheme.surfaceBorder))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .frame(minWidth: 380)

            if showsInspector {
                RuleInspector(rule: selectedRules.count == 1 ? selectedRules[0] : nil,
                              selectionCount: selectedRules.count,
                              onEdit: onEdit)
                    .frame(width: 300)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: showsInspector)
    }

    private var selectionBar: some View {
        HStack(spacing: 6) {
            Text(selection.isEmpty ? "\(rules.count) rule\(rules.count == 1 ? "" : "s")" : "\(selection.count) selected")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ForelTheme.secondaryText)
                .padding(.leading, 4)

            Spacer()

            Group {
                Button("Enable") { model.setRulesEnabled(selectedRules, true) }
                    .disabled(!selectedRules.contains { !$0.enabled })
                Button("Disable") { model.setRulesEnabled(selectedRules, false) }
                    .disabled(!selectedRules.contains(where: \.enabled))
                Button("Duplicate") { selectedRules.forEach { model.duplicateRule($0) } }
                    .disabled(selectedRules.isEmpty)
                Button("Delete", role: .destructive) { onDelete(selectedRules) }
                    .disabled(selectedRules.isEmpty)
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))

            Divider().frame(height: 14).padding(.horizontal, 2)

            Button {
                showsInspector.toggle()
            } label: {
                Image(systemName: "sidebar.right")
                    .foregroundStyle(showsInspector ? ForelTheme.accent : ForelTheme.secondaryText)
            }
            .buttonStyle(.borderless)
            .help(showsInspector ? "Hide the inspector" : "Show the inspector")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var table: some View {
        Table(rules, selection: $selection) {
            TableColumn("#") { rule in
                Text("\(orderById[rule.id] ?? 0)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(ForelTheme.secondaryText)
            }
            .width(24)

            TableColumn("Name") { rule in
                VStack(alignment: .leading, spacing: 1) {
                    Text(rule.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    if let hint = matchHints[rule.id] {
                        Text(hint)
                            .font(.system(size: 10))
                            .foregroundStyle(ForelTheme.accent)
                            .lineLimit(1)
                    }
                }
                .opacity(rule.enabled ? 1 : 0.55)
            }
            .width(min: 120, ideal: 180)

            TableColumn("On") { rule in
                Toggle("", isOn: Binding(get: { rule.enabled }, set: { model.toggleRule(rule, enabled: $0) }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .help(rule.enabled ? "Disable this rule" : "Enable this rule")
            }
            .width(28)

            TableColumn("If") { rule in
                Text(RuleSummary.conditions(rule))
                    .font(.system(size: 11))
                    .foregroundStyle(ForelTheme.secondaryText)
                    .lineLimit(1)
                    .help(RuleSummary.conditions(rule))
            }
            .width(min: 100, ideal: 170)

            TableColumn("Then") { rule in
                Text(RuleSummary.actions(rule))
                    .font(.system(size: 11))
                    .foregroundStyle(ForelTheme.secondaryText)
                    .lineLimit(1)
                    .help(RuleSummary.actions(rule))
            }
            .width(min: 100, ideal: 170)

            TableColumn("Runs") { rule in
                let stats = model.runStats(for: rule)
                let runs = (stats?.successCount ?? 0) + (stats?.failedCount ?? 0)
                HStack(spacing: 3) {
                    Text(runs == 0 ? "—" : "\(runs)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(ForelTheme.secondaryText)
                    if let failed = stats?.failedCount, failed > 0 {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                    }
                }
                .help("Last 30 days: \(stats?.successCount ?? 0) successful, \(stats?.failedCount ?? 0) failed")
            }
            .width(44)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            let targets = rules.filter { ids.contains($0.id) }
            if targets.count == 1, let rule = targets.first {
                Button("Edit…") { onEdit(rule) }
                if model.aiSettings.enabled {
                    Button("Review with AI…") { onReview(rule) }
                }
                Button("Duplicate") { model.duplicateRule(rule) }
                Button("Copy Share Link") { model.copyShareLink(for: rule) }
                Divider()
            }
            if !targets.isEmpty {
                Button("Enable") { model.setRulesEnabled(targets, true) }
                Button("Disable") { model.setRulesEnabled(targets, false) }
                Divider()
                Button(targets.count == 1 ? "Delete…" : "Delete \(targets.count) Rules…", role: .destructive) {
                    onDelete(targets)
                }
            }
        } primaryAction: { ids in
            guard ids.count == 1, let rule = rules.first(where: { ids.contains($0.id) }) else { return }
            onEdit(rule)
        }
        .scrollContentBackground(.hidden)
    }
}

/// Right-hand panel of the table view: what the selected rule does and how
/// it has been doing, with the common actions on it.
private struct RuleInspector: View {
    @EnvironmentObject var model: AppModel
    let rule: Rule?
    let selectionCount: Int
    let onEdit: (Rule) -> Void

    var body: some View {
        Group {
            if let rule {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(rule.name)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(ForelTheme.primaryText)
                                .textSelection(.enabled)
                            Spacer()
                            Toggle("", isOn: Binding(get: { rule.enabled }, set: { model.toggleRule(rule, enabled: $0) }))
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .labelsHidden()
                        }

                        RuleDetails(rule: rule)

                        Divider().overlay(ForelTheme.divider)

                        VStack(alignment: .leading, spacing: 8) {
                            infoRow("arrow.down.to.line.compact", "Scope", scopeText(rule))
                            infoRow("clock", "Last matched", lastMatchedText(rule))
                            infoRow("chart.bar", "Last 30 days", statsText(rule))
                        }

                        HStack(spacing: 8) {
                            Button {
                                onEdit(rule)
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .buttonStyle(PrimaryButtonStyle())

                            Button {
                                model.copyShareLink(for: rule)
                            } label: {
                                Label("Share Link", systemImage: "link")
                            }
                            .buttonStyle(SecondaryButtonStyle())
                        }
                    }
                    .padding(14)
                }
                .scrollIndicators(.never)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 22))
                        .foregroundStyle(ForelTheme.secondaryText)
                    Text(selectionCount > 1 ? "\(selectionCount) rules selected" : "No rule selected")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(ForelTheme.primaryText)
                    Text(selectionCount > 1 ? "Use the bar above to change them together." : "Select a rule to see what it does.")
                        .font(.system(size: 11))
                        .foregroundStyle(ForelTheme.secondaryText)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(ForelTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ForelTheme.surfaceBorder))
    }

    private func infoRow(_ icon: String, _ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(ForelTheme.secondaryText)
                .frame(width: 14)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(ForelTheme.secondaryText)
                .frame(width: 84, alignment: .leading)
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ForelTheme.primaryText)
                .textSelection(.enabled)
        }
    }

    private func scopeText(_ rule: Rule) -> String {
        switch rule.recursionDepth {
        case nil: return "This folder and all subfolders"
        case 0?: return "This folder only"
        case let depth?: return "\(depth) level\(depth == 1 ? "" : "s") of subfolders"
        }
    }

    private func lastMatchedText(_ rule: Rule) -> String {
        guard let date = model.db.withLock({ db in try? db.getRuleLastMatchedAt(ruleId: rule.id) }) else {
            return "Never"
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func statsText(_ rule: Rule) -> String {
        guard let stats = model.runStats(for: rule), stats.successCount + stats.failedCount > 0 else {
            return "No runs"
        }
        return stats.failedCount == 0
            ? "\(stats.successCount) successful"
            : "\(stats.successCount) successful, \(stats.failedCount) failed"
    }
}

/// One-line summaries of a rule's conditions and actions, for the table.
enum RuleSummary {
    static func conditions(_ rule: Rule) -> String {
        let terms = RuleSearch.searchableTerms(of: rule).filter { $0.field == .condition }.map(\.text)
        guard !terms.isEmpty else { return "Every file" }
        let joiner: String
        switch rule.conditionGroups.count == 1 ? rule.conditionGroups[0].match : rule.conditionMatch {
        case .any: joiner = " or "
        default: joiner = " and "
        }
        let text = terms.joined(separator: joiner)
        return rule.conditionMatch == .none && rule.conditionGroups.count > 1 ? "None of: \(text)" : text
    }

    static func actions(_ rule: Rule) -> String {
        let kinds = rule.actions.sorted { $0.position < $1.position }.map(\.kind.label)
        return kinds.isEmpty ? "Nothing" : kinds.joined(separator: " → ")
    }
}
