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

/// Inline dry-run results shown inside the rule editor: which files the
/// draft matched, how each condition evaluated, and what each action would
/// do. Kept inline (rather than a sheet over the editor sheet) so the rule
/// can be tweaked and re-tested without closing anything.
struct RuleTestPanel: View {
    let result: PreviewResult?
    let isTesting: Bool

    private var subtitle: String {
        guard let result else { return "" }
        let matchText = result.reachedMatchLimit
            ? "\(result.matches.count)+ matched"
            : "\(result.matches.count) matched"
        return "\(result.filesScanned) items scanned · \(matchText)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ForelTheme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Test results")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ForelTheme.primaryText)
                    if !isTesting, let result {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(ForelTheme.secondaryText)
                    }
                }
                Spacer()
                if isTesting {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Scanning folder…")
                            .font(.system(size: 11))
                            .foregroundStyle(ForelTheme.secondaryText)
                    }
                }
            }

            if isTesting {
                Spacer()
            } else if let result {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if result.reachedMatchLimit, let matchLimit = result.matchLimit {
                            matchLimitNote(matchLimit)
                        }
                        if result.matches.isEmpty {
                            if result.nonMatches.isEmpty {
                                Text("None of the \(result.filesScanned) scanned items were eligible for this rule.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(ForelTheme.secondaryText)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 24)
                            } else {
                                Text("No items matched — the rule's conditions failed on every scanned file. Samples below show which conditions didn't pass.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(ForelTheme.secondaryText)
                                    .padding(.vertical, 8)
                                if result.reachedNonMatchLimit {
                                    HStack(spacing: 8) {
                                        Image(systemName: "list.bullet.rectangle")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(ForelTheme.accent)
                                        Text("Showing the first \(result.nonMatches.count) non-matches.")
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(ForelTheme.secondaryText)
                                    }
                                    .padding(.bottom, 2)
                                }
                                ForEach(result.nonMatches, id: \.path) { nonMatch in
                                    FilePreviewRow(match: nonMatch)
                                }
                            }
                        } else {
                            ForEach(result.matches, id: \.path) { match in
                                FilePreviewRow(match: match)
                            }
                        }
                    }
                }
                .textSelection(.enabled)
                .scrollIndicators(.never)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 240)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(ForelTheme.accent.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(ForelTheme.accent.opacity(0.18))
        )
    }

    private func matchLimitNote(_ matchLimit: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ForelTheme.accent)
            Text("Showing the first \(matchLimit) matches. Narrow the folder scope or conditions to see fewer results.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ForelTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(ForelTheme.accent.opacity(0.10)))
    }
}

// MARK: - Shared dry-run rendering (also used by the folder-wide PreviewSheet)

/// One matched file: name, path, and the per-rule breakdown of how each
/// condition evaluated and what each action would do.
struct FilePreviewRow: View {
    let match: FilePreview

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "doc.fill").font(.system(size: 11)).foregroundStyle(ForelTheme.accent)
                Text(match.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(ForelTheme.primaryText)
            }
            Text(match.path)
                .font(.system(size: 10))
                .foregroundStyle(ForelTheme.secondaryText)
                .lineLimit(1)
                .truncationMode(.head)
            ForEach(match.rules, id: \.ruleId) { rulePreview in
                RulePreviewBreakdown(rulePreview: rulePreview)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(ForelTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ForelTheme.surfaceBorder))
    }
}

/// How one rule evaluated against a file: every condition with a pass/fail
/// mark (plus the strategy it used, when relevant) and the planned actions.
struct RulePreviewBreakdown: View {
    let rulePreview: RulePreview

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(rulePreview.ruleName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ForelTheme.secondaryText)
            ForEach(Array(rulePreview.conditions.enumerated()), id: \.offset) { _, condition in
                ConditionPreviewRow(condition: condition)
            }
            if rulePreview.actions.isEmpty {
                if rulePreview.matched {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 9))
                            .foregroundStyle(ForelTheme.secondaryText)
                        Text("No actions configured for this rule.")
                            .font(.system(size: 11))
                            .foregroundStyle(ForelTheme.secondaryText)
                    }
                    .padding(.leading, 6)
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 9))
                            .foregroundStyle(ForelTheme.secondaryText)
                        Text("Conditions didn't match — this rule's actions were skipped.")
                            .font(.system(size: 11))
                            .foregroundStyle(ForelTheme.secondaryText)
                    }
                    .padding(.leading, 6)
                }
            } else {
                ForEach(rulePreview.actions, id: \.self) { action in
                    ActionPreviewRow(action: action)
                }
            }
        }
        .padding(.leading, 6)
    }
}

struct ConditionPreviewRow: View {
    let condition: ConditionPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: condition.matched ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(condition.matched ? ForelTheme.accent : .red.opacity(0.85))
                Text(condition.label)
                    .font(.system(size: 11))
                    .foregroundStyle(ForelTheme.secondaryText)
                    .lineLimit(1)
            }
            if let detail = condition.detail {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(ForelTheme.secondaryText)
                    .lineLimit(1)
                    .padding(.leading, 15)
            }
        }
        .padding(.leading, 6)
    }
}

struct ActionPreviewRow: View {
    let action: ActionPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: action.statusIcon)
                    .font(.system(size: 9))
                    .foregroundStyle(action.statusColor)
                Text(action.description)
                    .font(.system(size: 11))
                    .foregroundStyle(ForelTheme.primaryText)
                Text(action.statusLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(action.statusColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(action.statusColor.opacity(0.12)))
            }
            if let targetPath = action.targetPath {
                Text("\((action.sourcePath as NSString).lastPathComponent) -> \((targetPath as NSString).lastPathComponent)")
                    .font(.system(size: 10))
                    .foregroundStyle(ForelTheme.secondaryText)
            }
            if let warning = action.warning {
                Text(warning)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }
}

extension ConditionPreview {
    var label: String {
        "\(kind.label) \(`operator_`.label) \(value)"
    }
}

extension ActionPreview {
    var statusLabel: String {
        if warning != nil { return "Likely to fail" }
        switch status {
        case .wouldRun: return "Would run"
        case .wouldSkip: return "Would skip"
        case .blockedByConflict: return "Blocked by conflict"
        case .needsConfirmation: return "Needs confirmation"
        }
    }

    var statusIcon: String {
        if warning != nil { return "exclamationmark.triangle.fill" }
        switch status {
        case .wouldRun: return "arrow.turn.down.right"
        case .wouldSkip: return "minus.circle"
        case .blockedByConflict: return "exclamationmark.triangle.fill"
        case .needsConfirmation: return "questionmark.circle.fill"
        }
    }

    @MainActor var statusColor: Color {
        if warning != nil { return .orange }
        switch status {
        case .wouldRun: return ForelTheme.accent
        case .wouldSkip: return ForelTheme.secondaryText
        case .blockedByConflict: return .orange
        case .needsConfirmation: return .purple
        }
    }
}
