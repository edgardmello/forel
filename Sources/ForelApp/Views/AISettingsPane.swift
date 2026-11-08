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

/// Settings → AI: "Generate Code" in script actions. Off by default; nothing
/// is sent anywhere until the user presses Generate Code.
struct AISettingsPane: View {
    @EnvironmentObject var model: AppModel
    @State private var apiKey = ""
    @State private var keySaved = false
    @State private var showingModels = false

    var body: some View {
        Group {
            SectionLabel(title: "Generate Code")
            GlassCard {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Write scripts from a description")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(ForelTheme.primaryText)
                        Text("Adds a Generate Code button to script actions. It runs only when you press it.")
                            .font(.system(size: 11))
                            .foregroundStyle(ForelTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("Generate Code", isOn: enabledBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
            }

            if model.aiSettings.enabled {
                SectionLabel(title: "Service")
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        row("Service") {
                            Picker("Service", selection: providerBinding) {
                                ForEach(AIProvider.allCases, id: \.self) { provider in
                                    Text(provider.label).tag(provider)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                        row("Address") {
                            GlassField(placeholder: "https://…/v1", text: baseURLBinding)
                        }
                        row("Model") {
                            HStack(spacing: 6) {
                                GlassField(placeholder: "Model ID", text: modelBinding)
                                Button {
                                    showingModels = true
                                } label: {
                                    Image(systemName: "chevron.up.chevron.down")
                                }
                                .help("Choose from the models this service offers")
                                .accessibilityLabel("Choose a model")
                                .popover(isPresented: $showingModels, arrowEdge: .bottom) {
                                    AIModelListPopover(
                                        settings: model.aiSettings,
                                        apiKey: apiKey,
                                        selected: model.aiSettings.model
                                    ) { id in
                                        model.updateAISettings { $0.model = id }
                                        showingModels = false
                                    }
                                }
                            }
                        }
                        row("API key") {
                            HStack {
                                SecureField("Paste your API key", text: $apiKey)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit(saveKey)
                                Button(keySaved ? "Saved" : "Save", action: saveKey)
                                    .disabled(keySaved)
                            }
                        }
                        if let url = model.aiSettings.provider.keyPageURL {
                            Link("Get an API key…", destination: url)
                                .font(.system(size: 11))
                        }
                    }
                    .padding(14)
                }

                SectionLabel(title: "Privacy")
                GlassCard {
                    Text("""
                    When you press Generate Code, Forel sends your description, the script language, your macOS version, \
                    and the names of the command-line tools installed on this Mac (such as exiftool or ffmpeg), so the \
                    script uses commands that work here. It never sends file names, paths, file contents, or your rules. \
                    The API key is kept in your Keychain. Read a generated script before saving the rule: it runs with your permissions.
                    """)
                    .font(.system(size: 11))
                    .foregroundStyle(ForelTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(14)
                }
            }
        }
        .onAppear(perform: loadKey)
        .onChange(of: model.aiSettings.provider) { _ in loadKey() }
        .onChange(of: apiKey) { _ in keySaved = apiKey == AIKeychain.key(for: model.aiSettings.provider.rawValue) && !apiKey.isEmpty }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(ForelTheme.primaryText)
                .frame(width: 70, alignment: .leading)
            content()
        }
    }

    private func loadKey() {
        apiKey = AIKeychain.key(for: model.aiSettings.provider.rawValue)
        keySaved = !apiKey.isEmpty
    }

    private func saveKey() {
        if AIKeychain.setKey(apiKey, for: model.aiSettings.provider.rawValue) {
            keySaved = !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } else {
            model.alertTitle = "Couldn't save the API key"
            model.errorMessage = "macOS didn't let Forel store the key in your Keychain. Check Keychain Access, then try again."
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { model.aiSettings.enabled }, set: { value in model.updateAISettings { $0.enabled = value } })
    }

    private var providerBinding: Binding<AIProvider> {
        Binding(
            get: { model.aiSettings.provider },
            set: { provider in
                model.updateAISettings { settings in
                    settings.provider = provider
                    settings.baseURL = provider.defaultBaseURL
                    settings.model = provider.defaultModel
                }
            }
        )
    }

    private var baseURLBinding: Binding<String> {
        Binding(get: { model.aiSettings.baseURL }, set: { value in model.updateAISettings { $0.baseURL = value } })
    }

    private var modelBinding: Binding<String> {
        Binding(get: { model.aiSettings.model }, set: { value in model.updateAISettings { $0.model = value } })
    }
}

/// The models the service offers, fetched when the popover opens. Typing a
/// model ID in the field keeps working for services that don't list them.
private struct AIModelListPopover: View {
    let settings: AISettings
    let apiKey: String
    let selected: String
    let choose: (String) -> Void

    @State private var models: [String]?
    @State private var errorMessage: String?
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(ForelTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Button("Try Again") { Task { await load() } }
            } else if let models {
                TextField("Filter", text: $filter)
                    .textFieldStyle(.roundedBorder)
                let shown = filtered(models)
                if shown.isEmpty {
                    Text("No models match “\(filter)”.")
                        .font(.system(size: 12))
                        .foregroundStyle(ForelTheme.secondaryText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(shown, id: \.self) { id in
                                Button { choose(id) } label: {
                                    HStack {
                                        Image(systemName: "checkmark")
                                            .opacity(id == selected ? 1 : 0)
                                        Text(id)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer(minLength: 0)
                                    }
                                    .font(.system(size: 12))
                                    .padding(.vertical, 4)
                                    .padding(.horizontal, 6)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            } else {
                ProgressView("Loading models…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(12)
        .frame(width: 300, height: errorMessage == nil ? 320 : nil)
        .task { await load() }
    }

    private func filtered(_ models: [String]) -> [String] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return models }
        return models.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    private func load() async {
        errorMessage = nil
        models = nil
        do {
            models = try await ScriptGenerator.listModels(settings: settings, apiKey: apiKey)
        } catch let error as ScriptGenerationError {
            errorMessage = error.message
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
