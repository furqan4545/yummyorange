import AppKit

/// One file on the line.
struct ClotheslineItem: Equatable {
    let id: UUID
    var url: URL
    /// A file reference (it follows the file when it is renamed or moved on the same volume), when there is one.
    var reference: NSURL?
    var name: String { FileManager.default.displayName(atPath: url.path) }
}

/// Card measurements, in points, in the card's own frame: origin at the pivot (where the clothespin grips the line),
/// y growing downward.
enum ClotheslineCardMetrics {
    static let matHeight: CGFloat = 110
    /// The mat starts this far below the pivot; the pin covers the gap.
    static let matTop: CGFloat = 8
    static let inset: CGFloat = 6
    static let caption: CGFloat = 20
    static var thumbHeight: CGFloat { matHeight - inset - caption }
    /// Narrow (portrait) pictures get a mat at least this wide, so the name below them stays readable (a 98 pt
    /// caption: about 17 characters at 11 pt); the picture sits centred in its well.
    static let minMatWidth: CGFloat = 112
    static let maxMatWidth: CGFloat = 170
    /// A document icon's card (no preview).
    static let iconMatWidth: CGFloat = 112
    static let pinWidth: CGFloat = 12
    static let pinTop: CGFloat = -11
    static let pinHeight: CGFloat = 29
    static let radius: CGFloat = 8
    /// Space between neighbouring cards, and before the first one.
    static let gap: CGFloat = 22
    static let leadingPad: CGFloat = 34
    static let trailingPad: CGFloat = 34

    /// The mat width for a thumbnail of this pixel aspect (nil: a document icon).
    static func matWidth(aspect: CGFloat?) -> CGFloat {
        guard let a = aspect, a.isFinite, a > 0 else { return iconMatWidth }
        return min(max(thumbHeight * a + 2 * inset, minMatWidth), maxMatWidth)
    }
    static func matRect(width w: CGFloat) -> CGRect { CGRect(x: -w / 2, y: matTop, width: w, height: matHeight) }
    static var pinRect: CGRect { CGRect(x: -pinWidth / 2, y: pinTop, width: pinWidth, height: pinHeight) }
}

/// Where one card is drawn this frame.
struct ClotheslineCardPose: Equatable {
    let id: UUID
    /// The pivot in scene coordinates.
    var pivot: CGPoint
    /// Radians, clockwise on screen (the bottom swings left for positive angles).
    var angle: Double
    var scale: Double
    var alpha: Double
    /// 0…1 hover lift, for the shadow.
    var lift: Double
    var width: CGFloat
    /// The card is in the air (a screenshot on its way to the line): the flight overlay draws it, the line's view doesn't.
    var flying = false
}

/// The clothesline's behaviour without any windows: the files, the state machine (hidden, revealing, shown,
/// retracting), the timing rules and the physics (the string, its sag, pendulum cards, scrolling). Deterministic: it
/// advances in fixed 1/240 s substeps, so a virtual clock (tests, previews) and the display link get the same motion.
///
/// The string moves on two springs. `line` is its spread: the two ends sliding out of the notch along the bottom of
/// the menu bar and back. `fall` is its height: 1 hanging in its sag, 0 pulled up taut with its middle drawn into the
/// notch. Going away, the string is first pulled up (the middle rises into the notch, the cards ride up with it),
/// then its ends are reeled in. Coming back, the ends run out first and then the string falls into its sag with a
/// small bounce. Both springs always move on from where they are, so every reversal is continuous.
final class ClotheslineEngine {
    enum State: String { case hidden, revealing, shown, retracting }

    // MARK: Tuning (Apple-style springs: damping ratio + response)
    //
    // Quick: about a third quicker than the first tuning everywhere the person waits on the motion (the line coming
    // out and going back, landings, the gap opening, cards sliding over), which read as sluggish; the shapes (the sag,
    // the bounce, the pull into the notch, the swing's tempo) stay as they were.

    static let capacity = 50
    static let substep = 1.0 / 240
    /// The ends running out of the notch along the menu bar (a hint of overshoot, like a string snapping taut) …
    static let lineDamping = 0.85, lineResponse = 0.3
    /// … and being reeled back in (no overshoot: the ends would cross inside the notch). The ends travel about 870 pt
    /// in about 0.3 s; the pull up before it (`pullResponse`) still shows the middle going into the notch first.
    static let lineInDamping = 1.0, lineInResponse = 0.35
    /// The string falling from the notch into its sag (a small bounce: it falls under its own weight) …
    static let fallDamping = 0.6, fallResponse = 0.23
    /// … and being pulled back up taut (no bounce): 80 % of the rise takes about 105 ms, so it is still seen.
    static let pullDamping = 1.0, pullResponse = 0.23
    /// A line turned round on its way into the notch falls back a little slower, so the reversal doesn't jolt.
    static let fallCatchResponse = 0.34
    /// The string starts to fall once its ends are this far out; the ends start in once it is this taut.
    static let fallGate = 0.55, pullGate = 0.2
    /// Pulled taut, the ends rise this much (the whole string lifts a little toward the menu bar).
    static let pulledLift = 4.0
    /// The line's sag: a little bounce when it fills or a card lands.
    static let sagDamping = 0.5, sagResponse = 0.38
    /// How deep the line sags at its middle: this much empty, then a base plus a little more for each card (up to 12),
    /// like a real line taking weight. Never more than `sagMaxShare` of the span.
    static let sagEmpty: Double = 20, sagBase: Double = 30, sagPerCard: Double = 3, sagMaxShare: Double = 0.08
    /// Each card's pendulum: low damping, 2–3 visible swings, within 0.5° in about 2 s. The response sets a period
    /// of about 0.87 s, the tempo of a card swinging on a pin (shorter reads as twitchy).
    static let swingDamping = 0.22, swingResponse = 0.85
    /// The clothespin's grip: a little dry friction (radians of restoring pull it can hold), so a small swing stops in
    /// a few beats instead of fading out over seconds. A card can rest up to this far (0.15°) off its exact angle.
    static let pinFriction = ClotheslineMath.radians(0.15)
    /// A hovered card calms down; while the cards scroll they swing less (no comb of identical swings).
    static let calmDamping = 0.9, scrollSwingDamping = 0.45
    /// Cards sliding to new slots (Apple's move/reposition spring).
    static let slotDamping = 1.0, slotResponse = 0.26
    /// A new card dropping onto the line: the pin catches it with at most ~2 pt of overshoot (the jaws stay on the
    /// string); the bounce goes into the string, which dips under the pin (as deep as before: the quicker dip spring
    /// gets a harder kick).
    static let dropDamping = 0.75, dropResponse = 0.2
    static let dropHeight = 70.0
    static let dipDamping = 0.4, dipResponse = 0.22, dipKick = 200.0, dipHalfWidth = 46.0
    /// The pin catching the line keeps the card swinging the way it was going (radians per second).
    static let arrivalKick = 0.85
    /// New cards follow each other by this much.
    static let cascade = 0.03
    /// When the line is coming out of the notch, new cards start dropping this long after it starts.
    static let dropDelayFromHidden = 0.16
    /// A card waits at most this long (from hang) for its thumbnail before it drops with a placeholder.
    static let pictureWait = 0.35
    /// The line stays this long after the last new card arrives (three times as long while VoiceOver runs).
    static let holdAfterArrival = 2.0
    /// … and retracts this long after the pointer leaves the line band.
    static let retractAfterLeave = 0.6
    /// The pointer must rest (stay within this many points) in the notch zone for the geometry's dwell time.
    static let restRadius: CGFloat = 4
    /// Reduce Motion: the line and cards cross-fade in and out in this time.
    static let reduceMotionFade = 0.2
    /// Reduce Motion: when the cards change places they fade out and back in, this long each way.
    static let reflowFade = 0.1
    /// Card tilt against the scroll velocity: this many degrees per 1000 pt/s, at most `maxScrollTilt`.
    static let tiltPerKPointsPerSecond = 8.0
    static let maxScrollTilt = 12.0
    /// Shown angles are softly limited above `tiltKnee` so they never pass `maxShownTilt` (degrees).
    static let tiltKnee = 11.0, maxShownTilt = 15.0
    /// Largest steady tilt from the pin accelerating, and the acceleration that reaches ~76 % of it.
    static let maxInertialTilt = 10.0
    static let inertialReference = 20000.0
    /// A clothespin clamps the card to the string, so the card follows half the string's slope.
    static let slopeFollow = 0.5
    /// … at most this much (radians): a short, deep line near the notch would otherwise twist the cards.
    static let maxSlopeTilt = ClotheslineMath.radians(6)
    /// The band that keeps the line out reaches this far above and below the string.
    static let bandReach = 12.0
    /// Scroll input that stops arriving this long during a gesture is treated as a lost "ended".
    static let lostGesture = 0.3

    // MARK: Tuning: dropping files on the line

    /// A dropped file doesn't fall: its card starts exactly where the ghost hangs and the ghost cross-fades into it
    /// in this time (Reduce Motion: `reduceMotionFade`). The landing is the pin closing on the string: the string dips
    /// under it and the card swings (`dipKick`, `arrivalKick`), so nothing jumps at the hand-off.
    static let handoffFade = 0.1
    /// The hand's speed handed over to a dropped card's swing: radians per second per 1000 pt/s, at most this much.
    static let dropSpinPerKPointsPerSecond = 0.5, maxDropSpin = 0.6
    /// A card let go by a still hand still swings a little more than the pin's catch alone gives (about 5° at first,
    /// like a job's newest card); several cards alternate, so they swing out of step.
    static let dropSettleSpin = 0.2
    /// Promised files (Photos, Mail, Safari) are written by their app after the drop: the gap and the ghost wait for
    /// them this long at most.
    static let promiseWait = 10.0
    /// The ghost card (where the dragged files will hang) moves between slots critically damped (an indicator, not
    /// an object with weight, so no overshoot), a little quicker than the cards opening the gap around it …
    static let ghostDamping = 1.0, ghostResponse = 0.2
    /// … and appears or goes on this spring (Reduce Motion: a 0.15 s fade).
    static let ghostShowDamping = 1.0, ghostShowResponse = 0.14
    static let ghostFade = 0.15
    /// Gliding along the string the ghost leans against its motion (degrees per 1000 pt/s, at most `maxGhostTilt`).
    static let ghostTiltPerKPointsPerSecond = 4.0, maxGhostTilt = 6.0
    /// The string brightens while it can take the files (and dims again) on this spring.
    static let dropGlowResponse = 0.17
    /// The gap moves to another slot only once the pointer is this much nearer to that slot (no flicker between two).
    static let gapHysteresis = 8.0
    /// Within this far of either end of the line a drag scrolls the hidden cards into view, up to this fast (pt/s).
    static let edgeScrollZone = 70.0, edgeScrollSpeed = 900.0
    /// A released button and the drop itself reach YummyOrange separately (the mouse-up through the event monitor, the
    /// drop through AppKit): after a release over the line the drag waits this long for its drop before it ends.
    static let dropGrace = 0.5
    /// The pose id of the ghost card.
    static let ghostID = UUID(uuidString: "6B1D7A2E-0C3F-4E55-9A0D-5D1B0C7E0D60")!
    /// Something dragged that the line has taken (files, or one of its own cards) keeps it out anywhere in the line's
    /// area (`dropArea`): this far past the string's ends and the lowest card's foot, and this much further while the
    /// drag is in it (so a hand wobbling at the edge doesn't flicker in and out).
    static let dropAreaMargin = 16.0, dropAreaHold = 12.0
    /// Dragged files or a card taken out of the line's area: the line goes this long after they left (a pointer with
    /// nothing in hand: `retractAfterLeave`). Short, since the hand has gone elsewhere with them, but long enough that a
    /// wobble out of the area and straight back doesn't send the line away.
    static let dragLeaveGrace = 0.35

    // MARK: Tuning: moving a card along the string

    /// A card in the hand hangs from its pin under the pointer and leans with the hand's speed (its foot trails): this
    /// many degrees per 1000 pt/s, at most `maxHeldTilt`. It swings into the lean on this damping (calmer than on the
    /// line, so it doesn't sway under the hand) …
    static let heldTiltPerKPointsPerSecond = 6.0, maxHeldTilt = 10.0, heldSwingDamping = 0.5
    /// … and its pin's speed is smoothed over this long for the lean (pointer events come in steps).
    static let heldSmoothing = 0.05
    /// Let go over the line, the card carries the hand's speed to its place, at most this fast across and up or down
    /// (pt/s): a fast flick would otherwise swing it past its slot into a neighbour, or snap the pin off the string.
    static let rehangMaxSpeedX = 1500.0, rehangMaxSpeedY = 400.0
    /// A card whose drag ended away from the line (dropped in a Finder folder, cancelled) fades back in at its place
    /// this long, when the line is out to show it.
    static let returnFade = 0.18

    // MARK: Tuning: a screenshot's flight

    /// A screenshot's card copied on another display comes in from the right edge of the line's: it starts just past
    /// that edge and slides in, already whole (it was only out of view). A card that starts on the display (at the
    /// pointer) first fades in there, growing from 94 % for this long …
    static let flightAppear = 0.1, flightStartScale = 0.94
    /// … then it flies to its spot on the line. On each axis a spring chases a critically damped lead spring that
    /// chases the spot, so the card leaves from rest, speeds up and slows toward the line, with no fixed duration; it
    /// adapts when the spot moves (the line spreading out, other cards making room). Across is quicker than up (it is
    /// over its spot well before the pin reaches the string), so the path is an arc (about 230 pt off the straight line
    /// on this Mac's display) that passes under the line and rises into its spot from below, clear of its neighbours.
    static let flightAcrossResponse = 0.28, flightAcrossDamping = 0.8, flightUpResponse = 0.41, flightUpDamping = 0.75
    /// A long flight is slowed down as a whole (both responses stretched alike, so its path keeps its shape) until it
    /// never moves faster than this, in points per second (about 85 pt a frame at 120 Hz at its very fastest, for a
    /// few frames mid-flight). From the right edge to the line's first spot on this Mac's display it takes about
    /// 0.47 s at the springs' own pace (it was 1.55 s, slowed to 2,800 pt/s, which read as sluggish); on a 3008 pt
    /// display the limit keeps it to about 0.8 s.
    static let flightTopSpeed = 10500.0
    /// The up spring aims this far above the string, so the pin meets the string still rising (about 350 pt/s) and
    /// the string gives under it (about 6 pt), instead of the card creeping the last points.
    static let flightRise = 16.0
    /// A hidden line starts out of the notch this long before the card is due at the string (from a dry run of the
    /// flight at take-off): the line takes about 0.2 s to come out, so it is out and still for the card's last
    /// approach and the string drops to meet the card.
    static let flightLineLead = 0.36
    /// A card this far below the line still aims across at its spot on the line as it will hang, not as it is now.
    static let flightNearReach = 250.0
    /// In the air the pin's acceleration swings the card this much as hard as on the line (it leans with the flight).
    static let flightSwing = 0.5
    /// The pin catches the line once it is this close under the string (it moves about 1.5 pt a substep there) and this
    /// close to its spot, with the line mostly out (it may still be falling into its sag: then it carries the card down
    /// with it). A pin that reaches the string a little wide of its spot (up to `catchWide`) is caught too, and slides
    /// the rest of the way along the string, rather than rising through it …
    static let catchReach = 0.5, catchSide = 14.0, catchWide = 42.0, catchOut = 0.8
    /// … or this long after it was due, whatever happens.
    static let flightGiveUp = 1.5

    // MARK: State

    var geometry: ClotheslineGeometry { didSet { layout() } }
    var reduceMotion: Bool {
        didSet {
            guard reduceMotion != oldValue else { return }
            // Start the fades from what is on screen now.
            fade = state == .hidden ? 0 : 1
            reflowStart = nil
            ghostReflowAt = nil
            for id in Array(cards.keys) { cards[id]?.reflowAt = nil; cards[id]?.reflowSnapped = false }
            // A card on its way back to its place is put there.
            for (id, c) in cards where c.aloft {
                cards[id]?.aloft = false; cards[id]?.slot.snap(); cards[id]?.drop.snap()
            }
            // Cards in the air are put on the line at once (they fade in there).
            if reduceMotion && cards.values.contains(where: { $0.flight != nil }) {
                for (id, c) in cards where c.flight != nil { cards[id] = Self.grounded(c) }
                beginReveal(hold: 0, freshPointer: false)
            }
        }
    }
    /// How wide each file's card is (the view knows the thumbnails). Default: a document card.
    var widthFor: (URL) -> CGFloat = { _ in ClotheslineCardMetrics.iconMatWidth }
    /// Whether a file's picture is ready (the view knows); a card waits up to `pictureWait` for it before dropping.
    var pictureReady: (URL) -> Bool = { _ in true }
    /// Whether a file still exists (tests replace it).
    var fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    /// Whether VoiceOver is running (the line then stays longer after new files arrive).
    var voiceOverRunning: () -> Bool = { false }
    /// The card VoiceOver or the keyboard focus is on: the line stays out while there is one.
    var accessibilityFocus: UUID? { willSet { catchUp() } }
    /// Called after the files change (cards added or removed, a file renamed).
    var onItemsChange: (() -> Void)?
    /// Called after the state changes.
    var onStateChange: ((State) -> Void)?

    private(set) var state: State = .hidden {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    private(set) var items: [ClotheslineItem] = []
    private(set) var cards: [UUID: Card] = [:]
    /// Cards being removed (they rise and fade), drawn under the others.
    private(set) var leavingOrder: [UUID] = []
    /// The string's spread: 0 = both ends gathered in the notch, 1 = spanning the display.
    private(set) var line = ClotheslineSpring(0, damping: lineDamping, response: lineResponse)
    /// The string's height: 0 = pulled up taut into the notch, 1 = hanging in its sag.
    private(set) var fall = ClotheslineSpring(0, damping: fallDamping, response: fallResponse)
    private(set) var sag = ClotheslineSpring(0, damping: sagDamping, response: sagResponse)
    /// Reduce Motion: overall opacity, moving linearly toward `fadeTarget`.
    private(set) var fade: Double = 0
    private var fadeTarget: Double = 0
    var scroller = ClotheslineScroller()
    /// Engine time in seconds.
    private(set) var time: Double
    private var remainder: Double = 0

    // Timeline
    private(set) var holdUntil: Double = 0
    private(set) var pendingArrivals: Set<UUID> = []
    private(set) var lastArrival: Double?
    private(set) var pointer: CGPoint?
    /// The pointer has moved since the line last came out. Until it does, it doesn't hold the line out or hover a
    /// card (a pointer that was resting on a toolbar when a file was hung must not keep the line there).
    private(set) var pointerFresh = false
    private(set) var pointerInBand = false
    private(set) var pointerLeftAt: Double?
    /// The current reveal turned round a retracting line (its fall is a little slower).
    private var caughtMidRetract = false
    private(set) var notchEnteredAt: Double?
    /// Where the current rest in the notch zone began.
    private(set) var notchAnchor: CGPoint?
    private(set) var hoveredCard: UUID?
    private(set) var pressedCard: UUID?
    /// The card picked with a click (`select`): it wears the selection ring and the panel has the keyboard for it.
    private(set) var selectedCard: UUID?
    /// One of the line's cards is being dragged in a drag session (its file, out of the line's area). The line goes
    /// when the drag is away from it, like any drag (`dragLeaveGrace`), and comes back for it at the notch or over its
    /// area.
    var isDragging = false {
        willSet { catchUp() }
        didSet { if !isDragging && oldValue { restartLeave() } }
    }
    var isMenuOpen = false {
        willSet { catchUp() }
        didSet { if !isMenuOpen && oldValue { restartLeave() } }
    }
    /// The pointer, nothing in hand now, counts as having left the band from now (when it is outside it).
    private func restartLeave() {
        pointerLeftAt = pointerInBand ? nil : time
        leftWhileDragging = false
    }
    /// A mouse button is held for a drag that didn't start on a card (a file dragged from Finder toward the notch, a
    /// window moved by its title). While it lasts the pointer doesn't drop the line at the notch, catch a retracting
    /// line or hover a card, so the line never comes down under a drag meant for another app.
    var otherDrag = false {
        didSet { if otherDrag { notchEnteredAt = nil; hoveredCard = nil } }
    }
    /// The time now (live: the controller's clock). A change from outside first brings the engine up to now, so a
    /// change made after a quiet spell (the clock stopped, the engine's time behind) starts moving from the moment it
    /// happens instead of being played out at once as catch-up.
    var currentTime: (() -> Double)?
    private var advancing = false
    private func catchUp() {
        guard !advancing, let now = currentTime?() else { return }
        advance(to: now)
    }
    /// Keeps the line out regardless of the timing rules (tests and previews; a "pin" later).
    var holdOpen = false
    /// The tilt the scroll velocity asks of every card this substep, in degrees (tests).
    private(set) var scrollTilt = 0.0
    /// Counts state transitions into revealing, for tests.
    private(set) var revealCount = 0
    /// After an explicit retract with the pointer in the notch zone or on the line, it has to leave first.
    private var notchNeedsExit = false
    private var catchNeedsExit = false
    private var lastScrollInput = -Double.infinity
    private var wasScrolling = false
    /// Reduce Motion: when every card started fading out to change places (new files from a job with the line
    /// scrolled; nil: not changing places). Cards that change places on their own (the gap moving under a drag) fade
    /// one by one (`Card.reflowAt`).
    private(set) var reflowStart: Double?
    /// Reduce Motion: when the cards around the ghost started fading out to make room for it. It moves to its new
    /// place once they have faded (it stays fully shown; a ghost that is just appearing waits for the room).
    private(set) var ghostReflowAt: Double?
    private var reflowSnapped = false
    /// Reduce Motion: the scroll goes back to the newest card once the cards have faded out.
    private var scrollResetPending = false
    /// Strings dips under landing pins this substep: (x, depth).
    private var dips: [(x: Double, depth: Double)] = []

    // Dropping files
    /// A drag of files (from Finder, another app or a YummyOrange window) is under way: the files on the drag
    /// pasteboard. nil when there is none (or the drag holds no files: that is `otherDrag`).
    private(set) var fileDrag: [URL]?
    /// The dragged files are over the line while it is out (first the notch zone, the string or a card, then anywhere
    /// over its area): the line takes them. The ghost shows where they will hang, the cards open a gap there and the
    /// string glows brighter. A card moved along the string by hand opens the gap the same way.
    private(set) var dropHover = false
    /// Where the files will hang while `dropHover` (an index into `items`).
    private(set) var dropIndex: Int?
    /// The ghost card's slot (content coordinates, like a card's), how much of it shows (0…1) and its width.
    private(set) var ghostSlot = ClotheslineSpring(0, damping: ghostDamping, response: ghostResponse)
    private(set) var ghostShow = ClotheslineSpring(0, damping: ghostShowDamping, response: ghostShowResponse)
    private(set) var ghostWidth: CGFloat = ClotheslineCardMetrics.iconMatWidth
    /// The string's extra brightness while it can take the files (0…1).
    private(set) var dropGlow = ClotheslineSpring(0, damping: 1, response: dropGlowResponse)
    /// The files have been over the line under this drag: from then on its whole area keeps them, and they catch it on
    /// its way into the notch.
    private(set) var dropSeen = false
    /// When the button went up over the line (the drop is on its way); nil otherwise.
    private(set) var dragReleasedAt: Double?
    /// The source offers no operation the line answers (a copy-only drag): the drag still goes to the panel, so the
    /// line hears when that changes, but nothing shows that it would hang, and a release there ends the drag.
    private(set) var dropRefused = false
    /// Promised files were let go over the line and are being written (until this time at most): the gap stays open
    /// and the ghost waits in it.
    private(set) var promisedUntil: Double?
    /// The card of the last drop that takes over from the ghost: the ghost stays where the card hangs until the card
    /// has faded in over it.
    private(set) var ghostHandoff: UUID?
    /// The hand's horizontal speed during the drag (pt/s, low-passed) and its last sample: dropped cards start
    /// swinging the way the hand was going.
    private(set) var dragVelocityX = 0.0
    private(set) var dragVelocityY = 0.0
    private var lastDragSample: (x: Double, y: Double, t: Double)?
    /// Drops so far (tests).
    private(set) var dropCount = 0
    /// The pointer left the band while it carried something (files or a card): the line goes `dragLeaveGrace` after,
    /// not `retractAfterLeave`.
    private(set) var leftWhileDragging = false

    // Moving a card along the string
    /// A card picked up by hand: moved along the string (lifted: it hangs from its pin under the pointer, its
    /// neighbours open a gap where it will go), or taken out of the line's area (`out`: a drag session carries its file,
    /// to a Finder folder or back onto the line). nil when no card is in the hand.
    struct CardDrag: Equatable {
        let id: UUID
        /// The pointer's offset from the card's pin where it was picked up: the pin keeps it (1:1 from there).
        let grab: CGPoint
        var out = false
    }
    private(set) var cardDrag: CardDrag?
    /// A card that changed places by hand, or by Move Left / Move Right: where it was and where it is now (indices into
    /// `items`).
    struct CardMove: Equatable {
        let id: UUID
        let from: Int
        let to: Int
        var moved: Bool { from != to }
    }

    struct Card {
        let id: UUID
        var width: CGFloat
        var slot: ClotheslineSpring
        var drop: ClotheslineSpring
        /// The string's dip under this card's pin (points, down).
        var dip = ClotheslineSpring(0, damping: ClotheslineEngine.dipDamping, response: ClotheslineEngine.dipResponse)
        /// When the card may start dropping onto the line; nil when it is already hanging.
        var dropStart: Double?
        /// When it actually started (it also waits for the card before it in its batch and for its picture).
        var startedAt: Double?
        /// The card before this one in its batch (it drops `cascade` after that one starts).
        var after: UUID?
        /// Waiting for the thumbnail until this time (nil: the picture is there).
        var pictureDeadline: Double?
        var arrived = true
        var angle = 0.0
        var spin = 0.0
        /// A per-file factor on the pendulum's response (cards of different size swing at slightly different tempos).
        var jitter = 1.0
        var lift = ClotheslineSpring(0, damping: 1, response: 0.15)
        var press = ClotheslineSpring(0, damping: 1, response: 0.08)
        var leaving = false
        var leave = ClotheslineSpring(0, damping: 1, response: 0.2)
        /// Dropped by hand: it starts where the ghost hangs, at the ghost's tilt, and cross-fades in over it (several
        /// files fan out from there to their slots), instead of being put in its slot before it appears.
        var fromGhost = false
        /// Reduce Motion: when this card started fading out to change places (nil: it isn't), and whether it has
        /// moved to its new place yet (it fades back in there).
        var reflowAt: Double?
        var reflowSnapped = false
        var lastX: Double?
        var smoothVX = 0.0
        var lastSmoothVX = 0.0
        var accel = 0.0
        var targetAngle = 0.0
        /// The pivot this substep (scene coordinates).
        var pivotX = 0.0
        var pivotY = 0.0
        /// A screenshot's card on its way up to the line; nil once the pin has caught the line (or for any other file).
        var flight: Flight?
        /// In the hand (`cardDrag`): its pin follows the pointer, off the string.
        var held = false
        /// Let go and on its way to its place: its pin carries the hand's speed there until the string catches it
        /// (it is drawn in the air until then, like a flying card), and whether it comes up to the string from below.
        var aloft = false
        var risesToString = false
        /// Back from a drag that ended away from the line: it fades in at its place from this time (nil: it doesn't).
        var returnedAt: Double?

        var isWaiting: Bool { dropStart != nil && startedAt == nil }
    }

    /// The flight of a screenshot's card: where its pin is, on two axes, each a spring that chases a lead spring
    /// that chases the card's spot on the line.
    struct Flight {
        /// Where the pin starts, in scene coordinates.
        var origin: CGPoint
        /// It starts off the display (copied on another display, it comes in from the edge), so it doesn't fade in.
        var entering: Bool
        var x: ClotheslineSpring
        var y: ClotheslineSpring
        var leadX: ClotheslineSpring
        var leadY: ClotheslineSpring
        /// When it left the origin (nil: still appearing there, or waiting for its picture).
        var launchedAt: Double?
        /// When a hidden line starts out to meet it, and when it is caught whatever happens (set at take-off).
        var revealAt: Double?
        var giveUpAt: Double?
        /// The string's height under the pin last substep (how fast the string moves there, at the catch).
        var lastUnder: Double?

        init(origin: CGPoint, entering: Bool = false) {
            self.origin = origin
            self.entering = entering
            let ox = Double(origin.x), oy = Double(origin.y)
            x = ClotheslineSpring(ox, damping: ClotheslineEngine.flightAcrossDamping, response: ClotheslineEngine.flightAcrossResponse)
            leadX = ClotheslineSpring(ox, damping: 1, response: ClotheslineEngine.flightAcrossResponse)
            y = ClotheslineSpring(oy, damping: ClotheslineEngine.flightUpDamping, response: ClotheslineEngine.flightUpResponse)
            leadY = ClotheslineSpring(oy, damping: 1, response: ClotheslineEngine.flightUpResponse)
        }

        /// Both responses stretched alike: the same path, taken more slowly.
        mutating func stretch(_ s: Double) {
            x.response *= s; leadX.response *= s
            y.response *= s; leadY.response *= s
        }

        /// One substep toward a pin goal (the up spring aiming `rise` above it).
        mutating func step(_ h: Double, goalX: Double, goalY: Double, rise: Double) {
            leadX.target = goalX
            leadY.target = goalY - rise
            leadX.step(h)
            leadY.step(h)
            x.target = leadX.value
            y.target = leadY.value
            x.step(h)
            y.step(h)
        }
    }

    /// A dry run of a flight from `from` to a pin spot on a still line (the line as it will hang): its top speed, and
    /// how long after take-off the pin would reach the string there. A flight is a linear system, so with both
    /// responses stretched by s it takes s times as long at 1/s of the speed.
    static func flightPlan(from a: CGPoint, to spot: CGPoint) -> (peak: Double, arrival: Double) {
        var f = Flight(origin: a)
        let gx = Double(spot.x), gy = Double(spot.y)
        var peak = 0.0, t = 0.0
        while t < 8 {
            f.step(substep, goalX: gx, goalY: gy, rise: flightRise)
            t += substep
            peak = max(peak, hypot(f.x.velocity, f.y.velocity))
            if abs(f.x.value - gx) <= catchSide && f.y.value - gy <= catchReach { break }
        }
        return (peak, t)
    }

    init(geometry: ClotheslineGeometry, reduceMotion: Bool = false, time: Double = 0) {
        self.geometry = geometry
        self.reduceMotion = reduceMotion
        self.time = time
        scroller.dimension = Double(geometry.rightEndX - geometry.leftEndX)
    }

    // MARK: Files

    var urls: [URL] { items.map(\.url) }

    /// Hangs new files: newest first from the left, at most 50 (the oldest drop off). A file already on the line
    /// moves to the front. The line drops out of the notch if it was hidden, the cards drop onto it one after another,
    /// and the line stays 2 s after the last one arrives.
    ///
    /// `origin` (scene coordinates, the pin's starting point): the cards fly from there instead (a copied screenshot,
    /// from the pointer). Each starts at the origin (off the display it slides in; on it, it fades in), flies up along
    /// an arc to its spot, and the pin catches the line, which drops out of the notch to meet it.
    /// Reduce Motion: no flight, the cards fade in on the line.
    func hang(_ newURLs: [URL], from origin: CGPoint? = nil) {
        // URLs stay as given (thumbnail caches are keyed by path); duplicates are found through resolved paths.
        // At most `capacity` of them: more would only make cards for files that fall off at once.
        var seen = Set<String>()
        let fresh = Array(newURLs.map { $0.absoluteURL }.filter { fileExists($0) && seen.insert(Self.identity($0)).inserted }
            .prefix(Self.capacity))
        guard !fresh.isEmpty else { return }
        pruneMissing()
        let comingOut = state == .hidden || line.value < 0.5
        // Reduce Motion with cards already showing: they fade out to make room, then everything fades in.
        let reflowing = reduceMotion && state != .hidden && fade > 0 && !items.isEmpty
        let paths = Set(fresh.map(Self.identity))
        // A file hung again leaves its old place (and drops in again at the front).
        let again = items.filter { paths.contains(Self.identity($0.url)) }.map(\.id)
        items.removeAll { paths.contains(Self.identity($0.url)) }
        discard(again)
        let added = fresh.map { ClotheslineItem(id: UUID(), url: $0, reference: Self.reference(for: $0)) }
        items = added + items
        if items.count > Self.capacity {
            let dropped = items[Self.capacity...].map(\.id)
            items.removeLast(items.count - Self.capacity)
            discard(dropped)
        }
        let flying = origin != nil && !reduceMotion
        let start = time + (comingOut && !reduceMotion && !flying ? Self.dropDelayFromHidden : 0) + (reflowing ? Self.reflowFade : 0)
        let pictureBy = max(start, time + Self.pictureWait)
        var previous: UUID?
        for (i, item) in added.enumerated() {
            var card = Card(id: item.id, width: widthFor(item.url),
                            slot: ClotheslineSpring(0, damping: Self.slotDamping, response: Self.slotResponse),
                            drop: ClotheslineSpring(-Self.dropHeight, target: 0, damping: Self.dropDamping, response: Self.dropResponse))
            card.dropStart = start + Double(i) * Self.cascade
            card.after = previous
            previous = item.id
            if !pictureReady(item.url) { card.pictureDeadline = pictureBy + Double(i) * Self.cascade }
            card.arrived = false
            card.jitter = Self.jitter(for: item.url)
            // Each card falls slightly turned, alternating, so it swings when the pin catches the line.
            card.angle = ClotheslineMath.radians(i % 2 == 0 ? 7 : -6)
            if reduceMotion { card.angle = 0; card.drop.snap() }
            if flying, let origin {
                // Upright; it lands with no drop of its own (the flight brings it).
                // A card that starts wholly off the display slides in rather than fading in.
                let half = Double(card.width) / 2
                let off = Double(origin.x) - half >= Double(geometry.width) || Double(origin.x) + half <= 0
                card.flight = Flight(origin: origin, entering: off)
                card.angle = 0
                card.drop = ClotheslineSpring(0, damping: Self.dropDamping, response: Self.dropResponse)
                card.pivotX = Double(origin.x)
                card.pivotY = Double(origin.y)
            }
            cards[item.id] = card
            pendingArrivals.insert(item.id)
        }
        layout(newIDs: Set(added.map(\.id)))
        // Back to the newest card. While any of the line can be seen (a retract that is turned round included) the
        // cards glide there; Reduce Motion moves them while they are faded out; hidden, they are simply put there.
        if reduceMotion && reflowing {
            if abs(scroller.offset) > 0.01 || !scroller.isIdle {
                beginReflow()
                scrollResetPending = true
            }
        } else {
            scroller.scroll(to: 0, animated: state != .hidden && !reduceMotion)
        }
        onItemsChange?()
        // A hidden line waits for the card to take off, then drops to meet it (step); one that is out, or on its way
        // in, comes out now.
        if flying && state == .hidden { return }
        beginReveal(hold: 0, freshPointer: false)
    }

    /// A card in the air put straight onto the line at its spot (Reduce Motion came on during its flight).
    private static func grounded(_ card: Card) -> Card {
        var c = card
        c.flight = nil
        c.slot.snap()
        c.drop = ClotheslineSpring(0, damping: dropDamping, response: dropResponse)
        c.angle = 0
        c.spin = 0
        return c
    }

    /// The cards in the air, in draw order.
    var flyingCards: [UUID] { drawOrder.filter { cards[$0]?.flight != nil } }

    /// Whether any card is in the air (or about to appear at its origin).
    var hasFlights: Bool { cards.values.contains { $0.flight != nil } }

    /// The same file however it is spelled (/tmp vs /private/tmp, ./ and ..).
    static func identity(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }

    static func reference(for url: URL) -> NSURL? {
        guard url.isFileURL else { return nil }
        return (url as NSURL).fileReferenceURL() as NSURL?
    }

    /// 0.95…1.05 from the file's name: a little variety in the swing (deterministic, so previews repeat exactly).
    static func jitter(for url: URL) -> Double {
        let sum = url.lastPathComponent.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) & 0xFFFF }
        return 0.95 + 0.1 * Double(sum % 101) / 100
    }

    /// Takes a file off the line (it lifts away; its neighbours close the gap). The line retracts when it is empty.
    func remove(_ id: UUID) {
        catchUp()
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items.remove(at: index)
        pendingArrivals.remove(id)
        startLeaving(id)
        if id == welcomeID { welcomeID = nil; onWelcomeRemoval?(true) }
        layout()
        onItemsChange?()
        if items.isEmpty { holdUntil = time + 0.25 }
    }

    /// Takes every file off the line, then retracts it.
    func clear() {
        catchUp()
        let ids = items.map(\.id)
        items.removeAll()
        pendingArrivals.removeAll()
        ids.forEach(startLeaving)
        if let w = welcomeID, ids.contains(w) { welcomeID = nil; onWelcomeRemoval?(true) }
        layout()
        onItemsChange?()
        holdUntil = time + 0.25
    }

    /// Puts a card taken off the line back where it was (⌘Z right after Delete), the way it went, reversed: one still
    /// lifting away turns round and comes back down from where it is; one already gone comes down from where it went,
    /// fading in. The welcome card is the welcome card again. Returns whether it went back (not on a line that is away,
    /// nor for a file that is gone).
    @discardableResult
    func restore(_ item: ClotheslineItem, at index: Int, welcome: Bool = false) -> Bool {
        catchUp()
        guard state == .shown || state == .revealing, cardDrag == nil, !items.contains(where: { $0.id == item.id }),
              fileExists(item.url) else { return false }
        items.insert(item, at: min(max(0, index), items.count))
        if var c = cards[item.id], c.leaving {
            c.leaving = false
            c.leave.target = 0
            c.drop.target = 0
            if reduceMotion { c.drop.snap() }
            cards[item.id] = c
            leavingOrder.removeAll { $0 == item.id }
        } else {
            var c = Card(id: item.id, width: widthFor(item.url),
                         slot: ClotheslineSpring(0, damping: Self.slotDamping, response: Self.slotResponse),
                         drop: ClotheslineSpring(reduceMotion ? 0 : -Self.dropHeight * 0.6, target: 0,
                                                 damping: Self.dropDamping, response: Self.dropResponse))
            c.leave = ClotheslineSpring(1, target: 0, damping: 1, response: 0.2)
            c.jitter = Self.jitter(for: item.url)
            cards[item.id] = c
        }
        if welcome { welcomeID = item.id; onWelcomeRemoval?(false) }
        layout(newIDs: cards[item.id]?.leave.value == 1 ? [item.id] : [])
        onItemsChange?()
        return true
    }

    /// Empties the line at once with nothing left moving (the feature is being turned off).
    func reset() {
        items.removeAll()
        cards.removeAll()
        leavingOrder.removeAll()
        pendingArrivals.removeAll()
        fileDrag = nil; dragReleasedAt = nil; dropSeen = false; lastDragSample = nil; dropRefused = false; promisedUntil = nil
        cardDrag = nil
        finishHidden()
        notchEnteredAt = nil; notchAnchor = nil; pointerFresh = false; pointerInBand = false
        layout()
        onItemsChange?()
    }

    private func startLeaving(_ id: UUID) {
        guard var card = cards[id] else { return }
        // Never seen yet, in the air (the flight overlay lets it go) or in the hand: nothing to animate.
        if card.isWaiting || state == .hidden || card.flight != nil || card.held {
            cards[id] = nil
            leavingOrder.removeAll { $0 == id }
            return
        }
        card.leaving = true
        card.leave.target = 1
        card.drop.target = -Self.dropHeight * 0.6
        if reduceMotion { card.drop.snap() }
        cards[id] = card
        leavingOrder.removeAll { $0 == id }
        leavingOrder.append(id)
    }

    /// Where an item's file is now: where it was, or where a rename or move took it; nil when it is gone. Like the
    /// Float shelf, a file in the Trash is gone.
    private func location(of item: ClotheslineItem) -> URL? {
        if fileExists(item.url) { return item.url }
        if let moved = item.reference?.filePathURL, moved.path != item.url.path, fileExists(moved),
           !moved.pathComponents.contains(".Trash") { return moved }
        return nil
    }

    /// Whether any file on the line is still there, so a reveal would show something. It changes nothing (the Show
    /// Clothesline menu item asks it each time the menu opens, on the main thread, before AppKit shows the menu). A
    /// file on another volume (an external disk, a server) counts as there without a look: a look at a disk that is
    /// asleep, or a server that went away, can take seconds, and the reveal drops what is gone anyway.
    var hasFilesOnDisk: Bool { items.contains { Self.isOnOtherVolume($0.url) || location(of: $0) != nil } }

    /// Under /Volumes (external disks, disk images, servers) or a network mount point, not on the startup volume.
    static func isOnOtherVolume(_ url: URL) -> Bool {
        ["/Volumes/", "/Network/", "/net/"].contains { url.path.hasPrefix($0) }
    }

    /// Follows renamed files and drops files that no longer exist (done whenever the line reveals, and before an
    /// action on a card).
    func pruneMissing() {
        catchUp()
        var gone: [UUID] = []
        var renamed = false
        for i in items.indices where !fileExists(items[i].url) {
            if let moved = location(of: items[i]) {
                items[i].url = moved
                renamed = true
            } else {
                gone.append(items[i].id)
            }
        }
        if !gone.isEmpty {
            let ids = Set(gone)
            items.removeAll { ids.contains($0.id) }
            discard(gone)
            layout()
        }
        if !gone.isEmpty || renamed { onItemsChange?() }
    }

    /// The file behind a card before acting on it: its current URL (following a rename), or nil when it is gone
    /// (its card then lifts away).
    func currentURL(of id: UUID) -> URL? {
        guard let item = items.first(where: { $0.id == id }) else { return nil }
        if fileExists(item.url) { return item.url }
        pruneMissing()
        return items.first { $0.id == id }?.url
    }

    /// Cards whose files left the line: gone at once while hidden, lifted away while the line is out.
    private func discard(_ ids: [UUID]) {
        for id in ids {
            pendingArrivals.remove(id)
            startLeaving(id)
        }
    }

    /// Card width changed (a thumbnail arrived): neighbours slide to make room.
    func setWidth(_ width: CGFloat, for id: UUID) {
        catchUp()
        guard var card = cards[id], abs(card.width - width) > 0.5 else { return }
        card.width = width
        cards[id] = card
        layout()
    }

    /// The card's thumbnail is ready: it may drop now (if it was waiting for it).
    func pictureArrived(for id: UUID) {
        catchUp()
        cards[id]?.pictureDeadline = nil
    }

    /// The cards hanging on the string: every file's but the one in the hand.
    var lineItems: [ClotheslineItem] {
        guard let d = cardDrag else { return items }
        return items.filter { $0.id != d.id }
    }

    /// The card in the hand while it is moved along the string (not while a drag session carries its file).
    var liftedCard: UUID? { cardDrag.flatMap { $0.out ? nil : $0.id } }

    /// The card in the hand left the line's area: the view hands its file to a drag session (`cardWentOut`).
    var cardLeftArea: Bool { liftedCard != nil && !dropHover }

    /// A card picked up by hand whose file is gone (pruned) is no longer in the hand.
    private func validateCardDrag() {
        guard let d = cardDrag, !items.contains(where: { $0.id == d.id }) else { return }
        cardDrag = nil
        cards[d.id]?.held = false
        if fileDrag == nil { dropHover = false; dropIndex = nil }
    }

    /// Slot targets: newest first from the left, with gaps. Cards not on the line yet start right in their slot.
    /// While dragged files (or a card in the hand) are over the line, the cards from `dropIndex` on make room for them;
    /// the card in the hand has no slot until it is let go.
    private func layout(newIDs: Set<UUID> = []) {
        validateCardDrag()
        // A selected card (or the welcome card) whose file left the line is no longer selected (or the welcome card).
        if let s = selectedCard, !items.contains(where: { $0.id == s }) { selectedCard = nil }
        if let w = welcomeID, !items.contains(where: { $0.id == w }) { welcomeID = nil }
        var u = Double(ClotheslineCardMetrics.leadingPad)
        var moved: [UUID] = []
        let line = lineItems
        let gapAt = showsGap ? dropIndex.map { min($0, line.count) } : nil
        let room = Double(ghostWidth) + Double(ClotheslineCardMetrics.gap)
        for (i, item) in line.enumerated() {
            if gapAt == i { u += room }
            guard var card = cards[item.id] else { continue }
            let w = Double(card.width)
            let target = u + w / 2
            let unseen = newIDs.contains(item.id) || (card.isWaiting && !card.fromGhost)
            if !unseen && abs(card.slot.target - target) > 0.5 { moved.append(item.id) }
            card.slot.target = target
            if unseen { card.slot.snap() }
            cards[item.id] = card
            u += w + Double(ClotheslineCardMetrics.gap)
        }
        // A ghost after the last card makes the content longer too (so a full line can scroll to it).
        if let gapAt, gapAt == line.count, !line.isEmpty { u += room }
        if reduceMotion {
            if !moved.isEmpty && state != .hidden && fade > 0 {
                // Only the cards that change places fade out, jump and fade back in; the rest of the line stays as it
                // is (a gap moving under a drag swaps one card at a time). The ghost moves while they are faded out.
                moved.forEach(beginReflow)
                if ghostReflowAt == nil && (dropHover || promisedUntil != nil || ghostShow.value > 0.002) { ghostReflowAt = time }
            } else if reflowStart == nil {
                for (id, c) in cards where c.reflowAt == nil { cards[id]?.slot.snap() }
            }
        }
        let content = u - Double(ClotheslineCardMetrics.gap) + Double(ClotheslineCardMetrics.trailingPad)
        let lineLength = Double(geometry.rightEndX - geometry.leftEndX)
        scroller.dimension = lineLength
        scroller.maxOffset = max(0, line.isEmpty ? 0 : content - lineLength)
        scroller.boundsChanged()
    }

    /// Reduce Motion: the cards fade out, change places, fade in (no sliding). A reflow already fading back in turns
    /// round from the opacity it has.
    private func beginReflow() {
        if let r = reflowStart, reflowSnapped {
            let shown = min(1, (time - r - Self.reflowFade) / Self.reflowFade)
            reflowStart = time - (1 - max(0, shown)) * Self.reflowFade
        } else if reflowStart == nil {
            reflowStart = time
        }
        reflowSnapped = false
    }

    /// Reduce Motion: one card fades out, changes places, fades in; one already fading back in turns round from the
    /// opacity it has.
    private func beginReflow(_ id: UUID) {
        guard var c = cards[id] else { return }
        if let r = c.reflowAt, c.reflowSnapped {
            let shown = min(1, (time - r - Self.reflowFade) / Self.reflowFade)
            c.reflowAt = time - (1 - max(0, shown)) * Self.reflowFade
        } else if c.reflowAt == nil {
            c.reflowAt = time
        }
        c.reflowSnapped = false
        cards[id] = c
    }

    /// Whether any card (or the ghost) is changing places under Reduce Motion (tests).
    var isReflowing: Bool { reflowStart != nil || ghostReflowAt != nil || cards.values.contains { $0.reflowAt != nil } }

    var contentWidth: Double {
        guard !items.isEmpty else { return 0 }
        return Double(ClotheslineCardMetrics.leadingPad) + items.reduce(0) { $0 + Double(cards[$1.id]?.width ?? 0) }
            + Double(ClotheslineCardMetrics.gap) * Double(items.count - 1) + Double(ClotheslineCardMetrics.trailingPad)
    }

    // MARK: Showing and hiding

    /// Drops the line showing every card (a menu item). It stays 2 s (6 s while VoiceOver runs, as for new files),
    /// then follows the pointer rules.
    func reveal() { beginReveal(hold: Self.holdAfterArrival * (voiceOverRunning() ? 3 : 1), freshPointer: false) }

    /// Gathers the line into the notch now. A pointer resting in the notch or on a card has to leave before it can
    /// bring the line back.
    func retract() {
        guard state == .revealing || state == .shown else { return }
        if pointer.map({ geometry.hoverZone.contains($0) }) ?? false { notchNeedsExit = true; notchEnteredAt = nil; notchAnchor = nil }
        if pointerInBand { catchNeedsExit = true }
        beginRetract()
    }

    private func beginReveal(hold: Double, freshPointer: Bool) {
        pruneMissing()
        // An empty line comes out only for a file drag (to show where the files will hang).
        guard !items.isEmpty || fileDrag != nil else { return }
        holdUntil = max(holdUntil, time + hold)
        if state == .hidden || state == .retracting {
            caughtMidRetract = state == .retracting
            state = .revealing
            revealCount += 1
            line.target = 1
            fadeTarget = 1
            pointerFresh = freshPointer
            if reduceMotion {
                line.value = 1; line.velocity = 0; line.target = 1
                fall.value = 1; fall.velocity = 0; fall.target = 1
            }
            updateBand()
            if pointerInBand { pointerLeftAt = nil }
        }
    }

    private func beginRetract() {
        state = .retracting
        fall.target = 0
        fadeTarget = 0
        hoveredCard = nil
        pressedCard = nil
        selectedCard = nil
        updateDrop()
    }

    private func finishHidden() {
        state = .hidden
        line.target = 0; line.snap()
        fall.target = 0; fall.snap()
        sag.value = 0; sag.velocity = 0
        fade = 0
        for id in leavingOrder { cards[id] = nil }
        leavingOrder.removeAll()
        // Nothing is visible: everything comes to rest at once, so the clock can stop. (Cards in the air keep flying;
        // the line comes back out for them.)
        for (id, var c) in cards where c.flight == nil {
            c.slot.snap(); c.lift.snap(); c.press.snap(); c.dip.snap(); c.leave.snap()
            if c.dropStart == nil && c.drop.target == 0 { c.drop.snap() }
            c.angle = c.targetAngle; c.spin = 0
            c.lastX = nil; c.smoothVX = 0; c.lastSmoothVX = 0; c.accel = 0
            c.reflowAt = nil; c.reflowSnapped = false
            if c.aloft { c.aloft = false; c.drop.snap() }
            c.returnedAt = nil
            cards[id] = c
        }
        scroller.settle()
        if scrollResetPending { scroller.scroll(to: 0, animated: false); scrollResetPending = false }
        wasScrolling = false
        reflowStart = nil
        ghostReflowAt = nil
        promisedUntil = nil
        dips = []
        hoveredCard = nil
        pointerLeftAt = nil
        holdUntil = 0
        catchNeedsExit = false
        dropHover = false; dropIndex = nil; ghostHandoff = nil
        ghostShow.target = 0; ghostShow.snap(); ghostSlot.snap(); dropGlow.target = 0; dropGlow.snap()
        selectedCard = nil
    }

    /// Whether the line may retract now.
    var mayRetract: Bool {
        guard state == .shown || state == .revealing else { return false }
        // Dragged files (or a card) over the line, just let go over it, or promised and on their way: it waits for
        // them. So it does for a card in the hand, or on its way back to its place.
        if dropHover || dragReleasedAt != nil || promisedUntil != nil || liftedCard != nil || hasCardAloft { return false }
        if items.isEmpty {
            // An empty line out for a file drag goes a moment after the drag leaves it, like a full one.
            if fileDrag != nil, let left = pointerLeftAt, time < left + leaveGrace { return false }
            return time >= holdUntil
        }
        if holdOpen { return false }
        // A card's drag session no longer holds the line by itself: dragged away from the line, the line goes.
        guard pendingArrivals.isEmpty, time >= holdUntil, !isMenuOpen, !pointerInBand,
              scroller.isIdle, accessibilityFocus == nil, selectedCard == nil else { return false }
        if let left = pointerLeftAt, time < left + leaveGrace { return false }
        return true
    }

    /// How long after the pointer left the band the line goes: a moment for a hand that carried something away,
    /// longer for a pointer passing by.
    private var leaveGrace: Double { leftWhileDragging ? Self.dragLeaveGrace : Self.retractAfterLeave }

    /// A card let go and still on its way to its place on the string.
    var hasCardAloft: Bool { cards.values.contains { $0.aloft } }

    // MARK: Pointer

    /// The pointer moved (scene coordinates; nil when it is on another display).
    func pointerMoved(to p: CGPoint?) {
        guard p != pointer else { return }
        pointer = p
        if state != .hidden { pointerFresh = true }
        // The notch itself: the pointer has to stay inside it for half a second (moving inside it is fine; a pass on the
        // way across the menu bar does nothing). Without a notch the zone is a stretch of the menu bar, where menus
        // live, so there the pointer has to stay still too. Nothing else brings the line out under the pointer.
        if let p, geometry.notchCore.contains(p) {
            if notchNeedsExit || otherDrag {
                notchEnteredAt = nil
            } else if let a = notchAnchor, notchEnteredAt != nil, geometry.hasNotch || hypot(p.x - a.x, p.y - a.y) <= Self.restRadius {
                // Still inside (still resting, without a notch).
            } else {
                notchAnchor = p
                notchEnteredAt = time
            }
        } else {
            notchEnteredAt = nil
            notchAnchor = nil
            notchNeedsExit = false
        }
        let card = p.flatMap { cardID(at: $0, minAlpha: 0.5) }
        // Cards don't hover under a drag (another app's, files on their way to the line, or one of its own cards).
        let carrying = fileDrag != nil || cardDrag != nil
        hoveredCard = state == .retracting || state == .hidden || otherDrag || carrying ? nil : card
        if pressedCard != nil && card != pressedCard { pressedCard = nil }
        if let p, carrying { sampleDrag(p) }
        // A pointer that moves onto a card while the line is going away catches it. (Only a real move: cards
        // sliding under a still pointer don't.) Files (or a card) brought back into the line's area catch a line that
        // is going away under this same drag; once it has gone, only heading back to the notch brings it out.
        if state == .retracting, !catchNeedsExit, !otherDrag {
            if !carrying, let id = card, items.contains(where: { $0.id == id }) {
                beginReveal(hold: 0, freshPointer: true)
                hoveredCard = id
            } else if dragHolds, let p, !geometry.hoverZone.contains(p), isInBand(p) {
                beginReveal(hold: 0, freshPointer: true)
            }
        }
        updateBand()
        updateDrop()
        updateTimeline()
    }

    /// The pointer pressed on (or released from) a card: the card answers on press.
    func setPressed(_ id: UUID?) {
        catchUp()
        pressedCard = id
    }

    /// The band the pointer keeps the line in: the notch zone, a strip along the string and every visible card. While
    /// the line has taken something dragged (`dragHolds`), its whole area (`dropArea`).
    func isInBand(_ p: CGPoint) -> Bool {
        if geometry.hoverZone.contains(p) { return true }
        guard state != .hidden else { return false }
        // Files that came onto the line (or a card in the hand) can be let go anywhere over it: the whole width of the
        // string, from the top of the screen down past the cards. Moving them a little off the string, or down over
        // the cards, never sends the line away from under them.
        if dragHolds && dropArea(holding: dropHover).contains(p) { return true }
        let ends = lineEnds()
        let x = Double(p.x)
        if x >= Double(ends.left.x) - 16 && x <= Double(ends.right.x) + 16 {
            let y = stringY(at: ClotheslineMath.clamp(x, Double(ends.left.x), Double(ends.right.x)), ends: ends)
            if abs(Double(p.y) - y) <= Self.bandReach { return true }
        }
        // While it shows, the ghost is part of the band: where it hangs and where it is headed (it glides there, and a
        // pointer moving down onto it must not drop out of the band before it arrives).
        if dropHover && !dropRefused {
            for slot in [ghostSlot.value, ghostSlot.target] {
                if let ghost = ghostPose(slot: slot), Self.contains(ghost, p, inflate: 8) { return true }
            }
        }
        return cardID(at: p, inflate: 8, minAlpha: 0.2) != nil
    }

    /// The line has taken something dragged: files that have been over it under this drag, or one of its own cards in
    /// the hand. Its whole area then keeps it (a first approach still has to reach the notch, the string or a card,
    /// so a drag meant for a window under the line's area isn't caught on its way past).
    var dragHolds: Bool { cardDrag != nil || (fileDrag != nil && dropSeen) }

    /// The line's area, in scene coordinates: across the whole width between the string's ends (a margin past each),
    /// from the top of the screen down to the lowest card's foot, at least a card's height under the string's lowest
    /// point (an empty or short line), a margin further; never past the panel. `holding`: the drag is in it, so it
    /// reaches `dropAreaHold` further (no flicker at its edge).
    func dropArea(holding: Bool) -> CGRect {
        let ends = lineEnds()
        let scale = max(0.06, pow(ClotheslineMath.clamp(line.value, 0, 1), 0.9))
        let depth = Double(ClotheslineCardMetrics.matTop + ClotheslineCardMetrics.matHeight)
        var foot = max(Double(ends.apex.y), Double(ends.left.y), Double(ends.right.y)) + depth * scale
        for item in lineItems {
            guard let c = cards[item.id], c.flight == nil, !c.leaving, !c.isWaiting, !c.aloft else { continue }
            let a = abs(c.angle)
            foot = max(foot, c.pivotY + (depth * cos(a) + Double(c.width) / 2 * sin(a)) * scale)
        }
        let margin = Self.dropAreaMargin + (holding ? Self.dropAreaHold : 0)
        let bottom = min(foot + margin, Double(ClotheslineGeometry.panelHeight))
        let left = Double(ends.left.x) - margin, right = Double(ends.right.x) + margin
        return CGRect(x: left, y: 0, width: right - left, height: bottom)
    }

    private func updateBand() {
        let inside = pointer.map { geometry.hoverZone.contains($0) || (pointerFresh && isInBand($0)) } ?? false
        if inside != pointerInBand {
            pointerInBand = inside
            pointerLeftAt = inside ? nil : time
            if !inside {
                catchNeedsExit = false
                leftWhileDragging = fileDrag != nil || cardDrag != nil
            }
        }
    }

    // MARK: Scrolling

    func scroll(_ input: ClotheslineScrollInput) {
        lastScrollInput = time
        scroller.handle(input)
        noteScrollIdle()
    }

    /// When the cards stop moving after a scroll, the 0.6 s after-leave timer starts from then.
    private func noteScrollIdle() {
        let scrolling = !scroller.isIdle
        if wasScrolling && !scrolling { pointerLeftAt = pointerInBand ? nil : time }
        wasScrolling = scrolling
    }

    // MARK: Dropping files

    /// A file drag started or moved on (the files on the drag pasteboard), or ended (nil): dropped elsewhere,
    /// cancelled, or let go away from the line. When it ends the gap closes and the line follows its usual rules (an
    /// empty line goes at once; one with files goes 0.6 s after the pointer leaves it).
    func setFileDrag(_ files: [URL]?) {
        catchUp()
        let files = files.flatMap { $0.isEmpty ? nil : $0 }
        let was = fileDrag
        fileDrag = files
        if let files {
            if was == nil {
                // A new drag: the ghost takes the first file's width; the hand's speed starts from rest. Promised files
                // still on their way from an earlier drop stop holding a gap (they hang at the front when they come).
                ghostWidth = widthFor(files[0])
                lastDragSample = nil
                dragVelocityX = 0
                hoveredCard = nil
                otherDrag = false
                dropRefused = false
                if promisedUntil != nil { promisedUntil = nil; dropIndex = nil; layout() }
            }
            dragReleasedAt = nil
        } else if was != nil {
            dragReleasedAt = nil
            dropSeen = false
            lastDragSample = nil
            dropRefused = false
        }
        updateDrop()
    }

    /// The button went up. Over the line the drop is on its way (AppKit delivers it apart from the mouse-up), so the
    /// drag waits `dropGrace` for it; anywhere else, or when the line refused the drag, the drag is over.
    func fileDragReleased() {
        catchUp()
        guard fileDrag != nil else { return }
        if dropHover && !dropRefused { dragReleasedAt = time } else { setFileDrag(nil) }
    }

    /// The source's operations, as AppKit last reported them: `refused` when the line answers none of them (a
    /// copy-only drag). The ghost, the gap and the glow then go (HIG Drag and drop: show an insertion point only when
    /// the destination can accept the item), but the panel keeps the drag so it hears when that changes.
    func setDropRefused(_ refused: Bool) {
        guard refused != dropRefused else { return }
        catchUp()
        dropRefused = refused
        layout()
        updateDrop()
    }

    /// Whether the line takes the dragged files now (the panel then accepts the drag; everywhere else it lets the
    /// mouse through), or a drag session of one of its own cards (it is hung again where it is let go).
    var acceptsDrop: Bool { dropHover && (fileDrag != nil || cardDrag?.out == true) }

    /// The button went up over the line and the drop hasn't arrived yet.
    var awaitingDrop: Bool { dragReleasedAt != nil }

    /// The gap is open: files the line can take (or a card in the hand) are over it, or promised files are on their
    /// way to it.
    var showsGap: Bool { (dropHover && !dropRefused) || promisedUntil != nil }

    /// The ghost shows in the gap, except for a card moved along the string by hand (the card itself is there, under
    /// the pointer).
    var showsGhost: Bool { showsGap && liftedCard == nil }

    /// The files the ghost stands for: the dragged files, or the file of the line's own card in its drag session.
    var draggedFiles: [URL]? {
        if let fileDrag { return fileDrag }
        guard let d = cardDrag, d.out else { return nil }
        return item(d.id).map { [$0.url] }
    }

    /// The first dragged file's picture arrived: the ghost (and the gap) take its width.
    func dragPicturesChanged() {
        catchUp()
        guard let first = fileDrag?.first else { return }
        let w = widthFor(first)
        guard abs(w - ghostWidth) > 0.5 else { return }
        ghostWidth = w
        if dropHover { updateDropIndex(); layout() }
    }

    /// Shows the ghost and opens the gap while the files are over the line (the notch zone, the string's band, a
    /// card or the ghost itself; then its whole area) and it is out; closes them when they leave. A card in the hand
    /// opens the gap the same way (and its drag session the ghost too).
    private func updateDrop() {
        let out = state == .revealing || state == .shown
        let over = cardDrag != nil ? out && pointerInBand && !isMenuOpen
            : fileDrag != nil && pointerInBand && out && !isDragging && !isMenuOpen
        if over != dropHover {
            dropHover = over
            if over {
                if fileDrag != nil { dropSeen = true }
                let fresh = ghostShow.value < 0.05
                updateDropIndex()
                if fresh { placeFreshGhost() }
            } else if promisedUntil == nil {
                dropIndex = nil
            }
            layout()
        } else if over {
            updateDropIndex()
        }
        ghostShow.target = showsGhost || ghostHandoff != nil ? 1 : 0
        // The string brightens for what it can take from a drag (not for a card only moved along it).
        dropGlow.target = dropHover && !dropRefused && liftedCard == nil ? 1 : 0
    }

    /// A ghost that wasn't showing never flies in from its last place. On a line still coming out of the notch it is
    /// put at its place and rides out with the string (everything starts gathered at the notch, under the pointer). On
    /// a line already out it appears under the pointer (on the string, within the line) and glides from there to where
    /// the files will hang, so the eye is led to the place (HIG Drag and drop: help people predict the result). Reduce
    /// Motion: it appears at its place.
    private func placeFreshGhost() {
        guard !reduceMotion, line.value > 0.9, let x = dragAnchorX else { ghostSlot.snap(); return }
        let half = Double(ghostWidth) / 2
        let lo = contentX(atScreenX: Double(geometry.leftEndX)) + half
        let hi = max(lo, contentX(atScreenX: Double(geometry.rightEndX)) - half)
        ghostSlot.value = ClotheslineMath.clamp(contentX(atScreenX: x), lo, hi)
        ghostSlot.velocity = 0
    }

    /// The screen x the gap follows: the pointer's for dragged files; for a card, its pin's (the pointer holds it by
    /// the place it was grabbed, so the card goes where it hangs, not where the hand is on it).
    private var dragAnchorX: Double? { pointer.map { Double($0.x) - Double(cardDrag?.grab.x ?? 0) } }

    /// Where the pin of the card in the hand is: under the pointer, as far from it as where the card was grabbed.
    var heldPin: CGPoint? {
        guard let d = cardDrag, let p = pointer else { return nil }
        return CGPoint(x: p.x - d.grab.x, y: p.y - d.grab.y)
    }

    /// Picks the slot for the pointer and aims the ghost at it; relays the cards when the slot changes. The ghost
    /// always rests where the files will stay: past the last card that is the place after it, not under the pointer.
    @discardableResult
    private func updateDropIndex() -> Bool {
        guard let x = dragAnchorX else { return false }
        let u = contentX(atScreenX: x)
        let centres = ghostCentres()
        let k = Self.dropSlot(contentX: u, centres: centres, current: dropIndex)
        ghostSlot.target = centres[k]
        guard k != dropIndex else { return false }
        dropIndex = k
        layout()
        return true
    }

    /// The slot whose ghost would sit nearest content x `u` (card k's place if the ghost took it; `centres` has one
    /// more entry than there are cards, the place after the last). Anywhere past the last card is that place. The
    /// current slot is kept unless another is `gapHysteresis` nearer, so the gap never flickers between two.
    static func dropSlot(contentX u: Double, centres: [Double], current: Int?) -> Int {
        guard let last = centres.indices.last else { return 0 }
        func distance(_ i: Int) -> Double { i == last ? max(0, centres[i] - u) : abs(u - centres[i]) }
        var best = 0
        for i in centres.indices where distance(i) < distance(best) { best = i }
        if let current, current <= last, current != best, distance(current) - distance(best) < gapHysteresis { return current }
        return best
    }

    /// Each slot's ghost centre in content coordinates: card k's place if the ghost took it, then the place after the
    /// last card (the card in the hand has no place of its own meanwhile).
    func ghostCentres() -> [Double] {
        var left = Double(ClotheslineCardMetrics.leadingPad)
        var out: [Double] = []
        let line = lineItems
        out.reserveCapacity(line.count + 1)
        for item in line {
            out.append(left + Double(ghostWidth) / 2)
            left += Double(cards[item.id]?.width ?? ClotheslineCardMetrics.iconMatWidth) + Double(ClotheslineCardMetrics.gap)
        }
        out.append(left + Double(ghostWidth) / 2)
        return out
    }

    /// The content coordinate (a slot position) under screen x on the line as it is now: `pinX` inverted.
    func contentX(atScreenX x: Double) -> Double {
        let nx = Double(geometry.notchCenterX)
        return nx + (x - nx) / max(0.2, line.value) - Double(geometry.leftEndX) + scroller.offset
    }

    /// One pointer sample of the drag, for the hand's speed.
    private func sampleDrag(_ p: CGPoint) {
        let x = Double(p.x), y = Double(p.y)
        if let last = lastDragSample {
            let dt = time - last.t
            guard dt > 1e-4 else { return }
            let k = dt > 0.15 ? 1 : 1 - exp(-dt / 0.05)
            dragVelocityX += ((x - last.x) / dt - dragVelocityX) * k
            dragVelocityY += ((y - last.y) / dt - dragVelocityY) * k
        }
        lastDragSample = (x, y, time)
    }

    /// The hand's horizontal speed as it lets go (0 when it had come to rest).
    var releaseVelocityX: Double {
        guard let last = lastDragSample, time - last.t < 0.1 else { return 0 }
        return dragVelocityX
    }

    /// … and its vertical speed (down is positive).
    var releaseVelocityY: Double {
        guard let last = lastDragSample, time - last.t < 0.1 else { return 0 }
        return dragVelocityY
    }

    /// The swing a dropped card starts with, in radians per second: its bottom carries on the way the hand was going
    /// (negative spin moves the bottom right), so the hand's speed is handed over. The pin catching the line then adds
    /// its kick (`arrivalKick`), so a card let go by a still hand swings too.
    static func dropSpin(velocity v: Double) -> Double {
        -ClotheslineMath.clamp(v / 1000 * dropSpinPerKPointsPerSecond, -maxDropSpin, maxDropSpin)
    }

    /// How fast a drag held near either end of the line scrolls the hidden cards into view (pt/s; 0 elsewhere).
    var edgeScrollVelocity: Double {
        guard dropHover, !dropRefused, let p = pointer, scroller.mode != .tracking, scroller.maxOffset > 0 else { return 0 }
        let x = Double(p.x), l = Double(geometry.leftEndX), r = Double(geometry.rightEndX), zone = Self.edgeScrollZone
        if x < l + zone && scroller.offset > 0.5 {
            return -Self.edgeScrollSpeed * ClotheslineMath.clamp((l + zone - x) / zone, 0, 1)
        }
        if x > r - zone && scroller.offset < scroller.maxOffset - 0.5 {
            return Self.edgeScrollSpeed * ClotheslineMath.clamp((x - r + zone) / zone, 0, 1)
        }
        return 0
    }

    /// How long a dropped card takes to fade in over the ghost.
    var handoffDuration: Double { reduceMotion ? Self.reduceMotionFade : Self.handoffFade }

    /// How far a dropped card has faded in over the ghost (0…1; 1 when it is not cross-fading).
    func handoffProgress(_ c: Card) -> Double {
        guard c.fromGhost, c.dropStart != nil else { return 1 }
        guard let started = c.startedAt else { return 0 }
        return ClotheslineMath.clamp((time - started) / handoffDuration, 0, 1)
    }

    /// One substep of the ghost, the string's brightness and the edge scroll.
    private func stepDrop(_ h: Double) {
        if let id = ghostHandoff {
            if let c = cards[id], c.startedAt.map({ time < $0 + handoffDuration - 1e-9 }) ?? true {
                // The ghost stays with the card it hands over to (the card may still wait for its picture, sliding
                // to its slot): it goes where the card goes.
                ghostSlot.value = c.slot.value; ghostSlot.velocity = c.slot.velocity; ghostSlot.target = c.slot.target
            } else {
                // The card has faded in over the ghost: the ghost is gone (it was transparent already).
                ghostHandoff = nil
                ghostShow.target = showsGhost ? 1 : 0
                if !showsGhost { ghostShow.snap() }
            }
        }
        if reduceMotion {
            // The ghost jumps to its place once the cards that make room for it have faded out; it stays fully shown.
            if let r = ghostReflowAt {
                if time - r >= Self.reflowFade - 1e-9 { ghostSlot.snap(); ghostReflowAt = nil }
            } else if reflowStart == nil && ghostHandoff == nil {
                ghostSlot.snap()
            }
            // A fade; a ghost that is just appearing waits for the room first.
            let rate = h / Self.ghostFade
            if ghostShow.target > ghostShow.value {
                if ghostReflowAt == nil { ghostShow.value = min(ghostShow.target, ghostShow.value + rate) }
            } else {
                ghostShow.value = max(ghostShow.target, ghostShow.value - rate)
            }
            ghostShow.velocity = 0
        } else {
            ghostShow.step(h)
            if ghostHandoff == nil { ghostSlot.step(h) }
        }
        dropGlow.step(h)
        let v = edgeScrollVelocity
        if v != 0 { scroller.handle(ClotheslineScrollInput(phase: .wheel, delta: v * h, time: time)) }
    }

    /// Files an app promised (Photos, Mail, Safari) were let go over the line: the drag is over, but the gap stays
    /// open and the ghost waits in it until the app has written them (`drop` then hangs them there), at most
    /// `promiseWait`. The line stays out meanwhile.
    func awaitPromisedFiles() {
        catchUp()
        guard dropHover && !dropRefused else { return }
        updateDropIndex()
        promisedUntil = time + Self.promiseWait
        fileDrag = nil; dragReleasedAt = nil; dropSeen = false; lastDragSample = nil
        dropHover = false
        layout()
        updateDrop()
    }

    /// Whether promised files are on their way to the gap.
    var awaitingPromisedFiles: Bool { promisedUntil != nil }

    /// The promised files never came (or their app failed): the gap closes and the ghost goes.
    func cancelPromisedFiles() {
        guard promisedUntil != nil else { return }
        catchUp()
        promisedUntil = nil
        if !dropHover { dropIndex = nil }
        layout()
        updateDrop()
    }

    /// Hangs dropped files where the ghost shows them (at the gap). The first card starts exactly where the ghost
    /// hangs, at its tilt, and the ghost cross-fades into it; more files fan out from there along the string to their
    /// places. The pin closing on the string is the landing: the string dips under it and the card swings on the way
    /// the hand was going. Then the line holds 2 s and retracts by the usual rules. A file already on the line moves
    /// there (it leaves its old place) instead of hanging twice; at most 50 stay, the last ones dropping off as when
    /// jobs add files. The files themselves are only referred to, never moved or copied. Returns the cards it added.
    @discardableResult
    func drop(_ urls: [URL]) -> [ClotheslineItem] {
        catchUp()
        var seen = Set<String>()
        let fresh = Array(urls.map { $0.absoluteURL }.filter { fileExists($0) && seen.insert(Self.identity($0)).inserted }
            .prefix(Self.capacity))
        guard !fresh.isEmpty else { setFileDrag(nil); cancelPromisedFiles(); return [] }
        pruneMissing()
        if dropHover { updateDropIndex() }
        let centres = ghostCentres()
        var index = min(dropIndex ?? pointer.map { Self.dropSlot(contentX: contentX(atScreenX: Double($0.x)), centres: centres, current: nil) } ?? 0,
                        items.count)
        // The cards start where the ghost hangs and slide to their slots from there.
        let ghostAt = ghostShow.value > 0.01 ? ghostSlot.value : centres[index]
        let paths = Set(fresh.map(Self.identity))
        let again = items.enumerated().filter { paths.contains(Self.identity($0.element.url)) }
        index -= again.filter { $0.offset < index }.count
        items.removeAll { paths.contains(Self.identity($0.url)) }
        discard(again.map(\.element.id))
        let added = fresh.map { ClotheslineItem(id: UUID(), url: $0, reference: Self.reference(for: $0)) }
        items.insert(contentsOf: added, at: index)
        let addedIDs = Set(added.map(\.id))
        // At most `capacity`: the last files drop off, never the ones just dropped.
        while items.count > Self.capacity, let last = items.lastIndex(where: { !addedIDs.contains($0.id) }) {
            let id = items[last].id
            items.remove(at: last)
            discard([id])
        }
        let spin = Self.dropSpin(velocity: releaseVelocityX)
        var previous: UUID?
        for (i, item) in added.enumerated() {
            var card = Card(id: item.id, width: widthFor(item.url),
                            slot: ClotheslineSpring(ghostAt, damping: Self.slotDamping, response: Self.slotResponse),
                            // No fall: the card is where the ghost showed it.
                            drop: ClotheslineSpring(0, damping: Self.dropDamping, response: Self.dropResponse))
            card.dropStart = time + Double(i) * Self.cascade
            card.after = previous
            previous = item.id
            if !pictureReady(item.url) { card.pictureDeadline = time + Self.pictureWait + Double(i) * Self.cascade }
            card.arrived = false
            card.fromGhost = true
            card.jitter = Self.jitter(for: item.url)
            // The settling swing goes the hand's way (a still hand: alternating), and several cards swing a little out
            // of step (no comb of identical swings).
            let way = spin != 0 ? (spin > 0 ? 1.0 : -1.0) : (i % 2 == 0 ? 1.0 : -1.0)
            card.spin = spin + way * Self.dropSettleSpin * (i % 2 == 0 ? 1 : 0.6)
            card.angle = ghostAngle(slot: ghostAt)
            if reduceMotion { card.angle = 0; card.spin = 0; card.drop.snap() }
            cards[item.id] = card
            pendingArrivals.insert(item.id)
        }
        // The drag is over: the gap is now the new cards' place, and the ghost stays with the first of them until it
        // has faded in.
        fileDrag = nil; dragReleasedAt = nil; dropSeen = false; lastDragSample = nil; promisedUntil = nil
        dropHover = false; dropIndex = nil; ghostReflowAt = nil
        ghostHandoff = added.first?.id
        ghostSlot.value = ghostAt; ghostSlot.target = ghostAt; ghostSlot.velocity = 0
        ghostShow.target = 1
        dropGlow.target = 0
        dropCount += 1
        // Reduce Motion: the new cards fade in at their places (nothing slides).
        layout(newIDs: reduceMotion ? addedIDs : [])
        onItemsChange?()
        beginReveal(hold: 0, freshPointer: true)
        return added
    }

    /// Where the ghost card hangs this frame (nil while it doesn't show): on the string at its slot, following the
    /// string's slope like a card and leaning a little against its own glide. While a dropped card fades in over it,
    /// it is exactly where that card is (same pivot, tilt and size) and fades out as the card fades in.
    var ghostPose: ClotheslineCardPose? {
        if let id = ghostHandoff, let c = cards[id], c.startedAt != nil, let card = pose(id) {
            guard var ghost = ghostPose(slot: c.slot.value) else { return nil }
            ghost.pivot = card.pivot
            ghost.angle = card.angle
            ghost.scale = card.scale
            ghost.alpha *= 1 - handoffProgress(c)
            return ghost.alpha > 0.001 ? ghost : nil
        }
        return ghostPose(slot: ghostSlot.value)
    }

    /// The tilt the ghost has hanging at `slot` (radians, before the soft limit): half the string's slope, and its lean
    /// against its own glide.
    private func ghostAngle(slot: Double) -> Double {
        let ends = lineEnds()
        let x = pinX(slot: slot, ends: ends)
        let follow = ClotheslineMath.clamp(Self.slopeFollow * atan(slopeAt(x, ends: ends)), -Self.maxSlopeTilt, Self.maxSlopeTilt)
        let lean = reduceMotion ? 0
            : ClotheslineMath.clamp(ghostSlot.velocity * Self.ghostTiltPerKPointsPerSecond / 1000, -Self.maxGhostTilt, Self.maxGhostTilt)
        return follow + ClotheslineMath.radians(lean)
    }

    /// The ghost's pose if it hung at `slot`.
    func ghostPose(slot: Double) -> ClotheslineCardPose? {
        let show = ClotheslineMath.clamp(ghostShow.value, 0, 1)
        guard show > 0.002, state != .hidden else { return nil }
        let ends = lineEnds()
        let x = pinX(slot: slot, ends: ends)
        let y = stringY(at: x, ends: ends)
        let s = ClotheslineMath.clamp(line.value, 0, 1)
        // Reduce Motion: it stays fully shown while cards change places around it (only they fade).
        let alpha = show * (reduceMotion ? fade * reflowAlpha : ClotheslineMath.smoothstep(0.015, 0.2, s))
        let scale = reduceMotion ? 1 : max(0.06, pow(s, 0.9)) * (0.94 + 0.06 * show)
        return ClotheslineCardPose(id: Self.ghostID, pivot: CGPoint(x: x, y: y), angle: Self.softLimit(ghostAngle(slot: slot)),
                                   scale: scale, alpha: alpha, lift: 0, width: ghostWidth)
    }

    // MARK: Moving a card along the string

    /// Picks a card up to move it along the string (its press moved past the drag threshold): it lifts off the string
    /// and hangs from its pin under the pointer, which holds it 1:1 by the place it was grabbed (`grab`, a scene point
    /// on the card). Its neighbours keep its place open until it is moved on; the gap follows it as it follows the
    /// dropped files. Returns false when the card can't be picked up (not hanging on a line that is out).
    @discardableResult
    func pickUp(_ id: UUID, at grab: CGPoint) -> Bool {
        catchUp()
        guard cardDrag == nil, fileDrag == nil, state == .shown || state == .revealing,
              let index = items.firstIndex(where: { $0.id == id }), var c = cards[id],
              !c.leaving, !c.isWaiting, c.flight == nil else { return false }
        cardDrag = CardDrag(id: id, grab: CGPoint(x: Double(grab.x) - c.pivotX, y: Double(grab.y) - c.pivotY))
        c.held = true
        // A card still settling from its own drop or arrival, or still on its way to its place after the last move, is
        // simply in the hand now, from where it is.
        c.aloft = false
        c.dropStart = nil; c.startedAt = c.startedAt ?? time; c.arrived = true; c.fromGhost = false; c.pictureDeadline = nil
        c.drop = ClotheslineSpring(0, damping: Self.dropDamping, response: Self.dropResponse)
        c.reflowAt = nil; c.reflowSnapped = false; c.returnedAt = nil
        cards[id] = c
        pendingArrivals.remove(id)
        if ghostHandoff == id { ghostHandoff = nil; ghostShow.target = 0; ghostShow.snap() }
        pressedCard = nil
        hoveredCard = nil
        // Picking a card up is not a click: any selection ends (the panel gives the keyboard back once the press is over).
        selectedCard = nil
        if pointer == nil { pointer = grab }
        // The gap is the card's own place to begin with: nothing moves until the card does.
        ghostWidth = c.width
        dropHover = true
        dropRefused = false
        dropIndex = index
        let centres = ghostCentres()
        ghostSlot.target = centres[min(index, centres.count - 1)]
        ghostSlot.snap()
        lastDragSample = nil
        dragVelocityX = 0
        dragVelocityY = 0
        layout()
        updateBand()
        return true
    }

    /// The card in the hand was let go. Over the line's area it is hung at the gap: its pin carries the hand's speed
    /// to its place and the string catches it there (a small swing, the string dips under the pin); the new order
    /// stays. Anywhere else (it can't be: out of the area it is a drag session) it goes back to its place. Reduce
    /// Motion: it fades out under the pointer and back in at its place, without a swing. Returns the move.
    @discardableResult
    func releaseCard() -> CardMove? {
        catchUp()
        guard let d = cardDrag, !d.out else { return nil }
        if dropHover { updateDropIndex() }
        let home = items.firstIndex { $0.id == d.id } ?? 0
        return rehang(d, at: dropHover ? (dropIndex ?? home) : home)
    }

    /// Esc while a card is moved along the string: it goes back to its place (the same way it is hung when let go).
    @discardableResult
    func cancelCardDrag() -> CardMove? {
        catchUp()
        guard let d = cardDrag, !d.out else { return nil }
        return rehang(d, at: items.firstIndex { $0.id == d.id } ?? 0)
    }

    /// Hangs the card in the hand at `index` (in `items`), from where it is now and as fast as the hand was going.
    private func rehang(_ d: CardDrag, at index: Int) -> CardMove? {
        guard let from = items.firstIndex(where: { $0.id == d.id }), var c = cards[d.id] else {
            cardDrag = nil; layout(); return nil
        }
        let pin = heldPin ?? CGPoint(x: c.pivotX, y: c.pivotY)
        let to = min(max(0, index), items.count - 1)
        let item = items.remove(at: from)
        items.insert(item, at: to)
        cardDrag = nil
        if fileDrag == nil { dropHover = false; dropIndex = nil }
        let ends = lineEnds()
        let x = Double(pin.x), y = Double(pin.y)
        let vx = ClotheslineMath.clamp(releaseVelocityX, -Self.rehangMaxSpeedX, Self.rehangMaxSpeedX)
        let vy = ClotheslineMath.clamp(releaseVelocityY, -Self.rehangMaxSpeedY, Self.rehangMaxSpeedY)
        c.held = false
        c.aloft = true
        c.pivotX = x
        c.pivotY = y
        // The slot starts where the pin is (content coordinates) with the hand's speed across; the drop is the pin's
        // height over (negative) or under the string there, with the hand's speed up or down.
        c.slot.value = contentX(atScreenX: x)
        c.slot.velocity = vx / max(0.2, ends.spread)
        c.drop = ClotheslineSpring(y - stringY(at: x, ends: ends), target: 0, damping: Self.dropDamping, response: Self.dropResponse)
        c.drop.velocity = vy
        c.risesToString = c.drop.value > 0
        if reduceMotion {
            c.reflowAt = time; c.reflowSnapped = false
            c.spin = 0
        }
        cards[d.id] = c
        lastDragSample = nil
        layout()
        onItemsChange?()
        updateDrop()
        return CardMove(id: d.id, from: from, to: to)
    }

    /// The card in the hand left the line's area and its file went to a drag session (to a Finder folder, or back onto
    /// the line): the system draws it now. The gap has closed; the line goes `dragLeaveGrace` after the card left, and
    /// comes back when it is brought over the line's area again (or toward the notch), where letting go hangs it
    /// (`dropCard`).
    func cardWentOut() {
        catchUp()
        guard var d = cardDrag, !d.out else { return }
        d.out = true
        cardDrag = d
        cards[d.id]?.lift.snap()
        updateDrop()
    }

    /// The card's drag session was let go over the line: the same card moves to the gap (its file is never hung
    /// twice). It takes over from the ghost as a dropped file does: it fades in over it, the pin closes on the string,
    /// and it swings on the way the hand was going. Returns the move (nil when the line didn't take it).
    @discardableResult
    func dropCard() -> CardMove? {
        catchUp()
        guard let d = cardDrag, d.out, dropHover, let from = items.firstIndex(where: { $0.id == d.id }), var c = cards[d.id] else {
            return nil
        }
        updateDropIndex()
        let to = min(dropIndex ?? from, items.count - 1)
        let centres = ghostCentres()
        let ghostAt = ghostShow.value > 0.01 ? ghostSlot.value : centres[min(to, centres.count - 1)]
        let item = items.remove(at: from)
        items.insert(item, at: to)
        let spin = Self.dropSpin(velocity: releaseVelocityX)
        c.held = false
        c.aloft = false
        c.slot = ClotheslineSpring(ghostAt, damping: Self.slotDamping, response: Self.slotResponse)
        c.drop = ClotheslineSpring(0, damping: Self.dropDamping, response: Self.dropResponse)
        c.dropStart = time; c.startedAt = nil; c.after = nil; c.pictureDeadline = nil
        c.arrived = false
        c.fromGhost = true
        c.spin = spin + (spin < 0 ? -1.0 : 1.0) * Self.dropSettleSpin
        c.angle = ghostAngle(slot: ghostAt)
        c.lastX = nil; c.smoothVX = 0; c.lastSmoothVX = 0; c.accel = 0
        c.lift.snap()
        if reduceMotion { c.angle = 0; c.spin = 0 }
        cards[d.id] = c
        pendingArrivals.insert(d.id)
        cardDrag = nil
        dropHover = false; dropIndex = nil; ghostReflowAt = nil; dropSeen = false; lastDragSample = nil
        ghostHandoff = d.id
        ghostSlot.value = ghostAt; ghostSlot.target = ghostAt; ghostSlot.velocity = 0
        ghostShow.target = 1
        dropGlow.target = 0
        layout(newIDs: reduceMotion ? [d.id] : [])
        onItemsChange?()
        beginReveal(hold: 0, freshPointer: true)
        return CardMove(id: d.id, from: from, to: to)
    }

    /// The card's drag session ended anywhere but on the line (dropped in a Finder folder, or cancelled): the card goes
    /// back to its place (it follows its file when the drop moved it). On a line that is out it fades in there.
    func cardDragEnded() {
        catchUp()
        guard let d = cardDrag else { return }
        cardDrag = nil
        if var c = cards[d.id] {
            c.held = false
            c.aloft = false
            c.drop = ClotheslineSpring(0, damping: Self.dropDamping, response: Self.dropResponse)
            c.angle = c.targetAngle; c.spin = 0
            c.lastX = nil; c.smoothVX = 0; c.lastSmoothVX = 0; c.accel = 0
            c.lift.target = 0; c.lift.snap()
            c.returnedAt = state == .hidden ? nil : time
            cards[d.id] = c
        }
        if fileDrag == nil { dropHover = false; dropIndex = nil; dropSeen = false }
        lastDragSample = nil
        layout(newIDs: [d.id])
        onItemsChange?()
        updateDrop()
    }

    /// Moves a card one place left or right along the string (VoiceOver's Move Left and Move Right): it and its
    /// neighbour change places (they slide; Reduce Motion: they cross-fade). Nil at either end of the line.
    @discardableResult
    func moveCard(_ id: UUID, by step: Int) -> CardMove? {
        catchUp()
        guard cardDrag == nil, let from = items.firstIndex(where: { $0.id == id }) else { return nil }
        let to = from + step
        guard to >= 0, to < items.count, to != from else { return nil }
        items.swapAt(from, to)
        layout()
        onItemsChange?()
        return CardMove(id: id, from: from, to: to)
    }

    // MARK: Selecting a card

    /// Selects a card (a click on it) or nothing, on a line that is out. The selected card wears the selection ring and
    /// takes the keys (Delete, the arrows, Esc); the line stays out while there is one. Ending the selection lets the
    /// line follow its usual rules again from now (it goes 0.6 s later when the pointer is away).
    func select(_ id: UUID?) {
        catchUp()
        let id = id.flatMap { i in items.contains { $0.id == i } && (state == .shown || state == .revealing) ? i : nil }
        guard id != selectedCard else { return }
        selectedCard = id
        if id == nil { restartLeave() }
    }

    /// Moves the selection one card left or right (the arrow keys), scrolling the line to show it. Nothing past either
    /// end. Returns whether it moved.
    @discardableResult
    func moveSelection(by step: Int) -> Bool {
        catchUp()
        guard let s = selectedCard, let i = items.firstIndex(where: { $0.id == s }), items.indices.contains(i + step) else { return false }
        let id = items[i + step].id
        selectedCard = id
        if let c = cards[id] {
            // Whole in view: the line scrolls as little as it needs to.
            let half = Double(c.width) / 2, length = Double(geometry.rightEndX - geometry.leftEndX)
            let lo = c.slot.target - half - Double(ClotheslineCardMetrics.leadingPad)
            let hi = c.slot.target + half + Double(ClotheslineCardMetrics.trailingPad) - length
            let to = lo < scroller.offset ? lo : hi > scroller.offset ? hi : scroller.offset
            if abs(to - scroller.offset) > 0.5 { scroller.scroll(to: to, animated: !reduceMotion && state != .hidden) }
        }
        return true
    }

    // MARK: The welcome card

    /// The card that stands in for an empty line (ClotheslineWelcome), while it hangs; nil otherwise.
    private(set) var welcomeID: UUID?
    /// The person took the welcome card off the line (true: Delete, Remove from Line, Clear Line), or put it back with
    /// ⌘Z (false).
    var onWelcomeRemoval: ((Bool) -> Void)?

    /// Hangs the welcome card at the end of the line (the oldest place) without bringing the line out: it is simply
    /// there the next time the line comes out. It is never a new file: no drop, no flight, no hold, no announcement.
    func placeWelcome(_ url: URL) {
        catchUp()
        let url = url.absoluteURL
        guard welcomeID == nil, items.count < Self.capacity, fileExists(url),
              !items.contains(where: { Self.identity($0.url) == Self.identity(url) }) else { return }
        let item = ClotheslineItem(id: UUID(), url: url, reference: Self.reference(for: url))
        items.append(item)
        var card = Card(id: item.id, width: widthFor(url), slot: ClotheslineSpring(0, damping: Self.slotDamping, response: Self.slotResponse),
                        drop: ClotheslineSpring(0, damping: Self.dropDamping, response: Self.dropResponse))
        card.jitter = Self.jitter(for: url)
        cards[item.id] = card
        welcomeID = item.id
        layout(newIDs: [item.id])
        onItemsChange?()
    }

    /// Whether any card is drawn in the air (the flight window): a screenshot's card flying up, a card in the hand, or
    /// one let go on its way to its place.
    var drawsInAir: Bool { hasFlights || liftedCard != nil || hasCardAloft }

    // MARK: Time

    /// Advances to `now` in fixed substeps. While nothing moves, time just jumps (no physics per mouse event).
    func advance(to now: Double) {
        var dt = now - time - remainder
        if dt <= 0 || advancing { return }
        advancing = true
        defer { advancing = false }
        if (state == .hidden || state == .shown) && isSettled && !hasPendingDrops {
            time = now
            remainder = 0
            updateBand()
            updateDrop()
            updateTimeline()
            return
        }
        if dt > 0.25 {
            time = now - 0.25
            dt = 0.25
        }
        remainder += dt
        while remainder >= Self.substep - 1e-9 {
            remainder -= Self.substep
            step(Self.substep)
        }
    }

    /// Cards that haven't started dropping yet.
    var hasPendingDrops: Bool { cards.values.contains { $0.isWaiting } }

    /// The deterministic order cards are stepped in (dictionary order differs between runs).
    private var stepOrder: [UUID] { leavingOrder + items.map(\.id) }

    /// Physics substeps taken so far (tests: nothing runs while the line is hidden and still).
    private(set) var substepCount = 0

    /// One physics substep.
    func step(_ h: Double) {
        time += h
        substepCount += 1
        // A card nearly at the line brings a hidden line out to meet it (and turns round one going in).
        if !reduceMotion, state == .hidden || state == .retracting,
           cards.values.contains(where: { c in c.flight?.revealAt.map { time >= $0 - 1e-9 } ?? false }) {
            beginReveal(hold: 0, freshPointer: false)
        }
        // The string.
        if reduceMotion {
            let rate = h / Self.reduceMotionFade
            fade = fadeTarget > fade ? min(fadeTarget, fade + rate) : max(fadeTarget, fade - rate)
            let v: Double = fade > 0 || fadeTarget > 0 ? 1 : 0
            line.value = v; line.velocity = 0; line.target = v
            fall.value = v; fall.velocity = 0; fall.target = v
        } else {
            orchestrate()
            line.step(h)
            fall.step(h)
            fade = fadeTarget
        }
        let s = ClotheslineMath.clamp(line.value, 0, 1)
        // The cards on the string weigh it down (one in the hand doesn't: the string rises a little as it is lifted).
        let hanging = items.count - (cardDrag == nil ? 0 : 1)
        let count = Double(min(hanging, 12))
        let overshoot = max(0, line.value - 1) * 80
        sag.target = (hanging == 0 ? Self.sagEmpty : Self.sagBase + Self.sagPerCard * count) * s * s + overshoot
        if reduceMotion { sag.snap() } else { sag.step(h) }

        // Reduce Motion: cards changing places fade out, jump, fade in.
        if let r = reflowStart {
            if !reflowSnapped && time - r >= Self.reflowFade {
                for id in Array(cards.keys) { cards[id]?.slot.snap() }
                ghostSlot.snap()
                if scrollResetPending { scroller.scroll(to: 0, animated: false); scrollResetPending = false }
                reflowSnapped = true
            }
            if time - r >= 2 * Self.reflowFade { reflowStart = nil }
        }

        // The ghost and the brighter string while files are dragged over the line.
        stepDrop(h)

        // Scrolling.
        let length = Double(geometry.rightEndX - geometry.leftEndX)
        scroller.dimension = length
        if scroller.mode == .tracking && time - lastScrollInput > Self.lostGesture { scroller.abandonTracking() }
        scroller.step(h, now: time)
        noteScrollIdle()
        scrollTilt = reduceMotion ? 0 : ClotheslineMath.clamp(-scroller.velocity * s * Self.tiltPerKPointsPerSecond / 1000,
                                                                  -Self.maxScrollTilt, Self.maxScrollTilt)

        // Cards, pass 1: their own springs; drops start in batch order.
        let order = stepOrder
        var landed: [UUID] = []
        for id in order {
            guard var c = cards[id] else { continue }
            if reduceMotion {
                if let r = c.reflowAt {
                    // Changing places: it jumps once it has faded out, then fades back in. A card let go by hand is
                    // on the string from then on.
                    if !c.reflowSnapped && time - r >= Self.reflowFade - 1e-9 {
                        c.slot.snap(); c.reflowSnapped = true
                        if c.aloft { c.aloft = false; c.drop.snap() }
                    }
                    if time - r >= 2 * Self.reflowFade - 1e-9 { c.reflowAt = nil; c.reflowSnapped = false }
                } else if reflowStart == nil {
                    c.slot.snap()
                }
            } else {
                c.slot.step(h)
            }
            if let back = c.returnedAt, time >= back + Self.returnFade - 1e-9 { c.returnedAt = nil }
            if c.isWaiting, let start = c.dropStart, time >= start - 1e-9 {
                let previousStarted = c.after.flatMap { cards[$0] }.map { p in p.startedAt.map { time >= $0 + Self.cascade - 1e-9 } ?? !p.isWaiting } ?? true
                let pictureOK = c.pictureDeadline.map { time >= $0 - 1e-9 } ?? true
                if previousStarted && pictureOK {
                    c.startedAt = time
                    c.pictureDeadline = nil
                    // A dropped card takes the ghost's tilt where it is now (it may have waited for its picture).
                    if c.fromGhost && !reduceMotion { c.angle = ghostAngle(slot: c.slot.value) }
                }
            }
            if c.flight != nil {
                // In the air: the flight moves it (pass 2) until the pin catches the line. It stays lifted (the
                // bigger, softer shadow of something off the screen) and settles as it lands.
                c.lift.value = 1
                c.lift.velocity = 0
            } else if let started = c.startedAt, c.dropStart != nil {
                if reduceMotion { c.drop.snap() } else { c.drop.step(h) }
                if !c.arrived && c.drop.value >= 0 {
                    c.arrived = true
                    landed.append(id)
                    if !reduceMotion { Self.pinCatches(&c) }
                }
                let fadeIn = c.fromGhost ? handoffDuration : (reduceMotion ? Self.reduceMotionFade : 0)
                let faded = time >= started + fadeIn - 1e-9
                if c.arrived && faded && c.drop.isSettled(position: 0.05, speed: 0.5) && !c.leaving { c.drop.snap(); c.dropStart = nil }
            } else if c.leaving {
                if reduceMotion { c.drop.snap() } else { c.drop.step(h) }
            } else if c.aloft && !reduceMotion {
                // Let go by hand: the pin travels to the string; the frame it reaches it, the string catches it.
                c.drop.step(h)
                if c.risesToString ? c.drop.value <= 0 : c.drop.value >= 0 {
                    // The string takes the pin's speed, and from above the card's weight as well (half a dropped
                    // card's: it is set down, not let fall).
                    c.aloft = false
                    let give = c.drop.velocity + (c.risesToString ? 0 : 0.5 * Self.dipKick)
                    Self.pinCatches(&c, dip: ClotheslineMath.clamp(give, -Self.dipKick, Self.dipKick))
                    sag.velocity += 12
                }
            } else if c.dropStart == nil && !c.held && !reduceMotion && !c.drop.isSettled(position: 0.01, speed: 0.1) {
                // Caught: the pin rides out its last bit of give with the string.
                c.drop.step(h)
            }
            if c.leaving || c.leave.value > 0 {
                if !reduceMotion { c.leave.step(h) }
                else { c.leave.value = c.leaving ? min(1, c.leave.value + h / Self.reduceMotionFade) : max(0, c.leave.value - h / Self.reduceMotionFade) }
                if !c.leaving && c.leave.isSettled(position: 0.002, speed: 0.01) { c.leave.snap() }
            }
            c.lift.target = liftGoal(id)
            c.press.target = pressGoal(id)
            if c.flight == nil { c.lift.step(h) }
            c.press.step(h)
            if reduceMotion { c.dip.snap() } else { c.dip.step(h) }
            cards[id] = c
        }

        // Pass 2: pivots on the string, and the pendulums.
        dips = order.compactMap { id in
            guard let c = cards[id], abs(c.dip.value) > 0.005 || abs(c.dip.velocity) > 0.05 else { return nil }
            return (c.pivotX, c.dip.value)
        }
        let ends = lineEnds()
        // Where the line will hang once it is out: what a card in the air aims at while the line is still coming.
        let restEnds = hasFlights ? Self.ends(spread: 1, fall: 1, sag: restSag, geometry: geometry,
                                              leftFull: fullEnds.left, rightFull: fullEnds.right) : ends
        for id in order {
            guard var c = cards[id] else { continue }
            var x = pinX(slot: c.slot.value, ends: ends)
            var y = stringY(at: x, ends: ends) + c.drop.value
            let inAir = c.flight != nil
            if inAir { (x, y) = fly(&c, h, spot: x, ends: ends, restEnds: restEnds, landed: &landed) }
            // In the hand: the pin is where the pointer holds it.
            let inHand = c.held
            if inHand { let pin = heldPin ?? CGPoint(x: c.pivotX, y: c.pivotY); x = Double(pin.x); y = Double(pin.y) }
            // Reduce Motion: let go, it stays exactly where it was until it has faded out (the string taking its weight
            // back doesn't carry it).
            if c.aloft && reduceMotion { x = c.pivotX; y = c.pivotY }
            c.pivotX = x
            c.pivotY = y
            // Pin velocity, low-passed, and its acceleration: the inertial push on the pendulum. The hand moves the
            // pin in steps (one per pointer event), so its speed is smoothed more and gives a lean instead of a push.
            let vx = c.lastX.map { (x - $0) / h } ?? 0
            c.lastX = x
            c.lastSmoothVX = c.smoothVX
            c.smoothVX += (vx - c.smoothVX) * (1 - exp(-h / (inHand ? Self.heldSmoothing : 0.035)))
            c.accel = inHand ? 0 : (c.smoothVX - c.lastSmoothVX) / h

            let waiting = c.isWaiting
            if waiting { c.lastX = nil; c.smoothVX = 0; c.lastSmoothVX = 0; c.accel = 0 }
            // In the air the card hangs plumb (no string to follow); the pin's acceleration still swings it. In the
            // hand it leans with the hand's speed, its foot trailing.
            let slope = inAir || inHand ? 0 : slopeAt(x, ends: ends)
            let follow = ClotheslineMath.clamp(Self.slopeFollow * atan(slope), -Self.maxSlopeTilt, Self.maxSlopeTilt)
            let lean = inHand ? ClotheslineMath.clamp(c.smoothVX * Self.heldTiltPerKPointsPerSecond / 1000, -Self.maxHeldTilt, Self.maxHeldTilt) : 0
            c.targetAngle = follow + (inAir || inHand ? 0 : ClotheslineMath.radians(scrollTilt)) + ClotheslineMath.radians(lean)
            if waiting {
                // Not on the line yet: keeps the turn it will fall with.
            } else if reduceMotion {
                c.angle = follow
                c.spin = 0
            } else {
                let calm = id == hoveredCard
                let zeta = calm ? Self.calmDamping
                    : inHand ? Self.heldSwingDamping : (scroller.isIdle ? Self.swingDamping : Self.scrollSwingDamping)
                let response = Self.swingResponse * Self.swingFactor(width: c.width) * c.jitter
                let k = pow(2 * .pi / response, 2)
                let friction = 4 * .pi * zeta / response
                // In the air the card leans with the flight but swings less than one jolted on the line.
                let push = k * ClotheslineMath.radians(Self.maxInertialTilt) * tanh(c.accel / Self.inertialReference)
                    * (calm ? 0.3 : 1) * (inAir ? Self.flightSwing : 1)
                let pull = -k * (c.angle - c.targetAngle) + push
                let grip = k * Self.pinFriction
                if abs(c.spin) < 0.02 && abs(pull) <= grip {
                    c.spin = 0      // the pin holds it
                } else {
                    let direction = c.spin != 0 ? (c.spin > 0 ? 1.0 : -1.0) : (pull > 0 ? 1.0 : -1.0)
                    var spin = c.spin + (pull - friction * c.spin - grip * direction) * h
                    // Friction alone never swings it back the other way.
                    if c.spin != 0 && (spin > 0) != (c.spin > 0) && abs(pull) <= grip { spin = 0 }
                    c.spin = spin
                }
                c.angle += c.spin * h
            }
            cards[id] = c
            if c.leaving && c.leave.value >= 0.985 {
                cards[id] = nil
                leavingOrder.removeAll { $0 == id }
            }
        }
        if !landed.isEmpty {
            for id in landed { pendingArrivals.remove(id) }
            lastArrival = time
            if !reduceMotion { sag.velocity += 22 * Double(landed.count) }
            if pendingArrivals.isEmpty {
                holdUntil = max(holdUntil, time + Self.holdAfterArrival * (voiceOverRunning() ? 3 : 1))
            }
        }
        updateBand()
        // Cards gliding under a still drag (or the line scrolling under it) move the gap.
        updateDrop()
        // Cards gliding or swinging under a still pointer: hover follows (no state change can come of it).
        if pointerFresh, !otherDrag, fileDrag == nil, cardDrag == nil, let p = pointer, state == .shown || state == .revealing,
           Double(p.y) < Double(ClotheslineGeometry.panelHeight) {
            hoveredCard = cardID(at: p, minAlpha: 0.5)
        }
        updateTimeline()
    }

    /// The pin catches the line: the card keeps swinging the way it was going, harder, and the string dips under the
    /// pin (a dropped card's weight; a flying card's own speed, up, which the string takes and gives back).
    private static func pinCatches(_ c: inout Card, dip: Double = ClotheslineEngine.dipKick) {
        let direction = c.spin != 0 ? (c.spin > 0 ? 1.0 : -1.0) : (c.angle > c.targetAngle ? -1.0 : 1.0)
        c.spin += direction * Self.arrivalKick
        c.dip.velocity += dip
    }

    /// The sag the line will settle into with the cards it has now.
    private var restSag: Double {
        let hanging = items.count - (cardDrag == nil ? 0 : 1)
        return hanging == 0 ? Self.sagEmpty : Self.sagBase + Self.sagPerCard * Double(min(hanging, 12))
    }

    /// One substep of a card's flight; returns its pin's position. `spot` is where its pin goes on the line as the line
    /// is now. While the line is still coming out of the notch the card aims at where its spot will be once the line
    /// is out, and moves over to the live spot as the line arrives. Once the line is mostly out and the pin is just
    /// under the string at its spot, the pin catches it: the card is handed to the line where it is and as fast as it
    /// is going (its slot spring starts from the flight's position and speed across; the string under the pin takes
    /// its speed up and gives, then springs back), so nothing jumps.
    private func fly(_ c: inout Card, _ h: Double, spot: Double, ends: Ends, restEnds: Ends, landed: inout [UUID]) -> (Double, Double) {
        guard var f = c.flight else { return (c.pivotX, c.pivotY) }
        guard let started = c.startedAt else { return (Double(f.origin.x), Double(f.origin.y)) }
        let restX = pinX(slot: c.slot.value, ends: restEnds), restY = stringY(at: restX, ends: restEnds)
        let out = min(ClotheslineMath.clamp(line.value, 0, 1), ClotheslineMath.clamp(fall.value, 0, 1))
        let w = ClotheslineMath.smoothstep(0.35, 0.95, out)
        // Across, the live spot only counts once the card is near the line: a line spreading out while the card is
        // still far below (it comes out as the card flies) would otherwise pull it over toward the notch and back, and
        // it would reach the string still wide of its spot.
        let near = ClotheslineMath.smoothstep(Self.flightNearReach, Self.flightNearReach * 0.4, f.y.value - restY)
        let goalX = ClotheslineMath.lerp(restX, spot, w * near)
        let goalY = ClotheslineMath.lerp(restY, stringY(at: spot, ends: ends), w)
        // A card that slides in from off the display leaves at once; one at the pointer fades in there first.
        if f.launchedAt == nil && (f.entering || time >= started + Self.flightAppear - 1e-9) {
            f.launchedAt = time
            // A dry run to the spot on the line as it will hang: a long flight is slowed as a whole to the top speed,
            // and a hidden line is sent out to arrive with the card.
            let plan = Self.flightPlan(from: CGPoint(x: f.x.value, y: f.y.value), to: CGPoint(x: restX, y: restY))
            let s = max(1, plan.peak / Self.flightTopSpeed)
            f.stretch(s)
            f.revealAt = time + max(0, plan.arrival * s - Self.flightLineLead)
            f.giveUpAt = time + plan.arrival * s + Self.flightGiveUp
        }
        if f.launchedAt != nil {
            // Above where the string will be while the line is still out of sight: wait for it there.
            let rise = out < Self.catchOut && f.y.value <= goalY ? 0 : Self.flightRise
            f.step(h, goalX: goalX, goalY: goalY, rise: rise)
        }
        let x = f.x.value, y = f.y.value
        if f.launchedAt != nil {
            let under = stringY(at: x, ends: ends)
            let stringSpeed = f.lastUnder.map { (under - $0) / h } ?? 0
            f.lastUnder = under
            let side = abs(x - goalX)
            let caught = out >= Self.catchOut && y - under <= Self.catchReach
                && (side <= Self.catchSide || (side <= Self.catchWide && y <= under))
            if caught || time >= (f.giveUpAt ?? .infinity) - 1e-9 {
                // On the line the pin moves with its slot and with the line still spreading: the slot keeps the
                // pin's speed across. Up and down, the string under the pin takes the pin's speed (less its own).
                let spread = max(ends.spread, 0.05)
                let nx = Double(geometry.notchCenterX)
                c.slot.value = (x - nx) / spread + nx - Double(geometry.leftEndX) + scroller.offset
                c.slot.velocity = (f.x.velocity - (x - nx) / spread * (ends.spread > 0.05 ? line.velocity : 0)) / spread
                c.drop.target = 0
                c.drop.value = y - under
                c.drop.velocity = 0
                c.flight = nil
                c.arrived = true
                landed.append(c.id)
                // The pin keeps the card swinging; the string gives under it and springs back.
                Self.pinCatches(&c, dip: f.y.velocity - stringSpeed)
                return (x, y)
            }
        }
        c.flight = f
        return (x, y)
    }

    /// Who moves first: going away, the string is pulled up taut before its ends are reeled in; coming out, the ends
    /// run out before it falls. Targets change, values never jump.
    private func orchestrate() {
        switch state {
        case .revealing, .shown:
            line.target = 1
            (line.damping, line.response) = (Self.lineDamping, Self.lineResponse)
            if fall.target < 1 && line.value >= Self.fallGate { fall.target = 1 }
        case .retracting:
            fall.target = 0
            if fall.value <= Self.pullGate { line.target = 0 }
        case .hidden:
            break
        }
        if state != .revealing { caughtMidRetract = false }
        (fall.damping, fall.response) = fall.target >= 1
            ? (Self.fallDamping, caughtMidRetract ? Self.fallCatchResponse : Self.fallResponse)
            : (Self.pullDamping, Self.pullResponse)
        if line.target <= 0 { (line.damping, line.response) = (Self.lineInDamping, Self.lineInResponse) }
    }

    /// 0.94…1.06 from the card's width: wider cards swing a little slower.
    static func swingFactor(width: CGFloat) -> Double {
        0.94 + 0.12 * ClotheslineMath.clamp((Double(width) - Double(ClotheslineCardMetrics.minMatWidth)) / 66, 0, 1)
    }


    /// The state machine.
    private func updateTimeline() {
        // A release over the line whose drop never came (the source refused it): the drag is over.
        if let released = dragReleasedAt, time >= released + Self.dropGrace - 1e-9 { setFileDrag(nil) }
        // Promised files that never came: the gap closes.
        if let promised = promisedUntil, time >= promised - 1e-9 { cancelPromisedFiles() }
        // Resting in the notch zone drops the line (or brings a retracting one back); with files dragged there, an
        // empty line too.
        if let entered = notchEnteredAt, let anchor = notchAnchor, time - entered >= geometry.dwell(at: anchor) - 1e-9,
           !items.isEmpty || fileDrag != nil, state == .hidden || state == .retracting {
            beginReveal(hold: 0, freshPointer: true)
            updateDrop()
        }
        switch state {
        case .hidden:
            break
        case .revealing:
            let out = reduceMotion ? fade >= 1
                : (line.value > 0.985 && abs(line.velocity) < 0.3 && abs(fall.value - 1) < 0.02 && abs(fall.velocity) < 0.3)
            if out { state = .shown }
            if mayRetract && state == .shown { beginRetract() }
        case .shown:
            if mayRetract { beginRetract() }
        case .retracting:
            let gone = reduceMotion ? fade <= 0
                : (line.value < 0.002 && abs(line.velocity) < 0.05 && fall.value < 0.01 && abs(fall.velocity) < 0.05)
            if gone { finishHidden() }
        }
    }

    /// The hover lift and the press a card is headed for.
    private func liftGoal(_ id: UUID) -> Double { id == liftedCard || (id == hoveredCard && state != .retracting) ? 1 : 0 }
    private func pressGoal(_ id: UUID) -> Double { id == pressedCard ? 1 : 0 }

    /// Whether anything still moves.
    var isSettled: Bool {
        if reduceMotion {
            if abs(fade - fadeTarget) > 1e-9 || isReflowing { return false }
        } else if !line.isSettled(position: 0.0005, speed: 0.002) || !fall.isSettled(position: 0.0005, speed: 0.002) { return false }
        if !sag.isSettled(position: 0.05, speed: 0.5) { return false }
        if !scroller.isIdle { return false }
        if !ghostShow.isSettled(position: 0.002, speed: 0.01) || !dropGlow.isSettled(position: 0.002, speed: 0.01) { return false }
        if ghostShow.value > 0.002 && !ghostSlot.isSettled(position: 0.1, speed: 1) { return false }
        // Files held still near the end of a line with hidden cards: it keeps scrolling them into view.
        if edgeScrollVelocity != 0 { return false }
        // A card in the hand leans and swings under the pointer; one let go is on its way to its place.
        if liftedCard != nil { return false }
        for (id, c) in cards {
            // A card whose file a drag session carries is drawn by the system, not here.
            if c.held { continue }
            if c.leaving || c.leave.value > 0 || c.dropStart != nil || !c.arrived || c.aloft || c.returnedAt != nil { return false }
            if !c.drop.isSettled(position: 0.05, speed: 0.5) { return false }
            if !c.slot.isSettled(position: 0.1, speed: 1) || !c.dip.isSettled(position: 0.02, speed: 0.2) { return false }
            // Hover and press against where they are headed now, not the targets of the last substep: a pointer that
            // reaches or presses a card on a still line has to start the clock (the lift and the press answer at once).
            if abs(c.lift.value - liftGoal(id)) > 0.002 || abs(c.lift.velocity) > 0.01 { return false }
            if abs(c.press.value - pressGoal(id)) > 0.002 || abs(c.press.velocity) > 0.01 { return false }
            if abs(c.angle - c.targetAngle) > Self.pinFriction + 0.0005 || abs(c.spin) > 0.01 { return false }
            if abs(c.smoothVX) > 0.5 { return false }
        }
        return true
    }

    /// Whether the display-synced clock has to run: something moves, or a state change waits on motion.
    var needsFrames: Bool {
        if state == .revealing || state == .retracting { return true }
        if hasPendingDrops { return true }
        return !isSettled
    }

    /// The next time the state machine may change by itself while nothing moves (a hold or a dwell ending).
    var nextDeadline: Double? {
        var times: [Double] = []
        if let entered = notchEnteredAt, let anchor = notchAnchor, !items.isEmpty || fileDrag != nil,
           state == .hidden || state == .retracting {
            times.append(entered + geometry.dwell(at: anchor))
        }
        if let released = dragReleasedAt { times.append(released + Self.dropGrace) }
        if let promised = promisedUntil { times.append(promised) }
        // Not while held open: the hold would end in the past and the wake-up timer would fire again and again.
        if state == .shown, !holdOpen || items.isEmpty, !isMenuOpen, !pointerInBand, accessibilityFocus == nil, selectedCard == nil,
           pendingArrivals.isEmpty || items.isEmpty, !dropHover, dragReleasedAt == nil, liftedCard == nil, !hasCardAloft {
            var t = holdUntil
            if let left = pointerLeftAt, !items.isEmpty || fileDrag != nil { t = max(t, left + leaveGrace) }
            times.append(t)
        }
        return times.min()
    }

    /// Tests: replace one card's physics state.
    func setCardForTesting(_ card: Card) { cards[card.id] = card }

    /// Ends the motion where it is headed (tests, previews).
    func settleNow() {
        pendingArrivals.removeAll()
        line.snap(); fall.snap(); sag.snap()
        for (id, var c) in cards {
            if c.flight != nil { c = Self.grounded(c); c.startedAt = c.startedAt ?? time; c.arrived = true }
            c.slot.snap(); c.lift.snap(); c.press.snap(); c.dip.snap()
            c.angle = c.targetAngle; c.spin = 0
            if c.dropStart != nil { c.drop.snap(); c.arrived = true; c.dropStart = nil; c.startedAt = c.startedAt ?? time; c.pictureDeadline = nil }
            cards[id] = c
        }
        dips = []
    }

    // MARK: Geometry of the string

    struct Ends {
        var left: CGPoint
        var right: CGPoint
        /// How far the ends have spread from the notch (0…1).
        var spread: Double
        /// 0 = pulled up taut, 1 = hanging.
        var fall: Double
        /// The middle of the string, under (or inside) the notch.
        var apex: CGPoint
        /// Each half's own droop.
        var droop: Double
        var spreadLeft: Double { spread }
        var spreadRight: Double { spread }
    }

    func lineEnds() -> Ends {
        let full = fullEnds
        return Self.ends(spread: line.value, fall: fall.value, sag: sag.value, geometry: geometry, leftFull: full.left, rightFull: full.right)
    }

    /// Where the ends sit when the string spans the display: 14 pt inside the edges, or past an edge when cards are
    /// hidden beyond it (the string runs off the screen there, so cards never hang beyond its tack).
    var fullEnds: (left: CGFloat, right: CGFloat) {
        let reach = 60.0
        let hiddenLeft = ClotheslineMath.clamp(scroller.offset / reach, 0, 1)
        let hiddenRight = ClotheslineMath.clamp((scroller.maxOffset - scroller.offset) / reach, 0, 1)
        let l = ClotheslineMath.lerp(Double(geometry.leftEndX), -16, hiddenLeft)
        let r = ClotheslineMath.lerp(Double(geometry.rightEndX), Double(geometry.width) + 16, hiddenRight)
        return (CGFloat(l), CGFloat(r))
    }

    static func ends(spread e: Double, fall f: Double, sag: Double, geometry g: ClotheslineGeometry,
                     leftFull: CGFloat? = nil, rightFull: CGFloat? = nil) -> Ends {
        let nx = Double(g.notchCenterX), inner = Double(g.notchInnerHalf), half = Double(g.notchHalf)
        let s = max(0, e)
        let L = Double(leftFull ?? g.leftEndX), R = Double(rightFull ?? g.rightEndX)
        let lx = nx - inner - (nx - inner - L) * s
        let rx = nx + inner + (R - nx - inner) * s
        let ff = ClotheslineMath.clamp(f, -0.2, 1.3)
        let base = Double(g.lineY) - pulledLift * (1 - ClotheslineMath.clamp(ff, 0, 1)) + 10 * max(0, ff - 1)
        // Inside the notch's width the ends go up into it.
        func endY(_ d: Double) -> Double {
            ClotheslineMath.lerp(Double(g.hiddenY), base, ClotheslineMath.smoothstep(inner, half, d))
        }
        let span = rx - lx
        let S = min(max(0, sag), sagMaxShare * span)
        let apexY = ClotheslineMath.lerp(Double(g.ceilingY), base + S, max(0, ff))
        let droop = S / 4 * (0.4 + 0.6 * ClotheslineMath.clamp(ff, 0, 1))
        return Ends(left: CGPoint(x: lx, y: endY(nx - lx)), right: CGPoint(x: rx, y: endY(rx - nx)),
                    spread: s, fall: ff, apex: CGPoint(x: nx, y: apexY), droop: droop)
    }

    /// The pin's x on screen for a slot position: content coordinates scrolled, then gathered toward the notch.
    func pinX(slot: Double, ends: Ends) -> Double {
        let full = Double(geometry.leftEndX) + slot - scroller.offset
        let nx = Double(geometry.notchCenterX)
        return nx + (full - nx) * ends.spread
    }

    /// The string's height at x. Each half runs from its end to the apex under the notch with a little droop; hanging,
    /// the two halves make one smooth sag (a parabola), pulled up they make a shallow Λ. Near the notch a string close
    /// to the menu bar is drawn up into the notch; under a landing pin it dips.
    func stringY(at x: Double, ends e: Ends) -> Double {
        let g = geometry
        let nx = Double(g.notchCenterX)
        let end = x <= nx ? e.left : e.right
        let span = abs(nx - Double(end.x))
        let u = span > 0.5 ? ClotheslineMath.clamp(1 - abs(nx - x) / span, 0, 1) : 1
        var y = Double(end.y) + (Double(e.apex.y) - Double(end.y)) * u + 4 * e.droop * u * (1 - u)
        let d = abs(x - nx), half = Double(g.notchHalf)
        if d < half {
            let ceiling = Double(g.ceilingY)
            // A string drawn through a slot bends up into it gradually (across most of the notch's width, and as it
            // nears the bar), so a pin sliding under the notch edge, or the string falling out of it, never jumps.
            let w = (1 - ClotheslineMath.smoothstep(ceiling + 2, ceiling + 16, y)) * (1 - ClotheslineMath.smoothstep(0.2 * half, half - 1, d))
            y = ClotheslineMath.lerp(y, Double(g.hiddenY), w)
        }
        if !dips.isEmpty {
            let fromEnd = min(x - Double(e.left.x), Double(e.right.x) - x)
            let fixed = ClotheslineMath.clamp(fromEnd / 50, 0, 1)
            for dip in dips where abs(x - dip.x) < Self.dipHalfWidth {
                y += dip.depth * 0.5 * (1 + cos(.pi * (x - dip.x) / Self.dipHalfWidth)) * fixed
            }
        }
        return y
    }

    func slopeAt(_ x: Double, ends: Ends) -> Double {
        let dx = 1.5
        return (stringY(at: x + dx, ends: ends) - stringY(at: x - dx, ends: ends)) / (2 * dx)
    }

    /// The string as points for drawing, denser near the notch where it turns up into it.
    func stringPoints() -> [CGPoint] {
        let e = lineEnds()
        let lx = Double(e.left.x), rx = Double(e.right.x)
        let nx = Double(geometry.notchCenterX), half = Double(geometry.notchHalf)
        var points: [CGPoint] = []
        points.reserveCapacity(400)
        var x = lx
        while x < rx {
            points.append(CGPoint(x: x, y: stringY(at: x, ends: e)))
            x += abs(x - nx) < half + 4 ? 1.5 : 6
        }
        points.append(CGPoint(x: rx, y: stringY(at: rx, ends: e)))
        return points
    }

    /// The string's height just beside the notch, the part of its middle you can see (tests: how far it has
    /// fallen or been pulled up).
    var middleY: Double { stringY(at: Double(geometry.notchCenterX) - Double(geometry.notchHalf) - 6, ends: lineEnds()) }

    // MARK: Poses

    /// Draw order: leaving cards first, then oldest to newest (the newest on top).
    var drawOrder: [UUID] { leavingOrder + items.reversed().map(\.id) }

    /// Reduce Motion: the opacity of cards changing places (out, then in).
    var reflowAlpha: Double {
        guard let r = reflowStart else { return 1 }
        let t = time - r
        return t < Self.reflowFade ? max(0, 1 - t / Self.reflowFade) : min(1, (t - Self.reflowFade) / Self.reflowFade)
    }

    /// Reduce Motion: the opacity of one card changing places on its own (out, then in).
    func cardReflowAlpha(_ c: Card) -> Double {
        guard let r = c.reflowAt else { return 1 }
        let t = time - r
        return t < Self.reflowFade ? max(0, 1 - t / Self.reflowFade) : min(1, (t - Self.reflowFade) / Self.reflowFade)
    }

    /// Reduce Motion: how much a card shows while cards change places (tests).
    func reflowAlpha(of id: UUID) -> Double { cards[id].map { min(reflowAlpha, cardReflowAlpha($0)) } ?? 1 }

    /// Angles past `tiltKnee` are compressed so they never pass `maxShownTilt`.
    static func softLimit(_ a: Double) -> Double {
        let knee = ClotheslineMath.radians(tiltKnee), top = ClotheslineMath.radians(maxShownTilt)
        let m = abs(a)
        guard m > knee else { return a }
        return (a < 0 ? -1 : 1) * (knee + (top - knee) * tanh((m - knee) / (top - knee)))
    }

    func pose(_ id: UUID) -> ClotheslineCardPose? {
        guard let c = cards[id] else { return nil }
        if c.flight != nil { return flightPose(c) }
        if c.held { return heldPose(c) }
        let ends = lineEnds()
        let s = ClotheslineMath.clamp(line.value, 0, 1)
        // Cards ride the string up into the notch and fade only as its ends are reeled in.
        var alpha = reduceMotion ? fade : ClotheslineMath.smoothstep(0.015, 0.2, s)
        // Cards that were off the edge must not hang in the air beyond a short line while it travels.
        if s < 1 && !reduceMotion {
            let outside = max(Double(ends.left.x) - c.pivotX, c.pivotX - Double(ends.right.x), 0)
            let rule = ClotheslineMath.clamp(1 - outside / 30, 0, 1)
            alpha *= ClotheslineMath.lerp(1, rule, ClotheslineMath.clamp((1 - s) * 4, 0, 1))
        }
        if c.dropStart != nil {
            if let started = c.startedAt {
                // A dropped card fades in over the ghost (a cross-fade: the ghost fades out as much).
                if c.fromGhost { alpha *= handoffProgress(c) }
                else if reduceMotion { alpha *= ClotheslineMath.clamp((time - started) / Self.reduceMotionFade, 0, 1) }
                else { alpha *= ClotheslineMath.smoothstep(-Self.dropHeight, -Self.dropHeight * 0.45, c.drop.value) }
            } else {
                alpha = 0
            }
        } else if reduceMotion {
            alpha *= min(reflowAlpha, cardReflowAlpha(c))
        }
        // Lifting away fades it; put back (⌘Z), it fades in again from there.
        alpha *= max(0, 1 - c.leave.value)
        // Back from a drag that ended away from the line: it fades in at its place.
        if let back = c.returnedAt { alpha *= ClotheslineMath.smoothstep(back, back + Self.returnFade, time) }
        // Cards shrink with the string as it gathers, a little faster than their spacing (they never pile up).
        var scale = reduceMotion ? 1 : max(0.06, pow(s, 0.9))
        if !reduceMotion { scale *= 1 + 0.035 * c.lift.value - 0.03 * c.press.value }
        // A card let go by hand is drawn in the air (over the string and the other cards) until the string catches it.
        return ClotheslineCardPose(id: id, pivot: CGPoint(x: c.pivotX, y: c.pivotY), angle: Self.softLimit(c.angle),
                                   scale: scale, alpha: alpha, lift: c.lift.value, width: c.width, flying: c.aloft)
    }

    /// The card in the hand: its pin exactly where the pointer holds it now (not where it was at the last substep, so it
    /// never lags the hand), lifted and drawn in the air, over everything on the line. While a drag session carries its
    /// file the system draws it, and the line shows nothing for it.
    private func heldPose(_ c: Card) -> ClotheslineCardPose {
        let pin = heldPin ?? CGPoint(x: c.pivotX, y: c.pivotY)
        guard let d = cardDrag, d.id == c.id, !d.out else {
            return ClotheslineCardPose(id: c.id, pivot: pin, angle: Self.softLimit(c.angle), scale: 1, alpha: 0, lift: 0, width: c.width)
        }
        let scale = reduceMotion ? 1 : 1 + 0.035 * c.lift.value
        return ClotheslineCardPose(id: c.id, pivot: pin, angle: Self.softLimit(c.angle), scale: scale, alpha: 1,
                                   lift: c.lift.value, width: c.width, flying: true)
    }

    /// A card in the air: at its pin's flight position, full size once it has appeared at the origin (at once when it
    /// slides in from off the display), lifted.
    private func flightPose(_ c: Card) -> ClotheslineCardPose {
        let entering = c.flight?.entering ?? false
        let appear = c.startedAt.map { entering ? 1 : ClotheslineMath.smoothstep(0, 1, ClotheslineMath.clamp((time - $0) / Self.flightAppear, 0, 1)) } ?? 0
        let grow = Self.flightStartScale + (1 - Self.flightStartScale) * appear
        return ClotheslineCardPose(id: c.id, pivot: CGPoint(x: c.pivotX, y: c.pivotY), angle: Self.softLimit(c.angle),
                                   scale: grow * (1 + 0.035 * c.lift.value), alpha: appear, lift: c.lift.value, width: c.width,
                                   flying: true)
    }

    var poses: [ClotheslineCardPose] { drawOrder.compactMap(pose) }

    /// The line's own opacity (Reduce Motion fades it; otherwise it hides by going into the notch).
    var lineAlpha: Double {
        if reduceMotion { return fade }
        let base = ClotheslineMath.smoothstep(0, 0.03, line.value)
        // Without a real notch the string would show on the menu bar on its way in: fade it there.
        return geometry.hasNotch ? base : base * ClotheslineMath.smoothstep(0.02, 0.12, line.value)
    }

    // MARK: Hit testing

    /// The topmost card under a scene point. Nothing over the menu bar (the cards are clipped there).
    func cardID(at p: CGPoint, inflate: CGFloat = 0, minAlpha: Double = 0.5) -> UUID? {
        guard state != .hidden, p.y >= geometry.menuBarHeight else { return nil }
        for id in drawOrder.reversed() {
            // Not a screenshot's card in the air; a card let go and on its way to its place can be grabbed again.
            guard let c = cards[id], let pose = pose(id), pose.alpha >= minAlpha, !pose.flying || c.aloft, !c.leaving else { continue }
            if Self.contains(pose, p, inflate: inflate) { return id }
        }
        return nil
    }

    static func contains(_ pose: ClotheslineCardPose, _ p: CGPoint, inflate: CGFloat = 0) -> Bool {
        let local = toLocal(pose, p)
        let mat = ClotheslineCardMetrics.matRect(width: pose.width).insetBy(dx: -inflate, dy: -inflate)
        let pin = ClotheslineCardMetrics.pinRect.insetBy(dx: -inflate, dy: -inflate)
        return mat.contains(local) || pin.contains(local)
    }

    /// A scene point in the card's own frame (origin at the pivot, unrotated, unscaled).
    static func toLocal(_ pose: ClotheslineCardPose, _ p: CGPoint) -> CGPoint {
        let dx = Double(p.x - pose.pivot.x), dy = Double(p.y - pose.pivot.y)
        let c = cos(-pose.angle), s = sin(-pose.angle)
        let sc = max(pose.scale, 0.01)
        return CGPoint(x: (dx * c - dy * s) / sc, y: (dx * s + dy * c) / sc)
    }

    /// A point of the card's frame in scene coordinates.
    static func toScene(_ pose: ClotheslineCardPose, _ p: CGPoint) -> CGPoint {
        let x = Double(p.x) * pose.scale, y = Double(p.y) * pose.scale
        let c = cos(pose.angle), s = sin(pose.angle)
        return CGPoint(x: Double(pose.pivot.x) + x * c - y * s, y: Double(pose.pivot.y) + x * s + y * c)
    }

    /// The card's bounding box in scene coordinates (accessibility frames).
    static func bounds(_ pose: ClotheslineCardPose) -> CGRect {
        let r = ClotheslineCardMetrics.matRect(width: pose.width).union(ClotheslineCardMetrics.pinRect)
        let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                       CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)].map { toScene(pose, $0) }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    func item(_ id: UUID) -> ClotheslineItem? { items.first { $0.id == id } }
}
