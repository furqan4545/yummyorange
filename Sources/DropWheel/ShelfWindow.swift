import AppKit

/// How a shelf shows its files. New shelves open in the mode last picked.
enum ShelfViewMode: String {
    case stack, list

    private static let key = "shelf.viewMode"
    static var last: ShelfViewMode {
        get { UserDefaults.standard.string(forKey: key).flatMap(ShelfViewMode.init) ?? .stack }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

/// Keeps every open shelf alive while the app runs and opens new ones. One of them is your shelf: Open Shelf shows it,
/// new files go on it (Show New Files › On a Shelf), and so do copied screenshots. Its files are saved, so closing it or
/// quitting loses nothing; other shelves (Float's) are gone when closed.
final class ShelfManager {
    static let shared = ShelfManager()
    private(set) var shelves: [ShelfController] = []
    /// Your shelf, while it is open.
    private(set) weak var mine: ShelfController?
    static let mineKey = "shelf.mine"
    /// Where your shelf's files are kept: paths, oldest first, as the shelf orders them. Tests swap both, so no
    /// preferences file is written.
    static var loadPaths: () -> [String] = { UserDefaults.standard.stringArray(forKey: mineKey) ?? [] }
    static var savePaths: ([String]) -> Void = { UserDefaults.standard.set($0, forKey: mineKey) }
    /// The most files your shelf keeps; the oldest go first.
    static let mineLimit = 500
    private var screenObserver: NSObjectProtocol?

    private init() {
        // A display unplugged or rearranged: bring every shelf back onto a screen.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.shelves.forEach { $0.settle(animated: false, pointer: nil) }
        }
    }

    // MARK: Your shelf

    /// Your shelf's files: those still on disk, oldest first.
    var savedFiles: [URL] {
        get {
            Self.loadPaths().map { URL(fileURLWithPath: $0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
        }
        set {
            var seen = Set<String>()
            let paths = newValue.map { $0.standardizedFileURL.path }.filter { seen.insert($0).inserted }
            Self.savePaths(Array(paths.suffix(Self.mineLimit)))
        }
    }

    /// Open Shelf: your shelf with its files, brought forward when it is already open, else opened near `point`.
    @discardableResult
    func openMine(near point: CGPoint = NSEvent.mouseLocation) -> ShelfController {
        if let mine {
            mine.model.refresh()
            mine.panel.orderFrontRegardless()
            return mine
        }
        let shelf = open(savedFiles, near: point)
        adopt(shelf)
        return shelf
    }

    /// Puts files on your shelf. Open, it shows them at once; closed, they are kept for the next time it opens, and
    /// `show` opens it near the pointer (a finished job), while a copied screenshot goes on quietly.
    func addToMine(_ files: [URL], show: Bool) {
        if let mine {
            mine.model.add(files)   // saved through the model's change handler
            if show { mine.panel.orderFrontRegardless() }
            return
        }
        savedFiles = savedFiles + files.filter { FileManager.default.fileExists(atPath: $0.path) }
        if show { openMine() }
    }

    /// Whether a file is on your shelf (open or closed).
    func mineContains(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if let mine { return mine.model.urls.contains { $0.standardizedFileURL.path == path } }
        return Self.loadPaths().contains(path)
    }

    /// Makes `shelf` your shelf: every change to its files (added, removed, cleared, followed after a move) is saved.
    private func adopt(_ shelf: ShelfController) {
        mine = shelf
        let viewHandler = shelf.model.onChange
        shelf.model.onChange = { [weak self, weak shelf] in
            viewHandler?()
            guard let self, let shelf, self.mine === shelf else { return }
            self.savedFiles = shelf.model.urls
        }
        savedFiles = shelf.model.urls
    }

    // MARK: Other shelves

    /// Opens a new shelf near `point` (screen coordinates), holding `files`. An empty list opens an empty shelf.
    @discardableResult
    func open(_ files: [URL], near point: CGPoint = NSEvent.mouseLocation, mode: ShelfViewMode? = nil) -> ShelfController {
        let others = shelves.map(\.frame)
        let shelf = ShelfController(files: files, mode: mode ?? .last)
        shelves.append(shelf)
        shelf.onClose = { [weak self, weak shelf] in self?.shelves.removeAll { $0 === shelf } }
        shelf.show(near: point, avoiding: others)
        return shelf
    }
}

/// A borderless floating panel that never activates YummyOrange, so the app you're working in stays in front.
/// It can still become key, so the list takes Delete and ⌘ shortcuts after a click.
final class ShelfPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// One shelf: its panel, its files, and where it sits on screen.
final class ShelfController {
    let model: ShelfModel
    let view: ShelfView
    let panel: ShelfPanel
    var onClose: (() -> Void)?
    /// The screen edges the shelf is snapped to.
    private(set) var docked: ShelfGeometry.Edges = []

    var frame: CGRect { panel.frame }

    init(files: [URL], mode: ShelfViewMode) {
        model = ShelfModel(files)
        view = ShelfView(model: model, mode: mode)
        panel = ShelfPanel(contentRect: CGRect(origin: .zero, size: view.preferredSize),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovable = false            // ShelfView moves it, so it can snap when let go
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.title = "Shelf"
        panel.contentView = view
        view.controller = self
    }

    func show(near point: CGPoint, avoiding others: [CGRect]) {
        let visible = Self.visibleFrame(for: CGRect(origin: point, size: .zero), pointer: point)
        let start = ShelfGeometry.initialFrame(size: view.preferredSize, pointer: point, visible: visible, others: others)
        let snap = ShelfGeometry.snapped(start, in: visible)
        apply(snap.frame, edges: snap.edges, animated: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.reduceMotion ? 0 : 0.15
            panel.animator().alphaValue = 1
        }
    }

    func close() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.reduceMotion ? 0 : 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.panel.orderOut(nil)
            self.onClose?()
        })
    }

    func setMode(_ mode: ShelfViewMode) {
        guard view.mode != mode else { return }
        ShelfViewMode.last = mode
        view.mode = mode
        fitToContent()
    }

    /// Grows or shrinks the panel to the content, keeping a docked edge docked.
    func fitToContent() {
        let size = view.preferredSize
        guard size != panel.frame.size else { return }
        let resized = ShelfGeometry.resized(panel.frame, to: size, keeping: docked)
        let visible = Self.visibleFrame(for: resized, pointer: nil)
        let target: CGRect
        var edges = docked
        if docked.isEmpty {
            target = ShelfGeometry.clamped(resized, in: visible)
        } else {
            (target, edges) = ShelfGeometry.snapped(resized, in: visible)
        }
        apply(target, edges: edges, animated: panel.isVisible)
    }

    /// While the shelf is carried it isn't docked anywhere.
    func moveBegan() {
        docked = []
        view.docked = []
    }

    func moveEnded() { settle(animated: true, pointer: NSEvent.mouseLocation) }

    /// Keeps the shelf on screen and snaps it to an edge it is close to.
    func settle(animated: Bool, pointer: CGPoint?) {
        let visible = Self.visibleFrame(for: panel.frame, pointer: pointer)
        let snap = ShelfGeometry.snapped(panel.frame, in: visible)
        apply(snap.frame, edges: snap.edges, animated: animated)
    }

    private func apply(_ frame: CGRect, edges: ShelfGeometry.Edges, animated: Bool) {
        docked = edges
        view.docked = edges
        if animated && !Self.reduceMotion {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }, completionHandler: { [weak self] in self?.panel.invalidateShadow() })
        } else {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        }
    }

    /// The visible area (without menu bar and Dock) of the screen under the pointer, or the one holding most of `frame`.
    static func visibleFrame(for frame: CGRect, pointer: CGPoint?) -> CGRect {
        let screens = NSScreen.screens
        if let p = pointer, let s = screens.first(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(p) }) {
            return s.visibleFrame
        }
        if let i = ShelfGeometry.bestScreen(for: frame, among: screens.map(\.frame)) { return screens[i].visibleFrame }
        return NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 875)
    }

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}
