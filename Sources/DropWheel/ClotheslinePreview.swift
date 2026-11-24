import AppKit
import QuartzCore

/// A snapshot view that can also write a video (`--snapshot <id> out.mp4`).
protocol SnapshotVideoRendering {
    func writeVideo(to url: URL) throws
}

/// The offscreen preview: the real engine, view and layers on a virtual clock (fixed 60 fps steps), drawn over a
/// mock desktop band (soft wallpaper, a menu bar with placeholder items and the black notch at the real geometry),
/// at 2x, cropped to the top 320 pt.
///
///     --snapshot clothesline out.png [--opt t=<seconds>] [--opt dark=true] [--opt files=a|b|c]
///     --snapshot clothesline out.mp4 [--opt dark=true] [--opt files=a|b|c] [--opt reduce=true] [--opt contrast=true]
///     [--opt older=<n>]: how many earlier files already hang on the line (default: enough to run off the right edge)
///
/// The scenario: hidden 0.3 s; three new files (an image, a video, a PDF) are hung on a line that already holds the
/// session's older files → the line drops out of the notch, the cards arrive and swing, it holds 2 s and retracts;
/// the pointer moves into the notch → the line drops with every card; two horizontal flicks → momentum, rubber band,
/// tilt; the pointer leaves → it retracts.
///
/// `--opt scenario=drop` (a taller crop that shows the desktop, 560 pt; four older files unless `older` says
/// otherwise; `files` names the dragged file, photo.png by default): a file icon is dragged up from the desktop to the
/// notch → after the 80 ms rest the line drops with the brighter string and the ghost under the pointer; the drag runs
/// along the string onto the cards, pauses (the gap open), runs on (the gap follows) and back; release at 5.0 s → the
/// card falls into its pin and swings; the pointer leaves → it holds 2 s and retracts. Later the pointer rests on the notch → the line drops; the new card is
/// dragged down off the line onto a folder on the desktop (the file moves there; its card stays on the line).
///
/// `--opt select=<n>` (the line scenario): the n-th card from the left (from 0) is clicked once the cards have landed
/// (2.2 s): it wears the selection ring and the line stays out (try t=3).
///
/// `--opt scenario=welcome`: a line that holds nothing but its welcome card (written to a temporary folder) drops out
/// of the notch at 0.3 s and holds 2 s (try t=1.6).
///
/// `--opt scenario=rearrange` (the drop scenario's crop; five older files unless `older` says otherwise; `files` names
/// the file dragged from the desktop): the pointer rests on the notch → the line drops; it presses the fourth card and
/// carries it along the string (lifted, hanging from its pin under the pointer, leaning; the gap follows it), pauses,
/// lets go at the second place → the pin catches the string, the card swings; it presses that card again and drags it
/// down off the line → it becomes a file drag (the system's picture of it), the gap closes and the line goes 0.35 s
/// later; let go on the Projects folder, the card is back in its place on the hidden line. Then a file is dragged up
/// from the desktop to the notch → the line drops with the ghost; the drag goes down well below the string and along
/// the cards' area → the line stays out and the gap follows; let go there, the file hangs; the pointer leaves.
enum ClotheslinePreview {
    static let cropHeight: CGFloat = 320
    /// The drop scenario's crop: the panel and the desktop under it, where the file starts and the folder sits.
    static let dropCropHeight: CGFloat = 560
    static let scale: CGFloat = 2
    static let fps = 60.0

    /// The scenario: files hung by a job (line), a file dropped on the line by hand (drop), a card moved along it
    /// (rearrange), or an empty line with its welcome card (welcome).
    enum Kind: String { case line, drop, rearrange, welcome }

    static func snapshotView(files: [URL], options: ToolOptions) -> NSView {
        let kind = Kind(rawValue: options.string("scenario", "line").lowercased()) ?? .line
        let fresh = kind == .drop || kind == .rearrange ? Array(newFiles(files: files, options: options).prefix(1))
            : kind == .welcome ? [] : newFiles(files: files, options: options)
        let older = options["older"].flatMap { Int($0) } ?? (kind == .drop ? 4 : kind == .rearrange ? 5 : kind == .welcome ? 0 : nil)
        let preview = Scenario(newFiles: fresh, olderFiles: olderFiles(excluding: fresh), dark: options.bool("dark", false),
                               reduceMotion: options.bool("reduce", false), geometry: .builtInSample, olderLimit: older, kind: kind)
        preview.surface.view.increaseContrast = options.bool("contrast", false)
        if let n = options["select"].flatMap({ Int($0) }) { preview.clickCard(n, at: 2.2) }
        return ClotheslinePreviewView(scenario: preview, stillTime: options.double("t", kind == .rearrange ? 3.2 : 1.45))
    }

    // MARK: Files

    static func fixturesRoot() -> URL? {
        let fm = FileManager.default
        var candidates = [URL(fileURLWithPath: fm.currentDirectoryPath)]
        var exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<5 { candidates.append(exe); exe.deleteLastPathComponent() }
        for c in candidates {
            let f = c.appendingPathComponent("Tests/fixtures")
            if fm.fileExists(atPath: f.appendingPathComponent("core").path) { return f }
        }
        return nil
    }

    static func newFiles(files: [URL], options: ToolOptions) -> [URL] {
        if let list = options["files"] {
            return list.split(separator: "|").map { URL(fileURLWithPath: String($0)) }
        }
        if !files.isEmpty { return files }
        guard let root = fixturesRoot()?.appendingPathComponent("core") else { return [] }
        return ["photo.png", "clip.mp4", "report.pdf"].map { root.appendingPathComponent($0) }
    }

    /// The session's earlier files: enough of the other fixtures to run off the right edge.
    static func olderFiles(excluding: [URL]) -> [URL] {
        guard let root = fixturesRoot()?.appendingPathComponent("features") else { return [] }
        let names = ["sample.avi", "deck.pptx", "camera.dng", "cocoa.docx", "scan.pdf", "odd.mkv", "report.xlsx",
                     "features.svg", "book.epub", "sample.md", "sample.wmv", "qr.svg", "tone.wav", "doc.pages"]
        let skip = Set(excluding.map(\.lastPathComponent))
        return names.filter { !skip.contains($0) }.map { root.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: Scenario

    /// One run of the preview: builds the line, plays scripted pointer and scroll input, renders frames.
    final class Scenario {
        let geometry: ClotheslineGeometry
        let engine: ClotheslineEngine
        let surface: ClotheslineOffscreenSurface
        let controller: ClotheslineController
        let dark: Bool
        private(set) var time = 0.0
        private var events: [(time: Double, run: (Scenario) -> Void)] = []
        private var nextEvent = 0
        /// The mock pointer, in scene coordinates.
        private(set) var pointer: CGPoint?
        let newFiles: [URL]
        let olderFiles: [URL]
        private var background: CGImage?
        /// The scenario's length in seconds.
        private(set) var duration = 11.2
        /// Seconds spent rendering frames (engine + layers + drawing), for the report.
        private(set) var renderSeconds = 0.0
        private(set) var renderedFrames = 0
        let kind: Kind
        /// How much of the display is drawn, from the top: the 320 pt band, or 560 pt for the drop and the rearrange
        /// (the desktop under the panel, where the file starts and the folder sits).
        let frameHeight: CGFloat
        /// The flight window, where a card in the hand is carried (rearrange scenario).
        let flight: ClotheslineFlightOffscreenSurface

        // The drop scenario: the mock drag pasteboard, the dragging info the panel is handed while it takes the drag,
        // what follows the pointer, and the desktop's file and folder.
        private var dragCount = 1
        private var dragPayload: [URL] = []
        private var dragInfo: ClotheslineDragInfo?
        private var overPanel = false
        /// The operation the line answered the drag with (the pointer's badge).
        private(set) var dragOperation: NSDragOperation = []
        private var dragImage: (image: CGImage, size: CGSize, offset: CGPoint)?
        /// A card dropped on the folder: its picture shrinking into it.
        private var sinking: (image: CGImage, size: CGSize, from: CGPoint, start: Double)?
        private var deskFileDimmed = false
        private var deskFileGone = false
        private var folderHot = false
        static let deskFile = CGPoint(x: 1150, y: 468)
        static let folder = CGPoint(x: 380, y: 462)
        static let iconSide: CGFloat = 64

        /// `olderLimit`: how many of the session's earlier files hang too (nil: enough to run off the right edge).
        init(newFiles: [URL], olderFiles: [URL], dark: Bool, reduceMotion: Bool, geometry: ClotheslineGeometry, olderLimit: Int? = nil,
             kind: Kind = .line) {
            self.geometry = geometry
            self.dark = dark
            self.newFiles = newFiles
            self.kind = kind
            frameHeight = kind == .drop || kind == .rearrange ? ClotheslinePreview.dropCropHeight : ClotheslinePreview.cropHeight
            engine = ClotheslineEngine(geometry: geometry, reduceMotion: reduceMotion, time: 0)
            surface = ClotheslineOffscreenSurface(engine: engine)
            surface.view.forcedDark = dark
            surface.view.pictureScale = ClotheslinePreview.scale
            flight = ClotheslineFlightOffscreenSurface(geometry: geometry)
            let clock = ClotheslineManualClock()
            // (The clock is set once the session's older files hang: `controller.now` below.)
            controller = ClotheslineController(engine: engine, surface: surface, clock: clock, now: { 0 })
            controller.usesTimers = false
            let flight = self.flight
            controller.makeFlightSurface = { _ in flight }
            let visible = CGRect(x: geometry.screenFrame.minX, y: geometry.screenFrame.minY, width: geometry.screenFrame.width,
                                 height: geometry.screenFrame.height - geometry.menuBarHeight)
            controller.visibleFrame = { visible }
            if kind == .welcome {
                // Drawn afresh each run (a picture left from an earlier build would be kept as it was).
                try? FileManager.default.removeItem(at: ClotheslineWelcome.url)
                let welcome = ClotheslineWelcome.write()
                ShelfThumbnails.preload([welcome].compactMap { $0 }, size: ClotheslineView.thumbnailRequest)
                controller.welcomeFile = { welcome }
            }
            let all = newFiles + olderFiles
            ShelfThumbnails.preload(all, size: ClotheslineView.thumbnailRequest)
            ClotheslineArt.preloadDurations(all)
            // Older files until the cards run past the right edge (so the flicks have somewhere to go).
            let lineLength = Double(geometry.rightEndX - geometry.leftEndX)
            var older: [URL] = []
            let view = surface.view
            for url in olderFiles {
                if let limit = olderLimit {
                    if older.count >= limit { break }
                } else {
                    let probe = (newFiles + older).reduce(0.0) { $0 + Double(view.width(for: $1)) + 22 } + 68
                    if probe > lineLength + 420 { break }
                }
                older.append(url)
            }
            self.olderFiles = older
            // The session so far: hung earlier, now gathered in the notch.
            if !older.isEmpty {
                engine.hang(older.reversed())
                engine.settleNow()
                engine.retract()
                for _ in 0..<600 where engine.state != .hidden { engine.step(ClotheslineEngine.substep) }
                engine.settleNow()
            }
            let clockStart = engine.time
            controller.now = { [unowned self] in clockStart + self.time }
            if ProcessInfo.processInfo.environment["DW_LINE_LOG"] != nil {
                engine.onStateChange = { [unowned self] st in
                    FileHandle.standardError.write("clothesline \(String(format: "%.3f", self.engine.time - clockStart)) s: \(st.rawValue)\n".data(using: .utf8)!)
                }
            }
            timeOffset = clockStart
            if kind == .drop || kind == .rearrange {
                // The drag pasteboard as a drag session would leave it, and the monitors as the app installs them.
                controller.dragChangeCount = { [unowned self] in self.dragCount }
                controller.dragFiles = { [unowned self] in self.dragPayload }
                controller.escapeDown = { false }
                controller.monitorInstaller = { ["pointer"] }
                controller.dropMonitorInstaller = { ["drag"] }
                controller.monitorRemover = { _ in }
                controller.watchDrops()
                if kind == .drop { dropScript() } else { rearrangeScript() }
            } else {
                script()
            }
        }

        private var timeOffset = 0.0

        private func at(_ t: Double, _ run: @escaping (Scenario) -> Void) { events.append((t, run)) }

        private func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }

        /// Moves the mock pointer from `a` to `b` over `[t0, t1]` (eased), one event per frame.
        private func move(from a: CGPoint, to b: CGPoint, _ t0: Double, _ t1: Double) {
            let frames = max(1, Int(((t1 - t0) * fps).rounded()))
            for i in 0...frames {
                let u = Double(i) / Double(frames)
                let e = u * u * (3 - 2 * u)
                let p = CGPoint(x: Double(a.x) + Double(b.x - a.x) * e, y: Double(a.y) + Double(b.y - a.y) * e)
                at(t0 + Double(i) / fps) { $0.setPointer(p) }
            }
        }

        /// A two-finger flick: deltas growing to `peak` points per frame over `frames`, then a release.
        private func flick(at t0: Double, peak: Double, frames: Int) {
            at(t0) { $0.scroll(.began, 0) }
            for i in 1...frames {
                let u = Double(i) / Double(frames)
                let d = peak * (0.35 + 0.65 * u)
                at(t0 + Double(i) / fps) { $0.scroll(.changed, d) }
            }
            at(t0 + Double(frames + 1) / fps) { $0.scroll(.ended, 0) }
        }

        /// Clicks the n-th card from the left at `t` (press and release where it hangs then): it is selected.
        func clickCard(_ n: Int, at t: Double) {
            at(t) { s in
                guard n >= 0, n < s.engine.items.count, let pose = s.engine.pose(s.engine.items[n].id) else { return }
                let p = ClotheslineEngine.toScene(pose, CGPoint(x: 0, y: 60))
                s.setPointer(p)
                s.surface.view.pressDown(at: p)
                s.surface.view.pressUp(at: p)
            }
        }

        private func script() {
            if kind == .welcome {
                at(0) { $0.setPointer(CGPoint(x: 1250, y: 520)) }
                at(0.3) { $0.controller.reveal() }
                duration = 4.5
                return
            }
            let n = geometry.notch
            let start = point(1250, 520)
            at(0) { $0.setPointer(start) }
            at(0.3) { $0.controller.hang($0.newFiles) }
            // After the retract: the pointer goes up to the notch and rests there.
            move(from: start, to: point(Double(n.midX) + 6, 16), 4.0, 4.55)
            // Down onto the cards.
            move(from: point(Double(n.midX) + 6, 16), to: point(1180, 132), 5.05, 5.6)
            // Flick toward the older files (content moves left), then back.
            flick(at: 5.95, peak: 34, frames: 9)
            flick(at: 7.75, peak: -46, frames: 9)
            // Away from the line: it retracts 0.6 s later.
            move(from: point(1180, 132), to: point(1260, 560), 9.4, 9.85)
            duration = 11.2
        }

        func setPointer(_ p: CGPoint) {
            pointer = p
            controller.pointerMoved(screen: geometry.screenPoint(fromScene: p))
        }

        // MARK: Drop scenario

        /// Moves the mock pointer along a quadratic curve from `a` through control `c` to `b` over `[t0, t1]` (eased),
        /// one event per frame, calling `step` with each point.
        private func curve(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ t0: Double, _ t1: Double, _ step: @escaping (Scenario, CGPoint) -> Void) {
            let frames = max(1, Int(((t1 - t0) * fps).rounded()))
            for i in 0...frames {
                let u = Double(i) / Double(frames)
                let e = u * u * (3 - 2 * u)
                let x = (1 - e) * (1 - e) * Double(a.x) + 2 * (1 - e) * e * Double(c.x) + e * e * Double(b.x)
                let y = (1 - e) * (1 - e) * Double(a.y) + 2 * (1 - e) * e * Double(c.y) + e * e * Double(b.y)
                at(t0 + Double(i) / fps) { step($0, CGPoint(x: x, y: y)) }
            }
        }

        private func dropScript() {
            guard let file = newFiles.first else { duration = 1; return }
            let n = geometry.notch
            let desk = Self.deskFile
            // Picked up by its right edge, so the drag image travels beside the pointer, not over the ghost's pin.
            let grab = CGPoint(x: desk.x + 28, y: desk.y + 2)
            let notch = point(Double(n.midX) + 4, 18)
            at(0) { $0.setPointer(grab) }
            // Press on the desktop file, then drag it up to the notch (the drag session writes the pasteboard).
            at(0.35) { $0.pressDesk(at: grab) }
            curve(grab, point(1120, 140), notch, 0.42, 1.3) { $0.dragFile(to: $1, file: file) }
            // Rest at the notch: after 80 ms the line drops with the ghost under the pointer.
            curve(notch, notch, notch, 1.3, 1.8) { $0.dragFile(to: $1, file: file) }
            // Down to the string, along it onto the cards, a pause there (the gap open), on along them (the gap
            // follows), and back.
            curve(notch, point(866, 44), point(858, 66), 1.8, 2.3) { $0.dragFile(to: $1, file: file) }
            curve(point(858, 66), point(700, 76), point(560, 70), 2.4, 3.0) { $0.dragFile(to: $1, file: file) }
            curve(point(560, 70), point(430, 74), point(300, 70), 3.5, 4.2) { $0.dragFile(to: $1, file: file) }
            curve(point(300, 70), point(380, 62), point(452, 66), 4.3, 4.8) { $0.dragFile(to: $1, file: file) }
            at(5.0) { $0.releaseFile() }
            // The pointer leaves: the line holds 2 s after the card lands, then retracts.
            move(from: point(452, 66), to: point(1000, 500), 5.5, 6.0)
            // Later: rest on the notch, the line drops; drag the new card down onto the folder.
            move(from: point(1000, 500), to: point(Double(n.midX) + 6, 16), 8.3, 8.8)
            at(9.3) { s in
                guard let pose = s.droppedPose() else { return }
                // Near the card's foot, so its picture travels above the pointer and the folder shows under it.
                s.pendingCardPoint = ClotheslineEngine.toScene(pose, CGPoint(x: 0, y: 104))
            }
            at(9.31) { s in
                guard let target = s.pendingCardPoint, let from = s.pointer else { return }
                s.scheduleMove(from: from, to: target, s.time, s.time + 0.5)
            }
            at(10.0) { $0.pressCard() }
            at(10.02) { s in
                guard let from = s.pointer else { return }
                let f = Self.folder
                s.scheduleCurve(from, CGPoint(x: Double(from.x) - 60, y: 380), CGPoint(x: f.x + 4, y: f.y - 2), s.time, s.time + 1.2) {
                    $0.dragCard(to: $1)
                }
            }
            at(11.4) { $0.releaseCard() }
            at(11.75) { s in
                guard let from = s.pointer else { return }
                s.scheduleMove(from: from, to: CGPoint(x: 640, y: 520), s.time, s.time + 0.5)
            }
            duration = 13.4
        }

        /// The card the drop made (the first card with the dragged file's name), as it hangs now.
        private func droppedPose() -> ClotheslineCardPose? {
            guard let file = newFiles.first, let item = engine.items.first(where: { $0.url.lastPathComponent == file.lastPathComponent })
            else { return nil }
            return engine.pose(item.id)
        }
        private var pendingCardPoint: CGPoint?

        /// Adds events while the scenario plays (moves that start from where the pointer is then).
        private func scheduleMove(from a: CGPoint, to b: CGPoint, _ t0: Double, _ t1: Double) {
            let frames = max(1, Int(((t1 - t0) * fps).rounded()))
            for i in 1...frames {
                let u = Double(i) / Double(frames)
                let e = u * u * (3 - 2 * u)
                let p = CGPoint(x: Double(a.x) + Double(b.x - a.x) * e, y: Double(a.y) + Double(b.y - a.y) * e)
                at(t0 + Double(i) / fps) { $0.setPointer(p) }
            }
        }

        private func scheduleCurve(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ t0: Double, _ t1: Double,
                                   _ step: @escaping (Scenario, CGPoint) -> Void) {
            curve(a, c, b, t0 + 1 / fps, t1, step)
        }

        private func screen(_ p: CGPoint) -> CGPoint { geometry.screenPoint(fromScene: p) }

        /// The mouse goes down on the desktop file.
        private func pressDesk(at p: CGPoint) {
            pointer = p
            controller.mouseEvent(.down, screen: screen(p))
        }

        /// A drag event of the file drag: the session writes the drag pasteboard once the pointer has moved 3 pt (the
        /// drag image appears then); the panel is handed the drag while it takes the mouse (as the window server would).
        private func dragFile(to p: CGPoint, file: URL) {
            let d = Self.deskFile
            if dragImage == nil, let from = pointer, hypot(p.x - from.x, p.y - from.y) >= 3 || dragPayload.isEmpty && time > 0.5 {
                dragCount += 1
                dragPayload = [file]
                deskFileDimmed = true
                if let icon = Self.iconImage(for: file) {
                    dragImage = (icon, CGSize(width: Self.iconSide, height: Self.iconSide), CGPoint(x: p.x - d.x, y: p.y - d.y))
                }
            }
            pointer = p
            controller.mouseEvent(.dragged, screen: screen(p))
            routeDrag(at: p, file: file)
        }

        /// Hands the drag to the panel's view while the panel takes the mouse (entered, updated, exited).
        private func routeDrag(at p: CGPoint, file: URL) {
            let view = surface.view
            let takes = !surface.ignoresMouse && p.y >= 0 && p.y < ClotheslineGeometry.panelHeight
            let local = CGPoint(x: p.x, y: view.bounds.height - p.y)
            if takes {
                if dragInfo == nil { dragInfo = ClotheslineDragInfo(files: [file], at: local) }
                dragInfo?.location = local
                guard let info = dragInfo else { return }
                dragOperation = overPanel ? view.draggingUpdated(info) : view.draggingEntered(info)
                overPanel = true
            } else if overPanel, let info = dragInfo {
                info.location = local
                view.draggingExited(info)
                overPanel = false
                dragOperation = []
            }
        }

        /// The button goes up: over the line the files are dropped (prepare, perform), then the monitors see the release.
        private func releaseFile() {
            guard let p = pointer else { return }
            if overPanel, let info = dragInfo {
                info.location = CGPoint(x: p.x, y: surface.view.bounds.height - p.y)
                if surface.view.prepareForDragOperation(info) { _ = surface.view.performDragOperation(info) }
                surface.view.draggingEnded(info)
            }
            controller.mouseEvent(.up, screen: screen(p))
            overPanel = false
            dragInfo = nil
            dragImage = nil
            dragOperation = []
            deskFileDimmed = false
        }

        /// The mouse goes down on the dropped card (the panel takes it there): the card answers the press.
        private func pressCard() {
            guard let pose = droppedPose() else { return }
            engine.setPressed(pose.id)
            controller.clotheslineNeedsUpdate()
            controller.mouseEvent(.down, screen: screen(pointer ?? .zero))
            dragCardID = pose.id
        }
        private var dragCardID: UUID?

        /// Dragging the card off the line: after 3 pt the drag session starts with the card's picture (the panel then
        /// lets the mouse through, so the folder below gets the drop); the folder highlights under the pointer.
        private func dragCard(to p: CGPoint) {
            if engine.pressedCard != nil, let id = dragCardID, let from = pointer, hypot(p.x - from.x, p.y - from.y) >= 3 {
                if let item = surface.view.draggingItem(for: id), let image = (item.imageComponents?.first?.contents as? NSImage)
                    .flatMap({ $0.cgImage(forProposedRect: nil, context: nil, hints: nil) }) {
                    let frame = item.draggingFrame
                    // The frame is in the view's (y-up) coordinates; the offset is from the frame's centre to the pointer.
                    let centre = CGPoint(x: frame.midX, y: surface.view.bounds.height - frame.midY)
                    dragImage = (image, frame.size, CGPoint(x: from.x - centre.x, y: from.y - centre.y))
                }
                engine.setPressed(nil)
                engine.isDragging = true
                controller.clotheslineNeedsUpdate()
            }
            pointer = p
            folderHot = Self.folderRect.contains(p)
            controller.mouseEvent(.dragged, screen: screen(p))
            controller.pointerMoved(screen: screen(p), buttonHeld: true)
        }

        /// Let go over the folder: the file moves there (on the same disk), its picture sinks into the folder and the
        /// file leaves the desktop; the card stays on the line, following the file.
        private func releaseCard() {
            guard let p = pointer else { return }
            if let image = dragImage, folderHot {
                sinking = (image.image, image.size, CGPoint(x: p.x - image.offset.x, y: p.y - image.offset.y), time)
                deskFileGone = true
            }
            dragImage = nil
            folderHot = false
            engine.isDragging = false
            controller.mouseEvent(.up, screen: screen(p))
            controller.clotheslineNeedsUpdate()
        }

        // MARK: Rearrange scenario

        private func rearrangeScript() {
            guard let file = newFiles.first else { duration = 1; return }
            let n = geometry.notch
            let notch = point(Double(n.midX) + 6, 16)
            let start = point(1000, 470)
            at(0) { $0.setPointer(start) }
            // Rest on the notch: the line drops.
            move(from: start, to: notch, 0.3, 0.8)
            // Down onto the fourth card; press it and carry it along the string to the second place.
            at(1.5) { $0.aimAtCard(3) }
            at(1.51) { s in
                guard let target = s.pendingCardPoint, let from = s.pointer else { return }
                s.scheduleMove(from: from, to: target, s.time, s.time + 0.55)
            }
            at(2.3) { $0.pressLineCard() }
            at(2.35) { s in
                // The pin goes over the second card's place, 18 pt above the string; the pointer keeps its grab on the
                // fourth card (where it pressed, from that card's pin).
                guard let from = s.pointer, s.engine.items.count > 3, let second = s.engine.pose(s.engine.items[1].id),
                      let held = s.engine.pose(s.engine.items[3].id) else { return }
                let grab = CGPoint(x: from.x - held.pivot.x, y: from.y - held.pivot.y)
                let x = Double(second.pivot.x), y = s.engine.stringY(at: x, ends: s.engine.lineEnds()) - 18
                let to = CGPoint(x: x + Double(grab.x), y: y + Double(grab.y))
                s.scheduleCurve(from, CGPoint(x: (Double(from.x) + Double(to.x)) / 2, y: Double(min(from.y, to.y)) - 26), to,
                                s.time, s.time + 1.25) { $0.carryCard(to: $1) }
            }
            at(4.0) { $0.releaseLineCard() }
            // Press the same card again (now second) and drag it down off the line, onto the Projects folder.
            at(4.7) { $0.aimAtCard(1) }
            at(4.71) { s in
                guard let target = s.pendingCardPoint, let from = s.pointer else { return }
                s.scheduleMove(from: from, to: target, s.time, s.time + 0.4)
            }
            at(5.3) { $0.pressLineCard() }
            at(5.35) { s in
                guard let from = s.pointer else { return }
                let f = Self.folder
                s.scheduleCurve(from, CGPoint(x: Double(from.x) - 30, y: 330), CGPoint(x: f.x + 4, y: f.y - 2), s.time, s.time + 1.3) {
                    $0.carryCard(to: $1)
                }
            }
            at(7.0) { $0.releaseLineCard() }
            // A file from the desktop: up to the notch, then well below the string and along the cards' area.
            let desk = Self.deskFile
            let grab = CGPoint(x: desk.x + 28, y: desk.y + 2)
            at(7.3) { s in s.scheduleMove(from: s.pointer ?? grab, to: grab, s.time, s.time + 0.5) }
            at(8.0) { $0.pressDesk(at: grab) }
            curve(grab, point(1120, 140), notch, 8.07, 8.9) { $0.dragFile(to: $1, file: file) }
            curve(notch, notch, notch, 8.9, 9.35) { $0.dragFile(to: $1, file: file) }
            curve(notch, point(900, 120), point(820, 205), 9.35, 10.0) { $0.dragFile(to: $1, file: file) }
            curve(point(820, 205), point(560, 222), point(300, 196), 10.2, 11.4) { $0.dragFile(to: $1, file: file) }
            at(11.75) { $0.releaseFile() }
            move(from: point(300, 196), to: point(1000, 520), 12.2, 12.7)
            duration = 15.6
        }

        /// The point the pointer goes to on card `index` (near its foot, so the picture travels above the pointer).
        private func aimAtCard(_ index: Int) {
            guard index < engine.items.count, let pose = engine.pose(engine.items[index].id) else { return }
            pendingCardPoint = ClotheslineEngine.toScene(pose, CGPoint(x: 8, y: 92))
        }

        /// The mouse goes down on a line card: the drag monitor hears it, then the view (the panel takes it there).
        private func pressLineCard() {
            guard let p = pointer else { return }
            controller.mouseEvent(.down, screen: screen(p))
            surface.view.pressDown(at: p)
        }

        /// The pressed mouse moves: the monitor and the view hear it while the panel has the mouse; once the card's file
        /// is in a drag session only the monitor's poll does (the system draws the card under the pointer then).
        private func carryCard(to p: CGPoint) {
            pointer = p
            controller.mouseEvent(.dragged, screen: screen(p))
            surface.view.pressMoved(to: p)
            if engine.cardDrag?.out == true {
                if dragImage == nil, let item = surface.view.lastDraggingItem,
                   let image = (item.imageComponents?.first?.contents as? NSImage).flatMap({ $0.cgImage(forProposedRect: nil, context: nil, hints: nil) }) {
                    let frame = item.draggingFrame
                    let centre = CGPoint(x: frame.midX, y: surface.view.bounds.height - frame.midY)
                    dragImage = (image, frame.size, CGPoint(x: p.x - centre.x, y: p.y - centre.y))
                }
                folderHot = Self.folderRect.contains(p)
            }
        }

        /// The mouse goes up: a card in the hand hangs at the gap; a card's file let go on the folder moves there (its
        /// picture sinks in) and the card is back in its place on the line.
        private func releaseLineCard() {
            guard let p = pointer else { return }
            let out = engine.cardDrag?.out == true
            controller.mouseEvent(.up, screen: screen(p))
            if out {
                if let image = dragImage, folderHot {
                    sinking = (image.image, image.size, CGPoint(x: p.x - image.offset.x, y: p.y - image.offset.y), time)
                }
                surface.view.ownDragEnded()
            } else {
                surface.view.pressUp(at: p)
            }
            dragImage = nil
            folderHot = false
        }

        static var folderRect: CGRect {
            CGRect(x: folder.x - 44, y: folder.y - iconSide / 2 - 6, width: 88, height: iconSide + 30)
        }

        /// A file's picture for the desktop icon and the drag image (its thumbnail, else its Finder icon).
        static func iconImage(for url: URL) -> CGImage? {
            let picture = ShelfThumbnails.cached(url, size: ClotheslineView.thumbnailRequest)?.image ?? NSWorkspace.shared.icon(forFile: url.path)
            let side = Int(iconSide * ClotheslinePreview.scale)
            guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return nil }
            let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ns
            let box = CGRect(x: 0, y: 0, width: side, height: side).insetBy(dx: 4, dy: 4)
            let size = picture.size
            let s = min(box.width / max(size.width, 1), box.height / max(size.height, 1))
            let r = CGRect(x: box.midX - size.width * s / 2, y: box.midY - size.height * s / 2, width: size.width * s, height: size.height * s)
            // Finder draws a picture's icon with a thin white border and a soft shadow.
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(white: 0, alpha: 0.3)
            shadow.shadowBlurRadius = 3
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            NSGraphicsContext.saveGraphicsState()
            shadow.set()
            NSColor.white.setFill()
            r.insetBy(dx: -2.5, dy: -2.5).fill()
            NSGraphicsContext.restoreGraphicsState()
            picture.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            return ctx.makeImage()
        }

        /// The desktop's file and folder, the drag image and the folder's highlight (drawn per frame, under the pointer).
        private func drawDesk(in ctx: CGContext) {
            guard kind == .drop || kind == .rearrange else { return }
            let side = Self.iconSide
            func label(_ text: String, at c: CGPoint, highlighted: Bool = false) {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white,
                    .shadow: { let s = NSShadow(); s.shadowColor = NSColor(white: 0, alpha: 0.55); s.shadowBlurRadius = 2
                               s.shadowOffset = NSSize(width: 0, height: -1); return s }(),
                ]
                let string = NSAttributedString(string: text, attributes: attributes)
                let size = string.size()
                let r = CGRect(x: c.x - size.width / 2, y: cy(c.y + side / 2 + 6) - size.height, width: size.width, height: size.height)
                if highlighted {
                    DWPalette.accent.setFill()
                    NSBezierPath(roundedRect: r.insetBy(dx: -5, dy: -1), xRadius: 4, yRadius: 4).fill()
                }
                string.draw(at: r.origin)
            }
            let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ns
            // The folder, highlighted while a card is over it (as Finder does).
            let f = Self.folder
            if folderHot {
                NSColor(white: 0, alpha: dark ? 0.32 : 0.22).setFill()
                NSBezierPath(roundedRect: CGRect(x: f.x - side / 2 - 6, y: cy(f.y + side / 2 + 4), width: side + 12, height: side + 8),
                             xRadius: 7, yRadius: 7).fill()
            }
            let folderIcon = NSWorkspace.shared.icon(for: .folder)
            folderIcon.draw(in: CGRect(x: f.x - side / 2, y: cy(f.y + side / 2), width: side, height: side))
            label("Projects", at: f, highlighted: folderHot)
            // The file on the desktop: dimmed while it is dragged, gone once it was moved into the folder.
            if !deskFileGone, let file = newFiles.first, let icon = Self.iconImage(for: file) {
                let d = Self.deskFile
                ctx.saveGState()
                ctx.setAlpha(deskFileDimmed ? 0.45 : 1)
                ctx.draw(icon, in: CGRect(x: d.x - side / 2, y: cy(d.y + side / 2), width: side, height: side))
                ctx.restoreGState()
                label(file.lastPathComponent, at: d)
            }
            NSGraphicsContext.restoreGraphicsState()
            // A card dropped on the folder sinks into it.
            if let s = sinking {
                let u = ClotheslineMath.clamp((time - s.start) / 0.25, 0, 1)
                if u < 1 {
                    let k = 1 - 0.85 * u
                    let c = CGPoint(x: Double(s.from.x) + Double(f.x - s.from.x) * u, y: Double(s.from.y) + Double(f.y - s.from.y) * u)
                    ctx.saveGState()
                    ctx.setAlpha(CGFloat(1 - u))
                    ctx.draw(s.image, in: CGRect(x: c.x - s.size.width * k / 2, y: cy(c.y) - s.size.height * k / 2,
                                                 width: s.size.width * k, height: s.size.height * k))
                    ctx.restoreGState()
                }
            }
        }

        /// What follows the pointer during a drag (the system draws it: translucent, at the grab offset).
        private func drawDragImage(in ctx: CGContext) {
            guard let d = dragImage, let p = pointer else { return }
            let c = CGPoint(x: p.x - d.offset.x, y: p.y - d.offset.y)
            ctx.saveGState()
            ctx.setAlpha(0.78)
            ctx.draw(d.image, in: CGRect(x: c.x - d.size.width / 2, y: cy(c.y) - d.size.height / 2, width: d.size.width, height: d.size.height))
            ctx.restoreGState()
        }

        func scroll(_ phase: ClotheslineScrollInput.Phase, _ delta: Double) {
            controller.clotheslineScroll(ClotheslineScrollInput(phase: phase, delta: delta, time: 0))
        }

        /// Advances the virtual clock to `t` seconds into the scenario (fixed frame steps).
        func advance(to t: Double) {
            while time + 1e-9 < t {
                time = min(t, time + 1 / fps)
                while nextEvent < events.count, events.sorted(by: { $0.time < $1.time })[nextEvent].time <= time + 1e-9 {
                    let e = events.sorted(by: { $0.time < $1.time })[nextEvent]
                    nextEvent += 1
                    e.run(self)
                }
                controller.tick(at: timeOffset + time)
            }
        }

        // MARK: Drawing

        var pixelSize: (w: Int, h: Int) {
            (Int(geometry.width * scale), Int(frameHeight * scale))
        }

        /// The current frame as BGRA pixels.
        func frame() -> CGImage? {
            let started = CACurrentMediaTime()
            defer { renderSeconds += CACurrentMediaTime() - started; renderedFrames += 1 }
            let (w, h) = pixelSize
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return nil }
            draw(in: ctx)
            return ctx.makeImage()
        }

        func draw(in ctx: CGContext) {
            if background == nil { background = makeBackground() }
            let (w, h) = pixelSize
            if let background { ctx.draw(background, in: CGRect(x: 0, y: 0, width: w, height: h)) }
            ctx.saveGState()
            ctx.scaleBy(x: scale, y: scale)
            // The panel covers the top 300 pt of the frame.
            ctx.translateBy(x: 0, y: frameHeight - ClotheslineGeometry.panelHeight)
            surface.view.render()
            surface.view.layer?.render(in: ctx)
            ctx.restoreGState()
            if kind == .rearrange, flight.isShown {
                // A card in the hand is carried in the flight window, over the whole display.
                ctx.saveGState()
                ctx.scaleBy(x: scale, y: scale)
                ctx.translateBy(x: 0, y: frameHeight - geometry.screenFrame.height)
                flight.view.layer?.render(in: ctx)
                ctx.restoreGState()
            }
            ctx.saveGState()
            ctx.scaleBy(x: scale, y: scale)
            // The drag image goes under the notch (no pixels there), the pointer over it as in the other scenario.
            drawDesk(in: ctx)
            drawDragImage(in: ctx)
            drawNotch(in: ctx)
            if let p = pointer, p.y < frameHeight + 20 {
                drawPointer(at: p, in: ctx)
                if dragOperation.contains(.link) { drawLinkBadge(at: p, in: ctx) }
            }
            ctx.restoreGState()
        }

        /// Scene y (down) to frame y (up).
        private func cy(_ y: CGFloat) -> CGFloat { frameHeight - y }

        private func makeBackground() -> CGImage? {
            let (w, h) = pixelSize
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return nil }
            ctx.scaleBy(x: scale, y: scale)
            let W = geometry.width, H = frameHeight
            let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ns
            // Wallpaper: a soft diagonal gradient with two big blurred blooms.
            let colors: [NSColor] = dark
                ? [NSColor(srgbRed: 0.12, green: 0.12, blue: 0.22, alpha: 1), NSColor(srgbRed: 0.27, green: 0.16, blue: 0.27, alpha: 1)]
                : [NSColor(srgbRed: 0.80, green: 0.80, blue: 0.95, alpha: 1), NSColor(srgbRed: 0.98, green: 0.86, blue: 0.84, alpha: 1)]
            NSGradient(colors: colors)?.draw(in: CGRect(x: 0, y: 0, width: W, height: H), angle: -18)
            for (x, y, r, a) in [(0.22, 0.2, 420.0, 0.22), (0.74, 0.75, 520.0, 0.16)] as [(Double, Double, Double, Double)] {
                let c = dark ? NSColor(srgbRed: 0.55, green: 0.38, blue: 0.62, alpha: a) : NSColor(white: 1, alpha: a)
                let g = NSGradient(colors: [c, c.withAlphaComponent(0)])
                g?.draw(fromCenter: CGPoint(x: W * x, y: H * y), radius: 0, toCenter: CGPoint(x: W * x, y: H * y), radius: r, options: [])
            }
            // The menu bar: a light (or dark) translucent band with placeholder items.
            let bar = geometry.menuBarHeight
            (dark ? NSColor(white: 0.08, alpha: 0.42) : NSColor(white: 1, alpha: 0.5)).setFill()
            CGRect(x: 0, y: H - bar, width: W, height: bar).fill(using: .sourceOver)
            let ink = dark ? NSColor(white: 1, alpha: 0.78) : NSColor(white: 0.1, alpha: 0.72)
            let faint = dark ? NSColor(white: 1, alpha: 0.42) : NSColor(white: 0.1, alpha: 0.36)
            var x: CGFloat = 22
            for (i, wd) in [15, 44, 30, 32, 36, 30, 52].map({ CGFloat($0) }).enumerated() {
                (i == 0 ? ink : (i == 1 ? ink : faint)).setFill()
                let r = i == 0 ? CGRect(x: x, y: H - bar / 2 - 7.5, width: 15, height: 15)
                               : CGRect(x: x, y: H - bar / 2 - 4, width: wd, height: 8)
                (i == 0 ? NSBezierPath(ovalIn: r) : NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)).fill()
                x += wd + (i == 0 ? 18 : 16)
            }
            var rx = W - 22
            for wd in [92.0, 18, 22, 18, 18, 20].map({ CGFloat($0) }) {
                rx -= wd
                (wd > 60 ? faint : ink).setFill()
                let r = wd > 60 ? CGRect(x: rx, y: H - bar / 2 - 4, width: wd, height: 8)
                                : CGRect(x: rx, y: H - bar / 2 - wd / 2 + 2, width: wd, height: wd - 4)
                NSBezierPath(roundedRect: r, xRadius: wd > 60 ? 4 : 4.5, yRadius: wd > 60 ? 4 : 4.5).fill()
                rx -= 14
            }
            NSGraphicsContext.restoreGraphicsState()
            return ctx.makeImage()
        }

        /// The camera housing: pure black, square top, rounded lower corners (drawn over everything, like the glass).
        private func drawNotch(in ctx: CGContext) {
            guard geometry.hasNotch else { return }
            let n = geometry.notch
            let r: CGFloat = 9
            let p = CGMutablePath()
            p.move(to: CGPoint(x: n.minX - 6, y: cy(0)))
            p.addQuadCurve(to: CGPoint(x: n.minX, y: cy(6)), control: CGPoint(x: n.minX, y: cy(0)))
            p.addLine(to: CGPoint(x: n.minX, y: cy(n.maxY - r)))
            p.addQuadCurve(to: CGPoint(x: n.minX + r, y: cy(n.maxY)), control: CGPoint(x: n.minX, y: cy(n.maxY)))
            p.addLine(to: CGPoint(x: n.maxX - r, y: cy(n.maxY)))
            p.addQuadCurve(to: CGPoint(x: n.maxX, y: cy(n.maxY - r)), control: CGPoint(x: n.maxX, y: cy(n.maxY)))
            p.addLine(to: CGPoint(x: n.maxX, y: cy(6)))
            p.addQuadCurve(to: CGPoint(x: n.maxX + 6, y: cy(0)), control: CGPoint(x: n.maxX, y: cy(0)))
            p.closeSubpath()
            ctx.addPath(p)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath()
            // Everything above the screen's top edge is bezel.
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fill(CGRect(x: 0, y: frameHeight, width: geometry.width, height: 10))
        }

        /// The drag-link pointer's badge (the line answers a drag with a link: no "+", the file stays where it is).
        private func drawLinkBadge(at p: CGPoint, in ctx: CGContext) {
            let box = CGRect(x: p.x + 10, y: cy(p.y) - 26, width: 12, height: 12)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -0.5), blur: 1.5, color: NSColor(white: 0, alpha: 0.35).cgColor)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil))
            ctx.fillPath()
            ctx.restoreGState()
            // A curved arrow, as on the system's alias pointer.
            let arc = CGMutablePath()
            arc.move(to: CGPoint(x: box.minX + 3, y: box.minY + 3))
            arc.addQuadCurve(to: CGPoint(x: box.maxX - 4, y: box.maxY - 4), control: CGPoint(x: box.minX + 3, y: box.maxY - 3.5))
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineWidth(1.4)
            ctx.setLineCap(.round)
            ctx.addPath(arc)
            ctx.strokePath()
            let head = CGMutablePath()
            head.move(to: CGPoint(x: box.maxX - 2, y: box.maxY - 4))
            head.addLine(to: CGPoint(x: box.maxX - 6.5, y: box.maxY - 1.8))
            head.addLine(to: CGPoint(x: box.maxX - 5.8, y: box.maxY - 6.8))
            head.closeSubpath()
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.addPath(head)
            ctx.fillPath()
        }

        /// A plain arrow pointer (black with a white rim), tip at `p`.
        private func drawPointer(at p: CGPoint, in ctx: CGContext) {
            let tip = CGPoint(x: p.x, y: cy(p.y))
            let pts: [(CGFloat, CGFloat)] = [(0, 0), (0, -17), (4.2, -13), (7.2, -19.6), (9.8, -18.4), (6.9, -11.9), (12.3, -11.9)]
            let path = CGMutablePath()
            path.addLines(between: pts.map { CGPoint(x: tip.x + $0.0, y: tip.y + $0.1) })
            path.closeSubpath()
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 2.5, color: NSColor(white: 0, alpha: 0.35).cgColor)
            ctx.addPath(path)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.setLineWidth(2.2)
            ctx.setLineJoin(.round)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.drawPath(using: .fillStroke)
            ctx.restoreGState()
            ctx.addPath(path)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath()
        }

        // MARK: Video

        /// Renders every frame and pipes it to ffmpeg (H.264, yuv420p, 60 fps).
        func writeVideo(to url: URL) throws {
            guard let ffmpeg = Capabilities.shared.ffmpeg else {
                throw ConversionError.toolFailed("The preview video needs ffmpeg. Install it (for example with Homebrew) and try again.")
            }
            let (w, h) = pixelSize
            let process = Process()
            process.executableURL = ffmpeg
            process.arguments = ["-hide_banner", "-loglevel", "error", "-y", "-f", "rawvideo", "-pix_fmt", "bgra",
                                 "-video_size", "\(w)x\(h)", "-framerate", "\(Int(fps))", "-i", "-",
                                 "-c:v", "libx264", "-preset", "medium", "-crf", "18", "-pix_fmt", "yuv420p",
                                 "-movflags", "+faststart", url.path]
            let input = Pipe()
            let errors = Pipe()
            process.standardInput = input
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            let frames = Int((duration * fps).rounded())
            let handle = input.fileHandleForWriting
            var buffer = [UInt8](repeating: 0, count: w * h * 4)
            for i in 0...frames {
                advance(to: Double(i) / fps)
                let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
                    guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
                    else { return false }
                    let started = CACurrentMediaTime()
                    // Raw frames are top row first; the context's memory is too (CG bitmap rows run top-down).
                    draw(in: ctx)
                    renderSeconds += CACurrentMediaTime() - started
                    renderedFrames += 1
                    return true
                }
                guard ok else { break }
                try handle.write(contentsOf: Data(buffer))
            }
            try handle.close()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let text = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                throw ConversionError.toolFailed("ffmpeg couldn’t encode the preview: \(text.prefix(300))")
            }
            FileHandle.standardError.write(String(format: "clothesline preview: %d frames, %.2f ms per frame (engine + layers + drawing)\n",
                                                  renderedFrames, renderSeconds / Double(max(renderedFrames, 1)) * 1000).data(using: .utf8)!)
        }
    }
}

/// `--snapshot clothesline`: the frame at `t` as a view (PNG), or the whole scenario as a video (MP4).
final class ClotheslinePreviewView: NSView, SnapshotVideoRendering {
    let scenario: ClotheslinePreview.Scenario
    private let still: CGImage?

    init(scenario: ClotheslinePreview.Scenario, stillTime: Double) {
        self.scenario = scenario
        scenario.advance(to: max(0, stillTime))
        still = scenario.frame()
        super.init(frame: CGRect(x: 0, y: 0, width: scenario.geometry.width, height: scenario.frameHeight))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let still, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = .high
        ctx.draw(still, in: bounds)
    }

    func writeVideo(to url: URL) throws {
        // A fresh run from the start (the still advanced this one).
        let fresh = ClotheslinePreview.Scenario(newFiles: scenario.newFiles, olderFiles: scenario.olderFiles + [],
                                                dark: scenario.dark, reduceMotion: scenario.engine.reduceMotion,
                                                geometry: scenario.geometry, olderLimit: scenario.olderFiles.count, kind: scenario.kind)
        fresh.surface.view.increaseContrast = scenario.surface.view.increaseContrast
        try fresh.writeVideo(to: url)
    }
}
