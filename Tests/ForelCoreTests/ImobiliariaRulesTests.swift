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

/// Guards the bundled `Rules/Imobiliaria.forelrules` export: it must decode
/// through the same import path the app uses, pass validation, and — most
/// importantly — the capture regexes inside its rename patterns must resolve
/// against realistic document text, the way OCR renders cartório headers
/// (ALL CAPS, accents, "fls. 2/10" page markers).
@Suite struct ImobiliariaRulesTests {
    private static let rulesFile = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ImobiliariaRulesTests.swift
        .deletingLastPathComponent()   // ForelCoreTests
        .deletingLastPathComponent()   // Tests
        .appendingPathComponent("Rules/Imobiliaria.forelrules")

    private func importedRules() throws -> [Rule] {
        let data = try Data(contentsOf: Self.rulesFile)
        let result = try RuleTransfer.importRules(from: data, folderId: "watched")
        #expect(result.issues.isEmpty)
        return result.rules
    }

    @Test func bundleDecodesValidatesAndDryRuns() throws {
        var rules = try importedRules()
        #expect(rules.count == 8)

        for rule in rules {
            #expect(rule.folderId == "watched")
            #expect(RuleValidator.validate(rule.conditions).isEmpty)
            #expect(RuleValidator.validate(rule.actions).isEmpty)
            #expect(RuleValidator.validate(groups: rule.conditionGroups).isEmpty)
            rule.actions.forEach { _ in } // keeps the loop expression honest above
        }

        // Rules ship disabled so they can be reviewed before running; enable
        // them the same way the user must after importing.
        for index in rules.indices { rules[index].enabled = true }
        rules.sort { $0.priority < $1.priority }

        let dir = TempDir()

        // RGI page with a printed "fls." marker: full rename with padded page.
        let rgiPage = dir.file("RGI.jpeg.txt", contents: """
            ESTADO DO RIO DE JANEIRO
            7º OFÍCIO DE REGISTRO DE IMÓVEIS
            MATRÍCULA Nº 123.456
            fls. 2/10
            """)
        let page = try #require(RuleEngine.previewFile(path: rgiPage, depth: 0, rules: rules))
        #expect(renameTarget(of: page, ruleName: "RGI — página com folha identificada") == "RGI-123.456-fls02-7RI.txt")
        let commentDescription = commentAction(of: page, ruleName: "RGI — página com folha identificada") ?? "<nil>"
        #expect(commentDescription.contains("7º Ofício"))
        #expect(!page.rules.contains { $0.ruleName == "RGI — página sem folha identificada" && $0.matched })

        // RGI page without a readable page number: fallback rule, no -fls.
        let rgiBlotchy = dir.file("scan.txt", contents: """
            ESTADO DO RIO DE JANEIRO
            7º OFÍCIO DE REGISTRO DE IMÓVEIS
            MATRÍCULA Nº 123.456
            """)
        let blotchy = try #require(RuleEngine.previewFile(path: rgiBlotchy, depth: 0, rules: rules))
        #expect(renameTarget(of: blotchy, ruleName: "RGI — página sem folha identificada") == "RGI-123.456-7RI.txt")

        // Real-world OCR noise: Vision read "MATRICILA" (U→I) and "ICHA"
        // (FICHA) on an actual RGI scan — the tolerant regexes must still land.
        let rgiCertidao = try #require(RuleEngine.previewFile(path: dir.file("certidao.txt", contents: "REGISTRO DE IMOVEIS DO 9º OFICIO\nMATRICILA\nICHA\n308809"), depth: 0, rules: rules))
        #expect(renameTarget(of: rgiCertidao, ruleName: "RGI — página sem folha identificada") == "RGI-308809-9RI.txt")

        // IPTU: exercise year + property inscription number.
        let iptu = dir.file("carnê.txt", contents: """
            PREFEITURA DA CIDADE DO RIO DE JANEIRO
            IPTU — EXERCÍCIO 2026
            Inscrição Imobiliária: 2.038.592-8
            """)
        let iptuPreview = try #require(RuleEngine.previewFile(path: iptu, depth: 0, rules: rules))
        #expect(renameTarget(of: iptuPreview, ruleName: "IPTU — exercício e inscrição") == "IPTU-2026-2.038.592-8.txt")

        // IPTU printed as "IPTU 2026" with the inscription on its own line —
        // the format the real Rio Prefeitura scan uses.
        let iptuRio = try #require(RuleEngine.previewFile(path: dir.file("iptu-rio.txt", contents: "PREFEITURA DA CIDADE DO RIO DE JANEIRO\nIPTU 2026\nInscrição\n3.124.789-3"), depth: 0, rules: rules))
        #expect(renameTarget(of: iptuRio, ruleName: "IPTU — exercício e inscrição") == "IPTU-2026-3.124.789-3.txt")

        // Tag-only rules match their document types.
        let escritura = try #require(RuleEngine.previewFile(path: dir.file("epv.txt", contents: "ESCRITURA PÚBLICA DE COMPRA E VENDA"), depth: 0, rules: rules))
        #expect(hasTagAction(escritura, ruleName: "Escritura pública", tag: "escritura"))

        let condominio = try #require(RuleEngine.previewFile(path: dir.file("boleto.txt", contents: "SEGUNDA VIA\nBOLETO DE CONDOMÍNIO — JANEIRO/2026"), depth: 0, rules: rules))
        #expect(hasTagAction(condominio, ruleName: "Boleto ou taxa de condomínio", tag: "condominio"))

        let certidao = try #require(RuleEngine.previewFile(path: dir.file("certidao.txt", contents: "CERTIDÃO DE ÔNUS E AÇÕES"), depth: 0, rules: rules))
        #expect(hasTagAction(certidao, ruleName: "Certidão de ônus", tag: "certidao"))

        // An unrelated document must match nothing.
        let noise = dir.file("notas.txt", contents: "reunião de condomínio na terça\nlevar o chaveiro")
        let noisePreview = RuleEngine.previewFile(path: noise, depth: 0, rules: rules)
        #expect(noisePreview?.rules.filter(\.matched).isEmpty != false)
    }

    /// Manual validation against real cartório documents: set
    /// FOREL_REAL_DOC_DIR to a folder of scanned files (JPEG/PDF) and this
    /// prints each file's OCR text plus the rules' dry-run verdicts, so the
    /// capture regexes can be tuned against what Vision actually reads.
    /// Skips silently when the variable is unset (normal test/CI runs).
    @Test func realDocumentsDryRunWhenProvided() throws {
        guard let dirPath = ProcessInfo.processInfo.environment["FOREL_REAL_DOC_DIR"],
              FileManager.default.fileExists(atPath: dirPath) else { return }

        var rules = try importedRules()
        for index in rules.indices { rules[index].enabled = true }
        rules.sort { $0.priority < $1.priority }

        let files = try FileManager.default.contentsOfDirectory(atPath: dirPath)
            .filter { !$0.hasPrefix(".") }
            .sorted()
        for file in files {
            let path = (dirPath as NSString).appendingPathComponent(file)
            let extraction = ContentExtractor.extract(path: path)
            print("\n=== \(file) — strategy: \(extraction.strategy.label) ===")
            print(String((extraction.text ?? "<no text>").prefix(600)))
            if let preview = RuleEngine.previewFile(path: path, depth: 0, rules: rules) {
                for rule in preview.rules where rule.matched {
                    print("→ MATCHED: \(rule.ruleName)")
                    for action in rule.actions {
                        print("    \(action.kind.rawValue): \(action.description)\(action.warning.map { " — ⚠️ \($0)" } ?? "")")
                    }
                }
            } else {
                print("→ no rule matched")
            }
        }
    }

    private func renameTarget(of preview: FilePreview, ruleName: String) -> String? {
        preview.rules
            .first { $0.ruleName == ruleName && $0.matched }?
            .actions.first { $0.kind == .rename }?
            .targetPath.map { ($0 as NSString).lastPathComponent }
    }

    private func commentAction(of preview: FilePreview, ruleName: String) -> String? {
        preview.rules
            .first { $0.ruleName == ruleName && $0.matched }?
            .actions.first { $0.kind == .addComment }?
            .description
    }

    private func hasTagAction(_ preview: FilePreview, ruleName: String, tag: String) -> Bool {
        preview.rules
            .first { $0.ruleName == ruleName && $0.matched }?
            .actions.contains { $0.kind == .addTag && $0.description.contains(tag) } ?? false
    }
}
