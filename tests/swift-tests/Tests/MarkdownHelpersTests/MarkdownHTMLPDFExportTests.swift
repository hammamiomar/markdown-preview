import AppKit
import PDFKit
import WebKit
import XCTest
@testable import MarkdownHelpers

@MainActor
final class MarkdownHTMLPDFExportTests: XCTestCase {
    func testWideTableWordsSurvivePDFExportAndPaperPrinting() async throws {
        _ = NSApplication.shared
        let header = String(repeating: "WideHeader", count: 24) + "HeaderEnd"
        let value = String(repeating: "WideValue", count: 28) + "ValueEnd"
        let markdown = "| \(header) |\n| --- |\n| \(value) |"
        let rendered = MarkdownHTML.render(
            markdown: markdown, allowsScroll: true, vendorLoading: .lazy,
            colorScheme: .light, documentFont: .system, readerLayout: .init()
        )

        for matchesPreview in [true, false] {
            let mode = matchesPreview ? "PDF export" : "paper printing"
            let harness = WebViewLayoutHarness(
                html: rendered.html, width: 900, isEditor: false, height: 600
            )
            defer { harness.close() }
            if matchesPreview {
                _ = try await harness.layout(texts: [], imageCount: 0)
                _ = try await harness.webView.callAsyncJavaScript("""
                    document.documentElement.classList.add(printClass);
                    const style = document.createElement('style');
                    style.textContent = printCSS;
                    document.head.appendChild(style);
                    """, arguments: [
                        "printClass": MarkdownHTML.previewPrintClass,
                        "printCSS": MarkdownHTML.previewPrintOverrideCSS,
                    ], in: nil, contentWorld: .page)
            }
            let screen = try await harness.layout(texts: [header, value], imageCount: 0)
            XCTAssertEqual(screen.elements.map(\.lines.count), [1, 1],
                           "\(mode) setup must preserve whole words on screen")
            XCTAssertTrue(screen.elements.allSatisfy { $0.rect.width > screen.columnWidth })

            let window = NSWindow(
                contentRect: harness.webView.frame, styleMask: [.titled],
                backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = harness.webView
            defer { window.close() }

            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let output = directory.appendingPathComponent("table.pdf")
            let printInfo = NSPrintInfo()
            printInfo.paperSize = NSSize(width: 612, height: 792)
            printInfo.horizontalPagination = .fit
            printInfo.verticalPagination = .automatic
            printInfo.isHorizontallyCentered = true
            printInfo.isVerticallyCentered = false
            printInfo.jobDisposition = .save
            printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = output

            let operation = harness.webView.printOperation(with: printInfo)
            operation.view?.frame = harness.webView.bounds
            operation.showsPrintPanel = false
            operation.showsProgressPanel = false
            let completion = PDFPrintCompletion()
            operation.runModal(
                for: window, delegate: completion,
                didRun: #selector(PDFPrintCompletion.didRun(_:success:contextInfo:)),
                contextInfo: nil
            )
            let deadline = Date().addingTimeInterval(30)
            while completion.success == nil && Date() < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(completion.success, true, "\(mode) did not produce a PDF")

            let pdf = try XCTUnwrap(PDFDocument(url: output))
            XCTAssertEqual(pdf.pageCount, 1, mode)
            let text = try XCTUnwrap(pdf.string).filter { !$0.isWhitespace }
            XCTAssertTrue(text.contains(header), "\(mode) clipped the header: \(text)")
            XCTAssertTrue(text.contains(value), "\(mode) clipped the cell: \(text)")
            let page = try XCTUnwrap(pdf.page(at: 0))
            let bounds = page.bounds(for: .mediaBox).insetBy(dx: -1, dy: -1)
            for index in 0..<page.numberOfCharacters {
                let character = page.characterBounds(at: index)
                if !character.isEmpty {
                    XCTAssertTrue(bounds.contains(character), "\(mode) placed text outside the page")
                }
            }
        }
    }
}

@MainActor
private final class PDFPrintCompletion: NSObject {
    var success: Bool?

    // AppKit may finish modal printing on its print worker thread.
    @objc nonisolated func didRun(_ operation: NSPrintOperation, success: Bool,
                                  contextInfo: UnsafeMutableRawPointer?) {
        Task { @MainActor in self.success = success }
    }
}
