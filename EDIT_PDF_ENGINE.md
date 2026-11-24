# Edit PDF engine: API for the window builder

Everything here is in `Sources/DropWheel/` and is checked by `--selftest pdf-edit` (193 checks). The engine never
writes the input file. Its output is always "<name> edited.pdf", and Save writes nothing unless the result passes the
verification gate.

| File | What it holds |
|---|---|
| `PDFEditTool.swift` | `PDFEditTool` (the FeatureModule): the petal, the `present` hook, the command-line `run`, self-test routing |
| `PDFEditSession.swift` | `PDFEditSession` (the API below), `PDFEditBuilder` (edits → one incremental update), `PDFEditAnalysis` (reads the candidate back) |
| `PDFContentRuns.swift` | `PDFPageContent`: runs, lines, images, glyph quads, `PDFEditGeometry` |
| `PDFEditFonts.swift` | `PDFEditFont` (decode, encode, evidence), `PDFFontMatch` (installed or closest font, editor font), `PDFTransplant` |
| `PDFEditVerify.swift` | the gate |
| `PDFObjectFile.swift`, `PDFObjectWriter.swift` | object parser, incremental writer, compaction writer |

All session calls are main-thread only, and the session is not thread-safe. `save` renders pages for the gate.
That takes about 0.1–0.2 s for the fixtures and grows with page size, so it is fine on the main thread for normal files.

## 1. The petal and opening a window

```swift
WheelCommand(wheel: .tools, id: "editpdf", title: "Edit PDF…", symbol: "character.cursor.ibeam",
             applies: PDFEditTool.applies,            // exactly one .pdf
             present: { PDFEditTool.present($0) }, run: …)
```

`PDFEditTool.present(_:)` refuses encrypted files with a HUD message. Otherwise it calls `PDFEditTool.openWindow`.

**Hook-up.** In your module's `appDidLaunch()`, set `PDFEditTool.openWindow = { PDFEditWindowController.open($0) }`,
or replace the body of `present`. Until one of those is done, the petal shows "The Edit PDF window isn’t part of this
build yet."

## 2. Opening a document

```swift
let session = try PDFEditSession(url: url)
session.undoManager = window.undoManager   // the one windowWillReturnUndoManager returns
session.onChange = { change in … }         // after every change, undo and redo included
```

**Errors from `init`.** It throws a `ConversionError` whose `localizedDescription` you can show as is:
- "<name> is encrypted, so its text can’t be edited. Use Remove Password first." This covers both user-password
  and owner-password-only files.
- "Couldn’t read <name>."
- A damaged-file or unreadable-page-tree message.

**What the session exposes:**
- `session.pageCount` and `session.pages[i]` (`PDFObjectFile.Page`). Each page has `cropBox`, `mediaBox` and `rotate`
  (0, 90, 180 or 270).
- `session.originalDocument`, a `PDFDocument` of the original. Use it for thumbnails of pages that haven't changed.
- `session.isReadOnly`. This is true only for a certification signature that allows no changes (DocMDP P = 1).
  Every edit then throws, and every line is `.readOnly`.

## 3. Pages, lines and coordinates

**Coordinate space.** Every quad and point is in PDF page space: the unrotated user space of the page, the same space
`PDFPage` uses for `bounds(for:)` and annotations.

**Upright coordinates.** To draw upright, use
`PDFEditGeometry.uprightTransform(crop: page.cropBox, rotate: page.rotate)`. It maps page space to the shown page,
with the crop box's bottom-left at the origin and /Rotate applied. It is identical to `PDFArchive.pageTransform(pdfPage)`,
and the self-test checks that.

**Lines and images:**
- `session.lines(page: i) -> [PDFTextLine]` returns lines in reading order, which is the Tab order: top to bottom,
  then left to right. `PDFLineID(page: i, line: k)` addresses line `k` of that array. IDs always refer to the
  original document, so they stay stable while edits pile up.
- `session.find(_ text:, page:)` returns the IDs of lines whose original text contains `text`.
- `session.content(page: i).images` lists the placed images as `PDFImagePlacement` (`.quad`, `.bounds`). Use them
  for the "Scanned image" hover reason.

**`PDFTextLine` fields.** These describe the original state.

| Field | Meaning |
|---|---|
| `text` | Gaps wider than about 0.15 em between runs, and TJ kerning gaps wider than 0.18 em, read as one space. |
| `quad` | Bottom-left, bottom-right, top-right, top-left. It runs from the font's descent to its ascent, along the baseline. Trailing spaces are excluded. |
| `origin` | Baseline start. |
| `direction` | Unit baseline vector. |
| `angle` | Degrees counter-clockwise in page space. |
| `pointSize` | Tf × text matrix × CTM, in page points. |
| `hidden` | Render mode 3 or 7. |
| `runs` | Indices into `content(page:).runs`. |

**Current state for drawing and the inspector.** `session.info(id) -> PDFLineInfo?` gives the line as it is now:

| Field | Meaning |
|---|---|
| `text`, `originalText` | Current text and original text. `text` is "" for a deleted line. |
| `isEdited`, `isDeleted` | |
| `quad`, `originalQuad` | `quad` is re-read from the candidate after an edit. The outline grows and shrinks with the new text. |
| `origin`, `direction`, `angle`, `pointSize`, `color` | Position, angle, size and colour for the inline editor. `color` is sRGB, from the run's fill colour. |
| `availability` | `.editable` or `.readOnly(reason)` (§4) |
| `notes: [PDFLineNote]` | Inspector notes, each with `.message`: `.hiddenText`, `.clippingText`, `.drawnGlyphs` (Type 3), `.rotated(angle)` (not a multiple of 90°: edit in a popover) |
| `fontDescription` | The font source line of the inspector, for example "Embedded subset of Monaco", "Helvetica, a standard PDF font", "Arial, not embedded" or "Glyphs drawn by the PDF itself (…)". |
| `substitutions: [PDFFontSubstitution]` | Characters taken from a font on this Mac. `.description` gives "5 characters from Monaco (this Mac)", "… (closest match on this Mac)", or "…, approximate size" for Type 3 fonts. |
| `spacing`, `scope` | The edit's current spacing and scope |
| `sharedPages` | Greater than 1 when the line is inside a form drawn on several pages |
| `overflow` | Points the new text runs past its room: the next text on the same baseline, or the crop-box edge, never less room than the line had. It also counts new glyph overlaps under Keep Position. `overflowMessage` gives "17.5 pt too wide", or nil below 0.05 pt. |
| `fitScale` | The horizontal scale Fit Width applied, clamped to 0.7–1.3 (1 = none) |

**Inline editor font.** `session.editorFont(id) -> (font: NSFont, source: PDFEditorFontSource)` is sized in page
points, so multiply by the zoom. The choices are tried in this order:
1. For a subset font, the same family installed on this Mac (`.installed`). It has every glyph, and new characters
   come from it anyway.
2. The embedded program (`.embedded`).
3. The installed or closest font (`.installed` / `.similar`).
4. The system font (`.system`).

## 4. Availability and refusals

**`session.availability(id)`** returns `.readOnly(reason)` with one of these reasons:
- "The signature on this PDF doesn’t allow changes."
- "Vertical text can’t be edited yet."
- "This text has no character information, so it can’t be edited."
- "This text’s font is missing from the PDF."
- "This text’s font is set in an unusual way, so it can’t be edited." (The font comes from an ExtGState.)
- "This page’s content can’t be read reliably, so it can’t be edited." (The stream count disagrees with Core Graphics.)
- A stream problem, for example "Part of this page is stored with DCTDecode, which can’t be edited."
- A limit for crafted or runaway files (see below), for example "Part of this PDF expands to more than 256 MB when
  it’s decompressed, so it can’t be edited." or "This page draws the same nested content too many times to edit."

**Limits for hostile input.** The parser never traps, recurses without bound or allocates without bound on a
crafted file; `--selftest pdf-edit` (and `--selftest pdf-edit-hostile` alone) checks each case:
- Numbers: anything that isn't a PDF number (`+nan`, `-inf`, `0x1p3`) is a keyword; values too large for a Double
  are clamped; every integer read from the file goes through `PDFNumber.int` (nil past 1e15) instead of `Int(_:)`.
- Decoding: 256 MB per stream (`PDFFilters.maxDecodedBytes`), checked while inflating, so a Flate, LZW or
  RunLength bomb stops early; at most 8 chained filters; 1 GB of decoded streams per file
  (`PDFObjectFile.maxTotalDecodedBytes`), each kept once. Predictor parameters must fit the data.
- Cross-reference data: xref-stream rows come from the stream's data (a huge /Index can't create phantom entries);
  an /XRefStm only fills the free rows of its own table, so an object a later update deleted stays deleted.
- Objects: `object(_:)` refuses a number it is already reading, so /Length references and object streams that
  refer to each other end instead of overflowing the stack.
- Content: 20,000 form draws or 512 MB of form content per page; inline image data is skipped by its length
  when the dictionary gives it; text placed with absurd numbers (a 1e300 pt font) is left out of the lines.
- Per page, at most 500,000 kept items (runs, their glyphs and TJ elements, array elements read, images;
  `PDFPageContent.maxItems`), 10 million operators and a q or marked-content depth of 10,000; past any of them the
  page reports "This page has more content than Edit PDF can read, so its text can’t be edited." and its lines are
  read-only. A content array keeps at most 100,000 elements. PDFKit is asked for the text under codes without
  Unicode at most 5,000 times a page.
- Xref-stream fields that wrap to a negative number are ignored. Streams are copied out of the file at most
  3 × its size + 64 MB in all, and "endstream" positions are found once, so many streams without a usable /Length
  don't make reading quadratic.
- "Remove replaced text" writes only the numbers in use when they are sparse (a live object numbered
  999,999,999, or a /Size of 10¹²), in subsections; ordinary files keep one subsection.
- CMaps clamp CIDs and codes past UInt32 (`PDFSVGCMap`, shared with the SVG export).

**Refusals at commit.** Some edits are refused when they are committed. The edit throws, and the edit list stays
exactly as it was:
- "Emoji can’t be added as PDF text."
- "“z” isn’t in this text’s font, and clipping text can only use characters its font already has." (Render modes
  4–7 need a transplant.)
- "Some of “…” can’t be added as PDF text."
- "“…” can’t be drawn with the fonts on this Mac."

Show the `localizedDescription` in an error sheet and keep the inline editor open.

## 5. Editing (each call is one undo step)

| Call | Undo name | Notes |
|---|---|---|
| `setText(_ text, for: id, spacing: PDFSpacing? = nil, scope: PDFEditScope? = nil)` | "Edit Text" | Commit an inline edit. `text` is the whole new line; the engine diffs it against the original by common prefix and suffix in glyph units. Setting the original text back removes the edit. `nil` keeps the line's previous spacing and scope; the defaults are `.flow` and `.thisPage`. |
| `deleteLine(id, scope:)` | "Delete Text" | ⌫ on a selected line. Equal-advance spacer, so nothing else moves. |
| `revert(id)` | "Revert Text" | The inspector's Revert |
| `setSpacing(_ : PDFSpacing, for: id)` | "Change Spacing" | `.flow` (default), `.keep` ("Keep Position"), `.fit` ("Fit Width"). `PDFSpacing.title` gives the label. |
| `setScope(.allPages / .thisPage, for: id)` | "Edit All Pages" / "Edit This Page" | The shared-text banner's buttons |
| `addText(_ text, page:, at: CGPoint, style: PDFTextStyle) -> UUID` | "Add Text" | `at` is the baseline start in page space. The text is drawn upright for the page's /Rotate. |
| `updateAddedText(id, text:, origin:, style:)` | "Move Text" (origin only) / "Edit Text" | |
| `removeAddedText(id)` | "Delete Text" | |

**Spacing modes:**
- **Flow** lets later glyphs of the same show operator move, as when typing. Text that is positioned on its own (Td
  or Tm) never moves; overflow reports the collision.
- **Keep Position** appends the kerning number `(A_new − A_old)·1000/(Tfs·Th)`.
- **Fit Width** wraps the operator in `n Tz … orig Tz`, clamped to 70–130 %. The scale makes the visible text as wide
  as it was; trailing padding spaces don't count. A final kerning number keeps the operator's total advance, so text
  chained after it doesn't move. When the clamp is reached, `overflow` reports the rest.

**Undo.** `undoManager` must be set before the first change. Undo and redo call `onChange` with a
`PDFEditChange(lines:, added:, actionName:)`. Use it to scroll to the line and outline it for 0.6 s
(undo-and-redo.md:17), without the fade when Reduce Motion is on.

**Reading the edit list.** `edits: [PDFEdit]` is the undo model. You can read it, but change it only through these
calls or `replaceEdits(_:actionName:)`. `addedTexts: [PDFAddedText]` gives each added text's `id`, `page`, `origin`,
`text`, `style`, current `quad` and `substitutions`.

**Status and markers:**
- `pagesWithChanges: Set<Int>` drives the sidebar's "edited" dot.
- `statusText` gives, for example, "3 changes on 2 pages · 1 font substituted · Replaced text stays in the file’s history".
  The last part appears only for text edits or deletes while "Remove replaced text" is off. With no edits it is
  "No changes".
- `hasChanges` decides whether the close button asks "Discard your changes?".

## 6. Drawing

**`session.candidateDocument`** is a `PDFDocument` of the original plus the pending incremental update. These are
the same bytes Save writes before the gate, and they are rebuilt after every change.
- Keep a strong reference to the document while you draw its pages. A `PDFPage` whose document was released draws
  nothing.
- Draw with `page.draw(with: .mediaBox, to:)` after applying the page's transform, or with your own upright mapping.
- `session.candidateData` gives the raw bytes.

**`session.previewDocument(blanking: id)`** returns the candidate with that line removed by a spacer. Draw it behind
the inline NSTextView while the line is being edited. It is cached per line until the next change.

**Banners:**
- `session.banners(page: i) -> [PDFEditBanner]` gives `.signed`, `.certified`, `.scanned` (an image covers at least
  half the page and there is no text), `.ocrOnly` (the image is covered by hidden text only) and `.unreadable(why)`.
- `session.banner(for: id)` gives `.sharedText(pages: n)` for the selected line; pair it with All Pages and Only This Page.
- Each banner's `.message` is the sentence to show, for example "This text appears on 2 pages." or "This PDF is signed.
  Saving keeps the signed version, but viewers will show it was changed after signing."

## 7. Saving

```swift
session.removeReplacedText = checkbox.state == .on   // "Remove replaced text from the file"
let out = try session.save()                         // "<name> edited.pdf" next to the original; or save(to:)
JobRunner.report(saved: [out])
```

**The checkbox.**
- Disable it when `!session.canRemoveReplacedText` (signed files) and show
  `removeReplacedTextUnavailableReason`.
- Turning it on makes Save rewrite the file whole, keeping every unchanged object byte for byte.
- Turning it off keeps one appended update, with the original as an exact prefix.
- A file whose cross-reference data was damaged is always rewritten whole.

**When the gate fails**, `save` throws "The edited PDF didn’t pass its final check (…), so nothing was saved." Show
it as a sheet. The gate runs in memory and checks:
- the original is a prefix of the result
- our parser, PDFKit and Core Graphics all reopen the result, with the same page count
- catalog keys, bookmarks and annotations per page are unchanged
- the update holds exactly the objects the engine wrote
- there are 0 changed pixels at 100 dpi outside the old and new text (+2 pt)
- every new visible glyph has ink
- the new text reads back in PDFKit (skipped for lines PDFKit couldn't read before)

## 8. Command line (the same session)

The debug binary keeps the Swift target's internal name (`.build/debug/DropWheel`); inside YummyOrange.app the same
program is `Contents/MacOS/YummyOrange`.

```
.build/debug/DropWheel --tool editpdf --opt find="Quarterly Report" --opt replace="Quarterly Totals" report.pdf
  [--opt page=N] [--opt all=true] [--opt spacing=flow|keep|fit] [--opt clean=true]
.build/debug/DropWheel --tool editpdf --opt 'edits=[{"page":1,"find":"Line 1","replace":"Row 1"},
                                                   {"page":2,"delete":"Line 8: …"},
                                                   {"page":3,"add":"Checked","x":400,"y":60,"size":16,"font":"Helvetica","color":"#CC2200"}]' report.pdf
```

**Options:**
- `all=true` replaces every match, and edits shared forms on all pages. Without it, only the first match in
  reading order is replaced.
- `delete` removes that text and keeps the rest in place, using a spacer for a whole line and Keep Position otherwise.
- The `x` and `y` of `add` are page-space points.

The command prints the output path.
