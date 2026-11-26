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

/// Which "organize rules" sheet is open for the selected folder.
enum RuleOrganizingSheet: String, Identifiable {
    case check
    case order
    case dailyInbox
    case flow

    var id: String { rawValue }
}

// MARK: - Check Rules

/// Lists what's wrong with how the folder's rules work together, and can
/// check the folder's files for rules that never get them.
struct RuleCheckSheet: View {
    @EnvironmentObject var model: AppModel
    let onSuggestOrder: () -> Void
    let onDailyInbox: () -> Void
    let onClose: () -> Void

    @State private var shadowed: [RuleDiagnostic]?
    @State private var isScanning = false
    @State private var scanTask: Task<Void, Never>?

    private var folderName: String {
        model.folders.first { $0.id == model.selectedFolderId }.map { ($0.path as NSString).lastPathComponent } ?? ""
    }

    private var diagnostics: [RuleDiagnostic] {
        (model.selectedFolderDiagnostics + (shadowed ?? []))
            .sorted { $0.severity > $1.severity }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewHeader(
                title: "Check Rules",
                subtitle: String(localized: "How the rules in \(folderName) work together"),
                systemImage: "checklist"
            )

            HStack(spacing: 8) {
                Button {
                    scan()
                } label: {
                    if isScanning {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Checking files…")
                        }
                    } else {
                        Label(shadowed == nil ? "Check Files in Folder" : "Check Files Again", systemImage: "doc.text.magnifyingglass")
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(isScanning)
                .help("Looks at up to 300 files here to find rules that never get them because a rule above takes them first. Nothing is changed.")

                Button("Suggest Order…", action: onSuggestOrder)
                    .buttonStyle(SecondaryButtonStyle())
                Button("Set Up Daily Inbox…", action: onDailyInbox)
                    .buttonStyle(SecondaryButtonStyle())
                Spacer()
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if diagnostics.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "checkmark.seal")
                                .font(.system(size: 22))
                                .foregroundStyle(ForelTheme.success)
                            Text(shadowed == nil
                                 ? "No problems found in the rules themselves. Check the files too to find rules that never get them."
                                 : "No problems found.")
                                .font(.system(size: 12))
                                .foregroundStyle(ForelTheme.secondaryText)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    }
                    ForEach(diagnostics) { diagnostic in
                        DiagnosticRow(diagnostic: diagnostic) {
                            guard let ruleId = diagnostic.ruleIds.first else { return }
                            let folderId = model.allRules().first { $0.rule.id == ruleId }?.folder.id ?? diagnostic.folderId
                            onClose()
                            model.reveal(ruleId: ruleId, inFolder: folderId)
                        }
                    }
                }
            }
            .scrollIndicators(.never)

            HStack {
                Spacer()
                Button("Done", action: onClose)
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 640, height: 560)
        .background(ForelTheme.background)
        .onAppear { model.refreshRuleDiagnostics() }
        .onDisappear { scanTask?.cancel() }
    }

    private func scan() {
        isScanning = true
        scanTask = Task {
            let found = await model.findShadowedRules()
            guard !Task.isCancelled else { return }
            shadowed = found
            isScanning = false
        }
    }
}

private struct DiagnosticRow: View {
    let diagnostic: RuleDiagnostic
    let onShowRule: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: diagnostic.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(diagnostic.severity == .warning ? Color.orange : ForelTheme.accent)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(diagnostic.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ForelTheme.primaryText)
                Text(diagnostic.message)
                    .font(.system(size: 11))
                    .foregroundStyle(ForelTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .textSelection(.enabled)
            Spacer(minLength: 8)
            if !diagnostic.ruleIds.isEmpty {
                Button("Show Rule", action: onShowRule)
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

// MARK: - Folder flow map

/// Each watched folder with where its rules send files: on to another
/// watched folder (whose rules run next), elsewhere, or to the Trash. Loops
/// between watched folders are marked.
struct FolderFlowSheet: View {
    @EnvironmentObject var model: AppModel
    let onClose: () -> Void

    @State private var nodes: [FolderFlow.Node] = []
    @AppStorage("folderFlowShowsDiagram") private var showsDiagram = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewHeader(
                title: "Folder Flow",
                subtitle: "Where each watched folder's rules send files",
                systemImage: "point.3.connected.trianglepath.dotted"
            ) {
                Picker("", selection: $showsDiagram) {
                    Label("Diagram", systemImage: "point.3.connected.trianglepath.dotted").tag(true)
                    Label("List", systemImage: "list.bullet").tag(false)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
            if showsDiagram {
                FolderFlowDiagram(nodes: nodes, name: name(of:))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
                HStack(spacing: 14) {
                    legend(color: ForelTheme.accent, dashed: false, text: "Rule sends files")
                    legend(color: ForelTheme.accent, dashed: true, text: "Rule is turned off")
                    legend(color: .orange, dashed: false, text: "Loop")
                    Spacer()
                }
                .font(.system(size: 11))
                .foregroundStyle(ForelTheme.secondaryText)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(nodes) { node in
                            FolderFlowCard(node: node, name: name(of:), onShowRule: { ruleId in
                                onClose()
                                model.reveal(ruleId: ruleId, inFolder: node.folder.id)
                            })
                        }
                    }
                }
                .scrollIndicators(.never)
            }
            HStack {
                Text("Rules that are turned off are shown dimmed. Destinations with tokens show the part before the first token.")
                    .font(.system(size: 11))
                    .foregroundStyle(ForelTheme.secondaryText)
                Spacer()
                Button("Done", action: onClose)
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 760, height: 560)
        .background(ForelTheme.background)
        .onAppear {
            let pairs = model.allRules()
            let rulesByFolder = Dictionary(grouping: pairs, by: { $0.folder.id }).mapValues { $0.map(\.rule) }
            nodes = FolderFlow.map(folders: model.folders, rulesByFolder: rulesByFolder)
        }
    }

    private func legend(color: Color, dashed: Bool, text: String) -> some View {
        HStack(spacing: 5) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 5))
                path.addLine(to: CGPoint(x: 22, y: 5))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, dash: dashed ? [5, 4] : []))
            .frame(width: 22, height: 10)
            Text(localized(text))
        }
    }

    private func name(of folderId: String) -> String {
        model.folders.first { $0.id == folderId }.map { ($0.path as NSString).lastPathComponent } ?? folderId
    }
}

private struct FolderFlowCard: View {
    let node: FolderFlow.Node
    let name: (String) -> String
    let onShowRule: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: node.folder.enabled ? "folder.fill" : "folder")
                    .foregroundStyle(ForelTheme.accent)
                Text((node.folder.path as NSString).lastPathComponent)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ForelTheme.primaryText)
                Text(node.folder.path)
                    .font(.system(size: 11))
                    .foregroundStyle(ForelTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
            }
            if !node.incomingFrom.isEmpty {
                Label {
                    Text(localized("Receives files from") + " " + node.incomingFrom.map(name).joined(separator: ", "))
                } icon: {
                    Image(systemName: "arrow.down.right")
                }
                .font(.system(size: 11))
                .foregroundStyle(ForelTheme.secondaryText)
            }
            if node.outgoing.isEmpty {
                Text("Files stay in this folder.")
                    .font(.system(size: 11))
                    .foregroundStyle(ForelTheme.secondaryText)
            }
            ForEach(node.outgoing) { step in
                HStack(spacing: 8) {
                    Image(systemName: icon(for: step.destination))
                        .frame(width: 16)
                        .foregroundStyle(step.inLoop ? Color.orange : ForelTheme.accent)
                    Text(destinationText(step.destination))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(ForelTheme.primaryText)
                        .textSelection(.enabled)
                    Text("· \(localized(step.action.label)) · “\(step.ruleName)”")
                        .font(.system(size: 11))
                        .foregroundStyle(ForelTheme.secondaryText)
                        .lineLimit(1)
                    if step.inLoop {
                        Text("Loop")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.orange)
                            .help("Files can come back here from that folder and go around in a circle. Check Rules explains how to fix it.")
                    }
                    Spacer()
                    Button("Show Rule") { onShowRule(step.ruleId) }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                }
                .opacity(step.ruleEnabled ? 1 : 0.5)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func icon(for destination: FolderFlow.Destination) -> String {
        switch destination {
        case .watched: return "arrow.right.circle.fill"
        case .elsewhere: return "arrow.up.right.square"
        case .trash: return "trash"
        case .removed: return "xmark.bin"
        }
    }

    private func destinationText(_ destination: FolderFlow.Destination) -> String {
        switch destination {
        case .watched(let folderId): return "→ " + name(folderId)
        case .elsewhere(let path): return "→ " + (path as NSString).abbreviatingWithTildeInPath
        case .trash: return "→ " + localized("Trash")
        case .removed: return localized("Deleted or uploaded")
        }
    }
}

// MARK: - Suggest Order

/// Shows the folder's rules in the suggested order next to why, and
/// applies it (with Undo) on request.
struct SuggestOrderSheet: View {
    @EnvironmentObject var model: AppModel
    let onClose: () -> Void

    @State private var previousOrder: [String]?

    private var suggested: [Rule] { RuleDiagnostics.suggestedOrder(model.rules) }
    private var isAlreadyInOrder: Bool { suggested.map(\.id) == model.rules.map(\.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewHeader(
                title: "Suggest Order",
                subtitle: "Rules run top to bottom; a rule that moves a file stops the ones below it",
                systemImage: "arrow.up.arrow.down"
            )

            Text("Suggested: cleanup first, then rules that only tag or label, then rules that move files from the most specific (content, origin, name pattern) to the broadest (only age or size).")
                .font(.system(size: 11))
                .foregroundStyle(ForelTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(Array(suggested.enumerated()), id: \.element.id) { index, rule in
                        let currentIndex = model.rules.firstIndex { $0.id == rule.id } ?? index
                        HStack(spacing: 10) {
                            Text("\(index + 1)")
                                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                .foregroundStyle(ForelTheme.secondaryText)
                                .frame(width: 22, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rule.name)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(rule.enabled ? ForelTheme.primaryText : ForelTheme.secondaryText)
                                Text(reason(rule))
                                    .font(.system(size: 10))
                                    .foregroundStyle(ForelTheme.secondaryText)
                            }
                            Spacer()
                            if currentIndex != index {
                                Label("was \(currentIndex + 1)", systemImage: currentIndex > index ? "arrow.up" : "arrow.down")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(ForelTheme.accent)
                            }
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
                    }
                }
            }
            .scrollIndicators(.never)

            HStack(spacing: 8) {
                if let previousOrder {
                    Text("Order applied.")
                        .font(.system(size: 11))
                        .foregroundStyle(ForelTheme.secondaryText)
                    Button("Undo") {
                        model.reorderRules(previousOrder)
                        self.previousOrder = nil
                    }
                    .buttonStyle(SecondaryButtonStyle())
                } else if isAlreadyInOrder {
                    Text("The rules are already in this order.")
                        .font(.system(size: 11))
                        .foregroundStyle(ForelTheme.secondaryText)
                }
                Spacer()
                Button("Close", action: onClose)
                    .buttonStyle(SecondaryButtonStyle())
                Button("Apply Order") {
                    previousOrder = model.rules.map(\.id)
                    model.reorderRules(suggested.map(\.id))
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isAlreadyInOrder)
            }
        }
        .padding(16)
        .frame(width: 560, height: 560)
        .background(ForelTheme.background)
    }

    private func reason(_ rule: Rule) -> String {
        let tier = RuleDiagnostics.specificity(rule)
        if tier == .cleanup { return "Cleanup or ignore" }
        guard RuleDiagnostics.takesFileAway(rule) else { return "Only tags, labels or runs something; doesn't move the file" }
        switch tier {
        case .cleanup: return "Cleanup or ignore"
        case .precise: return "Moves files picked by content, origin or name pattern"
        case .byType: return "Moves files picked by type or extension"
        case .catchAll: return "Moves files picked only by age, size or nothing; goes last"
        }
    }
}

// MARK: - Daily Inbox

/// Sets up a daily inbox: new files go to one folder and the sorting rules
/// wait there before moving them to their final place.
struct DailyInboxSheet: View {
    @EnvironmentObject var model: AppModel
    let onClose: () -> Void

    @State private var inboxName = "_Hoje"
    @State private var days = 1
    @State private var choices: [String: DailyInbox.Choice] = [:]

    private var source: WatchedFolder? {
        model.folders.first { $0.id == model.selectedFolderId }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewHeader(
                title: "Set Up Daily Inbox",
                subtitle: "Keep new files in one folder for a while, then sort them",
                systemImage: "tray.and.arrow.down"
            )

            if let source {
                Text("New files in \((source.path as NSString).lastPathComponent) go to the inbox folder right away. The rules you move there wait until a file has been in the inbox for the time below, then put it in its final place. \(recheckNote)")
                    .font(.system(size: 11))
                    .foregroundStyle(ForelTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 16) {
                    HStack(spacing: 6) {
                        Text("Inbox folder")
                            .font(.system(size: 12))
                        TextField("_Hoje", text: $inboxName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 140)
                    }
                    Stepper(value: $days, in: 1...30) {
                        Text("Wait \(days) day\(days == 1 ? "" : "s")")
                            .font(.system(size: 12))
                    }
                    Spacer()
                }

                Text((source.path as NSString).appendingPathComponent(inboxName))
                    .font(.system(size: 10))
                    .foregroundStyle(ForelTheme.secondaryText)
                    .textSelection(.enabled)

                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(model.rules, id: \.id) { rule in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(rule.name)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(rule.enabled ? ForelTheme.primaryText : ForelTheme.secondaryText)
                                    if !DailyInbox.canWait(rule) {
                                        Text("Its conditions can't take a wait (“none of these”), so it stays here.")
                                            .font(.system(size: 10))
                                            .foregroundStyle(ForelTheme.secondaryText)
                                    }
                                }
                                Spacer()
                                Picker("", selection: binding(for: rule)) {
                                    Text("Move to inbox").tag(DailyInbox.Choice.moveToInbox)
                                        .disabled(!DailyInbox.canWait(rule))
                                    Text("Keep here").tag(DailyInbox.Choice.keepHere)
                                    Text("Turn off").tag(DailyInbox.Choice.turnOff)
                                }
                                .labelsHidden()
                                .frame(width: 150)
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 10)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
                        }
                    }
                }
                .scrollIndicators(.never)

                Text("“Keep here” rules still act right away (for example removing duplicates). A new rule at the bottom sends everything else to the inbox. Rules you turn off stay in the list so you can turn them back on.")
                    .font(.system(size: 10))
                    .foregroundStyle(ForelTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onClose)
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Set Up Inbox") {
                    guard let source else { return }
                    if model.setUpDailyInbox(source: source, inboxName: inboxName, days: days, choices: resolvedChoices) != nil {
                        onClose()
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(source == nil || inboxName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 600, height: 600)
        .background(ForelTheme.background)
    }

    private var recheckNote: String {
        model.recheckIntervalMinutes > 0
            ? String(localized: "Forel checks waiting files every \(model.recheckIntervalMinutes) minutes.")
            : "Turn on the periodic re-check in Settings, or waiting files are only sorted by Run Now."
    }

    private var resolvedChoices: [String: DailyInbox.Choice] {
        Dictionary(uniqueKeysWithValues: model.rules.map { ($0.id, choices[$0.id] ?? DailyInbox.defaultChoice(for: $0)) })
    }

    private func binding(for rule: Rule) -> Binding<DailyInbox.Choice> {
        Binding(
            get: { choices[rule.id] ?? DailyInbox.defaultChoice(for: rule) },
            set: { choices[rule.id] = $0 }
        )
    }
}
