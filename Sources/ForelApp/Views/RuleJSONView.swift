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


import AppKit
import SwiftUI
import ForelCore

/// A rule's scope, conditions and actions as JSON — the same compact format
/// Review with AI exchanges with the service — selectable and copyable.
struct RuleJSONView: View {
    let rule: Rule
    @State private var copied = false

    private var json: String { RuleReviewer.json(for: rule) }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ScrollView([.vertical, .horizontal]) {
                Text(json)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(ForelTheme.primaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(ForelTheme.surfaceBorder))

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(json, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            } label: {
                Label(copied ? "Copied" : "Copy JSON", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .controlSize(.small)
        }
    }
}

/// "View as JSON" from the rule editor: the draft as it stands now.
struct RuleJSONSheet: View {
    let rule: Rule
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewHeader(
                title: "Rule as JSON",
                subtitle: "The scope, conditions and actions of “\(rule.name.isEmpty ? "this rule" : rule.name)”, as it is in the editor now",
                systemImage: "curlybraces"
            )
            RuleJSONView(rule: rule)
            HStack {
                Text("Upload passwords are hidden. To share or back up whole rules, use Export Rules… or Copy Share Link in the rule list.")
                    .font(.system(size: 10))
                    .foregroundStyle(ForelTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Done", action: onClose)
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 640, height: 560)
        .background(ForelTheme.background)
    }
}
