import Foundation
import Darwin
import ImageIO

/// Local Indra CLI bridge. No shell interpolation and no document uploads.
enum IndraOCR {
    @TaskLocal static var executableOverride: String? = nil
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: ContentExtraction] = [:]

    static func executable(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let override = executableOverride ?? environment["FOREL_INDRA_EXECUTABLE"] {
            return FileManager.default.isExecutableFile(atPath: override) ? override : nil
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let directories = [home + "/Library/Application Support/Forel/Indra/bin", home + "/.local/bin",
                           "/opt/homebrew/bin", "/usr/local/bin"]
            + (environment["PATH"] ?? "").components(separatedBy: ":").filter { $0.hasPrefix("/") }
        return directories.map { $0 + "/indra-ocr" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Whether an Indra runtime is installed. When it isn't, callers fall back
    /// to Apple's Vision OCR so content conditions keep working out of the box.
    static var isAvailable: Bool { executable() != nil }

    static func extract(path: String, maxPages: Int, timeout: TimeInterval = 120, normalizedImage: CGImage? = nil) -> ContentExtraction {
        guard let executable = executable() else {
            return failure("Indra OCR is not installed. Run ./scripts/setup-indra.sh from the Forel source folder, then try again.")
        }
        // Serialize expensive OCR work and reuse successful results across conditions.
        lock.lock()
        defer { lock.unlock() }
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(executable)|\(path)|\(modified)|\(attributes?[.size] ?? 0)|\(attributes?[.systemFileNumber] ?? 0)|\(maxPages)"
        if let cached = cache[key] { return cached }
        let result = run(executable: executable, path: path, maxPages: maxPages, timeout: timeout, normalizedImage: normalizedImage)
        if result.text != nil {
            if cache.count >= 32 { cache.removeAll() }
            cache[key] = result
        }
        return result
    }

    private static func failure(_ message: String) -> ContentExtraction {
        ContentExtraction(text: nil, strategy: .none, message: message)
    }

    private static func run(executable: String, path: String, maxPages: Int, timeout: TimeInterval, normalizedImage: CGImage?) -> ContentExtraction {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("forel-indra-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            var inputPath = URL(fileURLWithPath: path).standardizedFileURL.path
            if let normalizedImage {
                let imageURL = directory.appendingPathComponent("input.png")
                guard let destination = CGImageDestinationCreateWithURL(imageURL as CFURL, "public.png" as CFString, 1, nil) else {
                    return failure("Could not prepare this image for Indra OCR.")
                }
                CGImageDestinationAddImage(destination, normalizedImage, nil)
                guard CGImageDestinationFinalize(destination) else { return failure("Could not prepare this image for Indra OCR.") }
                inputPath = imageURL.path
            }
            let outputURL = directory.appendingPathComponent("output")
            let errorURL = directory.appendingPathComponent("errors")
            FileManager.default.createFile(atPath: outputURL.path, contents: nil)
            FileManager.default.createFile(atPath: errorURL.path, contents: nil)
            let output = try FileHandle(forWritingTo: outputURL)
            let errors = try FileHandle(forWritingTo: errorURL)
            defer { try? output.close(); try? errors.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["--format", "json", "--mode", "auto", "--cores", "1",
                                 "--max-pages", String(maxPages), inputPath]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            var stopped: String?
            while process.isRunning {
                if ProcessInfo.processInfo.systemUptime >= deadline {
                    stopped = "Indra OCR timed out. Check that its models are downloaded and try a smaller document."
                }
                for url in [outputURL, errorURL] {
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    if size > 32 * 1024 * 1024 { stopped = "Indra OCR output exceeds the 32 MB limit." }
                }
                if stopped != nil {
                    process.terminate()
                    // A model runtime may not respond to SIGTERM promptly.
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    break
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
            process.waitUntilExit()
            if let stopped { return failure(stopped) }
            for url in [outputURL, errorURL] {
                if ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 32 * 1024 * 1024 {
                    return failure("Indra OCR output exceeds the 32 MB limit.")
                }
            }
            guard process.terminationStatus == 0 else {
                let detail = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
                return failure("Indra OCR could not read this file. \(detail.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))")
            }
            return decode(try Data(contentsOf: outputURL))
        } catch {
            return failure("Could not run Indra OCR: \(error.localizedDescription)")
        }
    }

    /// The CLI can exit successfully even when an individual page failed.
    /// Reject the whole result so negative conditions cannot match partial text.
    static func decode(_ data: Data) -> ContentExtraction {
        struct Page: Decodable {
            struct Line: Decodable { let text: String }
            let source: String
            let lines: [Line]
        }
        guard let json = String(data: data, encoding: .utf8) else {
            return failure("Indra OCR returned invalid text.")
        }
        do {
            let pages = try json.split(whereSeparator: \.isNewline).map {
                try JSONDecoder().decode(Page.self, from: Data($0.utf8))
            }
            guard !pages.isEmpty, pages.allSatisfy({ ["text", "ocr", "hybrid"].contains($0.source) }) else {
                return failure("Indra OCR could not read every page. No content conditions were matched.")
            }
            let text = pages.flatMap(\.lines).map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return failure("Indra OCR found no text in this file.") }
            return ContentExtraction(text: text, strategy: .indraOCR)
        } catch {
            return failure("Indra OCR returned an unreadable result.")
        }
    }
}
