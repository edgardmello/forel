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

/// Which shell runs an embedded "Run shell script" action. Rules without the
/// param keep running with bash, as they always did. Hazel imports store the
/// shell's path (`/bin/zsh`), which maps onto the matching case.
public enum ScriptShell: String, CaseIterable, Sendable {
    case bash
    case zsh
    /// The user's own login shell, started as a login shell so it reads
    /// their profile (`~/.zprofile`, `~/.bash_profile`): Homebrew and other
    /// tools they set up in their PATH are found.
    case login

    public static func of(_ action: Action) -> ScriptShell {
        guard let raw = action.params[ActionParam.shell]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return .bash }
        if let shell = ScriptShell(rawValue: raw) { return shell }
        switch (raw as NSString).lastPathComponent {
        case "zsh": return .zsh
        default: return .bash
        }
    }

    public var label: String {
        switch self {
        case .bash: return "Bash"
        case .zsh: return "Zsh"
        case .login: return "My login shell (loads my profile)"
        }
    }

    /// The executable and the arguments that run `script` with this shell.
    public func command(for script: String, userShell: String = ScriptShell.userLoginShell()) -> (executable: String, arguments: [String]) {
        switch self {
        case .bash: return ("/bin/bash", ["-c", script])
        case .zsh: return ("/bin/zsh", ["-c", script])
        case .login: return (userShell, ["-l", "-c", script])
        }
    }

    /// The user's login shell from the user database, falling back to zsh
    /// (the macOS default) when it can't be read or isn't executable.
    public static func userLoginShell() -> String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/bin/zsh"
    }
}

/// The environment and output handling shared by script actions.
public enum ScriptEnvironment {
    /// Folders where command-line tools usually live but that an app started
    /// from Finder or at login doesn't have in its PATH, so a script calling
    /// `exiftool` or `ffmpeg` from Homebrew would fail with "command not found".
    public static let extraToolDirectories = [
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/local/sbin",
    ]

    /// Longest script output kept in Activity; longer output keeps its end,
    /// where errors and summaries usually are.
    public static let maxStoredOutput = 4000

    /// Variables a script receives for the file it runs on. `FOREL_FILE` is
    /// the full path, as before; the others save scripts from parsing it.
    public static func variables(
        path: String,
        root: String?,
        ruleName: String?,
        captures: [String: String]
    ) -> [String: String] {
        let url = URL(fileURLWithPath: path)
        var vars: [String: String] = [
            "FOREL_FILE": path,
            "FOREL_NAME": url.lastPathComponent,
            "FOREL_STEM": url.deletingPathExtension().lastPathComponent,
            "FOREL_EXTENSION": url.pathExtension,
            "FOREL_DIR": url.deletingLastPathComponent().path,
        ]
        if let root { vars["FOREL_FOLDER"] = root }
        if let ruleName { vars["FOREL_RULE"] = ruleName }
        for (name, value) in captures {
            guard let key = captureVariableName(name) else { continue }
            vars[key] = value
        }
        return vars
    }

    /// `FOREL_CAPTURE_<NAME>` for a named regex group, or nil when the name
    /// can't be an environment variable.
    public static func captureVariableName(_ name: String) -> String? {
        let allowed = name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_") }
        guard !name.isEmpty, allowed else { return nil }
        return "FOREL_CAPTURE_\(name.uppercased())"
    }

    /// The process environment for a script: Forel's own, the file's
    /// variables, and the usual tool folders appended to PATH when missing.
    public static func environment(
        base: [String: String] = ProcessInfo.processInfo.environment,
        variables: [String: String]
    ) -> [String: String] {
        var env = base
        let current = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            .split(separator: ":").map(String.init)
        let missing = extraToolDirectories.filter { !current.contains($0) }
        env["PATH"] = (current + missing).joined(separator: ":")
        for (key, value) in variables { env[key] = value }
        return env
    }

    /// Output worth keeping: trimmed, nil when empty, and the end of it when
    /// it's longer than `limit`.
    public static func storedOutput(_ text: String, limit: Int = maxStoredOutput) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > limit else { return trimmed }
        return "…" + String(trimmed.suffix(limit))
    }

    /// The message for a script that exited with `status`: its error output
    /// (or, when it wrote none, its regular output) after the status.
    public static func failureMessage(status: Int32, output: String, errors: String) -> String {
        let detail = storedOutput(errors) ?? storedOutput(output)
        guard let detail else { return "script exited with status \(status)" }
        return "script exited with status \(status): \(detail)"
    }
}
