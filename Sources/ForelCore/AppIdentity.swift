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

/// Who this build of Forel is: its bundle identifier, the repository its
/// releases come from, and where its data lives. Kept in one place so the
/// updater, the About pane, the data folder and the build script never point
/// at different projects.
public enum AppIdentity {
    /// The bundle identifier `build.sh` stamps into Info.plist.
    public static let bundleIdentifier = "io.github.edgardmello.forel"

    /// Identifiers earlier builds used, newest first. Their Application
    /// Support folders are copied over on first launch.
    public static let legacyBundleIdentifiers = ["com.lab421.forel", "com.forel.app"]

    /// `owner/name` of the GitHub repository releases are published to.
    public static let repository = "edgardmello/forel"

    public static var repositoryURL: URL {
        URL(string: "https://github.com/\(repository)")!
    }

    public static var releasesURL: URL {
        URL(string: "https://github.com/\(repository)/releases")!
    }

    /// The Application Support folder for `bundleIdentifier` under `root`.
    public static func appSupportDirectory(root: URL) -> URL {
        root.appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    /// Existing legacy folders under `root`, newest identifier first.
    public static func legacyAppSupportDirectories(root: URL, fileManager: FileManager = .default) -> [URL] {
        legacyBundleIdentifiers
            .map { root.appendingPathComponent($0, isDirectory: true) }
            .filter { fileManager.fileExists(atPath: $0.path) }
    }

    /// Returns the data folder, creating it if needed. When it doesn't exist
    /// yet, the newest legacy folder is copied into it first so rules,
    /// history and settings carry over. The legacy folder is left in place
    /// (an older build can still open it), and an existing new folder is
    /// never overwritten.
    @discardableResult
    public static func prepareAppSupportDirectory(root: URL, fileManager: FileManager = .default) throws -> URL {
        let directory = appSupportDirectory(root: root)
        if !fileManager.fileExists(atPath: directory.path),
           let legacy = legacyAppSupportDirectories(root: root, fileManager: fileManager).first {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            try fileManager.copyItem(at: legacy, to: directory)
            // The copied lock file still names the old holder's PID.
            try? fileManager.removeItem(at: directory.appendingPathComponent("forel.lock"))
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

/// Release version numbers as Forel tags them (`v1.4.0`, `1.3.5-fork`,
/// `2.0.0-beta.1`). `-fork` is a leftover channel label from when this
/// project shipped alongside the original, not a prerelease, so `1.3.5-fork`
/// and `1.3.5` are the same version.
public enum ReleaseVersion {
    public static let channelSuffixes = ["fork"]

    /// Strips a leading `v` and a channel suffix.
    public static func normalized(_ version: String) -> String {
        var value = version.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("v") || value.hasPrefix("V") { value.removeFirst() }
        for suffix in channelSuffixes where value.lowercased().hasSuffix("-\(suffix)") {
            value.removeLast(suffix.count + 1)
        }
        return value
    }

    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) == .orderedDescending
    }

    /// Semantic-version-style ordering: numeric core first, then a stable
    /// release outranks any prerelease, and prereleases compare identifier
    /// by identifier (numbers numerically), so `alpha.8` < `beta.1`.
    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let (lhsCore, lhsPre) = split(normalized(lhs))
        let (rhsCore, rhsPre) = split(normalized(rhs))
        let coreResult = compareCore(lhsCore, rhsCore)
        guard coreResult == .orderedSame else { return coreResult }
        switch (lhsPre, rhsPre) {
        case (nil, nil): return .orderedSame
        case (nil, _?): return .orderedDescending
        case (_?, nil): return .orderedAscending
        case let (lhsId?, rhsId?): return comparePrerelease(lhsId, rhsId)
        }
    }

    private static func split(_ version: String) -> (core: [Int], prerelease: String?) {
        let parts = version.split(separator: "-", maxSplits: 1)
        guard let first = parts.first else { return ([0], nil) }
        let core = first.split(separator: ".").map { Int($0) ?? 0 }
        let prerelease = parts.count > 1 ? String(parts[1]) : nil
        return (core, prerelease)
    }

    private static func compareCore(_ lhs: [Int], _ rhs: [Int]) -> ComparisonResult {
        let count = max(lhs.count, rhs.count)
        for index in 0..<count {
            let lhsPart = index < lhs.count ? lhs[index] : 0
            let rhsPart = index < rhs.count ? rhs[index] : 0
            if lhsPart != rhsPart { return lhsPart < rhsPart ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    private static func comparePrerelease(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lhsIds = lhs.split(separator: ".").map(String.init)
        let rhsIds = rhs.split(separator: ".").map(String.init)
        let count = max(lhsIds.count, rhsIds.count)
        for index in 0..<count {
            guard index < lhsIds.count else { return .orderedAscending }
            guard index < rhsIds.count else { return .orderedDescending }
            let lhsId = lhsIds[index]
            let rhsId = rhsIds[index]
            if let lhsNumber = Int(lhsId), let rhsNumber = Int(rhsId) {
                if lhsNumber != rhsNumber { return lhsNumber < rhsNumber ? .orderedAscending : .orderedDescending }
            } else if lhsId != rhsId {
                return lhsId < rhsId ? .orderedAscending : .orderedDescending
            }
        }
        return .orderedSame
    }
}
