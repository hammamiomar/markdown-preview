import AppKit
import PDFKit
import WebKit
import XCTest
@testable import MarkdownHelpers

@MainActor
final class MarkdownHTMLPDFExportTests: XCTestCase {
    private let longValue = String(repeating: "WideValue", count: 28) + "ValueEnd"
    private let longHeader = String(repeating: "WideHeader", count: 24) + "HeaderEnd"
    private let prose = Array(repeating: "ordinary words of prose", count: 20).joined(separator: " ")

    private var tables: String {
        """
        | Measure | Meaning |
        | --- | --- |
        | Static | \(prose) |

        | Category | Value |
        | --- | --- |
        | Stable | \(longValue) |

        | # | First | Second |
        | --- | --- | --- |
        | 1 | \(longValue) | \(longValue) |

        | Mixed \(longHeader) | Description |
        | --- | --- |
        | Ordinary | \(String(repeating: prose + " ", count: 6)) |

        <table><tr><th colspan="2">\(longHeader)</th></tr>
        <tr><td rowspan="2">Grouped</td><td>\(prose)</td></tr>
        <tr><td><a href="https://example.com"><em>\(longValue.prefix(120))</em>\(longValue.dropFirst(120))</a></td></tr></table>
        """
    }

    func testPDFAndPNGKeepWordsWholeAndPreserveWideText() async throws {
        for width: CGFloat in [500, 1200] {
            for margins in [0.0, 60.0] {
                let harness = makeHarness(markdown: tables, width: width, margins: margins)
                defer { harness.close() }
                let labels = ["Measure", "Static", "Category", "Stable", "Mixed", "Ordinary", "Grouped"]
                let before = try await harness.layout(texts: labels, imageCount: 0)
                let source = try await documentState(harness.webView)
                let name = "tables-\(Int(width))-margins-\(Int(margins))"

                let session = try await DocumentExportSession.capture(from: harness.webView)
                defer { session.close() }
                let imageView = try await session.webView(for: .png)
                let imagePDFData = try await imageView.pdf(configuration: WKPDFConfiguration())
                let imagePDF = try XCTUnwrap(PDFDocument(data: imagePDFData))
                XCTAssertEqual(imagePDF.page(at: 0)?.bounds(for: .mediaBox).width, width)
                assertCompleteText([longHeader, longValue, prose], in: imagePDF)
                assertWholeWords(labels, in: imagePDF)
                assertTextInsidePages(imagePDF)
                try saveArtifact(try XCTUnwrap(imagePDF.dataRepresentation()), name: "\(name)-png-capture.pdf")
                let imageURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
                defer { try? FileManager.default.removeItem(at: imageURL) }
                try await session.writePNG(to: imageURL)
                let imageData = try Data(contentsOf: imageURL)
                let image = try XCTUnwrap(NSBitmapImageRep(data: imageData))
                XCTAssertEqual(image.pixelsWide, Int(width * 2))
                try saveArtifact(imageData, name: "\(name).png")

                let pdfView = try await session.webView(for: .pdf)
                let pdf = try await printPDF(pdfView, session: session, name: name)
                XCTAssertTrue(session.isClosed)
                assertCompleteText([longHeader, longValue, prose], in: pdf)
                assertWholeWords(labels, in: pdf)
                assertTextInsidePages(pdf)

                let after = try await harness.layout(texts: labels, imageCount: 0)
                XCTAssertEqual(after, before)
                let finalSource = try await documentState(harness.webView)
                XCTAssertEqual(finalSource, source)
            }
        }
    }

    func testCancellationAndRepeatedExportsLeavePaperPrintingIntact() async throws {
        let harness = makeHarness(markdown: tables)
        defer { harness.close() }
        _ = try await harness.layout(texts: [], imageCount: 0)
        _ = try await harness.webView.evaluateJavaScript("window.scrollTo(0, 120); document.querySelectorAll('table')[1].scrollLeft = 80;")
        let before = try await documentState(harness.webView)

        for attempt in 1...2 {
            let session = try await DocumentExportSession.capture(from: harness.webView)
            let view = try await session.webView(for: .pdf)
            let window = makeWindow()
            defer { window.close() }
            let operation = printOperation(view)
            let panel = CancellingPrintPanel()
            let imageURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
            defer { try? FileManager.default.removeItem(at: imageURL) }
            if attempt == 2 {
                panel.beforeCancel = { try await session.writePNG(to: imageURL) }
            }
            operation.printPanel = panel
            operation.showsPrintPanel = true
            let success = await session.runPrintOperation(operation, from: window)
            XCTAssertFalse(success)
            XCTAssertNil(panel.error)
            if attempt == 2 {
                XCTAssertNotNil(NSBitmapImageRep(data: try Data(contentsOf: imageURL)))
            }
            XCTAssertTrue(session.isClosed)
            let after = try await documentState(harness.webView)
            XCTAssertEqual(after, before)
        }

        let exported = try await DocumentExportSession.capture(from: harness.webView)
        let view = try await exported.webView(for: .pdf)
        _ = try await printPDF(view, session: exported, name: "repeated-export")
        let paper = try await printPDF(harness.webView, name: "regular-print")
        assertCompleteText([longHeader, longValue, prose], in: paper)
        assertTextInsidePages(paper)
    }

    func testPDFTableContinuesAcrossPages() async throws {
        let rows = (1...70).map { "| Status\($0) | \(prose) |" }.joined(separator: "\n")
        let harness = makeHarness(markdown: "| Label | Description |\n| --- | --- |\n\(rows)")
        defer { harness.close() }
        _ = try await harness.layout(texts: [], imageCount: 0)
        let session = try await DocumentExportSession.capture(from: harness.webView)
        let view = try await session.webView(for: .pdf)
        let pdf = try await printPDF(view, session: session, name: "multiple-pages")
        XCTAssertGreaterThan(pdf.pageCount, 1)
        assertWholeWords((1...70).map { "Status\($0)" }, in: pdf)
        assertCompleteText([prose], in: pdf)
        assertTextInsidePages(pdf)
    }

    func testEmergencyWrappingKeepsTheOriginalTextSize() async throws {
        let markdown = """
        Table export example.

        | Category | Value |
        | --- | --- |
        | Static | \(longValue) |

        Following text.
        """
        let harness = makeHarness(markdown: markdown)
        defer { harness.close() }
        _ = try await harness.layout(texts: [], imageCount: 0)
        let session = try await DocumentExportSession.capture(from: harness.webView)
        let view = try await session.webView(for: .pdf)
        let pdf = try await printPDF(view, session: session, name: "ordinary-table")
        XCTAssertEqual(try textBounds("Static", in: pdf).height,
                       try textBounds("Table export example.", in: pdf).height, accuracy: 0.1)
        assertWholeWords(["Category", "Static"], in: pdf)
        assertCompleteText([longValue], in: pdf)
        assertTextInsidePages(pdf)
    }

    func testDenseTablesScaleWithoutSplittingWordsOrShrinkingSurroundingText() async throws {
        let surroundingText = "Surrounding text."
        let reference = makeHarness(markdown: surroundingText)
        defer { reference.close() }
        _ = try await reference.layout(texts: [], imageCount: 0)
        let referenceSession = try await DocumentExportSession.capture(from: reference.webView)
        let referenceView = try await referenceSession.webView(for: .pdf)
        let referencePDF = try await printPDF(referenceView, session: referenceSession, name: "ordinary-text")
        let referenceHeight = try textBounds(surroundingText, in: referencePDF).height

        for (columns, rowCount) in [(16, 1), (20, 1), (40, 1), (20, 140)] {
            let heading = "| " + Array(repeating: "Category", count: columns).joined(separator: " | ")
                + " |\n| " + Array(repeating: "---", count: columns).joined(separator: " | ") + " |"
            let rows = (1...rowCount).map { row in
                "| Row\(row) | " + Array(repeating: "Static", count: columns - 1).joined(separator: " | ") + " |"
            }.joined(separator: "\n")
            let harness = makeHarness(markdown: "\(surroundingText)\n\n\(heading)\n\(rows)\n\nFollowing text.")
            defer { harness.close() }
            _ = try await harness.layout(texts: [], imageCount: 0)
            let session = try await DocumentExportSession.capture(from: harness.webView)
            let view = try await session.webView(for: .pdf)
            let pdf = try await printPDF(view, session: session, name: "dense-\(columns)-\(rowCount)")
            assertWholeWords(["Category", "Static"] + (1...rowCount).map { "Row\($0)" }, in: pdf)
            XCTAssertEqual(try textBounds(surroundingText, in: pdf).height, referenceHeight, accuracy: 0.1)
            XCTAssertEqual(try textBounds("Following text.", in: pdf).height, referenceHeight, accuracy: 0.1)
            if rowCount == 1 {
                XCTAssertEqual(pdf.pageCount, 1)
                let tableBottom = try textBounds("Row1", in: pdf).minY
                XCTAssertLessThan(try textBounds("Following text.", in: pdf).maxY, tableBottom)
            } else {
                XCTAssertGreaterThan(pdf.pageCount, 1)
            }
            assertTextInsidePages(pdf)
        }
    }

    func testPNGPreservesPreviewZoomAndReaderFont() async throws {
        let harness = makeHarness(markdown: "| Category | Value |\n|---|---|\n| Static | \(longValue) |",
                                  width: 600, zoom: 1.25, font: .georgia)
        defer { harness.close() }
        _ = try await harness.layout(texts: [], imageCount: 0)
        let session = try await DocumentExportSession.capture(from: harness.webView)
        defer { session.close() }
        let view = try await session.webView(for: .png)
        XCTAssertEqual(view.pageZoom, harness.webView.pageZoom)
        let sourceFont = try await harness.webView.evaluateJavaScript("getComputedStyle(document.body).fontFamily") as? String
        let exportFont = try await view.evaluateJavaScript("getComputedStyle(document.body).fontFamily") as? String
        XCTAssertEqual(sourceFont, exportFont)
        let data = try await view.pdf(configuration: WKPDFConfiguration())
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        assertWholeWords(["Category", "Static"], in: pdf)
        assertCompleteText([longValue], in: pdf)
        assertTextInsidePages(pdf)
        try saveArtifact(try XCTUnwrap(pdf.dataRepresentation()), name: "png-zoom-serif.pdf")
    }

    func testExportSnapshotPreservesRenderedMediaAndColors() async throws {
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"160\" height=\"50\"><rect width=\"160\" height=\"50\" fill=\"royalblue\"/></svg>"
        let image = "data:image/svg+xml;base64," + Data(svg.utf8).base64EncodedString()
        let markdown = """
        # Rendered content

        ![Image](\(image))

        $E = mc^2$

        ```swift
        let message = "Hello"
        ```

        ```mermaid
        flowchart LR
          A[Start] --> B[Finish]
        ```

        | Category | Value |
        | --- | --- |
        | Static | \(longValue) |
        """
        let html = MarkdownHTML.render(markdown: markdown, allowsScroll: true, vendorLoading: .inline,
                                       colorScheme: .dark, documentFont: .georgia).html
        let harness = WebViewLayoutHarness(html: html, width: 900, isEditor: false, height: 600)
        defer { harness.close() }
        _ = try await harness.layout(texts: [], imageCount: 1, selectors: [".katex": 1])
        let session = try await DocumentExportSession.capture(from: harness.webView)
        defer { session.close() }
        let mediaScript = """
            JSON.stringify({
                images: Array.from(document.images).map(i => [i.naturalWidth, i.naturalHeight]),
                math: document.querySelector('.katex')?.outerHTML,
                diagram: document.querySelector('.mermaid svg')?.outerHTML,
                code: document.querySelector('pre code')?.innerHTML,
                color: getComputedStyle(document.body).color
            })
            """
        let source = try await harness.webView.evaluateJavaScript(mediaScript) as? String
        for format: DocumentExportSession.Format in [.pdf, .png] {
            let view = try await session.webView(for: format)
            let exported = try await view.evaluateJavaScript(mediaScript) as? String
            XCTAssertEqual(exported, source)
            let scriptCount = try await view.evaluateJavaScript("document.scripts.length") as? Int
            XCTAssertEqual(scriptCount, 0)
        }
        let imageURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: imageURL) }
        try await session.writePNG(to: imageURL)
        try saveArtifact(Data(contentsOf: imageURL), name: "rendered-media.png")
        let view = try await session.webView(for: .pdf)
        let pdf = try await printPDF(view, session: session, name: "rendered-media")
        assertWholeWords(["Rendered", "Start", "Finish", "Category", "Static"], in: pdf)
        assertCompleteText([longValue], in: pdf)
        assertTextInsidePages(pdf)
    }

    private func makeHarness(markdown: String, width: CGFloat = 900, margins: Double = 0,
                             zoom: CGFloat = 1, font: DocumentFontSetting = .system) -> WebViewLayoutHarness {
        _ = NSApplication.shared
        let html = MarkdownHTML.render(
            markdown: markdown, allowsScroll: true, vendorLoading: .lazy,
            colorScheme: .light, documentFont: font,
            readerLayout: .init(isCustomized: true, marginsPercent: margins)
        ).html
        return WebViewLayoutHarness(html: html, width: width, isEditor: false, zoom: zoom, height: 600)
    }

    private func documentState(_ view: WKWebView) async throws -> String? {
        try await view.evaluateJavaScript("""
            JSON.stringify({
                article: document.querySelector('article').outerHTML,
                rootClass: document.documentElement.className,
                scroll: [scrollX, scrollY],
                tables: Array.from(document.querySelectorAll('table')).map(t => t.scrollLeft)
            })
            """) as? String
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func printOperation(_ view: WKWebView) -> NSPrintOperation {
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 612, height: 792)
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = false
        let operation = view.printOperation(with: info)
        operation.view?.frame = view.bounds
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        return operation
    }

    private func printPDF(_ view: WKWebView, session: DocumentExportSession? = nil,
                          name: String) async throws -> PDFDocument {
        let window = makeWindow()
        defer { window.close() }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: output) }
        let operation = printOperation(view)
        operation.printInfo.jobDisposition = .save
        operation.printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = output
        let owner: DocumentExportSession
        if let session { owner = session }
        else { owner = try await DocumentExportSession.capture(from: view) }
        let success = await owner.runPrintOperation(operation, from: window)
        XCTAssertTrue(success, "Printing did not complete")
        let data = try Data(contentsOf: output)
        try saveArtifact(data, name: "\(name).pdf")
        return try XCTUnwrap(PDFDocument(data: data))
    }

    private func saveArtifact(_ data: Data, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["MDP_PDF_ARTIFACTS"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name))
    }

    private func textBounds(_ text: String, in pdf: PDFDocument) throws -> CGRect {
        let selection = try XCTUnwrap(pdf.findString(text, withOptions: []).first)
        return selection.bounds(for: try XCTUnwrap(selection.pages.first))
    }

    private func assertCompleteText(_ values: [String], in pdf: PDFDocument,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let text = (pdf.string ?? "").filter { !$0.isWhitespace }
        for value in values {
            XCTAssertTrue(text.contains(value.filter { !$0.isWhitespace }),
                          "PDF lost text: \(value)", file: file, line: line)
        }
    }

    private func assertWholeWords(_ words: [String], in pdf: PDFDocument,
                                  file: StaticString = #filePath, line: UInt = #line) {
        for word in words {
            let matches = pdf.findString(word, withOptions: [])
            XCTAssertFalse(matches.isEmpty, "Missing word: \(word)", file: file, line: line)
            for match in matches {
                XCTAssertEqual(match.selectionsByLine().count, 1, "Split word: \(word)", file: file, line: line)
            }
        }
    }

    private func assertTextInsidePages(_ pdf: PDFDocument, file: StaticString = #filePath, line: UInt = #line) {
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox).insetBy(dx: -1, dy: -1)
            for character in 0..<page.numberOfCharacters {
                let rect = page.characterBounds(at: character)
                if !rect.isEmpty {
                    XCTAssertTrue(bounds.contains(rect), "Text outside page \(index + 1)", file: file, line: line)
                }
            }
        }
    }
}

@MainActor
private final class CancellingPrintPanel: NSPrintPanel {
    var beforeCancel: (() async throws -> Void)?
    var error: Error?

    override func beginSheet(using printInfo: NSPrintInfo, on parentWindow: NSWindow,
                             completionHandler handler: ((NSPrintPanel.Result) -> Void)? = nil) {
        Task {
            do { try await beforeCancel?() }
            catch { self.error = error }
            handler?(.cancelled)
        }
    }
}
