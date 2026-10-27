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
import CryptoKit

/// Content-based duplicate detection for the `duplicate` condition. Two
/// files are duplicates when their bytes are identical; of a set of
/// identical files the oldest (earliest creation date, then the path that
/// sorts first) is the original and never counts as a duplicate, so a
/// "Duplicate → Move to Trash" rule always keeps one copy.
enum DuplicateFinder {
    /// Upper bound on files compared in one scope, so a rule on a huge tree
    /// can't stall the watcher.
    private static let maxCandidates = 20_000

    static func isDuplicate(path: String, scope: DuplicateScope) -> Bool {
        guard let me = FileFacts(path: path), !me.isDirectory else { return false }
        let folder = (path as NSString).deletingLastPathComponent
        // Hashed only once a same-size, older candidate turns up.
        var myDigest: String?
        for candidate in candidates(in: folder, scope: scope) where candidate != path {
            guard let other = FileFacts(path: candidate), !other.isDirectory, other.size == me.size else { continue }
            guard other.isOlder(than: me) else { continue }
            if myDigest == nil {
                guard let digest = FileHasher.sha256(path) else { return false }
                myDigest = digest
            }
            if FileHasher.sha256(candidate) == myDigest { return true }
        }
        return false
    }

    private static func candidates(in folder: String, scope: DuplicateScope) -> [String] {
        let fm = FileManager.default
        switch scope {
        case .sameFolder:
            let names = (try? fm.contentsOfDirectory(atPath: folder)) ?? []
            return names
                .filter { !SystemFileFilter.isExcluded($0) }
                .prefix(maxCandidates)
                .map { (folder as NSString).appendingPathComponent($0) }
        case .sameFolderTree:
            var paths: [String] = []
            RuleEngine.forEachEntry(root: folder, maxDepth: nil) { entry in
                if paths.count < maxCandidates { paths.append(entry.path) }
            }
            return paths
        }
    }

    private struct FileFacts {
        let path: String
        let size: UInt64
        let created: Date
        let isDirectory: Bool

        init?(path: String) {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
            let type = attrs[.type] as? FileAttributeType
            guard type != .typeSymbolicLink else { return nil }
            self.path = path
            self.size = (attrs[.size] as? UInt64) ?? 0
            self.created = (attrs[.creationDate] as? Date) ?? .distantFuture
            self.isDirectory = type == .typeDirectory
        }

        func isOlder(than other: FileFacts) -> Bool {
            if created != other.created { return created < other.created }
            return path < other.path
        }
    }
}

/// Streaming SHA-256 of a file's contents with a small cache keyed by the
/// file's fingerprint, so comparing one arrival against many same-size
/// files hashes each of them once.
enum FileHasher {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (fingerprint: String, digest: String)] = [:]
    private static let maxCacheEntries = 2_000

    static func sha256(_ path: String) -> String? {
        let fingerprint = FileFingerprint.current(path)
        if let fingerprint {
            lock.lock()
            let cached = cache[path]
            lock.unlock()
            if let cached, cached.fingerprint == fingerprint { return cached.digest }
        }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            } catch {
                return nil
            }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        if let fingerprint {
            lock.lock()
            if cache.count >= maxCacheEntries { cache.removeAll(keepingCapacity: true) }
            cache[path] = (fingerprint, digest)
            lock.unlock()
        }
        return digest
    }
}
