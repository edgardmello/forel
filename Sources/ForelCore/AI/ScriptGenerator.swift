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

/// A chat-completions service that writes scripts from a description. All
/// of them speak the OpenAI-compatible `/chat/completions` format.
public enum AIProvider: String, CaseIterable, Codable, Sendable {
    case deepseek
    /// Alibaba Cloud Model Studio (Bailian), pay-as-you-go, international.
    case alibabaSingapore = "alibaba_singapore"
    /// Alibaba Cloud Model Studio (Bailian), pay-as-you-go, China (Beijing).
    case alibabaBeijing = "alibaba_beijing"
    /// Any other OpenAI-compatible endpoint, such as a local server.
    case custom

    public var label: String {
        switch self {
        case .deepseek: return "DeepSeek"
        case .alibabaSingapore: return "Alibaba Model Studio (Singapore)"
        case .alibabaBeijing: return "Alibaba Model Studio (Beijing)"
        case .custom: return "Other OpenAI-compatible service"
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .deepseek: return "https://api.deepseek.com"
        case .alibabaSingapore: return "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
        case .alibabaBeijing: return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .custom: return ""
        }
    }

    public var defaultModel: String {
        switch self {
        case .deepseek: return "deepseek-flash"
        case .alibabaSingapore, .alibabaBeijing: return "qwen-plus"
        case .custom: return ""
        }
    }

    /// Where the user gets an API key for this service.
    public var keyPageURL: URL? {
        switch self {
        case .deepseek: return URL(string: "https://platform.deepseek.com/api_keys")
        case .alibabaSingapore: return URL(string: "https://modelstudio.console.alibabacloud.com/?tab=playground#/api-key")
        case .alibabaBeijing: return URL(string: "https://bailian.console.aliyun.com/?tab=model#/api-key")
        case .custom: return nil
        }
    }
}

/// Settings for "Generate Code". Off until the user turns it on; the API key
/// lives in the Keychain, not here.
public struct AISettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var provider: AIProvider
    public var baseURL: String
    public var model: String

    public init(enabled: Bool = false, provider: AIProvider = .deepseek, baseURL: String? = nil, model: String? = nil) {
        self.enabled = enabled
        self.provider = provider
        self.baseURL = baseURL ?? provider.defaultBaseURL
        self.model = model ?? provider.defaultModel
    }

    static let settingKey = "ai_settings"

    public static func load(from db: Database) -> AISettings {
        guard let raw = try? db.getSetting(settingKey),
              let data = raw.data(using: .utf8),
              let settings = try? JSONDecoder().decode(AISettings.self, from: data) else { return AISettings() }
        return settings
    }

    public func save(to db: Database) throws {
        let data = try JSONEncoder().encode(self)
        try db.setSetting(Self.settingKey, String(decoding: data, as: UTF8.self))
    }
}

/// The language of the script being generated, matching the script actions.
public enum ScriptLanguage: Sendable, Equatable {
    case shell(ScriptShell)
    case appleScript
    case javaScript

    public init?(kind: ActionKind, shell: ScriptShell = .bash) {
        switch kind {
        case .runScript: self = .shell(shell)
        case .runAppleScript: self = .appleScript
        case .runJavaScript: self = .javaScript
        default: return nil
        }
    }

    var promptName: String {
        switch self {
        case .shell(.bash): return "a bash script"
        case .shell(.zsh): return "a zsh script"
        case .shell(.login): return "a script for the user's login shell (zsh on most Macs; stick to POSIX sh syntax)"
        case .appleScript: return "an AppleScript"
        case .javaScript: return "a JavaScript for Automation (JXA) script"
        }
    }

    var fileVariableHelp: String {
        switch self {
        case .shell:
            return """
            The script runs once per matching file. Environment variables: FOREL_FILE (full path of the file), \
            FOREL_NAME (file name), FOREL_STEM (name without extension), FOREL_EXTENSION, FOREL_DIR (its folder), \
            FOREL_FOLDER (the watched folder), FOREL_RULE (rule name), and FOREL_CAPTURE_<NAME> for each named \
            regex group the rule captured. Always quote them, e.g. "$FOREL_FILE". Do not loop over files: Forel \
            already calls the script for each one. Exit with a non-zero status on failure and print a short \
            message to stderr. Never overwrite an existing different file without checking first.
            """
        case .appleScript:
            return """
            The script runs once per matching file. The variable FOREL_FILE is already set to the file's full \
            POSIX path as text; use POSIX file FOREL_FILE when an app expects a file. Do not declare an on run handler.
            """
        case .javaScript:
            return """
            The script runs once per matching file. The constant FOREL_FILE is already defined with the file's \
            full path as a string; use Path(FOREL_FILE) when an app expects a file. Do not redeclare it.
            """
        }
    }
}

public struct ScriptGenerationError: Error, CustomStringConvertible, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Builds the request for "Generate Code" and reads the script out of the
/// answer. What is sent: the user's description, the script language, the
/// macOS version, and the names of the command-line tools installed — never
/// file names, paths, contents, or anything from the rule.
public enum ScriptGenerator {
    /// Tools worth telling the model about, checked for on this Mac. Only
    /// the names of the ones found are sent.
    public static let candidateTools = [
        // macOS built-ins
        "sips", "mdls", "mdfind", "xattr", "osascript", "shortcuts", "textutil", "qlmanage",
        "ditto", "zip", "unzip", "tar", "rsync", "curl", "plutil", "pbcopy", "open", "afconvert", "tag",
        // Commonly installed with Homebrew
        "exiftool", "ffmpeg", "ffprobe", "magick", "convert", "pdftotext", "pdfinfo", "qpdf", "gs",
        "ocrmypdf", "tesseract", "pandoc", "jq", "yq", "7z", "unar", "yt-dlp", "rclone", "trash",
        "heif-convert", "cwebp", "dwebp", "img2pdf", "mutool", "python3", "node",
    ]

    public static func availableTools(
        candidates: [String] = candidateTools,
        searchPath: String = ScriptEnvironment.environment(variables: [:])["PATH"] ?? ""
    ) -> [String] {
        let directories = searchPath.split(separator: ":").map(String.init)
        let fm = FileManager.default
        return candidates.filter { tool in
            directories.contains { fm.isExecutableFile(atPath: ($0 as NSString).appendingPathComponent(tool)) }
        }
    }

    public static func systemPrompt(language: ScriptLanguage, tools: [String], macOSVersion: String) -> String {
        """
        You write automation scripts for Forel, a macOS app that runs rule actions on files. \
        Write \(language.promptName) that does what the user describes, for macOS \(macOSVersion).
        \(language.fileVariableHelp)
        Command-line tools available on this Mac: \(tools.isEmpty ? "only the macOS defaults" : tools.joined(separator: ", ")). \
        Prefer these; do not use tools that are not listed or built into macOS, and never install anything.
        Reply with only the script, no explanations and no Markdown code fences. Keep it short and add a brief comment \
        on top saying what it does.
        """
    }

    /// The `/chat/completions` request for `description`.
    public static func request(
        description: String,
        language: ScriptLanguage,
        settings: AISettings,
        apiKey: String,
        tools: [String] = availableTools(),
        macOSVersion: String = ProcessInfo.processInfo.operatingSystemVersionString
    ) throws -> URLRequest {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ScriptGenerationError("Describe what the script should do.") }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ScriptGenerationError("Add your \(settings.provider.label) API key in Settings → AI.")
        }
        guard !settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ScriptGenerationError("Choose a model in Settings → AI.")
        }
        guard let url = endpoint(settings.baseURL) else {
            throw ScriptGenerationError("The service address in Settings → AI isn't a valid https:// URL.")
        }

        var request = URLRequest(url: url, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": settings.model.trimmingCharacters(in: .whitespacesAndNewlines),
            "temperature": 0.2,
            "stream": false,
            "messages": [
                ["role": "system", "content": systemPrompt(language: language, tools: tools, macOSVersion: macOSVersion)],
                ["role": "user", "content": trimmed],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// `<base>/chat/completions`. Only https, except for a server on this
    /// Mac, so the API key never travels in the clear.
    public static func endpoint(_ baseURL: String) -> URL? {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/chat/completions") { base.removeLast("/chat/completions".count) }
        guard let components = URLComponents(string: base),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty else { return nil }
        let isLocal = ["localhost", "127.0.0.1", "::1"].contains(host)
        guard scheme == "https" || (scheme == "http" && isLocal) else { return nil }
        return URL(string: base + "/chat/completions")
    }

    /// The script in a chat-completions answer, or the service's own error.
    public static func script(fromResponse data: Data, statusCode: Int) throws -> String {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (200..<300).contains(statusCode) else {
            let serviceMessage = ((json?["error"] as? [String: Any])?["message"] as? String)
                ?? (json?["message"] as? String)
            switch statusCode {
            case 401, 403:
                throw ScriptGenerationError("The service refused the API key\(serviceMessage.map { ": \($0)" } ?? "."). Check the key and the service address in Settings → AI.")
            case 429:
                throw ScriptGenerationError("The service is rate-limiting requests or the account has no credit left\(serviceMessage.map { ": \($0)" } ?? ".")")
            default:
                throw ScriptGenerationError("The service answered with error \(statusCode)\(serviceMessage.map { ": \($0)" } ?? ".")")
            }
        }
        guard let choices = json?["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw ScriptGenerationError("The service's answer didn't contain a script.")
        }
        let script = stripCodeFences(content)
        guard !script.isEmpty else { throw ScriptGenerationError("The service returned an empty script.") }
        return script
    }

    /// Removes Markdown fences a model adds despite being asked not to.
    public static func stripCodeFences(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            if let newline = trimmed.firstIndex(of: "\n") {
                trimmed = String(trimmed[trimmed.index(after: newline)...])
            } else {
                trimmed = ""
            }
            if let fence = trimmed.range(of: "```", options: .backwards) {
                trimmed = String(trimmed[..<fence.lowerBound])
            }
        }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Sends the request and returns the generated script.
    public static func generate(
        description: String,
        language: ScriptLanguage,
        settings: AISettings,
        apiKey: String,
        session: URLSession = .shared
    ) async throws -> String {
        let request = try request(description: description, language: language, settings: settings, apiKey: apiKey)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw ScriptGenerationError("Couldn't reach \(settings.provider.label): \(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return try script(fromResponse: data, statusCode: status)
    }
}
