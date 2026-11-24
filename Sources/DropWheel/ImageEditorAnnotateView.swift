import AppKit

extension ImageEditors {
    /// Canvas tools, with their toolbar symbol and single-key shortcut.
    enum AnnotateTool: String, CaseIterable {
        case select, arrow, line, rect, ellipse, pen, highlight, text

        var symbol: String {
            switch self {
            case .select: return "cursorarrow"
            case .arrow: return "arrow.up.right"
            case .line: return "line.diagonal"
            case .rect: return "rectangle"
            case .ellipse: return "circle"
            case .pen: return "scribble"
            case .highlight: return "highlighter"
            case .text: return "textformat"
            }
        }

        var name: String {
            switch self {
            case .select: return "Select"
            case .arrow: return "Arrow"
            case .line: return "Line"
            case .rect: return "Rectangle"
            case .ellipse: return "Ellipse"
            case .pen: return "Pen"
            case .highlight: return "Highlighter"
            case .text: return "Text"
            }
        }

        var shortcut: String {
            switch self {
            case .select: return "v"
            case .arrow: return "a"
            case .line: return "l"
            case .rect: return "r"
            case .ellipse: return "o"
            case .pen: return "p"
            case .highlight: return "h"
            case .text: return "t"
            }
        }

        var hint: String {
            switch self {
            case .select: return "Click a mark to select it. Drag to move it or its handles to reshape it. ⌫ deletes, arrow keys nudge."
            case .arrow: return "Drag to draw an arrow; it points where you let go. Hold ⇧ for 45° angles."
            case .line: return "Drag to draw a line. Hold ⇧ for 45° angles."
            case .rect: return "Drag to draw a rectangle. Hold ⇧ for a square."
            case .ellipse: return "Drag to draw an ellipse. Hold ⇧ for a circle."
            case .pen: return "Drag to draw freehand."
            case .highlight: return "Drag over what you want to highlight. Hold ⇧ for a straight stroke."
            case .text: return "Click where the text goes, type, then press Return. Click a text mark to edit it."
            }
        }

        static let swatches: [(name: String, color: RGBA)] = ["red", "orange", "yellow", "green", "blue", "purple", "black", "white"]
            .map { ($0.capitalized, RGBA.named($0)) }
    }

    /// The Annotate window: Delete, Undo, Redo and Save in the window toolbar; a markup bar with tools, colors
    /// and sizes under it (as in Preview); the canvas; and a status bar with a hint and the image's size.
    final class AnnotateEditorView: EditorRootView {
        static let proxyPixels = 2400

        private let source: SourceImage
        let canvas: AnnotationCanvas
        private var toolControl: NSSegmentedControl!
        private var sizeControl: NSSegmentedControl!
        private var swatchButtons: [SwatchButton] = []
        private let moreColors = ColorPanelButton()
        private var undoItem: NSToolbarItem!
        private var redoItem: NSToolbarItem!
        private var undoRedoGroup: NSToolbarItemGroup!
        private var deleteItem: NSToolbarItem!
        private var saveItem: NSToolbarItem!
        private let statusBar = StatusBar()
        private var hintLabel: NSTextField { statusBar.leading }
        private var spinner: NSProgressIndicator { statusBar.spinner }
        private var isSaving = false
        private var isClosed = false

        override var minimumSize: CGSize { CGSize(width: 900, height: 540) }

        init(source: SourceImage, loadAsync: Bool = true) {
            self.source = source
            canvas = AnnotationCanvas(imageSize: source.size)
            super.init(frame: CGRect(x: 0, y: 0, width: 1100, height: 720))
            buildInterface()
            canvas.onChange = { [weak self] in self?.updateControls() }
            selectTool(.arrow)
            if loadAsync { loadProxy() } else { canvas.setImage(try? source.proxy(maxPixels: Self.proxyPixels)) }
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        // MARK: Interface

        private func buildInterface() {
            let top = buildMarkupBar()
            let bottom = buildStatusBar()
            for view in [top, canvas, bottom] as [NSView] {
                view.translatesAutoresizingMaskIntoConstraints = false
                addSubview(view)
            }
            NSLayoutConstraint.activate([
                top.topAnchor.constraint(equalTo: topAnchor),
                top.leadingAnchor.constraint(equalTo: leadingAnchor),
                top.trailingAnchor.constraint(equalTo: trailingAnchor),
                top.heightAnchor.constraint(equalToConstant: 48),
                canvas.topAnchor.constraint(equalTo: top.bottomAnchor),
                canvas.leadingAnchor.constraint(equalTo: leadingAnchor),
                canvas.trailingAnchor.constraint(equalTo: trailingAnchor),
                canvas.bottomAnchor.constraint(equalTo: bottom.topAnchor),
                bottom.leadingAnchor.constraint(equalTo: leadingAnchor),
                bottom.trailingAnchor.constraint(equalTo: trailingAnchor),
                bottom.bottomAnchor.constraint(equalTo: bottomAnchor),
                bottom.heightAnchor.constraint(equalToConstant: StatusBar.height),
            ])
        }

        /// Tools, colors and sizes: a bar inside the window, under its toolbar.
        private func buildMarkupBar() -> NSView {
            let bar = FillView(color: Style.chrome, hairlines: .maxY)
            let tools = AnnotateTool.allCases
            let icons = tools.map { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: $0.name) ?? NSImage() }
            toolControl = NSSegmentedControl(images: icons, trackingMode: .selectOne, target: self, action: #selector(toolChosen))
            toolControl.segmentStyle = .rounded
            toolControl.controlSize = .large
            for (i, tool) in tools.enumerated() {
                toolControl.setToolTip("\(tool.name) (\(tool.shortcut.uppercased()))", forSegment: i)
                toolControl.setWidth(36, forSegment: i)
            }

            for (name, color) in AnnotateTool.swatches {
                let swatch = SwatchButton(color: color, name: name)
                swatch.onClick = { [weak self] in self?.colorChosen(color) }
                swatchButtons.append(swatch)
            }
            moreColors.onPick = { [weak self] color in
                self?.canvas.setColor(color, continuous: true)
                self?.updateControls()
            }
            let swatches = NSStackView(views: swatchButtons + [moreColors])
            swatches.spacing = 2
            swatches.setCustomSpacing(6, after: swatchButtons[swatchButtons.count - 1])

            sizeControl = NSSegmentedControl(images: [1.5, 3, 5, 8].map(Self.lineImage), trackingMode: .selectOne,
                                             target: self, action: #selector(sizeChosen))
            sizeControl.segmentStyle = .rounded
            sizeControl.controlSize = .large
            for (i, name) in ["Small", "Medium", "Large", "Extra large"].enumerated() {
                sizeControl.setToolTip("\(name) lines and text (\(i + 1))", forSegment: i)
                sizeControl.setWidth(34, forSegment: i)
            }
            sizeControl.selectedSegment = canvas.sizeLevel

            let stack = NSStackView(views: [toolControl, Style.separator(), swatches, Style.separator(), sizeControl, NSView()])
            stack.orientation = .horizontal
            stack.spacing = 14
            stack.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
            stack.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
                stack.topAnchor.constraint(equalTo: bar.topAnchor),
                stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -1),
            ])
            return bar
        }

        /// The window toolbar: Delete, Undo and Redo, then Save, on the trailing side.
        private func buildToolbarItems() {
            let (group, undo, redo) = Bar.undoRedo(target: self, undo: #selector(undoClicked), redo: #selector(redoClicked))
            undoRedoGroup = group
            undoItem = undo
            redoItem = redo
            deleteItem = Bar.symbol("delete", "trash", label: "Delete", tip: "Delete the selected mark (⌫)",
                                    target: self, action: #selector(deleteClicked))
            saveItem = Bar.save(target: self, action: #selector(saveClicked),
                                tip: "Save a full-size copy with the marks next to the original (⌘S)")
        }

        override func makeToolbarItems() -> [NSToolbarItem] {
            [Bar.flexibleSpace(), deleteItem, undoRedoGroup, Bar.space(), saveItem]
        }

        /// Information only: what the current tool does, and the image's size and format.
        private func buildStatusBar() -> NSView {
            buildToolbarItems()
            statusBar.trailing.stringValue = source.summary
            return statusBar
        }

        /// A template image of a horizontal stroke, for the size control.
        private static func lineImage(_ thickness: CGFloat) -> NSImage {
            let image = NSImage(size: CGSize(width: 22, height: 14), flipped: false) { rect in
                let path = NSBezierPath()
                path.move(to: CGPoint(x: 3 + thickness / 2, y: rect.midY))
                path.line(to: CGPoint(x: rect.maxX - 3 - thickness / 2, y: rect.midY))
                path.lineWidth = thickness
                path.lineCapStyle = .round
                NSColor.black.setStroke()
                path.stroke()
                return true
            }
            image.isTemplate = true
            return image
        }

        private func updateControls() {
            Bar.enable(undoItem, canvas.canUndo && !isSaving)
            Bar.enable(redoItem, canvas.canRedo && !isSaving)
            Bar.enable(deleteItem, canvas.selection != nil && !isSaving)
            Bar.enable(saveItem, !canvas.annotations.isEmpty && canvas.image != nil && !isSaving)
            let current = canvas.currentColor
            for swatch in swatchButtons { swatch.isSelected = swatch.color == current }
            moreColors.customColor = swatchButtons.contains { $0.color == current } ? nil : current
            sizeControl?.selectedSegment = canvas.sizeLevel
            if let index = AnnotateTool.allCases.firstIndex(of: canvas.tool) { toolControl?.selectedSegment = index }
            hintLabel.stringValue = canvas.tool.hint
        }

        // MARK: Actions

        func selectTool(_ tool: AnnotateTool) {
            canvas.tool = tool
            updateControls()
        }

        @objc private func toolChosen() {
            let tools = AnnotateTool.allCases
            guard toolControl.selectedSegment >= 0, toolControl.selectedSegment < tools.count else { return }
            selectTool(tools[toolControl.selectedSegment])
            if !canvas.isEditingText { window?.makeFirstResponder(canvas) }
        }

        private func colorChosen(_ color: RGBA) {
            canvas.setColor(color)
            updateControls()
        }


        @objc private func sizeChosen() {
            canvas.setSizeLevel(sizeControl.selectedSegment)
            updateControls()
            if !canvas.isEditingText { window?.makeFirstResponder(canvas) }
        }

        @objc private func undoClicked() { canvas.undo() }
        @objc private func redoClicked() { canvas.redo() }
        @objc private func deleteClicked() { canvas.deleteSelection() }
        @objc private func saveClicked() { requestSave() }

        // MARK: Loading, saving, closing

        private func loadProxy() {
            canvas.isLoading = true
            let source = self.source
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = Result { try source.proxy(maxPixels: Self.proxyPixels) }
                DispatchQueue.main.async {
                    guard let self, !self.isClosed else { return }
                    self.canvas.isLoading = false
                    switch result {
                    case .success(let image): self.canvas.setImage(image)
                    case .failure(let error):
                        self.hintLabel.stringValue = error.localizedDescription
                        self.hintLabel.textColor = .systemRed
                    }
                    self.updateControls()
                }
            }
        }

        override func didAppear() { window?.makeFirstResponder(canvas) }

        override func requestSave() {
            canvas.commitTextEdit()
            guard !isSaving, !canvas.annotations.isEmpty, canvas.image != nil else { NSSound.beep(); return }
            isSaving = true
            spinner.startAnimation(nil)
            hintLabel.stringValue = "Saving…"
            updateControls()
            let items = canvas.annotations, source = self.source
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = Result { try AnnotationRenderer.save(items, source: source) }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isSaving = false
                    self.spinner.stopAnimation(nil)
                    self.updateControls()
                    switch result {
                    case .success(let url):
                        JobRunner.report(saved: [url])
                        self.onFinish?(url)
                    case .failure(let error):
                        JobRunner.report(saved: [], errors: [error.localizedDescription])
                        self.showError(error, title: "Couldn’t save the annotated copy")
                    }
                }
            }
        }

        override var hasUnsavedChanges: Bool { !isSaving && !canvas.annotations.isEmpty }

        /// Closes straight away when nothing was drawn; otherwise asks before throwing the marks away.
        override func requestCancel() {
            guard !isSaving else { return }
            canvas.cancelTextEdit()
            guard !canvas.annotations.isEmpty, window != nil else { onFinish?(nil); return }
            confirmDiscard("Discard your annotations?",
                           detail: "The marks on “\(source.url.lastPathComponent)” haven’t been saved.") { [weak self] in
                self?.onFinish?(nil)
            }
        }

        override func tearDown() {
            isClosed = true
            canvas.cancelTextEdit()
            canvas.setImage(nil)
            moreColors.detachPanel()
        }

        // MARK: Keys

        override func handleKey(_ event: NSEvent) -> Bool {
            guard event.type == .keyDown else { return false }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            let editingText = window?.firstResponder is NSText
            if event.keyCode == 53 {   // Esc: leave the text, drop the stroke, clear the selection, then close
                if canvas.isEditingText { canvas.cancelTextEdit() }
                else if canvas.cancelDraft() {}
                else if canvas.selection != nil { canvas.select(nil) }
                else { requestCancel() }
                return true
            }
            if flags == .command && key == "s" { requestSave(); return true }
            if flags == .command && key == "w" { requestCancel(); return true }
            if handleTextEditingShortcut(event) { return true }
            if editingText { return false }
            if flags == .command && key == "z" { canvas.undo(); return true }
            if flags == [.command, .shift] && key == "z" { canvas.redo(); return true }
            switch event.keyCode {
            case 51, 117:   // delete, forward delete
                guard canvas.selection != nil else { return false }
                canvas.deleteSelection()
                return true
            case 123, 124, 125, 126:   // arrows nudge the selection
                guard canvas.selection != nil, flags.subtracting(.shift).isEmpty else { return false }
                let step: CGFloat = flags.contains(.shift) ? 10 : 1
                let d: [UInt16: CGVector] = [123: CGVector(dx: -step, dy: 0), 124: CGVector(dx: step, dy: 0),
                                             125: CGVector(dx: 0, dy: step), 126: CGVector(dx: 0, dy: -step)]
                canvas.nudgeSelection(byViewPoints: d[event.keyCode]!, repeating: event.isARepeat)
                return true
            default:
                break
            }
            guard flags.isEmpty else { return false }
            if let tool = AnnotateTool.allCases.first(where: { $0.shortcut == key }) {
                selectTool(tool)
                return true
            }
            if let level = Int(key), (1...4).contains(level) {
                canvas.setSizeLevel(level - 1)
                updateControls()
                return true
            }
            return false
        }
    }

    // MARK: - Swatch

    /// A round color button for the toolbar; a ring marks the current color.
    final class SwatchButton: NSView {
        let color: RGBA
        var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true } } }
        var onClick: (() -> Void)?

        init(color: RGBA, name: String) {
            self.color = color
            super.init(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
            toolTip = name
            setAccessibilityRole(.button)
            setAccessibilityLabel(name)
            translatesAutoresizingMaskIntoConstraints = false
            widthAnchor.constraint(equalToConstant: 24).isActive = true
            heightAnchor.constraint(equalToConstant: 24).isActive = true
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { onClick?() }

        override func draw(_ dirtyRect: NSRect) {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let dot = NSBezierPath(ovalIn: bounds.insetBy(dx: 5, dy: 5))
                color.nsColor.setFill()
                dot.fill()
                NSColor(white: 0.5, alpha: 0.45).setStroke()
                dot.lineWidth = 1
                dot.stroke()
                if isSelected {
                    let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 1.5))
                    ring.lineWidth = 2
                    NSColor.controlAccentColor.setStroke()
                    ring.stroke()
                }
            }
        }
    }
}

extension ImageEditors {
    /// "Other colors": a hue ring that opens the system color panel. When the current color isn't one of the
    /// presets, the ring shows it in the middle and gets the selection ring.
    final class ColorPanelButton: NSView {
        var customColor: RGBA? { didSet { if customColor != oldValue { needsDisplay = true } } }
        var onPick: ((RGBA) -> Void)?
        /// The button the shared panel reports to (the last one clicked, in any editor window).
        private static weak var panelOwner: ColorPanelButton?

        init() {
            super.init(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
            toolTip = "Other colors…"
            setAccessibilityRole(.button)
            setAccessibilityLabel("Other colors")
            translatesAutoresizingMaskIntoConstraints = false
            widthAnchor.constraint(equalToConstant: 24).isActive = true
            heightAnchor.constraint(equalToConstant: 24).isActive = true
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            let panel = NSColorPanel.shared
            panel.showsAlpha = false
            panel.isContinuous = true
            panel.setTarget(nil)
            if let customColor { panel.color = customColor.nsColor }
            panel.setTarget(self)
            panel.setAction(#selector(panelChanged(_:)))
            panel.orderFront(nil)
            Self.panelOwner = self
        }

        @objc private func panelChanged(_ panel: NSColorPanel) { onPick?(RGBA(panel.color)) }

        /// Disconnects from (and hides) the shared color panel when the editor closes.
        func detachPanel() {
            guard Self.panelOwner === self else { return }
            Self.panelOwner = nil
            let panel = NSColorPanel.shared
            panel.setTarget(nil)
            panel.setAction(nil)
            panel.orderOut(nil)
        }

        override func draw(_ dirtyRect: NSRect) {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let center = CGPoint(x: bounds.midX, y: bounds.midY)
                let radius: CGFloat = 7.5
                let steps = 36
                for i in 0..<steps {
                    let start = CGFloat(i) / CGFloat(steps) * 360, end = CGFloat(i + 1) / CGFloat(steps) * 360 + 1
                    let arc = NSBezierPath()
                    arc.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end)
                    arc.lineWidth = 3.5
                    NSColor(hue: CGFloat(i) / CGFloat(steps), saturation: 0.8, brightness: 1, alpha: 1).setStroke()
                    arc.stroke()
                }
                if let customColor {
                    customColor.nsColor.setFill()
                    NSBezierPath(ovalIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)).fill()
                    let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 1.5))
                    ring.lineWidth = 2
                    NSColor.controlAccentColor.setStroke()
                    ring.stroke()
                }
            }
        }
    }
}

extension ImageEditors.AnnotateEditorView {
    /// An editor with marks from options, for `--snapshot annotate`: annotations=<JSON>, tool=, selected=,
    /// color=, size=0…3.
    static func snapshot(source: ImageEditors.SourceImage, options: ToolOptions) throws -> ImageEditors.AnnotateEditorView {
        let view = ImageEditors.AnnotateEditorView(source: source, loadAsync: false)
        let items = try ImageEditors.Annotation.parse(options["annotations"] ?? "", imageSize: source.size)
        // Checked: ToolOptions.int would trap on a huge number.
        let level = options.double("size", 1)
        view.canvas.setSizeLevel(level.isFinite ? Int(min(max(level.rounded(), 0), 3)) : 1)
        if let hex = options["color"], let color = ImageEditors.RGBA(hex: hex) { view.canvas.setColor(color) }
        view.selectTool(ImageEditors.AnnotateTool(rawValue: options.string("tool", "arrow").lowercased()) ?? .arrow)
        view.canvas.setAnnotations(items)
        if let index = options["selected"].flatMap(Int.init) {
            view.selectTool(.select)
            view.canvas.select(index)
        }
        return view
    }
}
