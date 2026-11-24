import AppKit

/// Where the clothesline lives on a display, in the panel's own coordinates: points, origin at the top-left of the
/// screen, y growing downward (the scene's coordinate space). Pure values, so tests can build one for any display.
///
/// The notch is the gap between `NSScreen.auxiliaryTopLeftArea` and `auxiliaryTopRightArea`; a display without one
/// gets a virtual notch: a 180 pt zone at the top centre of the menu bar.
struct ClotheslineGeometry: Equatable {
    /// The display's frame in global screen coordinates (bottom-left origin), for converting pointer positions.
    var screenFrame: CGRect
    /// Height of the menu bar / safe area at the top (40 pt on a notched MacBook, about 24 pt elsewhere).
    var menuBarHeight: CGFloat
    /// The notch (or virtual notch) in scene coordinates: x range and 0…menuBarHeight.
    var notch: CGRect
    /// Whether the notch is a real camera housing (pixels there are never seen) or the virtual zone.
    var hasNotch: Bool

    /// Height of the panel, from the top of the screen down.
    static let panelHeight: CGFloat = 300
    /// The ends of the line sit this far inside the left and right edges.
    static let endInset: CGFloat = 14
    /// The resting line runs this far below the menu bar (the pins' tops stay just under its edge).
    static let lineDrop: CGFloat = 12
    /// The string pulled taut runs this far under the menu bar's edge (it never crosses the bar outside the notch).
    static let ceilingGap: CGFloat = 2
    /// Width of the virtual notch on displays without one.
    static let virtualNotchWidth: CGFloat = 180
    /// The hover zone reaches this far around and below the notch.
    static let hoverMargin: CGFloat = 12
    /// How far below the line's resting height a card can reach: a full line's sag and bounce, a card swinging or
    /// tilted by a scroll, and the hover lift (164 pt with the first, shallower sag; the deeper sag adds up to 38 pt;
    /// `--selftest results-shelf` checks it with 50 cards swinging, hovered and scrolled).
    static let cardsReach: CGFloat = 210

    var width: CGFloat { screenFrame.width }
    var notchCenterX: CGFloat { notch.midX }
    /// The resting height of the line's ends.
    var lineY: CGFloat { menuBarHeight + Self.lineDrop }
    /// The lowest any card can hang, from the top of the screen (the progress panel stays under it).
    var cardsBottom: CGFloat { lineY + Self.cardsReach }
    /// Just under the menu bar: as high as the string may go outside the notch.
    var ceilingY: CGFloat { menuBarHeight + Self.ceilingGap }
    /// Where the gathered string waits: inside the notch, above its bottom edge (without a notch: just under the bar,
    /// where it fades).
    var hiddenY: CGFloat { hasNotch ? max(4, menuBarHeight - 14) : ceilingY }
    /// Half the notch's width.
    var notchHalf: CGFloat { notch.width / 2 }
    var leftEndX: CGFloat { Self.endInset }
    var rightEndX: CGFloat { width - Self.endInset }
    /// Half the width the two strands use while they drop out of the notch.
    var notchInnerHalf: CGFloat { max(6, notch.width / 2 - 8) }
    /// Panel frame in global screen coordinates.
    var panelFrame: CGRect {
        CGRect(x: screenFrame.minX, y: screenFrame.maxY - Self.panelHeight, width: screenFrame.width, height: Self.panelHeight)
    }

    /// The zone that drops the line when the pointer rests in it: the notch rect plus the strip of menu bar directly
    /// around and under it (12 pt), up to the top of the screen.
    var hoverZone: CGRect {
        CGRect(x: notch.minX - Self.hoverMargin, y: 0,
               width: notch.width + 2 * Self.hoverMargin, height: notch.maxY + Self.hoverMargin)
    }

    /// The notch itself, up to the top of the screen.
    var notchCore: CGRect { CGRect(x: notch.minX, y: 0, width: notch.width, height: notch.maxY) }

    /// How long the pointer has to stay inside the notch (or the virtual notch) to drop the line: half a second
    /// everywhere, so passing through or brushing past it never does.
    func dwell(at p: CGPoint) -> Double { Self.notchDwell }
    /// How long the pointer stays inside the notch (or the virtual notch) before the line comes out.
    static let notchDwell = 0.5

    /// Scene point (top-left origin) for a global screen point (bottom-left origin).
    func scenePoint(fromScreen p: CGPoint) -> CGPoint {
        CGPoint(x: p.x - screenFrame.minX, y: screenFrame.maxY - p.y)
    }
    /// Global screen point for a scene point.
    func screenPoint(fromScene p: CGPoint) -> CGPoint {
        CGPoint(x: p.x + screenFrame.minX, y: screenFrame.maxY - p.y)
    }

    /// From explicit values (tests, previews). `leftArea`/`rightArea` are the auxiliary top areas in global
    /// coordinates, or nil on a display without a notch.
    init(screenFrame: CGRect, safeAreaTop: CGFloat, visibleFrame: CGRect? = nil, leftArea: CGRect?, rightArea: CGRect?) {
        self.screenFrame = screenFrame
        if let l = leftArea, let r = rightArea, r.minX > l.maxX, safeAreaTop > 0 {
            menuBarHeight = safeAreaTop
            // The areas come in the same global space as the frame; tolerate screen-relative ones too.
            let global = l.minX >= screenFrame.minX - 1 && r.maxX <= screenFrame.maxX + 1
            let originX = global ? screenFrame.minX : 0
            notch = CGRect(x: l.maxX - originX, y: 0, width: r.minX - l.maxX, height: safeAreaTop)
            hasNotch = true
        } else {
            let bar = visibleFrame.map { max(0, screenFrame.maxY - $0.maxY) } ?? 0
            menuBarHeight = bar > 4 ? bar : max(safeAreaTop, 24)
            let w = Self.virtualNotchWidth
            notch = CGRect(x: screenFrame.width / 2 - w / 2, y: 0, width: w, height: menuBarHeight)
            hasNotch = false
        }
    }

    /// The display's own geometry.
    init(screen: NSScreen) {
        var left: CGRect?, right: CGRect?, top: CGFloat = 0
        if #available(macOS 12.0, *) {
            left = screen.auxiliaryTopLeftArea
            right = screen.auxiliaryTopRightArea
            top = screen.safeAreaInsets.top
        }
        self.init(screenFrame: screen.frame, safeAreaTop: top, visibleFrame: screen.visibleFrame, leftArea: left, rightArea: right)
    }

    /// The display the line hangs on: the one with a notch, else the one with the menu bar.
    static func preferredScreen() -> NSScreen? {
        if #available(macOS 12.0, *) {
            if let notched = NSScreen.screens.first(where: { $0.auxiliaryTopLeftArea != nil && $0.auxiliaryTopRightArea != nil }) {
                return notched
            }
        }
        return NSScreen.screens.first ?? NSScreen.main
    }

    /// This Mac's built-in display (1736 × 1133 pt, notch from x 838.5 to 897.5, 40 pt menu bar), for previews and tests.
    static let builtInSample = ClotheslineGeometry(
        screenFrame: CGRect(x: 0, y: 0, width: 1736, height: 1133), safeAreaTop: 40,
        leftArea: CGRect(x: 0, y: 1093, width: 838.5, height: 40),
        rightArea: CGRect(x: 897.5, y: 1093, width: 838.5, height: 40))
}
