import AppKit
import SwiftUI

// Where a finished job's new files appear. Every job ends in `JobRunner.finish` (Jobs.swift): tools, conversions,
// Zip, Split's parts, Merge, Snapshot, and every editor's Save through `JobRunner.report(saved:)`. With the default
// setting each job's files open on a NEW shelf near the pointer (one job, one shelf); the other choices are the
// Clothesline (the files hang under the notch for a moment, Clothesline.swift), a Finder window (what YummyOrange did
// before) or nothing beyond the progress panel.
//
// Never from the command line: `--tool`, `--convert`, `--selftest` and `--snapshot` run with the activation policy
// .prohibited and no run loop. The Float petal opens its own shelf and returns no files, so it never adds a second.

// MARK: - The setting

/// Where a finished job's new files appear (Settings › General › Show new files, and the menu's Show New Files).
enum ResultsDestination: String, CaseIterable, Identifiable {
    /// A new shelf near the pointer holding exactly that job's files. The default.
    case shelf
    /// Hung on the string under the notch for a moment; the line pulls up into the notch and drops again when the
    /// pointer rests there.
    case clothesline
    /// Selected in a Finder window.
    case finder
    /// Nowhere; the files are saved next to the originals and the progress panel says so.
    case none

    var id: String { rawValue }

    /// The pop-up and menu item title (title-style, as macOS menu items are).
    var title: String {
        switch self {
        case .shelf: return "On a Shelf"
        case .clothesline: return "On the Clothesline"
        case .finder: return "In Finder"
        case .none: return "Don’t Show"
        }
    }

    /// One line under the setting, saying what the choice does.
    var detail: String {
        switch self {
        case .shelf: return "Each job’s files open on a new shelf, ready to drag."
        case .clothesline:
            return Self.hasNotch()
                ? "Each job’s files hang under the notch for a moment. Rest the pointer there to see them again."
                : "Each job’s files hang under the menu bar for a moment. Rest the pointer on the middle of the menu bar to see them again."
        case .finder: return "Each job’s files are selected in a Finder window."
        case .none: return "Nothing opens. Files are saved next to the originals."
        }
    }

    /// Whether the display the Clothesline hangs on has a camera housing (the line's own test); without one the line
    /// hangs from a zone at the middle of the menu bar. Self-tests swap it.
    static var hasNotch: () -> Bool = { ClotheslineGeometry.preferredScreen().map(ClotheslineGeometry.init(screen:))?.hasNotch ?? false }

    /// `--opt results=shelf|clothesline|finder|none`, or the older `--opt reveal=on|off` (on: In Finder, off: Don't Show).
    /// `results` wins when both are given; nil when neither names a choice.
    static func parse(_ options: ToolOptions) -> ResultsDestination? {
        if let raw = options["results"]?.trimmingCharacters(in: .whitespaces).lowercased(),
           let choice = ResultsDestination(rawValue: raw) { return choice }
        guard let reveal = options["reveal"]?.trimmingCharacters(in: .whitespaces).lowercased() else { return nil }
        if ["1", "true", "yes", "on"].contains(reveal) { return ResultsDestination.finder }
        if ["0", "false", "no", "off"].contains(reveal) { return ResultsDestination.none }
        return nil
    }
}

// MARK: - Showing a job's files

enum ResultsPresenter {
    /// What a finished job shows.
    enum Presentation: Equatable {
        case shelf([URL])
        case clothesline([URL])
        case finder([URL])
    }

    /// What `destination` shows for one job's `outputs`: those that exist, in the job's order, each once. nil when
    /// nothing opens: the job made no file, or the choice is Don't Show.
    static func presentation(for outputs: [URL], destination: ResultsDestination) -> Presentation? {
        var seen = Set<String>()
        let files = outputs.filter { url in
            url.isFileURL && FileManager.default.fileExists(atPath: url.path) && seen.insert(url.standardizedFileURL.path).inserted
        }
        guard !files.isEmpty else { return nil }
        switch destination {
        case .shelf: return .shelf(files)
        case .clothesline: return .clothesline(files)
        case .finder: return .finder(files)
        case .none: return nil
        }
    }

    /// Whether this process shows windows at all. False on the command line (`--tool`, `--selftest`, `--snapshot`),
    /// which runs with the activation policy .prohibited; true for the menu-bar app (.accessory).
    static var canPresent: () -> Bool = { NSApp.map { showsWindows($0.activationPolicy()) } ?? false }

    static func showsWindows(_ policy: NSApplication.ActivationPolicy) -> Bool { policy != .prohibited }

    /// Self-tests set this to see what would open, instead of a real shelf or Finder window.
    static var hook: ((Presentation) -> Void)?

    /// The three ways files are shown. Always a new shelf, never an older one: the panel Float opens, near the pointer,
    /// ordered in front regardless of which app is active, on every Space (so on the current one) and over
    /// full-screen apps, without taking focus from the app you're in. The Clothesline adds the files to its string
    /// (newest on the left) and drops it for 2 s, also without taking focus. Self-tests swap all three (with `hook`
    /// off) to check that each choice reaches its own one, without a real shelf, line or Finder window.
    static var openShelf: ([URL]) -> Void = { _ = ShelfManager.shared.open($0) }
    static var hangOnLine: ([URL]) -> Void = { Clothesline.shared.hang($0) }
    static var revealInFinder: ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }

    /// Main thread, when a job has finished: shows its new files where Settings says.
    static func present(_ outputs: [URL]) {
        guard canPresent(), let presentation = presentation(for: outputs, destination: Settings.resultsDestination) else { return }
        if let hook { hook(presentation); return }
        switch presentation {
        case .shelf(let files): openShelf(files)
        case .clothesline(let files): hangOnLine(files)
        case .finder(let files): revealInFinder(files)
        }
    }
}

// MARK: - Settings and menu controls

/// The Show New Files pop-up, for Settings and the welcome tour.
struct ResultsDestinationPicker<Label: View>: View {
    let selection: Binding<ResultsDestination>
    @ViewBuilder let label: () -> Label

    var body: some View {
        Picker(selection: selection) {
            ForEach(ResultsDestination.allCases) { Text($0.title).tag($0) }
        } label: {
            label()
        }
        .pickerStyle(.menu)
        .accessibilityLabel("Show new files")
    }
}

/// The menu bar's Show New Files submenu: On a Shelf, On the Clothesline, In Finder, Don't Show, with a checkmark on
/// the current one.
final class ResultsMenu: NSObject, NSMenuDelegate {
    /// Menu items hold their target weakly, so the target lives here for good.
    static let shared = ResultsMenu()
    static let title = "Show New Files"

    /// The "Show New Files" item with its submenu, checked for the current setting.
    func makeItem() -> NSMenuItem {
        let item = NSMenuItem(title: Self.title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: Self.title)
        for choice in ResultsDestination.allCases {
            let entry = NSMenuItem(title: choice.title, action: #selector(choose(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = choice.rawValue
            entry.toolTip = choice.detail
            menu.addItem(entry)
        }
        menu.delegate = self
        item.submenu = menu
        update(menu)
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) { update(menu) }

    /// Checks the current choice and unchecks the others. The explanations are set again each time, so On the
    /// Clothesline follows the displays (a notch appears when a MacBook's lid opens).
    func update(_ menu: NSMenu) {
        let current = Settings.resultsDestination.rawValue
        for entry in menu.items {
            let choice = (entry.representedObject as? String).flatMap(ResultsDestination.init(rawValue:))
            entry.state = choice?.rawValue == current ? .on : .off
            entry.toolTip = choice?.detail
        }
    }

    @objc func choose(_ sender: NSMenuItem) {
        guard let choice = (sender.representedObject as? String).flatMap(ResultsDestination.init(rawValue:)) else { return }
        Settings.resultsDestination = choice
        sender.menu.map(update)
    }
}

// MARK: - Module

/// No petals. `--selftest results-shelf`, and `--snapshot menu` (the menu-bar menu with Show New Files open).
enum ResultsShelf: FeatureModule {
    static var commands: [WheelCommand] { [] }

    /// `--snapshot menu <out.png> [--opt results=shelf|clothesline|finder|none] [--opt dark=true]`: the menu-bar menu as AppDelegate
    /// builds it, with the Show New Files submenu open. Menus are drawn by the window server, which can't render
    /// offscreen, so this draws the real menu's items (titles, checkmarks, submenu, shortcuts, disabled lines) in a
    /// menu-like panel. Settings options apply to this snapshot only; nothing is saved.
    static func snapshot(_ id: String, files: [URL], options: ToolOptions) -> NSView? {
        guard id == "menu" else { return nil }
        AppShell.useSnapshotSettings(options)
        let menu = AppDelegate.makeMenu(target: nil)
        let open = menu.items.first { $0.submenu?.title == ResultsMenu.title }
        if let sub = open?.submenu { ResultsMenu.shared.update(sub) }
        return MenuSnapshotView(menu: menu, open: open)
    }

    static func selfTest(_ name: String) -> String? {
        #if DEBUG
        name == "results-shelf" ? ResultsShelfTests.run() : nil
        #else
        return nil
        #endif
    }
}

// MARK: - Menu snapshot

/// Draws an NSMenu and one open submenu the way macOS shows them, over the desktop-like backdrop.
final class MenuSnapshotView: NSView {
    private let drawnMenu: NSMenu
    private let open: NSMenuItem?
    private static let font = NSFont.menuFont(ofSize: 0)
    private static let lineHeight = ("Ag" as NSString).size(withAttributes: [.font: font]).height
    private static let rowHeight: CGFloat = 24
    private static let separatorHeight: CGFloat = 11
    private static let inset: CGFloat = 5          // panel edge to the highlight
    private static let margin: CGFloat = 24        // canvas edge to the menu

    init(menu: NSMenu, open: NSMenuItem?) {
        self.drawnMenu = menu
        self.open = open
        super.init(frame: .zero)
        let main = Self.size(of: menu)
        var size = CGSize(width: main.width + 2 * Self.margin, height: main.height + 2 * Self.margin)
        if let sub = open?.submenu {
            let s = Self.size(of: sub)
            size.width += s.width - 4
            size.height = max(size.height, Self.margin + Self.top(of: open!, in: menu) - Self.inset + s.height + Self.margin)
        }
        setFrameSize(size)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// macOS keeps a column for checkmarks in front of the titles unless a menu turns it off.
    private static func leading(_ menu: NSMenu) -> CGFloat { menu.showsStateColumn ? 30 : 14 }

    private static func keyText(_ item: NSMenuItem) -> String {
        guard !item.keyEquivalent.isEmpty else { return "" }
        var s = ""
        let m = item.keyEquivalentModifierMask
        if m.contains(.control) { s += "⌃" }
        if m.contains(.option) { s += "⌥" }
        if m.contains(.shift) { s += "⇧" }
        if m.contains(.command) { s += "⌘" }
        return s + item.keyEquivalent.uppercased()
    }

    private static func size(of menu: NSMenu) -> CGSize {
        let lead = leading(menu)
        var width: CGFloat = 0
        var height: CGFloat = 2 * inset
        for item in menu.items where !item.isHidden {
            height += item.isSeparatorItem ? separatorHeight : rowHeight
            guard !item.isSeparatorItem else { continue }
            let title = (item.title as NSString).size(withAttributes: [.font: font]).width
            let key = (keyText(item) as NSString).size(withAttributes: [.font: font]).width
            let trail: CGFloat = item.submenu != nil ? 30 : key > 0 ? key + 30 : 14
            width = max(width, lead + title + trail)
        }
        return CGSize(width: max(width, 120).rounded(.up), height: height)
    }

    /// Whether a row is drawn available. AppKit asks an item's target before the menu opens (Show Clothesline is
    /// dimmed while the line is empty), so this asks it too. Items whose target doesn't validate keep the state they
    /// were given: menu.update() would dim Launch at Login and Settings…, whose target is nil here.
    static func isDrawnEnabled(_ item: NSMenuItem, in menu: NSMenu) -> Bool {
        guard menu.autoenablesItems, item.action != nil, let target = item.target as? NSMenuItemValidation else { return item.isEnabled }
        return target.validateMenuItem(item)
    }

    /// The y of an item's row inside its menu panel.
    private static func top(of item: NSMenuItem, in menu: NSMenu) -> CGFloat {
        var y = inset
        for other in menu.items where !other.isHidden {
            if other === item { return y }
            y += other.isSeparatorItem ? separatorHeight : rowHeight
        }
        return y
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        effectiveAppearance.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            let flip = NSAffineTransform()
            flip.translateX(by: 0, yBy: self.bounds.height)
            flip.scaleX(by: 1, yBy: -1)
            flip.concat()
            ThemeDesktop.draw(in: self.bounds, dark: dark)
            NSGraphicsContext.restoreGraphicsState()

            let main = CGRect(origin: CGPoint(x: Self.margin, y: Self.margin), size: Self.size(of: self.drawnMenu))
            self.drawMenu(self.drawnMenu, in: main, dark: dark)
            if let open = self.open, let sub = open.submenu {
                let y = main.minY + Self.top(of: open, in: self.drawnMenu) - Self.inset
                let frame = CGRect(origin: CGPoint(x: main.maxX - 4, y: y), size: Self.size(of: sub))
                self.drawMenu(sub, in: frame, dark: dark)
            }
        }
    }

    private func drawMenu(_ menu: NSMenu, in frame: CGRect, dark: Bool) {
        let panel = NSBezierPath(roundedRect: frame, xRadius: 10, yRadius: 10)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.5 : 0.22)
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = CGSize(width: 0, height: -6)
        shadow.set()
        (dark ? NSColor(white: 0.16, alpha: 0.97) : NSColor(white: 0.975, alpha: 0.97)).setFill()
        panel.fill()
        NSGraphicsContext.restoreGraphicsState()
        (dark ? NSColor.white.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.1)).setStroke()
        panel.lineWidth = 1
        panel.stroke()

        let lead = Self.leading(menu)
        var y = frame.minY + Self.inset
        for item in menu.items where !item.isHidden {
            if item.isSeparatorItem {
                NSColor.separatorColor.setFill()
                CGRect(x: frame.minX + 14, y: y + Self.separatorHeight / 2, width: frame.width - 28, height: 1).fill()
                y += Self.separatorHeight
                continue
            }
            let row = CGRect(x: frame.minX + Self.inset, y: y, width: frame.width - 2 * Self.inset, height: Self.rowHeight)
            let highlighted = item === open
            if highlighted {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: row, xRadius: 6, yRadius: 6).fill()
            }
            let color: NSColor = highlighted ? .white : Self.isDrawnEnabled(item, in: menu) ? .labelColor : .tertiaryLabelColor
            let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: color]
            let textY = y + (Self.rowHeight - Self.lineHeight) / 2
            (item.title as NSString).draw(at: CGPoint(x: frame.minX + lead, y: textY), withAttributes: attrs)
            if item.state == .on {
                ("✓" as NSString).draw(at: CGPoint(x: frame.minX + 13, y: textY),
                                      withAttributes: [.font: NSFont.menuFont(ofSize: 0).withWeight(.semibold), .foregroundColor: color])
            }
            if item.submenu != nil {
                ("›" as NSString).draw(at: CGPoint(x: frame.maxX - 22, y: textY - 1),
                                      withAttributes: [.font: NSFont.systemFont(ofSize: 16, weight: .medium), .foregroundColor: color])
            } else {
                let key = Self.keyText(item) as NSString
                if key.length > 0 {
                    let w = key.size(withAttributes: attrs).width
                    key.draw(at: CGPoint(x: frame.maxX - 14 - w, y: textY),
                             withAttributes: [.font: Self.font, .foregroundColor: highlighted ? NSColor.white : NSColor.secondaryLabelColor])
                }
            }
            y += Self.rowHeight
        }
    }
}

private extension NSFont {
    func withWeight(_ weight: NSFont.Weight) -> NSFont { NSFont.systemFont(ofSize: pointSize, weight: weight) }
}
