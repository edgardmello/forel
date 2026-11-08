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

/// "Generate Code" under an embedded script: describe what the script should
/// do and an AI service writes it. Hidden until it's turned on in
/// Settings → AI. The result is shown first and only replaces the script
/// when the user chooses to.
struct GenerateCodeButton: View {
    @EnvironmentObject var model: AppModel
    let language: ScriptLanguage
    @Binding var script: String
    @State private var showing = false

    var body: some View {
        if model.aiSettings.enabled {
            Button {
                showing = true
            } label: {
                Label("Generate Code…", systemImage: "sparkles")
            }
            .controlSize(.small)
            .help("Describe what the script should do, and \(model.aiSettings.provider.label) writes it")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                GenerateCodePopover(
                    language: language,
                    settings: model.aiSettings,
                    hasExistingScript: !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    onUse: { generated in
                        script = generated
                        showing = false
                    }
                )
                .padding(14)
                .frame(width: 420)
            }
        }
    }
}

private struct GenerateCodePopover: View {
    let language: ScriptLanguage
    let settings: AISettings
    let hasExistingScript: Bool
    let onUse: (String) -> Void

    @State private var prompt = ""
    @State private var result = ""
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    private var isGenerating: Bool { task != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Generate Code")
                .font(.system(size: 13, weight: .semibold))
            Text("Describe what to do with each matching file, e.g. “strip the GPS location from photos” or “convert videos to MP4 with ffmpeg”.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("What should the script do?", text: $prompt, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
                .disabled(isGenerating)
                .onSubmit(generate)

            HStack {
                if isGenerating {
                    ProgressView().controlSize(.small)
                    Text("Asking \(settings.provider.label)…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") {
                        task?.cancel()
                        task = nil
                    }
                } else {
                    Text("Sends your description and the names of installed tools — no file names or contents.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Generate Code", action: generate)
                        .keyboardShortcut(.defaultAction)
                        .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if !result.isEmpty {
                Divider()
                Text("Review the script before using it: it runs with your permissions.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(result)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 160)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                HStack {
                    Spacer()
                    Button(hasExistingScript ? "Replace Script" : "Use Script") { onUse(result) }
                }
            }
        }
        .onDisappear { task?.cancel() }
    }

    private func generate() {
        guard !isGenerating else { return }
        error = nil
        let description = prompt
        let apiKey = AIKeychain.key(for: settings.provider.rawValue)
        task = Task {
            do {
                let script = try await ScriptGenerator.generate(
                    description: description,
                    language: language,
                    settings: settings,
                    apiKey: apiKey
                )
                if !Task.isCancelled { result = script }
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
