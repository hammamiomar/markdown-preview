import AppKit
import PDFKit
import WebKit

@MainActor
final class DocumentExportSession {
    enum Format { case pdf, png }

    private let html: String
    private let baseURL: URL?
    private let previewSize: NSSize
    private let previewZoom: CGFloat
    private let appearance: NSAppearance
    private let configuration: WKWebViewConfiguration
    private var pages: [Format: ExportPage] = [:]
    private var printCompletion: ExportPrintCompletion?
    private(set) var isClosed = false

    private init(html: String, source: WKWebView, configuration: WKWebViewConfiguration) {
        self.html = html
        baseURL = source.url
        previewSize = source.bounds.size
        previewZoom = source.pageZoom
        appearance = source.effectiveAppearance
        self.configuration = configuration
    }

    static func capture(
        from source: WKWebView,
        configuration: WKWebViewConfiguration = WKWebViewConfiguration()
    ) async throws -> DocumentExportSession {
        let result = try await source.callAsyncJavaScript("""
            await window.MdPreview?.mermaidRenderAll?.();
            await document.fonts.ready;
            const copy = document.documentElement.cloneNode(true);
            copy.querySelectorAll('script, #md-print-size').forEach(node => node.remove());
            const checkboxes = document.querySelectorAll('input[type="checkbox"]');
            copy.querySelectorAll('input[type="checkbox"]').forEach((box, index) => {
                box.toggleAttribute('checked', checkboxes[index].checked);
            });
            return '<!DOCTYPE html>' + copy.outerHTML;
            """, in: nil, contentWorld: .page)
        guard let html = result as? String else {
            throw exportError("The document could not be prepared for export.")
        }
        configuration.preferences = source.configuration.preferences
        configuration.websiteDataStore = source.configuration.websiteDataStore
        return DocumentExportSession(html: html, source: source, configuration: configuration)
    }

    func webView(for format: Format) async throws -> WKWebView {
        guard !isClosed else { throw CancellationError() }
        if let page = pages[format] { return page.webView }
        let size = format == .pdf
            ? NSSize(width: MarkdownHTML.preferredPageWidth, height: previewSize.height)
            : previewSize
        let page = ExportPage(size: size, configuration: configuration)
        page.webView.appearance = appearance
        page.webView.pageZoom = format == .png ? previewZoom : 1
        pages[format] = page
        do {
            try await page.load(html, baseURL: baseURL)
            let css = format == .pdf ? MarkdownHTML.previewPrintOverrideCSS : ""
            _ = try await page.webView.callAsyncJavaScript("""
                document.documentElement.classList.add(printClass);
                const style = document.createElement('style');
                style.textContent = css;
                document.head.append(style);
                const images = Array.from(document.images);
                images.forEach(image => { image.loading = 'eager'; });
                await Promise.allSettled(images.map(image => image.decode()));
                await document.fonts.ready;
                \(ExportTableLayout.prepareScript)
                """, arguments: ["printClass": MarkdownHTML.previewPrintClass, "css": css],
                in: nil, contentWorld: .page)
            guard !isClosed else { throw CancellationError() }
            return page.webView
        } catch {
            pages.removeValue(forKey: format)?.close()
            throw error
        }
    }

    func runPrintOperation(_ operation: NSPrintOperation, from window: NSWindow) async -> Bool {
        let completion = ExportPrintCompletion()
        printCompletion = completion
        defer {
            printCompletion = nil
            close()
        }
        return await completion.run(operation, from: window)
    }

    func writePNG(to url: URL) async throws {
        defer { pages.removeValue(forKey: .png)?.close() }
        let view = try await webView(for: .png)
        // WebKit's PDF capture uses screen media and one continuous page.
        let data = try await view.pdf(configuration: WKPDFConfiguration())
        try Self.writePNG(fromPDF: data, to: url)
    }

    func close() {
        isClosed = true
        pages.values.forEach { $0.close() }
        pages.removeAll()
    }

    private static func exportError(_ message: String) -> NSError {
        NSError(domain: "doc.md-preview.export", code: 1, userInfo: [
            NSLocalizedDescriptionKey: NSLocalizedString(message, comment: "Document export failure"),
        ])
    }
}

@MainActor
private final class ExportPage: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private let window: NSWindow
    private var navigation: CheckedContinuation<Void, Error>?

    init(size: NSSize, configuration: WKWebViewConfiguration) {
        let frame = NSRect(origin: .zero, size: size)
        webView = WKWebView(frame: frame, configuration: configuration)
        window = NSWindow(contentRect: frame, styleMask: [], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.contentView = webView
        webView.navigationDelegate = self
    }

    func load(_ html: String, baseURL: URL?) async throws {
        try await withCheckedThrowingContinuation { continuation in
            navigation = continuation
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    func close() {
        finish(.failure(CancellationError()))
        webView.stopLoading()
        webView.navigationDelegate = nil
        window.close()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<Void, Error>) {
        let continuation = navigation
        navigation = nil
        continuation?.resume(with: result)
    }
}

@MainActor
private final class ExportPrintCompletion: NSObject {
    private var continuation: CheckedContinuation<Bool, Never>?

    func run(_ operation: NSPrintOperation, from window: NSWindow) async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            operation.runModal(for: window, delegate: self,
                               didRun: #selector(didRun(_:success:contextInfo:)), contextInfo: nil)
        }
    }

    // AppKit can finish printing on its print worker thread.
    @objc nonisolated private func didRun(_ operation: NSPrintOperation, success: Bool,
                                         contextInfo: UnsafeMutableRawPointer?) {
        Task { @MainActor in
            let continuation = self.continuation
            self.continuation = nil
            continuation?.resume(returning: success)
        }
    }
}

extension DocumentExportSession {
    private static func writePNG(fromPDF data: Data, to url: URL) throws {
        guard let document = PDFDocument(data: data), document.pageCount > 0 else {
            throw exportError("The document could not be rendered as an image.")
        }

        // 2x so the result stays sharp on Retina displays and when zoomed.
        let scale: CGFloat = 2
        let pages = (0..<document.pageCount).compactMap { document.page(at: $0) }
        let bounds = pages.map { $0.bounds(for: .mediaBox) }
        let width = bounds.map(\.width).max() ?? 0
        let height = bounds.map(\.height).reduce(0, +)
        guard width > 0, height > 0 else {
            throw exportError("The document could not be rendered as an image.")
        }

        let pixelWidth = Int((width * scale).rounded())
        let pixelHeight = Int((height * scale).rounded())
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw exportError("The image could not be allocated.")
        }
        rep.size = NSSize(width: width, height: height)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
            throw exportError("The image could not be allocated.")
        }
        NSGraphicsContext.current = context
        let cgContext = context.cgContext
        cgContext.scaleBy(x: scale, y: scale)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        // PDF origin is bottom-left, so stack downward from the top edge.
        var offsetY = height
        for (page, pageBounds) in zip(pages, bounds) {
            offsetY -= pageBounds.height
            cgContext.saveGState()
            cgContext.translateBy(x: 0, y: offsetY)
            page.draw(with: .mediaBox, to: cgContext)
            cgContext.restoreGState()
        }

        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw exportError("The image could not be encoded.")
        }
        try png.write(to: url)
    }

}
