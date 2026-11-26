import AppKit

extension ImageEditors {
    enum Kind { case adjust, annotate }

    /// Base class for an editor's content view. The window forwards keys and close requests to it.
    class EditorRootView: NSView {
        /// Called once, with the saved file or nil when cancelled. The window closes in response.
        var onFinish: ((URL?) -> Void)?
        var minimumSize: CGSize { CGSize(width: 760, height: 500) }
        override var isFlipped: Bool { true }
        override var isOpaque: Bool { true }

        /// An opaque base, so translucent hairlines blend with the chrome color (also in offscreen snapshots).
        override func draw(_ dirtyRect: NSRect) {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                Style.chrome.setFill()
                dirtyRect.fill()
            }
        }

        /// The window toolbar's items, leading to trailing (`.flexibleSpace` and `.space` items mark gaps).
        /// Asked once when the window opens; an empty list means no toolbar.
        func makeToolbarItems() -> [NSToolbarItem] { [] }

        /// Items (by identifier) the toolbar centers: the editor's own tool controls.
        var centeredToolbarItems: Set<NSToolbarItem.Identifier> { [] }

        /// Window-level shortcuts, before the focused control sees the key (keyDown and keyUp).
        func handleKey(_ event: NSEvent) -> Bool { false }
        func requestCancel() { onFinish?(nil) }
        func requestSave() {}
        /// Changes that closing would throw away (the updater asks before a restart would).
        var hasUnsavedChanges: Bool { false }
        /// After the window is on screen and key.
        func didAppear() {}
        /// Drop images and caches when the window closes.
        func tearDown() {}

        /// ⌘X, ⌘C, ⌘V and ⌘A for text fields. The app has no Edit menu, so nothing else routes them.
        func handleTextEditingShortcut(_ event: NSEvent) -> Bool {
            guard event.type == .keyDown, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  let text = window?.firstResponder as? NSText else { return false }
            let actions: [String: Selector] = ["x": #selector(NSText.cut(_:)), "c": #selector(NSText.copy(_:)),
                                               "v": #selector(NSText.paste(_:)), "a": #selector(NSText.selectAll(_:))]
            guard let key = event.charactersIgnoringModifiers?.lowercased(), let action = actions[key] else { return false }
            return NSApp.sendAction(action, to: text, from: self)
        }

        /// Shows an error as a sheet on the editor's window (or does nothing offscreen).
        func showError(_ error: Error, title: String) {
            guard let window else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = title
            alert.informativeText = error.localizedDescription
            alert.beginSheetModal(for: window)
        }

        /// “Discard your changes?” as a sheet; `discard` runs only when the person chooses Discard. Without a
        /// window (offscreen tests) nothing is asked and nothing runs.
        func confirmDiscard(_ message: String = "Discard your changes?", detail: String, discard: @escaping () -> Void) {
            guard let window, window.attachedSheet == nil else { return }
            let alert = NSAlert()
            alert.messageText = message
            alert.informativeText = detail
            alert.addButton(withTitle: "Cancel")
            let button = alert.addButton(withTitle: "Discard")
            button.hasDestructiveAction = true
            alert.beginSheetModal(for: window) { response in
                if response == .alertSecondButtonReturn { discard() }
            }
        }
    }

    /// A titled editor window that hands key events to its editor first, so ⌘S, Esc and tool keys work
    /// whatever control has focus.
    class EditorWindow: NSWindow {
        var keyHandler: ((NSEvent) -> Bool)?

        override func sendEvent(_ event: NSEvent) {
            if event.type == .keyDown || event.type == .keyUp, attachedSheet == nil, let keyHandler, keyHandler(event) { return }
            super.sendEvent(event)
        }
    }

    /// Owns one editor window while it's open, and opens a batch of them for a drop.
    final class EditorWindowController: NSObject, NSWindowDelegate {
        private static var openControllers: [EditorWindowController] = []

        /// Open editor windows with changes that haven't been saved.
        static var unsavedCount: Int { openControllers.filter { $0.editor.hasUnsavedChanges }.count }

        let window: EditorWindow
        let editor: EditorRootView
        /// Kept alive here: a toolbar holds its delegate weakly.
        private var toolbarDelegate: EditorToolbar?

        /// Opens one window per image, up to `maxWindows`, and says in the HUD what didn't open. Deferred to the
        /// next turn of the run loop so the drop that triggered it finishes first.
        static func open(_ kind: Kind, files: [URL]) {
            switch kind {
            case .adjust: open(subtitle: "Adjust", verb: "adjust", files: files) { AdjustEditorView(source: $0) }
            case .annotate: open(subtitle: "Annotate", verb: "annotate", files: files) { AnnotateEditorView(source: $0) }
            }
        }

        /// Any image editor: `make` builds the editor for one opened image; `subtitle` names the tool under the
        /// file name ("Crop"); `verb` finishes "Drop images to … them."
        static func open(subtitle: String, verb: String, files: [URL], make: @escaping (SourceImage) throws -> EditorRootView) {
            MainThread.async { openNow(subtitle: subtitle, verb: verb, files: files, make: make) }
        }

        private static func openNow(subtitle: String, verb: String, files: [URL], make: (SourceImage) throws -> EditorRootView) {
            let images = files.filter { FileKind.of($0) == .image }
            guard !images.isEmpty else {
                HUD.shared.flash("Drop images to \(verb) them.", isError: true)
                return
            }
            var errors: [String] = []
            var opened = 0
            for url in images.prefix(maxWindows) {
                do {
                    let source = try SourceImage(url)
                    let controller = EditorWindowController(editor: try make(source), url: source.url, subtitle: subtitle)
                    openControllers.append(controller)
                    controller.show(cascade: opened)
                    opened += 1
                } catch {
                    errors.append(images.count == 1 ? error.localizedDescription
                                                    : "\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            if !errors.isEmpty {
                HUD.shared.flash(errors.joined(separator: " "), isError: true)
            } else if images.count > maxWindows {
                HUD.shared.flash("Opened \(maxWindows) of \(images.count) images. Editors open \(maxWindows) at a time.")
            }
        }

        private init(editor: EditorRootView, url: URL, subtitle: String) {
            self.editor = editor
            let visible = Self.screen.visibleFrame
            let size = CGSize(width: min(1180, visible.width * 0.88).rounded(), height: min(800, visible.height * 0.88).rounded())
            window = EditorWindow(contentRect: CGRect(origin: .zero, size: size),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            super.init()
            toolbarDelegate = Self.configure(window, editor: editor, url: url, subtitle: subtitle)
            // The first window of each kind remembers its size (later ones cascade from the default).
            window.setFrameAutosaveName("DropWheel \(subtitle) Editor")
            window.delegate = self
            editor.onFinish = { [weak self] _ in self?.close() }
        }

        /// Title, subtitle, proxy icon, content, keys and toolbar: shared by real windows and snapshots.
        /// Returns the toolbar's delegate, which the caller must keep.
        @discardableResult
        static func configure(_ window: EditorWindow, editor: EditorRootView, url: URL, subtitle: String) -> EditorToolbar? {
            window.isReleasedWhenClosed = false
            window.title = url.lastPathComponent
            window.subtitle = subtitle
            window.representedURL = url
            window.contentMinSize = editor.minimumSize
            window.contentView = editor
            window.keyHandler = { [weak editor] event in editor?.handleKey(event) ?? false }
            let items = editor.makeToolbarItems()
            guard !items.isEmpty else { return nil }
            let delegate = EditorToolbar(items: items)
            // A unique identifier: toolbars that share one also share their configuration across windows.
            let toolbar = NSToolbar(identifier: "DropWheel.\(subtitle).\(UUID().uuidString)")
            toolbar.delegate = delegate
            toolbar.displayMode = .iconOnly
            toolbar.allowsUserCustomization = false
            toolbar.autosavesConfiguration = false
            toolbar.centeredItemIdentifiers = editor.centeredToolbarItems
            window.toolbar = toolbar
            window.toolbarStyle = .unified
            return delegate
        }

        /// The screen under the pointer (where the drop happened), else the main screen.
        private static var screen: NSScreen {
            NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        }

        /// Centers the window on the drop's screen (a little above the middle, like NSWindow.center), offset
        /// down and right for each further window, then brings the app forward so the editor gets the keyboard.
        private func show(cascade index: Int) {
            let visible = Self.screen.visibleFrame
            var frame = window.frame
            frame.size.width = min(frame.width, visible.width)
            frame.size.height = min(frame.height, visible.height)
            let step = CGFloat(index) * 28
            frame.origin = CGPoint(x: (visible.midX - frame.width / 2 + step).rounded(),
                                   y: (visible.midY - frame.height / 2 + visible.height * 0.05 - step).rounded())
            window.setFrame(frame, display: false)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            editor.didAppear()
        }

        private func close() {
            editor.tearDown()
            editor.onFinish = nil
            window.keyHandler = nil
            window.delegate = nil
            window.close()
            window.toolbar = nil
            window.contentView = nil
            toolbarDelegate = nil
            Self.openControllers.removeAll { $0 === self }
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            editor.requestCancel()
            return false
        }
    }

    /// Serves an editor's ready-made toolbar items, in order. Not customizable.
    final class EditorToolbar: NSObject, NSToolbarDelegate {
        let items: [NSToolbarItem]

        init(items: [NSToolbarItem]) { self.items = items }

        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { items.map(\.itemIdentifier) }
        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { items.map(\.itemIdentifier) }

        func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                     willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
            items.first { $0.itemIdentifier == id }
        }
    }
}

// MARK: - Toolbar items

extension ImageEditors {
    /// Toolbar items in one style for every editor: borderless system symbols in the system's own capsules,
    /// and Save as the single prominent item on the trailing side.
    enum Bar {
        static func space() -> NSToolbarItem { NSToolbarItem(itemIdentifier: .space) }
        static func flexibleSpace() -> NSToolbarItem { NSToolbarItem(itemIdentifier: .flexibleSpace) }

        /// A symbol button. `label` is what VoiceOver and the overflow menu say; `tip` adds the shortcut.
        static func symbol(_ id: String, _ symbol: String, label: String, tip: String,
                           target: AnyObject, action: Selector) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: .init(id))
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            item.label = label
            item.paletteLabel = label
            item.toolTip = tip
            item.isBordered = true
            item.target = target
            item.action = action
            item.autovalidates = false
            return item
        }

        /// A button whose name is clearer than any symbol ("Find Text").
        static func text(_ id: String, _ title: String, tip: String, target: AnyObject, action: Selector) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: .init(id))
            item.title = title
            item.label = title
            item.paletteLabel = title
            item.toolTip = tip
            item.isBordered = true
            item.target = target
            item.action = action
            item.autovalidates = false
            return item
        }

        /// A control (pop-up, segmented control) as an item, with a menu form for the overflow menu.
        static func view(_ id: String, _ view: NSView, label: String, menu: NSMenuItem? = nil) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: .init(id))
            item.view = view
            item.label = label
            item.paletteLabel = label
            item.toolTip = view.toolTip
            view.setAccessibilityLabel(view.accessibilityLabel() ?? label)
            if let menu { item.menuFormRepresentation = menu }
            return item
        }

        /// Undo and Redo side by side in one group.
        static func undoRedo(target: AnyObject, undo: Selector, redo: Selector) -> (group: NSToolbarItemGroup, undo: NSToolbarItem, redo: NSToolbarItem) {
            let u = symbol("undo", "arrow.uturn.backward", label: "Undo", tip: "Undo (⌘Z)", target: target, action: undo)
            let r = symbol("redo", "arrow.uturn.forward", label: "Redo", tip: "Redo (⇧⌘Z)", target: target, action: redo)
            let group = NSToolbarItemGroup(itemIdentifier: .init("undoRedo"))
            group.subitems = [u, r]
            group.label = "Undo and Redo"
            group.paletteLabel = "Undo and Redo"
            return (group, u, r)
        }

        /// Save: the one prominent item, an accent-colored push button. (YummyOrange links against the macOS 13
        /// SDK, so the system draws its toolbars in the pre-Liquid Glass style, where an item's `.prominent`
        /// style has no effect; a tinted button looks the same everywhere.)
        static func save(target: AnyObject, action: Selector, tip: String) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: .init("save"))
            item.label = "Save"
            item.paletteLabel = "Save"
            item.toolTip = tip
            let button = ProminentButton(title: "Save", target: target, action: action)
            button.toolTip = tip
            button.setAccessibilityLabel("Save")
            item.view = button
            let menu = NSMenuItem(title: "Save", action: action, keyEquivalent: "s")
            menu.target = target
            item.menuFormRepresentation = menu
            return item
        }

        /// An accent-filled push button with a white title; plain (the system's disabled look) while disabled.
        final class ProminentButton: NSButton {
            override var isEnabled: Bool { didSet { restyle() } }

            convenience init(title: String, target: AnyObject, action: Selector) {
                self.init(frame: .zero)
                self.title = title
                self.target = target
                self.action = action
                bezelStyle = .rounded
                restyle()
            }

            private func restyle() {
                bezelColor = isEnabled ? .controlAccentColor : nil
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = .center
                attributedTitle = NSAttributedString(string: title, attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: isEnabled ? .medium : .regular),
                    .foregroundColor: isEnabled ? NSColor.white : NSColor.disabledControlTextColor,
                    .paragraphStyle: paragraph,
                ])
            }
        }

        /// Enables an item and, for a control item, its control.
        static func enable(_ item: NSToolbarItem?, _ on: Bool) {
            guard let item else { return }
            item.isEnabled = on
            (item.view as? NSControl)?.isEnabled = on
        }
    }

    /// A slim information bar along the bottom of an editor: a hint or status on the leading side, a readout
    /// on the trailing side, and a spinner while saving. Information only; actions live in the toolbar.
    final class StatusBar: FillView {
        static let height: CGFloat = 30
        let leading = Style.label("", size: 12, color: .secondaryLabelColor)
        let trailing = Style.label("", size: 12, color: .secondaryLabelColor)
        let spinner = NSProgressIndicator()

        init() {
            super.init(color: Style.chrome, hairlines: .minY)
            trailing.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            trailing.alignment = .right
            leading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            trailing.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isDisplayedWhenStopped = false
            let stack = NSStackView(views: [leading, NSView(), spinner, trailing])
            stack.orientation = .horizontal
            stack.spacing = 10
            stack.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                stack.topAnchor.constraint(equalTo: topAnchor, constant: 1),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        required init?(coder: NSCoder) { fatalError("not used") }
    }
}

// MARK: - Window snapshots

extension ImageEditors {
    /// Renders an editor in a real titled window with its toolbar, for `--snapshot`: the window is ordered in
    /// far off every screen, captured from the window server (the only way the toolbar's Liquid Glass comes
    /// out right), then closed. Falls back to the bare editor when the capture isn't possible.
    static func windowSnapshot(_ editor: EditorRootView, url: URL, subtitle: String, size: CGSize, dark: Bool) -> NSView {
        let window = SnapshotWindow(contentRect: CGRect(origin: .zero, size: size),
                                    styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let delegate = EditorWindowController.configure(window, editor: editor, url: url, subtitle: subtitle)
        window.contentMinSize = CGSize(width: 200, height: 200)
        window.setContentSize(size)
        let away = CGPoint(x: -30_000, y: -30_000)
        window.setFrameOrigin(away)
        window.orderFrontRegardless()
        window.makeKey()   // the app stays inactive, so this takes no keyboard focus; it gives the key look
        for name in ["_setForceActiveControls:", "_setForceMainAppearance:"] where window.responds(to: Selector((name))) {
            window.perform(Selector((name)), with: true as NSNumber)
        }
        window.setFrameOrigin(away)
        editor.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))   // toolbar layout and glass settle
        window.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let image = captureWindow(window.windowNumber)
        let frameSize = window.frame.size
        window.orderOut(nil)
        withExtendedLifetime(delegate) {}
        window.toolbar = nil
        window.contentView = nil
        window.close()
        guard let image else {
            editor.frame = CGRect(origin: .zero, size: size)
            return editor
        }
        return CapturedWindowView(image: image, size: frameSize)
    }

    /// CGWindowListCreateImage for one of our own windows (no screen-recording permission needed for those).
    /// Looked up at run time: the macOS 15 SDK no longer exposes it to Swift.
    static func captureWindow(_ number: Int) -> CGImage? {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard number > 0, let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let capture = unsafeBitCast(symbol, to: Capture.self)
        let includingWindow: UInt32 = 1 << 3, ignoreFraming: UInt32 = 1 << 0, bestResolution: UInt32 = 1 << 3
        return capture(.null, includingWindow, UInt32(number), ignoreFraming | bestResolution)?.takeRetainedValue()
    }

    /// A snapshot window: may sit outside every screen, and draws as the active window (traffic lights,
    /// a tinted Save) although the command-line process never becomes active.
    final class SnapshotWindow: EditorWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
        override var isKeyWindow: Bool { true }
        override var isMainWindow: Bool { true }
        // AppKit asks these (unpublished) to choose the active look; a missing one just means an inactive look.
        @objc func _hasActiveAppearance() -> Bool { true }
        @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
        @objc func _hasActiveControls() -> Bool { true }
        @objc func _hasActiveAppearanceForStandardWindowButton(_ button: Int) -> Bool { true }
    }

    /// Shows a captured window image at its size in points.
    private final class CapturedWindowView: NSView {
        let image: CGImage

        init(image: CGImage, size: CGSize) {
            self.image = image
            super.init(frame: CGRect(origin: .zero, size: size))
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func draw(_ dirtyRect: NSRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: bounds)
        }
    }
}

// MARK: - Shared look

extension ImageEditors {
    /// Colors and small views both editors use. Dynamic colors resolve for light and dark at draw time.
    enum Style {
        static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
            NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
        }

        /// Behind the picture: a quiet neutral, darker than the chrome in both modes.
        static let canvas = dynamic(light: NSColor(white: 0.885, alpha: 1), dark: NSColor(white: 0.115, alpha: 1))
        /// Bars and the sidebar.
        static let chrome = dynamic(light: NSColor(white: 0.965, alpha: 1), dark: NSColor(white: 0.185, alpha: 1))
        static let hairline = dynamic(light: NSColor(white: 0, alpha: 0.12), dark: NSColor(white: 0, alpha: 0.55))

        static func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                          color: NSColor = .labelColor) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: size, weight: weight)
            label.textColor = color
            label.lineBreakMode = .byTruncatingTail
            return label
        }

        static func button(_ title: String, target: AnyObject?, action: Selector, primary: Bool = false) -> NSButton {
            let button = NSButton(title: title, target: target, action: action)
            button.bezelStyle = .rounded
            button.controlSize = .large
            if primary { button.bezelColor = .controlAccentColor }
            button.setContentHuggingPriority(.required, for: .horizontal)
            return button
        }

        static func symbolButton(_ symbol: String, tip: String, target: AnyObject?, action: Selector) -> NSButton {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage()
            let button = NSButton(image: image, target: target, action: action)
            button.bezelStyle = .texturedRounded
            button.toolTip = tip
            button.setAccessibilityLabel(tip)
            button.widthAnchor.constraint(equalToConstant: 34).isActive = true
            return button
        }

        /// A thin vertical divider for toolbars.
        static func separator() -> NSView {
            let view = FillView(color: hairline)
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalToConstant: 1).isActive = true
            view.heightAnchor.constraint(equalToConstant: 22).isActive = true
            return view
        }
    }

    /// A view that fills itself with a (dynamic) color. Drawn in `draw`, so offscreen snapshots include it.
    class FillView: NSView {
        var color: NSColor { didSet { needsDisplay = true } }
        /// Edges that get a hairline.
        var hairlineEdges: Edges = []

        init(color: NSColor, hairlines: Edges = []) {
            self.color = color
            hairlineEdges = hairlines
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                // Source-over, not NSRectFill's copy, so translucent colors blend with what's behind.
                color.setFill()
                bounds.fill(using: .sourceOver)
                Style.hairline.setFill()
                let w = bounds.width, h = bounds.height
                if hairlineEdges.contains(.minY) { CGRect(x: 0, y: 0, width: w, height: 1).fill(using: .sourceOver) }
                if hairlineEdges.contains(.maxY) { CGRect(x: 0, y: h - 1, width: w, height: 1).fill(using: .sourceOver) }
                if hairlineEdges.contains(.minX) { CGRect(x: 0, y: 0, width: 1, height: h).fill(using: .sourceOver) }
                if hairlineEdges.contains(.maxX) { CGRect(x: w - 1, y: 0, width: 1, height: h).fill(using: .sourceOver) }
            }
        }
    }

    /// Which edges of a `FillView` get a hairline.
    struct Edges: OptionSet {
        let rawValue: Int
        static let minX = Edges(rawValue: 1), maxX = Edges(rawValue: 2), minY = Edges(rawValue: 4), maxY = Edges(rawValue: 8)
    }
}
