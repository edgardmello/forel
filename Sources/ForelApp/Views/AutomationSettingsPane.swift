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

/// Settings → Automation: the periodic re-check of time-dependent rules,
/// Trash cleanup, and the `forel://` links other apps can use.
struct AutomationSettingsPane: View {
    @EnvironmentObject var model: AppModel
    @State private var pendingPolicy: TrashCleanupPolicy?
    @State private var pendingPreview: [TrashItem] = []
    @State private var trashError: String?
    @State private var isPreparing = false

    var body: some View {
        Group {
            SectionLabel(title: "Re-check rules")
            GlassCard {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Re-check").font(.system(size: 13, weight: .semibold)).foregroundStyle(ForelTheme.primaryText)
                        Text("For rules using “is older than”, “is within the last” or “Date last matched”")
                            .font(.system(size: 11))
                            .foregroundStyle(ForelTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Picker("Re-check", selection: recheckBinding) {
                        ForEach(AppModel.recheckIntervalChoices, id: \.self) { minutes in
                            Text(Self.intervalLabel(minutes)).tag(minutes)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                Divider().overlay(ForelTheme.divider).padding(.leading, 14)
                SettingsActionRow(
                    title: "Re-check now",
                    subtitle: model.paused
                        ? "Automatic watching is paused, so nothing is re-checked"
                        : "A rule never repeats on a file it already handled, unless the file changed",
                    buttonTitle: "Re-check Now",
                    action: { model.recheckNow() }
                )
                .disabled(model.paused)
            }

            SectionLabel(title: "Trash")
            GlassCard {
                trashLimitRow(
                    title: "Delete items in the Trash after",
                    isOn: model.trashCleanupPolicy.maxAgeDays != nil,
                    value: model.trashCleanupPolicy.maxAgeDays ?? 30,
                    range: 1...365,
                    unit: { $0 == 1 ? "day" : "days" },
                    toggle: { enabled, value in
                        var policy = model.trashCleanupPolicy
                        policy.maxAgeDays = enabled ? value : nil
                        return policy
                    }
                )
                Divider().overlay(ForelTheme.divider).padding(.leading, 14)
                trashLimitRow(
                    title: "Keep the Trash under",
                    isOn: model.trashCleanupPolicy.maxSizeBytes != nil,
                    value: model.trashCleanupPolicy.maxSizeBytes.map { Int($0 / 1_073_741_824) } ?? 5,
                    range: 1...500,
                    unit: { _ in "GB" },
                    toggle: { enabled, value in
                        var policy = model.trashCleanupPolicy
                        policy.maxSizeBytes = enabled ? UInt64(value) * 1_073_741_824 : nil
                        return policy
                    }
                )
                Divider().overlay(ForelTheme.divider).padding(.leading, 14)
                Text("Items Forel removes from the Trash are deleted permanently and listed in Activity. Forel checks every hour.")
                    .font(.system(size: 11))
                    .foregroundStyle(ForelTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 14)
                if let message = trashError ?? model.trashCleanupError {
                    Divider().overlay(ForelTheme.divider).padding(.leading, 14)
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(message)
                                .font(.system(size: 11))
                                .foregroundStyle(ForelTheme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                            Button("Open Full Disk Access Settings…") { Self.openFullDiskAccessSettings() }
                                .font(.system(size: 11))
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 14)
                }
            }

            SectionLabel(title: "Links")
            GlassCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Shortcuts (Open URLs), Raycast, Alfred and scripts can control Forel with these links:")
                        .font(.system(size: 11))
                        .foregroundStyle(ForelTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(ForelURLCommand.examples, id: \.url) { example in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(example.url)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(ForelTheme.primaryText)
                                .textSelection(.enabled)
                            Text(example.summary)
                                .font(.system(size: 11))
                                .foregroundStyle(ForelTheme.secondaryText)
                        }
                    }
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
            }
        }
        .alert(
            "Permanently delete items from the Trash?",
            isPresented: Binding(get: { pendingPolicy != nil }, set: { if !$0 { pendingPolicy = nil } })
        ) {
            Button("Turn On and Delete", role: .destructive) {
                if let pendingPolicy {
                    model.setTrashCleanupPolicy(pendingPolicy)
                    model.runTrashCleanup()
                }
                pendingPolicy = nil
            }
            Button("Cancel", role: .cancel) { pendingPolicy = nil }
        } message: {
            Text(confirmationMessage)
        }
    }

    private var confirmationMessage: String {
        let total = pendingPreview.reduce(UInt64(0)) { $0 + $1.sizeBytes }
        let size = ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
        let now = pendingPreview.isEmpty
            ? "Nothing in the Trash matches yet."
            : "\(pendingPreview.count) item\(pendingPreview.count == 1 ? "" : "s") (\(size)) will be deleted right away."
        return "\(now) From then on, Forel deletes items as they reach the limit. Deleted items can't be recovered."
    }

    private func trashLimitRow(
        title: String,
        isOn: Bool,
        value: Int,
        range: ClosedRange<Int>,
        unit: @escaping (Int) -> String,
        toggle: @escaping (Bool, Int) -> TrashCleanupPolicy
    ) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(ForelTheme.primaryText)
            Spacer()
            Stepper(
                "\(value) \(unit(value))",
                value: Binding(get: { value }, set: { newValue in
                    let policy = toggle(isOn, newValue)
                    // A stricter limit deletes more, so it is confirmed
                    // like turning the limit on; a looser one is not.
                    if isOn, newValue < value { confirm(policy) } else if isOn { model.setTrashCleanupPolicy(policy) }
                }),
                in: range
            )
            .font(.system(size: 12))
            .fixedSize()
            .disabled(!isOn)
            ForelSwitch(isOn: Binding(get: { isOn }, set: { enabled in
                let policy = toggle(enabled, value)
                if enabled { confirm(policy) } else { model.setTrashCleanupPolicy(policy) }
            }), compact: true)
            .disabled(isPreparing)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
    }

    /// Shows what the policy deletes right away before saving it.
    private func confirm(_ policy: TrashCleanupPolicy) {
        isPreparing = true
        Task {
            defer { isPreparing = false }
            switch await model.trashCleanupPreview(policy) {
            case .success(let items):
                trashError = nil
                pendingPreview = items
                pendingPolicy = policy
            case .failure(let error):
                trashError = error.localizedDescription
            }
        }
    }

    private var recheckBinding: Binding<Int> {
        Binding(get: { model.recheckIntervalMinutes }, set: { model.setRecheckIntervalMinutes($0) })
    }

    static func intervalLabel(_ minutes: Int) -> String {
        switch minutes {
        case 0: return "Off"
        case 60: return "Every hour"
        case let m where m % 60 == 0: return "Every \(m / 60) hours"
        default: return "Every \(minutes) minutes"
        }
    }

    private static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
