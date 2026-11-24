import AppKit

extension ImageEditors {
    /// The Crop window: the aspect pop-up and rotate buttons in the toolbar's leading group, Reset, Undo, Redo
    /// and Save on the trailing side, the picture with a crop frame in the middle, and a hint with the crop's
    /// size in pixels in the status bar. Save runs the Crop command with the frame as options.
    final class CropEditorView: EditorRootView {
        static let proxyPixels = 2400

        let source: SourceImage
        let canvas: CropCanvas
        let statusBar = StatusBar()
        private let aspectPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        private var aspectItem: NSToolbarItem!
        private var rotateGroup: NSToolbarItemGroup!
        private var resetItem: NSToolbarItem!
        private var undoRedoGroup: NSToolbarItemGroup!
        private var undoItem: NSToolbarItem!
        private var redoItem: NSToolbarItem!
        private var saveItem: NSToolbarItem!
        private var isClosed = false
        /// Set when Save handed the crop to the job runner, so the window can close.
        private(set) var savedOptions: ToolOptions?
        /// Tests: receives Save's options instead of the job runner.
        var saveHandler: ((ToolOptions) -> Void)?

        override var minimumSize: CGSize { CGSize(width: 760, height: 500) }

        init(source: SourceImage, loadAsync: Bool = true) {
            self.source = source
            canvas = CropCanvas(imageSize: source.size)
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
            statusBar.leading.stringValue = "Drag a corner or an edge to crop, or inside to move. Return saves."
            canvas.onChange = { [weak self] in self?.updateControls() }
            if loadAsync { loadProxy() } else { canvas.setImage(try? source.proxy(maxPixels: Self.proxyPixels)) }
            updateControls()
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        // MARK: Toolbar

        private func buildToolbarItems() {
            aspectPopup.addItems(withTitles: ImageCrop.Aspect.allCases.map(\.title))
            aspectPopup.target = self
            aspectPopup.action = #selector(aspectChosen)
            aspectPopup.toolTip = "Aspect ratio of the crop"
            aspectPopup.setAccessibilityLabel("Aspect ratio")
            let aspectMenu = NSMenuItem(title: "Aspect Ratio", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for aspect in ImageCrop.Aspect.allCases {
                let item = NSMenuItem(title: aspect.title, action: #selector(aspectMenuChosen(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = aspect.rawValue
                submenu.addItem(item)
            }
            aspectMenu.submenu = submenu
            aspectItem = Bar.view("aspect", aspectPopup, label: "Aspect Ratio", menu: aspectMenu)

            let left = Bar.symbol("rotateLeft", "rotate.left", label: "Rotate Left", tip: "Rotate left (⌘L)",
                                  target: self, action: #selector(rotateLeft))
            let right = Bar.symbol("rotateRight", "rotate.right", label: "Rotate Right", tip: "Rotate right (⌘R)",
                                   target: self, action: #selector(rotateRight))
            rotateGroup = NSToolbarItemGroup(itemIdentifier: .init("rotate"))
            rotateGroup.subitems = [left, right]
            rotateGroup.label = "Rotate"
            rotateGroup.paletteLabel = "Rotate"

            resetItem = Bar.text("reset", "Reset", tip: "Back to the whole picture, unrotated", target: self, action: #selector(resetClicked))
            let (group, undo, redo) = Bar.undoRedo(target: self, undo: #selector(undoClicked), redo: #selector(redoClicked))
            undoRedoGroup = group
            undoItem = undo
            redoItem = redo
            saveItem = Bar.save(target: self, action: #selector(saveClicked), tip: "Save the cropped copy next to the original (⌘S)")
        }

        override func makeToolbarItems() -> [NSToolbarItem] {
            [Bar.flexibleSpace(), aspectItem, rotateGroup, Bar.flexibleSpace(), resetItem, Bar.space(), undoRedoGroup, Bar.space(), saveItem]
        }

        override var centeredToolbarItems: Set<NSToolbarItem.Identifier> { [aspectItem.itemIdentifier, rotateGroup.itemIdentifier] }

        private func updateControls() {
            let state = canvas.state
            if let index = ImageCrop.Aspect.allCases.firstIndex(of: state.aspect), aspectPopup.indexOfSelectedItem != index {
                aspectPopup.selectItem(at: index)
            }
            Bar.enable(undoItem, canvas.canUndo)
            Bar.enable(redoItem, canvas.canRedo)
            Bar.enable(resetItem, state != canvas.initial)
            Bar.enable(saveItem, canvas.hasChanges && canvas.image != nil)
            let plan = canvas.plan
            let out = plan.outputSize
            let turned = plan.turns == 0 ? "" : "  ·  turned \(plan.turns * 90)°"
            statusBar.trailing.stringValue = "\(Int(out.width)) × \(Int(out.height)) px\(turned)  ·  from \(source.summary)\(source.firstPictureNote)"
        }

        // MARK: Actions

        @objc private func aspectChosen() {
            let all = ImageCrop.Aspect.allCases
            guard aspectPopup.indexOfSelectedItem >= 0, aspectPopup.indexOfSelectedItem < all.count else { return }
            canvas.setAspect(all[aspectPopup.indexOfSelectedItem])
            window?.makeFirstResponder(canvas)
        }

        @objc private func aspectMenuChosen(_ sender: NSMenuItem) {
            guard let raw = sender.representedObject as? String, let aspect = ImageCrop.Aspect(rawValue: raw) else { return }
            canvas.setAspect(aspect)
        }

        @objc private func rotateLeft() { canvas.rotate(by: -1) }
        @objc private func rotateRight() { canvas.rotate(by: 1) }
        @objc private func resetClicked() { canvas.reset() }
        @objc private func undoClicked() { canvas.undo() }
        @objc private func redoClicked() { canvas.redo() }
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
                        self.statusBar.leading.stringValue = error.localizedDescription
                        self.statusBar.leading.textColor = .systemRed
                    }
                    self.updateControls()
                }
            }
        }

        override func didAppear() { window?.makeFirstResponder(canvas) }

        /// The options Save runs the Crop command with: exactly what the command line would pass.
        var saveOptions: ToolOptions { canvas.plan.options }

        /// Hands the crop to the job runner (the HUD shows progress and the result) and closes.
        override func requestSave() {
            canvas.cancelDrag()
            guard canvas.hasChanges, canvas.image != nil, let command = ImageCropRedact.command("crop") else { NSSound.beep(); return }
            let options = saveOptions
            savedOptions = options
            if let saveHandler { saveHandler(options) } else { JobRunner.run(.command(command, options), on: [source.url]) }
            onFinish?(nil)
        }

        override var hasUnsavedChanges: Bool { canvas.hasChanges }

        override func requestCancel() {
            canvas.cancelDrag()
            guard canvas.hasChanges, window != nil else { onFinish?(nil); return }
            confirmDiscard(detail: "The crop of “\(source.url.lastPathComponent)” hasn’t been saved.") { [weak self] in
                self?.onFinish?(nil)
            }
        }

        override func tearDown() {
            isClosed = true
            canvas.setImage(nil)
        }

        // MARK: Keys

        override func handleKey(_ event: NSEvent) -> Bool {
            guard event.type == .keyDown else { return false }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if event.keyCode == 53 { canvas.cancelDrag(); return true }   // Esc: stop a drag, never the window
            if flags == .command && key == "s" { requestSave(); return true }
            if flags == .command && key == "w" { requestCancel(); return true }
            if window?.firstResponder is NSText || window?.firstResponder is NSPopUpButton { return false }
            if flags.isEmpty && (event.keyCode == 36 || event.keyCode == 76) { requestSave(); return true }   // Return, Enter
            if flags == .command && key == "z" { canvas.undo(); return true }
            if flags == [.command, .shift] && key == "z" { canvas.redo(); return true }
            if flags == .command && key == "r" { canvas.rotate(by: 1); return true }
            if flags == .command && key == "l" { canvas.rotate(by: -1); return true }
            let arrows: [UInt16: CGVector] = [123: CGVector(dx: -1, dy: 0), 124: CGVector(dx: 1, dy: 0),
                                              125: CGVector(dx: 0, dy: 1), 126: CGVector(dx: 0, dy: -1)]
            if let d = arrows[event.keyCode], flags.subtracting([.shift, .option]).isEmpty {
                let step: CGFloat = flags.contains(.shift) ? 10 : 1
                let v = CGVector(dx: d.dx * step, dy: d.dy * step)
                // ⌥ arrows move the right or bottom edge (resize); plain arrows move the frame.
                if flags.contains(.option) { canvas.resizeByKeyboard(v, repeating: event.isARepeat) }
                else { canvas.nudge(v, repeating: event.isARepeat) }
                return true
            }
            return false
        }

        /// An editor with a crop from options, for `--snapshot crop-image`: x, y, w, h, rotate, aspect.
        static func snapshot(source: SourceImage, options: ToolOptions) throws -> CropEditorView {
            let view = CropEditorView(source: source, loadAsync: false)
            if let text = options["aspect"], let aspect = ImageCrop.Aspect(option: text) { view.canvas.setAspect(aspect) }
            if ["x", "y", "w", "h"].contains(where: { options[$0] != nil }) || options["rotate"] != nil {
                let plan = try ImageCrop.plan(options, size: source.size, name: source.url.lastPathComponent)
                view.canvas.setPlan(plan)
            } else if options["aspect"] == nil {
                // A realistic state: a frame pulled in from every side, as after a first drag.
                let s = source.size
                view.canvas.setPlan(ImageCrop.Plan(rect: CGRect(x: s.width * 0.12, y: s.height * 0.1, width: s.width * 0.66,
                                                                height: s.height * 0.72).integral, turns: 0))
            }
            view.canvas.showsGrid = options.bool("grid", true)
            return view
        }
    }

    // MARK: - Crop canvas

    /// Shows the picture (turned as it will be saved) with everything outside the crop dimmed, a frame with
    /// corner and edge handles, and a rule-of-thirds grid while dragging. The crop lives in upright source
    /// pixels; the shown picture is a downscaled proxy turned by `state.turns`.
    final class CropCanvas: NSView {
        struct State: Equatable {
            var rect: CGRect
            var turns: Int
            var aspect: ImageCrop.Aspect
        }

        let imageSize: CGSize
        private(set) var image: CGImage?
        private var shown: CGImage?
        private var hasAlpha = false
        private(set) var state: State { didSet { if state != oldValue { changed() } } }
        let initial: State
        var onChange: (() -> Void)?
        var isLoading = false { didSet { isLoading ? spinner.startAnimation(nil) : spinner.stopAnimation(nil) } }
        /// The thirds grid also when not dragging (snapshots).
        var showsGrid = false { didSet { needsDisplay = true } }

        private var undoStack: [State] = []
        private var redoStack: [State] = []
        private enum Drag { case handle(FrameEditing.Handle), move(CGPoint), new(CGPoint) }
        private var drag: Drag?
        private var dragStart: State?
        private var dragRectStart: CGRect = .zero
        private var dragMoved = false
        private let spinner = NSProgressIndicator()
        private var tracking: NSTrackingArea?

        init(imageSize: CGSize) {
            self.imageSize = imageSize
            let full = State(rect: CGRect(origin: .zero, size: imageSize), turns: 0, aspect: .free)
            state = full
            initial = full
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
            onChange?()
        }

        private func updateAccessibility() {
            let out = plan.outputSize
            setAccessibilityLabel("Crop frame, \(Int(out.width)) by \(Int(out.height)) pixels. Arrow keys move it; "
                                  + "Option-arrow keys resize it.")
        }

        func setImage(_ image: CGImage?) {
            self.image = image
            hasAlpha = image.map(ImageEditors.hasAlpha) ?? false
            refreshShown()
        }

        private func refreshShown() {
            shown = image.flatMap { try? ImageCrop.rotate($0, turns: state.turns) }
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }

        var canUndo: Bool { !undoStack.isEmpty }
        var canRedo: Bool { !redoStack.isEmpty }
        var hasChanges: Bool { plan.rect != CGRect(origin: .zero, size: imageSize) || plan.turns != 0 }

        /// The crop as it will be saved: whole pixels.
        var plan: ImageCrop.Plan {
            ImageCrop.Plan(rect: FrameEditing.integral(state.rect, in: CGRect(origin: .zero, size: imageSize)), turns: state.turns)
        }

        // MARK: Rotated space
        // "Turned" coordinates are pixels of the picture as shown (after `turns` quarter turns clockwise).

        private var turnedSize: CGSize {
            state.turns % 2 == 1 ? CGSize(width: imageSize.height, height: imageSize.width) : imageSize
        }
        private var turnedBounds: CGRect { CGRect(origin: .zero, size: turnedSize) }

        private func turned(_ p: CGPoint, turns: Int) -> CGPoint {
            let w = imageSize.width, h = imageSize.height
            switch ((turns % 4) + 4) % 4 {
            case 1: return CGPoint(x: h - p.y, y: p.x)
            case 2: return CGPoint(x: w - p.x, y: h - p.y)
            case 3: return CGPoint(x: p.y, y: w - p.x)
            default: return p
            }
        }

        private func unturned(_ p: CGPoint, turns: Int) -> CGPoint {
            let w = imageSize.width, h = imageSize.height
            switch ((turns % 4) + 4) % 4 {
            case 1: return CGPoint(x: p.y, y: h - p.x)
            case 2: return CGPoint(x: w - p.x, y: h - p.y)
            case 3: return CGPoint(x: w - p.y, y: p.x)
            default: return p
            }
        }

        private func box(_ a: CGPoint, _ b: CGPoint) -> CGRect {
            CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        }

        func turnedRect(_ r: CGRect, turns: Int? = nil) -> CGRect {
            let t = turns ?? state.turns
            return box(turned(CGPoint(x: r.minX, y: r.minY), turns: t), turned(CGPoint(x: r.maxX, y: r.maxY), turns: t))
        }

        private func sourceRect(_ r: CGRect, turns: Int? = nil) -> CGRect {
            let t = turns ?? state.turns
            return box(unturned(CGPoint(x: r.minX, y: r.minY), turns: t), unturned(CGPoint(x: r.maxX, y: r.maxY), turns: t))
        }

        private var ratio: CGFloat? { state.aspect.ratio(original: turnedSize) }

        // MARK: View mapping

        var imageRect: CGRect { FrameEditing.fit(turnedSize, in: bounds.insetBy(dx: 32, dy: 32)) }
        /// View points per image pixel.
        var scale: CGFloat { imageRect.width / max(turnedSize.width, 1) }

        func toView(_ p: CGPoint) -> CGPoint { CGPoint(x: imageRect.minX + p.x * scale, y: imageRect.minY + p.y * scale) }
        func toView(_ r: CGRect) -> CGRect {
            let o = toView(r.origin)
            return CGRect(x: o.x, y: o.y, width: r.width * scale, height: r.height * scale)
        }
        func toTurned(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - imageRect.minX) / scale, y: (p.y - imageRect.minY) / scale) }

        /// The crop frame in view points.
        var frameInView: CGRect { toView(turnedRect(state.rect)) }

        private var minSize: CGFloat { max(1, 12 / max(scale, 0.0001)) }

        // MARK: Editing model

        private func commit(_ new: State, from old: State? = nil) {
            let before = old ?? state
            guard new != before else { state = new; return }
            undoStack.append(before)
            if undoStack.count > 200 { undoStack.removeFirst() }
            redoStack.removeAll()
            let turnsChanged = new.turns != state.turns
            state = new
            if turnsChanged { refreshShown() }
        }

        func undo() {
            cancelDrag()
            guard let previous = undoStack.popLast() else { NSSound.beep(); return }
            redoStack.append(state)
            let turnsChanged = previous.turns != state.turns
            state = previous
            if turnsChanged { refreshShown() }
        }

        func redo() {
            cancelDrag()
            guard let next = redoStack.popLast() else { NSSound.beep(); return }
            undoStack.append(state)
            let turnsChanged = next.turns != state.turns
            state = next
            if turnsChanged { refreshShown() }
        }

        /// Sets the aspect; a fixed one makes the frame the largest of that shape around its current center.
        func setAspect(_ aspect: ImageCrop.Aspect) {
            var new = state
            new.aspect = aspect
            if let r = aspect.ratio(original: turnedSize) {
                let current = turnedRect(state.rect)
                let fitted = FrameEditing.largest(ratio: r, in: turnedBounds, around: CGPoint(x: current.midX, y: current.midY))
                new.rect = sourceRect(fitted)
            }
            commit(new)
        }

        /// Quarter turns (+1 clockwise). The frame keeps the same part of the picture; a fixed aspect is kept.
        func rotate(by quarterTurns: Int) {
            cancelDrag()
            var new = state
            new.turns = ((state.turns + quarterTurns) % 4 + 4) % 4
            if let r = state.aspect.ratio(original: new.turns % 2 == 1 ? CGSize(width: imageSize.height, height: imageSize.width) : imageSize),
               state.aspect != .original {
                let shownNow = turnedRect(state.rect, turns: new.turns)
                let size = new.turns % 2 == 1 ? CGSize(width: imageSize.height, height: imageSize.width) : imageSize
                let fitted = FrameEditing.largest(ratio: r, in: CGRect(origin: .zero, size: size), around: CGPoint(x: shownNow.midX, y: shownNow.midY))
                new.rect = sourceRect(fitted, turns: new.turns)
            }
            commit(new)
        }

        func reset() {
            cancelDrag()
            commit(initial)
        }

        /// For snapshots and tests: a crop straight from a plan.
        func setPlan(_ plan: ImageCrop.Plan) {
            var new = state
            new.rect = plan.rect
            new.turns = plan.turns
            commit(new)
        }

        /// Moves the frame by view points. Key repeats join the first press's undo step.
        func nudge(_ d: CGVector, repeating: Bool) {
            var t = turnedRect(state.rect)
            t = FrameEditing.moved(t, by: CGVector(dx: d.dx / scale, dy: d.dy / scale), in: turnedBounds)
            var new = state
            new.rect = sourceRect(t)
            if repeating && canUndo { state = new } else { commit(new) }
        }

        /// Moves the right and bottom edges by view points (⌥ arrows), keeping a fixed aspect.
        func resizeByKeyboard(_ d: CGVector, repeating: Bool) {
            let t = turnedRect(state.rect)
            let handle: FrameEditing.Handle = d.dx != 0 ? .right : .bottom
            let target = CGPoint(x: t.maxX + d.dx / scale, y: t.maxY + d.dy / scale)
            let r = FrameEditing.resize(t, handle: handle, to: target, ratio: ratio, bounds: turnedBounds, minSize: minSize)
            var new = state
            new.rect = sourceRect(r)
            if repeating && canUndo { state = new } else { commit(new) }
        }

        /// Esc during a drag: puts the frame back where the drag started. Returns whether a drag was cancelled.
        @discardableResult func cancelDrag() -> Bool {
            guard drag != nil, let start = dragStart else { return false }
            state = start
            drag = nil
            dragStart = nil
            dragMoved = false
            needsDisplay = true
            return true
        }

        var isDragging: Bool { drag != nil }

        // MARK: Mouse

        private func hit(_ p: CGPoint) -> Drag? {
            let f = frameInView
            if let h = FrameEditing.handle(at: p, of: f) { return .handle(h) }
            if f.contains(p) { return .move(p) }
            return imageRect.insetBy(dx: -FrameEditing.edgeReach, dy: -FrameEditing.edgeReach).contains(p) ? .new(p) : nil
        }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            guard image != nil else { return }
            let p = convert(event.locationInWindow, from: nil)
            guard let what = hit(p) else { return }
            drag = what
            dragStart = state
            dragRectStart = turnedRect(state.rect)
            dragMoved = false
            if case .move = what { NSCursor.closedHand.set() }
        }

        override func mouseDragged(with event: NSEvent) {
            guard let drag, dragStart != nil else { return }
            let p = convert(event.locationInWindow, from: nil)
            let shift = event.modifierFlags.contains(.shift)
            // In Free, ⇧ keeps the frame's current shape.
            let keep = ratio ?? (shift && dragRectStart.height > 0 ? dragRectStart.width / dragRectStart.height : nil)
            var t = dragRectStart
            switch drag {
            case .handle(let h):
                t = FrameEditing.resize(dragRectStart, handle: h, to: toTurned(p), ratio: keep, bounds: turnedBounds, minSize: minSize)
            case .move(let start):
                var d = CGVector(dx: (p.x - start.x) / scale, dy: (p.y - start.y) / scale)
                if shift { if abs(d.dx) > abs(d.dy) { d.dy = 0 } else { d.dx = 0 } }
                t = FrameEditing.moved(dragRectStart, by: d, in: turnedBounds)
            case .new(let start):
                guard dragMoved || hypot(p.x - start.x, p.y - start.y) >= 4 else { return }
                let a = FrameEditing.clamp(toTurned(start), to: turnedBounds), q = FrameEditing.clamp(toTurned(p), to: turnedBounds)
                t = FrameEditing.fromAnchor(a, sx: q.x >= a.x ? 1 : -1, sy: q.y >= a.y ? 1 : -1, width: abs(q.x - a.x),
                                            height: abs(q.y - a.y), ratio: keep, bounds: turnedBounds, minSize: minSize)
            }
            dragMoved = true
            var new = state
            new.rect = sourceRect(t)
            state = new
        }

        override func mouseUp(with event: NSEvent) {
            defer {
                drag = nil
                dragStart = nil
                dragMoved = false
                needsDisplay = true
                window?.invalidateCursorRects(for: self)
            }
            guard drag != nil, let start = dragStart, dragMoved else { return }
            let moved = state
            state = start
            commit(moved, from: start)
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
            switch hit(convert(event.locationInWindow, from: nil)) {
            case .handle(let h): h.cursor.set()
            case .move: NSCursor.openHand.set()
            case .new: NSCursor.crosshair.set()
            case nil: NSCursor.arrow.set()
            }
        }

        // MARK: Drawing

        override func draw(_ dirtyRect: NSRect) {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                Style.canvas.setFill()
                bounds.fill()
                guard let ctx = NSGraphicsContext.current?.cgContext, let shown else { return }
                let r = imageRect
                ImageEditors.drawPicture(shown, in: r, hasAlpha: hasAlpha, ctx: ctx)
                let f = frameInView.integral
                // Outside the crop: dimmed, so the result reads at a glance.
                let dim = NSBezierPath(rect: r)
                dim.append(NSBezierPath(rect: f))
                dim.windingRule = .evenOdd
                NSColor.black.withAlphaComponent(0.55).setFill()
                dim.fill()
                drawFrame(f, ctx: ctx)
            }
        }

        private func drawFrame(_ f: CGRect, ctx: CGContext) {
            if drag != nil || showsGrid {
                let grid = NSBezierPath()
                for i in 1...2 {
                    let x = (f.minX + f.width * CGFloat(i) / 3).rounded() + 0.5, y = (f.minY + f.height * CGFloat(i) / 3).rounded() + 0.5
                    grid.move(to: CGPoint(x: x, y: f.minY)); grid.line(to: CGPoint(x: x, y: f.maxY))
                    grid.move(to: CGPoint(x: f.minX, y: y)); grid.line(to: CGPoint(x: f.maxX, y: y))
                }
                grid.lineWidth = 1
                NSColor.white.withAlphaComponent(0.45).setStroke()
                grid.stroke()
            }
            // The video Crop editor's frame: white border and grips just inside it, on the picture.
            FrameEditing.drawCropFrame(f)

            if drag != nil && dragMoved {
                let out = plan.outputSize
                let text = "\(Int(out.width)) × \(Int(out.height))"
                let width = ceil(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)]).size().width) + 16
                let origin = CGPoint(x: (f.midX - width / 2).rounded(), y: min(f.maxY + 10, bounds.maxY - 26))
                ImageEditors.drawBadge(text, at: origin)
            }
        }

        override func layout() {
            super.layout()
            window?.invalidateCursorRects(for: self)
        }

        // MARK: Tests

        /// Drags from one point to another in view points, as the mouse would.
        func simulateDrag(from a: CGPoint, to b: CGPoint, shift: Bool = false, finish: Bool = true) {
            func event(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: convert(p, to: nil), modifierFlags: shift ? .shift : [], timestamp: 0,
                                   windowNumber: window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            mouseDown(with: event(.leftMouseDown, a))
            for step in 1...4 {
                let k = CGFloat(step) / 4
                mouseDragged(with: event(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k)))
            }
            if finish { mouseUp(with: event(.leftMouseUp, b)) }
        }
    }
}
