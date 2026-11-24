import AppKit

extension ImageEditors {
    /// The Redact window: Find Text, Find Faces and the style of the selected boxes in the toolbar's leading
    /// group; Delete, Undo, Redo and Save on the trailing side; the picture with the redaction previewed as it
    /// will be saved; a hint and the box count in the status bar. Found boxes arrive selected, so the ones to
    /// keep visible can be removed with ⌫ before saving.
    final class RedactEditorView: EditorRootView {
        static let proxyPixels = 2400

        let source: SourceImage
        let canvas: RedactCanvas
        let statusBar = StatusBar()
        private let styleControl = NSSegmentedControl(labels: ImageRedact.Style.allCases.map(\.title), trackingMode: .selectOne,
                                                      target: nil, action: nil)
        private var findTextItem: NSToolbarItem!
        private var findFacesItem: NSToolbarItem!
        private var styleItem: NSToolbarItem!
        private var addItem: NSToolbarItem!
        private var deleteItem: NSToolbarItem!
        private var undoRedoGroup: NSToolbarItemGroup!
        private var undoItem: NSToolbarItem!
        private var redoItem: NSToolbarItem!
        private var saveItem: NSToolbarItem!
        private var isClosed = false
        private(set) var isFinding = false
        private var message: String?
        private(set) var savedOptions: ToolOptions?
        /// Tests: receives Save's options instead of the job runner.
        var saveHandler: ((ToolOptions) -> Void)?

        override var minimumSize: CGSize { CGSize(width: 820, height: 520) }

        init(source: SourceImage, loadAsync: Bool = true) {
            self.source = source
            canvas = RedactCanvas(imageSize: source.size)
            super.init(frame: CGRect(x: 0, y: 0, width: 1100, height: 720))
            buildToolbarItems()
            for view in [canvas, statusBar] as [NSView] {
                view.translatesAutoresizingMaskIntoConstraints = false
                addSubview(view)
            }
            NSLayoutConstraint.activate([
                canvas.topAnchor.constraint(equalTo: topAnchor),
                canvas.leadingAnchor.constraint(equalTo: leadingAnchor),
                canvas.trailingAnchor.constraint(equalTo: trailingAnchor),
                canvas.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
                statusBar.leadingAnchor.constraint(equalTo: leadingAnchor),
                statusBar.trailingAnchor.constraint(equalTo: trailingAnchor),
                statusBar.bottomAnchor.constraint(equalTo: bottomAnchor),
                statusBar.heightAnchor.constraint(equalToConstant: StatusBar.height),
            ])
            canvas.onChange = { [weak self] in self?.updateControls() }
            canvas.onSelectionChange = { [weak self] in self?.message = nil; self?.updateControls() }
            if loadAsync { loadProxy() } else { canvas.setImage(try? source.proxy(maxPixels: Self.proxyPixels), async: false) }
            updateControls()
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        // MARK: Toolbar

        private func buildToolbarItems() {
            findTextItem = Bar.text("findText", "Find Text", tip: "Suggest a box over every word Vision can read",
                                    target: self, action: #selector(findTextClicked))
            findFacesItem = Bar.text("findFaces", "Find Faces", tip: "Suggest a box over every face", target: self,
                                     action: #selector(findFacesClicked))
            styleControl.target = self
            styleControl.action = #selector(styleChosen)
            styleControl.segmentStyle = .automatic
            for (i, style) in ImageRedact.Style.allCases.enumerated() {
                styleControl.setToolTip("\(style.title): \(Self.styleHelp(style))", forSegment: i)
            }
            styleControl.setAccessibilityLabel("Redaction style")
            styleControl.toolTip = "How the selected boxes, and new ones, hide what’s under them"
            let styleMenu = NSMenuItem(title: "Style", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for style in ImageRedact.Style.allCases {
                let item = NSMenuItem(title: style.title, action: #selector(styleMenuChosen(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = style.rawValue
                submenu.addItem(item)
            }
            styleMenu.submenu = submenu
            styleItem = Bar.view("style", styleControl, label: "Style", menu: styleMenu)
            // The keyboard's (and VoiceOver's) way to start a box; the video Redact editor has the same "+".
            addItem = Bar.symbol("addBox", "plus.rectangle", label: "Add Box",
                                 tip: "Add a box in the middle of the picture; arrow keys move it, ⌥ arrow keys resize it",
                                 target: self, action: #selector(addClicked))
            deleteItem = Bar.symbol("delete", "trash", label: "Delete", tip: "Remove the selected boxes (⌫)",
                                    target: self, action: #selector(deleteClicked))
            let (group, undo, redo) = Bar.undoRedo(target: self, undo: #selector(undoClicked), redo: #selector(redoClicked))
            undoRedoGroup = group
            undoItem = undo
            redoItem = redo
            saveItem = Bar.save(target: self, action: #selector(saveClicked),
                                tip: "Save a redacted copy, without metadata, next to the original (⌘S)")
        }

        override func makeToolbarItems() -> [NSToolbarItem] {
            [Bar.flexibleSpace(), findTextItem, Bar.space(), findFacesItem, Bar.space(), styleItem, Bar.flexibleSpace(), addItem,
             deleteItem, Bar.space(), undoRedoGroup, Bar.space(), saveItem]
        }

        override var centeredToolbarItems: Set<NSToolbarItem.Identifier> {
            [findTextItem.itemIdentifier, findFacesItem.itemIdentifier, styleItem.itemIdentifier]
        }

        private static func styleHelp(_ style: ImageRedact.Style) -> String {
            switch style {
            case .black: return "a solid black box"
            case .blur: return "a heavy blur that can’t be sharpened back"
            case .pixelate: return "large blocks of colour"
            }
        }

        private func updateControls() {
            let boxes = canvas.boxes, selected = canvas.selection
            let styles = Set(selected.compactMap { boxes.indices.contains($0) ? boxes[$0].style : nil })
            let shown = selected.isEmpty ? canvas.currentStyle : styles.count == 1 ? styles.first : nil
            for (i, style) in ImageRedact.Style.allCases.enumerated() { styleControl.setSelected(style == shown, forSegment: i) }
            Bar.enable(undoItem, canvas.canUndo)
            Bar.enable(redoItem, canvas.canRedo)
            Bar.enable(deleteItem, !selected.isEmpty)
            Bar.enable(addItem, canvas.image != nil)
            Bar.enable(findTextItem, !isFinding && canvas.image != nil)
            Bar.enable(findFacesItem, !isFinding && canvas.image != nil)
            Bar.enable(saveItem, !boxes.isEmpty && canvas.image != nil && !isFinding)
            if let message {
                statusBar.leading.stringValue = message
            } else if !selected.isEmpty {
                statusBar.leading.stringValue = selected.count == 1
                    ? "Drag the box or its handles. ⌫ removes it."
                    : "\(selected.count) boxes selected. ⌫ removes them; a style applies to all of them."
            } else {
                statusBar.leading.stringValue = "Drag over what to hide, or let Find Text and Find Faces suggest boxes."
            }
            let count = boxes.count == 1 ? "1 box" : "\(boxes.count) boxes"
            statusBar.trailing.stringValue = "\(count)  ·  \(source.summary)\(source.firstPictureNote)"
        }

        // MARK: Actions

        @objc private func findTextClicked() { find(.text) }
        @objc private func findFacesClicked() { find(.faces) }

        @objc private func styleChosen() {
            let all = ImageRedact.Style.allCases
            guard styleControl.selectedSegment >= 0, styleControl.selectedSegment < all.count else { return }
            canvas.setStyle(all[styleControl.selectedSegment])
            window?.makeFirstResponder(canvas)
        }

        @objc private func styleMenuChosen(_ sender: NSMenuItem) {
            guard let raw = sender.representedObject as? String, let style = ImageRedact.Style(rawValue: raw) else { return }
            canvas.setStyle(style)
        }

        @objc private func addClicked() {
            canvas.addBox()
            window?.makeFirstResponder(canvas)
        }
        @objc private func deleteClicked() { canvas.deleteSelection() }
        @objc private func undoClicked() { canvas.undo() }
        @objc private func redoClicked() { canvas.redo() }
        @objc private func saveClicked() { requestSave() }

        /// Tests: stands in for Vision (what to look for, in which picture → boxes), to simulate a slow search.
        var finder: ((ImageRedact.Find, SourceImage) throws -> [CGRect])?
        /// Bumped by every search and by Esc, so the answer of a search that was stopped is dropped.
        private var findGeneration = 0

        /// Runs Vision off the main thread; the boxes it finds are added and selected. Vision's first request in a
        /// process can take from seconds to minutes (it prepares its model), so Esc stops waiting (`cancelFind`).
        func find(_ what: ImageRedact.Find) {
            guard !isFinding, canvas.image != nil else { return }
            isFinding = true
            findGeneration += 1
            let generation = findGeneration
            message = (what == .faces ? "Looking for faces…" : "Looking for text…") + " Esc stops."
            statusBar.spinner.startAnimation(nil)
            updateControls()
            let source = self.source
            let look = finder ?? { try Self.look(for: $0, in: $1) }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = Result { try look(what, source) }
                DispatchQueue.main.async {
                    guard let self, !self.isClosed, generation == self.findGeneration else { return }
                    self.isFinding = false
                    self.statusBar.spinner.stopAnimation(nil)
                    switch result {
                    case .success(let rects): self.addFound(rects, what: what, style: self.canvas.currentStyle)
                    case .failure(let error): self.message = "Couldn’t look for \(what == .faces ? "faces" : "text"): \(error.localizedDescription)"
                    }
                    self.updateControls()
                }
            }
        }

        /// Esc while looking: stop waiting for Vision (its answer will be ignored), so Save and the other
        /// buttons work again. Returns whether a search was stopped.
        @discardableResult func cancelFind() -> Bool {
            guard isFinding else { return false }
            findGeneration += 1
            isFinding = false
            statusBar.spinner.stopAnimation(nil)
            message = "Stopped looking. Find Text and Find Faces can start again."
            updateControls()
            return true
        }

        /// The same, on the calling thread (snapshots and tests).
        func findNow(_ what: ImageRedact.Find, style: ImageRedact.Style? = nil) throws {
            addFound(try Self.look(for: what, in: source), what: what, style: style ?? canvas.currentStyle)
            updateControls()
        }

        private static func look(for what: ImageRedact.Find, in source: SourceImage) throws -> [CGRect] {
            let look = try Converter.orientedImage(source.source, maxPixels: min(4096, Int(source.longSide)))
            let found = what == .faces ? try ImageRedact.findFaces(look) : try ImageRedact.findText(look)
            let k = source.size.width / CGFloat(look.width)
            return found.map { ImageRedact.scaled($0, by: k, in: source.size) }
        }

        private func addFound(_ rects: [CGRect], what: ImageRedact.Find, style: ImageRedact.Style) {
            let added = canvas.addSuggested(rects, style: style)
            let noun = what == .faces ? (added == 1 ? "face" : "faces") : (added == 1 ? "word" : "words")
            if rects.isEmpty {
                message = what == .faces ? "No faces found." : "No text found."
            } else if added == 0 {
                message = "Every \(what == .faces ? "face" : "word") found is already covered."
            } else {
                message = "Found \(added) \(noun), now selected. ⌫ removes any you want to keep visible."
            }
        }

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
                    case .success(let image): self.canvas.setImage(image, async: true)
                    case .failure(let error): self.message = error.localizedDescription
                    }
                    self.updateControls()
                }
            }
        }

        override func didAppear() { window?.makeFirstResponder(canvas) }

        /// What Save runs the Redact command with: the boxes as drawn, and nothing found again.
        var saveOptions: ToolOptions { ["boxes": ImageRedact.format(canvas.boxes), "find": "none"] }

        override func requestSave() {
            canvas.cancelDrag()
            guard !canvas.boxes.isEmpty, canvas.image != nil, !isFinding,
                  let command = ImageCropRedact.command("redact") else { NSSound.beep(); return }
            let options = saveOptions
            savedOptions = options
            if let saveHandler { saveHandler(options) } else { JobRunner.run(.command(command, options), on: [source.url]) }
            onFinish?(nil)
        }

        override var hasUnsavedChanges: Bool { !canvas.boxes.isEmpty }

        override func requestCancel() {
            canvas.cancelDrag()
            guard !canvas.boxes.isEmpty, window != nil else { onFinish?(nil); return }
            confirmDiscard(detail: "The redaction of “\(source.url.lastPathComponent)” hasn’t been saved.") { [weak self] in
                self?.onFinish?(nil)
            }
        }

        override func tearDown() {
            isClosed = true
            canvas.setImage(nil, async: false)
        }

        // MARK: Keys

        override func handleKey(_ event: NSEvent) -> Bool {
            guard event.type == .keyDown else { return false }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if event.keyCode == 53 {   // Esc: stop a search, then a drag, then clear the selection; never closes the window
                if !cancelFind() && !canvas.cancelDrag() { canvas.select([]) }
                return true
            }
            if flags == .command && key == "s" { requestSave(); return true }
            if flags == .command && key == "w" { requestCancel(); return true }
            if window?.firstResponder is NSText { return false }
            if flags.isEmpty && (event.keyCode == 36 || event.keyCode == 76) { requestSave(); return true }
            if flags == .command && key == "z" { canvas.undo(); return true }
            if flags == [.command, .shift] && key == "z" { canvas.redo(); return true }
            if flags == .command && key == "a" { canvas.select(Set(canvas.boxes.indices)); return true }
            if flags.isEmpty && (event.keyCode == 51 || event.keyCode == 117) {
                guard !canvas.selection.isEmpty else { return false }
                canvas.deleteSelection()
                return true
            }
            let arrows: [UInt16: CGVector] = [123: CGVector(dx: -1, dy: 0), 124: CGVector(dx: 1, dy: 0),
                                              125: CGVector(dx: 0, dy: 1), 126: CGVector(dx: 0, dy: -1)]
            if let d = arrows[event.keyCode], !canvas.selection.isEmpty, flags.subtracting([.shift, .option]).isEmpty {
                let step: CGFloat = flags.contains(.shift) ? 10 : 1
                let v = CGVector(dx: d.dx * step, dy: d.dy * step)
                // ⌥ arrows move the right or bottom edge (resize), as in Crop; plain arrows move the boxes.
                if flags.contains(.option) { canvas.resizeSelection(v, repeating: event.isARepeat) }
                else { canvas.nudgeSelection(v, repeating: event.isARepeat) }
                return true
            }
            return false
        }

        /// An editor with boxes from options, for `--snapshot redact-image`: boxes=…, find=text|faces|both|none,
        /// style= (found text), faceStyle= (found faces). On the built-in sample it finds both by default.
        static func snapshot(source: SourceImage, options: ToolOptions, isSample: Bool) throws -> RedactEditorView {
            let view = RedactEditorView(source: source, loadAsync: false)
            let style = ImageRedact.Style(option: options.string("style", "black")) ?? .black
            let faceStyle = ImageRedact.Style(option: options.string("faceStyle", isSample ? "pixelate" : style.rawValue)) ?? style
            let given = try ImageRedact.parseBoxes(options.string("boxes", ""), size: source.size, defaultStyle: style)
            var all = Set<Int>()
            for box in given {   // each box keeps its own style
                view.canvas.addSuggested([box.rect], style: box.style)
                all.formUnion(view.canvas.selection)
            }
            let find = ImageRedact.Find(option: options.string("find", given.isEmpty ? "both" : "none")) ?? .none
            if find == .text || find == .both { try view.findNow(.text, style: style); all.formUnion(view.canvas.selection) }
            if find == .faces || find == .both { try view.findNow(.faces, style: faceStyle); all.formUnion(view.canvas.selection) }
            // selected=N (1-based) shows one box selected with its knobs, the rest outlined; selected=none, none.
            if let pick = options["selected"] {
                all = Int(pick).map { [$0 - 1] } ?? []
            }
            view.canvas.select(all)
            view.message = nil
            view.canvas.renderPreviewNow()
            view.updateControls()
            return view
        }
    }

    // MARK: - Redaction canvas

    /// The picture with its redaction previewed (rendered from the proxy by the same code that saves), and
    /// box outlines on top: thin white dashes for boxes, the accent colour and handles for the selection.
    final class RedactCanvas: NSView {
        let imageSize: CGSize
        private(set) var image: CGImage?
        private var preview: CGImage?
        private var hasAlpha = false
        private(set) var boxes: [ImageRedact.Box] = [] { didSet { changed() } }
        private(set) var selection: Set<Int> = [] {
            didSet { if selection != oldValue { needsDisplay = true; updateAccessibility(); onSelectionChange?() } }
        }
        private(set) var currentStyle: ImageRedact.Style = .black
        var onChange: (() -> Void)?
        var onSelectionChange: (() -> Void)?
        var isLoading = false { didSet { isLoading ? spinner.startAnimation(nil) : spinner.stopAnimation(nil) } }

        private var undoStack: [[ImageRedact.Box]] = []
        private var redoStack: [[ImageRedact.Box]] = []
        private enum Drag { case handle(Int, FrameEditing.Handle), move(CGPoint), new(CGPoint) }
        private var drag: Drag?
        private var dragBase: [ImageRedact.Box]?
        private var dragSelectionBase: Set<Int> = []
        private var dragMoved = false
        private let spinner = NSProgressIndicator()
        private var tracking: NSTrackingArea?
        private let renderQueue = DispatchQueue(label: "dropwheel.redact.preview", qos: .userInteractive)
        private var isRendering = false
        private var needsRender = false
        private var asyncPreview = true

        init(imageSize: CGSize) {
            self.imageSize = imageSize
            super.init(frame: .zero)
            spinner.style = .spinning
            spinner.isDisplayedWhenStopped = false
            spinner.translatesAutoresizingMaskIntoConstraints = false
            addSubview(spinner)
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor).isActive = true
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
            setAccessibilityElement(true)
            setAccessibilityRole(.image)
            updateAccessibility()
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        private func changed() {
            needsDisplay = true
            updateAccessibility()
            schedulePreview()
            onChange?()
        }

        private func updateAccessibility() {
            setAccessibilityLabel("Picture with \(boxes.count) redaction \(boxes.count == 1 ? "box" : "boxes"), \(selection.count) selected. "
                                  + "Drag or use Add Box to add one; arrow keys move the selection, Option-arrow keys resize it; "
                                  + "Delete removes it.")
        }

        func setImage(_ image: CGImage?, async: Bool) {
            self.image = image
            asyncPreview = async
            hasAlpha = image.map(ImageEditors.hasAlpha) ?? false
            preview = nil
            if async { schedulePreview() } else { renderPreviewNow() }
            needsDisplay = true
        }

        var canUndo: Bool { !undoStack.isEmpty }
        var canRedo: Bool { !redoStack.isEmpty }

        // MARK: Geometry

        private var imageBounds: CGRect { CGRect(origin: .zero, size: imageSize) }
        var imageRect: CGRect { FrameEditing.fit(imageSize, in: bounds.insetBy(dx: 32, dy: 32)) }
        var scale: CGFloat { imageRect.width / max(imageSize.width, 1) }
        func toView(_ p: CGPoint) -> CGPoint { CGPoint(x: imageRect.minX + p.x * scale, y: imageRect.minY + p.y * scale) }
        func toView(_ r: CGRect) -> CGRect {
            let o = toView(r.origin)
            return CGRect(x: o.x, y: o.y, width: r.width * scale, height: r.height * scale)
        }
        func toImage(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - imageRect.minX) / scale, y: (p.y - imageRect.minY) / scale) }
        private var minSize: CGFloat { max(2, 8 / max(scale, 0.0001)) }

        // MARK: Editing model

        private func commit(_ new: [ImageRedact.Box]) {
            guard new != boxes else { return }
            undoStack.append(boxes)
            if undoStack.count > 200 { undoStack.removeFirst() }
            redoStack.removeAll()
            boxes = new
        }

        func undo() {
            cancelDrag()
            guard let previous = undoStack.popLast() else { NSSound.beep(); return }
            redoStack.append(boxes)
            selection = []
            boxes = previous
        }

        func redo() {
            cancelDrag()
            guard let next = redoStack.popLast() else { NSSound.beep(); return }
            undoStack.append(boxes)
            selection = []
            boxes = next
        }

        func select(_ indices: Set<Int>) { selection = indices.filter { boxes.indices.contains($0) } }

        /// Adds boxes (skipping ones already covered by an existing box) and selects what was added.
        @discardableResult func addSuggested(_ rects: [CGRect], style: ImageRedact.Style) -> Int {
            var new = boxes
            var added: Set<Int> = []
            for r in rects {
                let rect = FrameEditing.integral(r, in: imageBounds)
                guard rect.width >= 1, rect.height >= 1 else { continue }
                let covered = new.contains { b in
                    let overlap = b.rect.intersection(rect)
                    return !overlap.isNull && overlap.width * overlap.height >= 0.8 * rect.width * rect.height
                }
                if covered { continue }
                new.append(ImageRedact.Box(rect: rect, style: style))
                added.insert(new.count - 1)
            }
            commit(new)
            selection = added
            return added.count
        }

        /// The style for new boxes; also restyles the selected ones (one undo step).
        func setStyle(_ style: ImageRedact.Style) {
            currentStyle = style
            guard !selection.isEmpty else { onChange?(); return }
            var new = boxes
            for i in selection where new.indices.contains(i) { new[i].style = style }
            commit(new)
            onChange?()
        }

        func deleteSelection() {
            guard !selection.isEmpty else { return }
            let remove = selection
            selection = []
            commit(boxes.enumerated().filter { !remove.contains($0.offset) }.map(\.element))
        }

        /// A new box in the middle of the picture (a quarter of its width and height) in the current style,
        /// selected, so the keyboard can move and resize it: the way to start a box without a mouse.
        func addBox() {
            cancelDrag()
            let w = max(minSize, (imageSize.width / 4).rounded()), h = max(minSize, (imageSize.height / 4).rounded())
            let rect = FrameEditing.integral(CGRect(x: ((imageSize.width - w) / 2).rounded(), y: ((imageSize.height - h) / 2).rounded(),
                                                    width: w, height: h), in: imageBounds)
            guard rect.width >= 1, rect.height >= 1 else { return }
            commit(boxes + [ImageRedact.Box(rect: rect, style: currentStyle)])
            selection = [boxes.count - 1]
        }

        /// Moves the right and bottom edges of the selected boxes by view points (⌥ arrows); key repeats join
        /// the first press's undo step.
        func resizeSelection(_ d: CGVector, repeating: Bool) {
            guard !selection.isEmpty else { return }
            var new = boxes
            for i in selection where new.indices.contains(i) {
                let r = new[i].rect
                let target = CGPoint(x: r.maxX + d.dx / scale, y: r.maxY + d.dy / scale)
                new[i].rect = FrameEditing.resize(r, handle: d.dx != 0 ? .right : .bottom, to: target, ratio: nil,
                                                  bounds: imageBounds, minSize: minSize)
            }
            if repeating && canUndo { boxes = new } else { commit(new) }
        }

        /// Moves the selected boxes by view points; key repeats join the first press's undo step.
        func nudgeSelection(_ d: CGVector, repeating: Bool) {
            guard !selection.isEmpty else { return }
            var new = boxes
            for i in selection where new.indices.contains(i) {
                new[i].rect = FrameEditing.moved(new[i].rect, by: CGVector(dx: d.dx / scale, dy: d.dy / scale), in: imageBounds)
            }
            if repeating && canUndo { boxes = new } else { commit(new) }
        }

        @discardableResult func cancelDrag() -> Bool {
            guard drag != nil, let base = dragBase else { return false }
            boxes = base
            selection = dragSelectionBase
            drag = nil
            dragBase = nil
            dragMoved = false
            needsDisplay = true
            return true
        }

        // MARK: Mouse

        private func hitBox(_ p: CGPoint) -> Int? {
            boxes.indices.reversed().first { toView(boxes[$0].rect).insetBy(dx: -3, dy: -3).contains(p) }
        }

        private func hit(_ p: CGPoint) -> Drag {
            if selection.count == 1, let i = selection.first, boxes.indices.contains(i),
               let h = FrameEditing.handle(at: p, of: toView(boxes[i].rect)) {
                return .handle(i, h)
            }
            if hitBox(p) != nil { return .move(p) }
            return .new(p)
        }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            guard image != nil else { return }
            let p = convert(event.locationInWindow, from: nil)
            let what = hit(p)
            dragBase = boxes
            dragSelectionBase = selection
            dragMoved = false
            switch what {
            case .handle:
                drag = what
            case .move:
                guard let i = hitBox(p) else { return }
                if event.modifierFlags.contains(.shift) {
                    // ⇧-click adds a box to the selection or takes it out; no drag.
                    if selection.contains(i) { selection.remove(i) } else { selection.insert(i) }
                    dragBase = nil
                    return
                }
                if !selection.contains(i) { selection = [i] }
                drag = what
                NSCursor.closedHand.set()
            case .new:
                if !event.modifierFlags.contains(.shift) { selection = [] }
                drag = what
            }
        }

        override func mouseDragged(with event: NSEvent) {
            guard let drag, let base = dragBase else { return }
            let p = convert(event.locationInWindow, from: nil)
            switch drag {
            case .handle(let i, let h):
                guard base.indices.contains(i) else { return }
                var new = base
                new[i].rect = FrameEditing.resize(base[i].rect, handle: h, to: toImage(p), ratio: nil, bounds: imageBounds, minSize: minSize)
                dragMoved = true
                boxes = new
            case .move(let start):
                var d = CGVector(dx: (p.x - start.x) / scale, dy: (p.y - start.y) / scale)
                if event.modifierFlags.contains(.shift) { if abs(d.dx) > abs(d.dy) { d.dy = 0 } else { d.dx = 0 } }
                // The whole selection moves together and stops as one at the picture's edges.
                let union = selection.reduce(CGRect.null) { $0.union(base.indices.contains($1) ? base[$1].rect : .null) }
                guard !union.isNull else { return }
                let allowed = FrameEditing.moved(union, by: d, in: imageBounds)
                let dd = CGVector(dx: allowed.minX - union.minX, dy: allowed.minY - union.minY)
                var new = base
                for i in selection where new.indices.contains(i) { new[i].rect = base[i].rect.offsetBy(dx: dd.dx, dy: dd.dy) }
                dragMoved = true
                boxes = new
            case .new(let start):
                guard dragMoved || hypot(p.x - start.x, p.y - start.y) >= 4 else { return }
                let a = FrameEditing.clamp(toImage(start), to: imageBounds), q = FrameEditing.clamp(toImage(p), to: imageBounds)
                let rect = FrameEditing.fromAnchor(a, sx: q.x >= a.x ? 1 : -1, sy: q.y >= a.y ? 1 : -1, width: abs(q.x - a.x),
                                                   height: abs(q.y - a.y), ratio: nil, bounds: imageBounds, minSize: minSize)
                var new = base
                new.append(ImageRedact.Box(rect: rect, style: currentStyle))
                dragMoved = true
                boxes = new
                selection = [new.count - 1]
            }
        }

        override func mouseUp(with event: NSEvent) {
            defer {
                drag = nil
                dragBase = nil
                dragMoved = false
                needsDisplay = true
            }
            guard drag != nil, let base = dragBase, dragMoved else { return }
            let result = boxes.map { b -> ImageRedact.Box in
                var b = b
                b.rect = FrameEditing.integral(b.rect, in: imageBounds)
                return b
            }
            boxes = base
            commit(result)
        }

        // MARK: Pointer

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            tracking = area
        }

        override func cursorUpdate(with event: NSEvent) { updateCursor(event) }
        override func mouseMoved(with event: NSEvent) { updateCursor(event) }

        private func updateCursor(_ event: NSEvent) {
            guard drag == nil, image != nil else { return }
            let p = convert(event.locationInWindow, from: nil)
            switch hit(p) {
            case .handle(_, let h): h.cursor.set()
            case .move: NSCursor.openHand.set()
            case .new: (imageRect.contains(p) ? NSCursor.crosshair : NSCursor.arrow).set()
            }
        }

        // MARK: Preview

        private func schedulePreview() {
            guard image != nil else { return }
            guard asyncPreview else { renderPreviewNow(); return }
            needsRender = true
            guard !isRendering else { return }
            renderNext()
        }

        private func renderNext() {
            guard needsRender, let image else { return }
            needsRender = false
            isRendering = true
            let k = CGFloat(image.width) / imageSize.width
            let scaled = boxes.map { ImageRedact.Box(rect: $0.rect.applying(CGAffineTransform(scaleX: k, y: k)), style: $0.style) }
            renderQueue.async { [weak self] in
                // detail 1/k: the proxy's blocks are counted as the full-size file's will be.
                let out = scaled.isEmpty ? image : (try? ImageRedact.apply(scaled, to: image, detail: 1 / k))
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isRendering = false
                    guard self.image === image else { return }
                    self.preview = out
                    self.needsDisplay = true
                    self.renderNext()
                }
            }
        }

        /// Renders the preview on the calling thread (snapshots and tests).
        func renderPreviewNow() {
            guard let image else { preview = nil; return }
            let k = CGFloat(image.width) / imageSize.width
            let scaled = boxes.map { ImageRedact.Box(rect: $0.rect.applying(CGAffineTransform(scaleX: k, y: k)), style: $0.style) }
            preview = scaled.isEmpty ? image : (try? ImageRedact.apply(scaled, to: image, detail: 1 / k))
            needsDisplay = true
        }

        var previewImage: CGImage? { preview }

        // MARK: Drawing

        override func draw(_ dirtyRect: NSRect) {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                Style.canvas.setFill()
                bounds.fill()
                guard let ctx = NSGraphicsContext.current?.cgContext, let picture = preview ?? image else { return }
                ImageEditors.drawPicture(picture, in: imageRect, hasAlpha: hasAlpha, ctx: ctx)
                // While a drag is changing boxes, show them right away over the last preview.
                if drag != nil, dragMoved {
                    for i in selection where boxes.indices.contains(i) && boxes[i].style == .black {
                        NSColor.black.setFill()
                        toView(boxes[i].rect).fill()
                    }
                }
                // The video Redact editor's look: a white outline for every box, the app's accent and knobs for the
                // selection, each with a soft dark shadow so it reads on any picture.
                for (i, box) in boxes.enumerated() where !selection.contains(i) {
                    FrameEditing.outline(toView(box.rect).integral, selected: false)
                }
                for i in selection where boxes.indices.contains(i) {
                    FrameEditing.outline(toView(boxes[i].rect).integral, selected: true)
                }
                if selection.count == 1, let i = selection.first, boxes.indices.contains(i) {
                    FrameEditing.drawKnobs(for: toView(boxes[i].rect).integral, edges: true)
                }
            }
        }

        // MARK: Tests

        func simulateDrag(from a: CGPoint, to b: CGPoint, shift: Bool = false) {
            func event(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: convert(p, to: nil), modifierFlags: shift ? .shift : [], timestamp: 0,
                                   windowNumber: window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            mouseDown(with: event(.leftMouseDown, a))
            for step in 1...4 {
                let k = CGFloat(step) / 4
                mouseDragged(with: event(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k)))
            }
            mouseUp(with: event(.leftMouseUp, b))
        }
    }
}
