#if DEBUG
// Self-tests: built into debug builds only (./test.sh); the shipped app leaves them out.
import AppKit
import PDFKit

/// `--selftest pdf-edit-ui`: the Edit PDF window offscreen, driven by synthesized clicks and keys: hover, click to
/// edit (caret at the glyph, the line's font, size, colour and baseline at the zoom), typing and IME input, Return,
/// Tab, ⇧Tab, Esc (twice), ⌫ on a selected line, ⌘Z / ⇧⌘Z with the 0.6 s outline (Reduce Motion on and off),
/// overflow with Fit Width and Keep Position, a refused edit, Add Text (type, move, edit), the inspector, the banners,
/// accessibility elements, rotated pages, zoom and pages, the discard prompt, ⌘S writing "report edited.pdf" that reads
/// back, "Remove replaced text from the file", and the snapshot.
enum PDFEditUITests {
    typealias Checker = PDFEditTests.Checker

    static func run() -> String {
        let c = Checker()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dropwheel-pdfedit-ui-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: dir)
            PDFEditCanvas.reduceMotionOverride = nil
        }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let t0 = Date()
            guard let report = PDFEditTests.fixture("report.pdf") else {
                return "FAIL pdf-edit-ui: Tests/fixtures/core/report.pdf not found (run from the project folder)"
            }
            try windowAndEditing(c, report, dir)
            try addTextAndInspector(c, report, dir)
            try removeReplacedAndDiscard(c, report, dir)
            try rotatedPages(c, dir)
            try bannersAndSnapshot(c, report, dir)
            try reviewRegressions(c, report, dir)
            c.lines.append("time \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        } catch {
            c.check(false, "error: \(error.localizedDescription)")
        }
        return (c.failed == 0 ? "PASS" : "FAIL") + " pdf-edit-ui (\(c.count - c.failed)/\(c.count) checks)\n" + c.lines.joined(separator: "\n")
    }

    // MARK: - Driving the window

    /// One editor window, never put on screen.
    final class Driver {
        let controller: PDFEditWindowController
        var window: NSWindow { controller.window }
        var canvas: PDFEditCanvas { controller.canvas }
        var session: PDFEditSession { controller.session }
        var reported: [URL] = []

        init(_ url: URL) throws {
            controller = PDFEditWindowController(session: try PDFEditSession(url: url), snapshot: false,
                                                 size: CGSize(width: 1180, height: 760))
            controller.reporter = { [unowned self] urls in self.reported += urls }
            controller.root.layoutSubtreeIfNeeded()
            canvas.setZoom(1)
        }

        func id(_ text: String, page: Int = 0) -> PDFLineID? { session.find(text, page: page).first }

        /// A view point on a line: `fraction` of the way along its baseline band, halfway up.
        func point(_ id: PDFLineID, at fraction: CGFloat = 0.5) -> CGPoint {
            let q = canvas.currentQuad(.line(id))
            let a = CGPoint(x: (q[0].x + q[3].x) / 2, y: (q[0].y + q[3].y) / 2)
            let b = CGPoint(x: (q[1].x + q[2].x) / 2, y: (q[1].y + q[2].y) / 2)
            return canvas.viewPoint(CGPoint(x: a.x + (b.x - a.x) * fraction, y: a.y + (b.y - a.y) * fraction))
        }

        /// The view point of the gap before character `index` of a line (uniform advance: report.pdf is Monaco).
        func point(_ id: PDFLineID, beforeCharacter index: Int) -> CGPoint {
            let n = CGFloat(session.line(id)?.text.reversed().drop(while: { $0 == " " }).count ?? 1)
            return point(id, at: (CGFloat(index) + 0.25) / n)
        }

        func mouse(_ type: NSEvent.EventType, _ p: CGPoint, clicks: Int = 1) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: canvas.convert(p, to: nil), modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
        }

        func click(_ p: CGPoint, clicks: Int = 1) {
            canvas.mouseDown(with: mouse(.leftMouseDown, p, clicks: clicks))
            canvas.mouseUp(with: mouse(.leftMouseUp, p, clicks: clicks))
        }

        func drag(_ from: CGPoint, _ to: CGPoint) {
            canvas.mouseDown(with: mouse(.leftMouseDown, from))
            for k in 1...4 {
                let f = CGFloat(k) / 4
                canvas.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * f, y: from.y + (to.y - from.y) * f)))
            }
            canvas.mouseUp(with: mouse(.leftMouseUp, to))
        }

        func hover(_ p: CGPoint) { canvas.mouseMoved(with: mouse(.mouseMoved, p)) }

        /// A key press sent through the window, as the system would (window shortcuts first, then the focused view).
        func key(_ chars: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) {
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, characters: chars,
                                     charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
            window.sendEvent(e)
        }

        func returnKey() { key("\r", 36) }
        func tab() { key("\t", 48) }
        func backTab() { key("\u{19}", 48, .shift) }
        func escape() { key("\u{1b}", 53) }
        func command(_ k: String, shift: Bool = false) { key(shift ? k.uppercased() : k, keyCode(k), shift ? [.command, .shift] : .command) }

        private func keyCode(_ k: String) -> UInt16 {
            ["z": 6, "s": 1, "=": 24, "-": 27, "0": 29, "w": 13][k] ?? 0
        }

        var editorText: String? { canvas.editor?.textView.string }

        /// Types at the end of the line (as the input system does), whatever the caret.
        func typeAtEnd(_ text: String) {
            guard let tv = canvas.editor?.textView else { return }
            tv.insertText(text, replacementRange: NSRange(location: (tv.string as NSString).length, length: 0))
        }

        func pump(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
    }

    // MARK: - 1. Window, click, type, Return, Tab, Esc, ⌫, undo, overflow, ⌘S

    static func windowAndEditing(_ c: Checker, _ fixture: URL, _ dir: URL) throws {
        c.section("window and inline editing (report.pdf)")
        let url = dir.appendingPathComponent("report.pdf")
        try FileManager.default.copyItem(at: fixture, to: url)
        let original = try Data(contentsOf: url)
        let d = try Driver(url)
        let ctl = d.controller, canvas = d.canvas, session = d.session

        // Window and toolbar.
        c.check(d.window.title == "report.pdf" && d.window.subtitle == "Edit PDF" && d.window.representedURL == url,
                "titled “report.pdf”, subtitle “Edit PDF”, represented URL set")
        let ids = d.window.toolbar?.items.map(\.itemIdentifier.rawValue) ?? []
        c.check(ids == ["pdfedit.sidebar", "NSToolbarFlexibleSpaceItem", "pdfedit.mode", "pdfedit.zoom", "NSToolbarFlexibleSpaceItem",
                        "pdfedit.undo", "pdfedit.redo", "pdfedit.inspector", "pdfedit.save"],
                "toolbar: sidebar · Edit Text|Add Text, zoom · Undo, Redo, inspector, Save (\(ids.count) items)")
        // The item's `.prominent` style draws nothing in YummyOrange's toolbars, so Save is the image editors' accent button.
        let prominent = d.window.toolbar?.items.filter { $0.view is ImageEditors.Bar.ProminentButton }.map(\.itemIdentifier.rawValue) ?? []
        c.check(prominent == ["pdfedit.save"], "Save is the one prominent toolbar item (an accent push button): \(prominent)")
        let item = { (id: String) in d.window.toolbar?.items.first { $0.itemIdentifier.rawValue == id } }
        c.check(item("pdfedit.undo")?.isEnabled == false && item("pdfedit.save")?.isEnabled == false,
                "Undo and Save start disabled")
        c.check(d.window.contentMinSize.width >= 900 && ctl.root.minimumSize.height >= 500, "a sensible minimum size")
        c.check(ctl.numberOfRows(in: ctl.table) == 3 && (0..<3).allSatisfy { ctl.thumbnail($0) != nil },
                "sidebar: 3 page thumbnails")
        if let p = session.originalDocument.page(at: 0) {
            let t = p.transform(for: .cropBox), u = PDFEditGeometry.uprightTransform(crop: session.pages[0].cropBox, rotate: session.pages[0].rotate)
            c.check(abs(t.a - u.a) + abs(t.b - u.b) + abs(t.c - u.c) + abs(t.d - u.d) + abs(t.tx - u.tx) + abs(t.ty - u.ty) < 0.001,
                    "the canvas draws with PDFKit's crop-box transform, which equals the engine's upright mapping")
        }

        guard let head = d.id("Quarterly Report"), let l1 = d.id("Line 1:"), let l2 = d.id("Line 2:"), let l3 = d.id("Line 3:"),
              let l4 = d.id("Line 4:"), let l5 = d.id("Line 5:") else { c.check(false, "report.pdf lines found"); return }

        // Hover.
        d.hover(d.point(head))
        c.check(canvas.hovered == .line(head), "hovering the title outlines it")
        d.hover(CGPoint(x: canvas.pageFrame.maxX - 20, y: canvas.pageFrame.maxY - 20))
        c.check(canvas.hovered == nil, "hovering empty paper outlines nothing")
        d.hover(d.point(l1))
        c.check(canvas.hovered == .line(l1), "hovering Line 1 picks Line 1, not the overlapping title or Line 2")

        // Click: the caret goes to the clicked glyph, in the line's font, size, colour and baseline.
        d.click(d.point(head, beforeCharacter: 10))
        guard let ed = canvas.editor else { c.check(false, "a click on a line opens the inline editor"); return }
        c.check(ed.lineID == head && d.window.firstResponder === ed.textView, "a click opens the inline editor with the keyboard")
        c.check(ed.textView.selectedRange() == NSRange(location: 10, length: 0),
                "the caret lands before the clicked glyph (index \(ed.textView.selectedRange().location), wanted 10)")
        let f = ed.textView.font
        c.check(f?.familyName == "Monaco" && abs((f?.pointSize ?? 0) - 12 * canvas.zoom) < 0.01,
                "the editor types in Monaco at 12 pt × zoom (\(f?.familyName ?? "?") \(f?.pointSize ?? 0))")
        let onCanvas = ed.textView.convert(laidOutBaseline(ed.textView), to: canvas)
        let want = canvas.viewPoint(session.line(head)!.origin)
        c.check(hypot(onCanvas.x - want.x, onCanvas.y - want.y) < 0.75,
                "the editor's baseline sits on the line's baseline (off by \(String(format: "%.2f", hypot(onCanvas.x - want.x, onCanvas.y - want.y))) pt)")
        if let tc = ed.textView.textColor?.usingColorSpace(.sRGB) {
            c.check(tc.redComponent < 0.05 && tc.greenComponent < 0.05 && tc.blueComponent < 0.05, "the editor uses the line's colour (black)")
        }
        // The old glyphs are blanked behind the editor (drawn from the preview with the line removed).
        if let blank = session.previewDocument(blanking: head)?.page(at: 0)?.string {
            c.check(!blank.contains("Quarterly Report - Page 1"), "behind the editor the page is drawn without the line’s old glyphs")
        }

        // Typing (keyboard events through the window) and typing undo.
        d.key("X", 7)
        let typedByKey = d.editorText == "Quarterly XReport - Page 1"
        c.check(typedByKey, "a key press types into the line (\(d.editorText ?? "nil"))")
        d.command("z")
        c.check(d.editorText == "Quarterly Report - Page 1" && session.edits.isEmpty, "⌘Z while typing undoes the typing, not a committed change")
        ed.textView.setSelectedRange(NSRange(location: 10, length: 6))
        ed.textView.insertText("Totals", replacementRange: NSRange(location: NSNotFound, length: 0))
        c.check(d.editorText == "Quarterly Totals - Page 1", "typing replaces the selected word")
        let w0 = ed.host.frame.width
        ed.textView.insertText("!", replacementRange: NSRange(location: 25, length: 0))
        c.check(ed.host.frame.width > w0, "the editor grows as you type")
        ed.textView.insertText("", replacementRange: NSRange(location: 25, length: 1))
        c.check(d.editorText == "Quarterly Totals - Page 1", "deleting a character works")

        // Return commits and moves to the next line.
        d.returnKey()
        c.check(session.edits.count == 1 && PDFEditTests.text(session.candidateData, 0).hasPrefix("Quarterly Totals - Page 1"),
                "Return commits: the candidate reads “Quarterly Totals - Page 1”")
        c.check(canvas.editor?.lineID == l1, "Return moves the editor to the next line (Line 1)")
        c.check(ctl.undo.undoActionName == "Edit Text" && item("pdfedit.undo")?.isEnabled == true
                && item("pdfedit.undo")?.toolTip == "Undo Edit Text (⌘Z)", "one named undo step “Edit Text”; Undo is enabled")
        c.check(item("pdfedit.save")?.isEnabled == true, "Save is enabled once something changed")
        let cell = ctl.tableView(ctl.table, viewFor: nil, row: 0) as? PDFEditThumbnailCell
        c.check(cell?.edited == true && cell?.accessibilityLabel() == "Page 1, edited" && session.pagesWithChanges == [0],
                "the sidebar marks page 1 as edited (dot and “Page 1, edited”)")
        c.check(ctl.status.left.stringValue.hasPrefix("1 change on 1 page"), "status: “\(ctl.status.left.stringValue)”")

        // Tab and ⇧Tab move through lines in reading order (committing).
        d.tab()
        c.check(canvas.editor?.lineID == l2, "Tab moves to Line 2")
        d.backTab()
        c.check(canvas.editor?.lineID == l1, "⇧Tab moves back to Line 1")

        // ⌘Z with nothing typed: leaves the editor and undoes the change, then outlines it (Reduce Motion on: no fade).
        PDFEditCanvas.reduceMotionOverride = true
        d.command("z")
        ctl.root.needsLayout = true
        ctl.root.layoutSubtreeIfNeeded()          // the window's next layout pass must not remove the outline
        c.check(session.edits.isEmpty && canvas.editor == nil && canvas.selection == .line(head),
                "⌘Z undoes “Edit Text” and selects the title again")
        c.check(canvas.flashView != nil && canvas.flashView?.alphaValue == 1 && !canvas.flashFades,
                "after undo the line is outlined, at full strength with Reduce Motion on")
        d.pump(0.75)
        c.check(canvas.flashView == nil, "the outline is gone after 0.6 s")
        PDFEditCanvas.reduceMotionOverride = false
        d.command("z", shift: true)
        c.check(session.edits.count == 1 && PDFEditTests.text(session.candidateData, 0).hasPrefix("Quarterly Totals"),
                "⇧⌘Z redoes it")
        c.check(canvas.flashView != nil && canvas.flashFades, "after redo the outline fades (Reduce Motion off)")
        var waited = 0.0
        let fadeStart = Date()
        while canvas.flashView != nil && waited < 1 { d.pump(0.05); waited = Date().timeIntervalSince(fadeStart) }
        c.check(canvas.flashView == nil, "the faded outline is removed within a second (after \(Int(waited * 1000)) ms)")

        // Esc: the first press puts the typing back, the second leaves the line selected.
        d.click(d.point(l3, at: 0.95))
        canvas.editor?.textView.insertText("zzz", replacementRange: NSRange(location: NSNotFound, length: 0))
        d.escape()
        c.check(canvas.editor != nil && d.editorText == session.line(l3)?.text.trimmingCharacters(in: .whitespaces), "Esc once puts back the text from before typing")
        d.escape()
        c.check(canvas.editor == nil && canvas.selection == .line(l3) && session.edits.count == 1,
                "Esc twice leaves the line selected, with nothing changed")

        // Keys on a selected line: Tab moves the selection; ⌫ deletes with a spacer; Return starts editing.
        d.window.makeFirstResponder(canvas)
        d.tab()
        c.check(canvas.selection == .line(l4) && canvas.editor == nil, "Tab (not typing) selects the next line")
        let fives = PDFEditTests.text(original, 0).components(separatedBy: "Line 5:").count
        canvas.select(.line(l5))
        d.key("\u{7f}", 51)
        c.check(session.info(l5)?.isDeleted == true && ctl.undo.undoActionName == "Delete Text"
                && PDFEditTests.text(session.candidateData, 0).components(separatedBy: "Line 5:").count == fives - 1, "⌫ on a selected line deletes it (“Delete Text”)")
        let after = session.line(PDFLineID(page: 0, line: l5.line + 1))!.quad
        let pdfAfter = PDFEditTests.pixelDiff(original, session.candidateData, page: 0,
                                              outside: [PDFEditGeometry.bounds(session.line(l5)!.quad).insetBy(dx: -2, dy: -2),
                                                        PDFEditGeometry.bounds(session.line(head)!.quad).insetBy(dx: -2, dy: -200).offsetBy(dx: 400, dy: 0),
                                                        PDFEditGeometry.bounds(session.line(head)!.quad).insetBy(dx: -2, dy: -2)])
        c.check(pdfAfter == 0 && after.count == 4, "nothing else on the page moved (\(pdfAfter) px changed outside the two lines)")
        d.command("z")
        c.check(session.info(l5)?.isDeleted == false && canvas.selection == .line(l5), "⌘Z brings the deleted line back")
        d.window.makeFirstResponder(canvas)
        canvas.select(.line(l4))
        d.returnKey()
        c.check(canvas.editor?.lineID == l4 && d.editorText?.hasPrefix("Line 4:") == true, "Return on a selected line starts editing it")
        d.escape()

        // Double click selects a word.
        d.click(d.point(l3, beforeCharacter: 13), clicks: 1)
        canvas.mouseDown(at: d.point(l3, beforeCharacter: 13), clickCount: 2)
        if let tv = canvas.editor?.textView {
            let sel = (tv.string as NSString).substring(with: tv.selectedRange())
            c.check(sel == "quick", "double-click selects the word (“\(sel)”)")
        }
        d.escape(); d.escape()

        // IME: marked text stays uncommitted until the input method inserts it.
        d.click(d.point(l3, at: 0.99))
        if let tv = canvas.editor?.textView {
            tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
            tv.setMarkedText(" にほん", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            c.check(tv.hasMarkedText() && session.edits.count == 1, "IME composition shows as marked text and changes nothing yet")
            tv.insertText(" 日本", replacementRange: NSRange(location: NSNotFound, length: 0))
            c.check(!tv.hasMarkedText() && tv.string.hasSuffix("dog. 日本"), "the input method's result replaces the composition")
            d.returnKey()
            c.check(PDFEditTests.text(session.candidateData, 0).contains("lazy dog. 日本"),
                    "Japanese typed through the input method reads back from the candidate")
            d.escape(); d.escape()
        }

        // A refused edit: the error is shown, the typing stays, nothing is added to undo.
        let undoBefore = ctl.undo.undoActionName, editsBefore = session.edits
        d.click(d.point(l4, at: 0.99))
        canvas.editor?.textView.insertText(" 🙂", replacementRange: NSRange(location: NSNotFound, length: 0))
        d.returnKey()
        c.check(canvas.editor?.lineID == l4 && d.editorText?.contains("🙂") == true && session.edits == editsBefore
                && ctl.undo.undoActionName == undoBefore && (ctl.lastError ?? "").contains("Emoji"),
                "an emoji is refused: “\(ctl.lastError ?? "")”, the editor stays open, no undo step (\(canvas.editor?.lineID == l4) \(d.editorText ?? "nil") \(session.edits == editsBefore) \(ctl.undo.undoActionName)/\(undoBefore))")
        d.escape(); d.escape()

        // Overflow: amber state, Fit Width and Keep Position from the callout.
        d.click(d.point(l2, at: 0.99))
        d.typeAtEnd(" It then naps in the afternoon sun for hours.")
        d.returnKey()
        d.escape(); d.escape()
        canvas.select(.line(l2))
        let over = session.info(l2)
        c.check((over?.overflow ?? 0) > 1 && canvas.callout != nil && canvas.callout?.message == over?.overflowMessage,
                "a line past the page edge shows “\(over?.overflowMessage ?? "?")” under it")
        canvas.callout?.fitButton.performClick(nil)
        let fit = session.info(l2)
        c.check(fit?.spacing == .fit && (fit?.fitScale ?? 1) < 1 && ctl.undo.undoActionName == "Change Spacing",
                "Fit Width squeezes it (scale \(String(format: "%.2f", fit?.fitScale ?? 1)), “Change Spacing”)")
        canvas.select(.line(l2))
        if canvas.callout != nil { canvas.callout?.keepButton.performClick(nil) } else { _ = ctl.perform("") { try session.setSpacing(.keep, for: l2) } }
        c.check(session.info(l2)?.spacing == .keep, "Keep Position is one click away")
        d.command("z"); d.command("z")
        c.check(session.info(l2)?.spacing == .flow, "two undos go back to Flow")

        // Zoom keeps the line under the editor in step.
        let z0 = canvas.zoom
        d.command("=")
        c.check(canvas.zoom > z0 && ctl.status.right.stringValue.hasSuffix("\(Int((canvas.zoom * 100).rounded()))%"), "⌘+ zooms in (status shows it)")
        d.command("-"); d.command("0")
        c.check(abs(canvas.zoom - 1) < 0.001, "⌘− and ⌘0 (actual size)")

        // Accessibility: one element per line, value = text, press = edit.
        let elements = (canvas.accessibilityChildren() ?? []).compactMap { $0 as? PDFEditLineElement }
        c.check(elements.count == session.lines(page: 0).count, "one accessibility element per line (\(elements.count))")
        if let e = elements.first(where: { $0.target == .line(head) }) {
            c.check((e.accessibilityValue() as? String) == session.info(head)?.text && e.accessibilityRole() == .textArea
                    && e.accessibilityLabel() == "Line 1, edited", "the title's element: “\(e.accessibilityLabel() ?? "")”, value = current text")
        }
        if let e = elements.first(where: { $0.target == .line(l3) }) {
            c.check(e.accessibilityPerformPress() && canvas.editor?.lineID == l3, "pressing a line's element starts editing it")
            d.escape()
        }

        // Pages: the sidebar and Page Down.
        ctl.table.selectRowIndexes([1], byExtendingSelection: false)
        c.check(canvas.page == 1 && ctl.status.right.stringValue.hasPrefix("Page 2 of 3"), "choosing a thumbnail shows that page")
        d.window.makeFirstResponder(canvas)
        d.key("\u{F72D}", 121)
        c.check(canvas.page == 2 && ctl.table.selectedRow == 2, "Page Down goes to the next page and the sidebar follows")
        canvas.show(page: 0)

        // Text pushed past the page edge can't pass the gate: Save says which line and what to do.
        d.command("s")
        c.check(ctl.savedURL == nil && canvas.selection == .line(l2) && (ctl.lastError ?? "").contains("“Line 2: The quick brown fox…” on page 1 runs past its room"),
                "Save refuses text pushed off the page, selects that line and says what to do: “\(ctl.lastError ?? "")”")
        canvas.callout?.fitButton.performClick(nil)

        // ⌘S: through the gate to "report edited.pdf", reported, window closed; the edit reads back.
        d.command("s")
        let out = dir.appendingPathComponent("report edited.pdf")
        c.check(ctl.savedURL == out && d.reported == [out] && FileManager.default.fileExists(atPath: out.path),
                "⌘S writes “report edited.pdf” and reports it (\(ctl.lastError ?? "no error"))")
        if let saved = try? Data(contentsOf: out) {
            c.check(PDFEditTests.text(saved, 0).hasPrefix("Quarterly Totals - Page 1") && PDFEditTests.text(saved, 0).contains("日本"),
                    "the saved file reads back the edits")
            c.check(saved.prefix(original.count) == original, "the original is an exact prefix of the saved file (incremental update)")
        }
        c.check((try? Data(contentsOf: url)) == original, "the original file is unchanged")
        c.check(d.window.delegate == nil && session.undoManager == nil, "Save closes the window")
    }

    /// The start of the first glyph's baseline in a text view, as the layout manager placed it.
    static func laidOutBaseline(_ tv: NSTextView) -> CGPoint {
        guard let lm = tv.layoutManager, lm.numberOfGlyphs > 0 else { return CGPoint(x: 0, y: 99) }
        let frag = lm.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        let loc = lm.location(forGlyphAt: 0)
        return CGPoint(x: frag.minX + loc.x + tv.textContainerOrigin.x, y: frag.minY + loc.y + tv.textContainerOrigin.y)
    }

    // MARK: - 2. Add Text and the inspector

    static func addTextAndInspector(_ c: Checker, _ fixture: URL, _ dir: URL) throws {
        c.section("Add Text and the inspector")
        let url = dir.appendingPathComponent("add.pdf")
        try FileManager.default.copyItem(at: fixture, to: url)
        let d = try Driver(url)
        let ctl = d.controller, canvas = d.canvas, session = d.session
        guard let l1 = d.id("Line 1:") else { c.check(false, "lines found"); return }

        // Inspector for a selected line, then Revert.
        canvas.select(.line(l1))
        c.check(ctl.inspector.sections == ["Text", "Spacing", "Saving"], "a selected line: inspector shows \(ctl.inspector.sections)")
        c.check(ctl.inspector.revertButton?.isEnabled == false && ctl.inspector.spacingButtons[.flow]?.isEnabled == false,
                "Revert and Spacing wait until the line changes")
        _ = ctl.perform("") { try session.setText("Line 1: The quick red fox.", for: l1) }
        canvas.select(.line(l1))
        c.check(ctl.inspector.revertButton?.isEnabled == true && ctl.inspector.spacingButtons[.flow]?.state == .on, "after a change Revert is enabled")
        ctl.inspector.spacingButtons[.keep]?.performClick(nil)
        c.check(session.info(l1)?.spacing == .keep, "choosing Keep Position in the inspector applies it")
        ctl.inspector.revertButton?.performClick(nil)
        c.check(session.edits.isEmpty && ctl.undo.undoActionName == "Revert Text", "Revert puts the original back (“Revert Text”)")

        // Add Text: the mode control, a click on empty paper, typing, Return.
        ctl.modeControl.selectedSegment = 1
        ctl.modeChanged(ctl.modeControl)
        c.check(canvas.mode == .addText && ctl.inspector.sections == ["Add Text", "Saving"], "Add Text mode (inspector: \(ctl.inspector.sections))")
        ctl.inspector.sizeField.doubleValue = 18
        ctl.inspector.sizeField.sendAction(ctl.inspector.sizeField.action, to: ctl.inspector.sizeField.target)
        c.check(canvas.addStyle.size == 18, "the inspector's size applies to new text")
        let spot = CGPoint(x: canvas.pageFrame.minX + 300 * canvas.zoom, y: canvas.pageFrame.maxY - 30 * canvas.zoom)
        d.click(spot)
        c.check(canvas.editor?.isNew == true && d.window.firstResponder === canvas.editor?.textView, "a click on the page opens a new text box")
        canvas.editor?.textView.insertText("Checked", replacementRange: NSRange(location: NSNotFound, length: 0))
        d.returnKey()
        let added = session.addedTexts
        c.check(added.count == 1 && added.first?.text == "Checked" && added.first?.style.size == 18 && ctl.undo.undoActionName == "Add Text",
                "Return adds “Checked” at 18 pt (“Add Text”)")
        c.check(PDFEditTests.text(session.candidateData, 0).contains("Checked"), "the added text reads back from the candidate")
        guard let a = added.first else { return }
        c.check(canvas.selection == .added(a.id) && ctl.inspector.sections == ["Added Text", "Saving"], "the new text is selected")
        let mid = PDFEditCanvas.bounds(canvas.viewQuad(a.quad))
        let clickY = canvas.pagePoint(CGPoint(x: mid.midX, y: mid.midY)).y
        c.check(abs(clickY - canvas.pagePoint(spot).y) < 4, "the text is centred on the click (\(String(format: "%.1f", abs(clickY - canvas.pagePoint(spot).y))) pt off)")

        // Move it by dragging; then click to edit it.
        let from = CGPoint(x: mid.midX, y: mid.midY)
        d.drag(from, CGPoint(x: from.x + 40, y: from.y + 20))
        let moved = session.addedTexts.first
        c.check(ctl.undo.undoActionName == "Move Text" && abs((moved?.origin.x ?? 0) - a.origin.x - 40 / canvas.zoom) < 0.01
                && abs((moved?.origin.y ?? 0) - a.origin.y + 20 / canvas.zoom) < 0.01, "dragging moves the text (“Move Text”)")
        let mid2 = PDFEditCanvas.bounds(canvas.viewQuad(moved?.quad ?? []))
        d.click(CGPoint(x: mid2.maxX - 1, y: mid2.midY))
        c.check(canvas.editor?.addedID == a.id && d.editorText == "Checked", "a click on added text edits it")
        d.typeAtEnd(" twice")
        d.returnKey()
        c.check(session.addedTexts.first?.text == "Checked twice", "editing added text changes it")
        if let blank = session.previewDocument(hidingAdded: a.id)?.page(at: 0)?.string {
            c.check(!blank.contains("Checked"), "behind its editor, the added text is hidden")
        }
        canvas.select(.added(a.id))
        d.window.makeFirstResponder(canvas)
        d.key("\u{7f}", 51)
        c.check(session.addedTexts.isEmpty && ctl.undo.undoActionName == "Delete Text", "⌫ removes a selected added text")
        d.command("z")
        c.check(session.addedTexts.count == 1 && canvas.selection == .added(a.id), "⌘Z brings it back, selected")
        ctl.setMode(.editText)
        c.check(canvas.mode == .editText && ctl.modeControl.selectedSegment == 0, "back to Edit Text")

        // Sidebar and inspector toggles.
        ctl.toggleSidebar(nil); ctl.toggleInspector(nil)
        ctl.root.layoutSubtreeIfNeeded()
        c.check(ctl.sidebarScroll.isHidden && ctl.inspector.isHidden && ctl.scroll.frame.width == ctl.root.bounds.width,
                "hiding the sidebar and inspector gives the page the full width")
        ctl.toggleSidebar(nil); ctl.toggleInspector(nil)
        ctl.forceClose()
    }

    // MARK: - 3. Remove replaced text, discard prompt

    static func removeReplacedAndDiscard(_ c: Checker, _ fixture: URL, _ dir: URL) throws {
        c.section("saving options and closing")
        let url = dir.appendingPathComponent("clean.pdf")
        try FileManager.default.copyItem(at: fixture, to: url)
        let original = try Data(contentsOf: url)
        let d = try Driver(url)
        guard let head = d.id("Quarterly Report") else { return }
        d.click(d.point(head, at: 0.98))
        d.typeAtEnd(" (draft)")
        c.check(d.controller.windowShouldClose(d.window) == false && d.controller.discardPromptPending,
                "closing with typing asks “Discard your changes?”")
        d.controller.discardPromptPending = false
        d.controller.inspector.removeReplaced.performClick(nil)
        c.check(d.session.removeReplacedText, "the checkbox turns on “Remove replaced text from the file”")
        d.controller.save()
        let out = dir.appendingPathComponent("clean edited.pdf")
        if let saved = try? Data(contentsOf: out) {
            let all = PDFEditTests.allDecoded(saved)
            c.check(PDFEditTests.text(saved, 0).hasPrefix("Quarterly Report - Page 1 (draft)") && saved.prefix(original.count) != original
                    && !all.contains("Quarterly Report - Page 1)"),
                    "with it on, Save commits the typing and rewrites the file without the old line")
        } else {
            c.check(false, "clean edited.pdf was written")
        }

        // A window with no changes closes without asking.
        let d2 = try Driver(url)
        c.check(d2.controller.windowShouldClose(d2.window) == false && !d2.controller.discardPromptPending && d2.window.delegate == nil,
                "a window with no changes closes without asking")
    }

    private static func canvas(_ d: Driver) -> PDFEditCanvas { d.canvas }

    // MARK: - 4. Rotated pages and coloured text

    /// A /Rotate 90 page: text that reads upright on screen, text that runs down the screen, text at 30°, red text.
    static func rotatedPDF() -> Data {
        var g = PDFEditTests.Gen()
        g.add(1, "<< /Type /Catalog /Pages 2 0 R >>")
        g.add(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        g.add(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Rotate 90 /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>")
        g.stream(4, """
        BT /F1 18 Tf 0 1 -1 0 100 72 Tm (Upright on screen) Tj ET
        BT /F1 14 Tf 400 300 Td (Sideways text) Tj ET
        BT /F1 14 Tf 0.866 0.5 -0.5 0.866 300 120 Tm (Tilted text) Tj ET
        BT 0.8 0 0 rg /F1 16 Tf 0 1 -1 0 200 72 Tm (Red words) Tj ET
        """)
        g.add(5, PDFEditTests.helvetica)
        return g.classic()
    }

    static func rotatedPages(_ c: Checker, _ dir: URL) throws {
        c.section("rotated pages")
        let url = dir.appendingPathComponent("rotated.pdf")
        try rotatedPDF().write(to: url)
        PDFEditTests.dump(rotatedPDF(), "rotated.pdf")
        let d = try Driver(url)
        let canvas = d.canvas, session = d.session
        c.check(abs(canvas.uprightSize.width - 792) < 0.01 && abs(canvas.uprightSize.height - 612) < 0.01, "a /Rotate 90 page is shown landscape")
        guard let up = d.id("Upright"), let side = d.id("Sideways"), let tilt = d.id("Tilted"), let red = d.id("Red words") else {
            c.check(false, "rotated lines found: \(session.lines(page: 0).map(\.text))"); return
        }
        c.check(abs(canvas.screenAngle(session.line(up)!.quad)) < 0.5 && abs(canvas.screenAngle(session.line(side)!.quad) - 90) < 0.5,
                "angles on screen: upright 0°, sideways 90°")

        func baselineOffBy(_ id: PDFLineID) -> CGFloat {
            guard let ed = canvas.editor else { return 99 }
            let p = ed.textView.convert(laidOutBaseline(ed.textView), to: canvas)
            let w = canvas.viewPoint(session.line(id)!.origin)
            return hypot(p.x - w.x, p.y - w.y)
        }
        func direction() -> CGFloat {
            guard let ed = canvas.editor else { return 99 }
            let a = ed.textView.convert(CGPoint.zero, to: canvas), b = ed.textView.convert(CGPoint(x: 10, y: 0), to: canvas)
            return atan2(b.y - a.y, b.x - a.x) * 180 / .pi
        }

        d.click(d.point(up))
        c.check(canvas.editor?.lineID == up && canvas.editor?.screenAngle == 0 && baselineOffBy(up) < 0.75 && abs(direction()) < 0.5,
                "upright text on a rotated page: an upright editor on its baseline (off by \(String(format: "%.2f", baselineOffBy(up))) pt)")
        d.typeAtEnd("!")
        d.returnKey()
        c.check(PDFEditTests.text(session.candidateData, 0).contains("Upright on screen!"), "its edit reads back")
        d.escape(); d.escape()

        d.click(d.point(side))
        c.check(canvas.editor?.lineID == side && abs(direction() - 90) < 0.5 && baselineOffBy(side) < 0.75,
                "sideways text: the editor is turned 90° (\(String(format: "%.1f", direction()))°) on the line's baseline (off by \(String(format: "%.2f", baselineOffBy(side))) pt)")
        d.typeAtEnd(" too")
        d.returnKey()
        c.check(PDFEditTests.text(session.candidateData, 0).contains("Sideways text too"), "the turned editor's text reads back")
        d.escape(); d.escape()

        d.click(d.point(tilt))
        c.check(canvas.editor == nil && canvas.anglePopover != nil && canvas.selection == .line(tilt), "text at 30° is edited in a popover")
        if let vc = canvas.anglePopover?.contentViewController as? PDFEditAngledEditor {
            _ = vc.view
            c.check(vc.field.stringValue == "Tilted text", "the popover holds the line's text")
            vc.field.stringValue = "Tilted words"
            // Its Change button, pressed.
            var buttons: [NSButton] = []
            func walk(_ v: NSView) { if let b = v as? NSButton { buttons.append(b) }; v.subviews.forEach(walk) }
            walk(vc.view)
            if let change = buttons.first(where: { $0.title == "Change" }) { change.sendAction(change.action, to: change.target) }
            c.check(PDFEditTests.text(session.candidateData, 0).contains("Tilted words"), "Change applies it")
        }

        d.click(d.point(red))
        if let tc = canvas.editor?.textView.textColor?.usingColorSpace(.sRGB) {
            c.check(abs(tc.redComponent - 0.8) < 0.02 && tc.greenComponent < 0.02 && tc.blueComponent < 0.02,
                    "red text is edited in red (\(String(format: "%.2f %.2f %.2f", tc.redComponent, tc.greenComponent, tc.blueComponent)))")
            c.check(abs((canvas.editor?.textView.font?.pointSize ?? 0) - 16 * canvas.zoom) < 0.01, "at its own size (16 pt)")
        } else {
            c.check(false, "red line editor opens")
        }
        d.escape(); d.escape()
        d.controller.forceClose()
    }

    // MARK: - 5. Banners, read-only text, snapshot

    /// Two pages that both draw one form holding "Shared footer".
    static func sharedFormPDF() -> Data {
        var g = PDFEditTests.Gen()
        g.add(1, "<< /Type /Catalog /Pages 2 0 R >>")
        g.add(2, "<< /Type /Pages /Kids [3 0 R 6 0 R] /Count 2 /MediaBox [0 0 612 792] >>")
        g.add(3, "<< /Type /Page /Parent 2 0 R /Resources << /Font << /F1 5 0 R >> /XObject << /Fm1 7 0 R >> >> /Contents 4 0 R >>")
        g.stream(4, "BT /F1 18 Tf 72 700 Td (Page one) Tj ET q /Fm1 Do Q\n")
        g.add(6, "<< /Type /Page /Parent 2 0 R /Resources << /Font << /F1 5 0 R >> /XObject << /Fm1 7 0 R >> >> /Contents 8 0 R >>")
        g.stream(8, "BT /F1 18 Tf 72 700 Td (Page two) Tj ET q /Fm1 Do Q\n")
        g.stream(7, "BT /F1 10 Tf 72 40 Td (Shared footer) Tj ET\n", dict: "/Type /XObject /Subtype /Form /BBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >>")
        g.add(5, PDFEditTests.helvetica)
        return g.classic()
    }

    static func bannersAndSnapshot(_ c: Checker, _ fixture: URL, _ dir: URL) throws {
        c.section("banners and snapshot")
        let signed = dir.appendingPathComponent("signed.pdf")
        try PDFEditTests.signedPDF(certified: false).write(to: signed)
        let d = try Driver(signed)
        c.check(d.controller.banners.messages.first?.hasPrefix("This PDF is signed.") == true, "a signed PDF shows the signed banner")
        c.check(!d.controller.inspector.removeReplaced.isEnabled, "“Remove replaced text” is off for signed files")
        d.controller.forceClose()

        let certified = dir.appendingPathComponent("certified.pdf")
        try PDFEditTests.signedPDF(certified: true).write(to: certified)
        let e = try Driver(certified)
        if let id = e.id("Signed") {
            e.click(e.point(id))
            c.check(e.canvas.editor == nil && e.canvas.selection == .line(id)
                    && e.controller.banners.messages.contains("The signature on this PDF doesn’t allow changes."),
                    "certified: a click selects the line and the banner says why it can't change")
            c.check(e.canvas.view(e.canvas, stringForToolTip: 0, point: e.point(id), userData: nil) == "The signature on this PDF doesn’t allow changes.",
                    "the read-only line's tooltip gives the reason")
            c.check(e.controller.modeControl.isEnabled(forSegment: 1) == false, "Add Text is unavailable")
        }
        e.controller.forceClose()

        // Text in a form drawn on two pages: the banner, All Pages, and the edit landing on both pages.
        let shared = dir.appendingPathComponent("shared.pdf")
        try sharedFormPDF().write(to: shared)
        PDFEditTests.dump(sharedFormPDF(), "shared.pdf")
        PDFEditTests.dump(PDFEditTests.signedPDF(certified: false), "signed.pdf")
        let sh = try Driver(shared)
        if let id = sh.id("Shared footer") {
            sh.canvas.select(.line(id))
            let row = sh.controller.banners.rows.first { $0.message == "This text appears on 2 pages." }
            let seg = row?.accessory as? NSSegmentedControl
            c.check(seg?.selectedSegment == 1, "shared text: “This text appears on 2 pages.” with All Pages | Only This Page (this page chosen)")
            seg?.selectedSegment = 0
            if let seg { seg.sendAction(seg.action, to: seg.target) }
            sh.click(sh.point(id, at: 0.99))
            sh.typeAtEnd(" (both)")
            sh.returnKey()
            let t = sh.session.candidateData
            c.check(PDFEditTests.text(t, 0).contains("Shared footer (both)") && PDFEditTests.text(t, 1).contains("Shared footer (both)")
                    && sh.session.pagesWithChanges.count >= 1, "with All Pages chosen, the edit changes both pages")
            sh.command("z")
            sh.canvas.select(.line(id))
            let seg2 = sh.controller.banners.rows.first { $0.message == "This text appears on 2 pages." }?.accessory as? NSSegmentedControl
            c.check(seg2?.selectedSegment == 0, "after undo the banner still shows the All Pages choice")
            seg2?.selectedSegment = 1
            if let seg2 { seg2.sendAction(seg2.action, to: seg2.target) }
            sh.click(sh.point(id, at: 0.99))
            sh.typeAtEnd(" (one)")
            sh.returnKey()
            let u = sh.session.candidateData
            c.check(PDFEditTests.text(u, 0).contains("Shared footer (one)") && !PDFEditTests.text(u, 1).contains("(one)"),
                    "with Only This Page, only this page changes")
        } else {
            c.check(false, "shared footer line found: \(sh.session.lines(page: 0).map(\.text))")
        }
        sh.controller.forceClose()

        let ocr = dir.appendingPathComponent("ocr.pdf")
        try PDFEditTests.ocrPDF().write(to: ocr)
        let o = try Driver(ocr)
        c.check(o.controller.banners.messages.contains(PDFEditBanner.ocrOnly.message), "hidden OCR text: the OCR banner")
        o.controller.forceClose()

        // The snapshot renders the whole window (title bar, toolbar, sidebar, page, inspector).
        for dark in [false, true] {
            guard let v = PDFEditWindowController.snapshotView(url: fixture, options: ["select": "Quarterly Report", "editing": "true",
                                                                                      "dark": dark ? "true" : "false"]) as? NSImageView,
                  let img = v.image, let rep = img.representations.first as? NSBitmapImageRep else {
                c.check(false, "snapshot renders"); continue
            }
            let status = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh - 8)?.usingColorSpace(.sRGB)
            let lum = status.map { 0.2126 * $0.redComponent + 0.7152 * $0.greenComponent + 0.0722 * $0.blueComponent } ?? -1
            c.check(rep.pixelsWide >= 1180 && (dark ? lum < 0.35 : lum > 0.8),
                    "snapshot \(dark ? "dark" : "light"): \(rep.pixelsWide)×\(rep.pixelsHigh) px, status bar luminance \(String(format: "%.2f", lum))")
        }
    }

    // MARK: - 6. Review regressions

    /// Where a line's text has ink, in view y: the glyphs' own bounding boxes in the font the editor uses for the line
    /// (0° lines only).
    static func ink(_ canvas: PDFEditCanvas, _ session: PDFEditSession, _ id: PDFLineID) -> (top: CGFloat, bottom: CGFloat, baseline: CGFloat)? {
        guard let line = session.line(id) else { return nil }
        let font = session.editorFont(id).font as CTFont
        let text = line.text.trimmingCharacters(in: .whitespaces) as NSString
        var chars = [UniChar](repeating: 0, count: text.length)
        text.getCharacters(&chars)
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        _ = CTFontGetGlyphsForCharacters(font, chars, &glyphs, chars.count)
        let r = CTFontGetBoundingRectsForGlyphs(font, .horizontal, glyphs, nil, glyphs.count)
        let base = canvas.viewPoint(line.origin).y
        return (base - r.maxY * canvas.zoom, base - r.minY * canvas.zoom, base)
    }

    /// The topmost and bottommost view y where the canvas, as drawn, shows coloured (outline) pixels in `rect`.
    static func colouredRows(_ canvas: PDFEditCanvas, in rect: CGRect) -> (top: CGFloat, bottom: CGFloat)? {
        guard let rep = canvas.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        canvas.cacheDisplay(in: rect, to: rep)
        let sy = CGFloat(rep.pixelsHigh) / rect.height
        var top: Int?, bottom: Int?
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let p = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let hi = max(p.redComponent, p.greenComponent, p.blueComponent), lo = min(p.redComponent, p.greenComponent, p.blueComponent)
                if hi - lo > 0.12 { if top == nil { top = y }; bottom = y; break }
            }
        }
        guard let top, let bottom else { return nil }
        return (rect.minY + CGFloat(top) / sy, rect.minY + CGFloat(bottom + 1) / sy)
    }

    /// A label and a value on one baseline, as in a form or a table row: two lines with room between them.
    static func cellsPDF() -> Data {
        var g = PDFEditTests.Gen()
        g.add(1, "<< /Type /Catalog /Pages 2 0 R >>")
        g.add(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        g.add(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>")
        g.stream(4, """
        BT /F1 12 Tf 72 700 Td (Name:) Tj ET
        BT /F1 12 Tf 200 700 Td (Ada Lovelace) Tj ET
        BT /F1 12 Tf 72 680 Td (Year:) Tj ET
        BT /F1 12 Tf 200 680 Td (1843) Tj ET
        """)
        g.add(5, PDFEditTests.helvetica)
        return g.classic()
    }

    /// A line with a footnote mark drawn over it on its own (a raised "1" inside the line's span), lines 30 pt apart.
    static func superscriptPDF() -> Data {
        var g = PDFEditTests.Gen()
        g.add(1, "<< /Type /Catalog /Pages 2 0 R >>")
        g.add(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        g.add(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>")
        g.stream(4, """
        BT /F1 12 Tf 72 700 Td (Revenue grew by twelve    percent this year) Tj ET
        BT /F1 7 Tf 175 705 Td (1) Tj ET
        BT /F1 12 Tf 72 670 Td (A plain line well below the first) Tj ET
        """)
        g.add(5, PDFEditTests.helvetica)
        return g.classic()
    }

    static func reviewRegressions(_ c: Checker, _ fixture: URL, _ dir: URL) throws {
        c.section("review: the editor box sits on its own line")
        let url = dir.appendingPathComponent("review.pdf")
        try FileManager.default.copyItem(at: fixture, to: url)
        let d = try Driver(url)
        let ctl = d.controller, canvas = d.canvas, session = d.session
        guard let head = d.id("Quarterly Report"), let l1 = d.id("Line 1:"), let l2 = d.id("Line 2:"), let l3 = d.id("Line 3:") else {
            c.check(false, "report.pdf lines found"); return
        }
        let accent = PDFEditPaint.accent
        let chromatic = max(accent.redComponent, accent.greenComponent, accent.blueComponent)
            - min(accent.redComponent, accent.greenComponent, accent.blueComponent) > 0.2
        for zoom: CGFloat in [1, 1.12, 2] {
            canvas.setZoom(zoom)
            for (id, above, below) in [(head, nil, l1), (l2, l1, l3)] as [(PDFLineID, PDFLineID?, PDFLineID)] {
                canvas.scrollToVisible(canvas.viewBounds(.line(id), grow: 60))
                d.click(d.point(id, at: 0.5))
                guard let ed = canvas.editor, ed.lineID == id, let own = ink(canvas, session, id), let next = ink(canvas, session, below) else {
                    c.check(false, "the editor opens on \(id)"); continue
                }
                let name = PDFEditWindowController.excerpt(session.line(id)?.text ?? "", length: 16)
                let drawn: (top: CGFloat, bottom: CGFloat)?
                if chromatic {
                    let b = canvas.viewBounds(.line(id), grow: 4)
                    let region = CGRect(x: b.minX, y: own.baseline - 30 * zoom, width: b.width, height: 60 * zoom)
                    drawn = colouredRows(canvas, in: region)
                } else {
                    // A grey accent can't be told from the text by colour: measure the outline's geometry instead.
                    let q = PDFEditCanvas.bounds(canvas.editorQuad(ed, grow: 2))
                    drawn = (q.minY - 1.75, q.maxY + 1.75)
                }
                guard let box = drawn else { c.check(false, "the editor outline is drawn at \(Int(zoom * 100))%"); continue }
                c.check(box.bottom <= next.top,
                        "\(Int(zoom * 100))%: the outline of “\(name)” stays above the next line's ink (\(String(format: "%.2f", next.top - box.bottom)) pt clear)")
                if let above, let prev = ink(canvas, session, above) {
                    c.check(box.top >= prev.bottom,
                            "\(Int(zoom * 100))%: …and below the previous line's ink (\(String(format: "%.2f", box.top - prev.bottom)) pt clear)")
                }
                // Lines this tight leave under half a point between one line's letters and the next: the outline
                // keeps off the neighbours and still spans the line, from ¾ of its cap height to below its baseline.
                let cap = (session.editorFont(id).font.capHeight) * zoom
                c.check(box.top <= own.baseline - 0.75 * cap && box.bottom >= own.baseline + 0.5,
                        "\(Int(zoom * 100))%: the outline still spans its own line (top \(String(format: "%.1f", own.baseline - box.top)) pt above the baseline, cap height \(String(format: "%.1f", cap)); bottom \(String(format: "%.1f", box.bottom - own.baseline)) pt below it)")
                d.escape(); d.escape()
            }
        }
        canvas.setZoom(1)

        c.section("verifier: a footnote mark over a line isn't a neighbouring line")
        // A superscript drawn on its own over a widely spaced line: the line's outline keeps its full height (it
        // used to be clamped to ¾ of the cap height, cutting through the line's own capitals).
        let supURL = dir.appendingPathComponent("superscript.pdf")
        try superscriptPDF().write(to: supURL)
        let sup = try Driver(supURL)
        if let main = sup.id("Revenue grew"), sup.id("1").map({ $0 != main }) == true, let mainLine = sup.session.line(main) {
            let base = sup.canvas.viewPoint(mainLine.origin).y
            let cap = sup.session.editorFont(main).font.capHeight * sup.canvas.zoom
            let drawn = PDFEditCanvas.bounds(sup.canvas.outlineQuad(.line(main), grow: 2, stroke: 1.5))
            let plain = sup.canvas.viewBounds(.line(main), grow: 2)
            c.check(base - drawn.minY >= cap && abs(drawn.minY - plain.minY) < 0.01,
                    "the outline of a line with a footnote mark reaches above its capitals (top \(String(format: "%.2f", base - drawn.minY)) pt above the baseline, cap height \(String(format: "%.2f", cap)), unclamped \(String(format: "%.2f", base - plain.minY)))")
        } else {
            c.check(false, "superscript.pdf: the line and its mark are separate lines (\(sup.session.lines(page: 0).map(\.text)))")
        }
        sup.controller.forceClose()

        c.section("review: typing shows in the status bar and the toolbar")
        let item = { (id: String) in d.window.toolbar?.items.first { $0.itemIdentifier.rawValue == id } }
        d.click(d.point(head, at: 0.98))
        c.check(canvas.editor?.lineID == head && ctl.status.left.stringValue == "No changes" && item("pdfedit.save")?.isEnabled == false,
                "an open editor with nothing typed: “\(ctl.status.left.stringValue)”, Save off (\(item("pdfedit.save")?.isEnabled == true))")
        d.key("X", 7)
        let typingStatus = ctl.status.left.stringValue
        c.check(typingStatus.hasPrefix("Editing “Quarterly Report - Page 1”") && !typingStatus.contains("No changes"),
                "while typing, the status says an edit is in progress: “\(typingStatus)”")
        c.check(item("pdfedit.undo")?.isEnabled == true && item("pdfedit.save")?.isEnabled == true,
                "while typing, Undo and Save are enabled (undo \(item("pdfedit.undo")?.isEnabled == true), save \(item("pdfedit.save")?.isEnabled == true))")
        func labels(_ v: NSView) -> [String] { ((v as? NSTextField).map { [$0.stringValue] } ?? []) + v.subviews.flatMap(labels) }
        c.check(labels(ctl.inspector).contains("Press Return to apply your typing, then choose how it fits."),
                "while typing, the inspector says how to get to the spacing choices")
        d.escape()
        c.check(canvas.editor != nil && ctl.status.left.stringValue == "No changes" && item("pdfedit.save")?.isEnabled == false
                && item("pdfedit.undo")?.isEnabled == false && labels(ctl.inspector).contains("Change the line to choose how it fits."),
                "Esc puts the text back: “\(ctl.status.left.stringValue)”, Save and Undo off again, the inspector as before")
        d.escape()
        d.click(d.point(l3, at: 0.98))
        d.typeAtEnd(" more")
        d.returnKey()
        d.typeAtEnd("!")
        c.check(ctl.status.left.stringValue.hasPrefix("Editing “Line 4: The quick brown fox…” · Return applies it · 1 change on 1 page"),
                "typing after a committed change keeps both in the status: “\(ctl.status.left.stringValue)”")
        d.escape(); d.escape()

        c.section("review: save errors say what went wrong")
        // A label that runs into the cell beside it (on the page) passes the final check; a folder that can't be
        // written to must not be blamed on that label.
        let ro = dir.appendingPathComponent("read-only")
        try FileManager.default.createDirectory(at: ro, withIntermediateDirectories: true)
        let roURL = ro.appendingPathComponent("cells.pdf")
        try cellsPDF().write(to: roURL)
        let r = try Driver(roURL)
        if let name = r.id("Name:") {
            _ = r.controller.perform("") { try r.session.setText("Name of the person who wrote it:", for: name) }
            let info = r.session.info(name)
            let crop = r.session.pages[0].cropBox
            let onPage = !(info?.quad ?? []).isEmpty && (info?.quad ?? []).allSatisfy { crop.insetBy(dx: -0.5, dy: -0.5).contains($0) }
            c.check(info?.overflowMessage != nil && onPage, "the longer label runs into the next cell (“\(info?.overflowMessage ?? "none")”) and stays on the page")
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: ro.path)
            r.controller.save()
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ro.path)
            let err = r.controller.lastError ?? ""
            c.check(r.controller.savedURL == nil && err.contains("Couldn’t save") && !err.contains("runs past its room"),
                    "a folder that can't be written to is reported as such, without blaming the label: “\(err)”")
        } else {
            c.check(false, "cells.pdf lines: \(r.session.lines(page: 0).map(\.text))")
        }
        r.controller.forceClose()

        c.section("review: keyboard and VoiceOver")
        d.window.makeFirstResponder(canvas)
        canvas.select(.line(l1))
        d.key("\t", 48, .control)
        let fr = d.window.firstResponder as? NSView
        c.check(fr != nil && fr !== canvas && fr?.isDescendant(of: canvas) == false,
                "⌃Tab moves the keyboard off the page (now \(fr.map { String(describing: type(of: $0)) } ?? "nil"))")
        // The inspector's buttons take the keyboard when Full Keyboard Access is on (a system setting), so check that
        // they're in the window's key view loop, and that Tab reaches them when the setting is on.
        d.window.recalculateKeyViewLoop()
        var chain: [NSView] = []
        var v: NSView? = canvas.nextKeyView
        while let k = v, k !== canvas, chain.count < 200 { chain.append(k); v = k.nextKeyView }
        c.check(chain.contains { $0 === ctl.inspector.removeReplaced } && chain.contains { $0.isDescendant(of: ctl.sidebarScroll) },
                "the key view loop runs from the page through the sidebar and the inspector (\(chain.count) views)")
        if NSApp.isFullKeyboardAccessEnabled {
            d.window.makeFirstResponder(canvas)
            var reached = false
            for _ in 0..<12 where !reached {
                d.key("\t", 48, .control)
                reached = (d.window.firstResponder as? NSView)?.isDescendant(of: ctl.inspector) == true
            }
            c.check(reached, "with Full Keyboard Access on, ⌃Tab reaches the inspector's controls")
        } else {
            c.lines.append("note Full Keyboard Access is off on this Mac: buttons only take the keyboard when it's on")
        }
        d.window.makeFirstResponder(canvas)
        d.key("\t", 48, [.control, .shift])
        let back = d.window.firstResponder as? NSView
        c.check(back != nil && back !== canvas, "⌃⇧Tab moves off the page the other way (now \(back.map { String(describing: type(of: $0)) } ?? "nil"))")
        // Typing a size and then using the font menu, the stepper or another mode rebuilds the inspector while the
        // Size field is still being typed in: no crash, what was typed applies, and the keyboard stays in the field.
        ctl.setMode(.addText)
        let field = ctl.inspector.sizeField
        func typeSize(_ s: String) {
            d.window.makeFirstResponder(field)
            (d.window.firstResponder as? NSTextView)?.selectAll(nil)
            (d.window.firstResponder as? NSTextView)?.insertText(s, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        func inField() -> Bool {
            let f = d.window.firstResponder
            return f === field || ((f as? NSText)?.delegate as AnyObject?) === field
        }
        typeSize("20")
        ctl.inspector.fontPopUp.selectItem(withTitle: "Georgia")
        ctl.inspector.fontPopUp.sendAction(ctl.inspector.fontPopUp.action, to: ctl.inspector.fontPopUp.target)
        c.check(canvas.addStyle.size == 20 && canvas.addStyle.fontName == "Georgia" && inField(),
                "typing 20 in Size, then choosing Georgia: both apply (\(canvas.addStyle.fontName) \(canvas.addStyle.size)), keyboard still in Size (\(inField()))")
        typeSize("24")
        ctl.inspector.sizeStepper.performClick(nil)
        c.check(inField() && abs(canvas.addStyle.size - 24) == 1,
                "typing 24 in Size, then clicking the stepper steps from 24 (now \(canvas.addStyle.size)), keyboard still in Size (\(inField()))")
        typeSize("18")
        d.key("\r", 36)
        ctl.setMode(.editText)
        c.check(canvas.addStyle.size == 18 && canvas.mode == .editText,
                "typing 18 and Return, then switching to Edit Text: applied (\(canvas.addStyle.size)), no crash")
        // Without Return: what rebuilt the inspector mustn't throw the typed size away (it used to snap back).
        ctl.setMode(.addText)
        typeSize("19")
        ctl.setMode(.editText)
        ctl.setMode(.addText)
        c.check(canvas.addStyle.size == 19 && field.doubleValue == 19,
                "verifier: typing 19 (no Return), then switching modes: the size applies (\(canvas.addStyle.size), field \(field.stringValue))")
        typeSize("21")
        ctl.inspector.removeReplaced.performClick(nil)
        c.check(canvas.addStyle.size == 21 && field.doubleValue == 21 && inField(),
                "verifier: typing 21, then clicking “Remove replaced text”: the size applies (\(canvas.addStyle.size)), keyboard still in Size (\(inField()))")
        ctl.inspector.removeReplaced.performClick(nil)
        typeSize("23")
        let zoomBefore = canvas.zoom
        d.key("=", 24, .command)
        c.check(canvas.addStyle.size == 23 && canvas.zoom > zoomBefore,
                "verifier: typing 23, then ⌘+: the size applies (\(canvas.addStyle.size)) and the page zooms (\(Int(canvas.zoom * 100))%)")
        canvas.setZoom(zoomBefore)
        ctl.setMode(.editText)
        if let e = (canvas.accessibilityChildren() ?? []).compactMap({ $0 as? PDFEditLineElement }).first(where: { $0.target == .line(l2) }) {
            let f = e.accessibilityFrame()
            let want = d.window.convertToScreen(canvas.convert(canvas.viewBounds(.line(l2)), to: nil))
            c.check(abs(f.midY - want.midY) < 1 && abs(f.minX - want.minX) < 1 && abs(f.height - want.height) < 1,
                    "VoiceOver's frame for Line 2 is where Line 2 is on screen (off by \(String(format: "%.1f", abs(f.midY - want.midY))) pt: \(NSStringFromRect(f)) vs \(NSStringFromRect(want)))")
        }
        ctl.forceClose()
    }
}
#endif
