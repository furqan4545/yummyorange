import AppKit
import QuartzCore

// A copied screenshot's card flies up to the Clothesline from the pointer. The line's panel covers only the top 300 pt
// of the display, so the flight is drawn in a second window: a click-through, non-activating panel over the whole notch
// display, just above the line's panel. It is on screen only while a card is in the air, draws nothing but the flying
// cards (copies of the line's own card layers, at the poses the engine gives them) and is ordered out the moment the
// last one is caught (it is kept for the next one). The frame the pin catches the line, the card stops being drawn here
// and starts being drawn by the line's view, at the same place. A card moved along the string by hand is carried in the
// same window (over the string and the other cards, never cut off at the panel's edge) from the moment it is picked up
// until the string catches it again.
//
// Neither window should end up in the user's next screenshot: the flight window is left out of screen captures while
// a screenshot's card is in it, and the line's panel while it is out for a screenshot (otherwise either can be
// captured like any window, so a card being moved shows in a screen recording).

/// The flight's start, in the line's scene coordinates (top-left origin of the notch display, y down).
enum ClotheslineFlightGeometry {
    /// A card that comes in from the right edge starts this far past it (its shadow included) …
    static let offEdge: CGFloat = 16
    /// … with its mat this far above the bottom of the display's visible frame (about where macOS shows a screenshot's
    /// floating thumbnail; assumed, not measured).
    static let edgeInset: CGFloat = 20

    /// The pin's starting point for a card that flies up from `p` (global screen coordinates, bottom-left origin), such
    /// as the pointer just after a screenshot was copied: the mat centred on it, wholly on the display, under the menu
    /// bar. A point on another display starts just past this display's right edge instead, near its bottom, and the
    /// card slides in: with "Displays have separate Spaces" on (the default) one window can't span two displays, so the
    /// card can only fly on the line's own. Measured for the widest card, since the card's width is known only once its
    /// thumbnail is.
    static func start(from p: CGPoint, geometry g: ClotheslineGeometry, visibleFrame: CGRect?) -> CGPoint {
        let mat = ClotheslineCardMetrics.matRect(width: ClotheslineCardMetrics.maxMatWidth)
        let halfW = Double(mat.width) / 2 + 6, halfH = Double(mat.height) / 2 + 6
        func underBar(_ y: CGFloat) -> CGFloat {
            CGFloat(ClotheslineMath.clamp(Double(y), Double(g.menuBarHeight) + halfH,
                                          max(Double(g.menuBarHeight) + halfH, Double(g.screenFrame.height) - halfH)))
        }
        if g.screenFrame.contains(p) {
            var center = g.scenePoint(fromScreen: p)
            center.x = CGFloat(ClotheslineMath.clamp(Double(center.x), halfW, Double(g.width) - halfW))
            center.y = underBar(center.y)
            return CGPoint(x: center.x, y: center.y - mat.midY)
        }
        let v = visibleFrame ?? g.screenFrame
        let level = g.scenePoint(fromScreen: CGPoint(x: v.maxX, y: v.minY + edgeInset + mat.height / 2)).y
        return CGPoint(x: g.width + mat.width / 2 + offEdge, y: underBar(level) - mat.midY)
    }
}

// MARK: - View

/// The cards in the air, over the whole notch display (layer-backed, y up). Each frame it shows exactly the engine's
/// flying cards, with the pictures the line's view made for them.
final class ClotheslineFlightView: NSView {
    private let root = CALayer()
    private var layers: [UUID: (shadow: CALayer, card: CALayer)] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        root.frame = bounds
        layer = root
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    /// Never takes the mouse (the window ignores it too).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        root.frame = bounds
    }

    /// The cards drawn now (tests).
    var visibleCards: [UUID] { layers.filter { !$0.value.card.isHidden }.map(\.key) }

    /// Mirrors the engine's flying cards: their pictures from `source` (the line's view), their poses from the engine.
    func render(engine: ClotheslineEngine, source: ClotheslineView) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let poses = engine.poses.filter(\.flying)
        let ids = Set(poses.map(\.id))
        for (id, l) in layers where !ids.contains(id) {
            l.shadow.removeFromSuperlayer()
            l.card.removeFromSuperlayer()
            layers[id] = nil
        }
        let palette = source.palette
        for pose in poses {
            if pose.alpha > 0.001 { source.ensurePicture(pose.id) }
            guard let from = source.cardLayerPair(pose.id) else { continue }
            let l = layers[pose.id] ?? makeLayers(pose.id)
            if l.card.contents as AnyObject? !== from.card.contents as AnyObject? { l.card.contents = from.card.contents }
            l.card.contentsScale = from.card.contentsScale
            l.card.bounds = from.card.bounds
            l.card.anchorPoint = from.card.anchorPoint
            l.shadow.bounds = from.shadow.bounds
            l.shadow.anchorPoint = from.shadow.anchorPoint
            l.shadow.shadowPath = from.shadow.shadowPath
            ClotheslineView.place(l, pose: pose, layerY: bounds.height - pose.pivot.y, palette: palette)
        }
        CATransaction.commit()
    }

    private func makeLayers(_ id: UUID) -> (shadow: CALayer, card: CALayer) {
        let shadow = CALayer()
        shadow.shadowColor = NSColor.black.cgColor
        let card = CALayer()
        for l in [shadow, card] {
            l.actions = ["position": NSNull(), "transform": NSNull(), "opacity": NSNull(), "shadowPath": NSNull(),
                         "shadowOpacity": NSNull(), "shadowRadius": NSNull(), "contents": NSNull(), "bounds": NSNull(),
                         "anchorPoint": NSNull()]
            root.addSublayer(l)
        }
        layers[id] = (shadow, card)
        return (shadow, card)
    }
}

// MARK: - Surfaces

/// Where the flight is shown: a transient panel, or the view alone (tests, previews).
protocol ClotheslineFlightSurface: AnyObject {
    var view: ClotheslineFlightView { get }
    var isShown: Bool { get }
    /// Left out of screen captures (screenshots, recordings, screen sharing).
    var excludedFromCapture: Bool { get set }
    func show()
    func hide()
    func geometryChanged(_ g: ClotheslineGeometry)
}

/// The borderless, transparent panel over the whole notch display that carries cards in the air. It never takes the
/// mouse or the keyboard, never activates YummyOrange and is left out of screen captures; it sits one level above the
/// line's panel (and so above the Dock and full-screen apps), so a card flies in front of the string and lands with
/// its pin over it.
final class ClotheslineFlightPanel: NSPanel {
    static let level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)

    init(geometry: ClotheslineGeometry) {
        super.init(contentRect: geometry.screenFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isFloatingPanel = true
        level = Self.level
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
        title = "Clothesline Flight"
        // Mostly it exists in the seconds after a screenshot, when the next one may be taken: out of captures until the
        // controller says otherwise (a card being moved by hand).
        sharingType = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class ClotheslineFlightPanelSurface: ClotheslineFlightSurface {
    let panel: ClotheslineFlightPanel
    let view: ClotheslineFlightView

    init(geometry: ClotheslineGeometry) {
        panel = ClotheslineFlightPanel(geometry: geometry)
        view = ClotheslineFlightView(frame: CGRect(origin: .zero, size: geometry.screenFrame.size))
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
    }

    var isShown: Bool { panel.isVisible }
    var excludedFromCapture: Bool {
        get { panel.sharingType == .none }
        set { let type: NSWindow.SharingType = newValue ? .none : .readOnly; if panel.sharingType != type { panel.sharingType = type } }
    }
    func show() { panel.orderFrontRegardless() }
    func hide() { panel.orderOut(nil) }
    func geometryChanged(_ g: ClotheslineGeometry) { panel.setFrame(g.screenFrame, display: false) }
}

/// The flight view with no window (tests, offscreen previews).
final class ClotheslineFlightOffscreenSurface: ClotheslineFlightSurface {
    let view: ClotheslineFlightView
    private(set) var isShown = false
    private(set) var showCount = 0
    var excludedFromCapture = true

    init(geometry: ClotheslineGeometry) {
        view = ClotheslineFlightView(frame: CGRect(origin: .zero, size: geometry.screenFrame.size))
    }

    func show() { if !isShown { isShown = true; showCount += 1 } }
    func hide() { isShown = false }
    func geometryChanged(_ g: ClotheslineGeometry) { view.setFrameSize(g.screenFrame.size) }
}
