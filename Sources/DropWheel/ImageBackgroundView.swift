import AppKit
import UniformTypeIdentifiers

extension ImageEditors {
    /// The Add Background window: a live preview of the result on the left and an inspector on the right — the
    /// Mac's wallpapers, soft gradients, colours and any picture as the background, sliders for padding, corner
    /// radius and shadow, the canvas shape and (macOS 14 and later) Remove photo’s own background. Reset and Save sit in the
    /// toolbar. The preview is drawn by `ImageBackground.compose`, the code that writes the file, so what you see
    /// is what Save makes. Save runs the Add Background command with the window's options.
    final class BackgroundEditorView: EditorRootView {
        static let proxyPixels = 1600
        static let inspectorWidth: CGFloat = 312
        /// Where the window's last saved choices are kept (a new key: the old form's answers don't carry over).
        static let defaultsKey = "ImageExtras.background-window"

        /// What a fresh window starts with: the first gradient, some padding, rounded corners and a soft shadow,
        /// so the first preview already looks finished.
        static let starter: ImageBackground.Style = {
            var s = ImageBackground.Style()
            s.fill = .gradient(ImageBackground.gradients[0])
            s.padding = 10
            s.corners = 4
            s.shadow = 40
            return s
        }()

        let source: SourceImage
        let preview = BackgroundPreview()
        let statusBar = StatusBar()
        private let async: Bool
        private(set) var style: ImageBackground.Style
        private let initial: ImageBackground.Style

        private var picture: CGImage?
        private var lifted: CGImage?
        private var isLifting = false
        private var pictureIsTransparent = false
        private var backgrounds: [URL: CGImage] = [:]
        private var loadingBackgrounds = Set<URL>()
        private var errorText: String?
        /// A plain note for the status bar (not an error): why Remove photo’s own background turned itself off.
        private var noteText: String?

        private var swatches: [Swatch] = []
        private var wallpaperGrid = NSGridView()
        private let wallpaperBox = NSStackView()
        private let colorPicker = Swatch(fill: nil, name: "Other Color…")
        private let paddingSlider = NSSlider(), cornersSlider = NSSlider(), shadowSlider = NSSlider()
        private let paddingValue = Style.label(""), cornersValue = Style.label(""), shadowValue = Style.label("")
        private let ratioControl = NSSegmentedControl()
        private let liftBox = NSButton(checkboxWithTitle: "Remove photo’s own background", target: nil, action: nil)
        private var resetItem: NSToolbarItem!
        private var saveItem: NSToolbarItem!
        private var customImage: URL?
        /// This window is the colour panel's target (it is shared by the whole app).
        private var ownsColorPanel = false

        private let renderQueue = DispatchQueue(label: "YummyOrange.background-preview", qos: .userInteractive)
        private var isRendering = false
        private var needsAnotherRender = false
        private var isClosed = false

        /// Set when Save handed the job to the runner, so the window can close.
        private(set) var savedOptions: ToolOptions?
        /// Tests: receives Save's options instead of the job runner.
        var saveHandler: ((ToolOptions) -> Void)?

        override var minimumSize: CGSize { CGSize(width: 820, height: 560) }

        init(source: SourceImage, style startStyle: ImageBackground.Style? = nil, loadAsync: Bool = true) {
            self.source = source
            async = loadAsync
            let start = startStyle ?? Self.remembered()
            style = start
            initial = start
            if case .image(let url) = start.fill, !Self.isWallpaper(url) { customImage = url }
            super.init(frame: CGRect(x: 0, y: 0, width: 1100, height: 720))
            buildToolbarItems()
            let inspector = buildInspector()
            for view in [preview, inspector, statusBar] as [NSView] {
                view.translatesAutoresizingMaskIntoConstraints = false
                addSubview(view)
            }
            NSLayoutConstraint.activate([
                preview.topAnchor.constraint(equalTo: topAnchor),
                preview.leadingAnchor.constraint(equalTo: leadingAnchor),
                preview.trailingAnchor.constraint(equalTo: inspector.leadingAnchor),
                preview.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
                inspector.topAnchor.constraint(equalTo: topAnchor),
                inspector.trailingAnchor.constraint(equalTo: trailingAnchor),
                inspector.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
                inspector.widthAnchor.constraint(equalToConstant: Self.inspectorWidth),
                statusBar.leadingAnchor.constraint(equalTo: leadingAnchor),
                statusBar.trailingAnchor.constraint(equalTo: trailingAnchor),
                statusBar.bottomAnchor.constraint(equalTo: bottomAnchor),
                statusBar.heightAnchor.constraint(equalToConstant: StatusBar.height),
            ])
            preview.onResize = { [weak self] in self?.scheduleRender() }
            preview.canvasSize = layout.canvas
            if style.lift && !ImageBackground.canLift { style.lift = false }
            syncControls()
            loadPicture()
            loadWallpapers()
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        // MARK: Remembering

        static func remembered() -> ImageBackground.Style {
            guard let saved = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String],
                  let style = try? ImageBackground.style(saved) else { return starter }
            return style
        }

        private static func remember(_ style: ImageBackground.Style) {
            UserDefaults.standard.set(style.options, forKey: defaultsKey)
        }

        private static func isWallpaper(_ url: URL) -> Bool {
            url.path.hasPrefix(ImageBackground.wallpaperFolder.path)
        }

        // MARK: Toolbar

        private func buildToolbarItems() {
            resetItem = Bar.text("reset", "Reset", tip: "Back to the settings this window opened with", target: self,
                                 action: #selector(resetClicked))
            saveItem = Bar.save(target: self, action: #selector(saveClicked), tip: "Save a copy with the background next to the original (⌘S)")
        }

        override func makeToolbarItems() -> [NSToolbarItem] { [Bar.flexibleSpace(), resetItem, Bar.space(), saveItem] }

        // MARK: Inspector

        private func buildInspector() -> NSView {
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 8
            stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 20, right: 20)

            // Wallpapers: filled in when they've been found; the last cell picks any picture.
            wallpaperBox.orientation = .vertical
            wallpaperBox.alignment = .leading
            stack.addArrangedSubview(header("Wallpaper"))
            stack.addArrangedSubview(wallpaperBox)
            rebuildWallpapers([])
            stack.setCustomSpacing(18, after: wallpaperBox)

            stack.addArrangedSubview(header("Gradient"))
            let gradientSwatches = ImageBackground.gradients.map { g -> Swatch in
                let s = Swatch(fill: .gradient(g), name: "\(g.name) gradient")
                s.drawing = .gradient(g)
                return s
            }
            let gradientGrid = grid(gradientSwatches)
            stack.addArrangedSubview(gradientGrid)
            stack.setCustomSpacing(18, after: gradientGrid)

            stack.addArrangedSubview(header("Color"))
            let presets: [(String, String)] = [("#FFFFFF", "White"), ("#F2F2F7", "Light Gray"), ("#1C1C1E", "Graphite"),
                                               ("#000000", "Black"), ("#FFD60A", "Yellow"), ("#FF9F0A", "Orange"),
                                               ("#FF6B6B", "Coral"), ("#34C759", "Green"), ("#12A594", "Teal"),
                                               ("#2F6FED", "Blue"), ("#7C4DDB", "Purple")]
            var colorCells: [NSView] = presets.compactMap { hex, name in
                guard let c = NSColor(hex: hex) else { return nil }
                let s = Swatch(fill: .color(c), name: name)
                s.drawing = .color(c)
                return s
            }
            // Any other colour, from the system colour picker (color-wells.md: use the system picker).
            colorPicker.isPicker = true
            colorPicker.drawing = .picker(nil)
            colorPicker.toolTip = "Any color, from the color picker"
            colorCells.append(colorPicker)
            let colorGrid = grid(colorCells)
            stack.addArrangedSubview(colorGrid)

            let divider = FillView(color: Style.hairline)
            divider.translatesAutoresizingMaskIntoConstraints = false
            divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
            stack.addArrangedSubview(divider)
            divider.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
            stack.setCustomSpacing(20, after: colorGrid)
            stack.setCustomSpacing(16, after: divider)

            // Padding, corners and shadow: label, slider, exact value (sliders.md: show the value).
            func slider(_ s: NSSlider, max: Double, label: String) {
                s.minValue = 0
                s.maxValue = max
                s.isContinuous = true
                s.controlSize = .regular
                s.target = self
                s.action = #selector(sliderMoved(_:))
                s.setAccessibilityLabel(label)
            }
            slider(paddingSlider, max: ImageBackground.maxPadding, label: "Padding")
            slider(cornersSlider, max: ImageBackground.maxCorners, label: "Corners")
            slider(shadowSlider, max: ImageBackground.maxShadow, label: "Shadow")
            for v in [paddingValue, cornersValue, shadowValue] {
                v.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
                v.textColor = .secondaryLabelColor
                v.alignment = .right
            }
            paddingSlider.toolTip = "Space around the picture, in % of its long side"
            cornersSlider.toolTip = "Corner radius, in % of the picture’s short side"
            shadowSlider.toolTip = "How strong the drop shadow under the picture is"
            let sliders = NSGridView(views: [
                [Style.label("Padding"), paddingSlider, paddingValue],
                [Style.label("Corners"), cornersSlider, cornersValue],
                [Style.label("Shadow"), shadowSlider, shadowValue],
            ])
            sliders.rowSpacing = 10
            sliders.columnSpacing = 10
            sliders.column(at: 0).width = 58
            sliders.column(at: 2).width = 38
            sliders.column(at: 2).xPlacement = .trailing
            for r in 0..<sliders.numberOfRows { sliders.row(at: r).yPlacement = .center }
            stack.addArrangedSubview(sliders)
            sliders.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
            stack.setCustomSpacing(18, after: sliders)

            stack.addArrangedSubview(header("Ratio"))
            let shapes = ImageBackground.Canvas.allCases
            ratioControl.segmentCount = shapes.count
            for (i, c) in shapes.enumerated() {
                ratioControl.setLabel(c.shortTitle, forSegment: i)
                ratioControl.setToolTip(c == .original ? "The picture’s own shape" : "A \(c.rawValue) canvas", forSegment: i)
            }
            ratioControl.trackingMode = .selectOne
            ratioControl.segmentDistribution = .fillEqually
            ratioControl.target = self
            ratioControl.action = #selector(ratioChosen)
            ratioControl.setAccessibilityLabel("Canvas ratio")
            stack.addArrangedSubview(ratioControl)
            ratioControl.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true

            if ImageBackground.canLift {
                liftBox.target = self
                liftBox.action = #selector(liftToggled)
                liftBox.toolTip = "Cuts the person, pet or object out of the photo, so only it sits on the new background"
                stack.setCustomSpacing(16, after: ratioControl)
                stack.addArrangedSubview(liftBox)
                // What it does, under the checkbox, lined up with its title.
                let note = Style.label("Cuts out the person, pet or object so only it sits on the new background. "
                                       + "For photos, not documents.", size: 11, color: .secondaryLabelColor)
                note.lineBreakMode = .byWordWrapping
                note.maximumNumberOfLines = 0
                note.preferredMaxLayoutWidth = Self.inspectorWidth - 40 - 20
                stack.setCustomSpacing(2, after: liftBox)
                let indent = NSStackView(views: [note])
                indent.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
                stack.addArrangedSubview(indent)
            }

            let document = FlippedView()
            stack.translatesAutoresizingMaskIntoConstraints = false
            document.addSubview(stack)
            document.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: document.topAnchor),
                stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
                stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            ])
            let scroll = NSScrollView()
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.documentView = document
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor).isActive = true

            let panel = FillView(color: Style.chrome, hairlines: .minX)
            scroll.translatesAutoresizingMaskIntoConstraints = false
            panel.addSubview(scroll)
            NSLayoutConstraint.activate([
                scroll.topAnchor.constraint(equalTo: panel.topAnchor),
                scroll.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 1),
                scroll.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
                scroll.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            ])
            swatches += gradientSwatches + colorCells.compactMap { $0 as? Swatch }
            return panel
        }

        private func header(_ text: String) -> NSTextField {
            Style.label(text, size: 12, weight: .semibold, color: .secondaryLabelColor)
        }

        /// Swatches in rows of six.
        private func grid(_ cells: [NSView]) -> NSGridView {
            var rows: [[NSView]] = []
            for start in stride(from: 0, to: cells.count, by: Swatch.perRow) {
                var row = Array(cells[start..<min(start + Swatch.perRow, cells.count)])
                while row.count < Swatch.perRow { row.append(NSGridCell.emptyContentView) }
                rows.append(row)
            }
            let grid = NSGridView(views: rows)
            grid.rowSpacing = Swatch.gap
            grid.columnSpacing = Swatch.gap
            for i in 0..<grid.numberOfColumns {
                grid.column(at: i).width = Swatch.side
                grid.column(at: i).xPlacement = .center
            }
            for i in 0..<grid.numberOfRows { grid.row(at: i).yPlacement = .center }
            for cell in cells where cell is Swatch {
                (cell as? Swatch)?.target = self
                (cell as? Swatch)?.action = #selector(swatchClicked(_:))
            }
            return grid
        }

        /// The wallpaper swatches: a custom picture first when there is one, then the Mac's, then Choose.
        private func rebuildWallpapers(_ wallpapers: [ImageBackground.Wallpaper]) {
            swatches.removeAll { if case .image = $0.fill { return true }; return $0.fill == nil && !$0.isPicker }
            wallpaperBox.arrangedSubviews.forEach { $0.removeFromSuperview() }
            var cells: [Swatch] = []
            if let customImage {
                let s = Swatch(fill: .image(customImage), name: customImage.deletingPathExtension().lastPathComponent)
                loadThumbnail(for: s, url: customImage, thumbnail: nil)
                cells.append(s)
            }
            for w in wallpapers.prefix(Swatch.perRow * 2 - cells.count - 1) {
                let s = Swatch(fill: .image(w.url), name: w.name)
                loadThumbnail(for: s, url: w.url, thumbnail: w.thumbnail)
                cells.append(s)
            }
            let choose = Swatch(fill: nil, name: "Choose Image…")
            choose.drawing = .add
            choose.toolTip = "Use any picture as the background"
            cells.append(choose)
            wallpaperGrid = grid(cells)
            wallpaperBox.addArrangedSubview(wallpaperGrid)
            swatches += cells
            syncSwatches()
        }

        private func loadWallpapers() {
            let finish: ([ImageBackground.Wallpaper]) -> Void = { [weak self] found in
                guard let self, !self.isClosed else { return }
                self.rebuildWallpapers(found)
            }
            if async {
                DispatchQueue.global(qos: .userInitiated).async {
                    let found = ImageBackground.wallpapers()
                    DispatchQueue.main.async { finish(found) }
                }
            } else {
                finish(ImageBackground.wallpapers())
            }
        }

        private func loadThumbnail(for swatch: Swatch, url: URL, thumbnail: URL?) {
            let load = { () -> CGImage? in
                (thumbnail.flatMap { try? ImageBackground.loadPicture($0, maxPixels: 160) })
                    ?? (try? ImageBackground.loadPicture(url, maxPixels: 160))
            }
            if async {
                DispatchQueue.global(qos: .userInitiated).async {
                    let image = load()
                    DispatchQueue.main.async { swatch.drawing = .image(image) }
                }
            } else {
                swatch.drawing = .image(load())
            }
        }

        // MARK: State → controls

        private var layout: ImageBackground.Layout {
            ImageBackground.layout(width: Int(source.size.width), height: Int(source.size.height), style: style)
        }

        private func syncControls() {
            paddingSlider.doubleValue = style.padding
            cornersSlider.doubleValue = style.corners
            shadowSlider.doubleValue = style.shadow
            paddingValue.stringValue = "\(Int(style.padding.rounded()))%"
            cornersValue.stringValue = "\(Int(style.corners.rounded()))%"
            shadowValue.stringValue = "\(Int(style.shadow.rounded()))%"
            ratioControl.selectedSegment = ImageBackground.Canvas.allCases.firstIndex(of: style.canvas) ?? 0
            liftBox.state = style.lift ? .on : .off
            syncSwatches()
            Bar.enable(resetItem, style != initial)
            Bar.enable(saveItem, canSave)
            let l = layout
            statusBar.trailing.stringValue = "\(Int(l.canvas.width)) × \(Int(l.canvas.height)) px  ·  from \(source.summary)"
            if let errorText {
                statusBar.leading.stringValue = errorText
                statusBar.leading.textColor = .systemRed
            } else if let noteText {
                statusBar.leading.textColor = .secondaryLabelColor
                statusBar.leading.stringValue = noteText
            } else {
                statusBar.leading.textColor = .secondaryLabelColor
                statusBar.leading.stringValue = isLifting ? "Cutting out the subject…"
                    : !hasSomethingToFill ? "This picture has no see-through parts. Add padding, round the corners or pick a ratio."
                    : "Pick a background, then set the padding, corners and shadow. Return saves."
            }
            if isLifting { statusBar.spinner.startAnimation(nil) } else { statusBar.spinner.stopAnimation(nil) }
        }

        private func syncSwatches() {
            for s in swatches { s.isChosen = s.fill.map { $0 == style.fill } ?? false }
            // The picker is chosen for a colour none of the tiles has, and shows it in its middle.
            if case .color(let c) = style.fill, !swatches.contains(where: { $0.isChosen }) {
                colorPicker.isChosen = true
                colorPicker.drawing = .picker(c)
            } else {
                colorPicker.isChosen = false
                colorPicker.drawing = .picker(nil)
            }
        }

        /// The same test the command makes before it refuses ("no see-through pixels to fill").
        private var hasSomethingToFill: Bool {
            picture == nil || pictureIsTransparent || style.lift || style.canvas != .original || style.padding > 0 || style.corners > 0
        }

        private var canSave: Bool { picture != nil && hasSomethingToFill && !isLifting }

        private func setStyle(_ change: (inout ImageBackground.Style) -> Void) {
            var s = style
            change(&s)
            guard s != style else { return }
            style = s
            errorText = nil
            noteText = nil
            preview.canvasSize = layout.canvas
            syncControls()
            scheduleRender()
        }

        // MARK: Actions

        @objc private func swatchClicked(_ sender: Swatch) {
            if sender.isPicker { showColorPanel(); return }
            guard let fill = sender.fill else { chooseImage(); return }
            setStyle { $0.fill = fill }
        }

        private func showColorPanel() {
            let panel = NSColorPanel.shared
            panel.setTarget(nil)
            panel.showsAlpha = true
            panel.isContinuous = true
            if case .color(let c) = style.fill { panel.color = c }
            panel.setTarget(self)
            panel.setAction(#selector(colorPanelChanged(_:)))
            ownsColorPanel = true
            panel.orderFront(nil)
        }

        @objc private func colorPanelChanged(_ sender: NSColorPanel) {
            let c = sender.color.usingColorSpace(.sRGB) ?? sender.color
            setStyle { $0.fill = .color(c) }
        }

        @objc private func sliderMoved(_ sender: NSSlider) {
            // Whole steps: the readout and the saved options say the same number.
            let v = sender.doubleValue.rounded()
            setStyle {
                if sender === paddingSlider { $0.padding = v }
                else if sender === cornersSlider { $0.corners = v }
                else { $0.shadow = v }
            }
        }

        @objc private func ratioChosen() {
            let all = ImageBackground.Canvas.allCases
            guard ratioControl.selectedSegment >= 0, ratioControl.selectedSegment < all.count else { return }
            setStyle { $0.canvas = all[ratioControl.selectedSegment] }
        }

        @objc private func liftToggled() {
            let on = liftBox.state == .on
            setStyle { $0.lift = on }
            if on && lifted == nil { liftPicture() }
        }

        @objc private func resetClicked() {
            style = initial
            errorText = nil
            noteText = nil
            preview.canvasSize = layout.canvas
            syncControls()
            scheduleRender()
        }

        @objc private func saveClicked() { requestSave() }

        private func chooseImage() {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.image]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.message = "Choose a picture to put behind \(source.url.lastPathComponent)."
            panel.prompt = "Use Picture"
            let use: (URL) -> Void = { [weak self] url in
                guard let self else { return }
                self.customImage = url
                self.rebuildWallpapers(ImageBackground.wallpapers())
                self.setStyle { $0.fill = .image(url) }
            }
            if let window {
                panel.beginSheetModal(for: window) { if $0 == .OK, let url = panel.url { use(url) } }
            } else if panel.runModal() == .OK, let url = panel.url {
                use(url)
            }
        }

        // MARK: Loading and rendering

        private func loadPicture() {
            preview.isLoading = true
            let source = self.source
            let work = { () -> Result<(CGImage, Bool), Error> in
                Result {
                    let image = try source.proxy(maxPixels: Self.proxyPixels)
                    return (image, ImageExtras.isTransparent(image))
                }
            }
            let finish: (Result<(CGImage, Bool), Error>) -> Void = { [weak self] result in
                guard let self, !self.isClosed else { return }
                self.preview.isLoading = false
                switch result {
                case .success(let (image, clear)):
                    self.picture = image
                    self.pictureIsTransparent = clear
                    if self.style.lift { self.liftPicture() }
                case .failure(let error):
                    self.errorText = error.localizedDescription
                }
                self.syncControls()
                self.scheduleRender()
            }
            if async {
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = work()
                    DispatchQueue.main.async { finish(result) }
                }
            } else {
                finish(work())
            }
        }

        private func liftPicture() {
            guard let picture, !isLifting else { return }
            guard #available(macOS 14.0, *) else { return }
            isLifting = true
            syncControls()
            let name = source.url.lastPathComponent
            let work = { Result { try ImageBackground.liftSubject(picture, name: name) } }
            let finish: (Result<CGImage, Error>) -> Void = { [weak self] result in
                guard let self, !self.isClosed else { return }
                self.isLifting = false
                switch result {
                case .success(let image): self.lifted = image
                case .failure(let error):
                    self.style.lift = false
                    _ = error
                    self.noteText = "No person, pet or object to cut out here, so the picture stays as it is."
                }
                self.syncControls()
                self.scheduleRender()
            }
            if async {
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = work()
                    DispatchQueue.main.async { finish(result) }
                }
            } else {
                finish(work())
            }
        }

        /// Draws the preview off the main thread, one at a time; changes made meanwhile get one more pass.
        private func scheduleRender() {
            guard let base = picture else { return }
            let target = preview.pixelTarget
            guard target.width >= 8, target.height >= 8 else { return }
            var background: CGImage?
            if case .image(let url) = style.fill {
                guard let decoded = backgrounds[url] else { loadBackground(url); return }
                background = decoded
            }
            if isRendering { needsAnotherRender = true; return }
            let image = style.lift ? (lifted ?? base) : base
            let style = self.style, size = source.size
            let work = { BackgroundPreview.render(image, pictureSize: size, style: style, background: background, target: target) }
            let finish: (CGImage?) -> Void = { [weak self] rendered in
                guard let self, !self.isClosed else { return }
                self.isRendering = false
                self.preview.image = rendered
                if self.needsAnotherRender {
                    self.needsAnotherRender = false
                    self.scheduleRender()
                }
            }
            isRendering = true
            if async {
                renderQueue.async {
                    let rendered = work()
                    DispatchQueue.main.async { finish(rendered) }
                }
            } else {
                finish(work())
            }
        }

        private func loadBackground(_ url: URL) {
            guard !loadingBackgrounds.contains(url) else { return }
            loadingBackgrounds.insert(url)
            let work = { Result { try ImageBackground.loadPicture(url, maxPixels: Self.proxyPixels) } }
            let finish: (Result<CGImage, Error>) -> Void = { [weak self] result in
                guard let self, !self.isClosed else { return }
                self.loadingBackgrounds.remove(url)
                switch result {
                case .success(let image):
                    self.backgrounds[url] = image
                case .failure(let error):
                    self.errorText = error.localizedDescription
                    self.style.fill = Self.starter.fill
                    self.syncControls()
                }
                self.scheduleRender()
            }
            if async {
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = work()
                    DispatchQueue.main.async { finish(result) }
                }
            } else {
                finish(work())
            }
        }

        // MARK: Saving and closing

        override func didAppear() { window?.makeFirstResponder(nil) }

        /// Hands the job to the runner (the HUD shows progress and the result), remembers the choices and closes.
        override func requestSave() {
            guard canSave, let command = ImageCropRedact.command("background") else { NSSound.beep(); return }
            let options = style.options
            savedOptions = options
            Self.remember(style)
            if let saveHandler { saveHandler(options) } else { JobRunner.run(.command(command, options), on: [source.url]) }
            onFinish?(nil)
        }

        override var hasUnsavedChanges: Bool { style != initial }

        override func requestCancel() {
            guard style != initial, window != nil else { onFinish?(nil); return }
            confirmDiscard(detail: "The background for “\(source.url.lastPathComponent)” hasn’t been saved.") { [weak self] in
                self?.onFinish?(nil)
            }
        }

        override func tearDown() {
            isClosed = true
            picture = nil
            lifted = nil
            backgrounds = [:]
            preview.image = nil
            if ownsColorPanel, NSColorPanel.sharedColorPanelExists {
                NSColorPanel.shared.setTarget(nil)
                NSColorPanel.shared.setAction(nil)
                NSColorPanel.shared.orderOut(nil)
            }
        }

        override func handleKey(_ event: NSEvent) -> Bool {
            guard event.type == .keyDown else { return false }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if flags == .command && key == "s" { requestSave(); return true }
            if flags == .command && key == "w" { requestCancel(); return true }
            if window?.firstResponder is NSText { return false }
            if flags.isEmpty && (event.keyCode == 36 || event.keyCode == 76) { requestSave(); return true }   // Return, Enter
            return false
        }

        /// An editor with options applied, for `--snapshot background-image`.
        static func snapshot(source: SourceImage, options: ToolOptions) throws -> BackgroundEditorView {
            let keys = ["color", "gradient", "image", "canvas", "padding", "corners", "shadow", "lift"]
            let style = keys.contains { options[$0] != nil } ? try ImageBackground.style(options) : starter
            return BackgroundEditorView(source: source, style: style, loadAsync: false)
        }
    }

    // MARK: - Preview

    /// The result, fitted into the space left of the inspector on the editors' neutral backdrop.
    final class BackgroundPreview: NSView {
        var image: CGImage? { didSet { needsDisplay = true } }
        /// The result's size in pixels, which sets the shape drawn even before a render arrives.
        var canvasSize = CGSize(width: 1, height: 1) { didSet { if canvasSize != oldValue { needsDisplay = true } } }
        var onResize: (() -> Void)?
        var isLoading = false { didSet { isLoading ? spinner.startAnimation(nil) : spinner.stopAnimation(nil) } }
        private let spinner = NSProgressIndicator()
        private var lastSize = CGSize.zero
        static let margin: CGFloat = 36

        override init(frame: NSRect) {
            super.init(frame: frame)
            spinner.style = .spinning
            spinner.isDisplayedWhenStopped = false
            spinner.translatesAutoresizingMaskIntoConstraints = false
            addSubview(spinner)
            NSLayoutConstraint.activate([spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
                                         spinner.centerYAnchor.constraint(equalTo: centerYAnchor)])
            setAccessibilityElement(true)
            setAccessibilityRole(.image)
            setAccessibilityLabel("Preview of the picture with its background")
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override var isOpaque: Bool { true }

        /// Where the result is drawn, in points.
        var resultRect: CGRect {
            let area = bounds.insetBy(dx: Self.margin, dy: Self.margin)
            guard area.width > 0, area.height > 0, canvasSize.width > 0, canvasSize.height > 0 else { return .zero }
            let s = min(area.width / canvasSize.width, area.height / canvasSize.height)
            let w = (canvasSize.width * s).rounded(), h = (canvasSize.height * s).rounded()
            return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h).integral
        }

        /// The render size in pixels: the result's rectangle on this screen.
        var pixelTarget: CGSize {
            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            let r = resultRect
            return CGSize(width: r.width * scale, height: r.height * scale)
        }

        override func layout() {
            super.layout()
            if bounds.size != lastSize {
                lastSize = bounds.size
                onResize?()
            }
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            onResize?()
        }

        override func draw(_ dirtyRect: NSRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            effectiveAppearance.performAsCurrentDrawingAppearance {
                Style.canvas.setFill()
                dirtyRect.fill()
                let r = resultRect
                guard r.width > 0 else { return }
                // A checkerboard shows through a see-through colour.
                checkerboard(r, ctx: ctx)
                if let image {
                    ctx.saveGState()
                    ctx.interpolationQuality = .high
                    ctx.draw(image, in: r)
                    ctx.restoreGState()
                }
                Style.hairline.setStroke()
                let edge = NSBezierPath(rect: r.insetBy(dx: -0.5, dy: -0.5))
                edge.lineWidth = 1
                edge.stroke()
            }
        }

        private func checkerboard(_ r: CGRect, ctx: CGContext) {
            ctx.saveGState()
            ctx.clip(to: r)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(r)
            ctx.setFillColor(NSColor(white: 0.88, alpha: 1).cgColor)
            let step: CGFloat = 8
            var y = r.minY, row = 0
            while y < r.maxY {
                var x = r.minX + (row % 2 == 0 ? 0 : step)
                while x < r.maxX { ctx.fill(CGRect(x: x, y: y, width: step, height: step)); x += step * 2 }
                y += step
                row += 1
            }
            ctx.restoreGState()
        }

        /// The result at `target` pixels (aspect kept), drawn by the same code that writes the file.
        static func render(_ picture: CGImage, pictureSize: CGSize, style: ImageBackground.Style, background: CGImage?,
                           target: CGSize) -> CGImage? {
            let l = ImageBackground.layout(width: Int(pictureSize.width), height: Int(pictureSize.height), style: style)
            let s = min(target.width / l.canvas.width, target.height / l.canvas.height)
            let w = max(1, Int((l.canvas.width * s).rounded())), h = max(1, Int((l.canvas.height * s).rounded()))
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.interpolationQuality = .high
            ctx.scaleBy(x: CGFloat(w) / l.canvas.width, y: CGFloat(h) / l.canvas.height)
            ImageBackground.compose(picture, pictureSize: pictureSize, style: style, background: background, ctx: ctx,
                                    scale: CGFloat(w) / l.canvas.width)
            return ctx.makeImage()
        }
    }

    // MARK: - Swatch

    /// One background choice: a rounded tile showing the wallpaper, gradient or colour, ringed in the accent colour
    /// when chosen. A button, so it takes clicks, keyboard focus and VoiceOver like any other.
    final class Swatch: NSButton {
        static let side: CGFloat = 40
        static let gap: CGFloat = 6
        static let perRow = 6

        enum Drawing { case none, gradient(ImageBackground.Gradient), color(NSColor), image(CGImage?), add, picker(NSColor?) }

        /// What choosing it does; nil for “Choose Image…”.
        let fill: ImageBackground.Fill?
        /// The colour-picker tile (its fill is nil too, like Choose Image…).
        var isPicker = false
        var drawing: Drawing = .none { didSet { needsDisplay = true } }
        var isChosen = false {
            didSet {
                guard isChosen != oldValue else { return }
                needsDisplay = true
                setAccessibilityValue(isChosen ? "Selected" : nil)
            }
        }
        private var isHovered = false { didSet { needsDisplay = true } }

        init(fill: ImageBackground.Fill?, name: String) {
            self.fill = fill
            super.init(frame: CGRect(x: 0, y: 0, width: Self.side, height: Self.side))
            title = ""
            isBordered = false
            setButtonType(.momentaryChange)
            toolTip = name
            setAccessibilityLabel(name)
            translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: Self.side),
                                         heightAnchor.constraint(equalToConstant: Self.side)])
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override var isFlipped: Bool { false }
        override var intrinsicContentSize: NSSize { NSSize(width: Self.side, height: Self.side) }

        private var tile: CGRect { bounds.insetBy(dx: 4, dy: 4) }
        private static let radius: CGFloat = 8

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                           owner: self))
        }

        override func mouseEntered(with event: NSEvent) { isHovered = true }
        override func mouseExited(with event: NSEvent) { isHovered = false }

        override func draw(_ dirtyRect: NSRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let shape = CGPath(roundedRect: tile, cornerWidth: Self.radius, cornerHeight: Self.radius, transform: nil)
                ctx.saveGState()
                ctx.addPath(shape)
                ctx.clip()
                switch drawing {
                case .none:
                    NSColor.quaternaryLabelColor.setFill()
                    tile.fill()
                case .gradient(let g):
                    ImageBackground.paint(g, in: tile, ctx: ctx)
                case .color(let c):
                    ctx.setFillColor(c.cgColor)
                    ctx.fill(tile)
                case .image(let image):
                    if let image {
                        let iw = CGFloat(image.width), ih = CGFloat(image.height)
                        let s = max(tile.width / iw, tile.height / ih)
                        ctx.interpolationQuality = .high
                        ctx.draw(image, in: CGRect(x: tile.midX - iw * s / 2, y: tile.midY - ih * s / 2, width: iw * s, height: ih * s))
                    } else {
                        NSColor.quaternaryLabelColor.setFill()
                        tile.fill()
                    }
                case .picker(let chosen):
                    // A colour wheel, with the picked colour as a dot in the middle.
                    let c = CGPoint(x: tile.midX, y: tile.midY), r = hypot(tile.width, tile.height) / 2
                    let steps = 48
                    for i in 0..<steps {
                        let a0 = CGFloat(i) / CGFloat(steps) * 2 * .pi, a1 = CGFloat(i + 1) / CGFloat(steps) * 2 * .pi + 0.02
                        ctx.move(to: c)
                        ctx.addArc(center: c, radius: r, startAngle: a0, endAngle: a1, clockwise: false)
                        ctx.closePath()
                        ctx.setFillColor(NSColor(hue: CGFloat(i) / CGFloat(steps), saturation: 0.8, brightness: 1, alpha: 1).cgColor)
                        ctx.fillPath()
                    }
                    let inner = tile.insetBy(dx: 9, dy: 9)
                    ctx.setFillColor(NSColor.white.cgColor)
                    ctx.fillEllipse(in: inner.insetBy(dx: -2, dy: -2))
                    ctx.setFillColor((chosen ?? .white).cgColor)
                    ctx.fillEllipse(in: inner)
                    if chosen == nil {
                        ctx.setStrokeColor(NSColor(white: 0, alpha: 0.15).cgColor)
                        ctx.setLineWidth(1)
                        ctx.strokeEllipse(in: inner)
                    }
                case .add:
                    NSColor.quaternaryLabelColor.setFill()
                    tile.fill()
                    let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
                    if let symbol = NSImage(systemSymbolName: "photo.badge.plus", accessibilityDescription: nil)?
                        .withSymbolConfiguration(config) {
                        let tinted = NSImage(size: symbol.size, flipped: false) { r in
                            symbol.draw(in: r)
                            NSColor.secondaryLabelColor.set()
                            r.fill(using: .sourceAtop)
                            return true
                        }
                        let s = tinted.size
                        tinted.draw(in: CGRect(x: tile.midX - s.width / 2, y: tile.midY - s.height / 2, width: s.width, height: s.height))
                    }
                }
                ctx.restoreGState()
                // A hairline so white and pale tiles keep their edge.
                ctx.addPath(shape)
                ctx.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.12).cgColor)
                ctx.setLineWidth(1)
                ctx.strokePath()
                if isChosen || isHovered {
                    let ring = bounds.insetBy(dx: 1.25, dy: 1.25)
                    ctx.addPath(CGPath(roundedRect: ring, cornerWidth: Self.radius + 2.5, cornerHeight: Self.radius + 2.5, transform: nil))
                    ctx.setStrokeColor((isChosen ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).cgColor)
                    ctx.setLineWidth(2.5)
                    ctx.strokePath()
                }
            }
        }

        override var focusRingMaskBounds: NSRect { bounds }
        override func drawFocusRingMask() {
            NSBezierPath(roundedRect: tile, xRadius: Self.radius, yRadius: Self.radius).fill()
        }
    }

    /// A top-down container for the inspector's scroll view.
    final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }
}
