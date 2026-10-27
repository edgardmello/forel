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
import PDFKit

/// Convert Image, Compress PDF and Make PDF Searchable. They share one
/// shape: `conversionPlan` decides what would happen (the same decision
/// Dry Run shows and execution follows), and the result is either written
/// next to the original or swapped in for it, with the original kept in
/// the Trash so the change can be undone.
extension ActionExecutor {
    struct ConversionTarget {
        /// Where the converted file goes; equal to the source path when it
        /// replaces the original in place.
        let target: String
        let description: String
        /// Why nothing would change, when nothing would.
        let skipReason: String?
    }

    static func conversionImageFormat(_ action: Action) -> ImageFormat {
        ImageFormat(rawValue: action.params[ActionParam.imageFormat]?.stringValue ?? "") ?? .jpeg
    }

    static func conversionMaxDimension(_ action: Action) -> Int? {
        let raw: String
        switch action.params[ActionParam.maxDimension] {
        case .number(let value)?: raw = String(Int(value))
        case .string(let value)?: raw = value
        default: return nil
        }
        guard let value = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)), value > 0 else { return nil }
        return value
    }

    public static func keepsOriginal(_ action: Action) -> Bool {
        action.params[ActionParam.keepOriginal]?.boolValue ?? true
    }

    static func conversionTarget(_ action: Action, path: String) -> ConversionTarget {
        let skip = { (reason: String) in ConversionTarget(target: path, description: reason, skipReason: reason) }
        let dir = (path as NSString).deletingLastPathComponent
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let ext = (path as NSString).pathExtension.lowercased()

        switch action.kind {
        case .convertImage:
            guard ext != "pdf", let size = MediaConverter.pixelSize(path) else { return skip("Not an image") }
            let format = conversionImageFormat(action)
            let maxDimension = conversionMaxDimension(action)
            let sameFormat = format.extensions.contains(ext)
            let needsResize = maxDimension.map { max(size.width, size.height) > $0 } ?? false
            if sameFormat && !needsResize {
                return skip(maxDimension == nil ? "Already \(format.label)" : "Already \(format.label), within \(maxDimension!) px")
            }
            let sizeNote = needsResize ? " at \(maxDimension!) px" : ""
            if sameFormat && !keepsOriginal(action) {
                return ConversionTarget(target: path, description: "Resize to \(maxDimension!) px", skipReason: nil)
            }
            let name = sameFormat ? "\(stem)-\(maxDimension!)px.\((path as NSString).pathExtension)" : "\(stem).\(format.fileExtension)"
            return sibling(name, of: path, in: dir, verb: "Convert to \(format.label)\(sizeNote)")

        case .compressPDF:
            guard ext == "pdf", let document = PDFDocument(url: URL(fileURLWithPath: path)) else { return skip("Not a PDF") }
            guard !document.isLocked else { return skip("Password-protected PDF") }
            guard !MediaConverter.isCompressedByForel(document) else { return skip("Already compressed by Forel") }
            return ConversionTarget(target: path, description: "Compress PDF", skipReason: nil)

        case .makeSearchablePDF:
            if ext == "pdf" {
                guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else { return skip("Not a readable PDF") }
                guard !document.isLocked else { return skip("Password-protected PDF") }
                let pages = MediaConverter.pagesNeedingOCR(document).count
                guard pages > 0 else { return skip("Already searchable") }
                return ConversionTarget(target: path, description: "Add searchable text to \(pages) page\(pages == 1 ? "" : "s")", skipReason: nil)
            }
            guard MediaConverter.pixelSize(path) != nil else { return skip("Not a PDF or image") }
            return sibling("\(stem).pdf", of: path, in: dir, verb: "Make searchable PDF")

        default:
            return skip("Not a conversion")
        }
    }

    /// A result written next to the source. One that's already there and
    /// newer than the source means an earlier run made it — converting
    /// again would only pile up " (1)" copies on every Run Now.
    private static func sibling(_ name: String, of path: String, in dir: String, verb: String) -> ConversionTarget {
        let naive = (dir as NSString).appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: naive) {
            if isNewer(naive, than: path) {
                return ConversionTarget(target: path, description: "Already converted to \(name)", skipReason: "Already converted to \(name)")
            }
            let unique = uniqueDest(dir: dir, fileName: name)
            return ConversionTarget(target: unique, description: "\(verb) → \((unique as NSString).lastPathComponent)", skipReason: nil)
        }
        return ConversionTarget(target: naive, description: "\(verb) → \(name)", skipReason: nil)
    }

    private static func isNewer(_ a: String, than b: String) -> Bool {
        let fm = FileManager.default
        guard let da = (try? fm.attributesOfItem(atPath: a))?[.modificationDate] as? Date,
              let db = (try? fm.attributesOfItem(atPath: b))?[.modificationDate] as? Date else { return false }
        return da >= db
    }

    static func conversionPlan(_ action: Action, path: String) -> ActionPlan {
        let conversion = conversionTarget(action, path: path)
        return ActionPlan(
            kind: action.kind,
            description: conversion.description,
            sourcePath: path,
            targetPath: conversion.skipReason == nil ? conversion.target : nil,
            status: conversion.skipReason == nil ? .wouldRun : .wouldSkip,
            finalPath: conversion.skipReason == nil ? conversion.target : path,
            copiedPath: nil,
            isTerminal: false
        )
    }

    static func convertImage(_ action: Action, path: String) throws -> Applied {
        let conversion = conversionTarget(action, path: path)
        guard conversion.skipReason == nil else { return Applied(newPath: path, undo: .none) }
        let format = conversionImageFormat(action)
        let maxDimension = conversionMaxDimension(action)
        let write = { (destination: String) in
            try MediaConverter.convertImage(source: path, destination: destination, format: format, maxDimension: maxDimension)
            return true
        }
        if conversion.target == path {
            return try replaceInPlace(path: path, write: write)
        }
        return try writeBeside(path: path, target: conversion.target, keepOriginal: keepsOriginal(action), write: write)
    }

    static func compressPDF(path: String) throws -> Applied {
        try replaceInPlace(path: path) { destination in
            try MediaConverter.compressPDF(source: path, destination: destination)
        }
    }

    static func makeSearchablePDF(_ action: Action, path: String) throws -> Applied {
        let conversion = conversionTarget(action, path: path)
        guard conversion.skipReason == nil else { return Applied(newPath: path, undo: .none) }
        if conversion.target == path {
            return try replaceInPlace(path: path) { destination in
                try MediaConverter.makeSearchablePDF(source: path, destination: destination)
                return true
            }
        }
        return try writeBeside(path: path, target: conversion.target, keepOriginal: true) { destination in
            try MediaConverter.makeSearchablePDF(fromImage: path, destination: destination)
            return true
        }
    }

    /// Writes the result into a private temporary folder first, so the
    /// watcher never sees a half-written file, then swaps it in for the
    /// original. The original goes to the Trash (undo puts it back). Finder
    /// tags, the Finder comment and the creation date carry over. `write`
    /// returns `false` when there's nothing worth replacing.
    private static func replaceInPlace(path: String, write: (String) throws -> Bool) throws -> Applied {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("forel-convert-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        let temporary = scratch.appendingPathComponent((path as NSString).lastPathComponent).path
        guard try write(temporary), fm.fileExists(atPath: temporary) else {
            return Applied(newPath: path, undo: .none)
        }
        let backup = uniqueDest(dir: try trashDir(), fileName: (path as NSString).lastPathComponent)
        try fm.moveItem(atPath: path, toPath: backup)
        do {
            try fm.moveItem(atPath: temporary, toPath: path)
        } catch {
            try? fm.moveItem(atPath: backup, toPath: path)
            throw error
        }
        carryOverFinderInfo(from: backup, to: path)
        return Applied(newPath: path, undo: .derived(created: path, original: path, backup: backup))
    }

    private static func writeBeside(path: String, target: String, keepOriginal: Bool, write: (String) throws -> Bool) throws -> Applied {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("forel-convert-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        let temporary = scratch.appendingPathComponent((target as NSString).lastPathComponent).path
        guard try write(temporary), fm.fileExists(atPath: temporary) else {
            return Applied(newPath: path, undo: .none)
        }
        try fm.moveItem(atPath: temporary, toPath: target)
        carryOverFinderInfo(from: path, to: target)
        var backup: String?
        if !keepOriginal {
            let trashed = uniqueDest(dir: try trashDir(), fileName: (path as NSString).lastPathComponent)
            try fm.moveItem(atPath: path, toPath: trashed)
            backup = trashed
        }
        return Applied(newPath: target, undo: .derived(created: target, original: path, backup: backup))
    }

    private static func carryOverFinderInfo(from source: String, to destination: String) {
        let tags = FinderTags.read(source)
        if !tags.isEmpty {
            try? FinderTags.write(destination, tags)
        }
        if let comment = FinderTags.readComment(source), !comment.isEmpty {
            try? FinderTags.writeComment(destination, comment)
        }
        if let created = (try? FileManager.default.attributesOfItem(atPath: source))?[.creationDate] as? Date {
            try? FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: destination)
        }
    }
}
