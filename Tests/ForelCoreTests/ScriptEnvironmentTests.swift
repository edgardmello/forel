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

struct ScriptEnvironmentTests {
    @Test func shellDefaultsToBashAndMapsHazelPaths() {
        #expect(ScriptShell.of(makeAction(.runScript, .object([:]))) == .bash)
        #expect(ScriptShell.of(makeAction(.runScript, .object([ActionParam.shell: .string("/bin/zsh")]))) == .zsh)
        #expect(ScriptShell.of(makeAction(.runScript, .object([ActionParam.shell: .string("/bin/sh")]))) == .bash)
        #expect(ScriptShell.of(makeAction(.runScript, .object([ActionParam.shell: .string("login")]))) == .login)
        #expect(ScriptShell.login.command(for: "true", userShell: "/bin/zsh").arguments == ["-l", "-c", "true"])
    }

    @Test func variablesDescribeTheFileRuleAndCaptures() {
        let vars = ScriptEnvironment.variables(
            path: "/Users/me/Downloads/Report 2026.pdf",
            root: "/Users/me/Downloads",
            ruleName: "Invoices",
            captures: ["year": "2026", "bad-name": "x"]
        )
        #expect(vars["FOREL_FILE"] == "/Users/me/Downloads/Report 2026.pdf")
        #expect(vars["FOREL_NAME"] == "Report 2026.pdf")
        #expect(vars["FOREL_STEM"] == "Report 2026")
        #expect(vars["FOREL_EXTENSION"] == "pdf")
        #expect(vars["FOREL_DIR"] == "/Users/me/Downloads")
        #expect(vars["FOREL_FOLDER"] == "/Users/me/Downloads")
        #expect(vars["FOREL_RULE"] == "Invoices")
        #expect(vars["FOREL_CAPTURE_YEAR"] == "2026")
        #expect(vars.keys.contains { $0.contains("BAD") } == false)
    }

    @Test func environmentAddsToolFoldersOnce() {
        let env = ScriptEnvironment.environment(base: ["PATH": "/usr/bin:/bin:/opt/homebrew/bin"], variables: ["FOREL_FILE": "/x"])
        let path = env["PATH"]?.split(separator: ":").map(String.init) ?? []
        #expect(path.first == "/usr/bin")
        #expect(path.filter { $0 == "/opt/homebrew/bin" }.count == 1)
        #expect(path.contains("/usr/local/bin"))
        #expect(env["FOREL_FILE"] == "/x")
    }

    @Test func storedOutputKeepsTheEnd() {
        #expect(ScriptEnvironment.storedOutput("  \n ") == nil)
        #expect(ScriptEnvironment.storedOutput(" done\n") == "done")
        let long = String(repeating: "a", count: 10) + "END"
        #expect(ScriptEnvironment.storedOutput(long, limit: 3) == "…END")
        #expect(ScriptEnvironment.failureMessage(status: 2, output: "out", errors: "") == "script exited with status 2: out")
        #expect(ScriptEnvironment.failureMessage(status: 2, output: "out", errors: "boom") == "script exited with status 2: boom")
        #expect(ScriptEnvironment.failureMessage(status: 1, output: "", errors: "") == "script exited with status 1")
    }

    @Test func scriptOutputAndErrorsReachActivity() throws {
        let dir = TempDir()
        let file = dir.file("a b.txt", contents: "x")
        let ok = makeRule(name: "Echo", actions: [makeAction(.runScript, .object(["script": .string("echo \"$FOREL_RULE:$FOREL_NAME\"")]))])
        let okResult = RuleEngine.run(path: file, depth: 0, rules: [ok], batchId: "b")
        #expect(okResult.history.first?.status == .applied)
        #expect(okResult.history.first?.message == "Echo:a b.txt")

        let failing = makeRule(name: "Fail", actions: [makeAction(.runScript, .object(["script": .string("echo nope >&2; exit 3")]))])
        let failResult = RuleEngine.run(path: file, depth: 0, rules: [failing], batchId: "b")
        #expect(failResult.history.first?.status == .failed)
        #expect(failResult.history.first?.message?.contains("script exited with status 3: nope") == true)
    }

    @Test func zshAndCapturesAreUsed() throws {
        let dir = TempDir()
        let file = dir.file("x.txt", contents: "x")
        let action = makeAction(.runScript, .object([
            "script": .string("print -rn -- \"$ZSH_NAME:$FOREL_CAPTURE_YEAR\""),
            ActionParam.shell: .string("zsh"),
        ]))
        let applied = try TokenExpander.$captures.withValue(["year": "2026"]) {
            try ActionExecutor.execute(action, path: file)
        }
        #expect(applied.message == "zsh:2026")
    }

    @Test func aBackgroundProcessDoesNotHoldTheScript() throws {
        let dir = TempDir()
        let file = dir.file("x.txt", contents: "x")
        let action = makeAction(.runScript, .object(["script": .string("echo started; sleep 5 &")]))
        let start = Date()
        let applied = try ActionExecutor.execute(action, path: file)
        #expect(Date().timeIntervalSince(start) < 4)
        #expect(applied.message == "started")
    }
}
