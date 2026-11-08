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

/// The answer to "why didn't my rule run on this file?": each rule of the
/// folder with its verdict and, when it doesn't match, its conditions.
struct FileExplanationView: View {
    let explanation: FileExplanation
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Why rules did or didn't run")
                    .font(.system(size: 14, weight: .semibold))
                Text(explanation.path)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let reason = explanation.skippedReason {
                        Text(reason)
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                    } else if explanation.rules.isEmpty {
                        Text("This folder has no rules yet.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(explanation.rules) { rule in
                            ruleRow(rule)
                        }
                        Text("Each rule is judged on the file as it is now. When an earlier rule moves or renames it, later rules see the result.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 520, height: 440)
    }

    private func ruleRow(_ rule: RuleExplanation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon(rule.verdict))
                    .foregroundStyle(color(rule.verdict))
                Text(rule.ruleName)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            Text(summary(rule.verdict))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if rule.verdict == .conditionsFail {
                ForEach(Array(rule.conditions.enumerated()), id: \.offset) { _, condition in
                    ConditionPreviewRow(condition: condition)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func summary(_ verdict: RuleExplanation.Verdict) -> String {
        switch verdict {
        case .matches: return "Matches: this rule acts on the file. If it hasn't yet, use Run Now; with Watching on it runs when the file arrives or changes."
        case .alreadyHandled: return "Matches, but it already handled this file and the file hasn't changed since, so automatic runs leave it alone. Run Now still runs it."
        case .conditionsFail: return "Doesn't match. Conditions marked with ✗ failed:"
        case .turnedOff: return "The rule is turned off."
        case .outOfScope: return "The file is in a subfolder deeper than this rule looks. Raise the rule's subfolder depth to include it."
        }
    }

    private func icon(_ verdict: RuleExplanation.Verdict) -> String {
        switch verdict {
        case .matches: return "checkmark.circle.fill"
        case .alreadyHandled: return "checkmark.circle"
        case .conditionsFail: return "xmark.circle.fill"
        case .turnedOff: return "pause.circle"
        case .outOfScope: return "arrow.down.right.circle"
        }
    }

    private func color(_ verdict: RuleExplanation.Verdict) -> Color {
        switch verdict {
        case .matches, .alreadyHandled: return .green
        case .conditionsFail: return .red
        case .turnedOff, .outOfScope: return .secondary
        }
    }
}
