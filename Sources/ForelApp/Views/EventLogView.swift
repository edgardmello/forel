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

/// Everything the watcher noticed this session and what the rules made of
/// it — including files no rule matched, which Action History never shows.
struct EventLogView: View {
    @EnvironmentObject var model: AppModel
    @State private var searchText = ""
    @State private var filter: Filter = .all
    @State private var isConfirmingClear = false

    enum Filter: String, CaseIterable, Identifiable {
        case all, matches, noMatch, errors
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "All Events"
            case .matches: return "Rules Matched"
            case .noMatch: return "No Rule Matched"
            case .errors: return "Problems"
            }
        }

        func includes(_ event: LoggedEvent) -> Bool {
            switch self {
            case .all: return true
            case .matches: return event.kind == .rulesMatched || event.kind == .runNow
            case .noMatch: return event.kind == .noRuleMatched
            case .errors: return event.isError
            }
        }
    }

    private var events: [LoggedEvent] {
        _ = model.eventLogRevision
        let words = searchText.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return model.eventLog.entries().filter { event in
            guard filter.includes(event) else { return false }
            let haystack = ([event.kind.label, event.message, event.path ?? ""] + event.ruleNames).joined(separator: " ")
            return words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    var body: some View {
        let events = self.events
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                GlassField(placeholder: "Filter by file, rule or message", text: $searchText)
                    .frame(maxWidth: 260)
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Button("Clear…") { isConfirmingClear = true }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(model.eventLog.entries().isEmpty)
            }

            if events.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                            EventRow(event: event)
                            if index != events.count - 1 {
                                Divider().overlay(ForelTheme.divider).padding(.leading, 44)
                            }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(ForelTheme.surface))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ForelTheme.surfaceBorder))
                    .textSelection(.enabled)
                }
                .scrollIndicators(.never)
            }

            Text("Shows the last \(model.eventLog.capacity.formatted()) events since Forel opened. Nothing here is saved to disk.")
                .font(.system(size: 10))
                .foregroundStyle(ForelTheme.secondaryText)
        }
        .confirmationDialog("Clear the event log?", isPresented: $isConfirmingClear, titleVisibility: .visible) {
            Button("Clear Event Log", role: .destructive) { model.eventLog.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The events seen since Forel opened are removed from this list. Action History and undo are not affected.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 28))
                .foregroundStyle(ForelTheme.secondaryText)
            Text(model.eventLog.entries().isEmpty ? "No events since Forel opened" : "No events match the filter")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ForelTheme.primaryText)
            Text(model.paused
                 ? "Watching is paused. Resume it, or use Run Now, to see events here."
                 : "Files the watcher sees, and what your rules do with them, appear here as they happen.")
                .font(.system(size: 11))
                .foregroundStyle(ForelTheme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 50)
    }
}

private struct EventRow: View {
    let event: LoggedEvent

    private var tint: Color {
        if event.isError { return .orange }
        switch event.kind {
        case .rulesMatched, .runNow: return ForelTheme.accent
        default: return ForelTheme.secondaryText
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(tint.opacity(0.14))
                Image(systemName: event.kind.iconSystemName)
                    .font(.system(size: 11))
                    .foregroundStyle(tint)
            }
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(event.kind.label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ForelTheme.primaryText)
                    if let path = event.path {
                        Text((path as NSString).lastPathComponent)
                            .font(.system(size: 12))
                            .foregroundStyle(ForelTheme.primaryText)
                            .lineLimit(1)
                    }
                }
                Text(event.message)
                    .font(.system(size: 11))
                    .foregroundStyle(event.isError ? Color.orange : ForelTheme.secondaryText)
                    .lineLimit(3)
                if let path = event.path {
                    Text(path)
                        .font(.system(size: 10))
                        .foregroundStyle(ForelTheme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(path)
                }
            }

            Spacer(minLength: 8)

            Text(event.date.formatted(date: .omitted, time: .standard))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(ForelTheme.secondaryText)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .contextMenu {
            if let path = event.path {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                }
            }
        }
    }
}
