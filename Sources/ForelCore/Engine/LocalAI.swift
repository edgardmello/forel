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
#if canImport(FoundationModels)
import FoundationModels
#endif

public enum LocalAIError: LocalizedError {
    case unavailable(String)
    case noAnswer
    case unreadableContent

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return reason
        case .noAnswer: return "Apple Intelligence didn't return an answer for this file"
        case .unreadableContent: return "ai token needs the file's text, but none could be extracted"
        }
    }
}

/// Apple's on-device language model (Foundation Models, macOS 26), used by
/// the "Document (AI)" condition and the `{ai:…}` rename token. Nothing
/// leaves the Mac. On a Mac without the model, Apple Intelligence turned
/// off, or a build without the macOS 26 SDK, every call reports why it's
/// unavailable and conditions simply don't match.
public enum LocalAI {
    /// The model's context window is small; the start of a document is
    /// where its type and key fields almost always are.
    static let maxInputCharacters = 6_000
    private static let timeout: TimeInterval = 60

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String] = [:]
    private static let maxCacheEntries = 1_000

    /// `nil` when the model is ready, otherwise a plain-language reason.
    public static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(.deviceNotEligible):
                return "This Mac doesn't support Apple Intelligence."
            case .unavailable(.appleIntelligenceNotEnabled):
                return "Apple Intelligence is turned off. Turn it on in System Settings → Apple Intelligence & Siri."
            case .unavailable(.modelNotReady):
                return "Apple Intelligence is still downloading its model. Try again later."
            case .unavailable:
                return "Apple Intelligence isn't available right now."
            @unknown default:
                return "Apple Intelligence isn't available right now."
            }
        }
        return "Apple Intelligence needs macOS 26 or later."
        #else
        return "This build of Forel was made without Apple Intelligence support."
        #endif
    }

    /// Whether the document fits `description`. `nil` when the model
    /// can't answer (unavailable, refused, timed out).
    static func classify(text: String, fileName: String, description: String) -> Bool? {
        let prompt = """
        File name: \(fileName)
        Document text:
        \(String(text.prefix(maxInputCharacters)))

        Question: Is this document \(description)? Answer with exactly one word: YES or NO.
        """
        guard let answer = cachedRespond(
            instructions: "You classify documents. You answer only YES or NO.",
            prompt: prompt
        ) else { return nil }
        let normalized = answer.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if normalized.hasPrefix("YES") || normalized.hasPrefix("SIM") { return true }
        if normalized.hasPrefix("NO") || normalized.hasPrefix("NÃO") || normalized.hasPrefix("NAO") { return false }
        return nil
    }

    /// A short value from the document answering `question`, for use in a
    /// file name — e.g. "the owner's full name".
    static func extract(question: String, text: String, fileName: String) throws -> String {
        if let reason = unavailableReason { throw LocalAIError.unavailable(reason) }
        let prompt = """
        File name: \(fileName)
        Document text:
        \(String(text.prefix(maxInputCharacters)))

        Reply with only \(question), exactly as written in the document, with no explanation. If the document doesn't say, reply NONE.
        """
        guard let answer = cachedRespond(
            instructions: "You extract short values from documents. You reply with the value only, on one line.",
            prompt: prompt
        ) else { throw LocalAIError.noAnswer }
        let value = answer
            .split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'“”.")) ?? ""
        guard !value.isEmpty, value.uppercased() != "NONE" else { throw LocalAIError.noAnswer }
        return value
    }

    private static func cachedRespond(instructions: String, prompt: String) -> String? {
        let key = instructions + "\u{1F}" + prompt
        lock.lock()
        let cached = cache[key]
        lock.unlock()
        if let cached { return cached }
        guard let answer = respond(instructions: instructions, prompt: prompt) else { return nil }
        lock.lock()
        if cache.count >= maxCacheEntries { cache.removeAll(keepingCapacity: true) }
        cache[key] = answer
        lock.unlock()
        return answer
    }

    /// Rules run synchronously on background queues, so the async model
    /// call is bridged with a semaphore and a timeout.
    private static func respond(instructions: String, prompt: String) -> String? {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *), unavailableReason == nil else { return nil }
        final class Box: @unchecked Sendable { var value: String? }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            defer { semaphore.signal() }
            let session = LanguageModelSession(instructions: instructions)
            box.value = try? await session.respond(to: prompt).content
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        return box.value
        #else
        return nil
        #endif
    }
}
