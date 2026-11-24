import AppKit
import QuartzCore

/// What the view asks of whoever runs the line (the live controller; nothing in snapshots).
protocol ClotheslineViewHost: AnyObject {
    /// Input changed the engine: run the clock, redraw.
    func clotheslineNeedsUpdate()
    /// Scene point of the pointer now.
    func clotheslineScroll(_ input: ClotheslineScrollInput)
    /// Files dragged over the view (scene point): the operation the line answers, or none.
    func clotheslineDragUpdated(at p: CGPoint, files: [URL], sourceMask: NSDragOperation) -> NSDragOperation
    /// The drag left the view (scene point, when known).
    func clotheslineDragExited(at p: CGPoint?)
    /// The files were let go over the view: whether the line took them.
    func clotheslineDrop(_ files: [URL], at p: CGPoint) -> Bool
    /// Files an app promises to write (Photos, Mail, Safari) were let go over the view: whether the line takes them.
    func clotheslineDropPromises(_ receivers: [NSFilePromiseReceiver], at p: CGPoint) -> Bool
    /// The drag session ended.
    func clotheslineDragEnded()
    /// A card's own drag session ended (its mouse-up never reaches the event monitors).
    func clotheslineOwnDragEnded()
    /// A press on a card began (the button and Esc are watched while it lasts).
    func clotheslineCardPressed()
    /// The card in the hand moved with the pointer (scene point).
    func clotheslineCardMoved(to p: CGPoint)
    /// The card in the hand was let go (scene point).
    func clotheslineCardReleased(at p: CGPoint)
    /// The line's own card, in its drag session, over the view (scene point): the operation the line answers, or none.
    func clotheslineCardDragUpdated(at p: CGPoint) -> NSDragOperation
    /// The card's drag session was let go over the view: whether the line hung it there.
    func clotheslineCardDropped(at p: CGPoint) -> Bool
    /// The card's drag session ended (dropped anywhere or cancelled).
    func clotheslineCardDragEnded()
}

/// The line and its cards, drawn with Core Animation layers that the engine's poses move every frame. It owns the
/// card pictures (thumbnails, durations), the mouse (hover, a click to select a card, double-click to open, press and
/// drag a card along the string, drag it down off the line to take its file, right-click menu, horizontal scrolling),
/// the keys while a card is selected (Delete, the arrows, Esc, ⌘Z), files dropped on the line (registered for file
/// drags only while some are over it) and the accessibility tree. Works without a window for offscreen rendering.
final class ClotheslineView: NSView, NSDraggingSource {
    let engine: ClotheslineEngine
    weak var host: ClotheslineViewHost?
    /// Pixels per point of the card pictures.
    var pictureScale: CGFloat = 2
    /// Forced appearance (snapshots); nil follows the view's effective appearance.
    var forcedDark: Bool? { didSet { appearanceChanged() } }
    /// Increase Contrast: solid card edges and an opaque string.
    var increaseContrast = false { didSet { if increaseContrast != oldValue { appearanceChanged() } } }
    /// The last VoiceOver announcement (tests).
    private(set) var lastAnnouncement: String?

    private let root = CALayer()
    /// A thin contrasting edge under the string (Increase Contrast only).
    private let halo = CAShapeLayer()
    /// The string is a strand of light: a gradient seen through the string's path (the core) …
    private let core = CAGradientLayer()
    private let string = CAShapeLayer()
    /// … over a soft glow: the same gradient seen through a wider copy of the path over its blur (`glowStroke`, and
    /// `glowBlur` under it).
    private let glow = CAGradientLayer()
    private let glowMask = CALayer()
    private let glowStroke = CAShapeLayer()
    private let glowBlur = CALayer()
    /// What the glow's blur was last drawn for: the view is rendered for every pointer event as well as every frame,
    /// and the string only moves once a frame.
    private var glowBlurKey: (path: CGPath, width: CGFloat, radius: CGFloat)?
    private let tacks = [CAShapeLayer(), CAShapeLayer()]
    /// The string's light layers (the performance self-test hides them one at a time).
    var stringLayers: (glow: CALayer, core: CALayer) { (glow, core) }
    /// Holds the cards, clipped at the menu bar's lower edge: cards come out from under the menu bar and go back
    /// behind it; only the string's path into the notch crosses the menu bar.
    let cardsLayer = CALayer()
    /// Where dragged files will hang: the card to be, translucent, with an open clothespin. Above the cards: while
    /// the gap moves it glides past the card that changes sides, and it must never be hidden behind it.
    let ghostLayer = CALayer()
    private var ghostKey: String?
    /// The cards' layers (a shadow and a card per file), without the ghost (tests).
    var cardLayerCount: Int { (cardsLayer.sublayers ?? []).filter { $0 !== ghostLayer }.count }
    private var cardLayers: [UUID: (shadow: CALayer, card: CALayer)] = [:]
    private var pictures: [UUID: (content: ClotheslineArt.CardContent, width: CGFloat, dark: Bool, url: URL)] = [:]
    private var thumbnails: [String: ShelfThumbnail] = [:]
    /// The press on a card and what it became: still a click, a card moved along the string, a card whose file a drag
    /// session carries (the session has the mouse then), or a move given up (Esc, or its file was gone).
    private enum Press { case none, card(UUID, at: CGPoint), moving(UUID), out(UUID), over }
    private var press: Press = .none
    private var accessibilityCards: [ClotheslineCardElement] = []
    /// A press that moves this far (points) is a drag; less is a click.
    static let dragThreshold: CGFloat = 3
    /// Opens a card's file (live: the file's app; self-tests swap it).
    var openFile: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// The selection ring (a focus ring in YummyOrange's accent), worn by the selected card's layer: it swings, scales and
    /// fades with the card. Under it a thin edge in the contrasting colour (Increase Contrast only).
    let selectionRing = CALayer()
    private let ringHalo = CAShapeLayer()
    private let ringStroke = CAShapeLayer()
    private var ringKey: String?
    /// The ring's width and its gap from the card's edge (points).
    static let ringWidth: CGFloat = 3, ringGap: CGFloat = 2.5
    /// The card just taken off with Delete, and where it hung: ⌘Z right after puts it back.
    private var lastRemoval: (item: ClotheslineItem, index: Int, welcome: Bool)?

    static let thumbnailRequest: CGFloat = 180

    init(engine: ClotheslineEngine, frame: CGRect) {
        self.engine = engine
        super.init(frame: frame)
        root.frame = bounds
        root.masksToBounds = false
        layer = root
        wantsLayer = true
        layerContentsRedrawPolicy = .never

        halo.fillColor = nil
        halo.lineCap = .round
        halo.lineWidth = 3.6
        // Masks: only their alpha counts, so they are drawn in opaque black. The glow's mask is a wider stroke over its
        // own blur, which fades out about 15 pt from the string (`Self.glowBlurImage`).
        string.fillColor = nil
        string.lineCap = .round
        string.lineWidth = 1.6
        string.strokeColor = NSColor.black.cgColor
        glowStroke.fillColor = nil
        glowStroke.lineCap = .round
        glowStroke.lineJoin = .round
        glowStroke.lineWidth = 4.5
        glowStroke.strokeColor = NSColor.black.cgColor
        glowBlur.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
        glowMask.addSublayer(glowBlur)
        glowMask.addSublayer(glowStroke)
        for g in [glow, core] {
            g.startPoint = CGPoint(x: 0, y: 0.5)
            g.endPoint = CGPoint(x: 1, y: 0.5)
            g.locations = [0, 0.5, 1]
            g.actions = ["colors": NSNull(), "startPoint": NSNull(), "endPoint": NSNull(), "opacity": NSNull(),
                         "bounds": NSNull(), "position": NSNull()]
        }
        glow.mask = glowMask
        core.mask = string
        root.addSublayer(halo)
        root.addSublayer(glow)
        root.addSublayer(core)
        layoutString()
        cardsLayer.masksToBounds = true
        cardsLayer.actions = ["bounds": NSNull(), "position": NSNull()]
        root.addSublayer(cardsLayer)
        ghostLayer.contentsScale = pictureScale
        ghostLayer.isHidden = true
        ghostLayer.actions = ["position": NSNull(), "transform": NSNull(), "opacity": NSNull(), "contents": NSNull(),
                              "bounds": NSNull(), "anchorPoint": NSNull(), "hidden": NSNull()]
        cardsLayer.addSublayer(ghostLayer)
        for t in tacks {
            t.path = CGPath(ellipseIn: CGRect(x: -3.2, y: -3.2, width: 6.4, height: 6.4), transform: nil)
            t.strokeColor = NSColor(white: 1, alpha: 0.85).cgColor
            t.lineWidth = 0.8
            t.shadowColor = NSColor.black.cgColor
            t.shadowOpacity = 0.3
            t.shadowRadius = 1
            t.shadowOffset = CGSize(width: 0, height: -0.8)
            root.addSublayer(t)
        }
        for l in [ringHalo, ringStroke] {
            l.fillColor = nil
            l.actions = ["path": NSNull(), "strokeColor": NSNull(), "lineWidth": NSNull(), "position": NSNull(), "bounds": NSNull()]
            selectionRing.addSublayer(l)
        }
        selectionRing.actions = ["position": NSNull(), "bounds": NSNull(), "sublayers": NSNull(), "onOrderIn": NSNull(), "onOrderOut": NSNull()]
        engine.widthFor = { [weak self] url in self?.width(for: url) ?? ClotheslineCardMetrics.iconMatWidth }
        engine.pictureReady = { [weak self] url in self?.hasPicture(url) ?? true }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        updateAccessibility()
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    /// The keys go to the line only while a card is selected (the panel has the keyboard then).
    override var acceptsFirstResponder: Bool { engine.selectedCard != nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        root.frame = bounds
        layoutString()
    }

    /// The light layers and their masks cover the whole view; the path does the rest.
    private func layoutString() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [glow, core, string, glowMask, glowStroke] as [CALayer] { l.frame = CGRect(origin: .zero, size: bounds.size) }
        CATransaction.commit()
    }

    var isDark: Bool {
        forcedDark ?? (effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        appearanceChanged()
    }

    private func appearanceChanged() {
        applyColors()
        for id in Array(pictures.keys) { refreshPicture(id) }
    }

    var palette: ClotheslineArt.Palette { .current(dark: isDark, contrast: increaseContrast) }

    private func applyColors() {
        let p = palette
        core.colors = p.stringColors.map(\.cgColor)
        glow.colors = p.glowColors.map(\.cgColor)
        halo.strokeColor = p.stringHalo.cgColor
        // Without Increase Contrast the halo is clear: not drawn at all.
        halo.isHidden = p.stringHalo.alphaComponent == 0
        string.lineWidth = increaseContrast ? 2.2 : 1.8
        halo.lineWidth = increaseContrast ? 4.6 : 3.6
        // The tacks at the two ends wear the light's end colours.
        tacks.first?.fillColor = p.stringColors.first?.cgColor
        tacks.last?.fillColor = p.stringColors.last?.cgColor
    }

    // MARK: Pictures

    /// The card width for a file: from its thumbnail's aspect once known, a document card until then.
    func width(for url: URL) -> CGFloat {
        guard let t = thumbnails[url.path] ?? ClotheslinePictures.cached(url, size: Self.thumbnailRequest) else {
            return ClotheslineCardMetrics.iconMatWidth
        }
        return t.isIcon ? ClotheslineCardMetrics.iconMatWidth
            : ClotheslineCardMetrics.matWidth(aspect: t.image.size.width / max(t.image.size.height, 1))
    }

    /// Whether a file's thumbnail is ready (a card waits a moment for it before dropping, so it doesn't change
    /// picture and width mid-swing).
    func hasPicture(_ url: URL) -> Bool {
        thumbnails[url.path] != nil || ClotheslinePictures.cached(url, size: Self.thumbnailRequest) != nil
    }

    /// Cards for new files; pictures for cards without one; layers for cards that left; names of renamed files.
    func itemsChanged() {
        pruneLayers()
        for item in engine.items {
            if let p = pictures[item.id], p.url != item.url {
                // Renamed or moved: new name, and its picture from the new path.
                pictures[item.id]?.url = item.url
                pictures[item.id]?.content.name = item.name
                refreshPicture(item.id)
                let url = item.url
                ClotheslinePictures.load(url, size: Self.thumbnailRequest) { [weak self] t in self?.thumbnailArrived(t, url: url) }
            }
        }
        if let focus = engine.accessibilityFocus, !engine.items.contains(where: { $0.id == focus }) { engine.accessibilityFocus = nil }
        for item in engine.items where cardLayers[item.id] == nil {
            let shadow = CALayer()
            shadow.shadowColor = NSColor.black.cgColor
            shadow.actions = ["position": NSNull(), "transform": NSNull(), "opacity": NSNull(), "shadowPath": NSNull(),
                              "shadowOpacity": NSNull(), "shadowRadius": NSNull()]
            let card = CALayer()
            card.contentsScale = pictureScale
            card.actions = ["position": NSNull(), "transform": NSNull(), "opacity": NSNull(), "contents": NSNull(),
                            "bounds": NSNull(), "anchorPoint": NSNull()]
            cardsLayer.addSublayer(shadow)
            cardsLayer.addSublayer(card)
            cardLayers[item.id] = (shadow, card)
            let url = item.url, id = item.id
            pictures[id] = (ClotheslineArt.CardContent(name: item.name, thumbnail: nil, isIcon: true,
                                                        duration: ClotheslineArt.cachedDuration(url)),
                            engine.cards[id]?.width ?? ClotheslineCardMetrics.iconMatWidth, isDark, url)
            if let t = thumbnails[url.path] ?? ClotheslinePictures.cached(url, size: Self.thumbnailRequest) {
                thumbnailArrived(t, url: url)
            } else {
                // No placeholder yet: the picture usually arrives before the card shows (it waits for it), and a card
                // that shows first gets its placeholder then (`ensurePicture`). Drawing one for every new card made the
                // frame a batch of files was hung in the slowest of all.
                ClotheslinePictures.load(url, size: Self.thumbnailRequest) { [weak self] t in self?.thumbnailArrived(t, url: url) }
            }
            if ClotheslineArt.isVideo(url) && ClotheslineArt.cachedDuration(url) == nil {
                ClotheslineArt.loadDuration(url) { [weak self] seconds in
                    guard let self, let seconds else { return }
                    for item in self.engine.items where item.url == url {
                        self.pictures[item.id]?.content.duration = seconds
                        self.refreshPicture(item.id)
                    }
                    self.host?.clotheslineNeedsUpdate()
                }
            }
        }
        // Stacking: draw order (leaving cards under the rest, newest on top), then the ghost over them all.
        for id in engine.drawOrder {
            guard let l = cardLayers[id] else { continue }
            cardsLayer.addSublayer(l.shadow)
            cardsLayer.addSublayer(l.card)
        }
        cardsLayer.addSublayer(ghostLayer)
        // Pictures of files no longer on the line are let go.
        let paths = Set(engine.items.map(\.url.path))
        thumbnails = thumbnails.filter { paths.contains($0.key) }
        updateAccessibility()
        render()
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    /// Removes the layers of cards the engine no longer has (a removed card that finished lifting away).
    private func pruneLayers() {
        let ids = Set(engine.cards.keys)
        for (id, layers) in cardLayers where !ids.contains(id) {
            layers.shadow.removeFromSuperlayer()
            layers.card.removeFromSuperlayer()
            cardLayers[id] = nil
            pictures[id] = nil
        }
    }

    func thumbnailArrived(_ t: ShelfThumbnail, url: URL) {
        thumbnails[url.path] = t
        for item in engine.items where item.url == url {
            // A card already showing its placeholder cross-fades to the picture (it waited as long as it could).
            let showing = (engine.pose(item.id)?.alpha ?? 0) > 0.01
            pictures[item.id]?.content.thumbnail = t.image
            pictures[item.id]?.content.isIcon = t.isIcon
            engine.setWidth(width(for: url), for: item.id)
            engine.pictureArrived(for: item.id)
            refreshPicture(item.id, crossFade: showing)
        }
        host?.clotheslineNeedsUpdate()
    }

    /// Cards whose picture was swapped with a cross-fade (tests).
    private(set) var crossFades = 0

    /// A card about to be seen has a picture: its placeholder (a document card with its name) until its own arrives.
    func ensurePicture(_ id: UUID) {
        guard let l = cardLayers[id], l.card.contents == nil else { return }
        refreshPicture(id)
    }

    private func refreshPicture(_ id: UUID, crossFade: Bool = false) {
        guard var p = pictures[id], let layers = cardLayers[id] else { return }
        p.width = engine.cards[id]?.width ?? p.width
        p.dark = isDark
        pictures[id] = p
        let rect = ClotheslineArt.imageRect(width: p.width)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if crossFade {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.15
            layers.card.add(fade, forKey: "picture")
            crossFades += 1
        }
        layers.card.contents = ClotheslineArt.cardImage(p.content, width: p.width, dark: p.dark, contrast: increaseContrast,
                                                        scale: pictureScale)
        layers.card.bounds = CGRect(origin: .zero, size: rect.size)
        // The pivot is the layer's anchor: x from the left, y from the bottom (layers are y-up).
        layers.card.anchorPoint = CGPoint(x: -rect.minX / rect.width, y: rect.maxY / rect.height)
        let mat = ClotheslineCardMetrics.matRect(width: p.width)
        // The shadow layer's own frame is the mat in y-up coordinates around the pivot.
        layers.shadow.bounds = CGRect(x: 0, y: 0, width: mat.width, height: mat.height)
        layers.shadow.anchorPoint = CGPoint(x: 0.5, y: mat.maxY / mat.height)
        layers.shadow.shadowPath = CGPath(roundedRect: layers.shadow.bounds, cornerWidth: ClotheslineCardMetrics.radius,
                                          cornerHeight: ClotheslineCardMetrics.radius, transform: nil)
        CATransaction.commit()
    }

    // MARK: Rendering

    /// Scene y (down) to layer y (up).
    private func ly(_ y: Double) -> CGFloat { bounds.height - CGFloat(y) }

    /// Pixels per point of the glow's blur (`glowBlurImage`).
    static let glowBlurScale: CGFloat = 0.25

    /// The glow's blur: what a shadow of `radius` would be under a stroke of the string's path `lineWidth` wide (alpha
    /// only, without the stroke), and where it goes in the view. It used to be that shadow, on the glow's mask: Core
    /// Animation renders it offscreen and blurs it on the GPU every frame the string moves, which made the glow the
    /// costliest part of the line's render (`--selftest clothesline-perf` with DW_PERF_PARTS=1 measures each part).
    /// Drawn here once a frame at a quarter of a point's resolution (about 440 × 25 pixels, well under 0.1 ms) and
    /// magnified, a blur this soft can't be told apart from it (within 7/255 on screen, 11/255 at its brightest).
    static func glowBlurImage(_ path: CGPath, lineWidth: CGFloat, radius: CGFloat) -> (image: CGImage, frame: CGRect)? {
        let reach = 3 * radius + lineWidth / 2
        let box = path.boundingBoxOfPath.insetBy(dx: -reach, dy: -reach).integral
        let s = glowBlurScale
        let w = Int((box.width * s).rounded(.up)), h = Int((box.height * s).rounded(.up))
        guard w > 0, h > 0, box.width.isFinite,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
        else { return nil }
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        // The blur alone: the stroke is drawn off to the side and casts its shadow back here (shadow offsets are in
        // pixels; Core Graphics' blur is twice Core Animation's shadow radius).
        let away = box.width + 4 * reach
        ctx.translateBy(x: away, y: 0)
        ctx.setShadow(offset: CGSize(width: -away * s, height: 0), blur: 2 * radius * s, color: CGColor(gray: 0, alpha: 1))
        ctx.addPath(path)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
        ctx.strokePath()
        return ctx.makeImage().map { ($0, box) }
    }

    /// Moves every layer to the engine's current poses.
    func render() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let clipTop = max(0, engine.geometry.menuBarHeight)
        cardsLayer.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - clipTop))
        let ends = engine.lineEnds()
        let path = CGMutablePath()
        let points = engine.stringPoints().map { CGPoint(x: $0.x, y: ly(Double($0.y))) }
        if let first = points.first {
            path.move(to: first)
            path.addLines(between: points)
        }
        let lineAlpha = Float(engine.lineAlpha)
        let visible = engine.state != .hidden || engine.line.value > 0.0005
        // Files dragged over the line: the string glows brighter (a wider, softer glow, a slightly thicker core).
        let boost = CGFloat(ClotheslineMath.clamp(engine.dropGlow.value, 0, 1))
        let glows = palette.glowOpacity > 0
        let glowWidth = 4.5 + (glows ? 3.5 * boost : 0)
        string.lineWidth = (increaseContrast ? 2.2 : 1.8) + 0.7 * boost
        string.path = path
        if !halo.isHidden { halo.path = path }
        core.opacity = visible ? lineAlpha : 0
        halo.opacity = visible ? lineAlpha : 0
        // The light comes on as the string falls into its sag and dims as it is pulled up into the notch.
        let on = ClotheslineMath.smoothstep(0, 1, ClotheslineMath.clamp(engine.fall.value, 0, 1))
        let glowLevel = min(1, palette.glowOpacity * Float(0.25 + 0.75 * on) + (glows ? 0.3 * Float(boost) : 0))
        glow.opacity = visible ? lineAlpha * glowLevel : 0
        let radius = 6 + (glows ? 4 * boost : 0)
        if glow.opacity > 0, glowBlurKey.map({ $0.path != path || $0.width != glowWidth || $0.radius != radius }) ?? true {
            glowBlurKey = (path, glowWidth, radius)
            glowStroke.lineWidth = glowWidth
            glowStroke.path = path
            if let blur = Self.glowBlurImage(path, lineWidth: glowWidth, radius: radius) {
                glowBlur.contents = blur.image
                glowBlur.frame = blur.frame
            }
        }
        // The gradient runs from end to end of the string as it is now, so a gathered line still shows every colour.
        let w = max(1, Double(bounds.width))
        let x0 = ClotheslineMath.clamp(Double(ends.left.x) / w, 0, 1)
        let x1 = max(x0 + 0.002, ClotheslineMath.clamp(Double(ends.right.x) / w, 0, 1))
        for g in [glow, core] {
            g.startPoint = CGPoint(x: x0, y: 0.5)
            g.endPoint = CGPoint(x: x1, y: 0.5)
        }
        let spread = (ends.spreadLeft + ends.spreadRight) / 2
        for (i, t) in tacks.enumerated() {
            let p = i == 0 ? ends.left : ends.right
            t.position = CGPoint(x: p.x, y: ly(p.y))
            t.opacity = visible ? lineAlpha * Float(ClotheslineMath.smoothstep(0.05, 0.3, spread)) : 0
        }
        if cardLayers.count != engine.cards.count { pruneLayers() }
        let palette = self.palette
        for pose in engine.poses {
            guard let l = cardLayers[pose.id] else { continue }
            if pose.alpha > 0.001 && l.card.contents == nil { ensurePicture(pose.id) }
            // A card in the air is drawn by the flight overlay until the pin catches the line.
            Self.place(l, pose: pose, layerY: ly(pose.pivot.y), palette: palette, hidden: pose.flying)
        }
        renderGhost()
        renderSelection()
        CATransaction.commit()
        setAccessibilityLabel(accessibilitySummary)
    }

    /// The selection ring on the selected card's layer, around its mat with a small gap, its corners following the
    /// mat's (HIG Focus and selection: a focus ring for an item that fills a cell, like a photo). Accent in light mode,
    /// the lighter accent in dark mode; Increase Contrast: the deeper accent (lighter still in dark mode) with a thin
    /// edge in the contrasting colour, so it reads over any wallpaper.
    private func renderSelection() {
        guard let id = engine.selectedCard, let l = cardLayers[id], let p = pictures[id] else {
            if selectionRing.superlayer != nil { selectionRing.removeFromSuperlayer() }
            return
        }
        if selectionRing.superlayer !== l.card { l.card.addSublayer(selectionRing) }
        let key = "\(id)|\(p.width)|\(isDark)|\(increaseContrast)"
        guard key != ringKey else { return }
        ringKey = key
        let rect = ClotheslineArt.imageRect(width: p.width), mat = ClotheslineCardMetrics.matRect(width: p.width)
        // The card's layer is y-up with its origin at the picture's lower left.
        let inLayer = CGRect(x: mat.minX - rect.minX, y: rect.maxY - mat.maxY, width: mat.width, height: mat.height)
        let out = Self.ringGap + Self.ringWidth / 2
        let ring = inLayer.insetBy(dx: -out, dy: -out)
        let radius = ClotheslineCardMetrics.radius + out
        let path = CGPath(roundedRect: ring, cornerWidth: radius, cornerHeight: radius, transform: nil)
        selectionRing.frame = CGRect(origin: .zero, size: rect.size)
        ringStroke.path = path
        ringStroke.lineWidth = Self.ringWidth
        ringStroke.strokeColor = Self.ringColor(dark: isDark, contrast: increaseContrast).cgColor
        ringHalo.path = path
        ringHalo.lineWidth = Self.ringWidth + 2
        ringHalo.strokeColor = palette.stringHalo.cgColor
    }

    /// The ring's colour: YummyOrange's accent, as the ghost card's outline wears it.
    static func ringColor(dark: Bool, contrast: Bool) -> NSColor {
        switch (dark, contrast) {
        case (false, false): return DWPalette.accent
        case (true, false): return DWPalette.accentHighlight
        case (false, true): return DWPalette.accentDeep
        case (true, true): return DWPalette.blend(DWPalette.accent, .white, 0.6)
        }
    }

    /// The ghost card: its picture (made again only when its width, caption, picture or appearance changes) at its pose.
    private func renderGhost() {
        guard let pose = engine.ghostPose, let files = ghostFiles else {
            ghostLayer.isHidden = true
            return
        }
        let content = ghostContentCache.flatMap { $0.files == files ? $0.content : nil } ?? ghostContent(files)
        ghostContentCache = (files, content)
        let key = "\(Int(pose.width.rounded()))|\(content.name)|\(content.thumbnail != nil)|\(content.isIcon)|\(isDark)|\(increaseContrast)"
        if key != ghostKey {
            ghostKey = key
            let rect = ClotheslineArt.imageRect(width: pose.width)
            ghostLayer.contents = ClotheslineArt.ghostImage(width: pose.width, content: content, palette: palette, scale: pictureScale)
            ghostLayer.bounds = CGRect(origin: .zero, size: rect.size)
            ghostLayer.anchorPoint = CGPoint(x: -rect.minX / rect.width, y: rect.maxY / rect.height)
        }
        let rotate = CATransform3DMakeRotation(CGFloat(-pose.angle), 0, 0, 1)
        ghostLayer.transform = CATransform3DScale(rotate, CGFloat(pose.scale), CGFloat(pose.scale), 1)
        ghostLayer.position = CGPoint(x: pose.pivot.x, y: ly(pose.pivot.y))
        ghostLayer.opacity = Float(pose.alpha)
        ghostLayer.isHidden = pose.alpha <= 0.001
    }

    /// What the ghost shows: the first file's picture as its card will show it (its Finder icon for a document, the
    /// type's icon for a promised file; nothing while the picture loads) and the file's name, or "3 files".
    func ghostContent(_ files: [URL]) -> ClotheslineArt.CardContent {
        let first = files[0]
        let name: String
        if files.count > 1 {
            name = "\(files.count) files"
        } else if ClotheslineController.isPromise(first) {
            name = ClotheslineController.promisedTypeName(first)
        } else {
            name = FileManager.default.displayName(atPath: first.path)
        }
        if ClotheslineController.isPromise(first) {
            let icon = ClotheslineController.promisedType(first).map { NSWorkspace.shared.icon(for: $0) }
            return ClotheslineArt.CardContent(name: name, thumbnail: icon, isIcon: true, duration: nil)
        }
        let t = thumbnails[first.path] ?? ClotheslinePictures.cached(first, size: Self.thumbnailRequest)
        return ClotheslineArt.CardContent(name: name, thumbnail: t?.image, isIcon: t?.isIcon ?? true, duration: nil)
    }

    /// The ghost's content for the files it stands for (made again when they change or a dragged file's picture
    /// arrives, not every frame).
    private var ghostContentCache: (files: [URL], content: ClotheslineArt.CardContent)?

    /// The files the ghost stands for: the drag's, and after the drop the dropped ones until the cards take over.
    private var ghostFiles: [URL]? {
        if let files = engine.draggedFiles { lastGhostFiles = files; return files }
        return lastGhostFiles
    }
    private var lastGhostFiles: [URL]?

    /// Puts a card's two layers at its pose (`layerY`: the pivot's y in the layer's y-up space). Also used by the
    /// flight overlay, so a card looks the same in the air and on the line.
    static func place(_ l: (shadow: CALayer, card: CALayer), pose: ClotheslineCardPose, layerY: CGFloat,
                      palette: ClotheslineArt.Palette, hidden: Bool = false) {
        let rotate = CATransform3DMakeRotation(CGFloat(-pose.angle), 0, 0, 1)
        let t = CATransform3DScale(rotate, CGFloat(pose.scale), CGFloat(pose.scale), 1)
        l.card.position = CGPoint(x: pose.pivot.x, y: layerY)
        l.card.transform = t
        l.card.opacity = Float(pose.alpha)
        l.card.isHidden = hidden || pose.alpha <= 0.001
        // The shadow follows the swing but always falls downward (light from above).
        let drop = 3 + 3 * pose.lift
        l.shadow.position = CGPoint(x: pose.pivot.x, y: layerY - CGFloat(drop))
        l.shadow.transform = t
        l.shadow.opacity = Float(pose.alpha)
        l.shadow.isHidden = l.card.isHidden
        l.shadow.shadowOpacity = palette.shadowOpacity + Float(0.08 * pose.lift)
        l.shadow.shadowRadius = CGFloat(5.5 + 4 * pose.lift)
        l.shadow.shadowOffset = .zero
    }

    /// A card's layers (the flight overlay copies its picture from them).
    func cardLayerPair(_ id: UUID) -> (shadow: CALayer, card: CALayer)? { cardLayers[id] }

    // MARK: Points

    /// Scene point (top-left origin) for a point in the view.
    func scenePoint(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: bounds.height - p.y) }

    func scenePoint(of event: NSEvent) -> CGPoint { scenePoint(convert(event.locationInWindow, from: nil)) }

    func card(at event: NSEvent) -> UUID? { engine.cardID(at: scenePoint(of: event)) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        // Cards take the mouse; so does the whole view while a scroll gesture is under way (cards move under the
        // pointer), while a card is moved along the string, and while it takes dragged files (AppKit finds the drop's
        // view by hit-testing).
        return engine.acceptsDrop || engine.liftedCard != nil || engine.cardID(at: scenePoint(local)) != nil
            || engine.scroller.mode == .tracking ? self : nil
    }

    // MARK: Dropping files on the line

    /// Registered for file drags only while dragged files are over the notch zone or the line's band (the controller
    /// sets it with the panel's click-through), so drops everywhere else reach the windows below.
    var acceptsFileDrops = false {
        didSet {
            guard acceptsFileDrops != oldValue else { return }
            if acceptsFileDrops { registerForDraggedTypes(Self.dropTypes) } else { unregisterDraggedTypes() }
        }
    }

    /// File URLs, and the types of files an app promises to write (Photos, Mail, Safari images), as the Float shelf.
    static let dropTypes: [NSPasteboard.PasteboardType] = [.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    /// Starts loading the dragged files' pictures while they are on their way (the ghost shows the first one's and
    /// takes its width; the cards don't wait for theirs when they land). Promised files have no picture yet.
    func prefetch(_ urls: [URL]) {
        for url in urls.prefix(12) where url.isFileURL && ClotheslinePictures.cached(url, size: Self.thumbnailRequest) == nil {
            ClotheslinePictures.load(url, size: Self.thumbnailRequest) { [weak self] _ in
                self?.ghostContentCache = nil
                self?.engine.dragPicturesChanged()
                self?.host?.clotheslineNeedsUpdate()
            }
        }
    }

    /// The drag's files (or stand-ins for promised ones), read once per drag session (every update of the same drag
    /// carries the same pasteboard).
    private func droppedFiles(_ info: NSDraggingInfo) -> [URL] {
        let key = ObjectIdentifier(info.draggingPasteboard)
        if let cached = dragFilesCache, cached.session == info.draggingSequenceNumber, cached.pasteboard == key { return cached.files }
        let files = ClotheslineController.dragItems(on: info.draggingPasteboard)
        dragFilesCache = (info.draggingSequenceNumber, key, files)
        return files
    }
    private var dragFilesCache: (session: Int, pasteboard: ObjectIdentifier, files: [URL])?

    private func dropPoint(_ info: NSDraggingInfo) -> CGPoint { scenePoint(convert(info.draggingLocation, from: nil)) }

    /// A drag the line started itself (a card's file taken off the line).
    private func isOwnDrag(_ info: NSDraggingInfo) -> Bool { (info.draggingSource as AnyObject?) === self }

    private func dragUpdate(_ info: NSDraggingInfo) -> NSDragOperation {
        guard let host else { return [] }
        // One of the line's own cards brought back over it in its drag session: it can be hung again there (moved,
        // never twice).
        if isOwnDrag(info) { return host.clotheslineCardDragUpdated(at: dropPoint(info)) }
        let files = droppedFiles(info)
        guard !files.isEmpty else { return [] }
        return host.clotheslineDragUpdated(at: dropPoint(info), files: files, sourceMask: info.draggingSourceOperationMask)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dragUpdate(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dragUpdate(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { host?.clotheslineDragExited(at: sender.map(dropPoint)) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { dragUpdate(sender) != [] }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let host else { return false }
        if isOwnDrag(sender) { return host.clotheslineCardDropped(at: dropPoint(sender)) }
        let files = droppedFiles(sender)
        let promised = files.contains(where: ClotheslineController.isPromise)
        guard !files.isEmpty, ClotheslineController.dropOperation(for: sender.draggingSourceOperationMask, promised: promised) != [] else { return false }
        if promised {
            return host.clotheslineDropPromises(ClotheslineController.promiseReceivers(on: sender.draggingPasteboard), at: dropPoint(sender))
        }
        return host.clotheslineDrop(files, at: dropPoint(sender))
    }
    override func draggingEnded(_ sender: NSDraggingInfo) { host?.clotheslineDragEnded() }
    /// Nothing changes while the files rest over the line (the engine's clock and timers do the rest).
    override func wantsPeriodicDraggingUpdates() -> Bool { false }


    // MARK: Mouse

    override func mouseDown(with event: NSEvent) { pressDown(at: scenePoint(of: event), clickCount: event.clickCount) }
    override func mouseDragged(with event: NSEvent) { pressMoved(to: scenePoint(of: event), event: event) }
    override func mouseUp(with event: NSEvent) { pressUp(at: scenePoint(of: event)) }

    /// The mouse went down (scene point): on a card it answers at once (on press, not on release); a double-click
    /// opens the file.
    func pressDown(at p: CGPoint, clickCount: Int = 1) {
        let id = engine.cardID(at: p)
        press = id.map { .card($0, at: p) } ?? .none
        engine.setPressed(id)
        lastRemoval = nil
        if id != nil { host?.clotheslineCardPressed() } else { engine.select(nil) }
        if clickCount == 2, let id {
            // Opened: its app takes the keyboard; the selection is done with (the release selects nothing).
            press = .over
            engine.select(nil)
            open(id)
        }
        host?.clotheslineNeedsUpdate()
    }

    /// The pressed mouse moved (scene point). Past the drag threshold the card is picked up and moved along the string
    /// with the pointer; once it leaves the line's area its file goes to a drag session (to a Finder folder, or back
    /// onto the line), which has the mouse from then on. `event` starts that session (nil: no window, as offscreen).
    func pressMoved(to p: CGPoint, event: NSEvent? = nil) {
        switch press {
        case .card(let id, let at):
            guard hypot(p.x - at.x, p.y - at.y) >= Self.dragThreshold else { return }
            engine.setPressed(nil)
            if engine.pickUp(id, at: at) {
                press = .moving(id)
                host?.clotheslineCardMoved(to: p)
                takeOutIfAway(id, event: event)
            } else {
                // Not on a line that is out (it is going away): the file is dragged as it is.
                press = .out(id)
                beginDrag(id, event: event)
            }
        case .moving(let id):
            // Esc (seen by the controller's poll) has put it back already.
            guard engine.liftedCard == id else { press = .over; return }
            host?.clotheslineCardMoved(to: p)
            guard engine.liftedCard == id else { press = .over; return }
            takeOutIfAway(id, event: event)
        case .none, .out, .over:
            break
        }
    }

    /// The mouse went up (scene point): a card in the hand is hung where the gap is; a press that never moved past the
    /// threshold was a click, which selects the card (the panel takes the keyboard for it).
    func pressUp(at p: CGPoint) {
        if case .moving(let id) = press, engine.liftedCard == id { host?.clotheslineCardReleased(at: p) }
        if case .card(let id, _) = press { engine.select(id) }
        press = .none
        engine.setPressed(nil)
        host?.clotheslineNeedsUpdate()
    }

    /// The card in the hand left the line's area: its file goes to a drag session, from where the card is now.
    private func takeOutIfAway(_ id: UUID, event: NSEvent?) {
        guard engine.cardLeftArea else { return }
        press = .out(id)
        beginDrag(id, event: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let input = Self.scrollInput(event, time: CACurrentMediaTime()) else { return }
        host?.clotheslineScroll(input)
    }

    /// An NSEvent reduced to what the scroller needs: the horizontal content delta (positive moves the cards left),
    /// trackpad phases, or a mouse-wheel step. The system's momentum events are ignored (ours follows the release).
    static func scrollInput(_ event: NSEvent, time: Double) -> ClotheslineScrollInput? {
        let dx = Double(event.scrollingDeltaX), dy = Double(event.scrollingDeltaY)
        return scrollInput(dx: dx, dy: dy, precise: event.hasPreciseScrollingDeltas, phase: event.phase,
                           momentum: event.momentumPhase, time: time)
    }

    static func scrollInput(dx: Double, dy: Double, precise: Bool, phase: NSEvent.Phase, momentum: NSEvent.Phase,
                            time: Double) -> ClotheslineScrollInput? {
        var delta = abs(dx) >= abs(dy) ? -dx : -dy
        if !precise { delta *= 10 }
        if !momentum.isEmpty { return ClotheslineScrollInput(phase: .momentum, delta: delta, time: time) }
        if phase.contains(.began) { return ClotheslineScrollInput(phase: .began, delta: delta, time: time) }
        if phase.contains(.changed) { return ClotheslineScrollInput(phase: .changed, delta: delta, time: time) }
        if phase.contains(.ended) { return ClotheslineScrollInput(phase: .ended, delta: delta, time: time) }
        if phase.contains(.cancelled) { return ClotheslineScrollInput(phase: .cancelled, delta: 0, time: time) }
        if phase.contains(.mayBegin) { return nil }
        return delta == 0 ? nil : ClotheslineScrollInput(phase: .wheel, delta: delta, time: time)
    }

    // MARK: Actions

    /// The card's file as it is now: renamed files are followed; a file that is gone takes its card off the line
    /// (it lifts away) and the action does nothing.
    func liveURL(_ id: UUID) -> URL? {
        let url = engine.currentURL(of: id)
        if url == nil { host?.clotheslineNeedsUpdate() }
        return url
    }

    func open(_ id: UUID) {
        guard let url = liveURL(id) else { return }
        openFile(url)
    }

    func reveal(_ id: UUID) {
        guard let url = liveURL(id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @discardableResult
    func copy(_ id: UUID, to pasteboard: NSPasteboard = .general) -> Bool {
        guard let url = liveURL(id) else { return false }
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        return true
    }

    /// Takes a card off the line (the file stays where it is) and tells VoiceOver.
    func removeCard(_ id: UUID) {
        let name = engine.item(id)?.name
        engine.remove(id)
        itemsChanged()
        if let name { announce("Removed \(name) from the Clothesline") }
        host?.clotheslineNeedsUpdate()
    }

    // MARK: Keys (while a card is selected)

    override func keyDown(with event: NSEvent) {
        if !handleKey(Self.keyCode(event), modifiers: event.modifierFlags) { super.keyDown(with: event) }
    }

    /// ⌘Z reaches the key window before any menu: it is the line's while it can put a card back.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, lastRemoval != nil, Self.keyCode(event) == 6 else { return super.performKeyEquivalent(with: event) }
        return handleKey(6, modifiers: event.modifierFlags)
    }

    /// The key's code, with Z as 6 whatever the keyboard layout puts there (⌘Z follows the letter, not the key).
    static func keyCode(_ event: NSEvent) -> UInt16 {
        let z = event.charactersIgnoringModifiers?.lowercased() == "z"
        return z ? 6 : (event.keyCode == 6 ? UInt16.max : event.keyCode)
    }

    /// Delete or Forward Delete takes the selected card off the line (as Remove from Line: the file stays where it is)
    /// and the selection moves to the card that takes its place; ← and → move the selection; Esc ends it; ⌘Z right
    /// after Delete puts the card back. Returns whether the key was the line's.
    @discardableResult
    func handleKey(_ code: UInt16, modifiers: NSEvent.ModifierFlags = []) -> Bool {
        let mods = modifiers.intersection([.command, .option, .control, .shift])
        let undo = lastRemoval
        lastRemoval = nil
        // Esc with nothing selected (a card in the hand, the panel keeping the keyboard until the press is over) is
        // the line's all the same: no beep.
        guard let id = engine.selectedCard else { return code == 53 }
        switch (code, mods) {
        case (51, []), (117, []):
            guard let index = engine.items.firstIndex(where: { $0.id == id }) else { return false }
            let item = engine.items[index], welcome = engine.welcomeID == id
            // The focus moves to a neighbour, never far (HIG Focus and selection): the card that slides into its place,
            // or the one before it at the end of the line. With none left the selection ends.
            let rest = engine.items.filter { $0.id != id }
            engine.select(rest.isEmpty ? nil : rest[min(index, rest.count - 1)].id)
            removeCard(id)
            lastRemoval = (item, index, welcome)
        case (123, []), (124, []):
            engine.moveSelection(by: code == 123 ? -1 : 1)
        case (53, []):
            engine.select(nil)
        case (6, [.command]):
            guard let undo, engine.restore(undo.item, at: undo.index, welcome: undo.welcome) else { return false }
            engine.select(undo.item.id)
            itemsChanged()
            announce("Put \(undo.item.name) back on the Clothesline")
        default:
            return false
        }
        host?.clotheslineNeedsUpdate()
        return true
    }

    /// Moves a card one place along the string (VoiceOver's Move Left and Move Right) and says where it went. False at
    /// either end of the line.
    @discardableResult
    func moveCard(_ id: UUID, by step: Int) -> Bool {
        guard let move = engine.moveCard(id, by: step) else { return false }
        announceMoved(move)
        host?.clotheslineNeedsUpdate()
        return true
    }

    func clearLine() {
        engine.clear()
        itemsChanged()
        host?.clotheslineNeedsUpdate()
    }

    // MARK: Context menu

    /// The right-click menu for a card: the common commands first, the ones that take files off the line last.
    func menu(for id: UUID) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = id
            menu.addItem(item)
        }
        add("Open", #selector(menuOpen(_:)))
        add("Show in Finder", #selector(menuReveal(_:)))
        add("Copy", #selector(menuCopy(_:)))
        menu.addItem(.separator())
        add("Remove from Line", #selector(menuRemove(_:)))
        add("Clear Line", #selector(menuClear(_:)))
        return menu
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let id = card(at: event) else { return nil }
        let menu = self.menu(for: id)
        menu.delegate = self
        return menu
    }

    @objc private func menuOpen(_ sender: NSMenuItem) { (sender.representedObject as? UUID).map(open) }
    @objc private func menuReveal(_ sender: NSMenuItem) { (sender.representedObject as? UUID).map(reveal) }
    @objc private func menuCopy(_ sender: NSMenuItem) { if let id = sender.representedObject as? UUID { copy(id) } }
    @objc private func menuRemove(_ sender: NSMenuItem) { (sender.representedObject as? UUID).map(removeCard) }
    @objc private func menuClear(_ sender: NSMenuItem) { clearLine() }

    // MARK: Dragging the file out

    /// The dragging item for a card: the file URL on the pasteboard and the card's picture.
    func draggingItem(for id: UUID) -> NSDraggingItem? {
        guard let url = liveURL(id) else { return nil }
        let drag = NSDraggingItem(pasteboardWriter: url as NSURL)
        if let pose = engine.pose(id), let picture = cardLayers[id]?.card.contents {
            let rect = ClotheslineArt.imageRect(width: pose.width)
            let origin = CGPoint(x: pose.pivot.x + rect.minX, y: ly(pose.pivot.y + rect.maxY))
            let image = NSImage(cgImage: picture as! CGImage, size: rect.size)
            drag.setDraggingFrame(CGRect(origin: origin, size: rect.size), contents: image)
        } else {
            drag.setDraggingFrame(CGRect(x: 0, y: 0, width: 64, height: 64), contents: ShelfThumbnails.icon(for: url).image)
        }
        return drag
    }

    private var draggedCard: UUID?
    /// The dragging item of the last drag session started (previews draw its picture where the system would).
    private(set) var lastDraggingItem: NSDraggingItem?

    /// Hands the card's file to a drag session, its picture where the card is now (it is in the hand, or on the line).
    /// Without a window (offscreen) there is no session: everything else happens as with one.
    private func beginDrag(_ id: UUID, event: NSEvent?) {
        guard let drag = draggingItem(for: id) else {
            // The file is gone (its card lifts away): nothing to drag.
            press = .over
            host?.clotheslineNeedsUpdate()
            return
        }
        draggedCard = id
        lastDraggingItem = drag
        engine.cardWentOut()
        if let event, window != nil {
            let session = beginDraggingSession(with: [drag], event: event, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = true
        }
        // The session owns the mouse now: the panel lets it through so drops reach the windows below (it takes the
        // drag again over the line's area, where the card can be hung once more).
        engine.isDragging = true
        host?.clotheslineNeedsUpdate()
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Like a Finder drag outside (the destination decides: move on the same disk, copy elsewhere, ⌥ copies);
        // inside YummyOrange the file is only read.
        context == .outsideApplication ? [.copy, .move, .link, .generic] : [.copy, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        ownDragEnded()
    }

    /// The card's drag session ended (dropped anywhere or cancelled): unless it was let go over the line, the card goes
    /// back to its place, and a file the drop moved is followed to its new folder.
    func ownDragEnded() {
        engine.isDragging = false
        press = .none
        // The session's loop kept its mouse-up from the event monitors: the drag watch hears of the release here.
        host?.clotheslineOwnDragEnded()
        host?.clotheslineCardDragEnded()
        host?.clotheslineNeedsUpdate()
        // Like the Float shelf: a file the drop moved is followed to its new folder; one that is gone (or in the
        // Trash) leaves the line.
        guard draggedCard != nil else { return }
        draggedCard = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.engine.pruneMissing()
            self?.host?.clotheslineNeedsUpdate()
        }
    }

    // MARK: Accessibility

    var accessibilitySummary: String {
        let n = engine.items.count
        return "Clothesline, \(n) file\(n == 1 ? "" : "s")"
    }

    private func updateAccessibility() {
        // The same element for a card that stays (VoiceOver keeps its focus on a card it moved), in the line's order.
        let existing = Dictionary(accessibilityCards.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        accessibilityCards = engine.items.map { existing[$0.id] ?? ClotheslineCardElement(view: self, id: $0.id) }
        setAccessibilityLabel(accessibilitySummary)
        setAccessibilityChildren(accessibilityCards)
    }

    var accessibilityCardElements: [ClotheslineCardElement] { accessibilityCards }

    /// Tells VoiceOver which files were just hung (it can't see a window appear at the top of the screen).
    func announceAdded(_ added: [ClotheslineItem]) {
        guard !added.isEmpty else { return }
        announce(added.count == 1 ? "\(added[0].name) added to the Clothesline" : "\(added.count) files added to the Clothesline")
    }

    /// Tells VoiceOver the line came down from the menu, and how many files it holds.
    func announceShown() { announce(accessibilitySummary) }

    /// Tells VoiceOver which files were dropped on the line.
    func announceDropped(_ added: [ClotheslineItem]) {
        guard !added.isEmpty else { return }
        announce(added.count == 1 ? "Added \(added[0].name) to the Clothesline" : "Added \(added.count) files to the Clothesline")
    }

    /// Tells VoiceOver where a card moved along the string went (its place counted from the left, from 1).
    func announceMoved(_ move: ClotheslineEngine.CardMove) {
        guard move.moved, let item = engine.item(move.id) else { return }
        announce("Moved \(item.name) to position \(move.to + 1)")
    }

    private func announce(_ text: String) {
        lastAnnouncement = text
        let element: Any = NSApp ?? self
        NSAccessibility.post(element: element, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// VoiceOver (or the keyboard) is on a card: the line stays out until it moves away.
    func accessibilityFocusChanged(_ id: UUID, focused: Bool) {
        if focused { engine.accessibilityFocus = id } else if engine.accessibilityFocus == id { engine.accessibilityFocus = nil }
        host?.clotheslineNeedsUpdate()
    }

    /// The card's frame in screen coordinates.
    func screenFrame(of id: UUID) -> CGRect {
        guard let pose = engine.pose(id) else { return .zero }
        let b = ClotheslineEngine.bounds(pose)
        let inView = CGRect(x: b.minX, y: bounds.height - b.maxY, width: b.width, height: b.height)
        guard let window else { return inView }
        return window.convertToScreen(convert(inView, to: nil))
    }
}

extension ClotheslineView: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) { engine.isMenuOpen = true; host?.clotheslineNeedsUpdate() }
    func menuDidClose(_ menu: NSMenu) {
        engine.isMenuOpen = false
        DispatchQueue.main.async { [weak self] in self?.host?.clotheslineNeedsUpdate() }
    }
}

/// One card for VoiceOver: its file name (and the video's length), Open as the press, and the menu's commands.
final class ClotheslineCardElement: NSAccessibilityElement {
    weak var view: ClotheslineView?
    let id: UUID

    init(view: ClotheslineView, id: UUID) {
        self.view = view
        self.id = id
        super.init()
        setAccessibilityRole(.button)
        setAccessibilityParent(view)
        setAccessibilityLabel(label)
        setAccessibilityHelp("Double-click to open. Drag along the line to move it; drag it off the line to take the file.")
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Show in Finder") { [weak self] in self?.perform { $0.reveal($1) } ?? false },
            NSAccessibilityCustomAction(name: "Copy") { [weak self] in self?.perform { $0.copy($1) } ?? false },
            NSAccessibilityCustomAction(name: "Move Left") { [weak self] in self?.move(by: -1) ?? false },
            NSAccessibilityCustomAction(name: "Move Right") { [weak self] in self?.move(by: 1) ?? false },
            NSAccessibilityCustomAction(name: "Remove from Line") { [weak self] in self?.perform { $0.removeCard($1) } ?? false },
        ])
    }

    var label: String {
        guard let item = view?.engine.item(id) else { return "" }
        if let seconds = ClotheslineArt.cachedDuration(item.url) {
            return "\(item.name), video, \(ClotheslineArt.durationText(seconds))"
        }
        return item.name
    }

    private func perform(_ action: (ClotheslineView, UUID) -> Void) -> Bool {
        guard let view else { return false }
        action(view, id)
        return true
    }

    /// One place along the string; false at either end.
    private func move(by step: Int) -> Bool { view?.moveCard(id, by: step) ?? false }

    private var focused = false
    override func isAccessibilityFocused() -> Bool { focused }
    override func setAccessibilityFocused(_ value: Bool) {
        focused = value
        view?.accessibilityFocusChanged(id, focused: value)
    }

    override func accessibilityFrame() -> NSRect { view?.screenFrame(of: id) ?? .zero }
    override func accessibilityPerformPress() -> Bool { perform { $0.open($1) } }
    override func accessibilityLabel() -> String? { label }
    override func isAccessibilitySelected() -> Bool { view?.engine.selectedCard == id }
}
