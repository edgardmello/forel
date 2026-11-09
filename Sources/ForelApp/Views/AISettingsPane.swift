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
import UniformTypeIdentifiers
import ForelCore

/// Settings → AI: "Generate Code" in script actions and "Review with AI" in
/// the rule editor. Off by default; nothing is sent anywhere until the user
/// presses one of them.
struct AISettingsPane: View {
    @EnvironmentObject var model: AppModel
    @State private var apiKey = ""
    @State private var keySaved = false
    @State private var showingModels = false
    @State private var confirmingForget = false
    /// What the last export or import did, or why it failed.
    @State private var transferStatus: (text: String, failed: Bool)?

    var body: some View {
        Group {
            SectionLabel(title: "AI Features")
            GlassCard {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Write scripts and review rules with AI")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(ForelTheme.primaryText)
                        Text("Adds Generate Code to script actions and Review with AI to the rule editor and the rule list's right-click menu. They run only when you press them.")
                            .font(.system(size: 11))
                            .foregroundStyle(ForelTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("AI features", isOn: enabledBinding)
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

                SectionLabel(title: "Review Memory")
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Remember reviews")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(ForelTheme.primaryText)
                                Text("Forel keeps, on this Mac, what you asked for in each Review with AI, the suggestions you applied or turned down, your replies and the rule you saved. New reviews of similar rules send the most relevant of these along, so the AI follows your preferences and reuses what worked.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(ForelTheme.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Toggle("Remember reviews", isOn: Binding(get: { model.rememberReviews }, set: model.setRememberReviews))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                        }
                        HStack {
                            Text(model.rememberedReviewCount == 0
                                 ? "No reviews remembered."
                                 : "\(model.rememberedReviewCount) review\(model.rememberedReviewCount == 1 ? "" : "s") remembered (up to \(RuleReviewMemory.maximumStoredRecords); the oldest are forgotten first).")
                                .font(.system(size: 11))
                                .foregroundStyle(ForelTheme.secondaryText)
                            Spacer()
                            Button("Import…", action: importReviews)
                                .help("Add the reviews exported from another Mac; ones this Mac already has keep their newest version")
                            Button("Export…", action: exportReviews)
                                .disabled(model.rememberedReviewCount == 0)
                                .help("Save the remembered reviews to a file, to import them on another Mac")
                            Button("Forget Reviews…") { confirmingForget = true }
                                .disabled(model.rememberedReviewCount == 0)
                        }
                        if let transferStatus {
                            Text(transferStatus.text)
                                .font(.system(size: 11))
                                .foregroundStyle(transferStatus.failed ? ForelTheme.danger : ForelTheme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(14)
                }
                .alert(
                    "Forget \(model.rememberedReviewCount) remembered review\(model.rememberedReviewCount == 1 ? "" : "s")?",
                    isPresented: $confirmingForget
                ) {
                    Button("Forget Reviews", role: .destructive) { model.forgetReviews() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Review with AI will no longer know the goals, replies and decisions of your earlier reviews, and can't be given them back. Your rules aren't changed.")
                }

                SectionLabel(title: "Privacy")
                GlassCard {
                    Text("""
                    When you press Generate Code, Forel sends your description, the script language, your macOS version, \
                    and the names of the command-line tools installed on this Mac (such as exiftool or ffmpeg), so the \
                    script uses commands that work here. Generate Code never sends file names, paths, file contents, or your rules.

                    When you press Review with AI, Forel sends that rule (its conditions, actions, folder paths and scripts, \
                    with upload passwords removed), the watched folder's path, the folder's other rules and your macOS \
                    version, the goal you describe for the rule, and, when you apply suggestions or reply to the AI, the ones you chose and what you wrote. With Remember reviews on, it also sends what you decided in up to four similar earlier reviews: their goals, the titles of the suggestions you applied or turned down, your replies and the rules you saved, which can include other folders' paths. It never sends the names or contents of your files.

                    The API key is kept in your Keychain. Read a generated script or a suggested rule before saving: it runs with your permissions.
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

    private func exportReviews() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: RuleReviewMemoryTransfer.fileExtension) ?? .json]
        panel.nameFieldStringValue = "Forel Review Memory.\(RuleReviewMemoryTransfer.fileExtension)"
        panel.prompt = "Export"
        panel.message = "The file holds your review goals, replies and rules (without upload passwords). Keep it private."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let count = try model.exportReviews(to: url)
            transferStatus = ("Exported \(count) review\(count == 1 ? "" : "s") to “\(url.lastPathComponent)”. On your other Mac, choose Import… here.", false)
        } catch {
            transferStatus = ("Couldn't export the reviews: \(error.localizedDescription)", true)
        }
    }

    private func importReviews() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: RuleReviewMemoryTransfer.fileExtension) ?? .json, .json]
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let count = try model.importReviews(from: url)
            transferStatus = (count == 0
                ? "Nothing new: this Mac already remembers every review in “\(url.lastPathComponent)”."
                : "Imported \(count) review\(count == 1 ? "" : "s") from “\(url.lastPathComponent)”.", false)
        } catch let error as RuleReviewMemoryTransfer.ImportError {
            transferStatus = (error.description, true)
        } catch {
            transferStatus = ("Couldn't import the reviews: \(error.localizedDescription)", true)
        }
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
