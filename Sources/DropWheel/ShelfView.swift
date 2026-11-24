import AppKit

/// Colors and shapes of the shelf: a frosted tray holding a fanned deck of rounded tiles.
enum ShelfStyle {
    static let radius: CGFloat = 14
    static let thumbnailSize: CGFloat = 96

    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }
    /// Painted over the blur so the tray reads the same on any wallpaper (and in offscreen snapshots).
    static let tint = dynamic(light: NSColor(white: 1, alpha: 0.62), dark: NSColor(white: 0.11, alpha: 0.55))
    static let border = dynamic(light: NSColor(white: 0, alpha: 0.13), dark: NSColor(white: 1, alpha: 0.16))
    static let tile = dynamic(light: .white, dark: NSColor(white: 0.26, alpha: 1))
    static let tileBorder = dynamic(light: NSColor(white: 0, alpha: 0.10), dark: NSColor(white: 1, alpha: 0.10))

    /// A rounded rectangle whose corners on the docked sides are square, so a snapped shelf sits flush.
    static func path(in r: CGRect, radius: CGFloat, square: ShelfGeometry.Edges) -> NSBezierPath {
        func corner(_ a: ShelfGeometry.Edges, _ b: ShelfGeometry.Edges) -> CGFloat {
            square.contains(a) || square.contains(b) ? 0 : min(radius, r.width / 2, r.height / 2)
        }
        let tl = corner(.left, .top), tr = corner(.right, .top), bl = corner(.left, .bottom), br = corner(.right, .bottom)
        let p = NSBezierPath()
        p.move(to: CGPoint(x: r.minX + bl, y: r.minY))
        p.line(to: CGPoint(x: r.maxX - br, y: r.minY))
        if br > 0 { p.appendArc(withCenter: CGPoint(x: r.maxX - br, y: r.minY + br), radius: br, startAngle: 270, endAngle: 360) }
        p.line(to: CGPoint(x: r.maxX, y: r.maxY - tr))
        if tr > 0 { p.appendArc(withCenter: CGPoint(x: r.maxX - tr, y: r.maxY - tr), radius: tr, startAngle: 0, endAngle: 90) }
        p.line(to: CGPoint(x: r.minX + tl, y: r.maxY))
        if tl > 0 { p.appendArc(withCenter: CGPoint(x: r.minX + tl, y: r.maxY - tl), radius: tl, startAngle: 90, endAngle: 180) }
        p.line(to: CGPoint(x: r.minX, y: r.minY + bl))
        if bl > 0 { p.appendArc(withCenter: CGPoint(x: r.minX + bl, y: r.minY + bl), radius: bl, startAngle: 180, endAngle: 270) }
        p.close()
        return p
    }

    /// A stretchable mask in the shelf's shape, for the blur behind it.
    static func mask(square: ShelfGeometry.Edges) -> NSImage {
        let side = radius * 2 + 2
        let image = NSImage(size: CGSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            path(in: rect, radius: radius, square: square).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    /// `size` scaled to fit inside `box`, centered.
    static func fit(_ size: CGSize, in box: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return box }
        let s = min(box.width / size.width, box.height / size.height)
        let w = size.width * s, h = size.height * s
        return CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
    }

    static func symbolButton(_ symbol: String, _ label: String, target: AnyObject, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 11.5, weight: .semibold)) ?? NSImage()
        let b = NSButton(image: image, target: target, action: action)
        b.isBordered = false
        b.imagePosition = .imageOnly
        b.contentTintColor = .secondaryLabelColor
        b.toolTip = label
        b.setAccessibilityLabel(label)
        return b
    }
}

/// The content of a shelf panel: header buttons, the stack or the list, a footer, and the drop target for the
/// whole shelf. Dragging its background moves the panel. Works without a controller (snapshots).
final class ShelfView: NSView, NSDraggingSource {
    let model: ShelfModel
    weak var controller: ShelfController?
    var mode: ShelfViewMode {
        didSet {
            reload()
            if controller == nil { setFrameSize(preferredSize) }
        }
    }
    var docked: ShelfGeometry.Edges = [] { didSet { if docked != oldValue { applyCorners() } } }
    /// Number of files hovering over the shelf, or nil.
    private(set) var dropCount: Int? { didSet { overlay.count = dropCount } }

    static let headerHeight: CGFloat = 30
    static let footerHeight: CGFloat = 30
    static let rowHeight: CGFloat = 40
    static let stackWidth: CGFloat = 184
    static let listWidth: CGFloat = 284

    private let effect = NSVisualEffectView()
    private let backdrop = ShelfBackdropView()
    private var closeButton: NSButton!
    private var toggleButton: NSButton!
    private var clearButton: NSButton!
    let stack = ShelfStackView()
    let table = ShelfTableView()
    private let scroll = NSScrollView()
    private let hint = ShelfDropHint()
    private let footer = NSTextField(labelWithString: "")
    private let dragAll = ShelfDragAllView()
    private let overlay = ShelfHighlightView()
    private var flashWork: DispatchWorkItem?
    private var moveStart: (mouse: CGPoint, origin: CGPoint)?
    private var isMoving = false

    init(model: ShelfModel, mode: ShelfViewMode) {
        self.model = model
        self.mode = mode
        super.init(frame: .zero)

        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = ShelfStyle.mask(square: [])
        addSubview(effect)
        addSubview(backdrop)

        closeButton = ShelfStyle.symbolButton("xmark", "Close Shelf", target: self, action: #selector(closeShelf))
        toggleButton = ShelfStyle.symbolButton("list.bullet", "Show as List", target: self, action: #selector(toggleMode))
        clearButton = ShelfStyle.symbolButton("trash", "Clear Shelf", target: self, action: #selector(clearShelf))
        [closeButton, toggleButton, clearButton].forEach { addSubview($0!) }

        stack.shelf = self
        addSubview(stack)

        let column = NSTableColumn(identifier: .init("file"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = .clear
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        if #available(macOS 11.0, *) { table.style = .plain }
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openClickedRow)
        table.shelf = self
        table.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: false)
        table.setDraggingSourceOperationMask([.copy, .generic], forLocal: true)
        table.setAccessibilityLabel("Files on the shelf")
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay
        addSubview(scroll)

        addSubview(hint)
        footer.font = .systemFont(ofSize: 11, weight: .medium)
        footer.textColor = .secondaryLabelColor
        footer.lineBreakMode = .byTruncatingMiddle
        footer.cell?.truncatesLastVisibleLine = true
        addSubview(footer)
        dragAll.shelf = self
        addSubview(dragAll)
        addSubview(overlay)

        registerForDraggedTypes([.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Shelf")
        model.onChange = { [weak self] in self?.modelDidChange() }
        setFrameSize(preferredSize)
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// The panel size for the current mode and contents.
    var preferredSize: CGSize {
        let chrome = Self.headerHeight + Self.footerHeight
        switch mode {
        case .stack:
            return CGSize(width: Self.stackWidth, height: chrome + 150)
        case .list:
            if model.isEmpty { return CGSize(width: Self.listWidth, height: chrome + 130) }
            let rows = CGFloat(min(max(model.count, 2), 6))
            return CGSize(width: Self.listWidth, height: chrome + rows * Self.rowHeight + 6)
        }
    }

    override func layout() {
        super.layout()
        let b = bounds
        effect.frame = b
        backdrop.frame = b
        overlay.frame = b
        let top = b.height - Self.headerHeight
        closeButton.frame = CGRect(x: 7, y: top + 4, width: 22, height: 22)
        clearButton.frame = CGRect(x: b.width - 29, y: top + 4, width: 22, height: 22)
        toggleButton.frame = CGRect(x: b.width - 53, y: top + 4, width: 22, height: 22)
        let body = CGRect(x: 6, y: Self.footerHeight, width: b.width - 12, height: top - Self.footerHeight)
        stack.frame = body
        scroll.frame = body
        hint.frame = body.insetBy(dx: 6, dy: 4)
        table.tableColumns.first?.width = scroll.contentSize.width
        if !dragAll.isHidden {
            dragAll.frame = CGRect(x: b.width - 10 - 82, y: 5, width: 82, height: 21)
            footer.frame = CGRect(x: 12, y: 8, width: b.width - 24 - 86, height: 15)
        } else {
            footer.frame = CGRect(x: 10, y: 8, width: b.width - 20, height: 15)
        }
    }

    // MARK: Content

    private func modelDidChange() {
        reload()
        if let controller { controller.fitToContent() } else { setFrameSize(preferredSize) }
    }

    /// Shows what the model holds now.
    func reload() {
        let empty = model.isEmpty
        hint.isHidden = !empty
        stack.isHidden = empty || mode != .stack
        scroll.isHidden = empty || mode != .list
        dragAll.isHidden = empty || mode != .list
        clearButton.isEnabled = !empty
        let toList = mode == .stack
        toggleButton.image = NSImage(systemSymbolName: toList ? "list.bullet" : "square.stack",
                                     accessibilityDescription: toList ? "Show as List" : "Show as Stack")?
            .withSymbolConfiguration(.init(pointSize: 11.5, weight: .semibold))
        toggleButton.toolTip = toList ? "Show as List" : "Show as Stack"
        toggleButton.setAccessibilityLabel(toggleButton.toolTip)
        footer.alignment = dragAll.isHidden ? .center : .left
        if flashWork == nil { footer.stringValue = model.summary }
        stack.update(items: Array(model.items.suffix(3)), total: model.count)
        stack.setAccessibilityLabel("\(model.summary). Drag to take every file; click to list them.")
        table.reloadData()
        needsLayout = true
    }

    /// Shows a short message in the footer, then the summary again.
    func flash(_ text: String) {
        flashWork?.cancel()
        footer.stringValue = text
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.flashWork = nil
            self.footer.stringValue = self.model.summary
        }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }

    /// Square corners on the docked sides, so a snapped shelf sits flush with the screen edge.
    private func applyCorners() {
        effect.maskImage = ShelfStyle.mask(square: docked)
        backdrop.docked = docked
        overlay.docked = docked
        window?.invalidateShadow()
    }

    /// Items in list order: the newest first, like the top of the stack.
    func item(atRow row: Int) -> ShelfItem? {
        let i = model.count - 1 - row
        return model.items.indices.contains(i) ? model.items[i] : nil
    }

    private func indices(forRows rows: IndexSet) -> IndexSet { IndexSet(rows.map { model.count - 1 - $0 }) }

    var selectedURLs: [URL] { table.selectedRowIndexes.compactMap { item(atRow: $0)?.url } }

    /// Every file, in list order.
    var newestFirst: [URL] { model.urls.reversed() }

    // MARK: Actions

    @objc func closeShelf() { controller?.close() }
    @objc func clearShelf() { model.clear() }
    @objc func toggleMode() {
        let next: ShelfViewMode = mode == .stack ? .list : .stack
        if let controller { controller.setMode(next) } else { mode = next }
    }

    func stackClicked() {
        if let controller { controller.setMode(.list) } else { mode = .list }
    }

    func removeSelected() {
        let rows = table.selectedRowIndexes
        guard !rows.isEmpty else { return }
        let first = rows.first ?? 0
        model.remove(at: indices(forRows: rows))
        if model.count > 0 { table.selectRowIndexes([min(first, model.count - 1)], byExtendingSelection: false) }
    }

    @objc func removeRow(_ sender: NSButton) {
        let row = table.row(for: sender)
        guard row >= 0 else { return }
        model.remove(at: indices(forRows: [row]))
    }

    @objc private func openClickedRow() {
        guard let url = item(atRow: table.clickedRow)?.url else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func menuOpen(_ sender: NSMenuItem) { (sender.representedObject as? [URL] ?? []).forEach { NSWorkspace.shared.open($0) } }
    @objc private func menuReveal(_ sender: NSMenuItem) {
        NSWorkspace.shared.activateFileViewerSelecting(sender.representedObject as? [URL] ?? [])
    }
    @objc private func menuCopy(_ sender: NSMenuItem) { copy(sender.representedObject as? [URL] ?? []) }
    @objc private func menuAirDrop(_ sender: NSMenuItem) { FileAction.airDrop.perform(on: sender.representedObject as? [URL] ?? []) }
    @objc private func menuRemove(_ sender: NSMenuItem) { model.remove(sender.representedObject as? [URL] ?? []) }

    private func copy(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
        flash(urls.count == 1 ? "Copied \(urls[0].lastPathComponent)" : "Copied \(urls.count) items")
    }

    /// The right-click menu, for some items or (from the stack) for the whole shelf.
    func menu(for urls: [URL], wholeShelf: Bool) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, _ urls: [URL]) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = urls
            menu.addItem(item)
        }
        if !urls.isEmpty {
            add(urls.count == 1 ? "Open" : "Open \(urls.count) Items", #selector(menuOpen(_:)), urls)
            add("Show in Finder", #selector(menuReveal(_:)), urls)
            add("Copy", #selector(menuCopy(_:)), urls)
            add("AirDrop…", #selector(menuAirDrop(_:)), urls)
            menu.addItem(.separator())
            if !wholeShelf { add(urls.count == 1 ? "Remove from Shelf" : "Remove \(urls.count) from Shelf", #selector(menuRemove(_:)), urls) }
        }
        let toggle = NSMenuItem(title: mode == .stack ? "Show as List" : "Show as Stack", action: #selector(toggleMode), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        if !model.isEmpty {
            let clear = NSMenuItem(title: "Clear Shelf", action: #selector(clearShelf), keyEquivalent: "")
            clear.target = self
            menu.addItem(clear)
        }
        let close = NSMenuItem(title: "Close Shelf", action: #selector(closeShelf), keyEquivalent: "")
        close.target = self
        menu.addItem(close)
        return menu
    }

    override func menu(for event: NSEvent) -> NSMenu? { menu(for: model.urls, wholeShelf: true) }

    // MARK: Keyboard

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.isKeyWindow == true, event.modifierFlags.contains(.command),
              let key = event.charactersIgnoringModifiers?.lowercased() else { return super.performKeyEquivalent(with: event) }
        let targets = selectedURLs.isEmpty ? model.urls : selectedURLs
        switch key {
        case "w": closeShelf()
        case "a" where mode == .list: table.selectAll(nil)
        case "c": copy(targets)
        case "o": targets.forEach { NSWorkspace.shared.open($0) }
        case "\u{8}", "\u{7f}": removeSelected()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    // MARK: Moving the panel

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        moveStart = (NSEvent.mouseLocation, window.frame.origin)
        isMoving = false
        if event.clickCount == 2 { toggleMode() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = moveStart, let window else { return }
        let p = NSEvent.mouseLocation
        let dx = p.x - start.mouse.x, dy = p.y - start.mouse.y
        if !isMoving {
            guard hypot(dx, dy) >= 3 else { return }
            isMoving = true
            controller?.moveBegan()
        }
        window.setFrameOrigin(CGPoint(x: start.origin.x + dx, y: start.origin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        if isMoving { controller?.moveEnded() }
        isMoving = false
        moveStart = nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    /// Coming back to the shelf after working in Finder: follow renamed files, drop deleted ones.
    override func mouseEntered(with event: NSEvent) { model.refresh() }

    // MARK: Dragging out

    /// Starts dragging `urls` out of the shelf. `frame` (in `view`) is where the drag image starts.
    func beginDrag(_ urls: [URL], from view: NSView, event: NSEvent, frame: CGRect, images: [NSImage] = []) {
        guard !urls.isEmpty else { return }
        let items = urls.enumerated().map { i, url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            // The first few carry a picture; the rest travel along unseen so huge drags stay quick.
            let image: NSImage? = i < images.count ? images[i] : (i < 6 ? ShelfThumbnails.icon(for: url).image : nil)
            item.setDraggingFrame(frame, contents: image)
            return item
        }
        let session = view.beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = urls.count > 1 ? .pile : .none
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Outside, the destination decides like a Finder drag (move on the same disk, copy elsewhere, ⌥ copies).
        // Inside YummyOrange (the wheel, another shelf) the files are only read.
        context == .outsideApplication ? [.copy, .move, .link, .generic] : [.copy, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragEnded()
    }

    /// After a drag out: a moved file is followed to its new folder, a deleted one is dropped.
    func dragEnded() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.model.refresh() }
    }

    // MARK: Dropping in

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    private func promises(_ info: NSDraggingInfo) -> [NSFilePromiseReceiver] {
        info.draggingPasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
    }

    private func isFromThisShelf(_ info: NSDraggingInfo) -> Bool {
        if (info.draggingSource as AnyObject?) === self { return true }
        guard let view = info.draggingSource as? NSView else { return false }
        return view.window != nil && view.window === window
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !isFromThisShelf(sender) else { dropCount = nil; return [] }
        let n = fileURLs(sender).count
        let count = n > 0 ? n : promises(sender).count
        dropCount = count > 0 ? count : nil
        return dropOperation(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dropOperation(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropCount = nil }
    override func draggingEnded(_ sender: NSDraggingInfo) { dropCount = nil }

    private func dropOperation(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard dropCount != nil else { return [] }
        let mask = sender.draggingSourceOperationMask
        return mask.contains(.copy) ? .copy : mask.contains(.link) ? .link : .generic
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { dropCount = nil }
        guard !isFromThisShelf(sender) else { return false }
        let urls = fileURLs(sender)
        if !urls.isEmpty {
            let result = model.add(urls)
            if result.added.isEmpty {
                flash(result.duplicates > 0 ? "Already on this shelf" : "Couldn’t find those files")
            } else if result.duplicates > 0 {
                flash("Added \(result.added.count), \(result.duplicates) already here")
            }
            return true
        }
        let receivers = promises(sender)
        guard !receivers.isEmpty else { return false }
        receive(receivers)
        return true
    }

    private static let promiseQueue: OperationQueue = {
        let q = OperationQueue()
        q.qualityOfService = .userInitiated
        return q
    }()

    /// Files promised by apps such as Mail or Photos are written to a temporary folder and shelved from there.
    private func receive(_ receivers: [NSFilePromiseReceiver]) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("YummyOrange Shelf", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { flash("Couldn’t make room for those files"); return }
        flash("Receiving…")
        for receiver in receivers {
            receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: Self.promiseQueue) { [weak self] url, error in
                DispatchQueue.main.async {
                    if error == nil { self?.model.add([url]) } else { self?.flash("Couldn’t receive a file") }
                }
            }
        }
    }

    /// For snapshots: shows the drop highlight as if `count` files hovered over the shelf.
    func showDropHighlight(_ count: Int?) { dropCount = count }

    /// What the footer says now (for the self-test).
    var footerText: String { footer.stringValue }
    var hoveringCount: Int? { dropCount }
}

// MARK: - List

extension ShelfView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { model.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let item = item(atRow: row) else { return nil }
        let cell = tableView.makeView(withIdentifier: ShelfRowView.identifier, owner: self) as? ShelfRowView ?? {
            let c = ShelfRowView()
            c.identifier = ShelfRowView.identifier
            c.removeButton.target = self
            c.removeButton.action = #selector(removeRow(_:))
            return c
        }()
        cell.show(item)
        return cell
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        item(atRow: row)?.url as NSURL?
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint,
                   operation: NSDragOperation) {
        dragEnded()
    }
}

/// The list. Delete removes the selected files; Return opens them.
final class ShelfTableView: NSTableView {
    weak var shelf: ShelfView?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: shelf?.removeSelected()                                  // delete, forward delete
        case 36, 76: shelf?.selectedURLs.forEach { NSWorkspace.shared.open($0) } // return, enter
        default: super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0, let shelf else { return shelf?.menu(for: [], wholeShelf: false) }
        if !selectedRowIndexes.contains(row) { selectRowIndexes([row], byExtendingSelection: false) }
        return shelf.menu(for: shelf.selectedURLs, wholeShelf: false)
    }
}

/// One file in the list: thumbnail, name, size and kind, and a remove button.
final class ShelfRowView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ShelfRow")
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    let removeButton: NSButton = {
        let b = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove from Shelf")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular)) ?? NSImage(), target: nil, action: nil)
        b.isBordered = false
        b.imagePosition = .imageOnly
        b.contentTintColor = .tertiaryLabelColor
        b.toolTip = "Remove from Shelf"
        return b
    }()
    private var url: URL?

    init() {
        super.init(frame: .zero)
        icon.imageScaling = .scaleProportionallyUpOrDown
        name.font = .systemFont(ofSize: 12.5, weight: .medium)
        name.lineBreakMode = .byTruncatingMiddle
        detail.font = .systemFont(ofSize: 10.5)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        [icon, name, detail, removeButton].forEach(addSubview)
        imageView = icon
        textField = name
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = bounds.height, w = bounds.width
        icon.frame = CGRect(x: 6, y: (h - 30) / 2, width: 30, height: 30)
        name.frame = CGRect(x: 44, y: h / 2 - 1, width: max(0, w - 44 - 30), height: 16)
        detail.frame = CGRect(x: 44, y: h / 2 - 15, width: max(0, w - 44 - 30), height: 14)
        removeButton.frame = CGRect(x: w - 26, y: (h - 20) / 2, width: 20, height: 20)
    }

    func show(_ item: ShelfItem) {
        let url = item.url
        self.url = url
        name.stringValue = FileManager.default.displayName(atPath: url.path)
        let kind = (try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey]))?.localizedTypeDescription
        let size = item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        detail.stringValue = [size, kind].compactMap { $0 }.joined(separator: " · ")
        toolTip = url.path
        setAccessibilityLabel("\(name.stringValue), \(detail.stringValue)")
        icon.image = (ShelfThumbnails.cached(url, size: ShelfStyle.thumbnailSize) ?? ShelfThumbnails.icon(for: url)).image
        ShelfThumbnails.load(url, size: ShelfStyle.thumbnailSize) { [weak self] t in
            guard let self, self.url == url else { return }
            self.icon.image = t.image
        }
    }
}

// MARK: - Stack

/// Up to three tiles fanned like a hand of cards, newest on top, with the count in a badge.
/// Drag it to take every file; click it to see the list.
final class ShelfStackView: NSView {
    weak var shelf: ShelfView?
    private var items: [ShelfItem] = []
    private var total = 0
    private var pictures: [String: ShelfThumbnail] = [:]
    private var mouseDownEvent: NSEvent?
    static let tile: CGFloat = 92
    /// Offset and rotation (degrees) for the top tile, the one under it, and the bottom one.
    private static let poses: [(dx: CGFloat, dy: CGFloat, angle: CGFloat)] = [(0, 0, 0), (-14, 4, 9), (14, 6, -8)]

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func update(items: [ShelfItem], total: Int) {
        self.items = items
        self.total = total
        let paths = Set(items.map(\.url.path))
        pictures = pictures.filter { paths.contains($0.key) }
        for item in items where pictures[item.url.path] == nil {
            let path = item.url.path
            ShelfThumbnails.load(item.url, size: ShelfStyle.thumbnailSize) { [weak self] t in
                self?.pictures[path] = t
                self?.needsDisplay = true
            }
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        needsDisplay = true
    }

    private func picture(_ item: ShelfItem) -> ShelfThumbnail {
        pictures[item.url.path] ?? ShelfThumbnails.cached(item.url, size: ShelfStyle.thumbnailSize) ?? ShelfThumbnails.icon(for: item.url)
    }

    private var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY + 1) }
    private var topTileFrame: CGRect {
        CGRect(x: center.x - Self.tile / 2, y: center.y - Self.tile / 2, width: Self.tile, height: Self.tile)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, !items.isEmpty else { return }
        let s = Self.tile
        for (i, item) in items.enumerated() {
            let pose = Self.poses[min(items.count - 1 - i, Self.poses.count - 1)]
            ctx.saveGState()
            ctx.translateBy(x: center.x + pose.dx, y: center.y + pose.dy)
            ctx.rotate(by: pose.angle * .pi / 180)
            let r = CGRect(x: -s / 2, y: -s / 2, width: s, height: s)
            let tile = NSBezierPath(roundedRect: r, xRadius: 13, yRadius: 13)

            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            shadow.shadowBlurRadius = 6
            shadow.set()
            ShelfStyle.tile.setFill()
            tile.fill()
            NSGraphicsContext.restoreGraphicsState()

            let pic = picture(item)
            let box = pic.isIcon ? r.insetBy(dx: 16, dy: 16) : r.insetBy(dx: 7, dy: 7)
            let place = ShelfStyle.fit(pic.image.size, in: box)
            NSGraphicsContext.saveGraphicsState()
            if !pic.isIcon { NSBezierPath(roundedRect: place, xRadius: 7, yRadius: 7).addClip() }
            pic.image.draw(in: place, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()

            ShelfStyle.tileBorder.setStroke()
            tile.lineWidth = 1
            tile.stroke()
            ctx.restoreGState()
        }
        drawBadge(at: CGPoint(x: topTileFrame.maxX - 6, y: topTileFrame.maxY - 6))
    }

    private func drawBadge(at p: CGPoint) {
        let text = NSAttributedString(string: ShelfModel.badge(total), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold), .foregroundColor: NSColor.white])
        let size = text.size()
        let w = max(22, size.width + 13), h: CGFloat = 22
        let rect = CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h)
        let pill = NSBezierPath(roundedRect: rect, xRadius: h / 2, yRadius: h / 2)
        NSColor.controlAccentColor.setFill()
        pill.fill()
        ShelfStyle.tile.setStroke()
        pill.lineWidth = 2
        pill.stroke()
        text.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }

    override func mouseDown(with event: NSEvent) { mouseDownEvent = event }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent, let shelf else { return }
        let d = hypot(event.locationInWindow.x - down.locationInWindow.x, event.locationInWindow.y - down.locationInWindow.y)
        guard d >= 3 else { return }
        mouseDownEvent = nil
        // Newest first, like the list; the visible tiles lend their pictures to the drag.
        shelf.beginDrag(shelf.newestFirst, from: self, event: down, frame: topTileFrame,
                        images: items.reversed().map { picture($0).image })
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseDownEvent != nil else { return }
        mouseDownEvent = nil
        shelf?.stackClicked()
    }

    override func menu(for event: NSEvent) -> NSMenu? { shelf?.menu(for: shelf?.model.urls ?? [], wholeShelf: true) }

    override func accessibilityPerformPress() -> Bool { shelf?.stackClicked(); return true }
}

// MARK: - Small parts

/// The frosted tray behind everything: tint, hairline border and a grip bar that says "move me".
final class ShelfBackdropView: NSView {
    var docked: ShelfGeometry.Edges = [] { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let path = ShelfStyle.path(in: bounds.insetBy(dx: 0.5, dy: 0.5), radius: ShelfStyle.radius - 0.5, square: docked)
        ShelfStyle.tint.setFill()
        path.fill()
        ShelfStyle.border.setStroke()
        path.lineWidth = 1
        path.stroke()
        let grip = CGRect(x: bounds.midX - 15, y: bounds.maxY - 15, width: 30, height: 4.5)
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(roundedRect: grip, xRadius: 2.25, yRadius: 2.25).fill()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // clicks fall through to ShelfView (moving)
}

/// The empty shelf: a dashed drop area.
final class ShelfDropHint: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 4, dy: 4)
        let path = NSBezierPath(roundedRect: r, xRadius: 11, yRadius: 11)
        path.lineWidth = 1.5
        path.setLineDash([5, 4], count: 2, phase: 0)
        NSColor.tertiaryLabelColor.setStroke()
        path.stroke()
        if let symbol = NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 26, weight: .light)
                .applying(.init(paletteColors: [.secondaryLabelColor])) ) {
            symbol.draw(in: ShelfStyle.fit(symbol.size, in: CGRect(x: r.midX - 18, y: r.midY - 2, width: 36, height: 32)))
        }
        let text = NSAttributedString(string: "Drop files here", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor])
        let size = text.size()
        text.draw(at: CGPoint(x: r.midX - size.width / 2, y: r.midY - size.height - 8))
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Drawn over the shelf while files hover over it.
final class ShelfHighlightView: NSView {
    var count: Int? { didSet { isHidden = count == nil; needsDisplay = true } }
    var docked: ShelfGeometry.Edges = [] { didSet { needsDisplay = true } }

    override init(frame: NSRect) { super.init(frame: frame); isHidden = true }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let count else { return }
        let path = ShelfStyle.path(in: bounds.insetBy(dx: 1.5, dy: 1.5), radius: ShelfStyle.radius - 1.5, square: docked)
        NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
        path.fill()
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 3
        path.stroke()
        let text = NSAttributedString(string: count == 1 ? "Add 1 file" : "Add \(count.formatted()) files", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white])
        let size = text.size()
        let pill = CGRect(x: bounds.midX - size.width / 2 - 10, y: 6, width: size.width + 20, height: 20)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: pill, xRadius: 10, yRadius: 10).fill()
        text.draw(at: CGPoint(x: pill.midX - size.width / 2, y: pill.midY - size.height / 2))
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A capsule in the list's footer that drags every file at once.
final class ShelfDragAllView: NSView {
    weak var shelf: ShelfView?
    private var mouseDownEvent: NSEvent?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        toolTip = "Drag every file on the shelf"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Drag all files")
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let pill = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
        pill.fill()
        let color = NSColor.controlAccentColor
        let text = NSAttributedString(string: "Drag All", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                                                                     .foregroundColor: color])
        let size = text.size()
        var x = r.midX - (size.width + 16) / 2
        if let symbol = NSImage(systemSymbolName: "hand.draw", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10.5, weight: .semibold).applying(.init(paletteColors: [color]))) {
            symbol.draw(in: ShelfStyle.fit(symbol.size, in: CGRect(x: x, y: r.midY - 6.5, width: 13, height: 13)))
            x += 16
        }
        text.draw(at: CGPoint(x: x, y: r.midY - size.height / 2))
    }

    override func mouseDown(with event: NSEvent) { mouseDownEvent = event }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent, let shelf else { return }
        guard hypot(event.locationInWindow.x - down.locationInWindow.x, event.locationInWindow.y - down.locationInWindow.y) >= 3 else { return }
        mouseDownEvent = nil
        shelf.beginDrag(shelf.newestFirst, from: self, event: down, frame: CGRect(x: 0, y: -10, width: 40, height: 40))
    }

    override func mouseUp(with event: NSEvent) { mouseDownEvent = nil }
}
