import AppKit
import PDFKit

/// The Edit PDF window: a titled window (title = file name, subtitle "Edit PDF") with a unified toolbar
/// (sidebar toggle · Edit Text | Add Text · zoom − + · Undo Redo · inspector toggle · Save, the one prominent item),
/// page thumbnails on the leading side (a dahlia dot marks edited pages), the page canvas in the middle with banners
/// above it, the inspector on the trailing side and a one-line status bar (information only).
///
/// Save (⌘S) commits any typing, runs the session's verification gate, writes "<name> edited.pdf" next to the original,
/// closes the window and reports the file like a finished job. Closing with changes asks "Discard your changes?".
final class PDFEditWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate, NSTableViewDataSource,
                                     NSTableViewDelegate, PDFEditCanvasDelegate {
    private static var openControllers: [PDFEditWindowController] = []
    /// Open windows with edits that haven't been saved (the updater asks before a restart would lose them).
    static var unsavedCount: Int { openControllers.filter { !$0.isSnapshot && ($0.session.hasChanges || $0.isTyping) }.count }
    static let autosaveName = "DropWheelPDFEdit"

    let session: PDFEditSession
    let isSnapshot: Bool
    let window: ImageEditors.EditorWindow
    let root = PDFEditRootView()
    let canvas: PDFEditCanvas
    let scroll = NSScrollView()
    let sidebarScroll = NSScrollView()
    let table = PDFEditThumbnailTable()
    let inspector = PDFEditInspector()
    let banners = PDFEditBannerArea()
    let status = PDFEditStatusBar()
    let undo = UndoManager()
    /// Where saved files are reported (the HUD); the self-test captures them instead.
    var reporter: ([URL]) -> Void = { JobRunner.report(saved: $0) }
    /// The last error shown as a sheet (the self-test reads it; offscreen windows can't show sheets reliably).
    private(set) var lastError: String?

    private(set) var showsSidebar = true
    private(set) var showsInspector = true
    private(set) var modeControl: NSSegmentedControl!
    private(set) var zoomControl: NSSegmentedControl!
    private var undoItem: NSToolbarItem?
    private var redoItem: NSToolbarItem?
    private var saveItem: NSToolbarItem?
    private var sidebarItem: NSToolbarItem?
    private var inspectorItem: NSToolbarItem?
    private var thumbs: [Int: NSImage] = [:]
    private var changedPages: Set<Int> = []
    private var closing = false

    // MARK: Opening

    /// Opens the editor for one PDF (deferred to the next turn of the run loop, so the drop finishes first). A file
    /// that is already open comes to the front.
    static func open(_ url: URL) {
        MainThread.async { openNow(url) }
    }

    private static func openNow(_ url: URL) {
        if let c = openControllers.first(where: { $0.session.url.standardizedFileURL == url.standardizedFileURL }) {
            NSApp.activate(ignoringOtherApps: true)
            c.window.makeKeyAndOrderFront(nil)
            return
        }
        do {
            let session = try PDFEditSession(url: url)
            let c = PDFEditWindowController(session: session, snapshot: false)
            openControllers.append(c)
            c.show()
        } catch {
            HUD.shared.flash(error.localizedDescription, isError: true, seconds: 5)
        }
    }

    init(session: PDFEditSession, snapshot: Bool, size: CGSize? = nil) {
        self.session = session
        isSnapshot = snapshot
        canvas = PDFEditCanvas(session: session)
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let wanted = size ?? CGSize(width: min(1180, visible.width * 0.88).rounded(), height: min(820, visible.height * 0.88).rounded())
        // A snapshot draws as the active window (traffic lights, the accent Save), as the image editors' snapshots do.
        let rect = CGRect(origin: .zero, size: wanted), style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        window = snapshot ? ImageEditors.SnapshotWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
                          : ImageEditors.EditorWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
        super.init()
        build()
    }

    private func build() {
        undo.groupsByEvent = false
        session.undoManager = undo
        session.onChange = { [weak self] change in self?.sessionChanged(change) }

        window.isReleasedWhenClosed = false
        window.title = session.url.lastPathComponent
        window.subtitle = "Edit PDF"
        window.representedURL = isSnapshot ? nil : session.url
        window.contentMinSize = root.minimumSize
        window.delegate = self
        window.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .line
        window.tabbingMode = .disallowed
        // ⌃Tab from the page reaches the sidebar and the inspector (rebuilt as the selection changes).
        window.autorecalculatesKeyViewLoop = true

        let toolbar = NSToolbar(identifier: "DropWheelPDFEdit")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.centeredItemIdentifiers = [Self.modeID, Self.zoomID]
        window.toolbar = toolbar

        if !isSnapshot { canvas.addStyle = inspector.loadRememberedStyle() }
        canvas.delegate = self
        scroll.documentView = canvas
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = ImageEditors.Style.canvas
        scroll.borderType = .noBorder
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)

        let column = NSTableColumn(identifier: .init("page"))
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.intercellSpacing = .zero
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Pages")
        table.controller = self
        sidebarScroll.documentView = table
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.autohidesScrollers = true
        sidebarScroll.drawsBackground = false
        sidebarScroll.borderType = .noBorder
        table.reloadData()
        table.selectRowIndexes([0], byExtendingSelection: false)

        inspector.controller = self
        banners.controller = self
        root.controller = self
        root.sidebar = sidebarScroll
        root.canvasScroll = scroll
        root.inspector = inspector
        root.banners = banners
        root.status = status
        window.contentView = root
        window.initialFirstResponder = canvas

        if session.isReadOnly { modeControl?.setEnabled(false, forSegment: 1) }
        root.layoutSubtreeIfNeeded()
        canvas.updateLayout()
        canvas.setZoom(canvas.fitWidthZoom)
        canvas.scroll(CGPoint(x: canvas.frame.width / 2 - canvas.visibleRect.width / 2, y: 0))
        refreshChrome()
    }

    private func show() {
        if !window.setFrameUsingName(Self.autosaveName) { window.center() }
        window.setFrameAutosaveName(Self.autosaveName)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.makeFirstResponder(canvas)
    }

    // MARK: Changes

    /// Every change to the session, including undo and redo.
    private func sessionChanged(_ change: PDFEditChange) {
        lastChange = change
        let fromUndo = undo.isUndoing || undo.isRedoing
        let now = session.pagesWithChanges
        var touched = now.union(changedPages)
        for id in change.lines { touched.insert(id.page) }
        changedPages = now
        for p in touched { thumbs[p] = nil }
        let rows = IndexSet(touched.filter { $0 < session.pageCount })
        if !rows.isEmpty { table.reloadData(forRowIndexes: rows, columnIndexes: [0]) }
        canvas.sessionChanged()
        if fromUndo {
            if let id = change.lines.first {
                if canvas.editor != nil { canvas.cancelEditing() }
                canvas.select(.line(id))
                canvas.flash(.line(id))
            } else if let a = change.added.first, session.addedTexts.contains(where: { $0.id == a }) {
                canvas.select(.added(a))
                canvas.flash(.added(a))
            } else if let a = change.added.first, case .added(a)? = canvas.selection {
                canvas.select(nil)
            }
        }
        refreshChrome()
    }

    /// Toolbar state, status line, inspector and banners.
    func refreshChrome() {
        refreshToolbarAndStatus()
        modeControl?.selectedSegment = canvas.mode == .editText ? 0 : 1
        sidebarItem?.toolTip = showsSidebar ? "Hide Sidebar (⌃⌘S)" : "Show Sidebar (⌃⌘S)"
        inspectorItem?.toolTip = showsInspector ? "Hide Inspector (⌥⌘I)" : "Show Inspector (⌥⌘I)"
        inspectorShowsTyping = isTyping
        inspector.reload()
        banners.reload()
        root.needsLayout = true
    }

    /// The inline editor holds typing that hasn't been applied yet (Return, Tab or Save applies it).
    var isTyping: Bool { canvas.editor.map { $0.textView.string != $0.startText } ?? false }

    /// Undo, Redo and Save, and the status line: on every change, and on every keystroke while typing.
    private func refreshToolbarAndStatus() {
        let typingUndo = canvas.editor?.typingUndo
        let canUndoTyping = typingUndo?.canUndo ?? false, canRedoTyping = typingUndo?.canRedo ?? false
        undoItem?.isEnabled = undo.canUndo || canUndoTyping
        redoItem?.isEnabled = undo.canRedo || canRedoTyping
        undoItem?.toolTip = canUndoTyping ? "\(typingUndo!.undoMenuItemTitle) (⌘Z)" : undo.canUndo ? "\(undo.undoMenuItemTitle) (⌘Z)" : "Undo (⌘Z)"
        redoItem?.toolTip = canRedoTyping ? "\(typingUndo!.redoMenuItemTitle) (⇧⌘Z)" : undo.canRedo ? "\(undo.redoMenuItemTitle) (⇧⌘Z)" : "Redo (⇧⌘Z)"
        let canSave = session.hasChanges || isTyping
        saveItem?.isEnabled = canSave
        (saveItem?.view as? NSControl)?.isEnabled = canSave
        status.update(left: statusText,
                      right: "Page \(canvas.page + 1) of \(session.pageCount)  ·  \(Int((canvas.zoom * 100).rounded()))%")
    }

    /// The status line: what's being typed (not applied yet), then the session's changes.
    /// "Editing “Line 4: The quick brown fox…” · Return applies it · 1 change on 1 page · …"
    var statusText: String {
        guard let ed = canvas.editor, isTyping else { return session.statusText }
        var parts: [String]
        switch ed.target {
        case .line(let id): parts = ["Editing “\(Self.excerpt(session.info(id)?.text ?? ed.startText))”", "Return applies it"]
        case .added: parts = ["Editing added text", "Return applies it"]
        case .new: parts = ["Adding text", "Return adds it"]
        }
        if session.hasChanges { parts.append(session.statusText) }
        return parts.joined(separator: " · ")
    }

    // MARK: Canvas delegate

    func canvasSelectionChanged(_ canvas: PDFEditCanvas) { refreshChrome() }

    func canvasPageChanged(_ canvas: PDFEditCanvas) {
        if table.selectedRow != canvas.page {
            table.selectRowIndexes([canvas.page], byExtendingSelection: false)
            table.scrollRowToVisible(canvas.page)
        }
        refreshChrome()
    }

    func canvasZoomChanged(_ canvas: PDFEditCanvas) { refreshChrome() }

    func canvasTypingChanged(_ canvas: PDFEditCanvas) {
        refreshToolbarAndStatus()
        // The inspector only changes when typing starts or is put back (it says how to apply it).
        if isTyping != inspectorShowsTyping { refreshChrome() }
    }

    /// Whether the inspector was last built while there was unapplied typing.
    private var inspectorShowsTyping = false

    /// Runs one change and registers it as one named undo step, only if the edit list really changed. (An undo group
    /// opened around a change that is then refused would stay on the stack empty and swallow the next ⌘Z, so the
    /// change runs with the session's undo manager detached and the step is registered here, the way the session
    /// registers its own: undo puts the old edit list back, and redo is registered by the session while undoing.)
    func canvas(_ canvas: PDFEditCanvas, perform failure: String, _ body: () throws -> Void) -> Bool {
        let old = session.edits
        lastChange = nil
        session.undoManager = nil
        var ok = true
        do { try body() } catch {
            ok = false
            showError(error, title: failure)
        }
        session.undoManager = undo
        if let change = lastChange, session.edits != old {
            undo.beginUndoGrouping()
            undo.registerUndo(withTarget: session) { s in
                try? s.replaceEdits(old, actionName: change.actionName, lines: change.lines, added: change.added)
            }
            undo.setActionName(change.actionName)
            undo.endUndoGrouping()
        }
        refreshChrome()
        return ok
    }

    private var lastChange: PDFEditChange?

    /// Runs a change from the inspector or a banner (one undo step).
    @discardableResult
    func perform(_ failure: String, _ body: () throws -> Void) -> Bool { canvas(canvas, perform: failure, body) }

    func showError(_ error: Error, title: String) {
        lastError = error.localizedDescription
        guard !isSnapshot, window.isVisible, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window)
    }

    @objc private func scrolled() { canvas.window?.invalidateCursorRects(for: canvas) }

    // MARK: Actions

    @objc func modeChanged(_ sender: NSSegmentedControl) { setMode(sender.selectedSegment == 1 ? .addText : .editText) }

    func setMode(_ mode: PDFEditCanvas.Mode) {
        if mode == .addText && session.isReadOnly { NSSound.beep(); refreshChrome(); return }
        canvas.mode = mode
        refreshChrome()
    }

    @objc func zoomClicked(_ sender: NSSegmentedControl) {
        sender.selectedSegment == 0 ? canvas.zoomOut() : canvas.zoomIn()
    }

    @objc func toggleSidebar(_ sender: Any?) {
        showsSidebar.toggle()
        root.showsSidebar = showsSidebar
        refreshChrome()
    }

    @objc func toggleInspector(_ sender: Any?) {
        showsInspector.toggle()
        root.showsInspector = showsInspector
        refreshChrome()
    }

    /// ⌘Z: typing first (while a line is being edited), then committed changes.
    @objc func undoAction() {
        if let ed = canvas.editor {
            if ed.typingUndo.canUndo { ed.typingUndo.undo(); canvas.layoutEditor(); refreshChrome(); return }
            canvas.cancelEditing()
        }
        guard undo.canUndo else { NSSound.beep(); return }
        undo.undo()
        refreshChrome()
    }

    @objc func redoAction() {
        if let ed = canvas.editor {
            if ed.typingUndo.canRedo { ed.typingUndo.redo(); canvas.layoutEditor(); refreshChrome(); return }
            canvas.cancelEditing()
        }
        guard undo.canRedo else { NSSound.beep(); return }
        undo.redo()
        refreshChrome()
    }

    /// Window-level keys, before the focused view sees them.
    func handleKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        guard flags.contains(.command) else { return false }
        switch (key, flags) {
        case ("s", .command): save(); return true
        case ("s", [.command, .control]): toggleSidebar(nil); return true
        case ("i", [.command, .option]): toggleInspector(nil); return true
        case ("z", .command): undoAction(); return true
        case ("z", [.command, .shift]): redoAction(); return true
        case ("=", _), ("+", _): canvas.zoomIn(); return true
        case ("-", .command): canvas.zoomOut(); return true
        case ("0", .command): canvas.setZoom(1); return true
        case ("9", .command): canvas.setZoom(canvas.fitWidthZoom); return true
        case ("w", .command): window.performClose(nil); return true
        default: return root.handleTextEditingShortcut(event)
        }
    }

    // MARK: Save and close

    /// The output, once saved (the self-test reads it).
    private(set) var savedURL: URL?

    @objc func save() {
        if canvas.editor != nil, !canvas.commitEditing() { return }
        guard session.hasChanges else { NSSound.beep(); return }
        session.removeReplacedText = inspector.removeReplacedText && session.canRemoveReplacedText
        do {
            let out = try session.save()
            savedURL = out
            forceClose()
            reporter([out])
        } catch {
            // The usual reason the gate fails: typing pushed text past the page edge, where it has no ink.
            var message = error.localizedDescription
            if let bad = lineOffThePage() {
                canvas.select(.line(bad), reveal: true)
                message += " “\(Self.excerpt(session.info(bad)?.text ?? ""))” on page \(bad.page + 1) runs past its room. Choose Fit Width or Keep Position, or shorten it."
            }
            showError(ConversionError.toolFailed(message), title: "Couldn’t save the PDF")
        }
    }

    /// The start of a line, for messages: “Line 2: The quick brown…”.
    static func excerpt(_ text: String, length: Int = 28) -> String {
        let t = text.trimmingCharacters(in: .whitespaces)
        return t.count <= length ? t : String(t.prefix(length)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The first changed line pushed past the edge of its page, where its new letters have no ink, so the final check
    /// refuses to save. (A line that only runs into its neighbours passes that check: when saving fails for another
    /// reason, such as a folder that can't be written to, it isn't to blame.)
    private func lineOffThePage() -> PDFLineID? {
        session.edits.compactMap(\.line).first { id in
            guard let info = session.info(id), !info.isDeleted, info.overflowMessage != nil else { return false }
            let crop = session.pages[id.page].cropBox.insetBy(dx: -0.5, dy: -0.5)
            return info.quad.contains { !crop.contains($0) }
        }
    }

    /// The discard prompt was wanted while the window was offscreen (the self-test reads it).
    var discardPromptPending = false

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard session.hasChanges || isTyping, !isSnapshot else { forceClose(); return false }
        guard sender.isVisible else { discardPromptPending = true; return false }
        let alert = NSAlert()
        alert.messageText = "Discard your changes?"
        alert.informativeText = "Your edits to \(session.url.lastPathComponent) haven’t been saved."
        let discard = alert.addButton(withTitle: "Discard")
        discard.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.forceClose() }
        }
        return false
    }

    /// Closes without asking.
    func forceClose() {
        tearDown()
        window.close()
    }

    func windowWillClose(_ notification: Notification) { tearDown() }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { undo }

    private func tearDown() {
        guard !closing else { return }
        closing = true
        canvas.cancelEditing()
        canvas.anglePopover?.close()
        NotificationCenter.default.removeObserver(self)
        undo.removeAllActions()
        session.onChange = nil
        session.undoManager = nil
        window.keyHandler = nil
        window.delegate = nil
        Self.openControllers.removeAll { $0 === self }
    }

    // MARK: Sidebar

    func numberOfRows(in tableView: NSTableView) -> Int { session.pageCount }

    /// The thumbnail's size for a page (fits 112 × 150 pt).
    func thumbnailSize(_ i: Int) -> CGSize {
        let p = session.pages[i]
        let s = p.rotate % 180 == 0 ? p.cropBox.size : CGSize(width: p.cropBox.height, height: p.cropBox.width)
        guard s.width > 0, s.height > 0 else { return CGSize(width: 112, height: 112) }
        let k = min(112 / s.width, 150 / s.height)
        return CGSize(width: (s.width * k).rounded(), height: (s.height * k).rounded())
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { thumbnailSize(row).height + 40 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: PDFEditThumbnailCell.identifier, owner: nil) as? PDFEditThumbnailCell) ?? PDFEditThumbnailCell()
        cell.identifier = PDFEditThumbnailCell.identifier
        cell.number = row + 1
        cell.thumbSize = thumbnailSize(row)
        cell.edited = session.pagesWithChanges.contains(row)
        cell.selected = row == canvas.page
        cell.image = thumbnail(row)
        cell.setAccessibilityLabel("Page \(row + 1)\(cell.edited ? ", edited" : "")")
        cell.needsDisplay = true
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard row >= 0, row != canvas.page else { return }
        if !canvas.show(page: row) { table.selectRowIndexes([canvas.page], byExtendingSelection: false) }
        table.reloadData(forRowIndexes: IndexSet(0..<session.pageCount), columnIndexes: [0])
    }

    /// A page thumbnail from the candidate document for edited pages, the original otherwise (cached).
    func thumbnail(_ i: Int) -> NSImage? {
        if let t = thumbs[i] { return t }
        let doc = session.pagesWithChanges.contains(i) ? session.candidateDocument : session.originalDocument
        guard let page = doc.page(at: i) else { return nil }
        let size = thumbnailSize(i)
        let scale = window.backingScaleFactor > 0 ? window.backingScaleFactor : 2
        let image = PDFOrganizerThumbnails.render(page, turn: 0, pixels: Int((max(size.width, size.height) * max(2, scale)).rounded()))
        thumbs[i] = image
        return image
    }

    // MARK: Toolbar

    static let sidebarID = NSToolbarItem.Identifier("pdfedit.sidebar")
    static let modeID = NSToolbarItem.Identifier("pdfedit.mode")
    static let zoomID = NSToolbarItem.Identifier("pdfedit.zoom")
    static let undoID = NSToolbarItem.Identifier("pdfedit.undo")
    static let redoID = NSToolbarItem.Identifier("pdfedit.redo")
    static let inspectorID = NSToolbarItem.Identifier("pdfedit.inspector")
    static let saveID = NSToolbarItem.Identifier("pdfedit.save")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.sidebarID, .flexibleSpace, Self.modeID, Self.zoomID, .flexibleSpace, Self.undoID, Self.redoID, Self.inspectorID, Self.saveID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case Self.sidebarID:
            let item = symbolItem(id, symbols: ["sidebar.leading", "sidebar.left"], label: "Sidebar", tip: "Hide Sidebar (⌃⌘S)",
                                  action: #selector(toggleSidebar(_:)))
            item.isNavigational = true
            sidebarItem = item
            return item
        case Self.modeID:
            let seg = NSSegmentedControl(labels: ["Edit Text", "Add Text"], trackingMode: .selectOne,
                                         target: self, action: #selector(modeChanged(_:)))
            seg.selectedSegment = canvas.mode == .editText ? 0 : 1
            seg.setToolTip("Click a line on the page to change it", forSegment: 0)
            seg.setToolTip("Click the page to add new text", forSegment: 1)
            seg.setWidth(84, forSegment: 0)
            seg.setWidth(84, forSegment: 1)
            seg.setAccessibilityLabel("Mode")
            if session.isReadOnly { seg.setEnabled(false, forSegment: 1) }
            modeControl = seg
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = seg
            item.label = "Mode"
            item.toolTip = "Edit Text or Add Text"
            item.autovalidates = false
            return item
        case Self.zoomID:
            let out = NSImage(systemSymbolName: "minus.magnifyingglass", accessibilityDescription: "Zoom Out") ?? NSImage()
            let inn = NSImage(systemSymbolName: "plus.magnifyingglass", accessibilityDescription: "Zoom In") ?? NSImage()
            let seg = NSSegmentedControl(images: [out, inn], trackingMode: .momentary, target: self, action: #selector(zoomClicked(_:)))
            seg.setToolTip("Zoom Out (⌘−)", forSegment: 0)
            seg.setToolTip("Zoom In (⌘+)", forSegment: 1)
            seg.setWidth(34, forSegment: 0)
            seg.setWidth(34, forSegment: 1)
            seg.setAccessibilityLabel("Zoom")
            zoomControl = seg
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = seg
            item.label = "Zoom"
            item.autovalidates = false
            return item
        case Self.undoID:
            let item = symbolItem(id, symbols: ["arrow.uturn.backward"], label: "Undo", tip: "Undo (⌘Z)", action: #selector(undoAction))
            undoItem = item
            return item
        case Self.redoID:
            let item = symbolItem(id, symbols: ["arrow.uturn.forward"], label: "Redo", tip: "Redo (⇧⌘Z)", action: #selector(redoAction))
            redoItem = item
            return item
        case Self.inspectorID:
            let item = symbolItem(id, symbols: ["sidebar.trailing", "sidebar.right"], label: "Inspector", tip: "Hide Inspector (⌥⌘I)",
                                  action: #selector(toggleInspector(_:)))
            inspectorItem = item
            return item
        case Self.saveID:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Save"
            item.toolTip = "Save a copy named “\(outputName)” (⌘S)"
            item.autovalidates = false
            // The image editors' accent push button. An item's `.prominent` style draws nothing in YummyOrange's
            // toolbars (pre-Liquid Glass look), which left Save as plain grey text on screen.
            let button = ImageEditors.Bar.ProminentButton(title: "Save", target: self, action: #selector(save))
            button.toolTip = item.toolTip
            button.setAccessibilityLabel("Save")
            item.view = button
            let menu = NSMenuItem(title: "Save", action: #selector(save), keyEquivalent: "s")
            menu.target = self
            item.menuFormRepresentation = menu
            saveItem = item
            return item
        default:
            return nil
        }
    }

    /// "report edited.pdf".
    var outputName: String { outputURL(for: session.url, ext: "pdf", suffix: " edited").lastPathComponent }

    private func symbolItem(_ id: NSToolbarItem.Identifier, symbols: [String], label: String, tip: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.image = symbols.lazy.compactMap { NSImage(systemSymbolName: $0, accessibilityDescription: label) }.first
        item.label = label
        item.paletteLabel = label
        item.toolTip = tip
        item.target = self
        item.action = action
        item.isBordered = true
        item.autovalidates = false
        return item
    }

    // MARK: Snapshot

    /// The whole window (title bar, toolbar, sidebar, page, inspector) rendered offscreen for `--snapshot editpdf`.
    /// Options: page (1-based), select (text of a line), hover (text), replace (the selected line's whole new text, committed),
    /// spacing (flow|keep|fit for it), editing (true: the inline editor open), type (text typed into it, not committed),
    /// mode (edit|add), add (a text added at x,y page points), zoom, sidebar/inspector (false hides them),
    /// width/height (content size), dark.
    static func snapshotView(url: URL, options: ToolOptions) -> NSView? {
        let session: PDFEditSession
        do { session = try PDFEditSession(url: url) } catch {
            let label = NSTextField(wrappingLabelWithString: error.localizedDescription)
            label.frame = CGRect(x: 0, y: 0, width: 480, height: 80)
            return label
        }
        func side(_ key: String, _ fallback: Double) -> CGFloat {
            let v = options.double(key, fallback)
            return CGFloat(v.isFinite ? min(max(v, 400), 3000) : fallback)
        }
        let c = PDFEditWindowController(session: session, snapshot: true, size: CGSize(width: side("width", 1180), height: side("height", 760)))
        return c.renderSnapshot(options)
    }

    func renderSnapshot(_ options: ToolOptions) -> NSView {
        let dark = options.bool("dark", false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        if !options.bool("sidebar", true) { toggleSidebar(nil) }
        if !options.bool("inspector", true) { toggleInspector(nil) }
        root.layoutSubtreeIfNeeded()
        if let p = Int(options.string("page", "")), p >= 1, p <= session.pageCount { canvas.show(page: p - 1) }
        if let z = Double(options.string("zoom", "")) {
            canvas.setZoom(CGFloat(z) / (z > 8 ? 100 : 1))
            canvas.scroll(CGPoint(x: max(0, canvas.pageFrame.minX - PDFEditCanvas.margin), y: 0))
        }
        if let add = options["add"], !add.isEmpty {
            let crop = session.pages[canvas.page].cropBox
            let origin = CGPoint(x: options.double("x", crop.minX + 72), y: options.double("y", crop.maxY - 120))
            var added: UUID?
            perform("Couldn’t add the text") { added = try session.addText(add, page: canvas.page, at: origin, style: canvas.addStyle) }
            if let added {
                canvas.select(.added(added))
                canvas.scrollToVisible(canvas.viewBounds(.added(added), grow: 160))
            }
        }
        if options.string("mode", "edit") == "add" { setMode(.addText) }
        if let text = options["select"], !text.isEmpty,
           let id = session.find(text, page: canvas.page).first ?? session.find(text).first {
            canvas.select(.line(id))
            if let new = options["replace"] {
                perform("Couldn’t change the text") { try session.setText(new, for: id) }
                if let sp = try? PDFEditTool.spacing(options["spacing"]), sp != .flow {
                    perform("Couldn’t change the spacing") { try session.setSpacing(sp, for: id) }
                }
                canvas.select(.line(id))
            }
            if options.bool("editing", false) {
                canvas.beginEditing(.line(id))
                if let typed = options["type"], let tv = canvas.editor?.textView {
                    // Typed as the keyboard would (so typing undo and the status line show it too).
                    tv.selectAll(nil)
                    tv.insertText(typed, replacementRange: NSRange(location: NSNotFound, length: 0))
                    canvas.layoutEditor()
                }
            }
            canvas.scrollToVisible(canvas.viewBounds(.line(id), grow: 120))
        }
        if let h = options["hover"], let id = session.find(h, page: canvas.page).first {
            let b = canvas.viewBounds(.line(id))
            canvas.scrollToVisible(b.insetBy(dx: 0, dy: -80))
            canvas.hover(at: CGPoint(x: b.midX, y: b.midY))
        }
        refreshChrome()
        root.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        root.layoutSubtreeIfNeeded()
        guard let frameView = window.contentView?.superview else { return root }
        frameView.layoutSubtreeIfNeeded()
        frameView.display()
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return root }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        let image = NSImage(size: frameView.bounds.size)
        image.addRepresentation(rep)
        let view = NSImageView(frame: CGRect(origin: .zero, size: frameView.bounds.size))
        view.image = image
        view.imageScaling = .scaleAxesIndependently
        tearDown()
        window.contentView = nil
        return view
    }
}

// MARK: - Root view

/// The window's content: sidebar | banners over the page | inspector, with the status bar along the bottom.
final class PDFEditRootView: ImageEditors.EditorRootView {
    weak var controller: PDFEditWindowController?
    var sidebar: NSView? { didSet { replace(oldValue, sidebar) } }
    var canvasScroll: NSView? { didSet { replace(oldValue, canvasScroll) } }
    var inspector: NSView? { didSet { replace(oldValue, inspector) } }
    var banners: PDFEditBannerArea? { didSet { replace(oldValue, banners) } }
    var status: NSView? { didSet { replace(oldValue, status) } }
    var showsSidebar = true { didSet { needsLayout = true } }
    var showsInspector = true { didSet { needsLayout = true } }
    private let sidebarLine = ImageEditors.FillView(color: ImageEditors.Style.hairline)
    private let inspectorLine = ImageEditors.FillView(color: ImageEditors.Style.hairline)

    static let sidebarWidth: CGFloat = 168
    static let inspectorWidth: CGFloat = 264
    static let statusHeight: CGFloat = 28

    override var minimumSize: CGSize { CGSize(width: 900, height: 540) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(sidebarLine)
        addSubview(inspectorLine)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func replace(_ old: NSView?, _ new: NSView?) {
        old?.removeFromSuperview()
        if let new { addSubview(new) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let sh = Self.statusHeight
        let sw = showsSidebar ? Self.sidebarWidth : 0
        let iw = showsInspector ? Self.inspectorWidth : 0
        let body = h - sh
        sidebar?.isHidden = !showsSidebar
        sidebarLine.isHidden = !showsSidebar
        inspector?.isHidden = !showsInspector
        inspectorLine.isHidden = !showsInspector
        sidebar?.frame = CGRect(x: 0, y: 0, width: max(0, sw - 1), height: body)
        sidebarLine.frame = CGRect(x: sw - 1, y: 0, width: 1, height: body)
        inspector?.frame = CGRect(x: w - iw + 1, y: 0, width: max(0, iw - 1), height: body)
        inspectorLine.frame = CGRect(x: w - iw, y: 0, width: 1, height: body)
        let cx = sw, cw = max(0, w - sw - iw)
        let bh = banners?.height(forWidth: cw) ?? 0
        banners?.frame = CGRect(x: cx, y: 0, width: cw, height: bh)
        canvasScroll?.frame = CGRect(x: cx, y: bh, width: cw, height: max(0, body - bh))
        status?.frame = CGRect(x: 0, y: body, width: w, height: sh)
        if let c = controller?.canvas { c.updateLayout() }
    }

    override func handleKey(_ event: NSEvent) -> Bool { controller?.handleKey(event) ?? false }
    override func requestSave() { controller?.save() }
    override func requestCancel() { window?.performClose(nil) }
}

// MARK: - Sidebar thumbnails

/// The page list. Up and down arrows move between pages.
final class PDFEditThumbnailTable: NSTableView {
    weak var controller: PDFEditWindowController?
    override var acceptsFirstResponder: Bool { true }
}

/// One page: its thumbnail, a selection backdrop, the page number, and a dahlia dot when the page has changes.
final class PDFEditThumbnailCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("PDFEditThumbnailCell")
    var image: NSImage?
    var number = 1
    var edited = false
    var selected = false
    var thumbSize = CGSize(width: 112, height: 145)

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let t = CGRect(x: ((bounds.width - thumbSize.width) / 2).rounded(), y: 10, width: thumbSize.width, height: thumbSize.height)
            if selected {
                NSColor.unemphasizedSelectedContentBackgroundColor.setFill()
                NSBezierPath(roundedRect: t.insetBy(dx: -6, dy: -6), xRadius: 7, yRadius: 7).fill()
            }
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
            shadow.shadowBlurRadius = 3
            shadow.shadowOffset = CGSize(width: 0, height: -1)
            shadow.set()
            NSColor.white.setFill()
            t.fill()
            NSGraphicsContext.restoreGraphicsState()
            image?.draw(in: t, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            NSColor.black.withAlphaComponent(0.12).setStroke()
            NSBezierPath(rect: t.insetBy(dx: -0.5, dy: -0.5)).stroke()

            let font = NSFont.systemFont(ofSize: 11, weight: selected ? .semibold : .regular)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: selected ? NSColor.labelColor : NSColor.secondaryLabelColor]
            let text = "\(number)" as NSString
            let size = text.size(withAttributes: attrs)
            let dot: CGFloat = edited ? 10 : 0
            let x = (bounds.width - size.width - dot) / 2 + dot
            let y = t.maxY + 9
            text.draw(at: CGPoint(x: x.rounded(), y: y), withAttributes: attrs)
            if edited {
                DWPalette.accentOnBackground.setFill()
                NSBezierPath(ovalIn: CGRect(x: (x - 10).rounded(), y: (y + size.height / 2 - 3).rounded(), width: 6, height: 6)).fill()
            }
        }
    }
}

// MARK: - Banners

/// Banners above the page: signed, certified, scanned, recognized text only, unreadable content, shared text
/// (with All Pages / Only This Page) and why the selected text can't be edited.
final class PDFEditBannerArea: NSView {
    weak var controller: PDFEditWindowController?
    private(set) var rows: [PDFEditBannerRow] = []
    /// The banners' messages (the self-test reads them).
    var messages: [String] { rows.map(\.message) }

    override var isFlipped: Bool { true }

    func reload() {
        guard let c = controller else { return }
        let session = c.session, canvas = c.canvas
        var wanted: [(symbol: String, tint: NSColor, text: String, accessory: NSView?)] = []
        for b in session.banners(page: canvas.page) {
            switch b {
            case .signed: wanted.append(("signature", .secondaryLabelColor, b.message, nil))
            case .certified: wanted.append(("lock.fill", .secondaryLabelColor, b.message, nil))
            case .scanned: wanted.append(("doc.viewfinder", .secondaryLabelColor, b.message,
                                          canvas.mode == .editText && !session.isReadOnly ? addTextButton() : nil))
            case .ocrOnly: wanted.append(("text.viewfinder", .secondaryLabelColor, b.message, nil))
            case .unreadable: wanted.append(("exclamationmark.triangle.fill", .systemOrange, b.message, nil))
            case .sharedText: break
            }
        }
        if case .line(let id)? = canvas.selection {
            if case .sharedText(let n)? = session.banner(for: id) {
                let seg = NSSegmentedControl(labels: ["All Pages", "Only This Page"], trackingMode: .selectOne,
                                             target: self, action: #selector(scopeChanged(_:)))
                seg.controlSize = .small
                seg.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
                let scope = session.info(id).flatMap { $0.isEdited ? $0.scope : nil } ?? canvas.pendingScope[id] ?? .thisPage
                seg.selectedSegment = scope == .allPages ? 0 : 1
                seg.setAccessibilityLabel("Change this text on")
                wanted.append(("square.on.square", .secondaryLabelColor, PDFEditBanner.sharedText(pages: n).message, seg))
            }
            if let why = canvas.availability(id).reason {
                wanted.append(("lock.fill", .secondaryLabelColor, why, nil))
            }
            for note in session.notes(id) where note != .hiddenText || session.banners(page: canvas.page).contains(.ocrOnly) == false {
                wanted.append(("info.circle", .secondaryLabelColor, note.message, nil))
            }
        }
        rows.forEach { $0.removeFromSuperview() }
        rows = wanted.map { PDFEditBannerRow(symbol: $0.symbol, tint: $0.tint, message: $0.text, accessory: $0.accessory) }
        rows.forEach(addSubview)
        needsLayout = true
    }

    private func addTextButton() -> NSView {
        let b = NSButton(title: "Add Text", target: self, action: #selector(addText(_:)))
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        return b
    }

    @objc private func addText(_ sender: Any?) { controller?.setMode(.addText) }

    @objc private func scopeChanged(_ sender: NSSegmentedControl) {
        guard let c = controller, case .line(let id)? = c.canvas.selection else { return }
        let scope: PDFEditScope = sender.selectedSegment == 0 ? .allPages : .thisPage
        c.canvas.pendingScope[id] = scope
        if c.session.info(id)?.isEdited == true {
            c.perform("Couldn’t change where the text is edited") { try c.session.setScope(scope, for: id) }
        }
    }

    func height(forWidth w: CGFloat) -> CGFloat {
        rows.reduce(0) { $0 + $1.height(forWidth: w) }
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        for r in rows {
            let h = r.height(forWidth: bounds.width)
            r.frame = CGRect(x: 0, y: y, width: bounds.width, height: h)
            y += h
        }
    }
}

/// One banner: a symbol, a sentence and an optional control, on the bar colour with a hairline below.
final class PDFEditBannerRow: NSView {
    let message: String
    private let icon = NSImageView()
    private let label: NSTextField
    /// The banner's control (Add Text, or All Pages | Only This Page).
    let accessory: NSView?

    init(symbol: String, tint: NSColor, message: String, accessory: NSView?) {
        self.message = message
        self.accessory = accessory
        label = NSTextField(wrappingLabelWithString: message)
        super.init(frame: .zero)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        icon.contentTintColor = tint
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.isSelectable = false
        addSubview(icon)
        addSubview(label)
        if let accessory { addSubview(accessory) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(message)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    private var accessorySize: CGSize { accessory?.fittingSize ?? .zero }

    func height(forWidth w: CGFloat) -> CGFloat {
        let textWidth = max(40, w - 16 - 18 - 8 - (accessory == nil ? 16 : accessorySize.width + 28))
        label.preferredMaxLayoutWidth = textWidth
        let th = label.cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: textWidth, height: 1000)).height ?? 16
        return max(36, (th + 18).rounded(.up), accessorySize.height + 12)
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let a = accessorySize
        let textWidth = max(40, bounds.width - 16 - 18 - 8 - (accessory == nil ? 16 : a.width + 28))
        icon.frame = CGRect(x: 16, y: ((h - 18) / 2).rounded(), width: 18, height: 18)
        let th = label.cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: textWidth, height: 1000)).height ?? 16
        label.frame = CGRect(x: 42, y: ((h - th) / 2).rounded(), width: textWidth, height: th)
        accessory?.frame = CGRect(x: bounds.width - 16 - a.width, y: ((h - a.height) / 2).rounded(), width: a.width, height: a.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            ImageEditors.Style.chrome.setFill()
            bounds.fill()
            NSColor.labelColor.withAlphaComponent(0.035).setFill()
            bounds.fill(using: .sourceOver)
            ImageEditors.Style.hairline.setFill()
            CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill(using: .sourceOver)
        }
    }
}

// MARK: - Status bar

/// "3 changes on 2 pages · 1 font substituted" on the leading side, "Page 1 of 3 · 100%" on the trailing side.
final class PDFEditStatusBar: ImageEditors.FillView {
    let left = ImageEditors.Style.label("", size: 12, color: .secondaryLabelColor)
    let right = ImageEditors.Style.label("", size: 12, color: .secondaryLabelColor)

    init() {
        super.init(color: ImageEditors.Style.chrome, hairlines: [.minY])
        right.alignment = .right
        addSubview(left)
        addSubview(right)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Status")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(left l: String, right r: String) {
        left.stringValue = l
        left.toolTip = l
        right.stringValue = r
        setAccessibilityValue("\(l). \(r)")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let rw = right.fittingSize.width.rounded(.up)
        let lh = left.fittingSize.height
        right.frame = CGRect(x: bounds.width - 16 - rw, y: ((h - lh) / 2).rounded() + 0.5, width: rw, height: lh)
        left.frame = CGRect(x: 16, y: ((h - lh) / 2).rounded() + 0.5, width: max(0, bounds.width - 48 - rw), height: lh)
    }
}

