// Forel - A native macOS file-automation app
// Copyright (C) 2026  Edgard Mello
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
import Combine
import ForelCore

/// Keeps track of what stops Forel from working (see `HealthIssue`): records
/// a heartbeat so the next launch knows how long Forel wasn't running,
/// catches up on files that arrived meanwhile, and re-checks missing
/// folders, Full Disk Access and recent failures. The menu bar glyph and the
/// quick panel show `issues`.
@MainActor
final class HealthMonitor: ObservableObject {
    @Published private(set) var issues: [HealthIssue] = []

    var needsAttention: Bool { issues.contains(where: \.needsAttention) }

    private let db: Database
    private let coordinator: WatcherCoordinator
    private let folders: @MainActor () -> [WatchedFolder]
    private let isPaused: @MainActor () -> Bool
    private let notify: @MainActor (String, String) -> Void
    private var downtime: HealthIssue.Kind?
    private var timer: AnyCancellable?
    private var notifiedIssueIds: Set<String> = []

    init(
        db: Database,
        coordinator: WatcherCoordinator,
        folders: @escaping @MainActor () -> [WatchedFolder],
        isPaused: @escaping @MainActor () -> Bool,
        notify: @escaping @MainActor (String, String) -> Void
    ) {
        self.db = db
        self.coordinator = coordinator
        self.folders = folders
        self.isPaused = isPaused
        self.notify = notify
    }

    /// Call once at launch, after the watchers started.
    func start() {
        let lastAlive = db.withLock { db in (try? db.getSetting(ForelHealth.lastAliveSetting)) ?? nil }
            .flatMap { ISO8601DateFormatter.forelUTC.date(from: $0) }
        recordHeartbeat()
        if !isPaused(), let gap = ForelHealth.downtime(lastAlive: lastAlive) {
            let paths = folders().filter(\.enabled).map(\.path)
            coordinator.catchUpAfterDowntime(watchedFolders: paths, since: gap.start) { [weak self] checked in
                Task { @MainActor in
                    guard let self else { return }
                    self.downtime = .wasNotRunning(from: gap.start, to: gap.end, checkedFiles: checked)
                    self.refresh()
                    if checked > 0, let issue = self.issues.first(where: { $0.id == "downtime" }) {
                        self.notify("Forel caught up", issue.message())
                    }
                }
            }
        }
        timer = Timer.publish(every: ForelHealth.heartbeatInterval, tolerance: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.recordHeartbeat()
                self?.refresh()
            }
        refresh()
    }

    func recordHeartbeat() {
        let now = ISO8601DateFormatter.forelUTC.string(from: Date())
        db.withLock { db in try? db.setSetting(ForelHealth.lastAliveSetting, now) }
    }

    /// Hides the "wasn't running" note.
    func dismissDowntime() {
        downtime = nil
        refresh()
    }

    func refresh() {
        let since = ISO8601DateFormatter.forelUTC.string(from: Date().addingTimeInterval(-24 * 60 * 60))
        let failures = db.withLock { db in (try? db.countFailedHistory(since: since)) ?? 0 }
        let current = ForelHealth.issues(
            folders: folders(),
            fullDiskAccess: PermissionsChecker.fullDiskAccessStatus(),
            recentFailureCount: failures,
            downtime: downtime
        )
        if current != issues { issues = current }
        // Tell once about each new problem that needs the user; failures
        // already notify on their own.
        for issue in current where issue.needsAttention && !notifiedIssueIds.contains(issue.id) {
            if case .recentFailures = issue.kind { continue }
            notifiedIssueIds.insert(issue.id)
            notify("Forel needs attention", issue.message())
        }
        notifiedIssueIds.formIntersection(current.map(\.id))
    }
}
