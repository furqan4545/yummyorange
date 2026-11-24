import AppKit

/// Image editors with a live preview: adjust (exposure, contrast and more) and annotate.
///
/// Both petals sit on the Tools (⌘) wheel for images. In the app each opens one editor window per
/// image (at most `maxWindows` from one drop); on the command line `run` applies the same edit from
/// options. The code is spread over files that start with "ImageEditor":
/// - ImageEditorIO.swift: opening images (EXIF orientation, preview proxies) and saving copies like the source.
/// - ImageEditorAdjust.swift: the adjustment values and their Core Image pipeline.
/// - ImageEditorAdjustView.swift: the Adjust window.
/// - ImageEditorAnnotation.swift: the annotation model, its JSON schema and the renderer.
/// - ImageEditorAnnotateView.swift: the Annotate window, its toolbar and color buttons.
/// - ImageEditorCanvas.swift: the Annotate canvas (drawing, selecting, moving, text, undo).
/// - ImageEditorWindow.swift: the shared window, bars and small controls.
/// - ImageEditorTests.swift: `--selftest image-editors` (also `adjust` and `annotate`).
enum ImageEditors: FeatureModule {
    /// Most editor windows one drop opens.
    static let maxWindows = 5

    static var commands: [WheelCommand] {
        [
            WheelCommand(wheel: .tools, id: "adjust", title: "Adjust…", symbol: "slider.horizontal.3",
                         applies: isImages,
                         present: { EditorWindowController.open(.adjust, files: $0) },
                         run: { files, options, progress in
                             try eachFile(files, progress) { try Adjustments.save($0, options: options) }
                         }),
            WheelCommand(wheel: .tools, id: "annotate", title: "Annotate…", symbol: "pencil.tip.crop.circle",
                         applies: isImages,
                         present: { EditorWindowController.open(.annotate, files: $0) },
                         run: { files, options, progress in
                             try eachFile(files, progress) { try AnnotationRenderer.save($0, options: options) }
                         }),
        ]
    }

    /// Every file is an image (folders and PDFs aren't). Cheap: it only looks at the file type.
    static func isImages(_ files: [URL]) -> Bool {
        !files.isEmpty && files.allSatisfy { FileKind.of($0) == .image }
    }

    private static func eachFile(_ files: [URL], _ progress: @escaping (Double) -> Void,
                                 _ body: (URL) throws -> URL) throws -> [URL] {
        var outputs: [URL] = []
        for (i, url) in files.enumerated() {
            outputs.append(try body(url))
            progress(Double(i + 1) / Double(files.count))
        }
        return outputs
    }

    // MARK: Snapshots and self-tests

    /// `--snapshot adjust|annotate <out.png> [image] [--opt k=v]...`
    /// adjust: any slider key (exposure=0.8, warmth=30, …), original=true for the before view.
    /// annotate: annotations=<JSON>, tool=<arrow|line|rect|ellipse|pen|highlight|text|select>, selected=<index>,
    /// color=#RRGGBB, size=0…3. Both: width= and height= for the content size, dark=true for dark mode,
    /// window=false for the content without the window and its toolbar.
    static func snapshot(_ id: String, files: [URL], options: ToolOptions) -> NSView? {
        guard id == "adjust" || id == "annotate" else { return nil }
        do {
            let url = try files.first ?? TestImages.sample()
            let source = try SourceImage(url)
            // View size in points, kept to a sane range (a huge or non-finite size would make AppKit throw).
            func side(_ key: String, _ fallback: Double) -> CGFloat {
                let v = options.double(key, fallback)
                return CGFloat(v.isFinite ? min(max(v, 200), 4000) : fallback)
            }
            let size = CGSize(width: side("width", 1100), height: side("height", 720))
            let view: EditorRootView = id == "adjust"
                ? try AdjustEditorView.snapshot(source: source, options: options)
                : try AnnotateEditorView.snapshot(source: source, options: options)
            view.frame = CGRect(origin: .zero, size: size)
            // The whole window with its toolbar (where Save lives); window=false gives the content alone.
            guard options.bool("window", true) else { return view }
            return windowSnapshot(view, url: url, subtitle: id == "adjust" ? "Adjust" : "Annotate", size: size,
                                  dark: options.bool("dark", false))
        } catch {
            let label = NSTextField(wrappingLabelWithString: "Snapshot failed: \(error.localizedDescription)")
            label.frame = CGRect(x: 0, y: 0, width: 600, height: 80)
            return label
        }
    }

    static func selfTest(_ name: String) -> String? {
        #if DEBUG
        switch name {
        case "image-editors", "imageeditors": return EditorTests.run(adjust: true, annotate: true)
        case "adjust": return EditorTests.run(adjust: true, annotate: false)
        case "annotate": return EditorTests.run(adjust: false, annotate: true)
        default: return nil
        }
        #else
        return nil
        #endif
    }
}
