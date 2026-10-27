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

import Testing
import Foundation
@testable import ForelCore

struct TokenExpanderTests {
    @Test func expandsYearMonthDayTokens() throws {
        let dir = TempDir()
        let file = dir.file("report.txt")

        let result = try TokenExpander.expand("{year}-{month}-{day}", path: file, now: fixedDate())

        #expect(result == "2026-03-05")
    }

    @Test func leavesUnknownTokensUntouched() throws {
        let dir = TempDir()
        let file = dir.file("report.txt")

        let result = try TokenExpander.expand("{not_a_token}", path: file)

        #expect(result == "{not_a_token}")
    }

    // MARK: - {content:REGEX} tokens

    @Test func contentTokenCapturesFirstGroupAndNestsRegexBraces() throws {
        let dir = TempDir()
        let file = dir.file("iptu2026.pdf.txt", contents: "COTA ÚNICA - IPTU 2026\nINSCRIÇÃO: 2.038.592-8")

        // \d{4} inside the token: the balanced-brace scanner must not end the
        // token at the quantifier's closing brace.
        let year = try TokenExpander.expand("{content:IPTU (\\d{4})}", path: file)
        let inscricao = try TokenExpander.expand("{content:INSCRIÇÃO: ([\\d.]+-\\d)}", path: file)

        #expect(year == "2026")
        #expect(inscricao == "2.038.592-8")
    }

    @Test func contentTokenFallsBackToWholeMatchWithoutCaptureGroup() throws {
        let dir = TempDir()
        let file = dir.file("doc.txt", contents: "ref REF-2026/042 ok")

        let result = try TokenExpander.expand("{content:REF-[0-9/]+}", path: file)

        #expect(result == "REF-2026/042")
    }

    @Test func contentTokenMatchesLineAnchorsAndTransformsTitle() throws {
        let dir = TempDir()
        let file = dir.file("doc.txt", contents: "intro line\nMARIA TEREZA ALCURE DIAS LEITE\nINSCRIÇÃO: 2.038.592-8")

        // ^…$ anchor per line (anchorsMatchLines), and |title capitalizes each
        // word while lowercasing the rest.
        let name = try TokenExpander.expand("{content:^([A-ZÀ-Ú ]+)$|title}", path: file)
        let upper = try TokenExpander.expand("{content:^([a-zà-ú ]+)$|upper}", path: file)

        #expect(name == "Maria Tereza Alcure Dias Leite")
        #expect(upper == "INTRO LINE")
    }

    @Test func padTransformZeroPadsNumericCapturesForSorting() throws {
        let dir = TempDir()
        let page2 = dir.file("page2.txt", contents: "MATRÍCULA 123.456\nfls. 2/10")
        let page10 = dir.file("page10.txt", contents: "MATRÍCULA 123.456\nfls. 10/10")
        let odd = dir.file("odd.txt", contents: "fls. 2/10")
        let wide = dir.file("wide.txt", contents: "mat 123")

        // "2" → "02": fls02 now sorts before fls10 in the Finder.
        let pageToken = "fls{content:fls\\.\\s*(\\d{1,3})|pad2}"
        #expect(try TokenExpander.expand(pageToken, path: page2) == "fls02")
        #expect(try TokenExpander.expand(pageToken, path: page10) == "fls10")

        // Captures that aren't pure digits, or are already wider than the
        // pad width, pass through unchanged.
        #expect(try TokenExpander.expand("fls{content:fls\\.\\s*(\\d/\\d+)|pad2}", path: odd) == "fls2/10")
        #expect(try TokenExpander.expand("{content:mat (\\d+)|pad2}", path: wide) == "123")
    }

    @Test func contentTokenKeepsRegexAlternationAndSharesExtraction() throws {
        let dir = TempDir()
        let file = dir.file("doc.txt", contents: "IPTU 2026")

        // `|` is alternation unless followed by a known transform name.
        let either = try TokenExpander.expand("{content:ISSU (\\d{4})|IPTU (\\d{4})}", path: file)
        #expect(either == "2026")

        let combined = try TokenExpander.expand("{content:IPTU (\\d{4})}-{content:IPTU (\\d{4})|title}", path: file)
        #expect(combined == "2026-2026")
    }

    @Test func contentTokenThrowsWhenRegexHasNoMatch() throws {
        let dir = TempDir()
        let file = dir.file("doc.txt", contents: "nothing relevant")

        #expect(throws: TokenExpanderError.self) {
            try TokenExpander.expand("{content:IPTU (\\d{4})}", path: file)
        }
    }

    @Test func contentTokenThrowsOnUnterminatedTokenAndInvalidRegex() throws {
        let dir = TempDir()
        let file = dir.file("doc.txt", contents: "IPTU 2026")

        #expect(throws: TokenExpanderError.self) {
            try TokenExpander.expand("{content:IPTU (\\d{4}", path: file)
        }
        #expect(throws: TokenExpanderError.self) {
            try TokenExpander.expand("{content:[unclosed}", path: file)
        }
    }

    @Test func previewExpandReplacesContentTokensWithPlaceholder() {
        let result = TokenExpander.previewExpand("{content:IPTU (\\d{4})}-iptu.{extension}", now: fixedDate())

        #expect(result == "content-iptu.txt")
    }

    /// End to end with the pipeline a real IPTU rename uses: a PDF with a
    /// text layer (PDFKit extraction, same as the Contents condition) and
    /// one pattern pulling three independent fields out of it. Mirrors the
    /// real Rio IPTU layout as PDFKit extracts it: the taxpayer's name
    /// shares the first line with the inscrição and a code, and all-caps
    /// decoys (the neighborhood) follow — anchoring on "first all-caps
    /// line" would grab the decoy instead of the contributor.
    @Test func contentTokensRenameAnIptuPdfEndToEnd() throws {
        let dir = TempDir()
        let pdf = (dir.path as NSString).appendingPathComponent("iptu2026.pdf")
        makeTextPDF(
            at: pdf,
            text: """
            2.038.592-8 00 MARIA TEREZA ALCURE DIAS LEITE
            BARRA DA TIJUCA
            COTA ÚNICA - IPTU 2026
            INSCRIÇÃO: 2.038.592-8
            """,
            fontSize: 11
        )

        let pattern = "{content:IPTU (\\d{4})}-iptu({content:INSCRIÇÃO: ([\\d.]+-[0-9X])})_{content:^\\d\\.\\d{3}\\.\\d{3}-[0-9X] \\d+ ([A-ZÀ-Ú ]+)$|title}.{extension}"
        let result = try TokenExpander.expand(pattern, path: pdf)

        #expect(result == "2026-iptu(2.038.592-8)_Maria Tereza Alcure Dias Leite.pdf")
    }

    @Test func expandsNameAndExtensionWithoutRequiringTheFileToExist() throws {
        // {name}/{extension} only need `path` itself, not a real file on
        // disk — unlike {date_modified}/{date_created}/{size} below.
        let result = try TokenExpander.expand("{name}.{extension}", path: "/nonexistent/report.pdf")

        #expect(result == "report.pdf")
    }

    @Test func throwsWhenASizeOrDateAttributeTokenNeedsAMissingFile() {
        #expect(throws: (any Error).self) {
            try TokenExpander.expand("{size}", path: "/nonexistent/report.pdf")
        }
    }

    @Test func previewExpandNeverThrowsAndUsesPlaceholderValues() {
        let result = TokenExpander.previewExpand("{name}-{year}-{month}-{day}.{extension}", now: fixedDate())

        #expect(result == "file-2026-03-05.txt")
    }

    private func fixedDate() -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = 5
        components.hour = 12
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: components)!
    }
}
