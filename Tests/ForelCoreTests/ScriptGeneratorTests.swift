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
import Testing
@testable import ForelCore

struct ScriptGeneratorTests {
    @Test func providersDefaultToTheirOpenAICompatibleEndpoints() {
        #expect(ScriptGenerator.endpoint(AIProvider.deepseek.defaultBaseURL)?.absoluteString == "https://api.deepseek.com/chat/completions")
        #expect(ScriptGenerator.endpoint(AIProvider.alibabaSingapore.defaultBaseURL)?.absoluteString == "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions")
        #expect(ScriptGenerator.endpoint("https://x.test/v1/chat/completions/")?.absoluteString == "https://x.test/v1/chat/completions")
        #expect(ScriptGenerator.endpoint("http://localhost:11434/v1")?.absoluteString == "http://localhost:11434/v1/chat/completions")
        // The API key must never travel in the clear to another machine.
        #expect(ScriptGenerator.endpoint("http://example.com/v1") == nil)
        #expect(ScriptGenerator.endpoint("") == nil)
    }

    @Test func requestCarriesOnlyTheDescriptionAndToolNames() throws {
        let settings = AISettings(enabled: true, provider: .deepseek)
        let request = try ScriptGenerator.request(
            description: "strip GPS from photos",
            language: .shell(.bash),
            settings: settings,
            apiKey: "sk-test",
            tools: ["exiftool", "sips"],
            macOSVersion: "15.0"
        )
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        let body = try #require(request.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(body["model"] as? String == "deepseek-flash")
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages.count == 2)
        #expect(messages[0]["content"]?.contains("exiftool, sips") == true)
        #expect(messages[0]["content"]?.contains("FOREL_FILE") == true)
        #expect(messages[1]["content"] == "strip GPS from photos")
    }

    @Test func requestExplainsWhatIsMissing() {
        let settings = AISettings(enabled: true, provider: .deepseek)
        #expect(throws: ScriptGenerationError.self) {
            try ScriptGenerator.request(description: " ", language: .appleScript, settings: settings, apiKey: "k", tools: [])
        }
        #expect(throws: ScriptGenerationError.self) {
            try ScriptGenerator.request(description: "x", language: .appleScript, settings: settings, apiKey: "", tools: [])
        }
        #expect(throws: ScriptGenerationError.self) {
            try ScriptGenerator.request(description: "x", language: .appleScript, settings: AISettings(enabled: true, provider: .custom), apiKey: "k", tools: [])
        }
    }

    @Test func responsesYieldTheScriptOrTheServiceError() throws {
        let ok = #"{"choices":[{"message":{"role":"assistant","content":"```bash\n# strip\nexiftool -gps:all= \"$FOREL_FILE\"\n```"}}]}"#
        #expect(try ScriptGenerator.script(fromResponse: Data(ok.utf8), statusCode: 200) == "# strip\nexiftool -gps:all= \"$FOREL_FILE\"")

        let denied = #"{"error":{"message":"Invalid API key"}}"#
        do {
            _ = try ScriptGenerator.script(fromResponse: Data(denied.utf8), statusCode: 401)
            Issue.record("expected an error")
        } catch let error as ScriptGenerationError {
            #expect(error.message.contains("Invalid API key"))
        }
        #expect(throws: ScriptGenerationError.self) {
            try ScriptGenerator.script(fromResponse: Data("{}".utf8), statusCode: 200)
        }
    }

    @Test func availableToolsOnlyListsToolsFound() throws {
        let dir = TempDir()
        let tool = dir.file("exiftool", contents: "#!/bin/sh\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool)
        _ = dir.file("ffmpeg", contents: "not executable")
        #expect(ScriptGenerator.availableTools(candidates: ["exiftool", "ffmpeg", "jq"], searchPath: dir.path) == ["exiftool"])
    }

    @Test func settingsRoundTripAndStartDisabled() throws {
        let db = try Database(path: ":memory:")
        #expect(AISettings.load(from: db).enabled == false)
        let settings = AISettings(enabled: true, provider: .alibabaSingapore, model: "qwen-max")
        try settings.save(to: db)
        #expect(AISettings.load(from: db) == settings)
        #expect(AISettings.load(from: db).baseURL == AIProvider.alibabaSingapore.defaultBaseURL)
    }
}
