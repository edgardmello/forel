import Testing
import Foundation
import AppKit
import PDFKit
@testable import ForelCore

@Suite struct IndraOCRTests {
    private let valid = #"{"source":"ocr","lines":[{"text":"Matrícula 12345 — certidão de ônus"}]}"#

    private func cli(in dir: TempDir, body: String) throws -> String {
        let path = dir.file("indra-ocr", contents: "#!/bin/sh\n" + body)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        return path
    }

    private func image(in dir: TempDir, name: String = "scan.png") throws -> String {
        let path = dir.path + "/" + name
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 10, pixelsHigh: 10,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        return path
    }

    @Test func decodesUnicodeAndRejectsPartialOrInvalidResults() {
        let result = IndraOCR.decode(Data(valid.utf8))
        #expect(result.strategy == .indraOCR)
        #expect(result.text == "Matrícula 12345 — certidão de ônus")
        for output in ["", "not json", valid + "\n" + #"{"source":"error","lines":[]}"#,
                       #"{"source":"ocr","lines":[]}"#, #"{"source":"unexpected","lines":[]}"#] {
            #expect(IndraOCR.decode(Data(output.utf8)).text == nil)
        }
    }

    @Test func executableOverrideIsAuthoritative() {
        #expect(IndraOCR.executable(environment: ["FOREL_INDRA_EXECUTABLE": "/missing/indra"]) == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["FOREL_TEST_INDRA_REAL"] == "1"))
    func realModelReadsImageScannedPDFAndMixedPDF() throws {
        let dir = TempDir()
        let digitalPath = dir.path + "/digital.pdf"
        makeTextPDF(at: digitalPath, text: "INVOICE TOTAL 12345")
        let digital = try #require(PDFDocument(url: URL(fileURLWithPath: digitalPath)))
        let page = try #require(digital.page(at: 0))
        let raster = page.thumbnail(of: NSSize(width: 1200, height: 1600), for: .mediaBox)
        let tiff = try #require(raster.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let imagePath = dir.path + "/scan.png"
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: imagePath))
        let scanned = PDFDocument()
        scanned.insert(try #require(PDFPage(image: raster)), at: 0)
        let scanPath = dir.path + "/scan.pdf"
        #expect(scanned.write(to: URL(fileURLWithPath: scanPath)))
        digital.insert(try #require(PDFPage(image: raster)), at: 1)
        let mixedPath = dir.path + "/mixed.pdf"
        #expect(digital.write(to: URL(fileURLWithPath: mixedPath)))
        for path in [imagePath, scanPath, mixedPath] {
            let extraction = ContentExtractor.extract(path: path)
            #expect(extraction.strategy == .indraOCR, "\(extraction.message ?? "")")
            #expect(try #require(extraction.text).contains("12345"))
            #expect(ConditionEvaluator.evaluate(makeCondition(.contents, .contains, "INVOICE"), path: path))
        }
    }

    @Test func launchesWithoutShellAndInvalidatesCacheWhenFileChanges() throws {
        let dir = TempDir()
        let input = try image(in: dir, name: "scan ' $(touch UNEXPECTED).png")
        let command = try cli(in: dir, body: """
        [ "$1" = '--format' ] && [ "$2" = 'json' ] && [ "$3" = '--mode' ] && [ "$4" = 'auto' ] || exit 2
        [ "$5" = '--cores' ] && [ "$6" = '1' ] && [ "$7" = '--max-pages' ] && [ "$8" = '20' ] || exit 2
        [ "$#" = '9' ] && [ -f "$9" ] || exit 2
        printf '%s\\n' '\(valid)'
        """)
        try IndraOCR.$executableOverride.withValue(command) {
            #expect(ContentExtractor.extract(path: input).text?.contains("Matrícula") == true)
            // Cached success should survive a temporary failure of the CLI.
            try "#!/bin/sh\nexit 1\n".write(toFile: command, atomically: false, encoding: .utf8)
            #expect(ContentExtractor.extract(path: input).text != nil)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: input)
            #expect(ContentExtractor.extract(path: input).text == nil)
        }
        #expect(!FileManager.default.fileExists(atPath: dir.path + "/UNEXPECTED"))
    }

    @Test func missingFailingAndPartialOCRNeverMatchNegativeConditions() throws {
        let dir = TempDir()
        let input = try image(in: dir)
        let failed = try cli(in: dir, body: "printf '%s\\n' '\(valid)'\nexit 1\n")
        for command in ["/missing/indra", failed] {
            IndraOCR.$executableOverride.withValue(command) {
                for op: Operator in [.contains, .doesNotContain, .isNot, .matchesRegex] {
                    #expect(!ConditionEvaluator.evaluate(makeCondition(.contents, op, "missing"), path: input))
                }
                #expect(ContentExtractor.extract(path: input).message != nil)
            }
        }
        let partial = try cli(in: dir, body: "printf '%s\\n' '\(valid)' '{\"source\":\"error\",\"lines\":[]}'\n")
        IndraOCR.$executableOverride.withValue(partial) {
            #expect(!ConditionEvaluator.evaluate(makeCondition(.contents, .doesNotContain, "missing"), path: input))
        }
    }

    @Test func timeoutDoesNotReturnPartialText() throws {
        let dir = TempDir()
        let command = try cli(in: dir, body: "exec /bin/sleep 10\n")
        IndraOCR.$executableOverride.withValue(command) {
            let result = IndraOCR.extract(path: dir.file("input"), maxPages: 20, timeout: 0.05)
            #expect(result.text == nil)
            #expect(result.message?.contains("timed out") == true)
        }
    }

    @Test func mixedPDFUsesIndraInsteadOfOnlyReadingItsDigitalPage() throws {
        let dir = TempDir()
        let pdf = dir.path + "/mixed.pdf"
        makeTextPDF(at: pdf, text: "Digital cover")
        let document = try #require(PDFDocument(url: URL(fileURLWithPath: pdf)))
        let scan = try #require(NSImage(contentsOfFile: image(in: dir)))
        document.insert(try #require(PDFPage(image: scan)), at: 1)
        #expect(document.write(to: URL(fileURLWithPath: pdf)))
        let command = try cli(in: dir, body: "printf '%s\\n' '\(valid)'\n")
        IndraOCR.$executableOverride.withValue(command) {
            #expect(ContentExtractor.extract(path: pdf).strategy == .indraOCR)
            #expect(ConditionEvaluator.evaluate(makeCondition(.contents, .contains, "certidão"), path: pdf))
        }
        // Over the OCR page limit, the digital pages' text layer is still read.
        for index in 2..<21 { document.insert(try #require(PDFPage(image: scan)), at: index) }
        #expect(document.write(to: URL(fileURLWithPath: pdf)))
        IndraOCR.$executableOverride.withValue(command) {
            let result = ContentExtractor.extract(path: pdf)
            #expect(result.strategy == .pdfText)
            #expect(result.text?.contains("Digital cover") == true)
        }
    }

    @Test func fullyScannedPDFOverPageLimitExplainsTheLimit() throws {
        let dir = TempDir()
        let scan = try #require(NSImage(contentsOfFile: image(in: dir)))
        let document = PDFDocument()
        for index in 0..<21 { document.insert(try #require(PDFPage(image: scan)), at: index) }
        let pdf = dir.path + "/scanned.pdf"
        #expect(document.write(to: URL(fileURLWithPath: pdf)))
        let command = try cli(in: dir, body: "printf '%s\\n' '\(valid)'\n")
        IndraOCR.$executableOverride.withValue(command) {
            let result = ContentExtractor.extract(path: pdf)
            #expect(result.text == nil)
            #expect(result.message?.contains("20-page") == true)
        }
    }

    @Test func missingRuntimeFallsBackToAppleOCR() throws {
        let dir = TempDir()
        let input = try image(in: dir)
        IndraOCR.$executableOverride.withValue("/missing/indra") {
            #expect(!IndraOCR.isAvailable)
            let result = ContentExtractor.extract(path: input)
            // A blank image has no text either way, but the Vision path must
            // run instead of reporting that Indra is not installed.
            #expect(result.strategy != .indraOCR)
            #expect(result.message?.contains("Indra") != true)
        }
    }

    @Test(arguments: [false, true])
    func previewManualAndWatcherAgreeIncludingFailures(fails: Bool) throws {
        let dir = TempDir()
        let runtime = TempDir()
        let command = try cli(in: runtime, body: fails ? "exit 1\n" : "printf '%s\\n' '\(valid)'\n")
        let db = try Database(path: ":memory:")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "Indra document check")
        rule.conditions = [makeCondition(.contents, fails ? .doesNotContain : .contains, "certidão", ruleId: rule.id)]
        rule.actions = [makeAction(.rename, .object(["pattern": .string("matched.png")]), ruleId: rule.id)]
        try db.saveRule(rule, sharingWith: [])
        let manual = try image(in: dir, name: "manual.png")
        let automatic = try image(in: dir, name: "automatic.png")
        IndraOCR.$executableOverride.withValue(command) {
            let entries = RuleEngine.walkEntries(root: dir.path, maxDepth: 0)
            for entry in entries {
                let preview = RuleEngine.previewFile(path: entry.path, depth: entry.depth, rules: [rule], root: dir.path)
                #expect((preview != nil) == !fails)
            }
            #expect(FileManager.default.fileExists(atPath: manual))
            _ = RuleEngine.run(path: manual, depth: 0, rules: [rule], batchId: "manual", root: dir.path)
            #expect(FileManager.default.fileExists(atPath: manual) == fails)
            if !fails { try? FileManager.default.removeItem(atPath: dir.path + "/matched.png") }
            WatcherCoordinator(db: db).handle(path: automatic)
            #expect(FileManager.default.fileExists(atPath: automatic) == fails)
        }
        #expect(try db.listHistory().isEmpty == fails)
    }
}
