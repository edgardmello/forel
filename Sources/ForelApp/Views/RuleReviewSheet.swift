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

/// "Review with AI" in the rule editor's bottom bar. Hidden until AI
/// features are turned on in Settings → AI.
struct ReviewRuleButton: View {
    @EnvironmentObject var model: AppModel
    let rule: Rule
    let onEdited: (RuleEdit, Int) -> Void
    @State private var showing = false

    var body: some View {
        if model.aiSettings.enabled {
            Button {
                showing = true
            } label: {
                Label("Review with AI…", systemImage: "sparkles")
            }
            .buttonStyle(SecondaryButtonStyle())
            .help("\(model.aiSettings.provider.label) checks this rule and suggests better ways to do the same")
            .sheet(isPresented: $showing) {
                RuleReviewSheet(
                    rule: rule,
                    folderPath: model.folders.first { $0.id == rule.folderId }?.path,
                    otherRules: model.rules.filter { $0.folderId == rule.folderId && $0.id != rule.id },
                    settings: model.aiSettings,
                    onEdited: { edit, count in
                        onEdited(edit, count)
                        showing = false
                    },
                    onClose: { showing = false }
                )
            }
        }
    }
}

/// Analyzes the rule as it stands in the editor as soon as it opens, lists
/// the suggestions (all chosen by default), and has the service rewrite the
/// rule with the chosen ones. The rewritten rule only replaces the editor's
/// draft, so it still has to be saved, and Cancel in the editor throws it
/// away.
struct RuleReviewSheet: View {
    let rule: Rule
    let folderPath: String?
    let otherRules: [Rule]
    let settings: AISettings
    let onEdited: (RuleEdit, Int) -> Void
    let onClose: () -> Void

    private enum Phase { case analyzing, editing }

    @State private var review: RuleReview?
    @State private var chosen: Set<Int> = []
    @State private var error: String?
    @State private var phase: Phase?
    @State private var task: Task<Void, Never>?

    private var chosenSuggestions: [RuleReviewSuggestion] {
        review?.suggestions.filter { chosen.contains($0.id) } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewHeader(
                title: "Review with AI",
                subtitle: "\(settings.provider.label) checks “\(rule.name.isEmpty ? "this rule" : rule.name)” and suggests improvements",
                systemImage: "sparkles"
            )

            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(ForelTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if let phase {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(phase == .analyzing
                         ? "Analyzing the rule with \(settings.provider.label)…"
                         : "\(settings.provider.label) is editing the rule with \(chosen.count) suggestion\(chosen.count == 1 ? "" : "s")…")
                        .font(.system(size: 12))
                        .foregroundStyle(ForelTheme.primaryText)
                    Text("This can take up to a minute.")
                        .font(.system(size: 11))
                        .foregroundStyle(ForelTheme.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let review {
                ScrollView {
                    ReviewResultView(review: review, chosen: $chosen)
                        .padding(.trailing, 6)
                }
                .frame(maxHeight: .infinity)
            } else {
                Spacer(minLength: 0)
            }

            Text("Sends this rule (conditions, actions, folder paths and scripts, without upload passwords), the watched folder's path and its other rules — never the names or contents of your files.")
                .font(.system(size: 10))
                .foregroundStyle(ForelTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Divider().overlay(ForelTheme.divider)

            HStack {
                Spacer()
                if phase != nil {
                    Button("Stop") {
                        task?.cancel()
                        task = nil
                        phase = nil
                    }
                    .buttonStyle(SecondaryButtonStyle())
                } else {
                    Button("Close", action: onClose)
                        .buttonStyle(SecondaryButtonStyle())
                        .keyboardShortcut(.cancelAction)
                    Button("Analyze Again", action: analyze)
                        .buttonStyle(SecondaryButtonStyle())
                    if let review, !review.suggestions.isEmpty {
                        Button(chosen.count > 1 ? "Apply \(chosen.count) Suggestions" : "Apply Suggestion", action: applyChosen)
                            .buttonStyle(PrimaryButtonStyle())
                            .keyboardShortcut(.defaultAction)
                            .disabled(chosen.isEmpty)
                            .opacity(chosen.isEmpty ? 0.5 : 1)
                            .help("\(settings.provider.label) rewrites the rule with the chosen suggestions and loads it into the editor for you to save")
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 720, height: 600)
        .background(ForelTheme.background)
        .onAppear { if review == nil && phase == nil { analyze() } }
        .onDisappear { task?.cancel() }
    }

    private func analyze() {
        guard phase == nil else { return }
        error = nil
        phase = .analyzing
        let apiKey = AIKeychain.key(for: settings.provider.rawValue)
        let rule = rule, folderPath = folderPath, otherRules = otherRules, settings = settings
        task = Task {
            do {
                let result = try await RuleReviewer.review(
                    rule: rule, folderPath: folderPath, otherRules: otherRules, settings: settings, apiKey: apiKey
                )
                guard !Task.isCancelled else { return }
                review = result
                chosen = Set(result.suggestions.map(\.id))
            } catch {
                report(error)
            }
            if !Task.isCancelled { phase = nil; task = nil }
        }
    }

    private func applyChosen() {
        let suggestions = chosenSuggestions
        guard phase == nil, !suggestions.isEmpty else { return }
        error = nil
        phase = .editing
        let apiKey = AIKeychain.key(for: settings.provider.rawValue)
        let rule = rule, folderPath = folderPath, settings = settings
        task = Task {
            do {
                let edit = try await RuleReviewer.edit(
                    rule: rule, folderPath: folderPath, suggestions: suggestions, settings: settings, apiKey: apiKey
                )
                guard !Task.isCancelled else { return }
                phase = nil
                task = nil
                onEdited(edit, suggestions.count)
                return
            } catch {
                report(error)
            }
            if !Task.isCancelled { phase = nil; task = nil }
        }
    }

    private func report(_ failure: Error) {
        guard !Task.isCancelled, !(failure is CancellationError) else { return }
        switch failure {
        case let failure as ScriptGenerationError: error = failure.message
        case let failure as RuleEditError: error = failure.description
        default: error = failure.localizedDescription
        }
    }
}

private struct ReviewResultView: View {
    let review: RuleReview
    @Binding var chosen: Set<Int>

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !review.summary.isEmpty {
                Text(review.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(ForelTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if review.suggestions.isEmpty {
                Label("Nothing to improve: the rule already looks good.", systemImage: "checkmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(ForelTheme.success)
            } else {
                HStack {
                    SectionLabel(title: "Suggestions")
                    Spacer()
                    Button(chosen.count == review.suggestions.count ? "Choose None" : "Choose All") {
                        chosen = chosen.count == review.suggestions.count ? [] : Set(review.suggestions.map(\.id))
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                }
                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(review.suggestions) { suggestion in
                            SuggestionRow(
                                suggestion: suggestion,
                                isChosen: Binding(
                                    get: { chosen.contains(suggestion.id) },
                                    set: { if $0 { chosen.insert(suggestion.id) } else { chosen.remove(suggestion.id) } }
                                )
                            )
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("Choose the suggestions to apply. Forel then asks the AI to edit the rule with them and loads the result into the editor, ready for you to check and save.")
                    .font(.system(size: 11))
                    .foregroundStyle(ForelTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SuggestionRow: View {
    let suggestion: RuleReviewSuggestion
    @Binding var isChosen: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Toggle("", isOn: $isChosen)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel("Apply “\(suggestion.title)”")
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 16)
                .help(categoryLabel)
                .accessibilityLabel(categoryLabel)
            VStack(alignment: .leading, spacing: 3) {
                Text(suggestion.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ForelTheme.primaryText)
                if !suggestion.detail.isEmpty {
                    Text(suggestion.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(ForelTheme.secondaryText)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }
    }

    private var icon: String {
        switch suggestion.category {
        case .problem: return "exclamationmark.circle"
        case .efficiency: return "bolt"
        case .simplification: return "wand.and.stars"
        case .safety: return "shield.lefthalf.filled"
        case .alternative: return "arrow.triangle.branch"
        case .other: return "lightbulb"
        }
    }

    private var color: Color {
        switch suggestion.category {
        case .problem: return ForelTheme.danger
        case .safety: return .orange
        default: return ForelTheme.accent
        }
    }

    private var categoryLabel: String {
        switch suggestion.category {
        case .problem: return "Problem"
        case .efficiency: return "Efficiency"
        case .simplification: return "Simpler"
        case .safety: return "Safety"
        case .alternative: return "Better approach"
        case .other: return "Idea"
        }
    }
}

/// Shown at the top of the rule editor after the AI edited the draft:
/// what changed, a warning when the new version runs code, deletes or
/// uploads, and a way back to the draft as it was.
struct AIEditNotice: View {
    let count: Int
    let explanation: String?
    let addsRiskyActions: Bool
    let onUndo: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(ForelTheme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("The rule was edited with \(count) AI suggestion\(count == 1 ? "" : "s"). Check it, use Test, then Save — or Undo.")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ForelTheme.primaryText)
                if let explanation {
                    Text(explanation)
                        .font(.system(size: 11))
                        .foregroundStyle(ForelTheme.secondaryText)
                        .textSelection(.enabled)
                }
                if addsRiskyActions {
                    Label("The new version runs a script, deletes files or uploads them. Test it before turning the rule on.", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Undo", action: onUndo)
                .buttonStyle(SecondaryButtonStyle())
                .help("Go back to the rule as it was before the AI edited it")
            Button(action: onDismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(IconButtonStyle())
            .help("Hide this message")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(ForelTheme.accent.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(ForelTheme.accent.opacity(0.25)))
    }
}
