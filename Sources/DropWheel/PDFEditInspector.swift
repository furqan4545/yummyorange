import AppKit

/// The Edit PDF inspector (trailing, 264 pt): the selected line (original text with Revert, where its font comes
/// from, size, colour, notes), its spacing (Flow, Keep Position, Fit Width), the Add Text style (font, size, colour)
/// and the file option "Remove replaced text from the file".
final class PDFEditInspector: NSView, NSTextFieldDelegate {
    weak var controller: PDFEditWindowController?
    static let padding: CGFloat = 16
    private let scroll = NSScrollView()
    private let content = PDFEditFlippedView()
    private let stack = NSStackView()

    // Controls that keep their state between reloads (and that the self-test drives).
    let removeReplaced = NSButton(checkboxWithTitle: "Remove replaced text from the file", target: nil, action: nil)
    let fontPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    let sizeField = NSTextField()
    let sizeStepper = NSStepper()
    let colorWell: NSColorWell
    /// Bold and Italic for added text.
    let addTraits = NSSegmentedControl(labels: ["B", "I"], trackingMode: .selectAny, target: nil, action: nil)
    /// The selected line's style controls (made again on every reload).
    private(set) var lineFont: NSPopUpButton?
    private(set) var lineTraits: NSSegmentedControl?
    private(set) var lineSize: NSTextField?
    private(set) var lineColor: NSColorWell?
    private(set) var highlightSwatches: NSSegmentedControl?
    private(set) var revertButton: NSButton?
    private(set) var spacingButtons: [PDFSpacing: NSButton] = [:]
    /// Section titles shown now (the self-test reads them).
    private(set) var sections: [String] = []
    private var reloading = false
    private var reloadAgain = false

    static let fonts = ["Helvetica", "Arial", "Times New Roman", "Georgia", "Courier New", "Menlo"]
    private static let remembered = "PDFEditAddText"

    var removeReplacedText: Bool { removeReplaced.state == .on }
    private var contentWidth: CGFloat { PDFEditRootView.inspectorWidth - 1 - 2 * Self.padding }

    override init(frame: NSRect) {
        colorWell = NSColorWell()
        super.init(frame: frame)
        scroll.documentView = content
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        addSubview(scroll)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: Self.padding, left: Self.padding, bottom: Self.padding, right: Self.padding)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
        ])

        removeReplaced.font = .systemFont(ofSize: 12)
        removeReplaced.target = self
        removeReplaced.action = #selector(removeReplacedChanged(_:))
        removeReplaced.setAccessibilityLabel("Remove replaced text from the file")

        fontPopUp.addItems(withTitles: Self.fonts)
        for item in fontPopUp.itemArray {
            if let f = NSFont(name: item.title, size: 13) { item.attributedTitle = NSAttributedString(string: item.title, attributes: [.font: f]) }
        }
        fontPopUp.controlSize = .regular
        fontPopUp.target = self
        fontPopUp.action = #selector(styleChanged(_:))
        fontPopUp.setAccessibilityLabel("Font for added text")

        let number = NumberFormatter()
        number.minimum = 1
        number.maximum = 400
        number.maximumFractionDigits = 1
        sizeField.formatter = number
        sizeField.alignment = .right
        sizeField.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        sizeField.target = self
        sizeField.action = #selector(styleChanged(_:))
        (sizeField.cell as? NSTextFieldCell)?.allowsUndo = false
        (sizeField.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = true
        sizeField.setAccessibilityLabel("Size of added text in points")
        sizeField.delegate = self
        sizeField.widthAnchor.constraint(equalToConstant: 52).isActive = true
        sizeStepper.minValue = 1
        sizeStepper.maxValue = 400
        sizeStepper.increment = 1
        sizeStepper.valueWraps = false
        sizeStepper.target = self
        sizeStepper.action = #selector(stepped(_:))
        sizeStepper.setAccessibilityLabel("Size")

        Self.configureTraits(addTraits, label: "added text")
        addTraits.target = self
        addTraits.action = #selector(styleChanged(_:))

        colorWell.isContinuous = false
        colorWell.target = self
        colorWell.action = #selector(styleChanged(_:))
        colorWell.setAccessibilityLabel("Color of added text")
        colorWell.widthAnchor.constraint(equalToConstant: 52).isActive = true
        colorWell.heightAnchor.constraint(equalToConstant: 24).isActive = true

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Inspector")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            ImageEditors.Style.chrome.setFill()
            dirtyRect.fill()
        }
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        let size = stack.fittingSize
        content.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(size.height, scroll.contentSize.height))
    }

    /// The Add Text style remembered from last time.
    func loadRememberedStyle() -> PDFTextStyle {
        let last = ImageExtras.remembered(Self.remembered)
        let name = last["font"].flatMap { NSFont(name: $0, size: 12) != nil ? $0 : nil } ?? "Helvetica"
        let size = ImageExtras.rememberedNumber(last, "size", 12)
        var style = PDFTextStyle(fontName: name, size: min(400, max(1, size)))
        if let hex = last["color"], let c = NSColor(hex: hex) { style = PDFTextStyle(fontName: style.fontName, size: style.size, color: c.cgColor) }
        return style
    }

    // MARK: Building

    func reload() {
        guard let c = controller else { return }
        // A change made while rebuilding (see below) asks for another rebuild, once this one is done.
        if reloading { reloadAgain = true; return }
        reloading = true
        defer {
            reloading = false
            if reloadAgain { reloadAgain = false; reload() }
        }
        let session = c.session, canvas = c.canvas
        // The controls are rebuilt: the keyboard goes back to the one that had it (Full Keyboard Access, or a field).
        let focus = focusedControl()
        defer { restoreFocus(focus) }
        // A field still being typed in (the Size field, while the stepper, the font menu or a mode change rebuilds
        // this) keeps what was typed but mustn't send its action as it leaves the window: that action rebuilds the
        // inspector again, in the middle of this rebuild, which AppKit stops with an exception.
        if let text = window?.firstResponder as? NSText, text.isFieldEditor, let field = text.delegate as? NSTextField,
           field.isDescendant(of: self) {
            field.validateEditing()
            let typed = field === sizeField ? sizeField.doubleValue : nil
            field.abortEditing()
            // A size typed but not yet applied (the mode, the checkbox or ⌘+ rebuilt this before Return) applies now,
            // as leaving the field would have, instead of being put back. Not while undoing, nor in the middle of
            // another change (the session's undo manager is detached then), where it would add an undo step.
            if let typed, typed.isFinite, typed > 0, c.session.undoManager === c.undo, !c.undo.isUndoing, !c.undo.isRedoing,
               abs(min(400, max(1, typed)) - shownStyle(c).size) > 0.001 {
                sizeField.doubleValue = typed
                styleChanged(sizeField)
            }
        }
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        sections = []
        revertButton = nil
        spacingButtons = [:]

        var lineID: PDFLineID?
        if case .line(let id)? = canvas.selection { lineID = id }
        if let id = canvas.editor?.lineID { lineID = id }
        var addedID: UUID?
        if case .added(let id)? = canvas.selection { addedID = id }
        if let id = canvas.editor?.addedID { addedID = id }
        let addingNew = canvas.editor?.isNew == true

        lineFont = nil; lineTraits = nil; lineSize = nil; lineColor = nil; highlightSwatches = nil
        if let m = canvas.selectedMarkInfo {
            markSection(m)
            add(separator())
            documentSection(session)
            needsLayout = true
            return
        }
        if canvas.mode == .highlight {
            highlightSection(selected: nil)
            add(separator())
            documentSection(session)
            needsLayout = true
            return
        }
        if let id = lineID, let info = session.info(id) {
            lineSection(info, canvas: canvas)
            if info.availability.isEditable && !info.isDeleted { lineStyleSection(id) }
            if info.availability.isEditable && !session.isRestyled(id) { spacingSection(info) }
        } else if canvas.mode == .editText, addedID == nil {
            add(header("Text"))
            let hasText = !session.lines(page: canvas.page).isEmpty
            add(note(session.isReadOnly ? "This PDF’s signature doesn’t allow changes."
                     : hasText ? "Click a line on the page to change it. Tab moves to the next line, Return confirms, Esc goes back."
                     : "This page has no text to change. Choose Add Text to put new text on it."))
        }
        if canvas.mode == .addText || addedID != nil || addingNew {
            if stack.arrangedSubviews.count > 0 { add(separator()) }
            addTextSection(c, addedID: addedID, addingNew: addingNew)
        }
        add(separator())
        documentSection(session)
        needsLayout = true
    }

    private func lineSection(_ info: PDFLineInfo, canvas: PDFEditCanvas) {
        let revert = NSButton(title: "Revert", target: self, action: #selector(revert(_:)))
        revert.bezelStyle = .rounded
        revert.controlSize = .small
        revert.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        revert.isEnabled = info.isEdited
        revert.toolTip = "Put back the original text of this line"
        revert.setAccessibilityLabel("Revert to the original text")
        revertButton = revert
        add(header(info.isDeleted ? "Text (Deleted)" : "Text", trailing: info.availability.isEditable ? revert : nil))
        add(caption("Original"))
        add(textBox(info.originalText.isEmpty ? "No text" : info.originalText))
        var rows: [(String, NSView)] = []
        let font = NSStackView(views: [value(info.fontDescription)] + info.substitutions.map { value($0.description, secondary: true) })
        font.orientation = .vertical
        font.alignment = .leading
        font.spacing = 2
        rows.append(("Font", font))
        rows.append(("Size", value("\(Self.points(info.pointSize)) pt")))
        rows.append(("Color", colorValue(info.color)))
        if info.fitScale != 1 { rows.append(("Width", value("\(Int((info.fitScale * 100).rounded()))%"))) }
        add(grid(rows))
        if let why = info.availability.reason { add(note(why, symbol: "lock.fill")) }
        for n in info.notes where n != .rotated(info.angle) || abs(info.angle.truncatingRemainder(dividingBy: 90)) > 0.5 {
            add(note(n.message, symbol: "info.circle"))
        }
    }

    private func spacingSection(_ info: PDFLineInfo) {
        add(separator())
        add(header("Spacing"))
        let enabled = info.isEdited && !info.isDeleted
        let details: [PDFSpacing: String] = [
            .flow: "Text after the change moves along, as when typing.",
            .keep: "Text after the change stays where it was.",
            .fit: "The new text is squeezed or stretched to the old width.",
        ]
        for sp in PDFSpacing.allCases {
            let b = NSButton(radioButtonWithTitle: sp.title, target: self, action: #selector(spacingChosen(_:)))
            b.state = info.spacing == sp ? .on : .off
            b.isEnabled = enabled
            b.tag = PDFSpacing.allCases.firstIndex(of: sp) ?? 0
            b.setAccessibilityHelp(details[sp])
            spacingButtons[sp] = b
            guard enabled else {
                // Until the line changes, the choices are shown without their explanations (progressive disclosure).
                add(b)
                continue
            }
            let d = NSTextField(wrappingLabelWithString: details[sp] ?? "")
            d.font = .systemFont(ofSize: 11)
            d.textColor = enabled ? .secondaryLabelColor : .tertiaryLabelColor
            d.preferredMaxLayoutWidth = contentWidth - 20
            let row = NSStackView(views: [b, d])
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = 1
            d.translatesAutoresizingMaskIntoConstraints = false
            let indent = NSStackView(views: [row])
            indent.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 2, right: 0)
            add(indent)
            d.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 20).isActive = true
            d.widthAnchor.constraint(equalToConstant: contentWidth - 20).isActive = true
        }
        if !enabled {
            // While the line is being typed in, the change isn't applied yet: say how to get to the choices.
            let typing = controller?.isTyping == true && controller?.canvas.editor?.lineID == info.id
            add(note(info.isDeleted ? "The line is deleted."
                     : typing ? "Press Return to apply your typing, then choose how it fits." : "Change the line to choose how it fits."))
        }
        if let msg = info.overflowMessage, enabled { add(note(msg, symbol: "exclamationmark.triangle.fill", tint: .systemOrange, primary: true)) }
    }

    /// The style the Add Text controls show: the added text being edited or selected, or the style for new text.
    private func shownStyle(_ c: PDFEditWindowController) -> PDFTextStyle {
        var addedID: UUID?
        if case .added(let id)? = c.canvas.selection { addedID = id }
        if let id = c.canvas.editor?.addedID { addedID = id }
        if let id = addedID, let a = c.session.addedTexts.first(where: { $0.id == id }) { return a.style }
        return c.canvas.addStyle
    }

    private func addTextSection(_ c: PDFEditWindowController, addedID: UUID?, addingNew: Bool) {
        let style: PDFTextStyle
        if let id = addedID, let a = c.session.addedTexts.first(where: { $0.id == id }) { style = a.style } else { style = c.canvas.addStyle }
        add(header(addedID != nil ? "Added Text" : "Add Text"))
        let family = Self.family(of: style.fontName)
        if fontPopUp.item(withTitle: family) == nil { fontPopUp.addItem(withTitle: family) }
        fontPopUp.selectItem(withTitle: family)
        Self.setTraits(addTraits, style: style)
        sizeField.doubleValue = style.size
        sizeStepper.doubleValue = style.size
        colorWell.color = NSColor(cgColor: style.color) ?? .black
        let sizeRow = NSStackView(views: [sizeField, sizeStepper, value("pt", secondary: true)])
        sizeRow.orientation = .horizontal
        sizeRow.alignment = .firstBaseline
        sizeRow.spacing = 4
        add(grid([("Font", fontPopUp), ("Style", addTraits), ("Size", sizeRow), ("Color", colorWell)]))
        if addedID == nil && !addingNew { add(note("Click the page where the new text should start.")) }
        if let id = addedID, let a = c.session.addedTexts.first(where: { $0.id == id }) {
            for s in a.substitutions { add(note(s.description, symbol: "info.circle")) }
            add(note("Drag the text to move it. Delete removes it."))
        }
    }

    private func documentSection(_ session: PDFEditSession) {
        add(header("Saving"))
        removeReplaced.isEnabled = session.canRemoveReplacedText
        if !session.canRemoveReplacedText { removeReplaced.state = .off }
        add(removeReplaced)
        add(note(session.removeReplacedTextUnavailableReason
                 ?? "Takes the old wording out of the saved file instead of keeping it in the file’s history. The whole file is rewritten.",
                 indent: 20))
        if let name = controller?.outputName { add(note("Saves a copy named “\(name)” next to the original.")) }
    }

    // MARK: Keyboard focus across rebuilds

    private enum Focus { case view(NSView), spacing(Int), revert }

    /// The inspector control that has the keyboard (a field being typed in counts as the field).
    private func focusedControl() -> Focus? {
        guard let responder = window?.firstResponder else { return nil }
        let text = responder as? NSText
        guard let view = (text?.isFieldEditor == true ? text?.delegate as? NSView : nil) ?? responder as? NSView,
              view.isDescendant(of: self) else { return nil }
        if [removeReplaced, fontPopUp, sizeField, sizeStepper, colorWell].contains(where: { $0 === view }) { return .view(view) }
        if let b = view as? NSButton, spacingButtons.values.contains(where: { $0 === b }) { return .spacing(b.tag) }
        if let b = view as? NSButton, b === revertButton { return .revert }
        return nil
    }

    private func restoreFocus(_ focus: Focus?) {
        guard let focus, let window else { return }
        let target: NSView?
        switch focus {
        case .view(let v): target = v.isDescendant(of: self) ? v : nil
        case .spacing(let tag): target = spacingButtons.values.first { $0.tag == tag }
        case .revert: target = revertButton
        }
        guard let target else { return }
        let text = window.firstResponder as? NSText
        if window.firstResponder === target || (text?.isFieldEditor == true && text?.delegate as? NSView === target) { return }
        window.makeFirstResponder(target)
    }

    // MARK: Pieces

    private func add(_ v: NSView) { stack.addArrangedSubview(v) }

    private func header(_ title: String, trailing: NSView? = nil) -> NSView {
        sections.append(title)
        let l = NSTextField(labelWithString: title)
        l.font = .systemFont(ofSize: 13, weight: .semibold)
        l.textColor = .labelColor
        l.setAccessibilityRole(.staticText)
        guard let trailing else { return l }
        let row = NSStackView(views: [l, NSView(), trailing])
        row.orientation = .horizontal
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        return row
    }

    private func caption(_ text: String) -> NSView {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func value(_ text: String, secondary: Bool = false) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: 12)
        l.textColor = secondary ? .secondaryLabelColor : .labelColor
        l.isSelectable = true
        l.preferredMaxLayoutWidth = contentWidth - 64
        return l
    }

    private func textBox(_ text: String) -> NSView {
        let box = PDFEditTextBox(text: text, width: contentWidth)
        return box
    }

    private func colorValue(_ c: CGColor) -> NSView {
        let swatch = PDFEditSwatch(color: NSColor(cgColor: c) ?? .black)
        let row = NSStackView(views: [swatch, value(Self.colorName(c))])
        row.orientation = .horizontal
        row.spacing = 6
        return row
    }

    private func note(_ text: String, symbol: String? = nil, tint: NSColor = .secondaryLabelColor, primary: Bool = false,
                      indent: CGFloat = 0) -> NSView {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: 11)
        l.textColor = primary ? .labelColor : .secondaryLabelColor
        l.isSelectable = false
        let iconWidth: CGFloat = symbol == nil ? 0 : 18
        l.preferredMaxLayoutWidth = contentWidth - iconWidth - indent
        var views: [NSView] = []
        if let symbol {
            let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .regular)) ?? NSImage())
            icon.contentTintColor = tint
            icon.setContentHuggingPriority(.required, for: .horizontal)
            views.append(icon)
        }
        views.append(l)
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 5
        row.edgeInsets = NSEdgeInsets(top: 0, left: indent, bottom: 0, right: 0)
        return row
    }

    private func grid(_ rows: [(String, NSView)]) -> NSView {
        let g = NSGridView(views: rows.map { [caption($0.0), $0.1] })
        g.rowSpacing = 8
        g.columnSpacing = 8
        g.column(at: 0).width = 48
        g.column(at: 0).xPlacement = .leading
        g.rowAlignment = .firstBaseline
        return g
    }

    private func separator() -> NSView {
        let v = ImageEditors.FillView(color: ImageEditors.Style.hairline)
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: 1).isActive = true
        v.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        let wrap = NSStackView(views: [v])
        wrap.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        return wrap
    }

    static func points(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        return r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r)
    }

    static func colorName(_ c: CGColor) -> String {
        let s = NSColor(cgColor: c)?.usingColorSpace(.sRGB) ?? .black
        let r = Int((s.redComponent * 255).rounded()), g = Int((s.greenComponent * 255).rounded()), b = Int((s.blueComponent * 255).rounded())
        if r == 0 && g == 0 && b == 0 { return "Black" }
        if r == 255 && g == 255 && b == 255 { return "White" }
        if r == g && g == b { return "Gray \(String(format: "#%02X%02X%02X", r, g, b))" }
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    // MARK: Style of a line, highlights and pictures

    /// Font, Bold/Italic, size and colour of the selected line: changing any redraws the line in that style.
    private func lineStyleSection(_ id: PDFLineID) {
        guard let c = controller, let style = c.session.style(of: id) else { return }
        add(separator())
        add(header("Style"))
        let font = NSPopUpButton(frame: .zero, pullsDown: false)
        let family = Self.family(of: style.fontName)
        var families = Self.fonts
        if !families.contains(family) { families.insert(family, at: 0) }
        font.addItems(withTitles: families)
        for item in font.itemArray {
            if let f = NSFont(name: item.title, size: 13) ?? NSFontManager.shared.font(withFamily: item.title, traits: [], weight: 5, size: 13) {
                item.attributedTitle = NSAttributedString(string: item.title, attributes: [.font: f])
            }
        }
        font.selectItem(withTitle: family)
        font.target = self
        font.action = #selector(lineStyleChanged(_:))
        font.setAccessibilityLabel("Font of the line")
        let traits = NSSegmentedControl(labels: ["B", "I"], trackingMode: .selectAny, target: self, action: #selector(lineStyleChanged(_:)))
        Self.configureTraits(traits, label: "the line")
        Self.setTraits(traits, style: style)
        let size = NSTextField()
        let number = NumberFormatter()
        number.minimum = 1; number.maximum = 400; number.maximumFractionDigits = 1
        size.formatter = number
        size.alignment = .right
        size.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        size.doubleValue = style.size
        size.target = self
        size.action = #selector(lineStyleChanged(_:))
        (size.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = true
        size.setAccessibilityLabel("Size of the line in points")
        size.widthAnchor.constraint(equalToConstant: 52).isActive = true
        let stepper = NSStepper()
        stepper.minValue = 1; stepper.maxValue = 400; stepper.increment = 1; stepper.doubleValue = style.size
        stepper.target = self
        stepper.action = #selector(lineSizeStepped(_:))
        stepper.setAccessibilityLabel("Size")
        let color = NSColorWell()
        color.isContinuous = false
        color.color = NSColor(cgColor: style.color) ?? .black
        color.target = self
        color.action = #selector(lineStyleChanged(_:))
        color.setAccessibilityLabel("Color of the line")
        color.widthAnchor.constraint(equalToConstant: 52).isActive = true
        color.heightAnchor.constraint(equalToConstant: 24).isActive = true
        lineFont = font; lineTraits = traits; lineSize = size; lineColor = color
        lineStepperRef = stepper
        let sizeRow = NSStackView(views: [size, stepper, value("pt", secondary: true)])
        sizeRow.orientation = .horizontal
        sizeRow.alignment = .firstBaseline
        sizeRow.spacing = 4
        add(grid([("Font", font), ("Style", traits), ("Size", sizeRow), ("Color", color)]))
    }
    private var lineStepperRef: NSStepper?

    @objc private func lineSizeStepped(_ sender: NSStepper) {
        lineSize?.doubleValue = sender.doubleValue
        lineStyleChanged(sender)
    }

    @objc private func lineStyleChanged(_ sender: Any?) {
        guard let c = controller, let font = lineFont, let traits = lineTraits, let sizeField = lineSize, let well = lineColor else { return }
        let id: PDFLineID
        if let e = c.canvas.editor?.lineID { id = e } else if case .line(let s)? = c.canvas.selection { id = s } else { return }
        if c.canvas.editor != nil { guard c.canvas.commitEditing() else { return } }
        let size = min(400, max(1, sizeField.doubleValue > 0 ? sizeField.doubleValue : 12))
        let style = Self.textStyle(family: font.titleOfSelectedItem ?? "Helvetica", bold: traits.isSelected(forSegment: 0),
                                   italic: traits.isSelected(forSegment: 1), size: size, color: well.color)
        c.perform("Couldn’t change the style") { try c.session.setStyle(style, for: id) }
        c.canvas.select(.line(id))
    }

    /// Highlight mode (no highlight selected): the colour for new highlights. A highlight selected: its colour.
    private func highlightSection(selected: PDFMark?) {
        guard let c = controller else { return }
        let removeButton = selected.map { _ in Self.smallButton("Remove", target: self, action: #selector(removeMark(_:))) }
        add(header("Highlight", trailing: removeButton))
        let current: (Double, Double, Double)
        if let m = selected, case .highlight(_, let r, let g, let b) = m.kind { current = (r, g, b) } else { current = c.canvas.highlightColor }
        let images = PDFEditCanvas.highlightColors.map { Self.dot(NSColor(srgbRed: $0.rgb.0, green: $0.rgb.1, blue: $0.rgb.2, alpha: 1)) }
        let seg = NSSegmentedControl(images: images, trackingMode: .selectOne, target: self, action: #selector(highlightColorChosen(_:)))
        for (i, hc) in PDFEditCanvas.highlightColors.enumerated() {
            seg.setWidth(32, forSegment: i)
            seg.setToolTip(hc.name, forSegment: i)
            seg.setLabel("", forSegment: i)
            (seg.cell as? NSSegmentedCell)?.setToolTip(hc.name, forSegment: i)
            if abs(hc.rgb.0 - current.0) < 0.01 && abs(hc.rgb.1 - current.1) < 0.01 && abs(hc.rgb.2 - current.2) < 0.01 { seg.selectedSegment = i }
        }
        seg.setAccessibilityLabel("Highlight colour")
        highlightSwatches = seg
        add(grid([("Color", seg)]))
        add(note(selected == nil ? "Drag across text to highlight it. Click a highlight to change its colour or remove it."
                 : "Delete removes the highlight."))
    }

    private func markSection(_ m: PDFMark) {
        switch m.kind {
        case .highlight:
            highlightSection(selected: m)
        case .image(_, let r):
            add(header("Picture", trailing: Self.smallButton("Remove", target: self, action: #selector(removeMark(_:)))))
            add(grid([("Size", value("\(Self.points(Double(r.width))) × \(Self.points(Double(r.height))) pt"))]))
            add(note("Drag the picture to move it, or its corner to resize it. Delete removes it."))
        }
    }

    @objc private func highlightColorChosen(_ sender: NSSegmentedControl) {
        guard let c = controller, sender.selectedSegment >= 0, sender.selectedSegment < PDFEditCanvas.highlightColors.count else { return }
        c.canvas.setHighlightColor(PDFEditCanvas.highlightColors[sender.selectedSegment].rgb)
    }

    @objc private func removeMark(_ sender: Any?) { controller?.canvas.removeSelectedMark() }

    static func smallButton(_ title: String, target: AnyObject, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: target, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        return b
    }

    static func dot(_ color: NSColor) -> NSImage {
        let img = NSImage(size: CGSize(width: 14, height: 14), flipped: false) { r in
            color.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
            NSColor.black.withAlphaComponent(0.2).setStroke()
            NSBezierPath(ovalIn: r.insetBy(dx: 1.5, dy: 1.5)).stroke()
            return true
        }
        img.isTemplate = false
        return img
    }

    /// B and I: bold and italic type in their own faces, with spoken names.
    static func configureTraits(_ seg: NSSegmentedControl, label: String) {
        seg.setWidth(32, forSegment: 0)
        seg.setWidth(32, forSegment: 1)
        let b = NSFont.boldSystemFont(ofSize: 13)
        let i = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 13), toHaveTrait: .italicFontMask)
        (seg.cell as? NSSegmentedCell)?.setToolTip("Bold", forSegment: 0)
        (seg.cell as? NSSegmentedCell)?.setToolTip("Italic", forSegment: 1)
        seg.setLabel("B", forSegment: 0)
        seg.setLabel("I", forSegment: 1)
        // Segment labels take the control's font: draw each letter as an image in its own face instead.
        seg.setImage(letter("B", b), forSegment: 0)
        seg.setImage(letter("I", i), forSegment: 1)
        seg.setLabel("", forSegment: 0)
        seg.setLabel("", forSegment: 1)
        seg.setAccessibilityLabel("Bold and italic for \(label)")
    }

    private static func letter(_ s: String, _ font: NSFont) -> NSImage {
        let str = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor.black])
        let size = str.size()
        let img = NSImage(size: CGSize(width: ceil(size.width) + 2, height: ceil(size.height)), flipped: false) { _ in
            str.draw(at: CGPoint(x: 1, y: 0)); return true
        }
        img.isTemplate = true
        img.accessibilityDescription = s == "B" ? "Bold" : "Italic"
        return img
    }

    static func setTraits(_ seg: NSSegmentedControl, style: PDFTextStyle) {
        let t = NSFont(name: style.fontName, size: 12).map { NSFontManager.shared.traits(of: $0) } ?? []
        seg.setSelected(t.contains(.boldFontMask) || style.syntheticBold, forSegment: 0)
        seg.setSelected(t.contains(.italicFontMask) || style.syntheticItalic, forSegment: 1)
    }

    /// A style in the family's bold or italic face, or drawn bold or slanted when the family has no such face.
    static func textStyle(family: String, bold: Bool, italic: Bool, size: Double, color: NSColor) -> PDFTextStyle {
        let name = fontName(family: family, bold: bold, italic: italic, size: size)
        var st = PDFTextStyle(fontName: name, size: size, color: (color.usingColorSpace(.sRGB) ?? .black).cgColor)
        let t = NSFont(name: name, size: 12).map { NSFontManager.shared.traits(of: $0) } ?? []
        st.syntheticBold = bold && !t.contains(.boldFontMask)
        st.syntheticItalic = italic && !t.contains(.italicFontMask)
        return st
    }

    static func family(of fontName: String) -> String { NSFont(name: fontName, size: 12)?.familyName ?? fontName }

    /// The family's face for bold and italic, or the nearest it has.
    static func fontName(family: String, bold: Bool, italic: Bool, size: Double) -> String {
        let fm = NSFontManager.shared
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        let weight = bold ? 9 : 5
        if let f = fm.font(withFamily: family, traits: traits, weight: weight, size: CGFloat(size)) { return f.fontName }
        guard var f = fm.font(withFamily: family, traits: [], weight: 5, size: CGFloat(size)) ?? NSFont(name: family, size: CGFloat(size)) else {
            return family
        }
        if bold { f = fm.convert(f, toHaveTrait: .boldFontMask) }
        if italic { f = fm.convert(f, toHaveTrait: .italicFontMask) }
        return f.fontName
    }

    // MARK: Actions

    @objc private func revert(_ sender: Any?) {
        guard let c = controller, let id = c.canvas.editor?.lineID ?? { if case .line(let id)? = c.canvas.selection { return id }; return nil }() else { return }
        if c.canvas.editor != nil { c.canvas.cancelEditing() }
        c.perform("Couldn’t revert the text") { c.session.revert(id) }
        c.canvas.select(.line(id))
    }

    @objc private func spacingChosen(_ sender: NSButton) {
        guard let c = controller, case .line(let id)? = c.canvas.selection, sender.tag < PDFSpacing.allCases.count else { return }
        let sp = PDFSpacing.allCases[sender.tag]
        c.perform("Couldn’t change the spacing") { try c.session.setSpacing(sp, for: id) }
    }

    @objc private func removeReplacedChanged(_ sender: NSButton) {
        guard let c = controller else { return }
        c.session.removeReplacedText = removeReplacedText && c.session.canRemoveReplacedText
        c.refreshChrome()
    }

    /// The stepper steps from what's typed in the Size field, not from the size before typing.
    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === sizeField, let editor = obj.userInfo?["NSFieldEditor"] as? NSText,
              let v = Double(editor.string.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")),
              v.isFinite else { return }
        sizeStepper.doubleValue = min(400, max(1, v))
    }

    @objc private func stepped(_ sender: NSStepper) {
        sizeField.doubleValue = sender.doubleValue
        styleChanged(sender)
    }

    /// Font, size or colour: the style for new text, and for the selected added text.
    @objc private func styleChanged(_ sender: Any?) {
        guard let c = controller else { return }
        let size = min(400, max(1, sizeField.doubleValue > 0 ? sizeField.doubleValue : 12))
        sizeStepper.doubleValue = size
        let style = Self.textStyle(family: fontPopUp.titleOfSelectedItem ?? "Helvetica", bold: addTraits.isSelected(forSegment: 0),
                                   italic: addTraits.isSelected(forSegment: 1), size: size, color: colorWell.color)
        c.canvas.addStyle = style
        ImageExtras.remember(["font": style.fontName, "size": Self.points(style.size),
                              "color": String(format: "#%02X%02X%02X", Int(style.red * 255), Int(style.green * 255), Int(style.blue * 255))],
                             as: Self.remembered)
        if c.canvas.editor != nil { _ = c.canvas.commitEditing() }
        if case .added(let id)? = c.canvas.selection {
            c.perform("Couldn’t change the text") { try c.session.updateAddedText(id, style: style) }
        }
        c.refreshChrome()
    }
}

/// A flipped container (scroll views lay out from the top).
final class PDFEditFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The original text in a quiet rounded box.
final class PDFEditTextBox: NSView {
    private let label: NSTextField

    init(text: String, width: CGFloat) {
        label = NSTextField(wrappingLabelWithString: text)
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.isSelectable = true
        label.preferredMaxLayoutWidth = width - 16
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
    }
}

/// A small colour swatch with a hairline edge (so white shows on white).
final class PDFEditSwatch: NSView {
    let color: NSColor

    init(color: NSColor) {
        self.color = color
        super.init(frame: CGRect(x: 0, y: 0, width: 12, height: 12))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 12).isActive = true
        heightAnchor.constraint(equalToConstant: 12).isActive = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        color.setFill()
        p.fill()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.labelColor.withAlphaComponent(0.3).setStroke()
            p.lineWidth = 1
            p.stroke()
        }
    }
}
