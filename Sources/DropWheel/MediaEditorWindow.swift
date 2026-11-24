import AppKit
import AVFoundation

/// The base class of every audio/video editor window (Trim; Bleep, Crop, Redact… build on it). It owns:
/// - a titled window (title = file name, subtitle = `toolName`, represented URL, frame autosave, sensible minimum
///   size) with a unified toolbar: the tool's items in the middle, Undo and Redo, then Save as the one prominent item;
/// - the preview (video only), the transport bar (play/pause, time, the tool's accessory, zoom) and the timeline;
/// - loading: AVFoundation plays the file when it can, otherwise a temporary H.264/AAC proxy is made with ffmpeg while
///   the window shows "Preparing preview…" with progress (deleted on close). The film strip and waveform load in the
///   background. Edits always run on the original file;
/// - keys: Space play/pause, I/O set in/out, ⇧I/⇧O go to them, ← → one frame (⇧ one second), Home/End, ⌘+ ⌘− ⌘0
///   zoom, ⌘Z/⇧⌘Z, ⌘S, ⌘W, Esc cancels a drag or text edit (never closes), ⌫ removes the selected range (multiple);
/// - Undo for range edits, the "Discard your changes?" sheet, and Save: the options from `makeOptions()` run through
///   `JobRunner.run(.command(command, options), on: [file])` — the same code as `--tool <id> --opt …` — and the
///   window closes while the HUD shows progress;
/// - offscreen rendering for `--snapshot` (`snapshotView`).
///
/// Subclass it and override the hooks under "Hooks"; open windows with `open(files, editor: MyEditor.self)`.
class MediaEditorWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    private static var openControllers: [MediaEditorWindowController] = []
    /// Open editor windows with changes that haven't been saved (the updater asks before a restart would lose them).
    static var unsavedCount: Int { openControllers.filter { $0.hasChanges && !$0.isSnapshot }.count }
    /// Most editor windows one drop opens.
    static let maxWindows = 4

    let source: MediaSource
    let isSnapshot: Bool
    let window: ImageEditors.EditorWindow
    let content = MediaEditorContentView()
    /// The picture (video files only).
    let preview: MediaPreviewView?
    let transport: MediaTransportBar
    private(set) var timeline: MediaTimelineView!
    /// nil in snapshots.
    let playback: MediaPlayback?
    let undo = UndoManager()

    /// The ranges as last committed (the timeline shows these, or a live copy while dragging).
    private(set) var ranges: [MediaRange] = []
    private(set) var selectedRange: Int?
    private(set) var playhead: Double = 0
    /// AVFoundation (the file itself or the proxy) is ready to show frames.
    private(set) var playerReady = false

    private var toolItems: [NSToolbarItem] = []
    private var undoItem: NSToolbarItem?
    private var redoItem: NSToolbarItem?
    private var saveItem: NSToolbarItem?
    /// The folder of the preview proxy, while there is one (deleted when the window closes).
    private(set) var proxyDir: URL?
    private var proxyJob: MediaJob?
    private var stillBusy = false
    private var stillPending: Double?
    private var closing = false

    // MARK: Hooks

    /// The window subtitle and the tool's name in messages ("Trim").
    class var toolName: String { "Edit" }
    /// The command Save runs.
    var command: WheelCommand? { nil }
    var timelineMode: MediaTimelineView.Mode { .single }
    /// The ranges a fresh window starts with: the whole file in single mode, none otherwise.
    func initialRanges() -> [MediaRange] {
        timelineMode == .single ? [MediaRange(start: 0, end: source.duration)] : []
    }
    /// Whether closing should ask first (and, unless `canSave` says otherwise, whether Save is enabled).
    var hasChanges: Bool { ranges != initialRanges() }
    /// Whether Save is enabled. Defaults to `hasChanges`; a tool that always has something to save (Snapshot)
    /// returns true without making closing ask.
    var canSave: Bool { hasChanges }
    /// Whether the toolbar shows Undo and Redo (a tool with nothing to undo leaves them out).
    var showsUndoRedo: Bool { true }
    /// The options for `command`; throw a ConversionError to refuse Save with a message.
    func makeOptions() throws -> ToolOptions { [:] }
    /// Toolbar items for the middle of the toolbar.
    func makeToolItems() -> [NSToolbarItem] { [] }
    /// The tool's controls in the transport bar (between the time and the zoom buttons).
    func makeTransportAccessory() -> NSView? { nil }
    /// After the ranges change: `live` during a drag, false once committed (also after Undo and Redo).
    func rangesDidChange(live: Bool) {}
    func playheadDidChange() {}
    /// Keys the tool handles itself, checked before the kit's own (not while a text field is being edited).
    func handleToolKey(_ event: NSEvent) -> Bool { false }
    /// The informative text of the "Discard your changes?" sheet.
    var discardMessage: String { "Your changes to \(source.name) haven’t been saved." }
    /// Once the preview shows frames (in snapshots: after the still is set).
    func previewDidLoad() {}
    /// Snapshot options for the tool's state (the base handles playhead, zoom, width, height, dark).
    func applySnapshotOptions(_ options: ToolOptions) {}
    /// Once the window, toolbar, preview and timeline exist (also in snapshots): install overlays, set up state.
    func didBuild() {}
    /// Toolbar label and tooltip of Save.
    var saveToolTip: String { "Save a copy next to the original (⌘S)" }
    /// Refuses a file this editor can't work on before its window opens (Bleep needs sound, Crop a picture);
    /// the error shows in the HUD.
    class func check(_ source: MediaSource) throws {}

    // MARK: Opening

    /// Opens one window per audio or video file (at most `maxWindows`), on the next turn of the run loop so the drop
    /// that asked for it finishes first. Errors show in the HUD.
    static func open(_ files: [URL], editor: MediaEditorWindowController.Type) {
        MainThread.async {
            let media = files.filter { [.video, .audio].contains(MoreFormats.kind($0)) }
            guard !media.isEmpty else {
                HUD.shared.flash("Drop video or audio files to \(editor.toolName.lowercased()) them.", isError: true)
                return
            }
            var errors: [String] = []
            var opened = 0
            for url in media.prefix(maxWindows) {
                do {
                    let source = try MediaSource.load(url)
                    guard source.duration > 0 else {
                        throw ConversionError.unsupported("\(url.lastPathComponent) reports no length, so it can’t be edited. Convert it first.")
                    }
                    try editor.check(source)
                    let controller = editor.init(source: source, snapshot: false)
                    openControllers.append(controller)
                    controller.show(cascade: opened)
                    opened += 1
                } catch {
                    errors.append(media.count == 1 ? error.localizedDescription : "\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            if !errors.isEmpty { HUD.shared.flash(errors.joined(separator: " "), isError: true) }
            else if media.count > maxWindows { HUD.shared.flash("Opened \(maxWindows) of \(media.count) files. Editors open \(maxWindows) at a time.") }
        }
    }

    required init(source: MediaSource, snapshot: Bool) {
        self.source = source
        self.isSnapshot = snapshot
        let visible = Self.screen.visibleFrame
        let wanted = source.hasVideo ? CGSize(width: 1100, height: 780) : CGSize(width: 960, height: 420)
        let size = CGSize(width: min(wanted.width, visible.width * 0.88).rounded(), height: min(wanted.height, visible.height * 0.88).rounded())
        // A snapshot draws as the active window (traffic lights, the accent Save), as the image editors' snapshots do.
        let rect = CGRect(origin: .zero, size: size), style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        window = snapshot ? ImageEditors.SnapshotWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
                          : ImageEditors.EditorWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
        preview = source.hasVideo ? MediaPreviewView(source: source) : nil
        transport = MediaTransportBar(hairlines: source.hasVideo ? [.minY, .maxY] : [.maxY])
        playback = snapshot ? nil : MediaPlayback()
        super.init()
        build()
    }

    private func build() {
        timeline = MediaTimelineView(source: source, mode: timelineMode)
        ranges = initialRanges()
        selectedRange = timelineMode == .single ? 0 : nil
        timeline.setRanges(ranges, selected: selectedRange)
        undo.groupsByEvent = false

        window.isReleasedWhenClosed = false
        window.title = source.name
        window.subtitle = Self.toolName
        window.representedURL = isSnapshot ? nil : source.url
        // Audio windows show "Preparing preview…" in the transport bar, so they need room for it beside the controls.
        window.contentMinSize = source.hasVideo ? CGSize(width: 760, height: 540) : CGSize(width: 880, height: 320)
        window.delegate = self
        window.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .line

        toolItems = makeToolItems()
        let toolbar = NSToolbar(identifier: "DropWheelMedia.\(Self.toolName)")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        // The tool's own controls sit in the centre (toolbars.md › Item groupings: common controls in the center
        // area, the primary action on the trailing edge), as in the image and Edit PDF editors.
        toolbar.centeredItemIdentifiers = Self.centered(toolItems)
        window.toolbar = toolbar

        transport.accessory = makeTransportAccessory()
        transport.duration = source.duration
        transport.playButton.target = self
        transport.playButton.action = #selector(togglePlayAction)
        transport.zoomInButton.target = self
        transport.zoomInButton.action = #selector(zoomInAction)
        transport.zoomOutButton.target = self
        transport.zoomOutButton.action = #selector(zoomOutAction)
        transport.setPlayable(false)

        content.preview = preview
        content.transport = transport
        content.timeline = timeline
        window.contentView = content

        timeline.onScrub = { [weak self] t, _ in self?.scrub(to: t) }
        timeline.onLiveRanges = { [weak self] live in self?.rangesDidChange(live: true); self?.updateLiveReadouts(live) }
        timeline.onCommitRanges = { [weak self] new, selected, name in self?.setRanges(new, selected: selected, action: name) }
        timeline.onSelectionChange = { [weak self] index in self?.selectedRange = index; self?.rangesDidChange(live: false) }

        if let playback {
            playback.seekNudge = source.hasVideo ? MediaPlayback.videoSeekNudge : 0
            playback.onTime = { [weak self] t in self?.playbackMoved(to: t) }
            playback.onPlayingChange = { [weak self] playing in
                self?.transport.isPlaying = playing
                self?.timeline.followsPlayhead = playing
            }
        }
        rangesDidChange(live: false)
        didBuild()
        updateToolbar()
    }

    /// The screen under the pointer (where the drop happened), else the main screen.
    private static var screen: NSScreen {
        NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private var autosaveName: String { "DropWheel Media \(Self.toolName) \(source.hasVideo ? "Video" : "Audio")" }

    private func show(cascade index: Int) {
        if !window.setFrameUsingName(autosaveName) {
            let visible = Self.screen.visibleFrame, frame = window.frame
            window.setFrameOrigin(CGPoint(x: (visible.midX - frame.width / 2).rounded(),
                                          y: (visible.midY - frame.height / 2 + visible.height * 0.05).rounded()))
        }
        window.setFrameAutosaveName(autosaveName)
        if index > 0 {
            let o = window.frame.origin
            window.setFrameOrigin(CGPoint(x: o.x + CGFloat(index) * 28, y: o.y - CGFloat(index) * 28))
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.makeFirstResponder(nil)
        loadPreview()
    }

    // MARK: Loading

    /// Starts loading the film strip, the waveform and the preview (AVFoundation, or a proxy it can play).
    /// `show` calls it; tests call it on a window that is never shown.
    func loadPreview() {
        let src = source
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let strip = MediaKit.filmStrip(src)
            DispatchQueue.main.async { self?.timeline.strip = strip }
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let peaks = MediaKit.peaks(src)
            DispatchQueue.main.async { self?.timeline.peaks = peaks }
        }
        if preview != nil { requestStill(at: 0) }
        MediaKit.checkPlayable(source) { [weak self] ok in
            guard let self, !self.closing else { return }
            if ok { self.loadPlayer(self.source.url, isProxy: false) } else { self.makeProxy() }
        }
    }

    private func loadPlayer(_ url: URL, isProxy: Bool) {
        guard let playback else { return }
        playback.onReady = { [weak self] ok in
            guard let self, !self.closing else { return }
            if !ok {
                if !isProxy { self.makeProxy() } else { self.previewFailed() }
                return
            }
            self.playerReady = true
            self.preview?.hideLoading()
            self.transport.setPlayable(true)
            self.transport.showStatus(nil)
            playback.seek(to: self.playhead)
            self.previewDidLoad()
        }
        playback.load(url)
        preview?.attach(playback.player)
    }

    private func makeProxy() {
        let dir = MediaKit.makePreviewFolder()
        proxyDir = dir
        let job = MediaJob()
        proxyJob = job
        showPreparing(0)
        let src = source
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let url = try MediaKit.makeProxy(src, in: dir, job: job) { p in
                    DispatchQueue.main.async { self?.showPreparing(p) }
                }
                DispatchQueue.main.async {
                    guard let self, !self.closing else { return }
                    self.loadPlayer(url, isProxy: true)
                }
            } catch {
                DispatchQueue.main.async { if let self, !self.closing { self.previewFailed() } }
            }
        }
    }

    private func showPreparing(_ progress: Double) {
        // A progress report that arrives after the player is ready (or the window closed) is stale.
        guard !playerReady, !closing else { return }
        if let preview { preview.showLoading("Preparing preview…", progress: progress) }
        else { transport.showStatus("Preparing preview…", progress: progress) }
    }

    private func previewFailed() {
        if let preview {
            preview.showLoading("Preview isn’t available for this file. You can still \(Self.toolName.lowercased()) it.", progress: nil)
        } else {
            transport.showStatus("Can’t preview this file", progress: nil, isError: true)
        }
    }

    /// The frame at `t` through ffmpeg, while AVFoundation can't show it yet (a proxy is being made). Only the latest
    /// request runs after the current one.
    private func requestStill(at t: Double) {
        guard preview != nil else { return }
        stillPending = t
        guard !stillBusy else { return }
        stillBusy = true
        let src = source
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = MediaKit.stillFrame(src, at: t, maxPixels: 1280)
            DispatchQueue.main.async {
                guard let self else { return }
                if let image { self.preview?.still = image }
                self.stillBusy = false
                if let next = self.stillPending, next != t, !self.playerReady { self.requestStill(at: next) } else { self.stillPending = nil }
            }
        }
    }

    // MARK: Playhead and playback

    /// Moves the playhead to `t` (snapped to a frame) and shows that frame.
    func scrub(to t: Double) {
        playback?.pause()
        setPlayhead(source.snap(t))
        timeline.reveal(playhead)
    }

    func setPlayhead(_ t: Double, seek: Bool = true) {
        playhead = min(max(0, t), source.duration)
        timeline.playhead = playhead
        transport.time = playhead
        if seek, !isSnapshot {
            if playerReady { playback?.seek(to: playhead) } else { requestStill(at: playhead) }
        }
        playheadDidChange()
    }

    private func playbackMoved(to t: Double) {
        setPlayhead(t, seek: false)
    }

    /// Space: plays the selection (single mode) from the playhead when it is inside, else from its start, and stops
    /// at its end; otherwise plays from the playhead to the end (from the start when at the end).
    func togglePlay() {
        guard let playback, playerReady else { NSSound.beep(); return }
        if playback.isPlaying { playback.pause(); return }
        let fd = source.frameDuration
        if timelineMode == .single, let r = ranges.first {
            if playhead < r.start - fd / 2 || playhead >= r.end - fd / 2 { setPlayhead(r.start) }
            playback.play(until: r.end, settle: max(r.start, source.snap(r.end - fd)))
        } else {
            if playhead >= source.duration - fd / 2 { setPlayhead(0) }
            playback.play()
        }
    }

    @objc private func togglePlayAction() { togglePlay() }
    @objc private func zoomInAction() { timeline.zoomIn() }
    @objc private func zoomOutAction() { timeline.zoomOut() }

    // MARK: Ranges and Undo

    /// Commits new ranges as one undoable step named `action` ("Set Start").
    func setRanges(_ new: [MediaRange], selected: Int?, action: String) {
        let old = ranges, oldSelected = selectedRange
        let sorted = timelineMode == .single ? Array(new.prefix(1)) : new.sorted { $0.start < $1.start }
        let selection = timelineMode == .single ? 0 : selected.flatMap { $0 < sorted.count ? $0 : nil }
        guard sorted != old || selection != oldSelected else {
            timeline.setRanges(old, selected: oldSelected)
            return
        }
        undo.beginUndoGrouping()
        undo.registerUndo(withTarget: self) { target in
            target.setRanges(old, selected: oldSelected, action: action)
            target.revealChange(from: sorted, to: old)
        }
        undo.setActionName(action)
        undo.endUndoGrouping()
        ranges = sorted
        selectedRange = selection
        timeline.setRanges(sorted, selected: selection)
        rangesDidChange(live: false)
        updateLiveReadouts(sorted)
        updateToolbar()
    }

    /// Shows `new` as the ranges without registering Undo: for tools whose own model owns the times (Redact shows
    /// the selected box's time range in single mode and keeps its own Undo).
    func replaceRanges(_ new: [MediaRange], selected: Int?) {
        ranges = timelineMode == .single ? Array(new.prefix(1)) : new.sorted { $0.start < $1.start }
        selectedRange = timelineMode == .single ? 0 : selected.flatMap { $0 < ranges.count ? $0 : nil }
        timeline.setRanges(ranges, selected: selectedRange)
        rangesDidChange(live: false)
        updateLiveReadouts(ranges)
        updateToolbar()
    }

    /// After Undo or Redo, scroll to the edge that changed so the result is visible.
    private func revealChange(from a: [MediaRange], to b: [MediaRange]) {
        for (x, y) in zip(a, b) where x != y {
            timeline.reveal(x.start != y.start ? y.start : y.end)
            return
        }
        if let last = b.last ?? a.last { timeline.reveal(last.start) }
    }

    func performUndo() { if undo.canUndo { undo.undo() } else { NSSound.beep() }; updateToolbar() }
    func performRedo() { if undo.canRedo { undo.redo() } else { NSSound.beep() }; updateToolbar() }
    @objc private func undoAction() { performUndo() }
    @objc private func redoAction() { performRedo() }

    /// I: the selection starts at the playhead (single), or the selected range does (multiple; a new one-second
    /// range when none is selected or the playhead is past its end).
    func setInPoint() {
        let t = source.snap(playhead), fd = source.frameDuration
        switch timelineMode {
        case .none: NSSound.beep()
        case .single:
            guard var r = ranges.first, t < source.duration - fd / 2 else { NSSound.beep(); return }
            if t >= r.end - fd / 2 { r.end = source.duration }
            r.start = t
            setRanges([r], selected: 0, action: "Set Start")
        case .multiple:
            if let i = selectedRange, i < ranges.count, t < ranges[i].end - fd / 2 {
                var all = ranges
                let lower = i > 0 ? all[i - 1].end : 0
                all[i].start = max(t, lower)
                setRanges(all, selected: i, action: "Set Start")
            } else {
                addRange(MediaRange(start: t, end: min(source.duration, t + 1)))
            }
        }
    }

    /// O: the selection ends after the frame under the playhead (the frame you see is kept); for sound, at the
    /// playhead.
    func setOutPoint() {
        let t = source.snap(playhead), fd = source.frameDuration
        let end = source.hasVideo ? source.snapEnd(min(source.duration, t + fd)) : t
        switch timelineMode {
        case .none: NSSound.beep()
        case .single:
            guard var r = ranges.first, end > fd / 2 else { NSSound.beep(); return }
            if end <= r.start + fd / 2 { r.start = 0 }
            r.end = end
            setRanges([r], selected: 0, action: "Set End")
        case .multiple:
            if let i = selectedRange, i < ranges.count, end > ranges[i].start + fd / 2 {
                var all = ranges
                let upper = i + 1 < all.count ? all[i + 1].start : source.duration
                all[i].end = min(end, upper)
                setRanges(all, selected: i, action: "Set End")
            } else {
                addRange(MediaRange(start: max(0, end - 1), end: end))
            }
        }
    }

    /// Adds a range (multiple mode), trimmed so it doesn't overlap its neighbours, and selects it.
    func addRange(_ range: MediaRange) {
        var r = range
        if let before = ranges.last(where: { $0.start <= r.start }), before.end > r.start { r.start = before.end }
        if let after = ranges.first(where: { $0.start > range.start }), after.start < r.end { r.end = after.start }
        guard r.length >= source.frameDuration / 2 else { NSSound.beep(); return }
        var all = ranges + [r]
        all.sort { $0.start < $1.start }
        setRanges(all, selected: all.firstIndex(of: r), action: "Add Range")
    }

    func removeSelectedRange() {
        guard timelineMode == .multiple, let i = selectedRange, i < ranges.count else { NSSound.beep(); return }
        var all = ranges
        all.remove(at: i)
        setRanges(all, selected: nil, action: "Delete Range")
    }

    /// Updates read-outs during a drag (the tool's fields); override `rangesDidChange(live:)` for more.
    func updateLiveReadouts(_ live: [MediaRange]) {}

    // MARK: Keys

    func handleKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let editingText = window.firstResponder is NSText
        if flags.contains(.command) {
            switch key {
            case "s": save(); return true
            case "z":
                endTextEditing()
                flags.contains(.shift) ? performRedo() : performUndo()
                return true
            case "w": window.performClose(nil); return true
            case "=", "+": timeline.zoomIn(); return true
            case "-": timeline.zoomOut(); return true
            case "0": timeline.zoomToFit(); return true
            case "x", "c", "v", "a":
                guard editingText, let text = window.firstResponder as? NSText else { return false }
                let actions: [String: Selector] = ["x": #selector(NSText.cut(_:)), "c": #selector(NSText.copy(_:)),
                                                   "v": #selector(NSText.paste(_:)), "a": #selector(NSText.selectAll(_:))]
                return NSApp.sendAction(actions[key]!, to: text, from: self)
            default: return false
            }
        }
        if editingText {
            // The field keeps its keys; Esc puts its text back and leaves it.
            if event.keyCode == 53 { abortTextEditing(); return true }
            return false
        }
        if handleToolKey(event) { return true }
        let shift = flags.contains(.shift)
        switch event.keyCode {
        case 49: togglePlay(); return true                                                          // Space
        case 123: scrub(to: shift ? playhead - 1 : source.step(playhead, by: -1)); return true      // ←
        case 124: scrub(to: shift ? playhead + 1 : source.step(playhead, by: 1)); return true       // →
        case 115: scrub(to: 0); return true                                                         // Home
        case 119: scrub(to: source.hasVideo ? source.snap(source.duration - source.frameDuration) : source.duration); return true // End
        case 53: if timeline.isDragging { timeline.cancelDrag() }; return true                     // Esc
        case 51, 117: if timelineMode == .multiple { removeSelectedRange(); return true }; return false // ⌫ ⌦
        default: break
        }
        guard flags.subtracting(.shift).isEmpty else { return false }
        switch key {
        case "i":
            if shift { goToSelectionEdge(start: true) } else { setInPoint() }
            return true
        case "o":
            if shift { goToSelectionEdge(start: false) } else { setOutPoint() }
            return true
        default: return false
        }
    }

    /// ⇧I / ⇧O: the playhead to the first or last kept frame of the selection.
    private func goToSelectionEdge(start: Bool) {
        let index = timelineMode == .single ? 0 : selectedRange
        guard let i = index, i < ranges.count else { NSSound.beep(); return }
        let r = ranges[i]
        scrub(to: start ? r.start : max(r.start, source.snap(r.end - source.frameDuration)))
    }

    private func endTextEditing() {
        if window.firstResponder is NSText { window.makeFirstResponder(nil) }
    }

    private func abortTextEditing() {
        if let editor = window.firstResponder as? NSText, let field = editor.delegate as? NSTextField {
            field.abortEditing()
            rangesDidChange(live: false)
        }
        window.makeFirstResponder(nil)
    }

    // MARK: Toolbar

    private static let undoID = NSToolbarItem.Identifier("media.undo")
    private static let redoID = NSToolbarItem.Identifier("media.redo")
    private static let saveID = NSToolbarItem.Identifier("media.save")

    /// The tool items the toolbar centres: all of them except spaces (a space at either end of the list would only
    /// push the centred group off centre, so those are dropped from the toolbar too).
    static func centered(_ items: [NSToolbarItem]) -> Set<NSToolbarItem.Identifier> {
        Set(items.map(\.itemIdentifier).filter { $0 != .space && $0 != .flexibleSpace })
    }

    /// Leading to trailing: a flexible space, the tool's items (centred), a flexible space, Undo and Redo, then Save.
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        var tools = toolItems.map(\.itemIdentifier)
        while let first = tools.first, first == .space || first == .flexibleSpace { tools.removeFirst() }
        while let last = tools.last, last == .space || last == .flexibleSpace { tools.removeLast() }
        return [.flexibleSpace] + tools + [.flexibleSpace] + (showsUndoRedo ? [Self.undoID, Self.redoID, .space] : [])
            + [Self.saveID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if let item = toolItems.first(where: { $0.itemIdentifier == id }) { return item }
        switch id {
        case Self.undoID:
            let item = symbolItem(id, symbol: "arrow.uturn.backward", label: "Undo", tip: "Undo (⌘Z)", action: #selector(undoAction))
            undoItem = item
            return item
        case Self.redoID:
            let item = symbolItem(id, symbol: "arrow.uturn.forward", label: "Redo", tip: "Redo (⇧⌘Z)", action: #selector(redoAction))
            redoItem = item
            return item
        case Self.saveID:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Save"
            item.toolTip = saveToolTip
            item.autovalidates = false
            // The image editors' accent push button. An item's `.prominent` style draws nothing in YummyOrange's
            // toolbars (pre-Liquid Glass look), which left Save as plain grey text on screen.
            let button = ImageEditors.Bar.ProminentButton(title: "Save", target: self, action: #selector(saveAction))
            button.toolTip = saveToolTip
            button.setAccessibilityLabel("Save")
            item.view = button
            let menu = NSMenuItem(title: "Save", action: #selector(saveAction), keyEquivalent: "s")
            menu.target = self
            item.menuFormRepresentation = menu
            saveItem = item
            return item
        default:
            return nil
        }
    }

    /// An icon-only toolbar item with a label for VoiceOver and the overflow menu.
    func symbolItem(_ id: NSToolbarItem.Identifier, symbol: String, label: String, tip: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.label = label
        item.toolTip = tip
        item.target = self
        item.action = action
        item.isBordered = true
        item.autovalidates = false
        return item
    }

    func updateToolbar() {
        undoItem?.isEnabled = undo.canUndo
        redoItem?.isEnabled = undo.canRedo
        undoItem?.toolTip = undo.canUndo ? "\(undo.undoMenuItemTitle) (⌘Z)" : "Undo (⌘Z)"
        redoItem?.toolTip = undo.canRedo ? "\(undo.redoMenuItemTitle) (⇧⌘Z)" : "Redo (⇧⌘Z)"
        let enabled = canSave
        saveItem?.isEnabled = enabled
        (saveItem?.view as? NSControl)?.isEnabled = enabled
    }

    // MARK: Save and close

    @objc private func saveAction() { save() }

    /// A tool sets this when a time typed into one of its fields is refused (it beeps and puts the old one back), so
    /// Save, which commits a field still being edited first, doesn't go on to save what the field had before.
    var refusedEdit = false
    /// How Save hands the job over: JobRunner (the HUD shows progress). Self-tests record it instead.
    var runSave: (WheelCommand, ToolOptions, URL) -> Void = { command, options, url in JobRunner.run(.command(command, options), on: [url]) }

    /// Runs `command` on the original file with `makeOptions()` through JobRunner (HUD progress, same code as the
    /// command line) and closes the window. A field still being edited is committed first (clicking Save in the
    /// toolbar doesn't take the focus from it); when the tool refuses what was typed, nothing is saved.
    func save() {
        refusedEdit = false
        endTextEditing()
        guard !refusedEdit else { return }
        guard canSave, let command else { NSSound.beep(); return }
        do {
            let options = try makeOptions()
            let url = source.url
            forceClose()
            runSave(command, options, url)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn’t save"
            alert.informativeText = error.localizedDescription
            alert.beginSheetModal(for: window)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if timeline.isDragging { timeline.cancelDrag() }
        guard hasChanges, !isSnapshot else { return true }
        let alert = NSAlert()
        alert.messageText = "Discard your changes?"
        alert.informativeText = discardMessage
        let discard = alert.addButton(withTitle: "Discard")
        discard.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.forceClose() }
        }
        return false
    }

    /// Closes without asking.
    func forceClose() {
        tearDown()
        window.close()
    }

    func windowWillClose(_ notification: Notification) { tearDown() }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { undo }

    func windowDidResize(_ notification: Notification) { timeline.needsDisplay = true }

    private func tearDown() {
        guard !closing else { return }
        closing = true
        playback?.tearDown()
        preview?.attach(nil)
        proxyJob?.cancel()
        if let proxyDir { try? FileManager.default.removeItem(at: proxyDir) }
        undo.removeAllActions()
        window.keyHandler = nil
        window.delegate = nil
        timeline.onScrub = nil; timeline.onLiveRanges = nil; timeline.onCommitRanges = nil; timeline.onSelectionChange = nil
        Self.openControllers.removeAll { $0 === self }
    }

    // MARK: Snapshot

    /// The whole window (title bar, toolbar and content) rendered offscreen for `--snapshot`, with a deterministic
    /// still (AVFoundation for files it plays, ffmpeg otherwise), the film strip and the waveform.
    /// Options: playhead (s), zoom (1…), width and height (window content, points), dark, plus the tool's own.
    static func snapshotView(_ editor: MediaEditorWindowController.Type, url: URL, options: ToolOptions) throws -> NSView {
        let source = try MediaSource.load(url)
        let controller = editor.init(source: source, snapshot: true)
        return controller.renderSnapshot(options)
    }

    func renderSnapshot(_ options: ToolOptions) -> NSView {
        let dark = options.bool("dark", false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        func side(_ key: String, _ fallback: Double) -> CGFloat {
            let v = options.double(key, fallback)
            return CGFloat(v.isFinite ? min(max(v, 300), 3000) : fallback)
        }
        let size = source.hasVideo ? CGSize(width: side("width", 1000), height: side("height", 660))
                                   : CGSize(width: side("width", 900), height: side("height", 380))
        window.setContentSize(size)
        timeline.strip = MediaKit.filmStrip(source)
        timeline.peaks = MediaKit.peaks(source)
        applySnapshotOptions(options)
        let t = source.snap(options.double("playhead", ranges.first?.start ?? 0))
        setPlayhead(t, seek: false)
        if let preview {
            preview.still = MediaKit.avStillFrame(source.url, at: t) ?? MediaKit.stillFrame(source, at: t)
            transport.setPlayable(true)
        } else {
            transport.setPlayable(true)
        }
        if let loading = options["loading"].flatMap(Double.init) {
            // The state while a proxy is made: no picture yet, progress in the preview (or the bar, for sound).
            preview?.still = nil
            showPreparing(loading)
            transport.setPlayable(false)
        } else {
            previewDidLoad()
        }
        content.layoutSubtreeIfNeeded()
        let zoom = options.double("zoom", 1)
        if zoom > 1 { timeline.setZoom(CGFloat(zoom), anchor: t) }
        updateToolbar()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        guard let frameView = window.contentView?.superview else { return content }
        frameView.layoutSubtreeIfNeeded()
        frameView.display()
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return content }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        let image = NSImage(size: frameView.bounds.size)
        image.addRepresentation(rep)
        let view = NSImageView(frame: CGRect(origin: .zero, size: frameView.bounds.size))
        view.image = image
        view.imageScaling = .scaleAxesIndependently
        tearDown()
        window.contentView = nil
        return view
    }
}

// MARK: - Content and transport bar

/// The window's content: preview (video) above the transport bar and the timeline; for sound, the transport bar
/// on top of a tall waveform.
final class MediaEditorContentView: NSView {
    var preview: NSView? { didSet { replace(oldValue, with: preview) } }
    var transport: NSView? { didSet { replace(oldValue, with: transport) } }
    var timeline: MediaTimelineView? { didSet { replace(oldValue, with: timeline) } }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    private func replace(_ old: NSView?, with new: NSView?) {
        old?.removeFromSuperview()
        if let new { addSubview(new) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let barHeight: CGFloat = 44
        if let preview, let timeline {
            let lineHeight = min(timeline.preferredHeight, max(80, h - barHeight - 160))
            let previewHeight = max(0, h - barHeight - lineHeight)
            preview.frame = CGRect(x: 0, y: 0, width: w, height: previewHeight)
            transport?.frame = CGRect(x: 0, y: previewHeight, width: w, height: barHeight)
            timeline.frame = CGRect(x: 0, y: previewHeight + barHeight, width: w, height: lineHeight)
        } else {
            transport?.frame = CGRect(x: 0, y: 0, width: w, height: barHeight)
            timeline?.frame = CGRect(x: 0, y: barHeight, width: w, height: max(0, h - barHeight))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            ImageEditors.Style.chrome.setFill()
            dirtyRect.fill()
        }
    }
}

/// Play/pause, the current time over the length, the tool's controls, and zoom out/in.
final class MediaTransportBar: ImageEditors.FillView {
    let playButton: NSButton
    let zoomOutButton: NSButton
    let zoomInButton: NSButton
    private let timeLabel = NSTextField(labelWithString: "0:00.00")
    private let durationLabel = NSTextField(labelWithString: "/ 0:00.00")
    private let statusLabel = NSTextField(labelWithString: "")
    private let statusBar = MediaProgressBar(width: 80)
    private let stack = NSStackView()
    private let accessoryHost = NSStackView()

    /// The tool's controls, shown right-aligned before the zoom buttons.
    var accessory: NSView? {
        didSet {
            accessoryHost.arrangedSubviews.forEach { $0.removeFromSuperview() }
            if let accessory { accessoryHost.addArrangedSubview(accessory) }
        }
    }

    var time: Double = 0 {
        didSet {
            timeLabel.stringValue = MediaTime.string(time)
            playButton.setAccessibilityValue(MediaTime.string(time))
        }
    }
    var duration: Double = 0 { didSet { durationLabel.stringValue = "/ " + MediaTime.string(duration) } }
    var isPlaying = false {
        didSet {
            let name = isPlaying ? "pause.fill" : "play.fill"
            playButton.image = NSImage(systemSymbolName: name, accessibilityDescription: isPlaying ? "Pause" : "Play")
            playButton.setAccessibilityLabel(isPlaying ? "Pause" : "Play")
            playButton.toolTip = isPlaying ? "Pause (Space)" : "Play (Space)"
        }
    }

    init(hairlines: ImageEditors.Edges) {
        playButton = Self.button("play.fill", tip: "Play (Space)", label: "Play")
        zoomOutButton = Self.button("minus.magnifyingglass", tip: "Zoom Out (⌘−)", label: "Zoom Out")
        zoomInButton = Self.button("plus.magnifyingglass", tip: "Zoom In (⌘+)", label: "Zoom In")
        super.init(color: ImageEditors.Style.chrome, hairlines: hairlines)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        timeLabel.textColor = .labelColor
        timeLabel.setAccessibilityLabel("Current time")
        durationLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        durationLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.isHidden = true
        statusBar.isHidden = true

        let timeGroup = NSStackView(views: [timeLabel, durationLabel])
        timeGroup.spacing = 5
        // The time and the tool's controls never squeeze; a status message gives way first.
        for v in [playButton, timeLabel, durationLabel, zoomOutButton, zoomInButton] as [NSView] {
            v.setContentCompressionResistancePriority(.required, for: .horizontal)
            v.setContentHuggingPriority(.required, for: .horizontal)
        }
        accessoryHost.setContentCompressionResistancePriority(.required, for: .horizontal)
        accessoryHost.spacing = 0
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let zoomGroup = NSStackView(views: [zoomOutButton, zoomInButton])
        zoomGroup.spacing = 2
        let separator = ImageEditors.Style.separator()
        for v in [playButton, timeGroup, statusLabel, statusBar, spacer, accessoryHost, separator, zoomGroup] { stack.addArrangedSubview(v) }
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.setCustomSpacing(8, after: playButton)
        stack.setCustomSpacing(14, after: timeGroup)
        stack.setCustomSpacing(16, after: accessoryHost)
        stack.setCustomSpacing(10, after: separator)
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isPlaying = false
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private static func button(_ symbol: String, tip: String, label: String) -> NSButton {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(config) ?? NSImage()
        let button = NSButton(image: image, target: nil, action: nil)
        button.bezelStyle = .recessed
        button.showsBorderOnlyWhileMouseInside = true
        button.imagePosition = .imageOnly
        button.toolTip = tip
        button.setAccessibilityLabel(label)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }

    func setPlayable(_ playable: Bool) { playButton.isEnabled = playable }

    /// A message in the bar (sound files: "Preparing preview…" with progress; errors in red). nil hides it.
    func showStatus(_ text: String?, progress: Double? = nil, isError: Bool = false) {
        statusLabel.isHidden = text == nil
        statusLabel.stringValue = text ?? ""
        statusLabel.toolTip = text
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
        statusBar.isHidden = text == nil || progress == nil
        if let progress { statusBar.value = progress }
    }
}

/// A small time field (m:ss.ff) with its label; commits on Return or when it loses focus.
final class MediaTimeField: NSTextField {
    let labelView: NSTextField

    init(label: String) {
        labelView = NSTextField(labelWithString: label)
        labelView.font = .systemFont(ofSize: 12)
        labelView.textColor = .secondaryLabelColor
        super.init(frame: CGRect(x: 0, y: 0, width: 82, height: 22))
        font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        alignment = .right
        bezelStyle = .roundedBezel
        controlSize = .small
        isEditable = true
        isSelectable = true
        (cell as? NSTextFieldCell)?.sendsActionOnEndEditing = true
        (cell as? NSTextFieldCell)?.allowsUndo = false
        setAccessibilityLabel(label)
        toolTip = "\(label) (m:ss.ff, or seconds)"
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 82).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}
