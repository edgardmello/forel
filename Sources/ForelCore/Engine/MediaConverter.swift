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
import CoreText
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Target format of the Convert Image action.
public enum ImageFormat: String, CaseIterable, Sendable {
    case jpeg
    case png
    case heic
    case tiff

    public var label: String {
        switch self {
        case .jpeg: return "JPEG"
        case .png: return "PNG"
        case .heic: return "HEIC"
        case .tiff: return "TIFF"
        }
    }

    public var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .png: return "png"
        case .heic: return "heic"
        case .tiff: return "tiff"
        }
    }

    /// Extensions that already are this format.
    var extensions: Set<String> {
        switch self {
        case .jpeg: return ["jpg", "jpeg"]
        case .png: return ["png"]
        case .heic: return ["heic", "heif"]
        case .tiff: return ["tif", "tiff"]
        }
    }

    var utType: UTType {
        switch self {
        case .jpeg: return .jpeg
        case .png: return .png
        case .heic: return .heic
        case .tiff: return .tiff
        }
    }

    /// Lossy formats take the compression quality option.
    var isLossy: Bool { self == .jpeg || self == .heic }
}

/// The file conversions behind the Convert Image, Compress PDF and Make
/// PDF Searchable actions. Each writes its result to a destination path
/// and never touches the source; `ActionExecutor` decides where results
/// go and how the change is undone.
enum MediaConverter {
    /// Marker stored in a PDF's keywords once Forel compressed it, so the
    /// watcher seeing the rewritten file doesn't recompress it again (each
    /// JPEG pass would lose a little more quality).
    static let compressedMarker = "forel-compressed"
    private static let lossyQuality = 0.85

    // MARK: - Images

    static func pixelSize(_ path: String) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return nil }
        return (width.intValue, height.intValue)
    }

    /// Writes `source` as `format`, scaled down so its longer side is at
    /// most `maxDimension` pixels when given (never scaled up). Orientation
    /// is applied to the pixels, so the result looks the same everywhere.
    static func convertImage(source: String, destination: String, format: ImageFormat, maxDimension: Int?) throws {
        guard let imageSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: source) as CFURL, nil),
              CGImageSourceGetCount(imageSource) > 0 else {
            throw ActionError("This file isn't an image Forel can read")
        }
        guard let destinationRef = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: destination) as CFURL, format.utType.identifier as CFString, 1, nil
        ) else {
            throw ActionError("This Mac can't write \(format.label) images")
        }
        var options: [CFString: Any] = [:]
        if format.isLossy { options[kCGImageDestinationLossyCompressionQuality] = lossyQuality }

        let size = pixelSize(source)
        let longest = size.map { max($0.width, $0.height) } ?? 0
        if let maxDimension, maxDimension > 0, longest > maxDimension {
            let thumbnailOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbnailOptions as CFDictionary) else {
                throw ActionError("Couldn't resize this image")
            }
            CGImageDestinationAddImage(destinationRef, image, options as CFDictionary)
        } else {
            // Keeps the metadata (EXIF, GPS, color profile) as is.
            CGImageDestinationAddImageFromSource(destinationRef, imageSource, 0, options as CFDictionary)
        }
        guard CGImageDestinationFinalize(destinationRef) else {
            throw ActionError("Couldn't write the \(format.label) image")
        }
    }

    // MARK: - PDF compression

    static func isCompressedByForel(_ document: PDFDocument) -> Bool {
        keywords(of: document).contains(compressedMarker)
    }

    private static func keywords(of document: PDFDocument) -> [String] {
        let raw = document.documentAttributes?[PDFDocumentAttribute.keywordsAttribute]
        if let list = raw as? [String] { return list }
        if let single = raw as? String { return single.components(separatedBy: CharacterSet(charactersIn: ",;")).map { $0.trimmingCharacters(in: .whitespaces) } }
        return []
    }

    /// Re-saves the PDF with its images recompressed as JPEG and downsampled
    /// for screen. Returns `false` (and writes nothing) when that wouldn't
    /// make the file meaningfully smaller.
    static func compressPDF(source: String, destination: String) throws -> Bool {
        guard let document = PDFDocument(url: URL(fileURLWithPath: source)) else {
            throw ActionError("This file isn't a PDF Forel can read")
        }
        guard !document.isLocked else {
            throw ActionError("This PDF is password-protected")
        }
        var attributes = document.documentAttributes ?? [:]
        attributes[PDFDocumentAttribute.keywordsAttribute] = keywords(of: document) + [compressedMarker]
        document.documentAttributes = attributes
        let options: [PDFDocumentWriteOption: Any]
        if #available(macOS 13.4, *) {
            options = [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]
        } else {
            options = [:]
        }
        let written = document.write(to: URL(fileURLWithPath: destination), withOptions: options)
        guard written else { throw ActionError("Couldn't write the compressed PDF") }
        let before = fileSize(source)
        let after = fileSize(destination)
        guard after > 0, Double(after) < Double(before) * 0.95 else {
            try? FileManager.default.removeItem(atPath: destination)
            return false
        }
        return true
    }

    // MARK: - Searchable PDF

    /// Pages of `document` without any text layer — the ones a scan made.
    static func pagesNeedingOCR(_ document: PDFDocument) -> [Int] {
        (0..<document.pageCount).filter { index in
            let text = document.page(at: index)?.string ?? ""
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Rewrites the PDF page by page, adding an invisible, selectable text
    /// layer from on-device OCR to every page that has no text yet. Pages
    /// that already have text are copied unchanged.
    static func makeSearchablePDF(source: String, destination: String) throws {
        guard let document = PDFDocument(url: URL(fileURLWithPath: source)) else {
            throw ActionError("This file isn't a PDF Forel can read")
        }
        guard !document.isLocked else {
            throw ActionError("This PDF is password-protected")
        }
        let needsOCR = Set(pagesNeedingOCR(document))
        var mediaBox = CGRect.zero
        guard let context = CGContext(URL(fileURLWithPath: destination) as CFURL, mediaBox: &mediaBox, auxiliaryInfo(document)) else {
            throw ActionError("Couldn't create the searchable PDF")
        }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            var box = page.bounds(for: .mediaBox)
            let pageInfo = [kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary
            context.beginPDFPage(pageInfo)
            page.draw(with: .mediaBox, to: context)
            if needsOCR.contains(index), let image = ContentExtractor.renderForOCR(page) {
                let lines = ContentExtractor.recognizeTextLines(in: image)
                drawInvisibleText(lines, in: context, area: box)
            }
            context.endPDFPage()
        }
        context.closePDF()
    }

    /// Lays a scanned image onto a single PDF page with an invisible text
    /// layer, so the result can be searched and its text selected.
    static func makeSearchablePDF(fromImage source: String, destination: String) throws {
        let orientedImage: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 12_000,
        ]
        guard let imageSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: source) as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, orientedImage as CFDictionary) else {
            throw ActionError("This file isn't an image Forel can read")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
        let dpi = max((properties?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72, 72)
        let scale = 72 / dpi
        var box = CGRect(x: 0, y: 0, width: Double(image.width) * scale, height: Double(image.height) * scale)
        guard let context = CGContext(URL(fileURLWithPath: destination) as CFURL, mediaBox: &box, nil) else {
            throw ActionError("Couldn't create the searchable PDF")
        }
        context.beginPDFPage(nil)
        context.draw(image, in: box)
        drawInvisibleText(ContentExtractor.recognizeTextLines(in: image), in: context, area: box)
        context.endPDFPage()
        context.closePDF()
    }

    private static func auxiliaryInfo(_ document: PDFDocument) -> CFDictionary? {
        var info: [String: Any] = [:]
        let attributes = document.documentAttributes ?? [:]
        if let title = attributes[PDFDocumentAttribute.titleAttribute] as? String { info[kCGPDFContextTitle as String] = title }
        if let author = attributes[PDFDocumentAttribute.authorAttribute] as? String { info[kCGPDFContextAuthor as String] = author }
        return info.isEmpty ? nil : info as CFDictionary
    }

    /// Draws each recognized line in invisible text mode, stretched to the
    /// width Vision found it at, so selecting text in a PDF viewer lines up
    /// with what's printed on the page.
    private static func drawInvisibleText(_ lines: [ContentExtractor.RecognizedLine], in context: CGContext, area: CGRect) {
        context.saveGState()
        context.setTextDrawingMode(.invisible)
        for line in lines {
            let rect = CGRect(
                x: area.minX + line.box.minX * area.width,
                y: area.minY + line.box.minY * area.height,
                width: line.box.width * area.width,
                height: line.box.height * area.height
            )
            guard rect.width > 1, rect.height > 1 else { continue }
            let font = CTFontCreateWithName("Helvetica" as CFString, rect.height * 0.85, nil)
            let attributed = NSAttributedString(
                string: line.text,
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
            )
            let ctLine = CTLineCreateWithAttributedString(attributed)
            let width = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
            guard width > 0 else { continue }
            context.textMatrix = CGAffineTransform(scaleX: rect.width / width, y: 1)
            context.textPosition = CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.15)
            CTLineDraw(ctLine, context)
        }
        context.restoreGState()
    }

    private static func fileSize(_ path: String) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? UInt64) ?? 0
    }
}
