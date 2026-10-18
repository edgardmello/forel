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

/// Failures of `{content:...}` token evaluation. These surface as the
/// action's error message in the rule history and the Dry Run, so they
/// must read like an explanation, not a stack trace.
public enum TokenExpanderError: LocalizedError {
    case noMatch(regex: String)
    case unreadableContent
    case unterminatedToken(String)
    case invalidRegex(String)

    public var errorDescription: String? {
        switch self {
        case .noMatch(let regex):
            return "content token found no match for /\(regex)/ in the file's text"
        case .unreadableContent:
            return "content token needs the file's text, but none could be extracted"
        case .unterminatedToken(let snippet):
            return "content token is missing its closing '}' — \(snippet)…"
        case .invalidRegex(let regex):
            return "content token regex /\(regex)/ does not compile"
        }
    }
}

/// Token substitution shared by the Rename action's pattern and the
/// Move/Copy actions' destination path — e.g. `{year}-{month}` for a
/// monthly archive folder, or `{name}-{current_date}.{extension}` for a
/// renamed file.
public enum TokenExpander {
    /// Substitutes tokens against a real file at `path`: `{name}`,
    /// `{extension}`, `{current_date}`, `{year}`, `{month}`, `{day}`,
    /// `{date_modified}`, `{date_created}`, `{size}`, and
    /// `{content:REGEX}`. The attribute tokens and `{content:...}` require
    /// the file to exist; every other token only needs `path` for its
    /// name/extension and doesn't touch the disk. `now` is the moment of
    /// evaluation (rule run or Dry Run) — the date tokens use it, not any
    /// date embedded in the file itself.
    ///
    /// `{content:REGEX}` extracts a value from the file's text (the same
    /// extraction machinery as the Contents condition — plain text, PDF,
    /// Word…): the first match of REGEX, using capture group 1 when the
    /// pattern has one. A trailing `|title`/`|upper`/`|lower` transforms
    /// the captured text. Regex braces nest naturally, so quantifiers like
    /// `\d{4}` work: `{content:IPTU (\d{4})}` yields `2026`. A token whose
    /// regex finds nothing throws — a rename must never silently produce a
    /// name with a missing field.
    public static func expand(_ template: String, path: String, now: Date = Date()) throws -> String {
        let url = URL(fileURLWithPath: path)
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension

        var result = substituteCommonTokens(template, name: stem, extension: ext, now: now)

        if result.contains("{date_modified}") || result.contains("{date_created}") || result.contains("{size}") {
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            let modified = (attrs[.modificationDate] as? Date) ?? now
            let created = (attrs[.creationDate] as? Date) ?? now
            let size = (attrs[.size] as? UInt64) ?? 0
            result = result
                .replacingOccurrences(of: "{date_modified}", with: dayFormatter.string(from: modified))
                .replacingOccurrences(of: "{date_created}", with: dayFormatter.string(from: created))
                .replacingOccurrences(of: "{size}", with: formatFileSize(size))
        }

        return try expandContentTokens(result, path: path)
    }

    /// Same token set with placeholder values (a fixed sample name/extension
    /// and size, `now`'s date, no disk access, never throws) — for live
    /// previews in the rule editor before a concrete file exists to
    /// evaluate against.
    public static func previewExpand(_ template: String, now: Date = Date()) -> String {
        let common = substituteCommonTokens(template, name: "file", extension: "txt", now: now)
            .replacingOccurrences(of: "{date_modified}", with: dayFormatter.string(from: now))
            .replacingOccurrences(of: "{date_created}", with: dayFormatter.string(from: now))
            .replacingOccurrences(of: "{size}", with: "1.2MB")
        // No real file to read in a live preview — a readable placeholder so
        // the pattern's shape still shows. Malformed tokens stay as typed.
        return replaceContentTokensForPreview(common)
    }

    private static func substituteCommonTokens(_ template: String, name: String, extension ext: String, now: Date) -> String {
        template
            .replacingOccurrences(of: "{name}", with: name)
            .replacingOccurrences(of: "{extension}", with: ext)
            .replacingOccurrences(of: "{current_date}", with: dayFormatter.string(from: now))
            .replacingOccurrences(of: "{year}", with: yearFormatter.string(from: now))
            .replacingOccurrences(of: "{month}", with: monthFormatter.string(from: now))
            .replacingOccurrences(of: "{day}", with: dayOfMonthFormatter.string(from: now))
    }

    // MARK: - Content-capture tokens ({content:REGEX})

    /// Expands every `{content:REGEX}` token against the file's extracted
    /// text. The text is extracted once and shared by all tokens in the
    /// template; the first token that fails aborts the whole expansion so a
    /// rename can never silently drop a field.
    private static func expandContentTokens(_ template: String, path: String) throws -> String {
        guard template.contains("{content:") else { return template }
        var extractedText: String?
        var output = ""
        var scanFrom = template.startIndex
        while let opening = template.range(of: "{content:", range: scanFrom..<template.endIndex) {
            output += template[scanFrom..<opening.lowerBound]
            guard let (body, end) = scanContentToken(in: template, from: opening.upperBound) else {
                throw TokenExpanderError.unterminatedToken(String(template[opening.lowerBound...].prefix(60)))
            }
            if extractedText == nil {
                extractedText = ContentExtractor.extract(path: path).text
            }
            guard let text = extractedText else {
                throw TokenExpanderError.unreadableContent
            }
            let (regex, transform) = splitContentTransform(body)
            guard let re = try? NSRegularExpression(pattern: regex, options: [.anchorsMatchLines]) else {
                throw TokenExpanderError.invalidRegex(regex)
            }
            guard let match = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
                throw TokenExpanderError.noMatch(regex: regex)
            }
            // Prefer the first capture group that actually participated —
            // in alternations only one branch's group matches, and that one
            // holds the intended value.
            var capturedRange: Range<String.Index>?
            for group in 1..<match.numberOfRanges {
                if let r = Range(match.range(at: group), in: text) {
                    capturedRange = r
                    break
                }
            }
            capturedRange = capturedRange ?? Range(match.range, in: text)
            guard let capturedRange else {
                throw TokenExpanderError.noMatch(regex: regex)
            }
            var captured = String(text[capturedRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let transform { captured = transform(captured) }
            output += captured
            scanFrom = end
        }
        output += template[scanFrom...]
        return output
    }

    /// Non-throwing variant for `previewExpand`: replaces each well-formed
    /// `{content:...}` token with a placeholder; unterminated tokens stay
    /// as typed.
    private static func replaceContentTokensForPreview(_ template: String) -> String {
        guard template.contains("{content:") else { return template }
        var output = ""
        var scanFrom = template.startIndex
        while let opening = template.range(of: "{content:", range: scanFrom..<template.endIndex) {
            output += template[scanFrom..<opening.lowerBound]
            guard let (_, end) = scanContentToken(in: template, from: opening.upperBound) else {
                return output + template[opening.lowerBound...]
            }
            output += "content"
            scanFrom = end
        }
        output += template[scanFrom...]
        return output
    }

    /// Scans one `{content:...}` token whose body starts at `start`, honoring
    /// nested braces so regex quantifiers like `\d{4}` don't end the token
    /// early. Returns the body and the index just past the closing `}`.
    private static func scanContentToken(in template: String, from start: String.Index) -> (body: String, end: String.Index)? {
        var depth = 1
        var cursor = start
        var body = ""
        while cursor < template.endIndex {
            let ch = template[cursor]
            if ch == "{" {
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth == 0 {
                    return (body, template.index(after: cursor))
                }
            }
            body.append(ch)
            cursor = template.index(after: cursor)
        }
        return nil
    }

    /// Splits a token body into regex and optional trailing transform. The
    /// last `|` only introduces a transform when what follows is a known
    /// name — regex alternation (`foo|bar`) stays part of the pattern, and a
    /// pattern literally ending in `|title` can be written as `|(?:title)`.
    private static func splitContentTransform(_ body: String) -> (regex: String, transform: ((String) -> String)?) {
        if let pipe = body.lastIndex(of: "|") {
            let name = String(body[body.index(after: pipe)...])
            let pattern = String(body[..<pipe])
            switch name {
            case "title": return (pattern, { $0.lowercased().capitalized })
            case "upper": return (pattern, { $0.uppercased() })
            case "lower": return (pattern, { $0.lowercased() })
            default: break
            }
        }
        return (body, nil)
    }

    private static func formatFileSize(_ bytes: UInt64) -> String {
        let kb: Double = 1024
        let mb = 1024 * kb
        let gb = 1024 * mb
        let value = Double(bytes)
        if value >= gb { return String(format: "%.1fGB", value / gb) }
        if value >= mb { return String(format: "%.1fMB", value / mb) }
        if value >= kb { return String(format: "%.1fKB", value / kb) }
        return "\(bytes)B"
    }

    private static var dayFormatter: DateFormatter { formatter("yyyy-MM-dd") }
    private static var yearFormatter: DateFormatter { formatter("yyyy") }
    private static var monthFormatter: DateFormatter { formatter("MM") }
    private static var dayOfMonthFormatter: DateFormatter { formatter("dd") }

    private static func formatter(_ dateFormat: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = dateFormat
        formatter.timeZone = .current
        return formatter
    }
}
