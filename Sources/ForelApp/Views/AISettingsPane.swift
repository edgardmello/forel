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
                            GlassField(placeholder: "Model ID", text: modelBinding)
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
