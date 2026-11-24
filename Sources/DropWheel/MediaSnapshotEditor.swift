import AppKit

/// The Snapshot window: scrub to a frame (the film strip, ← → one frame, ⇧ one second, or the frame buttons in the
/// toolbar) and Save (⌘S or Return) writes that exact frame as "<name> frame m-ss.ff.png" at full resolution.
/// There is nothing to undo and nothing to lose on closing, so Undo/Redo are left out and Save is always on.
final class SnapshotVideoEditorController: MediaEditorWindowController {
    override class var toolName: String { "Snapshot" }
    override var command: WheelCommand? { MediaFrameTools.snapshotCommand }
    override var timelineMode: MediaTimelineView.Mode { .none }
    override var hasChanges: Bool { false }
    override var canSave: Bool { true }
    override var showsUndoRedo: Bool { false }
    override var saveToolTip: String { "Save this frame as a PNG next to the original (⌘S)" }

    let frameLabel = NSTextField(labelWithString: "")

    /// The playhead is where the player stands (after a pause, part way into a frame; on a 23.976 fps grid, just
    /// before the frame it names, so the player shows the one before). Snapshot saves the frame that has started by
    /// then: the frame on screen. Nine decimals, as the player's time can sit a few microseconds before a frame. Until
    /// the player is ready the preview shows ffmpeg's still, which can be the frame starting just after the playhead
    /// (wmv's millisecond times, 23.976 fps grids): then Save takes the still's frame.
    override func makeOptions() throws -> ToolOptions {
        var options = ["time": String(format: "%.9f", playhead)]
        if !playerReady { options["still"] = "true" }
        return options
    }

    /// The frame the preview shows, counted at the file's true rate: the one that has started by the playhead (the
    /// player's), or until the player is ready the still's (the first that starts at or after `MediaKit.stillSeek`).
    var frameIndex: Int {
        let fd = MediaFrameTools.exactFrameDuration(source)
        if playerReady { return max(0, Int(((playhead - source.videoStart) / fd + 1e-5).rounded(.down))) }
        return max(0, Int(((MediaKit.stillSeek(playhead) - source.videoStart) / fd - 1e-5).rounded(.up)))
    }

    /// Previous and next frame as one control, like back and forward.
    let stepControl = NSSegmentedControl()

    override func makeToolItems() -> [NSToolbarItem] {
        stepControl.segmentCount = 2
        stepControl.trackingMode = .momentary
        stepControl.segmentStyle = .automatic
        for (i, (symbol, label, tip)) in [("chevron.backward", "Previous Frame", "Previous frame (←)"),
                                          ("chevron.forward", "Next Frame", "Next frame (→)")].enumerated() {
            stepControl.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: label), forSegment: i)
            stepControl.setToolTip(tip, forSegment: i)
            stepControl.setWidth(32, forSegment: i)
        }
        stepControl.target = self
        stepControl.action = #selector(step(_:))
        stepControl.setAccessibilityLabel("Step one frame")
        let item = NSToolbarItem(itemIdentifier: .init("snapshot.step"))
        item.view = stepControl
        item.label = "Step"
        let menu = NSMenuItem(title: "Step", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (i, title) in ["Previous Frame", "Next Frame"].enumerated() {
            let entry = NSMenuItem(title: title, action: #selector(stepMenu(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = i
            sub.addItem(entry)
        }
        menu.submenu = sub
        item.menuFormRepresentation = menu
        return [item]
    }

    override func makeTransportAccessory() -> NSView? {
        frameLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        frameLabel.textColor = .secondaryLabelColor
        frameLabel.alignment = .right
        frameLabel.setAccessibilityLabel("Frame")
        frameLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        return frameLabel
    }

    override func didBuild() { playheadDidChange() }

    /// The label follows the player once it shows frames.
    override func previewDidLoad() { playheadDidChange() }

    override func playheadDidChange() {
        let index = frameIndex
        let size = MediaSnapshot.outputSize(source)
        let text = NSMutableAttributedString(string: "Frame \(index)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor])
        text.append(NSAttributedString(string: "  ·  \(Int(size.width)) × \(Int(size.height)) PNG", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]))
        frameLabel.attributedStringValue = text
        frameLabel.setAccessibilityValue("Frame \(index), saved as a \(Int(size.width)) by \(Int(size.height)) PNG")
    }

    @objc private func step(_ sender: NSSegmentedControl) {
        scrub(to: source.step(playhead, by: sender.selectedSegment == 0 ? -1 : 1))
    }

    @objc private func stepMenu(_ sender: NSMenuItem) {
        scrub(to: source.step(playhead, by: sender.tag == 0 ? -1 : 1))
    }

    override func handleKey(_ event: NSEvent) -> Bool {
        keyBelongsToFocusedControl(event) ? false : super.handleKey(event)
    }

    override func handleToolKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if [36, 76].contains(event.keyCode), flags.isEmpty { save(); return true }   // Return, Enter
        return false
    }
}
