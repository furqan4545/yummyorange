import AppKit
import CoreImage

extension ImageEditors {
    /// The Adjust window: a live preview on the left (rendered from a downscaled proxy), slider groups on the
    /// right, Show Original and Save in the window toolbar, and the image's size and format in a status bar.
    /// Saving renders the full-size image off the main thread and writes "<name> adjusted.<ext>".
    final class AdjustEditorView: EditorRootView {
        /// Longest side of the preview proxy in pixels: sharp on a Retina screen, fast to filter.
        static let proxyPixels = 2048

        private let source: SourceImage
        private(set) var adjustments = Adjustments()
        private let preview = AdjustPreviewView()
        private var rows: [Adjustments.Key: AdjustSliderRow] = [:]
        private var resetButton: NSButton!
        private var compareButton: NSButton!
        private var compareItem: NSToolbarItem!
        private var saveItem: NSToolbarItem!
        private let statusBar = StatusBar()
        private var spinner: NSProgressIndicator { statusBar.spinner }
        private var statusLabel: NSTextField { statusBar.leading }

        private var proxyImage: CIImage?
        private var proxyScale: CGFloat = 1
        private static let previewContext = CIContext()
        private let renderQueue = DispatchQueue(label: "dropwheel.adjust.preview", qos: .userInteractive)
        private var isRendering = false
        private var needsRender = false
        private var isSaving = false
        private var stickyOriginal = false
        private var heldOriginal = false
        private var isClosed = false

        override var minimumSize: CGSize { CGSize(width: 780, height: 520) }

        init(source: SourceImage, loadAsync: Bool = true) {
            self.source = source
            super.init(frame: CGRect(x: 0, y: 0, width: 1100, height: 720))
            buildInterface()
            preview.fullSize = source.size
            if loadAsync { loadProxy() } else { loadProxySync() }
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        // MARK: Interface

        private func buildInterface() {
            let sidebar = buildSidebar()
            let bottom = buildStatusBar()
            let divider = FillView(color: Style.hairline)
            for view in [preview, divider, sidebar, bottom] as [NSView] {
                view.translatesAutoresizingMaskIntoConstraints = false
                addSubview(view)
            }
            preview.onHold = { [weak self] down in self?.heldOriginal = down; self?.updateOriginal() }
            NSLayoutConstraint.activate([
                preview.topAnchor.constraint(equalTo: topAnchor),
                preview.leadingAnchor.constraint(equalTo: leadingAnchor),
                preview.bottomAnchor.constraint(equalTo: bottom.topAnchor),
                preview.trailingAnchor.constraint(equalTo: divider.leadingAnchor),
                divider.topAnchor.constraint(equalTo: topAnchor),
                divider.bottomAnchor.constraint(equalTo: bottom.topAnchor),
                divider.widthAnchor.constraint(equalToConstant: 1),
                divider.trailingAnchor.constraint(equalTo: sidebar.leadingAnchor),
                sidebar.topAnchor.constraint(equalTo: topAnchor),
                sidebar.trailingAnchor.constraint(equalTo: trailingAnchor),
                sidebar.bottomAnchor.constraint(equalTo: bottom.topAnchor),
                sidebar.widthAnchor.constraint(equalToConstant: 300),
                bottom.leadingAnchor.constraint(equalTo: leadingAnchor),
                bottom.trailingAnchor.constraint(equalTo: trailingAnchor),
                bottom.bottomAnchor.constraint(equalTo: bottomAnchor),
                bottom.heightAnchor.constraint(equalToConstant: StatusBar.height),
            ])
        }

        private func buildSidebar() -> NSView {
            let panel = FillView(color: Style.chrome)
            let title = Style.label("Adjustments", size: 15, weight: .semibold)
            resetButton = NSButton(title: "Reset", target: self, action: #selector(resetAll))
            resetButton.bezelStyle = .rounded
            resetButton.controlSize = .small
            resetButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            resetButton.toolTip = "Set every slider back to zero"
            let header = NSStackView(views: [title, NSView(), resetButton])
            header.orientation = .horizontal

            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 6
            stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 22, right: 18)
            stack.addArrangedSubview(header)
            stack.setCustomSpacing(10, after: header)
            for group in Adjustments.groups {
                let symbol = NSImageView(image: NSImage(systemSymbolName: group.symbol, accessibilityDescription: nil) ?? NSImage())
                symbol.contentTintColor = .secondaryLabelColor
                symbol.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
                let groupTitle = Style.label(group.title, size: 12, weight: .semibold, color: .secondaryLabelColor)
                let groupHeader = NSStackView(views: [symbol, groupTitle])
                groupHeader.spacing = 6
                stack.addArrangedSubview(groupHeader)
                stack.setCustomSpacing(14, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])
                for key in group.keys {
                    let row = AdjustSliderRow(key: key)
                    row.onChange = { [weak self] value in self?.set(key, value) }
                    rows[key] = row
                    stack.addArrangedSubview(row)
                }
                if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(14, after: last) }
            }
            for view in stack.arrangedSubviews {
                view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36).isActive = true
            }

            let document = FlippedContainer()
            document.translatesAutoresizingMaskIntoConstraints = false
            stack.translatesAutoresizingMaskIntoConstraints = false
            document.addSubview(stack)
            let scroll = NSScrollView()
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.borderType = .noBorder
            scroll.documentView = document
            scroll.translatesAutoresizingMaskIntoConstraints = false
            panel.addSubview(scroll)
            NSLayoutConstraint.activate([
                scroll.topAnchor.constraint(equalTo: panel.topAnchor),
                scroll.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
                scroll.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
                document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
                document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
                document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
                stack.topAnchor.constraint(equalTo: document.topAnchor),
                stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
                stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            ])
            return panel
        }

        /// The toolbar: Show Original (a toggle) and Save, on the trailing side.
        private func buildToolbarItems() {
            compareButton = NSButton(title: "Show Original", target: self, action: #selector(toggleOriginal))
            compareButton.setButtonType(.pushOnPushOff)
            compareButton.bezelStyle = .texturedRounded
            compareButton.toolTip = "Show the original. You can also hold M, or press and hold on the picture."
            compareButton.setAccessibilityLabel("Show Original")
            let menu = NSMenuItem(title: "Show Original", action: #selector(toggleOriginalFromMenu), keyEquivalent: "")
            menu.target = self
            compareItem = Bar.view("compare", compareButton, label: "Show Original", menu: menu)
            saveItem = Bar.save(target: self, action: #selector(saveClicked), tip: "Save a full-size copy next to the original (⌘S)")
        }

        override func makeToolbarItems() -> [NSToolbarItem] {
            [Bar.flexibleSpace(), compareItem, Bar.space(), saveItem]
        }

        /// Information only: the image's size and format, or what's happening.
        private func buildStatusBar() -> NSView {
            buildToolbarItems()
            statusLabel.stringValue = source.summary
            updateButtons()
            return statusBar
        }

        private func updateButtons() {
            let neutral = adjustments.isNeutral
            Bar.enable(saveItem, !neutral && !isSaving && preview.original != nil)
            resetButton?.isEnabled = !neutral && !isSaving
            for row in rows.values { row.isEnabled = !isSaving }
        }

        /// Puts every slider and value field in step with `adjustments`.
        private func syncControls() {
            for (key, row) in rows { row.setValue(adjustments[key]) }
            updateButtons()
        }

        // MARK: Editing

        private func set(_ key: Adjustments.Key, _ value: Double) {
            adjustments[key] = value
            rows[key]?.setValue(adjustments[key])
            updateButtons()
            schedulePreview()
        }

        @objc private func resetAll() {
            adjustments = Adjustments()
            syncControls()
            schedulePreview()
        }

        @objc private func toggleOriginal() {
            stickyOriginal = compareButton.state == .on
            updateOriginal()
        }

        @objc private func toggleOriginalFromMenu() {
            compareButton.state = compareButton.state == .on ? .off : .on
            toggleOriginal()
        }

        private func updateOriginal() {
            preview.showsOriginal = stickyOriginal || heldOriginal
        }

        /// For snapshots and tests.
        func setValues(_ values: Adjustments, showOriginal: Bool = false) {
            adjustments = values
            syncControls()
            stickyOriginal = showOriginal
            compareButton.state = showOriginal ? .on : .off
            updateOriginal()
        }

        func value(_ key: Adjustments.Key) -> Double { adjustments[key] }
        var isShowingOriginal: Bool { preview.showsOriginal }
        var previewImage: CGImage? { preview.adjusted }

        // MARK: Preview

        private func loadProxy() {
            preview.isLoading = true
            let source = self.source
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = Result { try source.proxy(maxPixels: Self.proxyPixels) }
                DispatchQueue.main.async {
                    guard let self, !self.isClosed else { return }
                    self.preview.isLoading = false
                    switch result {
                    case .success(let image): self.useProxy(image)
                    case .failure(let error):
                        self.statusLabel.stringValue = error.localizedDescription
                        self.statusLabel.textColor = .systemRed
                    }
                }
            }
        }

        private func loadProxySync() {
            if let image = try? source.proxy(maxPixels: Self.proxyPixels) { useProxy(image) }
        }

        private func useProxy(_ image: CGImage) {
            preview.original = image
            preview.hasAlpha = ImageEditors.hasAlpha(image)
            proxyImage = CIImage(cgImage: image)
            proxyScale = CGFloat(max(image.width, image.height)) / source.longSide
            updateButtons()
            schedulePreview()
        }

        /// Re-renders the preview off the main thread. While a render runs, further changes coalesce into
        /// one more render with the latest values, so dragging a slider never queues up stale frames.
        private func schedulePreview() {
            guard proxyImage != nil else { return }
            needsRender = true
            guard !isRendering else { return }
            renderNextPreview()
        }

        private func renderNextPreview() {
            guard needsRender, let input = proxyImage, let original = preview.original, !isClosed else { return }
            needsRender = false
            isRendering = true
            let values = adjustments, scale = proxyScale, longSide = source.longSide
            renderQueue.async { [weak self] in
                let image = values.isNeutral ? original : Self.renderPreview(values, input, original, scale, longSide)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isRendering = false
                    guard !self.isClosed else { return }
                    self.preview.adjusted = image
                    self.renderNextPreview()
                }
            }
        }

        private static func renderPreview(_ values: Adjustments, _ input: CIImage, _ original: CGImage,
                                          _ scale: CGFloat, _ longSide: CGFloat) -> CGImage? {
            let output = values.apply(to: input, scale: scale, fullLongSide: longSide)
            return previewContext.createCGImage(output, from: input.extent, format: .RGBA8,
                                                colorSpace: ImageEditors.outputColorSpace(for: original))
        }

        /// Renders the preview on the calling thread (snapshots and tests).
        func renderPreviewNow() {
            guard let input = proxyImage, let original = preview.original else { return }
            needsRender = false
            preview.adjusted = adjustments.isNeutral ? original
                : Self.renderPreview(adjustments, input, original, proxyScale, source.longSide)
        }

        // MARK: Save and cancel

        @objc private func saveClicked() { requestSave() }

        override func requestSave() {
            window?.makeFirstResponder(nil)   // commit a value being typed
            guard !isSaving, !adjustments.isNeutral, preview.original != nil else { NSSound.beep(); return }
            isSaving = true
            spinner.startAnimation(nil)
            statusLabel.stringValue = "Saving…"
            updateButtons()
            let values = adjustments, source = self.source
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = Result { try values.save(source) }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isSaving = false
                    self.spinner.stopAnimation(nil)
                    switch result {
                    case .success(let url):
                        JobRunner.report(saved: [url])
                        self.onFinish?(url)
                    case .failure(let error):
                        self.statusLabel.stringValue = self.source.summary
                        self.updateButtons()
                        JobRunner.report(saved: [], errors: [error.localizedDescription])
                        self.showError(error, title: "Couldn’t save the adjusted copy")
                    }
                }
            }
        }

        override var hasUnsavedChanges: Bool { !isSaving && !adjustments.isNeutral }

        /// Closes straight away when nothing was changed; otherwise asks before throwing the changes away.
        override func requestCancel() {
            guard !isSaving else { return }
            guard !adjustments.isNeutral, window != nil else { onFinish?(nil); return }
            confirmDiscard(detail: "The adjustments to “\(source.url.lastPathComponent)” haven’t been saved.") { [weak self] in
                self?.onFinish?(nil)
            }
        }

        override func tearDown() {
            isClosed = true
            proxyImage = nil
            preview.original = nil
            preview.adjusted = nil
        }

        // MARK: Keys

        override func handleKey(_ event: NSEvent) -> Bool {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            let editingText = window?.firstResponder is NSText
            if event.type == .keyUp {
                if key == "m", heldOriginal { heldOriginal = false; updateOriginal(); return true }
                return false
            }
            if flags == .command && key == "s" { requestSave(); return true }
            if flags == .command && key == "w" { requestCancel(); return true }
            if event.keyCode == 53 {   // Esc: abandon a value being typed first, then close
                if editingText, let field = window?.firstResponder as? NSTextView {
                    field.string = ""   // an empty entry doesn't parse, so the field reverts to the slider's value
                    window?.makeFirstResponder(nil)
                } else {
                    requestCancel()
                }
                return true
            }
            if handleTextEditingShortcut(event) { return true }
            if !editingText, flags.subtracting(.capsLock).isEmpty, key == "m" {
                if !event.isARepeat { heldOriginal = true; updateOriginal() }
                return true
            }
            return false
        }
    }

    /// The flipped document view of the sidebar's scroll view, so content starts at the top.
    final class FlippedContainer: NSView {
        override var isFlipped: Bool { true }
    }

    // MARK: - Preview view

    /// Draws the picture fitted to the view on the canvas color, with a soft shadow, a checkerboard under
    /// transparent images and an "Original" badge while comparing. Pressing on it shows the original.
    final class AdjustPreviewView: NSView {
        var original: CGImage? { didSet { needsDisplay = true } }
        var adjusted: CGImage? { didSet { needsDisplay = true } }
        var showsOriginal = false { didSet { if showsOriginal != oldValue { needsDisplay = true } } }
        var hasAlpha = false
        /// Full-resolution size, so small images aren't blown up past 100%.
        var fullSize = CGSize(width: 1, height: 1)
        var isLoading = false {
            didSet { isLoading ? spinner.startAnimation(nil) : spinner.stopAnimation(nil) }
        }
        var onHold: ((Bool) -> Void)?
        private let spinner = NSProgressIndicator()

        override var isFlipped: Bool { true }

        override init(frame: NSRect) {
            super.init(frame: frame)
            spinner.style = .spinning
            spinner.isDisplayedWhenStopped = false
            spinner.translatesAutoresizingMaskIntoConstraints = false
            addSubview(spinner)
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor).isActive = true
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        var imageRect: CGRect {
            ImageEditors.fit(fullSize, in: bounds.insetBy(dx: 28, dy: 28))
        }

        override func draw(_ dirtyRect: NSRect) {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                Style.canvas.setFill()
                bounds.fill()
                guard let image = showsOriginal ? original : (adjusted ?? original),
                      let ctx = NSGraphicsContext.current?.cgContext else { return }
                let r = imageRect
                ImageEditors.drawPicture(image, in: r, hasAlpha: hasAlpha, ctx: ctx)
                if showsOriginal { ImageEditors.drawBadge("Original", at: CGPoint(x: r.minX + 10, y: r.minY + 10)) }
            }
        }

        override func mouseDown(with event: NSEvent) { onHold?(true) }
        override func mouseUp(with event: NSEvent) { onHold?(false) }
    }

    /// The largest rect with `size`'s aspect ratio that fits `area`, centered, never above 100% (small
    /// images are enlarged only up to 64 points on their long side so they stay visible).
    static func fit(_ size: CGSize, in area: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0, area.width > 0, area.height > 0 else { return .zero }
        let maxScale = max(1, 64 / max(size.width, size.height))
        let s = min(area.width / size.width, area.height / size.height, maxScale)
        let w = (size.width * s).rounded(), h = (size.height * s).rounded()
        return CGRect(x: (area.midX - w / 2).rounded(), y: (area.midY - h / 2).rounded(), width: w, height: h)
    }

    /// Draws a picture into a flipped view's context: shadow, checkerboard for transparency, then the pixels.
    static func drawPicture(_ image: CGImage, in r: CGRect, hasAlpha: Bool, ctx: CGContext) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 16, color: NSColor.black.withAlphaComponent(0.30).cgColor)
        ctx.setFillColor(hasAlpha ? NSColor.white.cgColor : NSColor.black.cgColor)
        ctx.fill(r)
        ctx.restoreGState()
        if hasAlpha {
            ctx.saveGState()
            ctx.clip(to: r)
            ctx.setFillColor(NSColor(white: 0.84, alpha: 1).cgColor)
            let cell: CGFloat = 8
            var y = r.minY, row = 0
            while y < r.maxY {
                var x = r.minX + (row % 2 == 0 ? 0 : cell)
                while x < r.maxX { ctx.fill(CGRect(x: x, y: y, width: cell, height: cell)); x += cell * 2 }
                y += cell; row += 1
            }
            ctx.restoreGState()
        }
        ctx.saveGState()
        // Upscaled tiny images stay crisp; everything else is smoothed.
        ctx.interpolationQuality = r.width > CGFloat(image.width) * 2 ? .none : .high
        ctx.translateBy(x: r.minX, y: r.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: r.size))
        ctx.restoreGState()
    }

    /// A small dark capsule with white text, for "Original" and similar overlays.
    static func drawBadge(_ text: String, at origin: CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                                                         .foregroundColor: NSColor.white]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        let box = CGRect(x: origin.x, y: origin.y, width: ceil(size.width) + 16, height: ceil(size.height) + 6)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
        string.draw(at: CGPoint(x: box.minX + 8, y: box.minY + 3))
    }

    // MARK: - Slider row

    /// One adjustment: its name and an editable value on top, the slider below. Double-click the slider to
    /// reset it; type a number in the value field to set it exactly.
    final class AdjustSliderRow: NSView, NSTextFieldDelegate {
        let key: Adjustments.Key
        let slider = ResettableSlider()
        let valueField = NSTextField(string: "")
        var onChange: ((Double) -> Void)?

        var isEnabled = true {
            didSet { slider.isEnabled = isEnabled; valueField.isEnabled = isEnabled }
        }

        init(key: Adjustments.Key) {
            self.key = key
            super.init(frame: .zero)
            let title = Style.label(key.title, size: 12.5)
            valueField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            valueField.textColor = .secondaryLabelColor
            valueField.alignment = .right
            valueField.isBordered = false
            valueField.drawsBackground = false
            valueField.focusRingType = .exterior
            valueField.delegate = self
            valueField.toolTip = "Type a value"
            valueField.setAccessibilityLabel("\(key.title) value")
            slider.minValue = key.range.lowerBound
            slider.maxValue = key.range.upperBound
            slider.doubleValue = 0
            slider.isContinuous = true
            slider.controlSize = .small
            slider.target = self
            slider.action = #selector(sliderMoved)
            slider.toolTip = "Double-click to reset"
            slider.setAccessibilityLabel(key.title)
            if key.range.lowerBound < 0 { slider.numberOfTickMarks = 1 }   // a center mark at zero
            slider.onReset = { [weak self] in self?.onChange?(0) }
            for view in [title, valueField, slider] as [NSView] {
                view.translatesAutoresizingMaskIntoConstraints = false
                addSubview(view)
            }
            NSLayoutConstraint.activate([
                title.topAnchor.constraint(equalTo: topAnchor),
                title.leadingAnchor.constraint(equalTo: leadingAnchor),
                valueField.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
                valueField.trailingAnchor.constraint(equalTo: trailingAnchor),
                valueField.widthAnchor.constraint(equalToConstant: 64),
                valueField.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8),
                slider.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
                slider.leadingAnchor.constraint(equalTo: leadingAnchor),
                slider.trailingAnchor.constraint(equalTo: trailingAnchor),
                slider.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            setValue(0)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        /// Shows a value without reporting a change.
        func setValue(_ value: Double) {
            slider.doubleValue = value
            if valueField.currentEditor() == nil { valueField.stringValue = key.format(value) }
        }

        @objc private func sliderMoved() {
            let raw = slider.doubleValue
            onChange?(key == .exposure ? (raw * 100).rounded() / 100 : raw.rounded())
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            if let value = Adjustments.Key.parse(valueField.stringValue) {
                valueField.stringValue = key.format(value)
                onChange?(value)
            } else {
                valueField.stringValue = key.format(slider.doubleValue)
            }
        }
    }

    /// A slider that resets to zero on double-click.
    final class ResettableSlider: NSSlider {
        var onReset: (() -> Void)?

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { onReset?(); return }
            super.mouseDown(with: event)
        }
    }
}

extension ImageEditors.AdjustEditorView {
    /// An editor with its preview rendered synchronously, for `--snapshot adjust`.
    static func snapshot(source: ImageEditors.SourceImage, options: ToolOptions) throws -> ImageEditors.AdjustEditorView {
        let view = ImageEditors.AdjustEditorView(source: source, loadAsync: false)
        view.setValues(try ImageEditors.Adjustments(options: options), showOriginal: options.bool("original", false))
        view.renderPreviewNow()
        return view
    }
}
