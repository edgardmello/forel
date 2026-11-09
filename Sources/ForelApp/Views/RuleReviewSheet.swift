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
    let onUseSuggestion: (Rule) -> Void
    @State private var showing = false

    var body: some View {
        if model.aiSettings.enabled {
            Button {
                showing = true
            } label: {
                Label("Review with AI…", systemImage: "sparkles")
            }
            .buttonStyle(SecondaryButtonStyle())
            .help("Ask \(model.aiSettings.provider.label) to check this rule and suggest better ways to do the same")
            .sheet(isPresented: $showing) {
                RuleReviewSheet(
                    rule: rule,
                    folderPath: model.folders.first { $0.id == rule.folderId }?.path,
                    otherRules: model.rules.filter { $0.folderId == rule.folderId && $0.id != rule.id },
                    settings: model.aiSettings,
                    onUse: { suggested in
                        onUseSuggestion(suggested)
                        showing = false
                    },
                    onClose: { showing = false }
                )
            }
        }
    }
}

/// Sends the rule as it stands in the editor for review and shows the
/// advice. A suggested version only replaces the editor's draft when the
/// user chooses it, and still has to be saved, so Cancel in the editor
/// throws it away.
struct RuleReviewSheet: View {
    let rule: Rule
    let folderPath: String?
    let otherRules: [Rule]
    let settings: AISettings
    let onUse: (Rule) -> Void
    let onClose: () -> Void

    @State private var goal = ""
    @State private var review: RuleReview?
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    private var isReviewing: Bool { task != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewHeader(
                title: "Review with AI",
                subtitle: "\(settings.provider.label) checks “\(rule.name.isEmpty ? "this rule" : rule.name)” and suggests improvements",
                systemImage: "sparkles"
            )

            VStack(alignment: .leading, spacing: 6) {
                Text("What should this rule achieve? (optional)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ForelTheme.primaryText)
                TextField("e.g. “keep Downloads tidy: PDFs into Documents by year, old installers to the Trash”", text: $goal, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isReviewing)
                Text("Sends this rule (conditions, actions, folder paths and scripts, without upload passwords), the watched folder's path and its other rules — never the names or contents of your files.")
                    .font(.system(size: 10))
                    .foregroundStyle(ForelTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(ForelTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if isReviewing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Asking \(settings.provider.label)… this can take up to a minute.")
                        .font(.system(size: 11))
                        .foregroundStyle(ForelTheme.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let review {
                ScrollView {
                    ReviewResultView(review: review, current: rule)
                        .padding(.trailing, 6)
                }
                .frame(maxHeight: .infinity)
            } else {
                Spacer(minLength: 0)
            }

            Divider().overlay(ForelTheme.divider)

            HStack {
                if review?.improvedRule != nil, !isReviewing {
                    Text("Using the suggested version changes the editor only; review it, then Save.")
                        .font(.system(size: 10))
                        .foregroundStyle(ForelTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if isReviewing {
                    Button("Stop") {
                        task?.cancel()
                        task = nil
                    }
                    .buttonStyle(SecondaryButtonStyle())
                } else {
                    Button(review == nil ? "Cancel" : "Close", action: onClose)
                        .buttonStyle(SecondaryButtonStyle())
                        .keyboardShortcut(.cancelAction)
                    if let improved = review?.improvedRule {
                        Button(review == nil ? "Review" : "Review Again", action: start)
                            .buttonStyle(SecondaryButtonStyle())
                        Button("Use Suggested Version") { onUse(improved) }
                            .buttonStyle(PrimaryButtonStyle())
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button(review == nil ? "Review" : "Review Again", action: start)
                            .buttonStyle(PrimaryButtonStyle())
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 760, height: review == nil && !isReviewing ? 300 : 640)
        .background(ForelTheme.background)
        .onDisappear { task?.cancel() }
    }

    private func start() {
        guard !isReviewing else { return }
        error = nil
        let apiKey = AIKeychain.key(for: settings.provider.rawValue)
        let rule = rule, folderPath = folderPath, otherRules = otherRules, goal = goal, settings = settings
        task = Task {
            do {
                let result = try await RuleReviewer.review(
                    rule: rule,
                    folderPath: folderPath,
                    otherRules: otherRules,
                    goal: goal,
                    settings: settings,
                    apiKey: apiKey
                )
                if !Task.isCancelled { review = result }
            } catch is CancellationError {
            } catch let failure as ScriptGenerationError {
                if !Task.isCancelled { error = failure.message }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
            task = nil
        }
    }
}

private struct ReviewResultView: View {
    let review: RuleReview
    let current: Rule

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
                Text("No suggestions: the service found nothing to improve.")
                    .font(.system(size: 11))
                    .foregroundStyle(ForelTheme.secondaryText)
            } else {
                SectionLabel(title: "Suggestions")
                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(review.suggestions) { suggestion in
                            SuggestionRow(suggestion: suggestion)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if let improved = review.improvedRule {
                SectionLabel(title: "Suggested Version")
                if let explanation = review.improvedRuleExplanation {
                    Text(explanation)
                        .font(.system(size: 11))
                        .foregroundStyle(ForelTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                HStack(alignment: .top, spacing: 12) {
                    RuleOutline(title: "Now", rule: current)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(ForelTheme.secondaryText)
                        .padding(.top, 30)
                    RuleOutline(title: "Suggested", rule: improved)
                }
                if improved.actions.contains(where: { [.runScript, .runAppleScript, .runJavaScript, .delete, .upload].contains($0.kind) }) {
                    Label("The suggested version runs a script, deletes files or uploads them. Check it and use Test before turning the rule on.", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if !review.improvedRuleProblems.isEmpty {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("The service also proposed a new version of the rule, but Forel can't use it:")
                        ForEach(review.improvedRuleProblems, id: \.self) { Text("• \($0)") }
                        Text("You can still apply the suggestions above by hand, or review again.")
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(.system(size: 11))
                .foregroundStyle(ForelTheme.secondaryText)
                .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SuggestionRow: View {
    let suggestion: RuleReviewSuggestion

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
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

/// A compact, read-only outline of a rule's scope, conditions and actions,
/// to compare the current rule with the suggested one.
private struct RuleOutline: View {
    let title: String
    let rule: Rule

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 6) {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(ForelTheme.secondaryText)
                Text(scope)
                    .font(.system(size: 11))
                    .foregroundStyle(ForelTheme.secondaryText)
                Text(matchLine)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ForelTheme.primaryText)
                ForEach(Array(rule.conditionGroups.enumerated()), id: \.offset) { _, group in
                    VStack(alignment: .leading, spacing: 2) {
                        if rule.conditionGroups.count > 1 {
                            Text(group.match == .any ? "Any of:" : "All of:")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(ForelTheme.secondaryText)
                        }
                        ForEach(Array(group.conditions.enumerated()), id: \.offset) { _, condition in
                            Text("• \(condition.kind.label) \(condition.operator.label) \(displayValue(condition))")
                        }
                    }
                    .padding(.leading, rule.conditionGroups.count > 1 ? 8 : 0)
                }
                Text("Actions")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ForelTheme.primaryText)
                    .padding(.top, 4)
                ForEach(Array(rule.actions.sorted { $0.position < $1.position }.enumerated()), id: \.offset) { index, action in
                    Text("\(index + 1). \(actionLine(action))")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(ForelTheme.primaryText)
            .textSelection(.enabled)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var scope: String {
        switch rule.recursionDepth {
        case nil: return "This folder and all subfolders"
        case 0?: return "This folder only"
        case let depth?: return "This folder and \(depth) level\(depth == 1 ? "" : "s") of subfolders"
        }
    }

    private var matchLine: String {
        if rule.conditions.isEmpty { return "Every file" }
        let mode = rule.conditionGroups.count > 1 ? rule.conditionMatch : (rule.conditionMatch == ConditionMatch.none ? ConditionMatch.none : rule.conditionGroups[0].match)
        let noun = rule.conditionGroups.count > 1 ? "groups" : "conditions"
        switch mode {
        case .all: return "When all \(noun) match"
        case .any: return "When any \(noun.dropLast()) matches"
        case .none: return "When no \(noun.dropLast()) matches"
        }
    }

    private func displayValue(_ condition: Condition) -> String {
        if condition.kind == .spotlightMetadata, let parsed = SpotlightMetadataCondition.parse(condition.value) {
            return "\(parsed.key) = \(parsed.value)"
        }
        return "“\(condition.value)”"
    }

    private func actionLine(_ action: Action) -> String {
        let p = action.params
        let detail: String?
        switch action.kind {
        case .moveToFolder, .copyToFolder, .syncToFolder, .syncFolders:
            detail = p[ActionParam.destination]?.stringValue
        case .sortIntoSubfolder: detail = p[ActionParam.subfolder]?.stringValue
        case .rename: detail = p[ActionParam.pattern]?.stringValue
        case .upload: detail = p[ActionParam.uploadURL]?.stringValue.map(UploadDestination.displayString(for:))
        case .addTag, .removeTag:
            detail = p[ActionParam.tags]?.arrayValue?.compactMap(\.stringValue).joined(separator: ", ") ?? p["tag"]?.stringValue
        case .setColorLabel: detail = p[ActionParam.color]?.stringValue
        case .addComment: detail = p[ActionParam.comment]?.stringValue
        case .runScript, .runAppleScript, .runJavaScript:
            if ScriptSource.of(action) == .file {
                detail = p[ActionParam.scriptPath]?.stringValue
            } else {
                let lines = (p[ActionParam.script]?.stringValue ?? "").split(separator: "\n")
                detail = lines.first.map { lines.count > 1 ? "\($0) … (\(lines.count) lines)" : String($0) }
            }
        case .runShortcut: detail = p[ActionParam.shortcutName]?.stringValue
        case .openApplication: detail = p[ActionParam.applicationPath]?.stringValue.map { ($0 as NSString).lastPathComponent }
        case .makeAlias: detail = p[ActionParam.aliasDestination]?.stringValue
        case .convertImage: detail = p[ActionParam.imageFormat]?.stringValue?.uppercased()
        case .displayNotification: detail = p[ActionParam.notificationTitle]?.stringValue
        case .runAutomatorWorkflow: detail = p[ActionParam.workflowPath]?.stringValue.map { ($0 as NSString).lastPathComponent }
        case .importToLibrary: detail = LibraryType(rawValue: p[ActionParam.libraryType]?.stringValue ?? "")?.label
        case .pause:
            if case .number(let seconds)? = p[ActionParam.pauseSeconds] { detail = "\(Int(seconds)) s" } else { detail = nil }
        default: detail = nil
        }
        guard let detail, !detail.isEmpty else { return action.kind.label }
        return "\(action.kind.label): \(detail)"
    }
}
