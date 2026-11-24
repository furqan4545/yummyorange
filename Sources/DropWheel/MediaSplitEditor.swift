import AppKit

/// The Split window, laid out like Trim: the picture (or the sound alone), the transport bar and the timeline with
/// its film strip and waveform. Splits are placed on the timeline as in a video editor:
/// - Split (scissors, ⌘B) splits at the playhead, on the start of the frame on screen, so that frame starts the
///   next part. Split Evenly replaces the splits with 2–5 equal parts or parts every 10 s, 30 s or a minute.
/// - The lanes come apart at each split into one rounded segment per part, each with its number; a tab under the
///   lanes marks each split. Press a split (in the lanes or by its tab) to select it: the accent line and a filled
///   tab show the selection. Drag it to move it (frame by frame; never past a neighbour; Esc puts it back); ⌫ or
///   Remove Split removes it. The ruler always moves the playhead. ↑ ↓ jump between splits and select the one they
///   land on, Tab and ⇧Tab select the next or previous one, Return edits the selected split's time.
/// - The transport bar reads "3 parts · shortest 0.80 s" and holds the selected split's time ("Split at"), which
///   can be typed. A split that would leave a part shorter than one frame (0.01 s of sound), come after the last
///   frame, or make more than 100 parts, beeps and says why there; so does a time typed that can't be used.
/// - Save writes "<name> part 1.<ext>", "<name> part 2.<ext>"… next to the original through `--tool split`'s code
///   with `at=` (the split times); every change is one Undo step.
final class SplitEditorController: MediaEditorWindowController, NSMenuDelegate {
    override class var toolName: String { "Split" }
    override var command: WheelCommand? { MediaTools.split }
    override var timelineMode: MediaTimelineView.Mode { .none }
    override var discardMessage: String { "The splits you placed in \(source.name) haven’t been saved." }
    override var saveToolTip: String { "Save each part next to the original (⌘S)" }
    override var hasChanges: Bool { !cuts.isEmpty }
    override class func check(_ source: MediaSource) throws {
        guard MediaSplit.cutBounds(source) != nil else {
            throw ConversionError.unsupported("\(source.name) is too short to split: it has less than two \(source.hasVideo ? "frames" : "hundredths of a second").")
        }
    }

    /// The splits in seconds, sorted, on the grid the parts are cut on (as committed).
    private(set) var cuts: [Double] = []
    private(set) var selectedCut: Int?
    /// Why the last Split or Split Evenly did nothing; shown in the read-out until the next change or until the
    /// playhead moves from where it was then.
    private(set) var notice: String?
    private var noticePlayhead: Double = 0
    /// `--snapshot split … --opt action=split`: press Split once the snapshot's playhead is set (to show a refusal).
    private var snapshotAction: String?
    /// Where the file's last video frame really starts (MediaSplit.lastFrameStart, read in the background when
    /// the window opens): no split goes after it. nil until known, and for sound.
    private(set) var lastFrame: Double?
    /// The alert sound (tests count it instead).
    var beep: () -> Void = { NSSound.beep() }

    private(set) var splitItem: NSToolbarItem?
    private(set) var evenlyItem: NSMenuToolbarItem?
    private(set) var removeItem: NSToolbarItem?
    let cutField = MediaTimeField(label: "Split at")
    let summaryLabel = NSTextField(labelWithString: "")

    // MARK: Options

    override func makeOptions() throws -> ToolOptions {
        guard !cuts.isEmpty else {
            throw ConversionError.unsupported("Add at least one split: move the playhead where a part should start and press ⌘B.")
        }
        let at = cuts.map(MediaTime.arg).joined(separator: ",")
        // The command checks the times again on its own grid (sound: the nearest sample). Checked here too, so a
        // time it would refuse shows in the window, which stays open with the splits, instead of failing after.
        _ = try MediaSplit.cutTimes(at, source: source, lastFrame: lastFrame, quoteTyped: false)
        return ["at": at]
    }

    // MARK: Split Evenly

    enum Evenly: Equatable {
        case parts(Int), every(Double), removeAll

        var title: String {
            switch self {
            case .parts(let n): return "\(n) Equal Parts"
            case .every(let s): return s == 60 ? "Every Minute" : "Every \(Ask.formatNumber(s)) Seconds"
            case .removeAll: return "Remove All Splits"
            }
        }
        /// The Undo menu's name for it ("Undo Split into 3 Equal Parts").
        var actionName: String {
            switch self {
            case .parts(let n): return "Split into \(n) Equal Parts"
            case .every: return "Split " + title
            case .removeAll: return "Remove All Splits"
            }
        }
    }

    /// The pull-down's items in order; nil is a separator.
    static let evenlyMenu: [Evenly?] = [.parts(2), .parts(3), .parts(4), .parts(5), nil, .every(10), .every(30), .every(60), nil, .removeAll]

    /// The splits a choice gives this file, or nil when it isn't available: a part would be shorter than one frame,
    /// there would be more than 100 parts, the file is too short for any split, or there is nothing to remove.
    func cuts(for choice: Evenly) -> [Double]? {
        if case .success(let new) = evenly(choice) { return new }
        return nil
    }

    /// A choice's splits, or why it isn't available (the sentence a beep comes with).
    func evenly(_ choice: Evenly) -> Result<[Double], ConversionError> {
        let d = source.duration
        let raw: [Double]
        switch choice {
        case .removeAll:
            return cuts.isEmpty ? .failure(.unsupported("There are no splits to remove.")) : .success([])
        case .parts(let n):
            raw = MediaSplit.evenCuts(duration: d, count: n)
        case .every(let s):
            guard let every = MediaSplit.everyCuts(duration: d, length: s) else {
                return .failure(.unsupported("That would make more than \(MediaSplit.maxParts) parts; Split makes at most \(MediaSplit.maxParts)."))
            }
            guard !every.isEmpty else {
                let length = s == 60 ? "a minute" : "\(Ask.formatNumber(s)) seconds"
                return .failure(.unsupported("\(source.name) is only \(MediaTime.lengthString(d)) long, so parts of \(length) would leave it whole."))
            }
            raw = every
        }
        var placed: [Double] = []
        for t in raw.map({ MediaSplit.normalize($0, source: source) }).sorted() where placed.last.map({ t - $0 > 1e-9 }) ?? true {
            placed.append(t)
        }
        guard placed.count == raw.count, MediaSplit.problem(placed, source: source, lastFrame: lastFrame) == nil else {
            return .failure(.unsupported("Each part needs at least \(shortestText)."))
        }
        return .success(placed)
    }

    /// Replaces the splits with a choice's (one Undo step); beeps and says why when it isn't available.
    func splitEvenly(_ choice: Evenly) {
        switch evenly(choice) {
        case .success(let new): commitCuts(new, selected: nil, action: choice.actionName)
        case .failure(let error): refuse(error.localizedDescription)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items where item.tag >= 0 && item.tag < Self.evenlyMenu.count {
            if let choice = Self.evenlyMenu[item.tag] { item.isEnabled = cuts(for: choice) != nil }
        }
    }

    @objc private func evenlyChosen(_ sender: NSMenuItem) {
        guard sender.tag >= 0, sender.tag < Self.evenlyMenu.count, let choice = Self.evenlyMenu[sender.tag] else { return }
        splitEvenly(choice)
    }

    // MARK: Editing

    /// Splits at the playhead: at the start of the frame on screen (the nearest 1/100 s of sound), so the frame you
    /// see starts the new part. Beeps and says why when a part would be too short or there would be too many.
    func splitAtPlayhead() {
        let t = MediaSplit.frameStart(at: playhead, source: source)
        if let reason = refusal(adding: t) { refuse(reason); return }
        let all = (cuts + [t]).sorted()
        commitCuts(all, selected: all.firstIndex(of: t), action: "Split")
    }

    /// Why a split at `t` can't be added, or nil.
    func refusal(adding t: Double) -> String? {
        guard cuts.count + 2 <= MediaSplit.maxParts else { return "Split makes at most \(MediaSplit.maxParts) parts." }
        if let existing = cuts.first(where: { abs($0 - t) < 1e-6 }) { return "There’s already a split at \(MediaTime.string(existing))." }
        if let lastFrame, t > lastFrame + 1e-6, t <= (MediaSplit.cutBounds(source)?.upperBound ?? 0) + 1e-6 {
            return "That’s after the last frame (\(MediaTime.string(lastFrame)))."
        }
        return MediaSplit.problem((cuts + [t]).sorted(), source: source, lastFrame: lastFrame) == nil ? nil : "Each part needs at least \(shortestText)."
    }

    private var shortestText: String { source.hasVideo ? "one frame" : "0.01 seconds" }

    func removeSelectedCut() {
        guard let i = selectedCut, i < cuts.count else { beep(); return }
        var all = cuts
        all.remove(at: i)
        commitCuts(all, selected: nil, action: "Remove Split")
    }

    /// Selects a split (or none) without an Undo step, the way clicking its handle does.
    func selectCut(_ index: Int?) {
        timeline.selectCut(index)
    }

    /// Tab / ⇧Tab: the next or previous split (from none: the first or the last), with the playhead on it.
    func cycleSelection(forward: Bool) {
        guard !cuts.isEmpty else { beep(); return }
        let next: Int
        if let i = selectedCut, i < cuts.count { next = (i + (forward ? 1 : cuts.count - 1)) % cuts.count }
        else { next = forward ? 0 : cuts.count - 1 }
        selectCut(next)
        scrub(to: cuts[next])
    }

    /// ↑ / ↓: the playhead to the previous or next split (or to the start or the last frame past the outer ones),
    /// as Final Cut's edit-point keys do; the split it lands on is selected (so ⌫ or Return act on it).
    func goToCut(forward: Bool) {
        let last = source.hasVideo ? min(source.snap(source.duration - source.frameDuration), lastFrame ?? .infinity) : source.duration
        let stops = [0] + cuts + [last]
        let here = playhead
        guard let target = forward ? stops.first(where: { $0 > here + 1e-6 }) : stops.last(where: { $0 < here - 1e-6 }) else {
            beep()
            return
        }
        selectCut(cuts.firstIndex { abs($0 - target) < 1e-9 })
        scrub(to: target)
    }

    /// Return: edit the selected split's time (its text selected). Without a selected split Return does nothing.
    func editSelectedCutTime() -> Bool {
        guard selectedCut != nil, cutField.isEnabled else { return false }
        window.makeFirstResponder(cutField)
        cutField.currentEditor()?.selectAll(nil)
        return true
    }

    /// The real last frame, once read: splits can't go after it (the bounds the timeline drags within, Split's
    /// refusal, ↓ and Save's check).
    func useLastFrame(_ t: Double?) {
        lastFrame = t
        timeline.cutBounds = MediaSplit.cutBounds(source, lastFrame: t)
    }

    /// Commits new splits as one undoable step named `action`; a change of selection alone isn't an Undo step.
    func commitCuts(_ new: [Double], selected: Int?, action: String) {
        let old = cuts, oldSelected = selectedCut
        let sorted = new.sorted()
        let selection = selected.flatMap { $0 >= 0 && $0 < sorted.count ? $0 : nil }
        if sorted != old {
            undo.beginUndoGrouping()
            undo.registerUndo(withTarget: self) { target in
                target.commitCuts(old, selected: oldSelected, action: action)
                target.revealChange(from: sorted, to: old)
            }
            undo.setActionName(action)
            undo.endUndoGrouping()
        }
        apply(sorted, selected: selection)
    }

    private func apply(_ new: [Double], selected: Int?) {
        cuts = new
        selectedCut = selected.flatMap { $0 >= 0 && $0 < new.count ? $0 : nil }
        notice = nil
        timeline.setCuts(new, selected: selectedCut)
        refreshReadouts(new, selected: selectedCut)
        updateToolbar()
    }

    /// After Undo or Redo, scroll to the split that changed so the result is visible.
    private func revealChange(from a: [Double], to b: [Double]) {
        let changed = Set(a).symmetricDifference(Set(b)).sorted()
        if let t = changed.first { timeline.reveal(t) }
    }

    /// Beeps, shows why in the read-out and tells VoiceOver.
    func refuse(_ reason: String) {
        beep()
        notice = reason
        noticePlayhead = playhead
        refreshReadouts(cuts, selected: selectedCut)
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: reason, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    override func updateToolbar() {
        super.updateToolbar()
        removeItem?.isEnabled = selectedCut != nil
    }

    // MARK: Toolbar and transport bar

    override func makeToolItems() -> [NSToolbarItem] {
        let split = symbolItem(.init("split.add"), symbol: "scissors", label: "Split", tip: "Split at Playhead (⌘B)", action: #selector(splitAction))
        split.image = NSImage(systemSymbolName: "scissors", accessibilityDescription: "Split at Playhead")
        split.paletteLabel = "Split at Playhead"
        splitItem = split

        let menu = NSMenu(title: "Split Evenly")
        menu.autoenablesItems = false
        menu.delegate = self
        for (i, choice) in Self.evenlyMenu.enumerated() {
            guard let choice else { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: choice.title, action: #selector(evenlyChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            menu.addItem(item)
        }
        let evenly = NSMenuToolbarItem(itemIdentifier: .init("split.evenly"))
        let symbol = MediaTools.symbol("rectangle.split.3x1", or: "square.split.2x1")
        evenly.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Split Evenly")
        evenly.label = "Evenly"
        evenly.paletteLabel = "Split Evenly"
        evenly.toolTip = "Split Evenly"
        evenly.menu = menu
        evenly.showsIndicator = true
        evenly.autovalidates = false
        evenlyItem = evenly

        let remove = symbolItem(.init("split.remove"), symbol: "trash", label: "Remove Split",
                                tip: "Remove Selected Split (⌫)", action: #selector(removeAction))
        remove.isEnabled = false
        removeItem = remove
        return [split, evenly, remove]
    }

    override func makeTransportAccessory() -> NSView? {
        cutField.target = self
        cutField.action = #selector(fieldCommitted(_:))
        cutField.placeholderString = "–"
        cutField.toolTip = "Time of the selected split (m:ss.ff, or seconds). Press Return to edit it."
        cutField.setAccessibilityHelp("The selected split’s time. Press Return to edit it, type a time and press Return to move the split.")
        summaryLabel.font = .systemFont(ofSize: 12)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.alignment = .right
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.setAccessibilityLabel("Parts")
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 236).isActive = true
        let stack = NSStackView(views: [cutField.labelView, cutField, summaryLabel])
        for v in stack.arrangedSubviews { v.setContentCompressionResistancePriority(.required, for: .horizontal) }
        // A long reason truncates (its tooltip has it whole) rather than widening the window.
        summaryLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        stack.spacing = 6
        stack.setCustomSpacing(16, after: cutField)
        return stack
    }

    @objc private func splitAction() { splitAtPlayhead() }
    @objc private func removeAction() { removeSelectedCut() }

    /// A time typed for the selected split: the nearest frame start (1/100 s of sound), kept between its
    /// neighbours with a frame to spare; anything else beeps, is put back and says why (also when Save commits it).
    @objc private func fieldCommitted(_ sender: MediaTimeField) {
        guard let i = selectedCut, i < cuts.count else { refreshReadouts(cuts, selected: nil); return }
        let text = sender.stringValue.trimmingCharacters(in: .whitespaces)
        guard let typed = MediaTime.parse(text) ?? Double(text), typed.isFinite else {
            refusedEdit = true
            refuse("“\(text)” isn’t a time. Type one like 0:01.50, or seconds.")
            return
        }
        let t = source.snap(min(max(typed, 0), source.duration))
        guard abs(t - cuts[i]) > 1e-9 else { refreshReadouts(cuts, selected: i); return }
        guard abs(timeline.placeCut(i, at: t, in: cuts) - t) < 1e-9 else {
            refusedEdit = true
            let lo = timeline.placeCut(i, at: 0, in: cuts), hi = timeline.placeCut(i, at: source.duration, in: cuts)
            refuse("Split \(i + 1) has to stay between \(MediaTime.string(lo)) and \(MediaTime.string(hi)).")
            return
        }
        var all = cuts
        all[i] = t
        commitCuts(all, selected: i, action: "Move Split")
        scrub(to: t)
    }

    // MARK: Read-outs

    /// "3 parts · shortest 0:00.80", or how to start; a refusal's reason while there is one. The selected split's
    /// time in the field.
    func refreshReadouts(_ all: [Double], selected: Int?) {
        let t = selected.flatMap { $0 < all.count ? all[$0] : nil }
        cutField.isEnabled = t != nil
        cutField.labelView.textColor = t == nil ? .tertiaryLabelColor : .secondaryLabelColor
        if cutField.currentEditor() == nil { cutField.stringValue = t.map(MediaTime.string) ?? "" }
        if let notice {
            let text = NSMutableAttributedString()
            if let symbol = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .regular).applying(.init(paletteColors: [.systemOrange]))) {
                let attachment = NSTextAttachment()
                attachment.image = symbol
                attachment.bounds = CGRect(x: 0, y: -2, width: symbol.size.width, height: symbol.size.height)
                text.append(NSAttributedString(attachment: attachment))
                text.append(NSAttributedString(string: " "))
            }
            text.append(NSAttributedString(string: notice, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]))
            let style = NSMutableParagraphStyle()
            style.alignment = .right
            style.lineBreakMode = .byTruncatingTail
            text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
            summaryLabel.attributedStringValue = text
            summaryLabel.toolTip = notice
            summaryLabel.setAccessibilityValue(notice)
        } else {
            let summary = summaryText(all)
            summaryLabel.textColor = .secondaryLabelColor
            summaryLabel.stringValue = summary
            summaryLabel.toolTip = nil
            summaryLabel.setAccessibilityValue(summary)
        }
    }

    func summaryText(_ all: [Double]) -> String {
        guard !all.isEmpty else { return "Press ⌘B to split at the playhead" }
        let edges = [0] + all + [source.duration]
        let shortest = zip(edges, edges.dropFirst()).map { $1 - $0 }.min() ?? 0
        return "\(all.count + 1) parts · shortest \(MediaTime.lengthString(shortest))"
    }

    override func rangesDidChange(live: Bool) {
        // The kit calls this after Esc leaves a text field: put the field's time back.
        if !live, timeline != nil { refreshReadouts(cuts, selected: selectedCut) }
    }

    override func playheadDidChange() {
        guard notice != nil, abs(playhead - noticePlayhead) > 1e-9 else { return }
        notice = nil
        refreshReadouts(cuts, selected: selectedCut)
    }

    // MARK: Building

    override func didBuild() {
        timeline.showsCuts = true
        let src = source
        timeline.cutSnap = { MediaSplit.frameStart(at: $0, source: src) }
        timeline.cutBounds = MediaSplit.cutBounds(source)
        timeline.cutGap = MediaSplit.shortestPart(source)
        timeline.onCommitCuts = { [weak self] new, selected, name in self?.commitCuts(new, selected: selected, action: name) }
        timeline.onLiveCuts = { [weak self] live in
            guard let self else { return }
            self.refreshReadouts(live, selected: self.timeline.selectedCut)
        }
        timeline.onCutSelectionChange = { [weak self] index in
            guard let self else { return }
            self.selectedCut = index
            self.notice = nil
            self.refreshReadouts(self.cuts, selected: index)
            self.updateToolbar()
        }
        refreshReadouts(cuts, selected: nil)
        updateToolbar()
        // Read the last frame in the background: a file whose sound runs past its picture (sample.wmv) has no frame
        // where the grid's last one would be.
        guard !isSnapshot, source.hasVideo else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let last = MediaSplit.lastFrameStart(src)
            DispatchQueue.main.async { self?.useLastFrame(last) }
        }
    }

    // MARK: Keys

    /// ⌘B splits (also from the time field, which it leaves first); keys of a focused control stay with it.
    override func handleKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        if keyBelongsToFocusedControl(event) { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "b" {
            if window.firstResponder is NSText { window.makeFirstResponder(nil) }
            splitAtPlayhead()
            return true
        }
        return super.handleKey(event)
    }

    /// ↑ ↓ previous / next split, ⌫ ⌦ remove the selected one, Tab ⇧Tab select the next / previous one (unless a
    /// control has the keyboard focus: then Tab moves it, as Full Keyboard Access expects), Return edits the
    /// selected split's time, Esc lets go of the selection when nothing is being dragged.
    override func handleToolKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch event.keyCode {
        case 126 where flags.isEmpty: goToCut(forward: false); return true            // ↑
        case 125 where flags.isEmpty: goToCut(forward: true); return true             // ↓
        case 51, 117:                                                                  // ⌫ ⌦
            guard flags.isEmpty else { return false }
            removeSelectedCut()
            return true
        case 48:                                                                       // Tab
            guard flags.subtracting(.shift).isEmpty, !cuts.isEmpty, !(window.firstResponder is NSControl) else { return false }
            cycleSelection(forward: !flags.contains(.shift))
            return true
        case 36, 76:                                                                   // Return, Enter
            return flags.isEmpty && editSelectedCutTime()
        case 53:                                                                       // Esc
            guard !timeline.isDragging, selectedCut != nil else { return false }
            selectCut(nil)
            return true
        default:
            return false
        }
    }

    // MARK: Snapshot

    /// Options: at (split times, as `--tool split` takes them; default two splits, at 30 % and 65 %), selected
    /// (which split is selected, counting from 1 as the window does: selected=1 is the first) and action=split
    /// (press Split at the playhead, silently, after the rest is set: shows a new split or the reason it was refused).
    override func applySnapshotOptions(_ options: ToolOptions) {
        var marked: [Double] = []
        if let at = options["at"] {
            marked = (try? MediaSplit.cutTimes(at, source: source)) ?? []
        } else {
            let wanted = [0.3, 0.65].map { MediaSplit.normalize(source.duration * $0, source: source) }
            if MediaSplit.problem(wanted, source: source) == nil { marked = wanted }
        }
        let selected = options["selected"].flatMap(Int.init).map { $0 - 1 }
        apply(marked, selected: selected)
        undo.removeAllActions()
        updateToolbar()
        snapshotAction = options["action"]
    }

    override func previewDidLoad() {
        // Snapshots: the playhead is set by now, so a Split pressed here shows its result or its reason.
        guard isSnapshot, snapshotAction == "split" else { return }
        snapshotAction = nil
        beep = {}
        splitAtPlayhead()
    }
}
