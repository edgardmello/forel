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
    /// The edit, how many suggestions it applies, and the remembered review it came from.
    let onEdited: (RuleEdit, Int, String?) -> Void
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
                    onEdited: { edit, count, reviewId in
                        onEdited(edit, count, reviewId)
                        showing = false
                    },
                    onClose: { showing = false }
                )
            }
        }
    }
}

/// First asks, optionally, what the rule should achieve, so the service can
/// judge it against that goal, then analyzes the rule and lists the
/// suggestions (all chosen by default). The user can answer the
/// service with new directions or ideas, which updates the suggestions, then
/// have it write the rule with the chosen ones. The written rule is shown as
/// JSON and can be discussed the same way before it replaces the editor's
/// draft, which still has to be saved: Cancel in the editor throws it away.
struct RuleReviewSheet: View {
    let rule: Rule
    let folderPath: String?
    let otherRules: [Rule]
    let settings: AISettings
    /// The edit, how many suggestions it applies, and the id of the
    /// remembered review, so the editor can record how it ended.
    let onEdited: (RuleEdit, Int, String?) -> Void
    let onClose: () -> Void
    @EnvironmentObject private var model: AppModel

    private enum Phase { case analyzing, editing, replying }

    @State private var goal = ""
    @State private var review: RuleReview?
    @State private var reviewConversation: RuleReviewConversation?
    @State private var edit: RuleEdit?
    @State private var editConversation: RuleReviewConversation?
    /// Whether the rule the service wrote is on screen (instead of the
    /// suggestions it was written from).
    @State private var showingEdit = false
    @State private var appliedCount = 0
    @State private var chosen: Set<Int> = []
    @State private var replyText = ""
    @State private var lastReply: String?
    @State private var error: String?
    @State private var phase: Phase?
    @State private var task: Task<Void, Never>?
    /// What this session has done so far, kept when Remember Reviews is on.
    @State private var record: RuleReviewRecord?
    /// How many earlier reviews went along with the analysis.
    @State private var pastReviewCount = 0

    private var chosenSuggestions: [RuleReviewSuggestion] {
        review?.suggestions.filter { chosen.contains($0.id) } ?? []
    }

    private var canReply: Bool {
        phase == nil && (showingEdit ? editConversation != nil : reviewConversation != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewHeader(
                title: showingEdit ? "Suggested Rule" : "Review with AI",
                subtitle: showingEdit
                    ? "\(settings.provider.label) rewrote “\(rule.name.isEmpty ? "this rule" : rule.name)” with \(appliedCount) suggestion\(appliedCount == 1 ? "" : "s")"
                    : "\(settings.provider.label) checks “\(rule.name.isEmpty ? "this rule" : rule.name)” and suggests improvements",
                systemImage: showingEdit ? "curlybraces" : "sparkles"
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
                    Text(progressText(phase))
                        .font(.system(size: 12))
                        .foregroundStyle(ForelTheme.primaryText)
                    Text("This can take up to a minute.")
                        .font(.system(size: 11))
                        .foregroundStyle(ForelTheme.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if showingEdit, let edit {
                VStack(alignment: .leading, spacing: 10) {
                    if let lastReply { youSaid(lastReply) }
                    if let explanation = edit.explanation {
                        Text(explanation)
                            .font(.system(size: 12))
                            .foregroundStyle(ForelTheme.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    RuleJSONView(rule: edit.rule)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            } else if let review {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Label {
                                Text("Goal: \(goal.trimmingCharacters(in: .whitespacesAndNewlines))").textSelection(.enabled)
                            } icon: {
                                Image(systemName: "target")
                            }
                            .font(.system(size: 11))
                            .foregroundStyle(ForelTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        if pastReviewCount > 0 {
                            Label("Took \(pastReviewCount) similar earlier review\(pastReviewCount == 1 ? "" : "s") into account", systemImage: "clock.arrow.circlepath")
                                .font(.system(size: 11))
                                .foregroundStyle(ForelTheme.secondaryText)
                                .help("What you applied, turned down, replied and saved in those reviews went along, so the AI can follow your preferences and reuse what worked")
                        }
                        if let lastReply { youSaid(lastReply) }
                        ReviewResultView(review: review, chosen: $chosen)
                    }
                    .padding(.trailing, 6)
                }
                .frame(maxHeight: .infinity)
            } else {
                goalForm
            }

            if canReply {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField(
                        showingEdit
                            ? "Reply to the AI: ask for changes to this rule, or share an idea…"
                            : "Reply to the AI with new directions or ideas, e.g. “keep the script” or “also handle images”…",
                        text: $replyText,
                        axis: .vertical
                    )
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(sendReply)
                    Button("Send", action: sendReply)
                        .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help(showingEdit
                              ? "The AI adjusts the rule it wrote, or keeps it and answers you"
                              : "The AI reconsiders the rule and updates its suggestions")
                }
            }

            Text(model.rememberReviews
                 ? "Sends this rule (conditions, actions, folder paths and scripts, without upload passwords), the watched folder's path, its other rules, the goal you describe, your replies and what you decided in similar earlier reviews — never the names or contents of your files. Reviews are remembered on this Mac (Settings → AI)."
                 : "Sends this rule (conditions, actions, folder paths and scripts, without upload passwords), the watched folder's path, its other rules, the goal you describe and your replies — never the names or contents of your files.")
                .font(.system(size: 10))
                .foregroundStyle(ForelTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Divider().overlay(ForelTheme.divider)

            HStack {
                if showingEdit, phase == nil {
                    Button("Back to Suggestions") {
                        showingEdit = false
                        lastReply = nil
                        error = nil
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
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
                    if showingEdit, let edit {
                        Button("Use This Rule") {
                            remember { $0.finish(.used) }
                            onEdited(edit, appliedCount, model.rememberReviews ? record?.id : nil)
                        }
                            .buttonStyle(PrimaryButtonStyle())
                            .help("Load this rule into the editor, where you can check it, test it and save it")
                    } else {
                        if review == nil {
                            Button("Analyze", action: analyze)
                                .buttonStyle(PrimaryButtonStyle())
                                .keyboardShortcut(.defaultAction)
                        } else {
                            Button("Analyze Again", action: analyze)
                                .buttonStyle(SecondaryButtonStyle())
                                .help("Analyze the rule again from the start, with the same goal")
                        }
                        if let review, !review.suggestions.isEmpty {
                            Button(chosen.count > 1 ? "Apply \(chosen.count) Suggestions" : "Apply Suggestion", action: applyChosen)
                                .buttonStyle(PrimaryButtonStyle())
                                .disabled(chosen.isEmpty)
                                .opacity(chosen.isEmpty ? 0.5 : 1)
                                .help("\(settings.provider.label) rewrites the rule with the chosen suggestions and shows it before it goes into the editor")
                        }
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 720, height: 640)
        .background(ForelTheme.background)
        .onDisappear { task?.cancel() }
    }

    /// Before the first analysis: what the rule should achieve, in the
    /// user's own words. Optional; without it the service works the goal
    /// out from the rule.
    private var goalForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What should this rule achieve?")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ForelTheme.primaryText)
            Text("Optional. Describing the goal gives the AI more context to judge the rule and suggest better ways to get there. Leave it empty and it works the goal out from the rule.")
                .font(.system(size: 11))
                .foregroundStyle(ForelTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            TextField("e.g. “file bank statements by year and keep only the PDFs; never delete anything”", text: $goal, axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func progressText(_ phase: Phase) -> String {
        switch phase {
        case .analyzing: return "Analyzing the rule with \(settings.provider.label)…"
        case .editing: return "\(settings.provider.label) is writing the rule with \(chosen.count) suggestion\(chosen.count == 1 ? "" : "s")…"
        case .replying: return "\(settings.provider.label) is considering your reply…"
        }
    }

    private func youSaid(_ text: String) -> some View {
        Label {
            Text(text).textSelection(.enabled)
        } icon: {
            Image(systemName: "person.crop.circle")
        }
        .font(.system(size: 11))
        .foregroundStyle(ForelTheme.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func analyze() {
        guard phase == nil else { return }
        error = nil
        lastReply = nil
        phase = .analyzing
        let apiKey = AIKeychain.key(for: settings.provider.rawValue)
        let rule = rule, folderPath = folderPath, otherRules = otherRules, goal = goal, settings = settings
        let pastReviews = model.relevantPastReviews(for: rule, folderPath: folderPath, goal: goal, excluding: record?.id)
        task = Task {
            do {
                let (result, conversation) = try await RuleReviewer.review(
                    rule: rule, folderPath: folderPath, otherRules: otherRules, goal: goal, pastReviews: pastReviews,
                    settings: settings, apiKey: apiKey
                )
                guard !Task.isCancelled else { return }
                show(result, conversation: conversation)
                pastReviewCount = pastReviews.count
                // Analyze Again starts the session over, under the same record.
                record = RuleReviewRecord(id: record?.id ?? UUID().uuidString, rule: rule, folderPath: folderPath, goal: goal, review: result)
                remember { _ in }
            } catch {
                report(error)
            }
            if !Task.isCancelled { phase = nil; task = nil }
        }
    }

    private func show(_ result: RuleReview, conversation: RuleReviewConversation) {
        review = result
        reviewConversation = conversation
        chosen = Set(result.suggestions.map(\.id))
    }

    private func applyChosen() {
        let suggestions = chosenSuggestions
        guard phase == nil, !suggestions.isEmpty else { return }
        error = nil
        phase = .editing
        let apiKey = AIKeychain.key(for: settings.provider.rawValue)
        let rule = rule, folderPath = folderPath, goal = goal, settings = settings
        task = Task {
            do {
                let (result, conversation) = try await RuleReviewer.edit(
                    rule: rule, folderPath: folderPath, suggestions: suggestions, goal: goal, settings: settings, apiKey: apiKey
                )
                guard !Task.isCancelled else { return }
                edit = result
                editConversation = conversation
                appliedCount = suggestions.count
                remember { $0.propose(result, chosen: suggestions) }
                lastReply = nil
                showingEdit = true
            } catch {
                report(error)
            }
            if !Task.isCancelled { phase = nil; task = nil }
        }
    }

    private func sendReply() {
        let feedback = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canReply, !feedback.isEmpty,
              let conversation = showingEdit ? editConversation : reviewConversation else { return }
        error = nil
        phase = .replying
        let apiKey = AIKeychain.key(for: settings.provider.rawValue)
        let rule = rule, settings = settings
        task = Task {
            do {
                let (reply, next) = try await RuleReviewer.reply(
                    feedback, to: conversation, rule: rule, settings: settings, apiKey: apiKey
                )
                guard !Task.isCancelled else { return }
                switch reply {
                case .review(let result):
                    show(result, conversation: next)
                    remember { $0.addReply(feedback); $0.update(with: result) }
                case .edit(let result):
                    edit = result
                    editConversation = next
                    remember { $0.addReply(feedback); $0.propose(result) }
                }
                lastReply = feedback
                replyText = ""
            } catch {
                report(error)
            }
            if !Task.isCancelled { phase = nil; task = nil }
        }
    }

    /// Applies `change` to this session's record and keeps it.
    private func remember(_ change: (inout RuleReviewRecord) -> Void) {
        guard var current = record else { return }
        change(&current)
        record = current
        model.rememberReview(current)
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
                Text("Choose the suggestions to apply, or reply to the AI below to change them. Forel then asks the AI to write the rule with them and shows it before it goes into the editor, ready for you to check and save.")
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
