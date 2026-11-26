#if DEBUG
import AppKit
import PDFKit

/// The window's Highlight mode, pictures and the line Style controls, driven as a person would (part of
/// `--selftest pdf-edit-ui`).
extension PDFEditUITests {
    static func markupTools(_ c: Checker, _ url: URL, _ dir: URL) throws {
        c.section("highlight, pictures and style")
        // A copy: saving writes "<name> edited.pdf" next to the file, which must not be the shared fixture.
        let copy = dir.appendingPathComponent("markup-report.pdf")
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: url, to: copy)
        let d = try Driver(copy)
        let ctl = d.controller, canvas = d.canvas, session = d.session
        guard let l1 = d.id("Line 1:"), let l2 = d.id("Line 2:") else { c.check(false, "lines found"); return }

        // Highlight: drag from the middle of line 1 to the middle of line 2.
        ctl.setMode(.highlight)
        c.check(ctl.modeControl.selectedSegment == 2 && ctl.inspector.sections.first == "Highlight", "Highlight mode: segment and inspector")
        canvas.mouseDown(at: d.point(l1, at: 0.5))
        canvas.mouseDragged(to: d.point(l2, at: 0.3))
        canvas.mouseUp(at: d.point(l2, at: 0.3))
        guard let hl = session.marks.first, case .highlight(let rects, _, _, _) = hl.kind else { c.check(false, "highlight: made by dragging"); return }
        c.check(rects.count == 2, "highlight: two lines dragged across give two pieces (\(rects.count))")
        let b1 = session.line(l1)!.bounds
        c.check(abs(rects.map(\.maxX).max()! - b1.maxX) < 1 && rects.map(\.minX).max()! > b1.minX + 20, "highlight: from the press to the end of the line")
        c.check(canvas.selectedMark == hl.id && ctl.inspector.sections.first == "Highlight", "highlight: selected after the drag")
        // Its colour, from the inspector.
        ctl.inspector.highlightSwatches?.selectedSegment = 1
        if let sw = ctl.inspector.highlightSwatches { sw.sendAction(sw.action, to: sw.target) }
        if case .highlight(_, _, let g, _)? = session.marks.first?.kind { c.check(abs(g - 0.9) < 0.01, "highlight: colour changed to green") }
        else { c.check(false, "highlight: colour changed") }
        // Delete removes it; undo brings it back.
        canvas.deleteSelection()
        c.check(session.marks.isEmpty && canvas.selectedMark == nil, "highlight: Delete removes it")
        ctl.undo.undo()
        c.check(session.marks.count == 1, "highlight: undo brings it back")

        // A picture: placed, moved by dragging, resized by its corner, removed.
        ctl.setMode(.editText)
        let png = PDFEditTests.stampPNG()
        guard let pic = canvas.placePicture(png: png, pixelSize: CGSize(width: 60, height: 30), width: 120),
              case .image(_, let r0)? = session.marks.first(where: { $0.id == pic })?.kind else { c.check(false, "picture: placed"); return }
        c.check(abs(r0.width - 120) < 0.5 && abs(r0.height - 60) < 0.5 && canvas.selectedMark == pic, "picture: placed 120 × 60 pt and selected")
        let v0 = canvas.viewRect(r0)
        canvas.mouseDown(at: CGPoint(x: v0.midX, y: v0.midY))
        canvas.mouseDragged(to: CGPoint(x: v0.midX + 40, y: v0.midY))
        canvas.mouseUp(at: CGPoint(x: v0.midX + 40, y: v0.midY))
        guard case .image(_, let r1)? = session.marks.first(where: { $0.id == pic })?.kind else { c.check(false, "picture: moved"); return }
        c.check(abs(r1.minX - r0.minX - 40) < 0.5 && abs(r1.minY - r0.minY) < 0.5, "picture: dragged 40 pt right")
        let h = canvas.resizeHandle(r1)
        canvas.mouseDown(at: CGPoint(x: h.midX, y: h.midY))
        canvas.mouseDragged(to: CGPoint(x: h.midX + 60, y: h.midY))
        canvas.mouseUp(at: CGPoint(x: h.midX + 60, y: h.midY))
        guard case .image(_, let r2)? = session.marks.first(where: { $0.id == pic })?.kind else { c.check(false, "picture: resized"); return }
        c.check(abs(r2.width - 180) < 1 && abs(r2.height - 90) < 1, "picture: corner drag keeps its proportions (\(r2.size))")
        c.check(ctl.inspector.sections.first == "Picture", "picture: inspector")

        // A drawn signature becomes a transparent picture, cropped to the ink.
        let pad = PDFSignaturePadView(frame: CGRect(x: 0, y: 0, width: 520, height: 200))
        pad.add(stroke: (0..<50).map { CGPoint(x: 60 + CGFloat($0) * 6, y: 100 + 20 * sin(CGFloat($0) / 5)) })
        if let sig = pad.renderPNG(), let rep = NSBitmapImageRep(data: sig.png) {
            let corner = rep.colorAt(x: 0, y: 0)?.alphaComponent ?? 1
            c.check(rep.hasAlpha && corner < 0.01 && abs(sig.size.width / sig.size.height - (294 + 8) / (40 + 8 + 2.6)) < 1.2,
                    "signature: a transparent picture cropped to the ink (\(sig.size))")
            c.check(canvas.placePicture(png: sig.png, pixelSize: sig.size, width: 160) != nil, "signature: placed on the page")
        } else { c.check(false, "signature: rendered") }

        // Style a line: Bold through the inspector.
        canvas.select(.line(l2))
        c.check(canvas.selectedMark == nil && ctl.inspector.sections.contains("Style"), "a line selected: Style section")
        if let t = ctl.inspector.lineTraits {
            t.setSelected(true, forSegment: 0)
            t.sendAction(t.action, to: t.target)
        }
        let st = session.style(of: l2)
        c.check(st.map { $0.syntheticBold || (NSFont(name: $0.fontName, size: 12).map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false) } == true,
                "style: B makes the line bold (\(st?.fontName ?? "-"))")
        if let well = ctl.inspector.lineColor {
            well.color = .systemRed
            well.sendAction(well.action, to: well.target)
        }
        c.check((session.style(of: l2)?.red ?? 0) > 0.8, "style: colour well changes its colour")
        let out = try session.save()
        let txt = PDFEditVerify.normalized(PDFDocument(url: out)?.page(at: 0)?.string ?? "")
        c.check(txt.contains(PDFEditVerify.normalized(session.line(l2)!.text)), "markup: saved through the gate, the styled line reads back")
    }
}
#endif
