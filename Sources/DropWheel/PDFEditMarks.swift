import AppKit

/// Highlights and pictures (images, stamps, signatures) on the Edit PDF canvas: placing, hit-testing, moving,
/// resizing and drawing their selection. The marks themselves are drawn by the candidate PDF.
extension PDFEditCanvas {
    static let highlightColors: [(name: String, rgb: (Double, Double, Double))] = [
        ("Yellow", (1, 0.86, 0.2)), ("Green", (0.55, 0.9, 0.45)), ("Blue", (0.5, 0.78, 1)), ("Pink", (1, 0.6, 0.8)),
    ]

    /// A page-space rectangle as a view rectangle.
    func viewRect(_ r: CGRect) -> CGRect {
        Self.bounds([CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)].map(viewPoint))
    }

    /// A view rectangle as a page-space rectangle.
    func pageRect(_ v: CGRect) -> CGRect {
        let a = pagePoint(CGPoint(x: v.minX, y: v.minY)), b = pagePoint(CGPoint(x: v.maxX, y: v.maxY))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// The mark under a view point: pictures in every mode, highlights only while highlighting (elsewhere a click on
    /// highlighted text edits the text).
    func mark(at p: CGPoint) -> PDFMark? {
        for m in marksOnPage.reversed() {
            switch m.kind {
            case .image(_, let r):
                if viewRect(r).insetBy(dx: -3, dy: -3).contains(p) { return m }
            case .highlight(let rs, _, _, _):
                if mode == .highlight, rs.contains(where: { viewRect($0).insetBy(dx: -1, dy: -1).contains(p) }) { return m }
            }
        }
        return nil
    }

    /// The resize handle of a selected picture: its bottom-right corner as shown.
    func resizeHandle(_ r: CGRect) -> CGRect {
        let v = viewRect(r)
        return CGRect(x: v.maxX - 7, y: v.maxY - 7, width: 14, height: 14)
    }

    // MARK: Highlighting by dragging

    /// Like selecting text: from the press to the release, across the lines between. Off text it's the dragged box.
    func highlightRects(from a: CGPoint, to b: CGPoint) -> [CGRect] {
        let (p1, p2) = a.y <= b.y ? (a, b) : (b, a)
        var hits: [CGRect] = []
        for l in lines() {
            let id = PDFLineID(page: page, line: l.index)
            let vb = viewBounds(.line(id))
            guard !vb.isNull, vb.width > 0 else { continue }
            let touchesTop = p1.y >= vb.minY && p1.y <= vb.maxY, touchesBottom = p2.y >= vb.minY && p2.y <= vb.maxY
            let between = vb.midY > p1.y && vb.midY < p2.y
            guard touchesTop || touchesBottom || between else { continue }
            var x0 = vb.minX, x1 = vb.maxX
            if touchesTop && touchesBottom { x0 = max(vb.minX, min(a.x, b.x)); x1 = min(vb.maxX, max(a.x, b.x)) }
            else if touchesTop { x0 = max(vb.minX, p1.x) }
            else if touchesBottom { x1 = min(vb.maxX, p2.x) }
            guard x1 - x0 > 1 else { continue }
            hits.append(CGRect(x: x0, y: vb.minY, width: x1 - x0, height: vb.height))
        }
        if hits.isEmpty {
            let box = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)).intersection(pageFrame)
            if box.width > 4 && box.height > 4 { hits = [box] }
        }
        return hits
    }

    // MARK: Placing pictures

    /// Puts a picture in the middle of what's visible of the page, `width` points wide (smaller if the page is),
    /// and selects it so it can be moved and resized at once.
    @discardableResult
    func placePicture(png: Data, pixelSize: CGSize, width: CGFloat) -> UUID? {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return nil }
        let visible = visibleRect.intersection(pageFrame)
        let centre = visible.isNull ? CGPoint(x: pageFrame.midX, y: pageFrame.midY) : CGPoint(x: visible.midX, y: visible.midY)
        let w = min(width, uprightSize.width * 0.8) * zoom
        let h = w * pixelSize.height / pixelSize.width
        let rect = pageRect(CGRect(x: centre.x - w / 2, y: centre.y - h / 2, width: w, height: h))
        var id: UUID?
        _ = delegate?.canvas(self, perform: "Couldn’t add the picture") { id = try session.addMark(.image(png: png, rect: rect), page: page) }
        if let id { selectMark(id) }
        return id
    }

    func selectMark(_ id: UUID?) {
        if id != nil, selection != nil { select(nil) }
        guard id != selectedMark else { return }
        selectedMark = id
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        delegate?.canvasSelectionChanged(self)
    }

    var selectedMarkInfo: PDFMark? { selectedMark.flatMap { id in session.marks.first { $0.id == id } } }

    func removeSelectedMark() {
        guard let id = selectedMark else { return }
        _ = delegate?.canvas(self, perform: "Couldn’t remove it") { session.removeMark(id) }
        selectMark(nil)
    }

    func setHighlightColor(_ rgb: (Double, Double, Double)) {
        highlightColor = rgb
        guard let m = selectedMarkInfo, case .highlight(let rs, _, _, _) = m.kind else { delegate?.canvasSelectionChanged(self); return }
        _ = delegate?.canvas(self, perform: "Couldn’t change the colour") {
            try session.updateMark(m.id, .highlight(rects: rs, red: rgb.0, green: rgb.1, blue: rgb.2), actionName: "Highlight Colour")
        }
    }

    // MARK: Mouse

    /// A press on a mark or, while highlighting, anywhere on the page. True when it was handled here.
    func markMouseDown(at p: CGPoint) -> Bool {
        if let m = mark(at: p) {
            selectMark(m.id)
            if case .image(_, let r) = m.kind {
                markDrag = MarkDrag(id: m.id, start: p, original: r, resize: resizeHandle(r).insetBy(dx: -4, dy: -4).contains(p))
            }
            return true
        }
        if mode == .highlight {
            selectMark(nil)
            select(nil)
            if pageFrame.contains(p) { highlightDrag = (p, p) }
            return true
        }
        if selectedMark != nil { selectMark(nil) }
        return false
    }

    func markMouseDragged(to p: CGPoint) -> Bool {
        if var d = markDrag {
            d.offset = CGVector(dx: p.x - d.start.x, dy: p.y - d.start.y)
            if !d.moved && hypot(d.offset.dx, d.offset.dy) < 3 { return true }
            d.moved = true
            markDrag = d
            needsDisplay = true
            return true
        }
        if let h = highlightDrag {
            highlightDrag = (h.start, p)
            needsDisplay = true
            return true
        }
        return false
    }

    func markMouseUp(at p: CGPoint) -> Bool {
        if let d = markDrag {
            markDrag = nil
            if d.moved, let r = draggedRect(d), let m = session.marks.first(where: { $0.id == d.id }), case .image(let png, _) = m.kind {
                _ = delegate?.canvas(self, perform: "Couldn’t move the picture") {
                    try session.updateMark(d.id, .image(png: png, rect: r), actionName: d.resize ? "Resize Picture" : "Move Picture")
                }
            }
            needsDisplay = true
            return true
        }
        if let h = highlightDrag {
            highlightDrag = nil
            let rects = highlightRects(from: h.start, to: p).map(pageRect)
            if !rects.isEmpty {
                let c = highlightColor
                var id: UUID?
                _ = delegate?.canvas(self, perform: "Couldn’t highlight") {
                    id = try session.addMark(.highlight(rects: rects, red: c.0, green: c.1, blue: c.2), page: page)
                }
                if let id { selectMark(id) }
            }
            needsDisplay = true
            return true
        }
        return false
    }

    /// Where a picture being moved or resized is now, page space (resizing keeps its proportions).
    func draggedRect(_ d: MarkDrag) -> CGRect? {
        let v = viewRect(d.original)
        if d.resize {
            let w = max(16, v.width + d.offset.dx)
            return pageRect(CGRect(x: v.minX, y: v.minY, width: w, height: w * v.height / max(1, v.width)))
        }
        return pageRect(v.offsetBy(dx: d.offset.dx, dy: d.offset.dy))
    }

    // MARK: Drawing

    func drawMarkOverlays() {
        // The highlight being dragged.
        if let h = highlightDrag {
            let c = highlightColor
            NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 0.45).setFill()
            for r in highlightRects(from: h.start, to: h.end) { r.fill(using: .multiply) }
        }
        // The picture being moved or resized: its outline where it will land.
        if let d = markDrag, d.moved, let r = draggedRect(d) {
            let p = NSBezierPath(rect: viewRect(r))
            p.lineWidth = 1.5
            p.setLineDash([4, 3], count: 2, phase: 0)
            PDFEditPaint.accent.setStroke()
            p.stroke()
        }
        // The selected mark.
        guard let m = selectedMarkInfo, m.page == page, markDrag?.moved != true else { return }
        switch m.kind {
        case .image(_, let r):
            let v = viewRect(r).insetBy(dx: -1, dy: -1)
            let p = NSBezierPath(rect: v)
            p.lineWidth = 1.5
            PDFEditPaint.accent.setStroke()
            p.stroke()
            let handle = NSBezierPath(ovalIn: resizeHandle(r).insetBy(dx: 2, dy: 2))
            NSColor.white.setFill()
            handle.fill()
            handle.lineWidth = 1.5
            handle.stroke()
        case .highlight(let rs, _, _, _):
            for r in rs {
                let p = NSBezierPath(roundedRect: viewRect(r).insetBy(dx: -1.5, dy: -1.5), xRadius: 2, yRadius: 2)
                p.lineWidth = 1.5
                PDFEditPaint.accent.setStroke()
                p.stroke()
            }
        }
    }

    func addMarkCursorRects() {
        for m in marksOnPage {
            guard case .image(_, let r) = m.kind else { continue }
            addCursorRect(viewRect(r).intersection(visibleRect), cursor: .openHand)
            if m.id == selectedMark { addCursorRect(resizeHandle(r).intersection(visibleRect), cursor: .crosshair) }
        }
    }

    struct MarkDrag {
        let id: UUID
        let start: CGPoint
        let original: CGRect
        let resize: Bool
        var offset: CGVector = .zero
        var moved = false
    }
}

// MARK: - Pictures from files and signatures

enum PDFEditPicture {
    /// A picture file as PNG data, at most 2000 pixels on its longest side, with its pixel size.
    static func load(_ url: URL) -> (png: Data, size: CGSize)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2000,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return (png, CGSize(width: cg.width, height: cg.height))
    }

    static let signatureKey = "PDFEditSignaturePNG"

    /// The signature drawn last time (kept on this Mac only).
    static var savedSignature: (png: Data, size: CGSize)? {
        guard let d = Settings.defaults.data(forKey: signatureKey), let rep = NSBitmapImageRep(data: d) else { return nil }
        return (d, CGSize(width: rep.pixelsWide, height: rep.pixelsHigh))
    }

    static func saveSignature(_ png: Data?) { Settings.defaults.set(png, forKey: signatureKey) }
}

/// Draw a signature with the trackpad or mouse: strokes in ink, Clear, Cancel, Use Signature.
final class PDFSignaturePadView: NSView {
    private(set) var strokes: [[CGPoint]] = []
    var onChange: (() -> Void)?
    var inkColor = NSColor(srgbRed: 0.05, green: 0.1, blue: 0.3, alpha: 1)

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseDown(with event: NSEvent) {
        strokes.append([convert(event.locationInWindow, from: nil)])
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !strokes.isEmpty else { return }
        strokes[strokes.count - 1].append(convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) { onChange?() }

    func clear() { strokes = []; needsDisplay = true; onChange?() }

    /// A stroke as if drawn (self-tests and snapshots).
    func add(stroke: [CGPoint]) { strokes.append(stroke); needsDisplay = true; onChange?() }

    static func path(_ s: [CGPoint]) -> NSBezierPath {
        let p = NSBezierPath()
        p.lineWidth = 2.6
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        guard let first = s.first else { return p }
        p.move(to: first)
        if s.count == 1 { p.line(to: CGPoint(x: first.x + 0.1, y: first.y)); return p }
        // Smoothed through the midpoints, so a quick stroke doesn't look jagged.
        for i in 1..<s.count {
            let mid = CGPoint(x: (s[i - 1].x + s[i].x) / 2, y: (s[i - 1].y + s[i].y) / 2)
            p.curve(to: mid, controlPoint1: s[i - 1], controlPoint2: s[i - 1])
        }
        p.line(to: s[s.count - 1])
        return p
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        // The signing line.
        let base = NSBezierPath()
        base.move(to: CGPoint(x: 24, y: bounds.height - 44))
        base.line(to: CGPoint(x: bounds.width - 24, y: bounds.height - 44))
        base.lineWidth = 1
        NSColor(white: 0.82, alpha: 1).setStroke()
        base.stroke()
        if strokes.isEmpty {
            let hint = "Sign here with your trackpad or mouse" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor(white: 0.55, alpha: 1)]
            let sz = hint.size(withAttributes: attrs)
            hint.draw(at: CGPoint(x: (bounds.width - sz.width) / 2, y: bounds.height - 44 - sz.height - 10), withAttributes: attrs)
        }
        inkColor.setStroke()
        for s in strokes { Self.path(s).stroke() }
    }

    /// The ink as a transparent PNG, cropped to the strokes, at 4× for print.
    func renderPNG() -> (png: Data, size: CGSize)? {
        let pts = strokes.flatMap { $0 }
        guard pts.count > 1 else { return nil }
        let pad: CGFloat = 4
        var box = PDFEditGeometry.bounds(pts).insetBy(dx: -pad, dy: -pad)
        box.size.width = max(box.width, 20); box.size.height = max(box.height, 10)
        let scale: CGFloat = 4
        let w = Int(box.width * scale), h = Int(box.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.cgContext.clear(CGRect(x: 0, y: 0, width: w, height: h))
        // Flip: the pad is top-down, the bitmap bottom-up.
        let t = NSAffineTransform()
        t.translateX(by: 0, yBy: CGFloat(h))
        t.scaleX(by: scale, yBy: -scale)
        t.translateX(by: -box.minX, yBy: -box.minY)
        t.concat()
        inkColor.setStroke()
        for s in strokes { Self.path(s).stroke() }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return (png, CGSize(width: w, height: h))
    }
}

/// The sheet that holds the signature pad.
final class PDFSignatureSheet: NSWindowController {
    let pad = PDFSignaturePadView(frame: CGRect(x: 0, y: 0, width: 520, height: 200))
    private let useButton = NSButton(title: "Use Signature", target: nil, action: nil)
    private var done: ((PDFSignaturePadView?) -> Void)?

    convenience init(done: @escaping (PDFSignaturePadView?) -> Void) {
        let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 560, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        self.init(window: w)
        self.done = done
        let title = NSTextField(labelWithString: "Draw your signature")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let note = NSTextField(labelWithString: "It’s kept on this Mac for next time.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        pad.wantsLayer = true
        pad.layer?.cornerRadius = 6
        pad.layer?.borderWidth = 1
        pad.layer?.borderColor = NSColor.separatorColor.cgColor
        pad.setAccessibilityLabel("Signature pad")
        let clear = NSButton(title: "Clear", target: self, action: #selector(clear(_:)))
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        useButton.target = self
        useButton.action = #selector(use(_:))
        useButton.keyEquivalent = "\r"
        useButton.isEnabled = false
        pad.onChange = { [weak self] in self?.useButton.isEnabled = !(self?.pad.strokes.isEmpty ?? true) }
        let buttons = NSStackView(views: [clear, NSView(), cancel, useButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let stack = NSStackView(views: [title, pad, note, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        w.contentView = NSView()
        w.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: w.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: w.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: w.contentView!.topAnchor),
            stack.bottomAnchor.constraint(equalTo: w.contentView!.bottomAnchor),
            pad.widthAnchor.constraint(equalToConstant: 520), pad.heightAnchor.constraint(equalToConstant: 200),
            buttons.widthAnchor.constraint(equalToConstant: 520),
        ])
    }

    @objc private func clear(_ sender: Any?) { pad.clear() }
    @objc private func cancel(_ sender: Any?) { finish(nil) }
    @objc private func use(_ sender: Any?) { finish(pad) }

    private func finish(_ result: PDFSignaturePadView?) {
        guard let w = window else { return }
        w.sheetParent?.endSheet(w)
        done?(result)
        done = nil
    }
}
