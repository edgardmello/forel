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

import Foundation
import ForelCore
import Combine
import AppKit
import UserNotifications

private let historyCleanupInterval: TimeInterval = 3600
private let watcherNotificationDelay: Duration = .seconds(5)

/// Central observable state for the SwiftUI app: owns the database, the
/// watcher coordinator, and the in-memory view of folders/rules. Mirrors the
/// surface of the old `useForelStore` Zustand store, but as direct Swift
@MainActor
final class AppModel: ObservableObject {
    /// Which screen the detail pane shows. History is an in-app view reached
    /// from the sidebar; Settings is its own window (see `ForelMacApp`'s
    /// `Settings` scene), matching standard macOS app structure.
    enum DetailRoute { case rules, history }

    struct RunNowMessage: Equatable {
        let text: String
        let hasFailures: Bool
        /// The folder that was run: the result belongs to it, not to
        /// whichever folder is selected later.
        let folderId: String
    }

    @Published var folders: [WatchedFolder] = []
    @Published var selectedFolderId: String?
    @Published var rules: [Rule] = []
    @Published private(set) var ruleRunStats: [RuleRunStats] = []
    @Published var history: [HistoryEntry] = []
    @Published var historyTotalCount: Int = 0
    @Published var historyFolderFilterId: String?
    @Published private(set) var hasMoreHistory = false
    @Published private(set) var isLoadingHistory = false
    @Published var paused: Bool = false
    @Published var alertTitle: String = "Error"
    @Published var errorMessage: String?
    @Published var detailRoute: DetailRoute = .rules
    @Published var accentPreset: AccentPreset = .default
    @Published var showDockIcon: Bool = true
    @Published var showMenuBarIcon: Bool = true
    @Published var wantsLaunchAtLogin = false
    @Published var watcherNotificationsEnabled: Bool = true
    @Published var historyMaxDays: Int = 30
    /// Minutes between re-checks of time-dependent rules; 0 turns them off.
    @Published private(set) var recheckIntervalMinutes: Int = 30
    @Published private(set) var trashCleanupPolicy = TrashCleanupPolicy()
    /// Why the last automatic Trash cleanup couldn't run, if it couldn't.
    @Published private(set) var trashCleanupError: String?
    /// Bumped whenever the accent colour changes, so views can force a full
    /// re-render with `.id(model.accentVersion)` — `ForelTheme.accent` is a
    /// plain static var, not itself observable.
    @Published var accentVersion: Int = 0
    @Published private(set) var isRunningNow = false
    @Published private(set) var runNowMessage: RunNowMessage?
    private var runNowMessageId: UUID?
    @Published private(set) var isPreviewing = false
    @Published var previewResult: PreviewResult?
    /// Dry-run of the draft rule open in the rule editor, driven by
    /// `testRule(_:)` — separate from the folder-wide Dry Run state above.
    @Published private(set) var isTestingRule = false
    @Published var ruleTestResult: PreviewResult?
    private var ruleTestTask: Task<PreviewResult, Never>?
    private var ruleTestGeneration = 0
    @Published var showHazelImportAssistant = false
    @Published private var ruleExpansionPreferences = RuleExpansionPreferences()

    let db: Database
    private let coordinator: WatcherCoordinator
    private let historyPageSize = 200
    private let previewMatchLimit = 500
    private let ruleTestNonMatchSampleLimit = 5
    private let ruleRunStatsWindowDays = 30
    private var historyCleanupTimer: AnyCancellable?
    private var recheckTimer: AnyCancellable?
    private var wakeObserver: NSObjectProtocol?
    private var pendingWatcherNotification = PendingWatcherNotification()
    private var watcherNotificationTask: Task<Void, Never>?
    private var volumeNotifier = VolumeUnavailableNotifier()
    private var volumeNotificationTask: Task<Void, Never>?
    private var volumeMountObserver: NSObjectProtocol?
    /// Bumped when automatic runs record history, for views showing recent
    /// activity. A burst of files makes one bump, not one per file.
    @Published private(set) var watcherHistoryRevision = 0
    private var watcherHistoryRevisionTask: Task<Void, Never>?
        private let hazelAppURL: URL?

    /// Forel's Application Support folder, migrated from the legacy location
    /// and created if needed. Separate from `init` so the single-instance
    /// lock can be taken there before the database is opened.
    static func prepareAppSupportDirectory() throws -> URL {
        let appSupportRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let appSupport = appSupportRoot.appendingPathComponent("com.lab421.forel", isDirectory: true)
        migrateLegacyAppSupportDirectoryIfNeeded(root: appSupportRoot, newDirectory: appSupport)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return appSupport
    }

    init(appSupport: URL) throws {
        let dbPath = appSupport.appendingPathComponent("forel.db").path

        let db = try Database(path: dbPath)
        self.db = db
        RuleMatchMemory.shared.attach(db)
        self.hazelAppURL = Self.locateHazel()
        self.coordinator = WatcherCoordinator(db: db)
        self.coordinator.onActivity = { [weak self] summary in
            Task { @MainActor in
                self?.queueWatcherNotification(summary)
            }
        }
        self.coordinator.onVolumeUnavailable = { [weak self] event in
            Task { @MainActor in
                self?.queueVolumeNotification(event)
            }
        }
        self.coordinator.onHistoryRecorded = { [weak self] in
            Task { @MainActor in
                self?.bumpWatcherHistoryRevision()
            }
        }
        // Default to paused (watching off) on a fresh install — a brand-new
        // user hasn't set up any rules yet, and starting to watch folders
        // immediately means triggering permission prompts and risking rule-less
        // surprises before they've configured anything. Once they've explicitly
        // set this either way, that choice persists.
        let storedPaused = db.withLock { db in try? db.getSetting("paused") }
        self.paused = storedPaused.map { $0 == "1" } ?? true

        let storedAccent = db.withLock { db in (try? db.getSetting("accent_color")) ?? nil }
        let preset = storedAccent.flatMap(AccentPreset.init(rawValue:)) ?? .default
        self.accentPreset = preset
        ForelTheme.apply(preset)

        let storedShowDockIcon = db.withLock { db in try? db.getSetting("show_dock_icon") }
        self.showDockIcon = storedShowDockIcon.map { $0 == "1" } ?? true

        let storedShowMenuBarIcon = db.withLock { db in try? db.getSetting("show_menu_bar_icon") }
        self.showMenuBarIcon = storedShowMenuBarIcon.map { $0 == "1" } ?? true

        let storedLaunchAtLogin = db.withLock { db in try? db.getSetting("launch_at_login") }
        self.wantsLaunchAtLogin = storedLaunchAtLogin == "1"

        let storedWatcherNotificationsEnabled = db.withLock { db in try? db.getSetting("watcher_notifications_enabled") }
        self.watcherNotificationsEnabled = storedWatcherNotificationsEnabled.map { $0 == "1" } ?? true

        let storedMaxDays = db.withLock { db in (try? db.getSetting("history_max_days")).flatMap { Int($0) } }
        self.historyMaxDays = min(max(storedMaxDays ?? 30, 1), 30)

        self.ruleExpansionPreferences = db.withLock { db in RuleExpansionPreferences.load(from: db) }

        let storedRecheck = db.withLock { db in (try? db.getSetting("recheck_interval_minutes")).flatMap { Int($0) } }
        self.recheckIntervalMinutes = max(storedRecheck ?? 30, 0)
        self.trashCleanupPolicy = db.withLock { db in
            TrashCleanupPolicy(
                maxAgeDays: (try? db.getSetting("trash_max_age_days")).flatMap { Int($0) }.flatMap { $0 > 0 ? $0 : nil },
                maxSizeBytes: (try? db.getSetting("trash_max_size_gb")).flatMap { Double($0) }.flatMap { $0 > 0 ? UInt64($0 * 1_073_741_824) : nil }
            )
        }

        reloadFolders()
        let hazelPromptSeen = db.withLock { db in (try? db.getSetting("hazel_import_prompt_seen")) == "1" }
        showHazelImportAssistant = !hazelPromptSeen && folders.isEmpty && hazelAppURL != nil
        startWatchingEnabledFolders()
        startHistoryCleanupTimer()
        startRecheckTimer()
        observeVolumeMounts()
        observeWake()
        if recheckIntervalMinutes > 0 { recheckNow() }
    }

    // MARK: - Periodic re-check

    /// Choices offered in Settings, in minutes (0 = off).
    static let recheckIntervalChoices = [0, 5, 15, 30, 60, 180]

    func setRecheckIntervalMinutes(_ minutes: Int) {
        let clamped = max(minutes, 0)
        guard clamped != recheckIntervalMinutes else { return }
        recheckIntervalMinutes = clamped
        db.withLock { db in try? db.setSetting("recheck_interval_minutes", "\(clamped)") }
        startRecheckTimer()
    }

    private func startRecheckTimer() {
        recheckTimer = nil
        guard recheckIntervalMinutes > 0 else { return }
        let interval = TimeInterval(recheckIntervalMinutes * 60)
        recheckTimer = Timer.publish(every: interval, tolerance: min(interval / 10, 60), on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.recheckNow() }
    }

    /// Re-checks time-dependent rules on every folder unless watching is
    /// paused — pausing means no rule runs on its own.
    func recheckNow() {
        guard !paused else { return }
        coordinator.recheckTimeDependentRules()
    }

    /// A Mac that slept through the scheduled re-checks catches up on wake.
    private func observeWake() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.recheckIntervalMinutes > 0 else { return }
                self.recheckNow()
            }
        }
    }

    // MARK: - Trash cleanup

    func setTrashCleanupPolicy(_ policy: TrashCleanupPolicy) {
        trashCleanupPolicy = policy
        db.withLock { db in
            try? db.setSetting("trash_max_age_days", "\(policy.maxAgeDays ?? 0)")
            let gigabytes = policy.maxSizeBytes.map { Double($0) / 1_073_741_824 } ?? 0
            try? db.setSetting("trash_max_size_gb", "\(gigabytes)")
        }
    }

    /// What the given policy would permanently delete right now, for the
    /// confirmation shown before turning a limit on or cleaning up by hand.
    func trashCleanupPreview(_ policy: TrashCleanupPolicy) async -> Result<[TrashItem], TrashCleanerError> {
        await Task.detached(priority: .userInitiated) { () -> Result<[TrashItem], TrashCleanerError> in
            do {
                return .success(TrashCleaner.plan(policy, items: try TrashCleaner.items()))
            } catch let error as TrashCleanerError {
                return .failure(error)
            } catch {
                return .failure(.cannotReadTrash)
            }
        }.value
    }

    /// Applies the saved policy now. Deleted items are recorded in Activity.
    func runTrashCleanup() {
        let policy = trashCleanupPolicy
        guard policy.isEnabled else { return }
        Task {
            let outcome = await Task.detached(priority: .background) { [db] () -> String? in
                do {
                    let result = try TrashCleaner.clean(policy)
                    let entries = TrashCleaner.historyEntries(deleted: result.deleted, failed: result.failed)
                    if !entries.isEmpty {
                        db.withLock { db in try? db.insertHistoryEntries(entries) }
                    }
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            trashCleanupError = outcome
            reloadHistory()
        }
    }

    /// A disk or share coming back runs the rules again on the files that
    /// couldn't be moved or copied to it while it was missing.
    private func observeVolumeMounts() {
        volumeMountObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            MainActor.assumeIsolated {
                self?.volumeDidMount(atPath: url.path)
            }
        }
    }

    private func bumpWatcherHistoryRevision() {
        guard watcherHistoryRevisionTask == nil else { return }
        watcherHistoryRevisionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            self?.watcherHistoryRevisionTask = nil
            self?.watcherHistoryRevision += 1
        }
    }

    private func volumeDidMount(atPath mountPoint: String) {
        volumeNotifier.volumeConnected((mountPoint as NSString).lastPathComponent)
        coordinator.volumeDidMount(atPath: mountPoint)
    }

    private static func locateHazel() -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.noodlesoft.Hazel")
            ?? ["/Applications/Hazel.app", "/Applications/Setapp/Hazel.app"]
                .map(URL.init(fileURLWithPath:))
                .first(where: { FileManager.default.fileExists(atPath: $0.path) })
    }

    /// Forel's bundle identifier moved from `com.forel.app` (`.app` isn't a
    /// valid reverse-DNS component on macOS) to `com.lab421.forel`. Existing
    /// users have their database and settings under the old identifier's
    /// Application Support folder; move that folder to the new location so
    /// they don't lose rules or history. No-ops once migrated, and never
    /// overwrites a new-location folder that already exists.
    private static func migrateLegacyAppSupportDirectoryIfNeeded(root: URL, newDirectory: URL) {
        let legacyDirectory = root.appendingPathComponent("com.forel.app", isDirectory: true)
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyDirectory.path), !fm.fileExists(atPath: newDirectory.path) else { return }
        try? fm.moveItem(at: legacyDirectory, to: newDirectory)
    }

    func applyDockIconPreference(keepingWindowsVisible: Bool = false) {
        let visibleWindows = NSApp.windows.filter { window in
            window.isVisible && !(window is NSPanel)
        }
        let keyWindow = NSApp.keyWindow

        NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)

        guard keepingWindowsVisible else { return }

        let windowsToRestore = visibleWindows.isEmpty
            ? NSApp.windows.filter { !($0 is NSPanel) }
            : visibleWindows

        let restoreWindows = {
            for window in windowsToRestore {
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
            keyWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        restoreWindows()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            for window in windowsToRestore {
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
            keyWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func setShowDockIcon(_ enabled: Bool) {
        showDockIcon = enabled
        db.withLock { db in try? db.setSetting("show_dock_icon", enabled ? "1" : "0") }
        applyDockIconPreference(keepingWindowsVisible: true)
    }

    func setShowMenuBarIcon(_ enabled: Bool) {
        showMenuBarIcon = enabled
        db.withLock { db in try? db.setSetting("show_menu_bar_icon", enabled ? "1" : "0") }
    }

    func setWantsLaunchAtLogin(_ enabled: Bool) {
        wantsLaunchAtLogin = enabled
        db.withLock { db in try? db.setSetting("launch_at_login", enabled ? "1" : "0") }
    }

    func setWatcherNotificationsEnabled(_ enabled: Bool) {
        watcherNotificationsEnabled = enabled
        db.withLock { db in try? db.setSetting("watcher_notifications_enabled", enabled ? "1" : "0") }
        guard !enabled else { return }
        watcherNotificationTask?.cancel()
        watcherNotificationTask = nil
        pendingWatcherNotification = PendingWatcherNotification()
        volumeNotificationTask?.cancel()
        volumeNotificationTask = nil
        volumeNotifier.discardPending()
    }

    func setAccentPreset(_ preset: AccentPreset) {
        accentPreset = preset
        ForelTheme.apply(preset)
        accentVersion += 1
        db.withLock { db in try? db.setSetting("accent_color", preset.rawValue) }
    }

    func setHistoryMaxDays(_ days: Int) {
        let clamped = min(max(days, 1), 30)
        guard clamped != historyMaxDays else { return }
        historyMaxDays = clamped
        db.withLock { db in try? db.setSetting("history_max_days", "\(clamped)") }
        runHistoryCleanup()
    }

    private func runHistoryCleanup() {
        let days = historyMaxDays
        Task.detached(priority: .background) { [db] in
            try? db.withLock { db in
                try db.purgeHistory(before: days)
            }
        }
    }

    private func startHistoryCleanupTimer() {
        historyCleanupTimer = Timer.publish(every: historyCleanupInterval, tolerance: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.runHistoryCleanup()
                self?.runTrashCleanup()
            }
        runHistoryCleanup()
        runTrashCleanup()
    }

    private func queueWatcherNotification(_ summary: WatcherActivitySummary) {
        guard watcherNotificationsEnabled else { return }
        pendingWatcherNotification.add(summary)
        guard watcherNotificationTask == nil else { return }
        watcherNotificationTask = Task { [weak self] in
            try? await Task.sleep(for: watcherNotificationDelay)
            await self?.flushWatcherNotification()
        }
    }

    private func flushWatcherNotification() async {
        watcherNotificationTask = nil
        guard watcherNotificationsEnabled else {
            pendingWatcherNotification = PendingWatcherNotification()
            return
        }
        guard let notification = pendingWatcherNotification.makeNotification() else { return }
        pendingWatcherNotification = PendingWatcherNotification()
        await postNotification(title: notification.title, body: notification.body)
    }

    private func queueVolumeNotification(_ event: VolumeUnavailableEvent) {
        guard watcherNotificationsEnabled, volumeNotifier.add(event) else { return }
        guard volumeNotificationTask == nil else { return }
        volumeNotificationTask = Task { [weak self] in
            try? await Task.sleep(for: watcherNotificationDelay)
            await self?.flushVolumeNotification()
        }
    }

    private func flushVolumeNotification() async {
        volumeNotificationTask = nil
        guard watcherNotificationsEnabled, let notification = volumeNotifier.makeNotification() else { return }
        await postNotification(title: notification.title, body: notification.body)
    }

    private func postNotification(title: String, body: String) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        guard (await center.notificationSettings()).authorizationStatus == .authorized else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "forel-watcher-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }

    func reloadFolders() {
        folders = db.withLock { db in (try? db.listFolders()) ?? [] }
        if let selectedFolderId, !folders.contains(where: { $0.id == selectedFolderId }) {
            self.selectedFolderId = folders.first?.id
        }
        if selectedFolderId == nil {
            selectedFolderId = folders.first?.id
        }
        if let historyFolderFilterId, !folders.contains(where: { $0.id == historyFolderFilterId }) {
            self.historyFolderFilterId = nil
            reloadHistory()
        }
        reloadRules()
    }

    func reloadRules() {
        guard let folderId = selectedFolderId else { rules = []; return }
        rules = db.withLock { db in (try? db.listRules(folderId: folderId)) ?? [] }
        reloadRuleRunStats()
    }

    func reloadHistory() {
        loadHistoryPage(reset: true)
        reloadRuleRunStats()
    }

    /// Success/failed run counts per rule over the last `ruleRunStatsWindowDays`
    /// days — kept in sync with `rules` and `history`, since both can change
    /// what these totals should be.
    private func reloadRuleRunStats() {
        let days = ruleRunStatsWindowDays
        ruleRunStats = db.withLock { db in (try? db.ruleRunStats(sinceDays: days)) ?? [] }
    }

    func runStats(for rule: Rule) -> RuleRunStats? {
        ruleRunStats.first { $0.id == rule.id }
    }

    func isRuleExpanded(_ rule: Rule) -> Bool {
        ruleExpansionPreferences.isExpanded(rule)
    }

    func toggleRuleExpanded(_ rule: Rule) {
        db.withLock { db in ruleExpansionPreferences.toggle(rule, in: db) }
    }

    private func clearRuleExpansionState(_ ruleId: String) {
        db.withLock { db in ruleExpansionPreferences.clear(ruleId: ruleId, in: db) }
    }

    private func clearRuleExpansionState(_ ruleIds: Set<String>) {
        db.withLock { db in ruleExpansionPreferences.clear(ruleIds: ruleIds, in: db) }
    }

    var totalSuccessCount30d: Int { ruleRunStats.reduce(0) { $0 + $1.successCount } }
    var totalFailedCount30d: Int { ruleRunStats.reduce(0) { $0 + $1.failedCount } }

    func loadMoreHistoryIfNeeded(currentEntry entry: HistoryEntry? = nil) {
        guard hasMoreHistory, !isLoadingHistory else { return }
        if let entry, history.last?.id != entry.id { return }
        loadHistoryPage(reset: false)
    }

    func setHistoryFolderFilter(_ folderId: String?) {
        guard historyFolderFilterId != folderId else { return }
        historyFolderFilterId = folderId
        reloadHistory()
    }

    private func loadHistoryPage(reset: Bool) {
        guard !isLoadingHistory else { return }
        isLoadingHistory = true
        defer { isLoadingHistory = false }

        let directoryPath = historyFilterDirectoryPath
        if reset {
            history = []
            historyTotalCount = db.withLock { db in (try? db.countHistory(directoryPath: directoryPath)) ?? 0 }
        }

        let offset = reset ? 0 : history.count
        let limit = historyPageSize
        let page = db.withLock { db in (try? db.listHistory(limit: limit, offset: offset, directoryPath: directoryPath)) ?? [] }
        history = reset ? page : history + page
        hasMoreHistory = history.count < historyTotalCount
    }

    private var historyFilterDirectoryPath: String? {
        guard let historyFolderFilterId else { return nil }
        return folders.first(where: { $0.id == historyFolderFilterId })?.path
    }

    private func startWatchingEnabledFolders() {
        guard !paused else { return }
        let allFolders = db.withLock { db in (try? db.listFolders()) ?? [] }
        for folder in allFolders where folder.enabled {
            coordinator.add(folder.path)
        }
    }

    func addFolder(path: String) {
        let normalizedPath = (path as NSString).standardizingPath
        if let existingFolder = folders.first(where: { ($0.path as NSString).standardizingPath == normalizedPath }) {
            selectedFolderId = existingFolder.id
            detailRoute = .rules
            reloadRules()
            showNotice(
                title: "Folder already watched",
                message: "\"\((existingFolder.path as NSString).lastPathComponent)\" is already in your watched folders."
            )
            return
        }

        let folder = WatchedFolder(path: normalizedPath)
        do {
            try db.withLock { db in try db.insertFolder(folder) }
            if !paused { coordinator.add(normalizedPath) }
            reloadFolders()
        } catch {
            showError(error)
        }
    }

    func removeFolder(_ folder: WatchedFolder) {
        let removedRuleIds = db.withLock { db in
            Set(((try? db.listRules(folderId: folder.id)) ?? []).map(\.id))
        }
        coordinator.remove(folder.path)
        db.withLock { db in try? db.deleteFolder(folder.id) }
        clearRuleExpansionState(removedRuleIds)
        reloadFolders()
    }

    func updateFolderPath(_ folder: WatchedFolder, path: String) {
        guard !isRunningNow && !isPreviewing else {
            showNotice(
                title: "Folder is busy",
                message: "Wait for the current Run Now or Dry Run to finish before changing this watched folder."
            )
            return
        }
        guard !coordinator.isProcessing(in: folder.path) else {
            showNotice(
                title: "Folder is busy",
                message: "Forel is still processing a file event in this watched folder. Try again once it finishes."
            )
            return
        }

        let normalizedPath = (path as NSString).standardizingPath
        let oldPath = (folder.path as NSString).standardizingPath
        guard normalizedPath != oldPath else { return }

        if let existingFolder = folders.first(where: { existing in
            existing.id != folder.id && (existing.path as NSString).standardizingPath == normalizedPath
        }) {
            selectedFolderId = existingFolder.id
            detailRoute = .rules
            reloadRules()
            showNotice(
                title: "Folder already watched",
                message: "\"\((existingFolder.path as NSString).lastPathComponent)\" is already in your watched folders."
            )
            return
        }

        do {
            try db.withLock { db in try db.updateFolderPath(folder.id, path: normalizedPath) }
            if folder.enabled, !paused {
                coordinator.remove(folder.path)
                coordinator.add(normalizedPath)
            }
            reloadFolders()
            reloadRules()
            if historyFolderFilterId == folder.id {
                reloadHistory()
            }
        } catch {
            showError(error)
        }
    }

    func toggleFolder(_ folder: WatchedFolder, enabled: Bool) {
        db.withLock { db in try? db.toggleFolder(folder.id, enabled: enabled) }
        if enabled, !paused {
            coordinator.add(folder.path)
        } else {
            coordinator.remove(folder.path)
        }
        reloadFolders()
    }

    func reorderFolders(_ folderIds: [String]) {
        db.withLock { db in try? db.reorderFolders(folderIds) }
        reloadFolders()
    }

    func saveRule(_ rule: Rule) {
        do {
            let isUpdate = rules.contains(where: { $0.id == rule.id })
            try db.withLock { db in
                if isUpdate {
                    try db.updateRule(rule)
                } else {
                    try db.insertRule(rule)
                }
            }
            if !paused { coordinator.refreshWatchedPaths() }
            reloadRules()
        } catch {
            showError(error)
        }
    }

    func deleteRule(_ rule: Rule) {
        db.withLock { db in try? db.deleteRule(rule.id) }
        clearRuleExpansionState(rule.id)
        if !paused { coordinator.refreshWatchedPaths() }
        reloadRules()
    }

    func exportRules(to url: URL) {
        do {
            let data = try RuleTransfer.exportForel(rules)
            try data.write(to: url, options: .atomic)
            showRunNowMessage(RunNowMessage(text: "Exported \(rules.count) rule\(rules.count == 1 ? "" : "s")", hasFailures: false, folderId: selectedFolderId ?? ""))
        } catch {
            showError(error)
        }
    }

    @discardableResult
    func importRules(from url: URL) -> Bool {
        guard let folderId = selectedFolderId else { return false }
        do {
            let result = try RuleTransfer.importRules(from: Data(contentsOf: url), folderId: folderId)
            try db.withLock { db in
                for rule in result.rules { try db.insertRule(rule) }
            }
            reloadRules()
            if result.issues.isEmpty {
                showRunNowMessage(RunNowMessage(text: "Imported \(result.rules.count) rule\(result.rules.count == 1 ? "" : "s")", hasFailures: false, folderId: folderId))
            } else {
                alertTitle = "Imported with review needed"
                errorMessage = "Imported \(result.rules.count) rule\(result.rules.count == 1 ? "" : "s"). Rules with unsupported Hazel parts were disabled.\n\n"
                    + result.issues.map { "\($0.ruleName): \($0.message)" }.joined(separator: "\n")
            }
            return true
        } catch {
            showError(error)
            return false
        }
    }

    func openHazel() {
        guard let hazelAppURL else { return }
        NSWorkspace.shared.openApplication(at: hazelAppURL, configuration: .init()) { _, error in
            if let error {
                Task { @MainActor in self.showError(error) }
            }
        }
    }

    func finishHazelImportAssistant() {
        db.withLock { db in try? db.setSetting("hazel_import_prompt_seen", "1") }
        showHazelImportAssistant = false
    }

    func toggleRule(_ rule: Rule, enabled: Bool) {
        db.withLock { db in try? db.toggleRule(rule.id, enabled: enabled) }
        reloadRules()
    }

    /// Bulk enable/disable, used by "Enable All"/"Disable All" and by the
    /// multi-selection toolbar.
    func setRulesEnabled(_ rules: [Rule], _ enabled: Bool) {
        guard !rules.isEmpty else { return }
        db.withLock { db in
            for rule in rules { try? db.toggleRule(rule.id, enabled: enabled) }
        }
        if !paused { coordinator.refreshWatchedPaths() }
        reloadRules()
    }

    func deleteRules(_ rules: [Rule]) {
        guard !rules.isEmpty else { return }
        db.withLock { db in
            for rule in rules { try? db.deleteRule(rule.id) }
        }
        clearRuleExpansionState(Set(rules.map(\.id)))
        if !paused { coordinator.refreshWatchedPaths() }
        reloadRules()
    }

    /// Duplicates a rule (same folder by default, another folder for "Copy to")
    /// with fresh identifiers. The copy starts disabled so it never doubles
    /// up on files the original already acts on.
    func duplicateRule(_ rule: Rule, toFolder folderId: String? = nil) {
        let clone = rule.duplicated(inFolder: folderId)
        db.withLock { db in try? db.insertRule(clone) }
        if !paused { coordinator.refreshWatchedPaths() }
        reloadRules()
        let destination = folderId == nil
            ? nil
            : folders.first { $0.id == folderId }?.path.split(separator: "/").last.map(String.init)
        showRunNowMessage(RunNowMessage(
            text: destination.map { "Copied “\(rule.name)” to \($0) — starts disabled" }
                ?? "Duplicated “\(rule.name)” — starts disabled",
            hasFailures: false,
            folderId: selectedFolderId ?? ""
        ))
    }

    /// Moves a rule to another folder, keeping its id (and history) intact.
    func moveRule(_ rule: Rule, toFolder folderId: String) {
        guard folderId != rule.folderId else { return }
        db.withLock { db in try? db.moveRule(rule.id, toFolder: folderId) }
        clearRuleExpansionState(rule.id)
        if !paused { coordinator.refreshWatchedPaths() }
        reloadRules()
        let destination = folders.first { $0.id == folderId }?.path.split(separator: "/").last.map(String.init) ?? "folder"
        showRunNowMessage(RunNowMessage(
            text: "Moved “\(rule.name)” to \(destination)",
            hasFailures: false,
            folderId: selectedFolderId ?? ""
        ))
    }

    func collapseAllRules() {
        db.withLock { db in ruleExpansionPreferences.collapseAll(rules, in: db) }
    }

    func reorderRules(_ ruleIds: [String]) {
        guard let folderId = selectedFolderId else { return }
        db.withLock { db in try? db.reorderRules(folderId: folderId, ruleIds: ruleIds) }
        reloadRules()
    }

    /// Runs all enabled rules in the selected folder against every file
    /// currently in it (a manual "Run Now"), bounded by each rule's scope.
    func runNow() {
        guard let folder = folders.first(where: { $0.id == selectedFolderId }) else { return }
        runNow(folder: folder, rules: rules.filter(\.enabled))
    }

    /// Run Now on `folder` with `folderRules`. `notifies` also posts the
    /// result as a notification — for runs started from a `forel://` link,
    /// where the window may not be open.
    private func runNow(folder: WatchedFolder, rules folderRules: [Rule], notifies: Bool = false) {
        guard !isRunningNow else { return }
        guard !folderRules.isEmpty else {
            showRunNowMessage(RunNowMessage(text: "Run complete — no enabled rules", hasFailures: false, folderId: folder.id))
            if notifies {
                Task { await postNotification(title: "Forel", body: "\((folder.path as NSString).lastPathComponent): no enabled rules to run") }
            }
            return
        }
        isRunningNow = true
        Task {
            defer { isRunningNow = false }
            let allHistory = await Task.detached(priority: .userInitiated) {
                let maxDepth = RuleEngine.maxRuleDepth(folderRules)
                let entries = RuleEngine.walkEntries(root: folder.path, maxDepth: maxDepth)
                let batchId = UUID().uuidString
                var allHistory: [HistoryEntry] = []
                for entry in entries {
                    let (_, history) = RuleEngine.run(path: entry.path, depth: entry.depth, rules: folderRules, batchId: batchId, root: folder.path)
                    allHistory.append(contentsOf: history)
                }
                return allHistory
            }.value
            if !allHistory.isEmpty {
                db.withLock { db in try? db.insertHistoryEntries(allHistory) }
            }
            reloadHistory()
            let summary = RunSummary.message(for: allHistory)
            showRunNowMessage(RunNowMessage(
                text: summary,
                hasFailures: allHistory.contains { $0.status == .failed },
                folderId: folder.id
            ))
            if notifies {
                await postNotification(title: (folder.path as NSString).lastPathComponent, body: summary)
            }
        }
    }

    // MARK: - forel:// links

    /// Parses and carries out a `forel://` link.
    func handle(url: URL) {
        guard let command = ForelURLCommand(url: url) else {
            showNotice(title: "Unknown Forel link", message: "Forel doesn't understand “\(url.absoluteString)”. Settings → Automation lists the links it supports.")
            return
        }
        handle(command)
    }

    /// Carries out a `forel://` link. Unknown links and links naming a
    /// folder or rule that doesn't exist explain what went wrong.
    func handle(_ command: ForelURLCommand) {
        switch command {
        case .runFolder(let path):
            guard let folder = folders.first(where: { ($0.path as NSString).standardizingPath == path }) else {
                showNotice(title: "Can't run that folder", message: "“\(path)” isn't one of Forel's watched folders. Add it in the sidebar first, or check the path in the link.")
                return
            }
            let folderRules = db.withLock { db in (try? db.listRules(folderId: folder.id)) ?? [] }.filter(\.enabled)
            runNow(folder: folder, rules: folderRules, notifies: true)
        case .runRule(let nameOrId):
            let match = db.withLock { db -> (WatchedFolder, Rule)? in
                let folders = (try? db.listFolders()) ?? []
                for folder in folders {
                    let rules = (try? db.listRules(folderId: folder.id)) ?? []
                    if let rule = rules.first(where: { $0.id == nameOrId || $0.name.localizedCaseInsensitiveCompare(nameOrId) == .orderedSame }) {
                        return (folder, rule)
                    }
                }
                return nil
            }
            guard let match else {
                showNotice(title: "Can't find that rule", message: "No rule is named “\(nameOrId)”. Check the rule's name in the link — it has to match exactly, apart from capitalization.")
                return
            }
            var runnable = match.1
            runnable.enabled = true
            runNow(folder: match.0, rules: [runnable], notifies: true)
        case .recheck:
            recheckNow()
        case .pause:
            if !paused { togglePaused() }
        case .resume:
            if paused { togglePaused() }
        case .open:
            break
        }
    }

    /// Shows the result of a manual run. A clean run is auto-dismissed a few
    /// seconds later — unless a newer run has already replaced it. A run with
    /// failures stays until dismissed, so there is time to open Activity.
    private func showRunNowMessage(_ message: RunNowMessage) {
        let id = UUID()
        runNowMessageId = id
        runNowMessage = message
        guard !message.hasFailures else { return }
        Task {
            try? await Task.sleep(for: .seconds(3))
            if runNowMessageId == id { runNowMessage = nil }
        }
    }

    func dismissRunNowMessage() {
        runNowMessage = nil
    }

    /// The last Run Now result, shown only with the folder it was run on. A
    /// result with failures stays until dismissed, so it is back when that
    /// folder is selected again.
    var runNowMessageForSelectedFolder: RunNowMessage? {
        guard let runNowMessage, runNowMessage.folderId == selectedFolderId else { return nil }
        return runNowMessage
    }

    /// Opens Activity. When coming from a folder's run result, a filter set
    /// to another folder would hide that run, so it is cleared.
    func showActivity(forFolder folderId: String? = nil) {
        if let folderId, let historyFolderFilterId, historyFolderFilterId != folderId {
            self.historyFolderFilterId = nil
        }
        reloadHistory()
        detailRoute = .history
    }

    /// Runs Dry Run off the main thread — scanning every file in a large
    /// folder can take a while, so `isPreviewing` drives a loading state on
    /// the button instead of freezing the UI. Sets `previewResult` when done,
    /// which the view presents as a sheet.
    func preview() {
        guard !isPreviewing else { return }
        guard let folder = folders.first(where: { $0.id == selectedFolderId }) else {
            previewResult = PreviewResult(filesScanned: 0, matches: [])
            return
        }
        let folderRules = rules.filter(\.enabled)
        guard !folderRules.isEmpty else {
            previewResult = PreviewResult(filesScanned: 0, matches: [])
            return
        }
        let matchLimit = previewMatchLimit
        isPreviewing = true
        Task {
            defer { isPreviewing = false }
            previewResult = await Task.detached(priority: .userInitiated) {
                let maxDepth = RuleEngine.maxRuleDepth(folderRules)
                var filesScanned = 0
                var matches: [FilePreview] = []
                var reachedMatchLimit = false
                RuleEngine.forEachEntry(root: folder.path, maxDepth: maxDepth) { entry in
                    filesScanned += 1
                    guard let match = RuleEngine.previewFile(path: entry.path, depth: entry.depth, rules: folderRules) else {
                        return
                    }
                    if matches.count < matchLimit {
                        matches.append(match)
                    } else {
                        reachedMatchLimit = true
                    }
                }
                return PreviewResult(
                    filesScanned: filesScanned,
                    matches: matches,
                    matchLimit: matchLimit,
                    reachedMatchLimit: reachedMatchLimit
                )
            }.value
        }
    }

    /// Dry-runs a single rule draft inside the rule editor, off the main
    /// thread. Unlike `preview()` this tests the unsaved draft as it stands
    /// in the editor — not the folder's saved, enabled rules — so conditions
    /// and actions can be iterated on before committing. The draft is tested
    /// alone, so matches show what *this* rule would do, unaffected by other
    /// rules' chains or conflicts. Disabled drafts are tested as if enabled:
    /// that flag only gates automatic execution. When nothing matches, a
    /// sample of non-matching files with the failing conditions' breakdown
    /// is collected so the editor can show *why* they didn't match.
    func testRule(_ draft: Rule) {
        guard !isTestingRule else { return }
        guard let folder = folders.first(where: { $0.id == draft.folderId }) else {
            ruleTestResult = PreviewResult(filesScanned: 0, matches: [])
            return
        }
        var testable = draft
        testable.enabled = true
        let matchLimit = previewMatchLimit
        let nonMatchLimit = ruleTestNonMatchSampleLimit
        ruleTestGeneration += 1
        let generation = ruleTestGeneration
        isTestingRule = true
        let scan = Task.detached(priority: .userInitiated) {
            let maxDepth = RuleEngine.maxRuleDepth([testable])
            var filesScanned = 0
            var matches: [FilePreview] = []
            var nonMatches: [FilePreview] = []
            var reachedMatchLimit = false
            var reachedNonMatchLimit = false
            RuleEngine.forEachEntry(root: folder.path, maxDepth: maxDepth) { entry in
                guard !Task.isCancelled else { return }
                filesScanned += 1
                guard let match = RuleEngine.previewFile(path: entry.path, depth: entry.depth, rules: [testable], includeNonMatches: true) else {
                    return
                }
                if match.rules.first?.matched == false {
                    if nonMatches.count < nonMatchLimit {
                        nonMatches.append(match)
                    } else {
                        reachedNonMatchLimit = true
                    }
                    return
                }
                if matches.count < matchLimit {
                    matches.append(match)
                } else {
                    reachedMatchLimit = true
                }
            }
            return PreviewResult(
                filesScanned: filesScanned,
                matches: matches,
                matchLimit: matchLimit,
                reachedMatchLimit: reachedMatchLimit,
                nonMatches: nonMatches,
                reachedNonMatchLimit: reachedNonMatchLimit
            )
        }
        ruleTestTask = scan
        Task {
            let result = await scan.value
            // A newer test (or a cancel) superseded this scan — drop it.
            guard generation == ruleTestGeneration else { return }
            isTestingRule = false
            ruleTestResult = result
        }
    }

    /// Stops an in-flight editor dry-run — e.g. the editor sheet closed —
    /// and ignores whatever it would still publish.
    func cancelRuleTest() {
        ruleTestGeneration += 1
        ruleTestTask?.cancel()
        ruleTestTask = nil
        isTestingRule = false
    }

    /// The enabled rules and watched root currently covering `path`, if
    /// watching is actually active there — empty/`nil` when paused or the
    /// folder is disabled, since the watcher wouldn't reprocess anything in
    /// that case regardless of what the rules say.
    private func activeRules(coveringRestorePath path: String) -> (rules: [Rule], watchedRoot: String?) {
        guard !paused else { return ([], nil) }
        return db.withLock { db -> (rules: [Rule], watchedRoot: String?) in
            guard let folder = try? db.folderForPath(path), folder.enabled else { return ([], nil) }
            let rules = (try? db.listRules(folderId: folder.id))?.filter(\.enabled) ?? []
            return (rules, folder.path)
        }
    }

    /// Reverses `entry` only if `UndoChecker` finds it safe right now —
    /// never a silent best-effort rollback on a file that no longer matches
    /// what Forel originally changed.
    func undo(_ entry: HistoryEntry) {
        guard entry.status == .applied else { return }
        let context = activeRules(coveringRestorePath: entry.originalPath)
        switch UndoChecker.evaluate(entry, activeRules: context.rules, watchedRoot: context.watchedRoot) {
        case .unsafe(let reason):
            showNotice(title: "Can't undo this action", message: reason)
        case .safe:
            do {
                try ActionExecutor.revert(Undo.fromJSON(entry.undo))
                try db.withLock { db in try db.markHistoryUndone(entry.id) }
                reloadHistory()
            } catch {
                showError(error)
            }
        }
    }

    /// Reverts every still-applied, reversible entry in a batch that
    /// `UndoChecker` finds safe, in reverse application order so chained
    /// actions on the same file (e.g. tag then rename) revert correctly.
    /// Entries that aren't safe — including ones that would collide with
    /// another restore in the same batch — are left untouched and reported,
    /// rather than attempted.
    func undoBatch(_ batchId: String) {
        let entries = db.withLock { db in (try? db.listHistoryBatch(batchId)) ?? [] }
        let reversible = entries.filter { $0.status == .applied && $0.reversible }
        let colliding = UndoChecker.collidingRestoreTargets(reversible)

        var failures: [String] = []
        for entry in reversible.reversed() {
            if colliding.contains(entry.id) {
                failures.append("\((entry.originalPath as NSString).lastPathComponent): would collide with another file being restored in this batch.")
                continue
            }
            let context = activeRules(coveringRestorePath: entry.originalPath)
            switch UndoChecker.evaluate(entry, activeRules: context.rules, watchedRoot: context.watchedRoot) {
            case .unsafe(let reason):
                failures.append("\((entry.originalPath as NSString).lastPathComponent): \(reason)")
            case .safe:
                do {
                    try ActionExecutor.revert(Undo.fromJSON(entry.undo))
                    try db.withLock { db in try db.markHistoryUndone(entry.id) }
                } catch {
                    failures.append("\((entry.originalPath as NSString).lastPathComponent): \(error)")
                }
            }
        }

        if !failures.isEmpty {
            showError("Some actions could not be undone:\n" + failures.joined(separator: "\n"))
        }
        reloadHistory()
    }

    func togglePaused() {
        paused.toggle()
        let isPaused = paused
        let allFolders = db.withLock { db -> [WatchedFolder] in
            try? db.setSetting("paused", isPaused ? "1" : "0")
            return (try? db.listFolders()) ?? []
        }
        if isPaused {
            coordinator.removeAll()
            return
        }
        for folder in allFolders {
            if folder.enabled {
                coordinator.add(folder.path)
            }
        }
        coordinator.refreshWatchedPaths()
    }

    private func showNotice(title: String, message: String) {
        alertTitle = title
        errorMessage = message
    }

    private func showError(_ error: any Error) {
        showError("\(error)")
    }

    private func showError(_ message: String) {
        alertTitle = "Error"
        errorMessage = message
    }
}

private struct PendingWatcherNotification {
    var actionCount = 0
    var fileCount = 0
    var ruleCounts: [String: Int] = [:]

    mutating func add(_ summary: WatcherActivitySummary) {
        actionCount += summary.actionCount
        fileCount += summary.fileCount
        for ruleName in summary.ruleNames {
            ruleCounts[ruleName, default: 0] += 1
        }
    }

    mutating func makeNotification() -> (title: String, body: String)? {
        guard actionCount > 0 else { return nil }

        let actionLabel = actionCount == 1 ? "action" : "actions"
        let fileLabel = fileCount == 1 ? "file" : "files"
        let title = "Forel applied \(actionCount) \(actionLabel)"

        let ruleNames = ruleCounts
            .sorted { lhs, rhs in
                lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
            }
            .map(\.key)
        let visibleRules = ruleNames.prefix(3)
        let remainingRuleCount = max(0, ruleNames.count - visibleRules.count)
        let rulesText: String
        if visibleRules.isEmpty {
            rulesText = "No rules"
        } else {
            rulesText = visibleRules.joined(separator: ", ")
                + (remainingRuleCount > 0 ? " and \(remainingRuleCount) more" : "")
        }

        return (
            title,
            "\(fileCount) \(fileLabel) processed. Rules: \(rulesText)."
        )
    }
}
