import AppKit
import PDFKit
import WebKit

/// Lays HTML files out on pages with an offscreen WKWebView and WebKit's own print pagination, one file
/// at a time, and returns them joined into one PDF. Offline and confined by construction: a non-persistent
/// data store, JavaScript off, and a content rule list that blocks every http(s) load and every file: URL
/// outside the one folder the pages come from (`loadFileURL(_:allowingReadAccessTo:)` alone only limits
/// navigation, not the pictures, stylesheets and frames a page pulls in).
/// Everything WebKit touches runs on the main thread through MainThread, so it works from the job queue
/// and from the command line.
final class EbooksAndPagesRenderer: NSObject, WKNavigationDelegate {
    struct Page {
        var size = EbooksAndPagesRenderer.defaultPaper
        var margin: CGFloat = 54
    }

    /// A4, or US Letter where the region uses it.
    static var defaultPaper: CGSize {
        Locale.current.measurementSystem == .us ? CGSize(width: 612, height: 792) : CGSize(width: 595.28, height: 841.89)
    }

    private var webView: WKWebView!
    private var window: NSWindow!
    private var page = Page()
    private var output: URL?
    private var completion: ((Result<Void, Error>) -> Void)?
    private var navigation: WKNavigation?
    private var ruleStoreURL: URL?
    private var allowedRoots: [String] = []

    private static let ruleListID = "dropwheel-ebooks-offline-v2"

    /// Content rules: nothing from the network, and file: URLs only inside `folder` (both spellings of the
    /// temporary folder, /var/... and /private/var/...).
    static func contentRules(allowingFolder folder: URL) -> String {
        var rules: [[String: Any]] = [
            ["trigger": ["url-filter": "^https?:"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "^wss?:"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "^ftp:"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "^file:"], "action": ["type": "block"]],
        ]
        var paths = Set<String>()
        for p in [folder.standardizedFileURL.path, folder.resolvingSymlinksInPath().path] {
            paths.insert(p)
            if p.hasPrefix("/private/") { paths.insert(String(p.dropFirst("/private".count))) } else { paths.insert("/private" + p) }
        }
        for p in paths.sorted() {
            let prefix = URL(fileURLWithPath: p, isDirectory: true).absoluteString   // file:///…/book/
            rules.append(["trigger": ["url-filter": "^" + regexEscaped(prefix)], "action": ["type": "ignore-previous-rules"]])
        }
        let data = (try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// A literal for WebKit's content-rule regular expressions.
    private static func regexEscaped(_ s: String) -> String {
        var out = ""
        for c in s {
            if "\\^$.|?*+()[]{}".contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }

    /// Renders `files` (each a chapter; a chapter always starts on a new page) into one PDF document.
    /// `titles` become the PDF's bookmarks.
    static func render(_ files: [URL], titles: [String], readAccess: URL, page: Page = Page(),
                       progress: @escaping (Double) -> Void) throws -> PDFDocument {
        let renderer = MainThread.sync { EbooksAndPagesRenderer() }
        let rules = contentRules(allowingFolder: readAccess)
        try MainThread.wait(timeout: 60) { finish in renderer.setUp(page: page, rules: rules, finish) }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("dropwheel-print-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: scratch)
            MainThread.sync { renderer.tearDown() }
        }

        let combined = PDFDocument()
        let outline = PDFOutline()
        for (i, file) in files.enumerated() {
            let out = scratch.appendingPathComponent("part-\(i).pdf")
            try MainThread.wait(timeout: 240) { finish in renderer.printFile(file, readAccess: readAccess, to: out, finish) }
            // Read into memory: the scratch files are deleted before the combined PDF is saved.
            guard let data = try? Data(contentsOf: out), let part = PDFDocument(data: data), part.pageCount > 0 else {
                throw ConversionError.toolFailed("Couldn’t lay out \(file.lastPathComponent) on pages.")
            }
            let first = combined.pageCount
            for p in 0..<part.pageCount {
                if let pg = part.page(at: p) { combined.insert(pg, at: combined.pageCount) }
            }
            if i < titles.count, !titles[i].isEmpty, let target = combined.page(at: first) {
                let item = PDFOutline()
                item.label = titles[i]
                item.destination = PDFDestination(page: target, at: CGPoint(x: 0, y: target.bounds(for: .mediaBox).maxY))
                outline.insertChild(item, at: outline.numberOfChildren)
            }
            progress(Double(i + 1) / Double(max(files.count, 1)))
        }
        if outline.numberOfChildren > 1 { combined.outlineRoot = outline }
        return combined
    }

    // MARK: Main thread

    private func setUp(page: Page, rules: String, _ finish: @escaping (Result<Void, Error>) -> Void) {
        self.page = page
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.suppressesIncrementalRendering = true
        if #available(macOS 13.3, *) { config.preferences.shouldPrintBackgrounds = true }
        let frame = CGRect(origin: .zero, size: page.size)
        // An offscreen window gives the view a real backing for layout and printing.
        window = NSWindow(contentRect: frame.offsetBy(dx: -10_000, dy: -10_000), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // A throwaway store in the temporary folder, so nothing is left behind in ~/Library.
        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("dropwheel-rules-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true)
        ruleStoreURL = storeURL
        let store = WKContentRuleListStore(url: storeURL) ?? WKContentRuleListStore.default()!
        store.compileContentRuleList(forIdentifier: Self.ruleListID,
                                     encodedContentRuleList: rules) { [weak self] list, error in
            guard let self else { return }
            guard let list else {
                finish(.failure(ConversionError.toolFailed("Couldn’t set up offline rendering: \(error?.localizedDescription ?? "unknown error").")))
                return
            }
            config.userContentController.add(list)
            self.webView = WKWebView(frame: frame, configuration: config)
            if #available(macOS 13.3, *) { self.webView.isInspectable = false }
            self.webView.navigationDelegate = self
            self.window.contentView = self.webView
            finish(.success(()))
        }
    }

    private func tearDown() {
        if let ruleStoreURL { try? FileManager.default.removeItem(at: ruleStoreURL) }
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        window?.contentView = nil
        window?.close()
        webView = nil
        window = nil
    }

    private func printFile(_ file: URL, readAccess: URL, to out: URL, _ finish: @escaping (Result<Void, Error>) -> Void) {
        output = out
        completion = finish
        allowedRoots = Self.spellings(of: readAccess)
        navigation = webView.loadFileURL(file, allowingReadAccessTo: readAccess)
    }

    /// The folder's path, with a trailing slash, as /var/... and as /private/var/....
    private static func spellings(of folder: URL) -> [String] {
        var out = Set<String>()
        for p in [folder.standardizedFileURL.path, folder.resolvingSymlinksInPath().path] {
            let slashed = p.hasSuffix("/") ? p : p + "/"
            out.insert(slashed)
            out.insert(slashed.hasPrefix("/private/") ? String(slashed.dropFirst("/private".count)) : "/private" + slashed)
        }
        return Array(out)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Give layout one turn of the run loop before printing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.printLoadedPage() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        done(.failure(ConversionError.toolFailed("Couldn’t render the page: \(error.localizedDescription)")))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        done(.failure(ConversionError.toolFailed("Couldn’t open the page: \(error.localizedDescription)")))
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Only files inside the folder; no remote pages.
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        if url.scheme == "about" { return decisionHandler(.allow) }
        let path = url.standardizedFileURL.path
        decisionHandler(url.isFileURL && allowedRoots.contains { path.hasPrefix($0) } ? .allow : .cancel)
    }

    private func printLoadedPage() {
        guard let output else { return }
        let info = NSPrintInfo()
        info.paperSize = page.size
        info.topMargin = page.margin
        info.bottomMargin = page.margin
        info.leftMargin = page.margin
        info.rightMargin = page.margin
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = output
        let op = webView.printOperation(with: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        op.view?.frame = CGRect(origin: .zero, size: page.size)
        // A synchronous run() deadlocks with WebKit's out-of-process printing; the window-modal form
        // returns at once and reports back through the delegate when the PDF is written.
        op.runModal(for: window, delegate: self, didRun: #selector(printOperationDidRun(_:success:contextInfo:)),
                    contextInfo: nil)
    }

    @objc private func printOperationDidRun(_ op: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        let ok = success && output.map { FileManager.default.fileExists(atPath: $0.path) } == true
        done(ok ? .success(()) : .failure(ConversionError.toolFailed("Printing to PDF failed.")))
    }

    private func done(_ result: Result<Void, Error>) {
        let c = completion
        completion = nil
        c?(result)
    }
}
