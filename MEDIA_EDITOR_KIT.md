# Media editor kit

The kit is what YummyOrange's audio and video editors share. Trim… is built on it, and Bleep, Speed, Split, Channels,
Visualize, Crop, Redact and Snapshot are meant to be. It is AppKit and AVFoundation, plus ffmpeg for anything
AVFoundation can't do. Every name below exists in the code. If you rename something, update this file.

| File | What it holds |
|---|---|
| `MediaEditorKit.swift` | `MediaSource` (the probe), `MediaRange`, `MediaTime` (m:ss.ff text), `MediaEncode` (re-encode rules per container), `MediaKit` (key frames, stills, film strip, waveform peaks, preview proxies, a cancellable ffmpeg run), `MediaJob`, `MediaMeasure` (measurements for tests) |
| `MediaPreview.swift` | `MediaPreviewView` (the picture, the overlay, the view ↔ video-pixel mapping, "Preparing preview…"), `MediaOverlayView`, `MediaProgressBar`, `MediaColors`, `MediaPlayback` (AVPlayer with chased exact seeks) |
| `MediaTimeline.swift` | `MediaTimelineView` (ruler, film strip, waveform, playhead, zoom and scroll, ranges, handles, opt-in cut markers, VoiceOver elements) |
| `MediaEditorWindow.swift` | `MediaEditorWindowController` (the base class), `MediaEditorContentView`, `MediaTransportBar`, `MediaTimeField`, `MediaProminentStandIn` |
| `MediaTestSupport.swift` | `MediaTestSupport` (fixtures, a checker, an editor that is never shown, key and mouse events) |
| `MediaTrim.swift`, `MediaTrimTests.swift` | The worked example: Trim… and `--selftest media-trim` |
| `MediaTools.swift`, `MediaBleep.swift`, `MediaBleepEditor.swift`, `MediaSpeedSplit.swift`, `MediaChannels.swift`, `MediaVisualize.swift`, `MediaToolsTests.swift` | Bleep… (a `.multiple` editor), Speed…, Split… (its engine), Channels…, Visualize… and `--selftest media-tools` |
| `MediaSplitEditor.swift`, `MediaSplitTests.swift` | The Split window (`SplitEditorController`: a `.none` timeline with cut markers) and `--selftest media-split` |
| `MediaFrameTools.swift`, `MediaFrameBox.swift`, `MediaCropEditor.swift`, `MediaRedactEditor.swift`, `MediaSnapshotEditor.swift`, `MediaFrameTests.swift` | The frame tools: Crop…, Redact…, Snapshot… (video), box geometry and handles (`MediaBoxGeometry`, `MediaFrameOverlayView`), the player's current frame (`MediaFrameGrabber`), the redaction preview (`MediaRedactRenderer`) and `--selftest media-frame` |

## 1. Making a new media editor

A tool is a `WheelCommand` in a `FeatureModule`. Give your module its own file and its own line in `Registry.modules`
(Extensions.swift). `run` must work from options alone, because that is what the command line calls. The window only
gathers the options.

```swift
enum MediaBleep: FeatureModule {
    static var commands: [WheelCommand] { [command] }

    static let command = WheelCommand(
        wheel: .tools, id: "bleep", title: "Bleep…", symbol: "speaker.slash",
        applies: MediaTrim.isMedia,                       // ffmpeg is installed and every file is video or audio
        present: { MediaEditorWindowController.open($0, editor: BleepEditorController.self) },
        run: { files, options, progress in try files.map { try bleep($0, options: options, progress: progress) } })

    static func snapshot(_ id: String, files: [URL], options: ToolOptions) -> NSView? {
        guard id == "bleep", let url = files.first else { return nil }
        return try? MediaEditorWindowController.snapshotView(BleepEditorController.self, url: url, options: options)
    }
}

final class BleepEditorController: MediaEditorWindowController {
    override class var toolName: String { "Bleep" }                     // the window subtitle
    override var command: WheelCommand? { MediaBleep.command }          // what Save runs
    override var timelineMode: MediaTimelineView.Mode { .multiple }     // .single (Trim), .multiple, .none
    override func makeOptions() throws -> ToolOptions {                 // exactly the keys `run` reads
        ["ranges": ranges.map { "\(MediaTime.arg($0.start))-\(MediaTime.arg($0.end))" }.joined(separator: ",")]
    }
}
```

`open(files, editor:)` opens one window per video or audio file, at most `maxWindows` (4). It runs on the next turn
of the run loop, and errors go to the HUD. Each window gets the following:

- **The window.** The title is the file name and the subtitle is `toolName`. `representedURL` is set. The frame is
  saved under "DropWheel Media <tool> Video|Audio". Minimum size is 760 × 540 for video and 880 × 320 for audio (the
  audio transport bar needs room for "Preparing preview…").
- **The toolbar.** It is unified. Your `makeToolItems()` sit in the centre (`centeredItemIdentifiers`, between two
  flexible spaces, as in the image and Edit PDF editors; a `.space` at either end of your list is dropped), and Undo,
  Redo and **Save** sit on the trailing edge. Save is
  the one prominent item: `.prominent` on macOS 26 and later, an accent push button before that. It is enabled only
  while `hasChanges` is true.
- **The layout.** For video, the preview sits above the transport bar and the timeline. For audio, the transport bar
  sits on top of a tall waveform.
- **The transport bar.** It holds play/pause, the time over the length, your `makeTransportAccessory()`, and the
  zoom out/in buttons.
- **Loading.** The film strip and waveform load in the background. AVFoundation plays the file when it can (it is
  asked, not guessed: `MediaKit.checkPlayable`). Otherwise `MediaKit.makeProxy` writes a VideoToolbox H.264 .mp4
  (upright, square pixels, at most 1280 px on the long side, GOP 12) or an AAC .m4a into
  `$TMPDIR/dropwheel-media-preview-<uuid>`. While it works, "Preparing preview…" with progress shows in the preview,
  or in the transport bar for audio. The proxy runs as a `MediaJob`. Closing the window stops it and deletes the
  folder, and folders more than a day old are swept the next time. The proxy keeps the original's times, and **edits
  always read the original file.**
- **Keys.** These are handled at the window, before the focused control sees them:

  | Key | Action |
  |---|---|
  | Space | Play or pause |
  | I / O | Set in / out |
  | ⇧I / ⇧O | Go to the first or last kept frame |
  | ← → | One frame (⇧ for one second) |
  | Home / End | Go to the start or the last frame |
  | ⌘+ / ⌘= / ⌘− / ⌘0 | Zoom in, zoom in, zoom out, fit |
  | ⌘Z / ⇧⌘Z | Undo / Redo |
  | ⌘S | Save |
  | ⌘W | Close (asks first when there are changes) |
  | Esc | Cancels a drag or leaves a text field. It never closes the window |
  | ⌫ / ⌦ | Delete the selected range (multiple mode) |
  | ⌘X ⌘C ⌘V ⌘A | Routed to text fields (the app has no Edit menu) |

  `handleToolKey(_:)` sees each key first, but not while a text field is being edited. Return true when you used it.
- **Closing.** Closing with `hasChanges` asks "Discard your changes?" in a sheet with Discard (destructive) and
  Cancel. Override `discardMessage` for the sentence under it.
- **Saving.** Save calls `makeOptions()`. When that succeeds, the window closes and
  `JobRunner.run(.command(command, options), on: [original])` runs: the HUD shows progress and the result or error,
  and it is the same code path as `--tool <id> --opt k=v`. When `makeOptions()` throws, its message shows in a sheet
  and the window stays open.

### Hooks (override what you need)

| Hook | Default | Use |
|---|---|---|
| `class var toolName` | "Edit" | Subtitle, and the tool's name in messages |
| `var command` | nil | The command Save runs |
| `var timelineMode` | `.single` | `.single` gives one in/out range, `.multiple` a list, `.none` only a playhead |
| `func initialRanges()` | whole file (single) or none | Ranges a fresh window starts with |
| `var hasChanges` | `ranges != initialRanges()` | Enables Save and the discard sheet. Override for frame tools (for example, "a box exists") |
| `var canSave` | `hasChanges` | Enables Save without making closing ask (Snapshot: always true, `hasChanges` false) |
| `var showsUndoRedo` | true | false leaves Undo and Redo out of the toolbar (a tool with nothing to undo) |
| `func makeOptions() throws` | `[:]` | The options for `command` |
| `func makeToolItems()` | `[]` | Toolbar items, centred. Use `symbolItem(_:symbol:label:tip:action:)` for icon buttons, or `NSToolbarItemGroup` |
| `func makeTransportAccessory()` | nil | Your controls in the transport bar. Give them `.required` compression resistance |
| `func didBuild()` | — | Called once everything exists (also in snapshots). Install overlays here |
| `func rangesDidChange(live:)` | — | After every change. `live` is true during a drag; false once committed and after Undo and Redo |
| `func updateLiveReadouts(_:)` | — | Ranges during a drag and after commits, for read-outs |
| `func playheadDidChange()` | — | After the playhead moves |
| `func handleToolKey(_:)` | false | Tool keys: Return applies, Delete removes a box, and so on |
| `func previewDidLoad()` | — | The player shows frames (in snapshots, the still is set) |
| `func applySnapshotOptions(_:)` | — | Put `--opt` values into the window's state for `--snapshot` |
| `var discardMessage`, `var saveToolTip` | generic | Text |
| `class func check(_ source:)` | accepts all | Throw to refuse a file before its window opens (the HUD shows why). Bleep refuses files without sound |

### State you can read and change

- `source: MediaSource` describes the file (section 4).
- `ranges`, `selectedRange` and `playhead` are read-only properties.
- `replaceRanges(_:selected:)` shows ranges **without** registering Undo, for a tool whose own model owns the times
  (Redact shows the selected box's time range in single mode and keeps its own Undo; it also rewires
  `timeline.onCommitRanges` in `didBuild`). `timeline.showsRanges = false` hides the single range (no frame, dimming
  or grips) while nothing is selected.
- `setRanges(_:selected:action:)` commits ranges as **one undoable step** named `action` ("Set Start"). It keeps
  single mode to one range and sorts multiple mode. Undo and Redo scroll to the edge that changed.
- `setInPoint()`, `setOutPoint()`, `addRange(_:)` and `removeSelectedRange()` are the I, O and ⌫ actions.
  - Single mode: I sets the start, and O sets the end **after** the frame under the playhead (the frame you see is
    kept). For audio, O sets the end at the playhead.
  - Multiple mode: I and O change the selected range. With nothing selected, or when the playhead is past the
    range, they add a one-second range. New ranges are trimmed so they never overlap their neighbours.
- `scrub(to:)` moves the playhead to a time snapped to the nearest frame, shows that frame and scrolls it into view.
  `setPlayhead(_:seek:)` does the same without snapping or scrolling. The player seeks 1 ms past the time
  (`MediaPlayback.seekNudge`, `seekTime`, rounded up to a 90 kHz tick), so the frame shown is the one that starts at
  that time even when the file stores its start in whole milliseconds (mkv, webm, wmv and their proxies) or the time
  falls between ticks; it reports the time asked for.
- `togglePlay()` plays from the playhead to the end in modes other than single. In single mode it plays the
  selection: from the playhead when it is inside, otherwise from the start, and it stops on the last kept frame.
- `playback: MediaPlayback?` is nil in snapshots. `playerReady` is true once AVFoundation shows frames.
- `undo` is the window's UndoManager (`groupsByEvent` is false, so it works without events in tests).
- `window`, `content`, `preview`, `transport`, `timeline` are the views; `proxyDir` is the proxy's folder while one
  exists.
- `save()`, `forceClose()` and `loadPreview()` are also available. `save()` first ends the editing of a text field
  (the toolbar's Save doesn't take the focus from it), so a time typed but not confirmed is used; a tool whose field
  refuses what was typed sets `refusedEdit` and nothing is saved. `runSave` is how Save hands the job to JobRunner
  (tests replace it). `loadPreview()` is what `show` calls, and tests
  call it on windows that are never shown.

## 2. Overlays for frame tools (Crop, Redact, Snapshot)

`preview.overlay` is a transparent, flipped `MediaOverlayView` covering the whole preview, above the picture.

- Clicks pass through it unless a subview, or a subclass's `hitTest`, takes them.
- `preview.onStillChange` runs after the still changes (a tool that draws from the picture redraws then).
- Add your view in `didBuild()` and redraw it from `preview.onLayout`, which runs after every layout. The picture
  moves when the window resizes.

```swift
final class CropBoxView: NSView {
    weak var preview: MediaPreviewView?
    var box = CGRect(x: 100, y: 50, width: 640, height: 360)          // video pixels, top-left origin
    override var isFlipped: Bool { true }
    override func hitTest(_ p: NSPoint) -> NSView? { preview.map { $0.pictureRect.contains(convert(p, from: superview)) } == true ? self : nil }
    override func draw(_ dirty: NSRect) {
        guard let preview else { return }
        let r = preview.viewRect(fromPixel: box)                       // overlay and preview share coordinates
        MediaColors.accent.setStroke(); NSBezierPath(rect: r.insetBy(dx: 1, dy: 1)).stroke()
    }
    override func mouseDragged(with e: NSEvent) {
        guard let preview else { return }
        let px = preview.pixelPoint(fromView: convert(e.locationInWindow, from: nil))   // back to video pixels
        box.origin = px; needsDisplay = true
    }
}

final class CropEditorController: MediaEditorWindowController {
    override class var toolName: String { "Crop" }
    override var timelineMode: MediaTimelineView.Mode { .none }       // only the playhead, to pick a frame
    let boxView = CropBoxView()
    override func didBuild() {
        guard let preview else { return }
        boxView.preview = preview
        boxView.frame = preview.overlay.bounds
        boxView.autoresizingMask = [.width, .height]
        preview.overlay.addSubview(boxView)
        preview.onLayout = { [weak self] in self?.boxView.needsDisplay = true }
    }
}
```

**The mapping.** Video pixels are the grid ffmpeg filters use (`crop`, `overlay`, `drawbox`, `delogo`): the picture
in **display orientation**. ffmpeg turns a quarter-turned phone clip upright before filtering, so it is 1080 × 1920
pixels. The grid keeps the stream's **pixel aspect**: odd.mkv is 641 × 361 pixels with SAR 5776:5769, shown 16:9.

| Property or function | What it gives |
|---|---|
| `source.pixelSize` | The grid's size (rotated) |
| `source.pixelAspect` | The width of one pixel relative to its height (rotated) |
| `source.displaySize`, `source.displayAspect` | The shape on screen |
| `preview.pictureRect` | Where the picture is drawn: its display shape fitted inside `inset` (20 pt), scaled up or down |
| `preview.pointsPerPixel` | Points per pixel, horizontally and vertically. They differ when pixels aren't square |
| `viewPoint(fromPixel:)`, `pixelPoint(fromView:)` | Convert a point |
| `viewRect(fromPixel:)`, `pixelRect(fromView:)` | Convert a rect (the result is not clamped: intersect with `CGRect(origin: .zero, size: source.pixelSize)`) |

The self-test checks the mapping for odd.mkv and for a parsed rotated clip.

Round boxes to even pixel values before handing them to ffmpeg. Conventions for frame editors are in conventions.md:
handles with at least 20 × 20 pt hit areas, resize cursors, aspect presets in a pop-up, a W × H readout, Return
applies, Delete removes.

**Stills.** `preview.still` is drawn under the player and is what snapshots show. `MediaKit.avStillFrame(url, at:)`
gives the exact frame from AVFoundation. `MediaKit.stillFrame(source, at:)` decodes with ffmpeg: any format, upright,
square pixels, and the BT.709 hint for untagged HD (`source.rgbScaleOptions`). Snapshot (the PNG tool) should use the
same ffmpeg recipe as its `run`.

## 3. Ranges and the timeline

`MediaTimelineView` draws:

- a ruler whose labels never collide or run off the edge;
- a film strip (video), made by one ffmpeg `fps`+`tile` run with up to 120 thumbnails (key frames only past two
  minutes);
- a waveform: the loudest sample of any channel per millisecond, decoded at the file's own rate, so no tone is lost
  to resampling, on the file's clock (sound that starts late is padded, `MediaKit.soundFromZero`), and blank where
  the sound has ended;
- the ranges and the playhead (accent, with a halo so it shows over the accent waveform).

It zooms with ⌘+/⌘−/⌘0, pinch, ⌘/⌥-scroll and the zoom buttons. A frame can reach about 30 pt wide (1/100 s about
12 pt for audio). It scrolls with the trackpad or wheel, or by dragging the scroll indicator, and follows the playhead
while playing.

**Modes.**

- **`.single`:** what lies outside the range is dimmed (a light wash in light mode, a dark scrim in dark mode). The
  range is framed in the accent with 11 pt grips at both ends; each grip is hit within 20 pt. Clicking or dragging
  the lanes or the ruler scrubs.
- **`.multiple`:** ranges are accent-tinted blocks. Clicking one selects it; it gets grips and its body can be
  dragged. Dragging on empty lanes adds a range. The ruler scrubs. Ranges never overlap.
- **`.none`:** only the playhead.

**Interaction.**

- A handle keeps the offset from where you grabbed it.
- While a handle moves, the preview shows the frame at that edge: the first kept frame for a start, the last kept
  frame for an end.
- Ends snap with `source.snapEnd`, so an end dragged past the last frame keeps the file's full length. This matters
  for wmv files, whose sound runs 44 ms past the last frame.
- Esc during a drag puts everything back (`cancelDrag()`).
- The timeline never commits on its own. It reports `onCommitRanges(new, selected, actionName)`, and the controller
  registers Undo and calls `setRanges`. `onLiveRanges` reports ranges during a drag.

**VoiceOver.** The timeline is a group labelled "Timeline". Its children are adjustable sliders: "Playhead",
"Selection start" and "Selection end" (in multiple mode, "Range n start" and "Range n end"; with cut markers, "Split n"
whose value is its time and the parts it separates, "0:01.50, between parts 1 and 2", and which a press selects). Increment and decrement move them one frame, and handle moves
are undoable.

**Cut markers (opt-in; Split uses them).** `timeline.showsCuts = true` turns them on; it is false by default, so the
other editors draw and behave exactly as before. Use them with `.none` (Split does).

- Drawing: the lanes come apart at each cut into one rounded segment per part, each with its own outline, so the
  parts read as separate clips (the lanes are clipped to `partSegments`). The gap is 10 pt, wider than the playhead's
  5 pt halo, so a cut stays visible under the playhead. Each cut has a 14 × 11 pt tab under the lanes (the timeline
  keeps 30 pt under them instead of 17 when cut markers are on): hollow and neutral (secondary label colour), tinted
  on hover, filled with the accent when selected (outlined in `MediaColors.cutTabOutline`, the deep accent in light
  mode: 5.4:1 against the timeline, where the accent alone is 2.9:1), deeper while pressed. Only the selected cut
  has an accent line in its gap: the accent stays the playhead's and the selection's (color.md, "Avoid using the
  same color to mean different things"). A cut closer than 36 pt to a neighbour or an end is drawn compact
  (`isCompactCut`): a 1 pt gap and no tab unless it is selected or under the pointer, so many cuts don't eat the
  lanes. Each part's number ("1", "2"…) sits at its top-left in the top lane, in a dark capsule (white on black at
  55 %, at least 4.7:1 over any picture), pinned to the visible edge when the part starts off screen. When a part in
  view is too narrow for its number, only every 2nd, 5th, 10th… part is numbered, the smallest step whose numbers
  all fit, plus the first (`partNumberBadges()`), so the numbers never skip irregularly. Ruler labels are never
  hidden. The playhead is drawn on top.
- State: `cuts` (sorted seconds) and `selectedCut`, set with `setCuts(_:selected:)` (no callbacks) and
  `selectCut(_:)` (reports `onCutSelectionChange`).
- Rules: `cutSnap` maps a time under the pointer to where a cut lands (default `source.snap`; Split uses the start of
  the frame on screen), `cutBounds` the first and last place a cut can go, `cutGap` the least distance between cuts.
  `placeCut(i, at:in:)` applies all three; a dragged cut never crosses a neighbour.
- Mouse: a cut is grabbed 10 pt either side of it, from the top of the lanes to below its tab (`cutHitRect`, the
  nearest cut wins), with the resize-left-right pointer, as Trim's range edges are grabbed along the lanes. The ruler
  never grabs a cut: it always scrubs, so the playhead's head is the playhead's even when a cut sits under it.
  Pressing a cut selects it and scrubs to it (the frame that starts the next part); dragging moves it (`onLiveCuts`
  during the drag; the preview follows). Esc (`cancelDrag()`) puts it back. A click elsewhere in the lanes lets go of
  the selection and scrubs.
- Like ranges, the view never commits cuts itself: it reports `onCommitCuts(new, selected, "Move Split")` and the
  owner registers Undo and calls `setCuts`.

**Showing the result in the waveform.** `timeline.waveformPeak = { from, to, peak in … }` maps each drawn column's
loudest sample (0…1) to the one to draw. Bleep draws its tone's level (or nothing) inside its ranges, so the
waveform shows what Save will write. It reads `timeline.ranges`, so it follows a drag live.

**Other properties.** `timeline.x(_:)` and `timeline.time(atX:)` convert between time and the view's x.
`timeline.strip` and `timeline.peaks` can be set by hand (snapshots and tests do).

## 4. The source, times and encoding

**`MediaSource.load(url)`** runs `ffmpeg -i` once and parses it with `MoreFormats.MediaProbe` and `FFmpeg.MediaInfo`,
plus what those miss:

| Property | Meaning |
|---|---|
| `rotation` | Clockwise turn: 0, 90, 180 or 270 |
| `sampleAspect` | The stream's SAR. When the codec's and the container's differ, the container's wins, as in ffmpeg |
| `videoCodec`, `pixelFormat`, `colorMatrix` | Codec, pixel format, and the colour matrix tag (nil when untagged) |
| `videoStart` | Time of the first video frame (wmv starts at 0.046 s) |
| `audioStart` | When the sound starts, as the container reports it (0 when it reports none; not a decoder's own delay) |
| `audioCodec`, `audioBits`, `audioBitrate` | Sound codec, PCM/FLAC bit depth, bit rate |
| `kind` | .video when there is a picture |
| `frameDuration` | One frame, or 0.01 s for audio. NTSC rates, which ffmpeg prints rounded ("23.98 fps"), are the exact 24000/1001, 30000/1001, 60000/1001 and 120000/1001 |
| `snap(t)` | The nearest frame start on the `videoStart + n/fps` grid |
| `snapEnd(t)` | `snap`, or the file's length when no further frame fits |
| `step(t, by:)` | `snap(t)` moved by n frames |

`MediaSource.parse(text, url:)` parses captured ffmpeg output, for tests. It reads ffmpeg's report without the file
path (every occurrence of `url.path`: a name can hold line breaks) and the `Metadata:` blocks
(`MediaSource.withoutTags`), so a tag or a name such as "Duration: 10:00:00.00" can't set the length. A length the container itself claims is still believed, so code that scales with `duration` (buffers, loops,
the ruler) must not trust it: a damaged file can claim years.

**`MediaTime`** handles time text:

- `string(t)` gives "1:05.50": m:ss.ff in hundredths, and h:mm:ss.ff from an hour.
- `parse` reads "1:05.5", "90" and "0,5", and refuses "0:61".
- `arg(t)` gives an ffmpeg argument with 6 decimals.
- `lengthString` gives "2.70 s".

**`MediaEncode`** writes edits in the input's own container (the table in map-media.md):

| Container | Picture | Sound | Extra |
|---|---|---|---|
| mp4, m4v, mov, 3gp, 3g2, mkv | VideoToolbox H.264 (`-q:v 70`; `avc1` tag except mkv) | AAC at about the source bit rate, at least 128k | `+faststart` except mkv |
| webm | VP9 crf 32 | Opus | |
| avi | XVID q3, `-r` constant rate | MP3 192k | |
| wmv, asf | WMV2 q3 | WMA 2 | |
| other containers | mp4 | | |

- Audio files keep their own codec (`Converter.normalizeAudioArgs`): PCM keeps its sample format (24-bit WAV stays
  24-bit), FLAC keeps its depth, lossy codecs keep about the source bit rate, and WMA is capped at 48 kHz.
- `outputExtension(for:)` gives the extension of the edited copy.
- `videoArgs(for:ext:videoFilters:audio:audioFilters:quality:)` maps the first video and first audio stream, builds
  one `-vf` from your filters plus an even-size crop and one `-af` from your filters, and adds the codecs and muxer
  flags. Never add another `-vf` or `-af`, because ffmpeg keeps only the last one.
- `audioOnlyArgs(for:ext:filters:)` does the same for sound alone. `audioCodecArgs`, `videoCodecArgs` and
  `containerArgs` are the pieces.

**Running ffmpeg.** Call `FFmpeg.run(input:output:args:duration:inputOptions:progress:)`, with `inputOptions` before
`-i` (fast `-ss`). Pass the output's length as `duration`, so progress is right. `MediaKit.runFFmpeg(…, job:)` is the
same, but a `MediaJob` can cancel it. A failed run throws `FFmpeg.failureMessage`'s line: the system's own words for a
full disk or a folder it can't write to ("File too large", "No space left on device", "Permission denied") win even
on a follow-up line, so a caller can turn them into a sentence (Split does). Name outputs with `outputURL(for:ext:suffix:)` and the suffix conventions.md
gives.

**Reusing Trim's cut.** `MediaTrim.trim(url, options: ["start": …, "end": …], source: probed, output: url)` writes an
exact cut to a file you name (Split writes each part into a temporary folder on the same disk, checks it has a
picture or sound, and moves the whole set next to the original only when every part is there). Split's window saves
through `--tool split --opt at=1.2,2.6` (times on the frame grid, or the nearest sample for sound, with one sample of
slack; `MediaSplit.cutBounds`, `problem`, `frameStart(at:)` and `lastFrameStart` are the rules the window and the
command share; `lastFrameStart` reads the frame on screen at the end, not frame count × frame length, which ends early
in a variable-rate WebM or MKV that reports its nominal rate, and the window's `makeOptions` runs `cutTimes` so a time the command would refuse keeps the window
open with its sheet).

**Sound clocks.** Every time in the kit is on the file's clock: the picture's, the player's, `-ss`'s, `atrim`'s and
`aeval`'s `t`. Sound doesn't always start at 0 on it: a recording's sound often starts a little after the picture,
and ffmpeg's WMA decoder puts the first sample at 0.092 s (`MediaBleep.audioStart(url)` reads it). Anything that
moves sound to 0 (`asetpts=PTS-STARTPTS`, raw samples, the tempo filters, a container that can't record a start such
as AVI) must pad it first with `MediaKit.soundFromZero(source, seek:)` (`aresample=first_pts=0:min_hard_comp=1e9`), or
the sound slides ahead of the picture by that much. The waveform, Trim's re-encode, Split, Speed (with a picture) and
Visualize's drawing do; Bleep and Channels keep the sound's own times. ffmpeg makes the padding as one block in memory,
so `soundFromZero(source, seek:)` returns no filter when `audioStart` is more than `MediaKit.maxLeadSamples` (2^26
samples, about 11 minutes of 48 kHz stereo) past the seek point: a file that claims its sound starts a day in would
otherwise take 2 GB and a minute (the waveform prepends that lead as zeros itself). `min_hard_comp` keeps aresample from
filling jumps later in the sound's times the same way. `MediaMeasure.pcm(…, fileClock: true)` measures on that clock. Every WMA re-encode also moves the
whole sound 46 ms earlier (ffmpeg's wmav2 encoder delay, which ASF can't record); edits move with it, and an ASF
muxer that meets the encoder's negative first time shifts both streams by 46 ms (so its reported length grows). A cut
of sound alone into WMA puts that block of silence in front instead (`MediaTrim.encoderPreroll`), so nothing is lost.

**WMV/ASF re-encodes** pass `-fps_mode passthrough` (in `videoCodecArgs`): ffmpeg otherwise treats ASF as
constant-rate and repeated a last frame whose display ran on to the end of longer sound.

**Frame-accurate cuts (Trim's recipe, reuse it for Split, Speed and the rest).**

1. `MediaTrim.frameRange(range, source:)` puts both ends on frame starts.
2. Seek half a second early with `-ss` before `-i` (`MediaTrim.seekPoint`), and stop reading with `-t` one second after
   the end. In a container without an index (`MediaKit.unindexedContainers`: .ts, .m2ts, .vob, .mpg…) ffmpeg seeks
   by bytes and the decoder drops every frame up to the next key frame, so the seek also goes half a second before the
   last key frame at or before the cut (`MediaKit.seekBefore`, which reads the key frames up to it; Split reads them
   once for all its parts). Anything else that seeks to show or cut a frame needs the same (`stillFrame` does).
3. Keep frames with `select=gte(t\,A-fd/2)*lt(t\,B-fd/2)`, then `setpts=max(0\,PTS-A/TB)`: the first kept frame
   keeps its distance from the cut, as the sound does (a wmv's first frame at 0.046 s; the next frame after a still
   in a variable-rate recording, which `PTS-STARTPTS` put 0.34 s ahead of its sound). A cut inside a still the file
   holds (the frame on screen at the cut began more than 1.5 frames before it: `MediaTrim.heldFrame`, which decodes
   around the cut with `MediaSnapshot.frameTime` except in constant-rate MP4/MOV) keeps that still too, from the seek
   before it, as the first frame at 0; otherwise the part had no picture until the screen changed. The still is then
   in both parts, each showing it for its own side of the cut. No `-ss` at all for a seek to
   0: in an FLV it landed seconds in (part 1 of a split had no picture), and an AAC or Opus decoder seeked to 0 drops
   its first packet.
4. Keep sound with `aresample=first_pts=0,atrim=start=A:end=B,asetpts=PTS-STARTPTS` (the first filter pads sound that
   starts after the seek point, so it keeps its place under the picture).

Don't use `trim` for video: it also keeps a frame that only overlaps the start (an off-by-one on sample.avi). Don't
rely on output `-t` either: its rounding adds a frame.

Stream copy is only exact from a key frame (`MediaKit.keyframes(source, upTo:)`). Even then, copied B-frames can run
past the end, so count the packets afterwards (`MediaKit.videoPacketCount`) and fall back to re-encoding. Trim's copy
reads the sound from a second input that starts half a second earlier and cuts it with `atrim` (read from the key
frame itself, a WebM part lost its first 20 ms of Opus).

**Sound alone.** Seek half a second before the cut (`MediaTrim.soundSeek`) and cut with `atrim` + `asetpts` (MP3's bit
reservoir and AAC's overlap need what comes before: a seek straight to the cut left 20–30 ms of silence at each join).
ffmpeg's WMA encoder drops the first block it is given (2048 samples at 44.1/48 kHz), so `MediaTrim.encoderPreroll`
puts that much silence in front; a WMA part still ends with up to one block of silence, since ASF can't say where the
sound ends. Edited .m4a files use ffmpeg's own AAC (`aac`), not AudioToolbox's, which padded every file to a whole
1024-sample frame without recording it.

**Other helpers.** `MediaKit.filmStrip`, `MediaKit.peaks` (`Peaks.peak(from:to:)`) and `MediaKit.runBinary` (stdout as
binary chunks).

## 5. Snapshots

```sh
.build/debug/DropWheel --snapshot trim out.png --opt start=0.8 --opt end=3.1 --opt playhead=1.5 [--opt dark=true] clip.mp4
```

`MediaEditorWindowController.snapshotView(MyEditor.self, url:, options:)` renders the whole window offscreen: title
bar, toolbar and content. It builds the controller with `snapshot: true`, which means no player, no proxy and no
autosave. It loads the strip and the waveform, sets a deterministic still, applies your `applySnapshotOptions`, and
captures the window frame.

| Base option | Meaning |
|---|---|
| `playhead` | Seconds (default: the first range's start) |
| `zoom` | 1 or more |
| `width`, `height` | Window content size (default 1000 × 660 video, 900 × 380 audio) |
| `dark` | `true` for dark mode |
| `loading` | 0…1 renders the "Preparing preview…" state |

The window is never on screen, so it renders as an inactive window: grey title, grey toolbar glyphs. Offscreen
rendering also can't capture the system's tinted glass, so in snapshots Save is drawn by `MediaProminentStandIn` (grey when there is nothing to save, as the real item is disabled).
Progress bars are `MediaProgressBar` (drawn) for the same reason. **Look at the PNG in light and dark mode.** A
snapshot error is drawn as text and still exits 0.

## 6. Tests

Add `--selftest <name>` in your module's `selfTest`, put the name in test.sh's list and one CLI line per tool in
Tests/features.sh (`ok <label> "$BIN" --tool <id> --opt k=v <fixture>`, and the snapshot id in the snapshot loop).

**`MediaTestSupport`** provides:

- `Checker("suite")`, with `check(ok, what)`, `throwsError(what, containing:) { … }` and `report`. The report starts
  with PASS or FAIL, which test.sh reads.
- `fixturesFolder()`, which finds Tests/fixtures/features (from `$DW_FIXTURES`, the current folder, or above the
  binary).
- `scratchCopy(of:from:)`, which copies fixtures into a temporary folder so outputs never land next to the
  originals.
- `editor(MyEditor.self, url:, size:, loadLanes:)`, a laid-out editor that is never shown.
- `key(_:keyCode:flags:window:)` with `Code`, and `mouse(_:at:in:)` and `drag(view, from:to:cancel:)` for timeline
  drags. Use `timeline.x(t)` for positions; the lanes are at `timeline.bounds.height / 2` and the ruler at y ≈ 8.
- `toolbarLayout(window, tools:)`: the toolbar's items leading to trailing and whether `tools` are the centred ones.
- `makeLateSoundClip(url)` and `flashAndBurst(url)`: a clip whose sound starts at 0.5 s with a flash and a 1 kHz burst
  together at 2.5 s, and when each happens on the file's clock. An edit that keeps them within 20 ms kept the sound
  in its place under the picture.

**`MediaMeasure`** decodes with ffmpeg:

| Function | Gives |
|---|---|
| `frameTimes(url)` | The time of every decoded frame |
| `frameRGB(url, index:, width:, height:, crop:)` | Frame pixels. `crop` evens a source the way a re-encode did |
| `frameLuma(url, index:)` | The luma plane with no colour conversion. Use it to compare with AVFoundation frames |
| `areaAverage(...)` | Averages a luma plane down to a small size |
| `psnr(a, b)` | Peak signal-to-noise ratio in dB |
| `pcm(url, rate:, channels:, fileClock:)` | 16-bit samples (`fileClock`: sample i is at i / rate on the picture's clock) |
| `sha256(url)` | A hash, for "input unchanged" checks |

Prove that a frame is the right one by beating its neighbours by 3 dB, not by an absolute PSNR alone. The test
pattern's adjacent frames score about 20 dB, the right frame 40–60 dB, and a 4:4:4 → 4:2:0 re-encode about 29 dB.

`MediaTrimTests.multipleRanges` already exercises the other two modes through two small test editors.
`RangesEditor` (`.multiple`) checks I/O adding ranges, drag-to-add stopping at a neighbour, click-to-select,
moving a range without overlap, ⌫, Undo and the VoiceOver elements. `FrameEditor` (`.none`) checks an overlay
installed in `didBuild`. Copy them as the starting point for the Bleep and Crop tests.

For a live preview, call `loadPreview()` on `MyEditor(source:snapshot: false)` and spin the run loop until
`playerReady`. See `MediaTrimTests.livePreview`: it attaches one `AVPlayerItemVideoOutput` before scrubbing and waits
for the buffer whose display time is the target, because buffers from earlier seeks wait in the output.

Run a mutation check before you finish: break one key behaviour per tool, confirm a check fails, then restore it.
`media-trim` catches each of these:

- a copy whose frame count isn't verified;
- a half-frame tolerance with the wrong sign;
- 24-bit PCM written as 16-bit;
- O ending at the playhead instead of after its frame;
- a dropped drag commit.

## 7. Gotchas found while building Trim

- **Lazy image decoding.** ImageIO decodes lazily from the file. `MediaKit.loadImage` reads the bytes and decodes
  immediately; anything else loses the image once the temporary PNG is deleted.
- **AVFoundation doesn't play** mkv, webm, avi, wmv or wma on macOS 27, so those get the proxy.
  `checkPlayable` asks rather than assuming.
- **Sound beyond the picture.** Container durations include sound that outlasts the picture (wmv: video ends 4.046
  s, file 4.09 s). Measure video length from frame times, not the "Duration" line.
- **`-ss` with `-c copy`** starts at the key frame at or before the time. Seek exactly to a listed key frame.
- **Close on Save.** The app has no Edit menu and `JobRunner.run` has no completion callback. Windows therefore
  close on Save and the HUD reports the result; if the job fails, the window is already gone.
- **Petal titles** must fit 82 pt on the wheel (`--snapshot wheel out.png --opt mode=tools clip.mp4`, and
  `--selftest wheel`), and a title already on that wheel is silently dropped.
