import AppKit

/// The Float shelf and the first-run welcome tour with a practice wheel.
enum ShelfAndWelcome: FeatureModule {
    static var commands: [WheelCommand] {
        [
            WheelCommand(wheel: .actions, id: "float", title: "Float", symbol: "square.stack.3d.up",
                         combinesInputs: true, applies: { !$0.isEmpty },
                         present: { urls in ShelfManager.shared.open(urls) },
                         run: { urls, options, _ in try float(urls, options: options) }),
        ]
    }

    /// Headless Float. In the app it opens a shelf near the pointer; on the command line there is no screen to
    /// float on, so it checks the files and says what the shelf would hold. Either way it writes no files.
    /// Options: view=stack|list (default: the last view used).
    static func float(_ urls: [URL], options: ToolOptions) throws -> [URL] {
        let model = ShelfModel()
        let result = model.add(urls)
        guard !model.isEmpty else {
            throw ConversionError.unsupported(urls.count == 1 ? "Couldn’t find \(urls[0].lastPathComponent), so there’s nothing to float."
                                                              : "Couldn’t find any of these files, so there’s nothing to float.")
        }
        let mode = ShelfViewMode(rawValue: options.string("view", ShelfViewMode.last.rawValue).lowercased()) ?? .stack
        let inApp = MainThread.sync { NSApp.activationPolicy() != .prohibited }
        if inApp {
            MainThread.sync { _ = ShelfManager.shared.open(model.urls, mode: mode) }
        } else {
            var note = "Float: \(model.summary) on a \(mode.rawValue) shelf"
            if result.duplicates > 0 { note += ", \(result.duplicates) duplicate\(result.duplicates == 1 ? "" : "s") skipped" }
            if result.missing > 0 { note += ", \(result.missing) missing" }
            FileHandle.standardError.write((note + ". Shelves open only in the app.\n").data(using: .utf8)!)
        }
        return []
    }

    /// First launch: the welcome tour, once (a flag in UserDefaults), after the menu-bar icon has appeared.
    /// DW_SELFCHECK_WELCOME=<page>[:<state>] opens it on a page instead (see `WelcomeTour.runSelfCheckHook`).
    static func appDidLaunch() {
        if WelcomeTour.runSelfCheckHook() { return }
        guard WelcomeTour.shouldShowOnLaunch() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { WelcomeTour.show() }
    }

    static func menuItems() -> [NSMenuItem] {
        let shelf = NSMenuItem(title: "New Shelf", action: #selector(ShelfMenuTarget.newShelf), keyEquivalent: "")
        shelf.target = ShelfMenuTarget.shared
        let tour = NSMenuItem(title: "Welcome Tour…", action: #selector(ShelfMenuTarget.welcomeTour), keyEquivalent: "")
        tour.target = ShelfMenuTarget.shared
        return [shelf, tour]
    }

    static func snapshot(_ id: String, files: [URL], options: ToolOptions) -> NSView? {
        switch id {
        case "shelf": return shelfSnapshot(files: files, options: options)
        case "welcome":
            // `--snapshot welcome out.png --opt page=1...7|welcome|demo|convert|tools|actions|saved|setup`
            // [--opt state=drag|shortcut|drop|done, or drop-tools, done-actions…] (state: demo page)
            // [--opt convert=off tools=command style=metallic results=finder ...]: settings for this snapshot only (nothing is saved).
            if options["style"] != nil || ResultsDestination.parse(options) != nil
                || WheelMode.allCases.contains(where: { options[$0.rawValue.lowercased()] != nil }) {
                AppShell.useSnapshotSettings(options)
            }
            let page = WelcomePage.parse(options.string("page", "1")) ?? .welcome
            return WelcomeTour.snapshotView(page: page, demoState: options["state"])
        default: return nil
        }
    }

    /// `--snapshot shelf out.png [files] --opt view=stack|list --opt edge=left,top --opt drop=3 --opt select=1,2`
    private static func shelfSnapshot(files: [URL], options: ToolOptions) -> NSView {
        let mode = ShelfViewMode(rawValue: options.string("view", "stack").lowercased()) ?? .stack
        let model = ShelfModel(files)
        ShelfThumbnails.preload(Array(model.urls.suffix(8)), size: ShelfStyle.thumbnailSize)
        let view = ShelfView(model: model, mode: mode)
        view.docked = ShelfGeometry.Edges(names: options.string("edge", ""))
        if options["drop"] != nil { view.showDropHighlight(max(1, options.int("drop", 1))) }
        let rows = options.string("select", "").split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        if !rows.isEmpty { view.table.selectRowIndexes(IndexSet(rows.map { $0 - 1 }.filter { $0 >= 0 }), byExtendingSelection: false) }
        view.setFrameSize(view.preferredSize)
        return view
    }

    static func selfTest(_ name: String) -> String? {
        #if DEBUG
        switch name {
        case "shelf": return ShelfAndWelcomeTests.shelf()
        case "welcome": return WelcomeTests.run()
        default: return nil
        }
        #else
        return nil
        #endif
    }
}

/// Target for the menu-bar items (menu items hold their target weakly, so it lives here for good).
final class ShelfMenuTarget: NSObject {
    static let shared = ShelfMenuTarget()

    /// An empty shelf near the menu-bar icon (where the pointer is when the menu item is chosen).
    @objc func newShelf() { ShelfManager.shared.open([]) }

    @objc func welcomeTour() { WelcomeTour.show() }
}
