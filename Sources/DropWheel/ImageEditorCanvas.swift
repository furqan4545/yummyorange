import AppKit

extension ImageEditors {
    /// Shows the picture and its marks, and turns mouse drags into marks. Marks live in full-resolution image
    /// pixels (top-left origin), so the saved file matches the screen whatever the window size; the picture on
    /// screen is a downscaled proxy.
    final class AnnotationCanvas: NSView, NSTextFieldDelegate {
        let imageSize: CGSize
        private(set) var image: CGImage?
        private var hasAlpha = false
        private(set) var annotations: [Annotation] = [] { didSet { changed() } }
        private(set) var selection: Int? { didSet { if selection != oldValue { changed() } } }
        var tool: AnnotateTool = .arrow {
            didSet {
                guard tool != oldValue else { return }
                commitTextEdit()
                if tool != .select { selection = nil }
                window?.invalidateCursorRects(for: self)
                changed()
            }
        }
        /// Color for new marks; the highlighter keeps its own.
        private(set) var color = RGBA.named("red")
        private(set) var highlightColor = Annotation.highlightColor
        /// 0…3: small, medium, large, extra large.
        private(set) var sizeLevel = 1
        var onChange: (() -> Void)?
        var isLoading = false { didSet { isLoading ? spinner.startAnimation(nil) : spinner.stopAnimation(nil) } }

        private var undoStack: [[Annotation]] = []
        private var redoStack: [[Annotation]] = []
        private var draft: Annotation?
        private var dragAnchor: CGPoint?
        /// State when a move or reshape began, for one undo step per drag.
        private var dragBase: [Annotation]?
        private var activeHandle: Int?
        /// The mark the color panel is recoloring, so a drag across the panel is one undo step.
        private var colorEditIndex: Int?
        private var textField: NSTextField?
        private var textEditIndex: Int?
        private var textTemplate: Annotation?
        private let spinner = NSProgressIndicator()

        init(imageSize: CGSize) {
            self.imageSize = imageSize
            super.init(frame: .zero)
            spinner.style = .spinning
            spinner.isDisplayedWhenStopped = false
            spinner.translatesAutoresizingMaskIntoConstraints = false
            addSubview(spinner)
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor).isActive = true
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        private func changed() {
            needsDisplay = true
            onChange?()
        }

        func setImage(_ image: CGImage?) {
            self.image = image
            hasAlpha = image.map(ImageEditors.hasAlpha) ?? false
            changed()
        }

        var canUndo: Bool { !undoStack.isEmpty }
        var canRedo: Bool { !redoStack.isEmpty }
        var isEditingText: Bool { textField != nil }

        // MARK: Geometry

        var imageRect: CGRect { ImageEditors.fit(imageSize, in: bounds.insetBy(dx: 28, dy: 28)) }
        /// View points per image pixel.
        var scale: CGFloat { imageRect.width / max(imageSize.width, 1) }

        func toImage(_ p: CGPoint) -> CGPoint {
            let r = imageRect
            return CGPoint(x: (p.x - r.minX) / scale, y: (p.y - r.minY) / scale)
        }

        func toView(_ p: CGPoint) -> CGPoint {
            let r = imageRect
            return CGPoint(x: r.minX + p.x * scale, y: r.minY + p.y * scale)
        }

        func toView(_ rect: CGRect) -> CGRect {
            let origin = toView(rect.origin)
            return CGRect(x: origin.x, y: origin.y, width: rect.width * scale, height: rect.height * scale)
        }

        private func clamped(_ p: CGPoint) -> CGPoint {
            CGPoint(x: min(max(p.x, 0), imageSize.width), y: min(max(p.y, 0), imageSize.height))
        }

        // Sizes scale with the image, so a mark looks the same on a screenshot and on a 50 MP photo.
        private var longSide: CGFloat { max(imageSize.width, imageSize.height) }
        var strokeWidth: CGFloat { max([1.5, 2, 3, 5][sizeLevel], (longSide * [0.0025, 0.004, 0.007, 0.012][sizeLevel]).rounded()) }
        var textSize: CGFloat { max(10, (longSide * [0.018, 0.028, 0.042, 0.064][sizeLevel]).rounded()) }
        var currentColor: RGBA {
            if let i = selection, annotations.indices.contains(i) { return annotations[i].color }
            return tool == .highlight ? highlightColor : color
        }

        // MARK: Editing model

        private func commit(_ new: [Annotation]) {
            guard new != annotations else { return }
            colorEditIndex = nil
            undoStack.append(annotations)
            if undoStack.count > 200 { undoStack.removeFirst() }
            redoStack.removeAll()
            annotations = new
        }

        func setAnnotations(_ items: [Annotation]) { commit(items) }

        func undo() {
            commitTextEdit()
            guard let previous = undoStack.popLast() else { NSSound.beep(); return }
            redoStack.append(annotations)
            selection = nil
            annotations = previous
        }

        func redo() {
            guard let next = redoStack.popLast() else { NSSound.beep(); return }
            undoStack.append(annotations)
            selection = nil
            annotations = next
        }

        func select(_ index: Int?) {
            selection = index.flatMap { annotations.indices.contains($0) ? $0 : nil }
        }

        func deleteSelection() {
            guard let i = selection, annotations.indices.contains(i) else { return }
            var new = annotations
            new.remove(at: i)
            selection = nil
            commit(new)
        }

        /// Moves the selection by view points. Key repeats join the first press's undo step.
        func nudgeSelection(byViewPoints d: CGVector, repeating: Bool) {
            guard let i = selection, annotations.indices.contains(i) else { return }
            var new = annotations
            new[i].move(by: CGVector(dx: d.dx / scale, dy: d.dy / scale))
            if repeating && canUndo { annotations = new } else { commit(new) }
        }

        /// Colors the selected mark (if any) and becomes the color for new marks of the current tool.
        /// `continuous` changes (from the color panel, while dragging) join one undo step per mark.
        func setColor(_ new: RGBA, continuous: Bool = false) {
            if let i = selection, annotations.indices.contains(i) {
                var items = annotations
                items[i].color = new
                if continuous && colorEditIndex == i && canUndo {
                    annotations = items
                } else {
                    commit(items)
                    colorEditIndex = continuous ? i : nil
                }
                if items[i].kind == .highlight { highlightColor = new } else { color = new }
            } else if tool == .highlight {
                highlightColor = new
            } else {
                color = new
            }
            if let field = textField {
                field.textColor = new.nsColor
                textTemplate?.color = new
            }
            changed()
        }

        /// Sets line width and text size for new marks, and resizes the selected mark.
        func setSizeLevel(_ level: Int) {
            sizeLevel = min(3, max(0, level))
            if let i = selection, annotations.indices.contains(i) {
                var items = annotations
                switch items[i].kind {
                case .text: items[i].fontSize = textSize
                case .highlight where !items[i].isBox: items[i].width = strokeWidth * 4
                case .highlight: break
                default: items[i].width = strokeWidth
                }
                commit(items)
            }
            if textField != nil { textTemplate?.fontSize = textSize; layoutTextField() }
            changed()
        }

        @discardableResult func cancelDraft() -> Bool {
            guard draft != nil || dragBase != nil else { return false }
            if let base = dragBase { annotations = base }
            draft = nil
            dragBase = nil
            dragAnchor = nil
            activeHandle = nil
            needsDisplay = true
            return true
        }

        private func hitIndex(_ p: CGPoint, kinds: Set<Annotation.Kind>? = nil) -> Int? {
            let slop = 5 / scale
            // Outlines first, so a small mark inside a big hollow box can still be picked.
            for interior in [false, true] {
                for i in annotations.indices.reversed() where kinds?.contains(annotations[i].kind) ?? true {
                    if AnnotationRenderer.hit(annotations[i], at: p, slop: slop, interior: interior) { return i }
                }
            }
            return nil
        }

        /// Reshape handles of a mark: line and arrow ends, box corners (clockwise from top-left).
        private func handles(of a: Annotation) -> [CGPoint] {
            switch a.kind {
            case .line, .arrow: return Array(a.points.prefix(2))
            case .rect, .ellipse: break
            case .highlight where a.isBox: break
            default: return []
            }
            let r = a.box
            return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                    CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        }

        private func newMark(at p: CGPoint) -> Annotation? {
            switch tool {
            case .arrow: return Annotation(kind: .arrow, points: [p, p], color: color, width: strokeWidth)
            case .line: return Annotation(kind: .line, points: [p, p], color: color, width: strokeWidth)
            case .rect: return Annotation(kind: .rect, points: [p, p], color: color, width: strokeWidth)
            case .ellipse: return Annotation(kind: .ellipse, points: [p, p], color: color, width: strokeWidth)
            case .pen: return Annotation(kind: .pen, points: [p], color: color, width: strokeWidth)
            case .highlight:
                return Annotation(kind: .highlight, points: [p], color: highlightColor, width: strokeWidth * 4, opacity: 0.5)
            case .select, .text: return nil
            }
        }

        /// Snaps `p` so the segment from `anchor` runs at a multiple of 45°.
        private func snapped45(_ anchor: CGPoint, _ p: CGPoint) -> CGPoint {
            let dx = p.x - anchor.x, dy = p.y - anchor.y
            let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            let length = hypot(dx, dy)
            return CGPoint(x: anchor.x + cos(angle) * length, y: anchor.y + sin(angle) * length)
        }

        /// Makes the box from `anchor` to `p` square.
        private func squared(_ anchor: CGPoint, _ p: CGPoint) -> CGPoint {
            let side = max(abs(p.x - anchor.x), abs(p.y - anchor.y))
            return CGPoint(x: anchor.x + (p.x < anchor.x ? -side : side), y: anchor.y + (p.y < anchor.y ? -side : side))
        }

        // MARK: Mouse

        override func mouseDown(with event: NSEvent) {
            let wasEditing = textField != nil
            window?.makeFirstResponder(self)   // ends text editing, which commits the text
            if wasEditing { commitTextEdit(); return }
            guard image != nil else { return }
            let p = toImage(convert(event.locationInWindow, from: nil))
            switch tool {
            case .select:
                if let i = selection,
                   let h = handles(of: annotations[i]).firstIndex(where: { hypot($0.x - p.x, $0.y - p.y) * scale <= 7 }) {
                    activeHandle = h
                    dragBase = annotations
                    return
                }
                let hit = hitIndex(p)
                if event.clickCount == 2, let i = hit, annotations[i].kind == .text {
                    beginTextEdit(index: i)
                    return
                }
                selection = hit
                if hit != nil {
                    dragAnchor = p
                    dragBase = annotations
                }
            case .text:
                if let i = hitIndex(p, kinds: [.text]) { beginTextEdit(index: i) } else { beginTextEdit(at: clamped(p)) }
            default:
                selection = nil
                dragAnchor = clamped(p)
                draft = newMark(at: clamped(p))
            }
        }

        override func mouseDragged(with event: NSEvent) {
            let p = clamped(toImage(convert(event.locationInWindow, from: nil)))
            let shift = event.modifierFlags.contains(.shift)
            if let i = selection, let base = dragBase, let h = activeHandle {
                var a = base[i]
                switch a.kind {
                case .line, .arrow:
                    a.points[h] = shift ? snapped45(a.points[1 - h], p) : p
                default:
                    let opposite = handles(of: base[i])[(h + 2) % 4]
                    a.points = [opposite, shift ? squared(opposite, p) : p]
                }
                annotations[i] = a
            } else if let i = selection, let base = dragBase, let anchor = dragAnchor {
                var a = base[i]
                var d = CGVector(dx: p.x - anchor.x, dy: p.y - anchor.y)
                if shift { if abs(d.dx) > abs(d.dy) { d.dy = 0 } else { d.dx = 0 } }
                a.move(by: d)
                annotations[i] = a
            } else if var a = draft, let anchor = dragAnchor {
                switch a.kind {
                case .arrow, .line:
                    a.points[1] = shift ? snapped45(anchor, p) : p
                case .rect, .ellipse:
                    a.points[1] = shift ? squared(anchor, p) : p
                case .pen, .highlight:
                    if shift {
                        a.points = [anchor, snapped45(anchor, p)]
                    } else if let last = a.points.last, hypot(p.x - last.x, p.y - last.y) * scale >= 1.5 {
                        a.points.append(p)
                    }
                case .text:
                    break
                }
                draft = a
                needsDisplay = true
            }
        }

        override func mouseUp(with event: NSEvent) {
            if let base = dragBase {
                if annotations != base {
                    let moved = annotations
                    annotations = base
                    commit(moved)
                }
            } else if let a = draft, isMeaningful(a) {
                commit(annotations + [a])
            }
            draft = nil
            dragBase = nil
            dragAnchor = nil
            activeHandle = nil
            needsDisplay = true
        }

        /// Ignores clicks that didn't drag far enough to draw a line or a box.
        private func isMeaningful(_ a: Annotation) -> Bool {
            switch a.kind {
            case .arrow, .line:
                return hypot(a.points[1].x - a.points[0].x, a.points[1].y - a.points[0].y) * scale >= 4
            case .rect, .ellipse:
                return a.box.width * scale >= 3 && a.box.height * scale >= 3
            default:
                return true
            }
        }

        override func resetCursorRects() {
            let cursor: NSCursor
            switch tool {
            case .select: cursor = .arrow
            case .text: cursor = .iBeam
            default: cursor = .crosshair
            }
            addCursorRect(imageRect, cursor: cursor)
        }

        // MARK: Text

        /// Starts typing a new text mark whose top-left is at `p` (image pixels).
        func beginTextEdit(at p: CGPoint) {
            var template = Annotation(kind: .text, points: [p], color: color, width: 0)
            template.fontSize = textSize
            startTextField(template, index: nil)
        }

        /// Edits an existing text mark in place.
        func beginTextEdit(index: Int) {
            guard annotations.indices.contains(index), annotations[index].kind == .text else { return }
            selection = nil
            startTextField(annotations[index], index: index)
        }

        private func startTextField(_ template: Annotation, index: Int?) {
            commitTextEdit()
            let field = NSTextField(string: template.text)
            field.isBordered = false
            field.drawsBackground = false
            field.focusRingType = .none
            field.isEditable = true
            field.cell?.isScrollable = true
            field.cell?.wraps = false
            field.delegate = self
            field.placeholderString = "Text"
            textField = field
            textTemplate = template
            textEditIndex = index
            addSubview(field)
            layoutTextField()
            window?.makeFirstResponder(field)
            if let editor = field.currentEditor() as? NSTextView { editor.insertionPointColor = template.color.nsColor }
            needsDisplay = true
        }

        /// Matches the field's font, color and position to the mark it will become.
        private func layoutTextField() {
            guard let field = textField, var template = textTemplate else { return }
            template.text = field.stringValue.isEmpty ? "Text" : field.stringValue
            let font = AnnotationRenderer.font(for: template) as NSFont
            field.font = NSFont(descriptor: font.fontDescriptor, size: max(4, template.fontSize * scale)) ?? font
            field.textColor = template.color.nsColor
            let size = AnnotationRenderer.textLayout(template).size
            let origin = toView(template.points[0])
            // NSTextField insets its text by about 2 points; line the glyphs up with where they'll be drawn.
            field.frame = CGRect(x: origin.x - 2, y: origin.y, width: max(40, size.width * scale + 24),
                                 height: max(16, template.fontSize * scale * 1.35))
            needsDisplay = true
        }

        func controlTextDidChange(_ obj: Notification) { layoutTextField() }

        /// Return, Tab or a click elsewhere. Committed on the next turn of the run loop: the field is still
        /// finishing its edit while this notification is delivered.
        func controlTextDidEndEditing(_ obj: Notification) {
            DispatchQueue.main.async { [weak self] in self?.commitTextEdit() }
        }

        /// Turns the field's text into a mark (or updates or removes the one being edited).
        func commitTextEdit() {
            guard let field = textField, let template = textTemplate else { return }
            let text = field.stringValue
            endTextField()
            let isBlank = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if let i = textEditIndex, annotations.indices.contains(i) {
                var items = annotations
                if isBlank {
                    items.remove(at: i)
                } else {
                    items[i].text = text
                    items[i].color = template.color
                    items[i].fontSize = template.fontSize
                }
                commit(items)
            } else if !isBlank {
                var mark = template
                mark.text = text
                commit(annotations + [mark])
            }
            textEditIndex = nil
            textTemplate = nil
        }

        func cancelTextEdit() {
            guard textField != nil else { return }
            endTextField()
            textEditIndex = nil
            textTemplate = nil
            changed()
        }

        private func endTextField() {
            guard let field = textField else { return }
            textField = nil
            field.delegate = nil
            if window?.firstResponder === field.currentEditor() { window?.makeFirstResponder(self) }
            field.removeFromSuperview()
            needsDisplay = true
        }

        /// For tests: types into the open text field.
        func typeText(_ text: String) {
            textField?.stringValue = text
            layoutTextField()
        }

        override func layout() {
            super.layout()
            layoutTextField()
        }

        // MARK: Drawing

        override func draw(_ dirtyRect: NSRect) {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                Style.canvas.setFill()
                bounds.fill()
                guard let ctx = NSGraphicsContext.current?.cgContext, let image else { return }
                let r = imageRect
                ImageEditors.drawPicture(image, in: r, hasAlpha: hasAlpha, ctx: ctx)

                ctx.saveGState()
                ctx.clip(to: r)
                ctx.translateBy(x: r.minX, y: r.minY)
                ctx.scaleBy(x: scale, y: scale)
                for (i, mark) in annotations.enumerated() where !(textField != nil && i == textEditIndex) {
                    AnnotationRenderer.draw(mark, in: ctx)
                }
                if let draft { AnnotationRenderer.draw(draft, in: ctx) }
                ctx.restoreGState()

                if let i = selection, annotations.indices.contains(i) { drawSelection(annotations[i], ctx: ctx) }
                if let field = textField {
                    let box = field.frame.insetBy(dx: -4, dy: -3)
                    let path = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
                    path.lineWidth = 1
                    path.setLineDash([4, 3], count: 2, phase: 0)
                    NSColor.controlAccentColor.setStroke()
                    path.stroke()
                }
            }
        }

        /// The selected mark: a dashed outline and knobs in the app accent, as the Crop, Redact and video editors
        /// draw their selection (the knobs with the same soft shadow, so they read on any picture).
        private func drawSelection(_ mark: Annotation, ctx: CGContext) {
            let accent = FrameEditing.accent
            let box = toView(AnnotationRenderer.bounds(of: mark)).insetBy(dx: -5, dy: -5)
            let outline = NSBezierPath(rect: box.integral.insetBy(dx: 0.5, dy: 0.5))
            outline.lineWidth = 1
            outline.setLineDash([4, 3], count: 2, phase: 0)
            accent.setStroke()
            outline.stroke()
            for h in handles(of: mark) {
                let c = toView(h)
                let knob = NSBezierPath(ovalIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10))
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
                shadow.shadowBlurRadius = 2
                shadow.shadowOffset = CGSize(width: 0, height: -0.5)
                shadow.set()
                NSColor.white.setFill()
                knob.fill()
                NSGraphicsContext.restoreGraphicsState()
                knob.lineWidth = 1.5
                accent.setStroke()
                knob.stroke()
            }
        }
    }
}
