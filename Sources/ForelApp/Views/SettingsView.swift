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

/// Modern macOS Settings layout: a category sidebar on the left (matching
/// System Settings' own convention), detail content on the right — instead
/// of one long scrolling list of sections.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var updater: UpdaterManager
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var hasLoadedLoginState = false
    @State private var loginItemError: String?
    @State private var selectedCategory: SettingsCategory = .general

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(ForelTheme.divider)
            detail
        }
        .frame(width: 600, height: 440)
        .background(ForelTheme.background)
        .navigationTitle("Settings")
        .onAppear { refreshLaunchAtLoginState() }
        .alert("Couldn't change Start at login", isPresented: loginItemErrorBinding) {
            Button("Open Login Items Settings…") { LoginItem.openSystemSettings() }
            Button("OK", role: .cancel) {}
        } message: {
            Text(loginItemError ?? "")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsCategory.allCases) { category in
                SettingsSidebarRow(
                    category: category,
                    isSelected: selectedCategory == category,
                    action: { selectedCategory = category }
                )
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: 170, alignment: .top)
    }

    @ViewBuilder
    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch selectedCategory {
                case .general:
                    generalPane
                case .automation:
                    AutomationSettingsPane()
                case .permissions:
                    PermissionsSection()
                case .updates:
                    updatesPane
                case .about:
                    aboutPane
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var generalPane: some View {
        Group {
            SectionLabel(title: "Appearance")
            GlassCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Accent color").font(.system(size: 13)).foregroundStyle(ForelTheme.primaryText)
                    AccentColorPicker(selection: accentBinding)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
            }

            SectionLabel(title: "General")
            GlassCard {
                ToggleRow(
                    title: "Automatic watching",
                    subtitle: model.paused ? "Paused — new files are ignored" : "Watching folders — rules run automatically",
                    isOn: watchingBinding
                )
                Divider().overlay(ForelTheme.divider).padding(.leading, 14)
                ToggleRow(
                    title: "Start at login",
                    subtitle: "Open Forel automatically when you log in",
                    isOn: launchAtLoginBinding
                )
                if let warning = loginItemWarning {
                    LoginItemWarningRow(message: warning)
                }
                Divider().overlay(ForelTheme.divider).padding(.leading, 14)
                ToggleRow(
                    title: "Show Dock icon",
                    subtitle: "Keep Forel visible in the Dock while it runs",
                    isOn: dockIconBinding
                )
                Divider().overlay(ForelTheme.divider).padding(.leading, 14)
                ToggleRow(
                    title: "Show menu bar icon",
                    subtitle: "Open Forel from Finder or Spotlight when it is hidden",
                    isOn: menuBarIconBinding
                )
                Divider().overlay(ForelTheme.divider).padding(.leading, 14)
                ToggleRow(
                    title: "Watcher notifications",
                    subtitle: "Notify when automatic rules process files",
                    isOn: watcherNotificationsBinding
                )
                Divider().overlay(ForelTheme.divider).padding(.leading, 14)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Keep history for").font(.system(size: 13, weight: .semibold)).foregroundStyle(ForelTheme.primaryText)
                        Spacer()
                        Text("\(model.historyMaxDays) day\(model.historyMaxDays > 1 ? "s" : "")").font(.system(size: 12)).foregroundStyle(ForelTheme.secondaryText)
                    }
                    Slider(value: historyMaxDaysDoubleBinding, in: 1...30, step: 1)
                        .tint(ForelTheme.accent)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
            }
        }
    }

    private var updatesPane: some View {
        Group {
            SectionLabel(title: "Updates")
            if updater.updateAvailable {
                UpdateAvailableBanner(
                    version: updater.latestVersion,
                    isInstalling: updater.isInstalling,
                    action: updater.installUpdate
                )
            }
            GlassCard {
                ToggleRow(
                    title: "Automatic updates",
                    subtitle: "Check for new versions in the background",
                    isOn: automaticUpdatesBinding
                )
                Divider().overlay(ForelTheme.divider).padding(.leading, 14)
                SettingsActionRow(
                    title: "Current version",
                    subtitle: versionSubtitle,
                    buttonTitle: "Check Now",
                    action: { updater.checkForUpdates() }
                )
                .disabled(updater.isChecking || updater.isInstalling || updater.updateAvailable)
            }
        }
    }

    private var aboutPane: some View {
        Group {
            SectionLabel(title: "About")
            GlassCard {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AppInfo.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(ForelTheme.primaryText)
                        Text(AppInfo.tagline).font(.system(size: 11)).foregroundStyle(ForelTheme.secondaryText)
                    }
                    Spacer()
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                Divider().overlay(ForelTheme.divider).padding(.leading, 14)
                aboutRow(title: "Version", value: AppInfo.version)
                Divider().overlay(ForelTheme.divider).padding(.leading, 14)
                aboutRow(title: "Build", value: AppInfo.build)
                if let copyright = AppInfo.copyright {
                    Divider().overlay(ForelTheme.divider).padding(.leading, 14)
                    aboutRow(title: "Copyright", value: copyright)
                }
                Divider().overlay(ForelTheme.divider).padding(.leading, 14)
                HStack {
                    Text("GitHub Repository").font(.system(size: 13)).foregroundStyle(ForelTheme.primaryText)
                    Spacer()
                    Link("lab421/forel", destination: AppInfo.repositoryURL)
                        .font(.system(size: 12))
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
            }
        }
    }

    private func aboutRow(title: String, value: String) -> some View {
        HStack {
            Text(title).font(.system(size: 13)).foregroundStyle(ForelTheme.primaryText)
            Spacer()
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(ForelTheme.secondaryText)
                .textSelection(.enabled)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
    }

    private var accentBinding: Binding<AccentPreset> {
        Binding(get: { model.accentPreset }, set: { model.setAccentPreset($0) })
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(get: { launchAtLogin }, set: { enabled in
            model.setWantsLaunchAtLogin(enabled)
            if LoginItem.isPackagedApp, case .failure(let error) = LoginItem.setEnabled(enabled) {
                loginItemError = "macOS refused the change: \(error.localizedDescription). You can try again, or review Forel under Login Items & Extensions in System Settings."
            }
            refreshLaunchAtLoginState()
        })
    }

    private var loginItemErrorBinding: Binding<Bool> {
        Binding(get: { loginItemError != nil }, set: { if !$0 { loginItemError = nil } })
    }

    /// The toggle shows what macOS will actually do. In a bare dev build
    /// (no packaged .app) registration isn't possible, so there it mirrors
    /// the stored preference instead.
    private func refreshLaunchAtLoginState() {
        launchAtLogin = LoginItem.isPackagedApp ? LoginItem.isEnabled : model.wantsLaunchAtLogin
        hasLoadedLoginState = true
    }

    /// Non-nil when the user wants to start at login but macOS currently
    /// wouldn't launch Forel — the registration was lost (system updates and
    /// cleaner utilities drop them) or is awaiting approval.
    private var loginItemWarning: String? {
        guard hasLoadedLoginState, LoginItem.isPackagedApp,
              model.wantsLaunchAtLogin, !launchAtLogin else { return nil }
        return LoginItem.requiresApproval
            ? "macOS is waiting for your approval. Open Login Items & Extensions in System Settings and allow Forel."
            : "Forel is set to start at login, but macOS has no active registration — a system update or cleaner app may have removed it. Turn this off and back on to fix it."
    }

    private var dockIconBinding: Binding<Bool> {
        Binding(get: { model.showDockIcon }, set: { model.setShowDockIcon($0) })
    }

    private var menuBarIconBinding: Binding<Bool> {
        Binding(get: { model.showMenuBarIcon }, set: { model.setShowMenuBarIcon($0) })
    }

    private var watcherNotificationsBinding: Binding<Bool> {
        Binding(get: { model.watcherNotificationsEnabled }, set: { model.setWatcherNotificationsEnabled($0) })
    }

    private var watchingBinding: Binding<Bool> {
        Binding(get: { !model.paused }, set: { enabled in
            if enabled == model.paused {
                model.togglePaused()
            }
        })
    }

    private var historyMaxDaysBinding: Binding<Int> {
        Binding(get: { model.historyMaxDays }, set: { model.setHistoryMaxDays($0) })
    }

    private var historyMaxDaysDoubleBinding: Binding<Double> {
        Binding(get: { Double(model.historyMaxDays) }, set: { model.setHistoryMaxDays(Int($0)) })
    }

    private var automaticUpdatesBinding: Binding<Bool> {
        Binding(get: { updater.automaticallyChecksForUpdates }, set: { updater.automaticallyChecksForUpdates = $0 })
    }

    private var versionSubtitle: String {
        let current = AppInfo.version
        if updater.isChecking { return "\(current) — Checking…" }
        return current
    }
}

private enum SettingsCategory: CaseIterable, Identifiable {
    case general, automation, permissions, updates, about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .automation: "Automation"
        case .permissions: "Permissions"
        case .updates: "Updates"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape.fill"
        case .automation: "clock.arrow.2.circlepath"
        case .permissions: "lock.shield.fill"
        case .updates: "arrow.triangle.2.circlepath"
        case .about: "info.circle.fill"
        }
    }

    /// A fixed, distinctly-colored badge per category (as in System Settings)
    /// rather than the single theme accent — it's what makes the sidebar
    /// scannable at a glance, so it intentionally doesn't follow the user's
    /// chosen accent color.
    var tint: Color {
        switch self {
        case .general: Color(red: 0.36, green: 0.34, blue: 0.90)
        case .automation: Color(red: 0.55, green: 0.36, blue: 0.85)
        case .permissions: Color(red: 0.95, green: 0.55, blue: 0.13)
        case .updates: Color(red: 0.20, green: 0.70, blue: 0.45)
        case .about: Color(red: 0.31, green: 0.55, blue: 0.95)
        }
    }
}

private struct LoginItemWarningRow: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(ForelTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Login Items Settings…") { LoginItem.openSystemSettings() }
                    .font(.system(size: 11))
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 14)
    }
}

private struct SettingsSidebarRow: View {
    let category: SettingsCategory
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(category.tint)
                    Image(systemName: category.systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 22, height: 22)

                Text(category.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? .white : ForelTheme.primaryText)

                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? ForelTheme.accent : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
