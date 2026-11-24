import AppKit
import PDFKit
import UniformTypeIdentifiers

/// One page in the organizer: a page of a source document plus the quarter turns the user added.
/// Source pages are never changed; Save writes copies.
struct PDFOrganizerPage {
    var id = UUID()
    let page: PDFPage
    /// "report.pdf, page 3", for tooltips.
    let label: String
    /// Degrees added to the page's own rotation (0, 90, 180 or 270).
    var turn = 0

    /// The page's visible size with its own rotation and the added turn.
    var displaySize: CGSize {
        let box = page.bounds(for: .cropBox).size
        let total = PDFOrganizer.normalized(page.rotation + turn)
        return total % 180 == 0 ? box : CGSize(width: box.height, height: box.width)
    }
}

/// "Organize…": reorder, delete, rotate, duplicate and insert pages, then save "<name> organized.pdf".
enum PDFOrganizer {
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "bmp",
                                               "webp", "avif", "jp2"]

    /// At least one PDF, and nothing but PDFs and images (images become pages).
    static func applies(_ files: [URL]) -> Bool {
        guard files.contains(where: { Ext.of($0) == "pdf" }) else { return false }
        return files.allSatisfy { Ext.of($0) == "pdf" || imageExtensions.contains(Ext.of($0)) }
    }

    static func normalized(_ degrees: Int) -> Int { ((degrees % 360) + 360) % 360 }

    // MARK: Loading and saving

    /// Every page of each PDF and of each image (one, or one per page of a multi-page TIFF), in order, an image
    /// on A4 or US Letter like Merge PDF. The documents must stay alive while their pages are used, so they are
    /// returned too. Locked PDFs are refused.
    static func load(_ files: [URL]) throws -> (pages: [PDFOrganizerPage], documents: [PDFDocument]) {
        var pages: [PDFOrganizerPage] = []
        var documents: [PDFDocument] = []
        for url in files {
            let ext = Ext.of(url)
            if ext == "pdf" || FileKind.of(url) == .pdf {
                guard let doc = PDFDocument(url: url) else { throw ConversionError.unreadable(url.lastPathComponent) }
                if doc.isLocked { throw PDFExtras.lockedError(url) }
                documents.append(doc)
                for i in 0..<doc.pageCount {
                    guard let page = doc.page(at: i) else { continue }
                    pages.append(PDFOrganizerPage(page: page, label: "\(url.lastPathComponent), page \(i + 1)"))
                }
            } else if imageExtensions.contains(ext) || FileKind.of(url) == .image {
                try PDFTools.imagePDFPages(url) { page, index, count in   // every page of a multi-page TIFF
                    let label = count > 1 ? "\(url.lastPathComponent), page \(index + 1)" : url.lastPathComponent
                    pages.append(PDFOrganizerPage(page: page, label: label))
                }
            } else {
                throw ConversionError.unsupported("\(url.lastPathComponent) isn’t a PDF or an image.")
            }
        }
        return (pages, documents)
    }

    /// Writes the pages, in order, to "<source> organized.pdf" (never over an existing file).
    /// Bookmarks and internal links follow their pages; those pointing at deleted pages are dropped.
    static func write(_ pages: [PDFOrganizerPage], next source: URL, attributes: [AnyHashable: Any]?) throws -> URL {
        guard !pages.isEmpty else { throw ConversionError.unsupported("There are no pages left to save.") }
        let copier = PDFPageCopier()
        for p in pages {
            guard copier.append(p.page, adjust: { $0.rotation = normalized($0.rotation + p.turn) }) else {
                throw ConversionError.toolFailed("Couldn’t copy \(p.label).")
            }
        }
        let doc = copier.finish()
        if let attributes {
            let kept: [PDFDocumentAttribute] = [.titleAttribute, .authorAttribute, .subjectAttribute, .keywordsAttribute,
                                                .creatorAttribute]
            doc.documentAttributes = attributes.filter { key, _ in
                kept.contains { $0.rawValue == (key as? String) || $0 == (key as? PDFDocumentAttribute) }
            }
        }
        let out = outputURL(for: source, ext: "pdf", suffix: " organized")
        guard doc.write(to: out) else {
            try? FileManager.default.removeItem(at: out)
            throw ConversionError.toolFailed("Couldn’t save \(out.lastPathComponent).")
        }
        return out
    }

    // MARK: Headless

    /// Command-line organizer. Several files are combined first, then:
    /// - `order="3,1,2"`: the new page order (1-based, ranges like "4-6" or "6-4" allowed, "end" for the
    ///   last page). Pages left out are deleted; a page listed twice is duplicated. Default: unchanged.
    /// - `rotate="1:90,3:-90"`: turns added to pages, by their number in the combined input (so every copy
    ///   of that page turns). Ranges, "all:90", and "left"/"right" work too.
    static func run(_ files: [URL], options: ToolOptions, progress: @escaping (Double) -> Void) throws -> URL {
        guard let first = files.first else { throw ConversionError.unsupported("Nothing to organize.") }
        let (loaded, documents) = try load(files)
        guard !loaded.isEmpty else { throw ConversionError.unsupported("\(first.lastPathComponent) has no pages.") }
        var source = loaded
        for (index, degrees) in try parseRotations(options.string("rotate", ""), count: loaded.count) {
            source[index].turn = normalized(source[index].turn + degrees)
        }
        let order = try parseOrder(options.string("order", ""), count: loaded.count) ?? Array(loaded.indices)
        guard !order.isEmpty else { throw ConversionError.unsupported("Can’t remove every page.") }
        let pages = order.map { index -> PDFOrganizerPage in
            var p = source[index]
            p.id = UUID()
            return p
        }
        progress(0.5)
        let out = try write(pages, next: first, attributes: documents.first?.documentAttributes)
        withExtendedLifetime(documents) {}
        progress(1)
        return out
    }

    /// "3,1,2" → [2, 0, 1]. nil when the text is empty (keep the order).
    static func parseOrder(_ text: String, count: Int) throws -> [Int]? {
        let tokens = text.split(whereSeparator: { ",; \t".contains($0) }).map(String.init)
        guard !tokens.isEmpty else { return nil }
        var order: [Int] = []
        for token in tokens { order += try pageRange(token, count: count) }
        return order
    }

    /// "1:90,3:-90" → [0: 90, 2: 270], keyed by 0-based page index.
    static func parseRotations(_ text: String, count: Int) throws -> [Int: Int] {
        var turns: [Int: Int] = [:]
        for token in text.split(whereSeparator: { ",; \t".contains($0) }).map(String.init) {
            let parts = token.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else {
                throw ConversionError.unsupported("“\(token)” isn’t a rotation. Use page:degrees, like 2:90.")
            }
            let degrees: Int
            switch parts[1].lowercased() {
            case "left": degrees = -90
            case "right": degrees = 90
            default:
                guard let d = Int(parts[1].replacingOccurrences(of: "+", with: "").replacingOccurrences(of: "°", with: "")) else {
                    throw ConversionError.unsupported("“\(parts[1])” isn’t a number of degrees.")
                }
                degrees = d
            }
            guard degrees % 90 == 0 else {
                throw ConversionError.unsupported("Pages turn in steps of 90°, so \(degrees)° won’t work.")
            }
            let indices = ["all", "*"].contains(parts[0].lowercased()) ? Array(0..<count) : try pageRange(parts[0], count: count)
            for i in indices { turns[i] = normalized((turns[i] ?? 0) + degrees) }
        }
        return turns
    }

    /// "4", "end", "2-5", "5-2", "3-" → 0-based indices.
    private static func pageRange(_ token: String, count: Int) throws -> [Int] {
        func number(_ s: Substring) throws -> Int {
            let t = s.trimmingCharacters(in: .whitespaces).lowercased()
            if t == "end" || t == "last" { return count }
            guard let n = Int(t) else { throw ConversionError.unsupported("“\(s)” isn’t a page number.") }
            guard n >= 1 && n <= count else {
                throw ConversionError.unsupported("Page \(n) doesn’t exist: there \(count == 1 ? "is 1 page" : "are \(count) pages").")
            }
            return n
        }
        let parts = token.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 {
            let a = try number(parts[0])
            let b = parts[1].isEmpty ? count : try number(parts[1])
            return (a <= b ? Array(a...b) : Array((b...a).reversed())).map { $0 - 1 }
        }
        return [try number(Substring(token)) - 1]
    }

    // MARK: Window

    /// Opens the organizer for the dropped files (app mode, main thread).
    static func present(_ files: [URL]) {
        do {
            let controller = try PDFOrganizerController(files: files)
            controller.showWindow()
        } catch {
            JobRunner.report(saved: [], errors: [error.localizedDescription])
        }
    }

    /// The organizer's content for `--snapshot organizer`, with thumbnails drawn up front.
    /// Options: width, height, size (thumbnail side), select ("1,3").
    static func snapshotView(files: [URL], options: ToolOptions) -> NSView? {
        guard !files.isEmpty, let controller = try? PDFOrganizerController(files: files, synchronous: true) else { return nil }
        controller.root.setFrameSize(CGSize(width: options.double("width", 900), height: options.double("height", 620)))
        controller.setThumbnailSide(CGFloat(options.double("size", 150)))
        if let order = try? parseOrder(options.string("select", ""), count: controller.pages.count) {
            controller.select(Set(order))
        }
        return controller.root
    }
}

// MARK: - Thumbnails

/// Renders page thumbnails off the main thread and caches them by page, turn and pixel size.
final class PDFOrganizerThumbnails {
    private let cache = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(label: "dropwheel.organizer.thumbnails", qos: .userInitiated)
    private var pending = Set<String>()

    static func key(_ p: PDFOrganizerPage, pixels: Int) -> String {
        "\(ObjectIdentifier(p.page).hashValue)-\(PDFOrganizer.normalized(p.turn))-\(pixels)"
    }

    func cached(_ p: PDFOrganizerPage, pixels: Int) -> NSImage? { cache.object(forKey: Self.key(p, pixels: pixels) as NSString) }

    /// Renders now, on the calling thread (snapshots).
    func renderNow(_ p: PDFOrganizerPage, pixels: Int) -> NSImage? {
        if let hit = cached(p, pixels: pixels) { return hit }
        guard let image = Self.render(p.page, turn: p.turn, pixels: pixels) else { return nil }
        cache.setObject(image, forKey: Self.key(p, pixels: pixels) as NSString)
        return image
    }

    /// The size thumbnails are wanted at now; queued work for other sizes (from moving the slider) is skipped.
    private let lock = NSLock()
    private var wantedPixels = 0

    /// Renders in the background and calls `done` on the main thread.
    func request(_ p: PDFOrganizerPage, pixels: Int, done: @escaping (String, NSImage) -> Void) {
        let key = Self.key(p, pixels: pixels)
        lock.lock(); wantedPixels = pixels; lock.unlock()
        guard !pending.contains(key) else { return }
        pending.insert(key)
        let page = p.page, turn = p.turn
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); let stale = self.wantedPixels != pixels; self.lock.unlock()
            let image = stale ? nil : Self.render(page, turn: turn, pixels: pixels)
            DispatchQueue.main.async {
                self.pending.remove(key)
                guard let image else { return }
                self.cache.setObject(image, forKey: key as NSString)
                done(key, image)
            }
        }
    }

    /// Waits for thumbnails being drawn, so pages aren't copied while they render.
    func drain() { queue.sync {} }

    /// The page on white, its long side `pixels` long. PDFKit applies the page's own rotation; the added
    /// turn rotates the context around the centre.
    static func render(_ page: PDFPage, turn: Int, pixels: Int) -> NSImage? {
        let box = page.bounds(for: .cropBox).size
        let base = PDFOrganizer.normalized(page.rotation)
        let baseSize = base % 180 == 0 ? box : CGSize(width: box.height, height: box.width)
        let t = PDFOrganizer.normalized(turn)
        let total = t % 180 == 0 ? baseSize : CGSize(width: baseSize.height, height: baseSize.width)
        guard total.width > 0, total.height > 0 else { return nil }
        let scale = CGFloat(pixels) / max(total.width, total.height)
        let w = max(1, Int((total.width * scale).rounded())), h = max(1, Int((total.height * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: total.width / 2, y: total.height / 2)
        ctx.rotate(by: -CGFloat(t) * .pi / 180)
        ctx.translateBy(x: -baseSize.width / 2, y: -baseSize.height / 2)
        page.draw(with: .cropBox, to: ctx)
        guard let cg = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cg, size: CGSize(width: w, height: h))
    }
}

// MARK: - Controller

/// The organizer window's model and views: a grid of pages with a button bar and a size slider.
final class PDFOrganizerController: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate, NSWindowDelegate {
    private static var open: [PDFOrganizerController] = []
    /// Open windows with reorganized pages that haven't been saved (the updater asks before a restart would lose them).
    static var unsavedCount: Int { open.filter(\.edited).count }
    static let pageType = NSPasteboard.PasteboardType("app.dropwheel.organizer-page")

    private(set) var pages: [PDFOrganizerPage]
    private var documents: [PDFDocument]
    private let sources: [URL]
    private let undo = UndoManager()
    private let synchronous: Bool
    private let thumbs = PDFOrganizerThumbnails()
    private var side: CGFloat = 150
    private var dragged: [Int] = []
    private var edited = false
    private var window: NSWindow?

    let root = PDFOrganizerRootView()
    let collection = PDFOrganizerCollectionView()
    let flow = NSCollectionViewFlowLayout()
    private let scroll = NSScrollView()
    private let slider = NSSlider(value: 150, minValue: 80, maxValue: 320, target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "No pages. Drop PDFs or images here, or click Add…")
    private var rotateLeftButton: NSButton!, rotateRightButton: NSButton!, duplicateButton: NSButton!
    private var deleteButton: NSButton!, undoButton: NSButton!, saveButton: NSButton!

    init(files: [URL], synchronous: Bool = false) throws {
        let loaded = try PDFOrganizer.load(files)
        guard !loaded.pages.isEmpty else { throw ConversionError.unsupported("There are no pages to organize.") }
        pages = loaded.pages
        documents = loaded.documents
        sources = files
        self.synchronous = synchronous
        super.init()
        root.controller = self
        buildViews()
        updateControls()
    }

    // MARK: Views

    private func button(_ title: String, _ symbol: String, _ action: Selector, tip: String) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        b.imagePosition = .imageLeading
        b.bezelStyle = .rounded
        b.toolTip = tip
        return b
    }

    private func buildViews() {
        root.frame = CGRect(x: 0, y: 0, width: 900, height: 620)

        let add = button("Add…", "plus", #selector(addFiles), tip: "Insert pages from PDFs or images (⌘O)")
        rotateLeftButton = button("Left", "rotate.left", #selector(rotateLeft), tip: "Rotate left (⌘L)")
        rotateRightButton = button("Right", "rotate.right", #selector(rotateRight), tip: "Rotate right (⌘R)")
        duplicateButton = button("Duplicate", "plus.square.on.square", #selector(duplicateSelected), tip: "Duplicate (⌘D)")
        deleteButton = button("Delete", "trash", #selector(deleteSelected), tip: "Delete (⌫)")
        undoButton = button("Undo", "arrow.uturn.backward", #selector(undoChange), tip: "Undo (⌘Z)")

        slider.target = self
        slider.action = #selector(sliderMoved)
        slider.controlSize = .small
        slider.toolTip = "Thumbnail size"
        slider.widthAnchor.constraint(equalToConstant: 120).isActive = true
        let small = NSImageView(image: NSImage(systemSymbolName: "square.grid.3x3", accessibilityDescription: "Smaller")!)
        let large = NSImageView(image: NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Larger")!)
        for v in [small, large] { v.contentTintColor = .secondaryLabelColor; v.symbolConfiguration = .init(scale: .small) }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let top = NSStackView(views: [add, rotateLeftButton, rotateRightButton, duplicateButton, deleteButton, undoButton,
                                      spacer, small, slider, large])
        top.spacing = 8
        top.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        top.setCustomSpacing(16, after: deleteButton)

        flow.sectionInset = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        flow.minimumInteritemSpacing = 10
        flow.minimumLineSpacing = 14
        collection.collectionViewLayout = flow
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.allowsEmptySelection = true
        collection.backgroundColors = [.underPageBackgroundColor]
        collection.register(PDFOrganizerItem.self, forItemWithIdentifier: PDFOrganizerItem.identifier)
        collection.dataSource = self
        collection.delegate = self
        collection.controller = self
        collection.registerForDraggedTypes([.fileURL, Self.pageType])
        collection.setDraggingSourceOperationMask(.move, forLocal: true)
        collection.setDraggingSourceOperationMask([], forLocal: false)
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true

        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.keyEquivalent = "\r"
        saveButton.toolTip = "Save a copy named “\(sources[0].deletingPathExtension().lastPathComponent) organized.pdf” (⌘S)"
        let spacer2 = NSView()
        spacer2.setContentHuggingPriority(.init(1), for: .horizontal)
        let bottom = NSStackView(views: [status, spacer2, cancel, saveButton])
        bottom.spacing = 8
        bottom.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 12, right: 14)

        let topLine = NSBox(), bottomLine = NSBox()
        topLine.boxType = .separator
        bottomLine.boxType = .separator
        for v in [top, topLine, scroll, bottomLine, bottom, emptyLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: root.topAnchor),
            top.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            top.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            topLine.topAnchor.constraint(equalTo: top.bottomAnchor),
            topLine.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topLine.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottomLine.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            bottomLine.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottomLine.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottom.topAnchor.constraint(equalTo: bottomLine.bottomAnchor),
            bottom.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        setThumbnailSide(side)
    }

    func showWindow() {
        let title = sources.count == 1 ? sources[0].lastPathComponent : "\(sources.count) files"
        let window = PDFOrganizerWindow(contentRect: root.frame, styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                     backing: .buffered, defer: false)
        window.title = "Organize – \(title)"
        window.contentMinSize = CGSize(width: 700, height: 420)   // the button bar fits from 700 pt
        window.contentView = root
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.organizer = self
        window.setFrameAutosaveName("DropWheelOrganizer")
        if !window.setFrameUsingName("DropWheelOrganizer") { window.center() }
        self.window = window
        Self.open.append(self)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(collection)
    }

    func setThumbnailSide(_ value: CGFloat) {
        side = min(320, max(80, value.rounded()))
        slider.doubleValue = Double(side)
        flow.itemSize = NSSize(width: side + 20, height: side + 42)
        collection.reloadData()
    }

    private var pixels: Int {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        return Int((side * scale / 32).rounded(.up)) * 32
    }

    var selection: [Int] { collection.selectionIndexPaths.map(\.item).filter { $0 < pages.count }.sorted() }

    func select(_ indices: Set<Int>) {
        let valid = indices.filter { $0 >= 0 && $0 < pages.count }
        collection.selectionIndexPaths = Set(valid.map { IndexPath(item: $0, section: 0) })
        updateControls()
    }

    private func updateControls() {
        let count = selection.count
        for b in [rotateLeftButton, rotateRightButton, duplicateButton, deleteButton] { b?.isEnabled = count > 0 }
        undoButton.isEnabled = undo.canUndo
        saveButton.isEnabled = !pages.isEmpty
        emptyLabel.isHidden = !pages.isEmpty
        let total = pages.count == 1 ? "1 page" : "\(pages.count) pages"
        status.stringValue = count > 0 ? "\(total), \(count) selected" : total
    }

    // MARK: Editing (each change can be undone)

    /// Applies a change to the page list, recording the previous list and selection for Undo.
    private func change(_ name: String, select newSelection: Set<Int>? = nil, _ body: (inout [PDFOrganizerPage]) -> Void) {
        let before = pages, beforeSelection = Set(selection)
        // One undo step per change, even when several happen in one event.
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        undo.registerUndo(withTarget: self) { $0.restore(before, beforeSelection, name) }
        undo.setActionName(name)
        undo.endUndoGrouping()
        body(&pages)
        edited = true
        collection.reloadData()
        select(newSelection ?? [])
    }

    private func restore(_ state: [PDFOrganizerPage], _ selected: Set<Int>, _ name: String) {
        let current = pages, currentSelection = Set(selection)
        undo.registerUndo(withTarget: self) { $0.restore(current, currentSelection, name) }
        undo.setActionName(name)
        pages = state
        collection.reloadData()
        select(selected)
    }

    @objc func undoChange() { if undo.canUndo { undo.undo() }; updateControls() }
    @objc func redoChange() { if undo.canRedo { undo.redo() }; updateControls() }

    @objc func rotateLeft() { rotate(by: -90) }
    @objc func rotateRight() { rotate(by: 90) }

    private func rotate(by degrees: Int) {
        let chosen = selection
        guard !chosen.isEmpty else { return }
        change(degrees < 0 ? "Rotate Left" : "Rotate Right", select: Set(chosen)) { pages in
            for i in chosen { pages[i].turn = PDFOrganizer.normalized(pages[i].turn + degrees) }
        }
    }

    @objc func deleteSelected() {
        let chosen = selection
        guard !chosen.isEmpty else { return }
        let next = chosen.first!
        change("Delete", select: []) { pages in
            for i in chosen.reversed() { pages.remove(at: i) }
        }
        if !pages.isEmpty { select([min(next, pages.count - 1)]) }
    }

    /// Puts a copy right after each selected page and selects the copies.
    @objc func duplicateSelected() {
        let chosen = selection
        guard !chosen.isEmpty else { return }
        var copies: Set<Int> = []
        var shift = 0
        for i in chosen { copies.insert(i + shift + 1); shift += 1 }
        change("Duplicate", select: copies) { pages in
            for i in chosen.reversed() {
                var copy = pages[i]
                copy.id = UUID()
                pages.insert(copy, at: i + 1)
            }
        }
    }

    @objc func selectAll() { select(Set(pages.indices)) }

    /// Moves pages to sit before `destination` (an index in the current list), keeping their order.
    func move(_ indices: [Int], to destination: Int) {
        let moving = indices.filter { $0 >= 0 && $0 < pages.count }.sorted()
        guard !moving.isEmpty else { return }
        let target = destination - moving.filter { $0 < destination }.count
        if moving == Array(target..<(target + moving.count)) { return }   // dropped where they already are
        change("Move", select: Set(target..<(target + moving.count))) { pages in
            let items = moving.map { pages[$0] }
            for i in moving.reversed() { pages.remove(at: i) }
            pages.insert(contentsOf: items, at: min(target, pages.count))
        }
    }

    /// Inserts every page of the files (PDFs and images) before `index`.
    func insert(_ files: [URL], at index: Int) {
        do {
            let loaded = try PDFOrganizer.load(files)
            guard !loaded.pages.isEmpty else { return }
            documents += loaded.documents
            let at = min(max(0, index), pages.count)
            change("Add Pages", select: Set(at..<(at + loaded.pages.count))) { pages in
                pages.insert(contentsOf: loaded.pages, at: at)
            }
            collection.scrollToItems(at: [IndexPath(item: at, section: 0)], scrollPosition: .nearestHorizontalEdge)
        } catch {
            showError(error.localizedDescription)
        }
    }

    @objc func addFiles() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf, .image]
        panel.message = "Choose PDFs or images to insert."
        panel.prompt = "Insert"
        let at = (selection.last.map { $0 + 1 }) ?? pages.count
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self else { return }
            self.insert(panel.urls, at: at)
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn’t add those pages"
        alert.informativeText = message
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    // MARK: Save and close

    /// Writes the current pages to "<first file> organized.pdf".
    func saveCopy() throws -> URL {
        thumbs.drain()
        return try PDFOrganizer.write(pages, next: sources[0], attributes: documents.first?.documentAttributes)
    }

    @objc func save() {
        guard !pages.isEmpty else { return }
        do {
            let out = try saveCopy()
            close()
            JobRunner.report(saved: [out])
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t save the pages"
            alert.informativeText = error.localizedDescription
            if let window { alert.beginSheetModal(for: window) }
        }
    }

    @objc func cancel() { close() }

    private func close() {
        edited = false
        window?.close()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard edited else { return true }
        let alert = NSAlert()
        alert.messageText = "Discard your changes?"
        alert.informativeText = "The reorganized pages haven’t been saved."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Keep Editing")
        alert.beginSheetModal(for: sender) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.close() }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        undo.removeAllActions()
        (window as? PDFOrganizerWindow)?.organizer = nil
        window = nil
        root.controller = nil
        Self.open.removeAll { $0 === self }
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { undo }

    // MARK: Data source

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { pages.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: PDFOrganizerItem.identifier, for: indexPath)
        guard let organizerItem = item as? PDFOrganizerItem, indexPath.item < pages.count else { return item }
        let p = pages[indexPath.item]
        let cell = organizerItem.cell
        let px = pixels
        let key = PDFOrganizerThumbnails.key(p, pixels: px)
        cell.key = key
        cell.number = indexPath.item + 1
        cell.pageSize = p.displaySize
        cell.toolTip = p.label
        cell.setAccessibilityElement(true)
        cell.setAccessibilityRole(.image)
        cell.setAccessibilityLabel("Page \(indexPath.item + 1): \(p.label)")
        if let image = synchronous ? thumbs.renderNow(p, pixels: px) : thumbs.cached(p, pixels: px) {
            cell.image = image
        } else {
            cell.image = nil
            thumbs.request(p, pixels: px) { [weak collectionView] key, image in
                guard let collectionView else { return }
                for case let visible as PDFOrganizerItem in collectionView.visibleItems() where visible.cell.key == key {
                    visible.cell.image = image
                }
            }
        }
        cell.isSelected = organizerItem.isSelected
        return organizerItem
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { updateControls() }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { updateControls() }

    @objc private func sliderMoved() { setThumbnailSide(CGFloat(slider.doubleValue)) }

    // MARK: Drag and drop

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool { true }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(indexPath.item), forType: Self.pageType)
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession,
                        willBeginAt screenPoint: NSPoint, forItemsAt indexPaths: Set<IndexPath>) {
        dragged = indexPaths.map(\.item).sorted()
    }

    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession,
                        endedAt screenPoint: NSPoint, dragOperation operation: NSDragOperation) {
        dragged = []
    }

    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo,
                        proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        if dropOperation.pointee == .on { dropOperation.pointee = .before }
        if (draggingInfo.draggingSource as? NSCollectionView) === collectionView { return .move }
        return droppedFiles(draggingInfo).isEmpty ? [] : .copy
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo,
                        indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        let index = min(max(0, indexPath.item), pages.count)
        if (draggingInfo.draggingSource as? NSCollectionView) === collectionView {
            move(dragged, to: index)
            return true
        }
        let files = droppedFiles(draggingInfo)
        guard !files.isEmpty else { return false }
        insert(files, at: index)
        return true
    }

    private func droppedFiles(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { Ext.of($0) == "pdf" || PDFOrganizer.imageExtensions.contains(Ext.of($0)) }
    }
}

// MARK: - Views

/// The organizer's content view. It owns its controller while it is on screen or being snapshotted.
final class PDFOrganizerRootView: NSView {
    var controller: PDFOrganizerController?

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

/// The window, so ⌘Z, ⌘S and friends work without a main menu (the app has none).
final class PDFOrganizerWindow: NSWindow {
    weak var organizer: PDFOrganizerController?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let organizer, event.modifierFlags.contains(.command),
              let key = event.charactersIgnoringModifiers?.lowercased() else { return super.performKeyEquivalent(with: event) }
        let shift = event.modifierFlags.contains(.shift)
        switch key {
        case "z": shift ? organizer.redoChange() : organizer.undoChange()
        case "s": organizer.save()
        case "a": organizer.selectAll()
        case "d": organizer.duplicateSelected()
        case "l": organizer.rotateLeft()
        case "r": organizer.rotateRight()
        case "o": organizer.addFiles()
        case "w": performClose(nil)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}

/// The grid; ⌫ and ⌦ delete the selected pages.
final class PDFOrganizerCollectionView: NSCollectionView {
    weak var controller: PDFOrganizerController?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { controller?.deleteSelected(); return }
        super.keyDown(with: event)
    }
}

/// One grid item.
final class PDFOrganizerItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("PDFOrganizerItem")
    let cell = PDFOrganizerCell()

    override func loadView() { view = cell }

    override var isSelected: Bool { didSet { cell.isSelected = isSelected } }
    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet { cell.isHighlighted = highlightState == .forSelection }
    }
}

/// Draws a page thumbnail with its number underneath, and the selection around it.
final class PDFOrganizerCell: NSView {
    var key = ""
    var image: NSImage? { didSet { needsDisplay = true } }
    var pageSize = CGSize(width: 612, height: 792) { didSet { needsDisplay = true } }
    var number = 0 { didSet { needsDisplay = true } }
    var isSelected = false { didSet { needsDisplay = true } }
    var isHighlighted = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let labelHeight: CGFloat = 22
        let area = CGRect(x: 10, y: 8, width: bounds.width - 20, height: bounds.height - labelHeight - 14)
        let fit = min(area.width / max(pageSize.width, 1), area.height / max(pageSize.height, 1))
        let size = CGSize(width: (pageSize.width * fit).rounded(), height: (pageSize.height * fit).rounded())
        let pageRect = CGRect(x: area.midX - size.width / 2, y: area.maxY - size.height, width: size.width, height: size.height)

        let chosen = isSelected || isHighlighted
        if chosen {
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.22).setFill()
            NSBezierPath(roundedRect: pageRect.insetBy(dx: -6, dy: -6), xRadius: 6, yRadius: 6).fill()
        }

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        NSColor.white.setFill()
        pageRect.fill()
        NSGraphicsContext.restoreGraphicsState()
        image?.draw(in: pageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        (chosen ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        let border = NSBezierPath(rect: pageRect.insetBy(dx: chosen ? -1 : -0.25, dy: chosen ? -1 : -0.25))
        border.lineWidth = chosen ? 2 : 0.5
        border.stroke()

        let text = "\(number)" as NSString
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: chosen ? .semibold : .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: chosen ? NSColor.white : NSColor.secondaryLabelColor]
        let textSize = text.size(withAttributes: attributes)
        let labelCenter = CGPoint(x: bounds.midX, y: pageRect.maxY + 6 + labelHeight / 2)
        if chosen {
            let pill = CGRect(x: labelCenter.x - textSize.width / 2 - 7, y: labelCenter.y - 9, width: textSize.width + 14, height: 18)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: pill, xRadius: 9, yRadius: 9).fill()
        }
        text.draw(at: CGPoint(x: labelCenter.x - textSize.width / 2, y: labelCenter.y - textSize.height / 2), withAttributes: attributes)
    }
}
