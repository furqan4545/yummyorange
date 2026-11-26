#if DEBUG
// Self-tests: built into debug builds only (./test.sh); the shipped app leaves them out.
import AppKit

/// Headless checks for `--selftest shelf` (`--selftest welcome` is in WelcomeTests).
enum ShelfAndWelcomeTests {
    /// Collects pass/fail lines; the report starts with "FAIL" when anything failed.
    final class Checker {
        private(set) var lines: [String] = []
        private(set) var failures = 0
        func check(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
            if !ok { failures += 1 }
            let d = detail()
            lines.append("\(ok ? "ok  " : "FAIL") \(what)\(d.isEmpty ? "" : " — \(d)")")
        }
        var report: String {
            let head = failures == 0 ? "PASS \(lines.count) checks" : "FAIL \(failures) of \(lines.count) checks"
            return ([head] + lines).joined(separator: "\n")
        }
    }

    private static func scratch(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("YummyOrange selftest \(name) \(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func touch(_ url: URL, bytes: Int = 10) throws {
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    // MARK: Shelf

    static func shelf() -> String {
        let c = Checker()
        do { try shelfModel(c) } catch { c.check(false, "model setup", error.localizedDescription) }
        shelfGeometry(c)
        do { try yourShelf(c) } catch { c.check(false, "your shelf setup", error.localizedDescription) }
        do { try shelfView(c) } catch { c.check(false, "view setup", error.localizedDescription) }
        return c.report
    }

    /// Your shelf keeps its files while closed: what goes on it is saved (each file once, only files that exist) and
    /// read back without the ones deleted since.
    private static func yourShelf(_ c: Checker) throws {
        let dir = try scratch("your-shelf")
        defer { try? FileManager.default.removeItem(at: dir) }
        var stored: [String] = []
        let (load, save) = (ShelfManager.loadPaths, ShelfManager.savePaths)
        ShelfManager.loadPaths = { stored }
        ShelfManager.savePaths = { stored = $0 }
        defer { ShelfManager.loadPaths = load; ShelfManager.savePaths = save }
        let a = dir.appendingPathComponent("Screenshot a.png"), b = dir.appendingPathComponent("b.pdf")
        try touch(a, bytes: 10); try touch(b, bytes: 10)
        let shelves = ShelfManager.shared
        guard shelves.mine == nil else { c.check(false, "your shelf is closed at the start of the test"); return }
        shelves.addToMine([a], show: false)
        shelves.addToMine([a, b, dir.appendingPathComponent("gone.png")], show: false)
        c.check(stored.map { URL(fileURLWithPath: $0).lastPathComponent } == ["Screenshot a.png", "b.pdf"],
                "files put on your closed shelf are kept, each once, missing ones left out", "\(stored)")
        c.check(shelves.mineContains(a) && !shelves.mineContains(dir.appendingPathComponent("c.png")), "it knows what it holds")
        try FileManager.default.removeItem(at: b)
        c.check(shelves.savedFiles.map(\.lastPathComponent) == ["Screenshot a.png"], "a file deleted since isn't shown when it opens")
        c.check(ShelfAndWelcome.menuItems().first?.title == "Open Shelf", "the menu offers Open Shelf (your shelf), not New Shelf")
    }

    private static func shelfModel(_ c: Checker) throws {
        let dir = try scratch("shelf")
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.png"), b = dir.appendingPathComponent("b.txt"), d = dir.appendingPathComponent("d.pdf")
        try touch(a, bytes: 1000); try touch(b, bytes: 2000); try touch(d, bytes: 3000)

        let m = ShelfModel()
        var changes = 0
        m.onChange = { changes += 1 }
        var r = m.add([a, b])
        c.check(m.count == 2 && r.added.count == 2 && changes == 1, "add two files", "count \(m.count), changes \(changes)")
        c.check(m.urls.map(\.lastPathComponent) == ["a.png", "b.txt"], "keeps the order they were added in")

        r = m.add([a])
        c.check(r.duplicates == 1 && m.count == 2 && changes == 1, "same URL again is a duplicate, no change event")
        r = m.add([URL(fileURLWithPath: dir.path + "/./sub/../a.png")])
        c.check(r.duplicates == 1 && m.count == 2, "a.png through ./ and .. is a duplicate", "dup \(r.duplicates)")
        let caseInsensitive = (try? dir.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames == false
        if caseInsensitive {
            r = m.add([dir.appendingPathComponent("A.PNG")])
            c.check(r.duplicates == 1 && m.count == 2, "A.PNG on a case-insensitive disk is the same file")
        }
        r = m.add([d, d, dir.appendingPathComponent("missing.jpg"), URL(string: "https://example.com/x.png")!])
        c.check(r.added == [d.standardizedFileURL] && r.duplicates == 1 && r.missing == 2 && m.count == 3,
                "one drop with a repeat, a missing file and a web URL",
                "added \(r.added.count) dup \(r.duplicates) missing \(r.missing)")

        let link = dir.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: a)
        r = m.add([link])
        c.check(r.added.count == 1 && m.count == 4, "a symlink is its own item (the link, not its target)")
        m.remove([link])

        let folder = dir.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        m.add([folder])
        c.check(m.items.last?.isFolder == true && m.items.last?.size == nil, "a folder is an item without a size")
        let expected = "4 items · \(ByteCountFormatter.string(fromByteCount: 6000, countStyle: .file))"
        c.check(m.summary == expected, "summary counts items and file bytes", m.summary)
        c.check(ShelfModel(Array([a])).summary == "a.png", "one item's summary is its name")
        c.check(ShelfModel().summary == "Empty shelf", "empty summary")
        c.check(ShelfModel.badge(7) == "7" && ShelfModel.badge(1000) == "999+", "badge text")

        var n = m.remove([b])
        c.check(n == 1 && m.count == 3 && !m.urls.contains(b.standardizedFileURL), "remove by URL")
        n = m.remove([b])
        c.check(n == 0 && m.count == 3, "removing something not there changes nothing")
        n = m.remove(at: IndexSet([0, 99]))
        c.check(n == 1 && m.urls.first?.lastPathComponent == "d.pdf", "remove at offsets ignores out-of-range ones",
                m.urls.map(\.lastPathComponent).joined(separator: ","))
        m.add([a])
        c.check(m.count == 3, "a removed file can be added back")

        // Following Finder.
        let moved = dir.appendingPathComponent("renamed d.pdf")
        try FileManager.default.moveItem(at: d, to: moved)
        var f = m.refresh()
        c.check(f.followed == 1 && m.urls.contains(moved.standardizedFileURL), "follows a renamed file through its bookmark",
                "followed \(f.followed) dropped \(f.dropped)")
        try Data("new".utf8).write(to: a, options: .atomic)   // replaced in place, new inode
        f = m.refresh()
        c.check(f.dropped == 0 && m.urls.contains(a.standardizedFileURL), "keeps a file that was saved over atomically")
        c.check(m.add([a]).duplicates == 1, "and still knows it after the inode changed")
        try FileManager.default.removeItem(at: moved)
        f = m.refresh()
        c.check(f.dropped == 1 && !m.urls.contains(moved.standardizedFileURL), "drops a deleted file")
        m.clear()
        c.check(m.isEmpty && m.add([a]).added.count == 1, "clear empties it and forgets duplicates")

        // Many files.
        let many = dir.appendingPathComponent("many", isDirectory: true)
        try FileManager.default.createDirectory(at: many, withIntermediateDirectories: true)
        let urls = try (0..<3000).map { i -> URL in
            let u = many.appendingPathComponent("f\(i).dat")
            try touch(u, bytes: 1)
            return u
        }
        let big = ShelfModel()
        var t = Date()
        r = big.add(urls)
        let addTime = Date().timeIntervalSince(t)
        t = Date()
        let again = big.add(urls)
        let dupTime = Date().timeIntervalSince(t)
        t = Date()
        big.refresh()
        let refreshTime = Date().timeIntervalSince(t)
        c.check(r.added.count == 3000 && again.duplicates == 3000 && big.count == 3000, "3,000 files, then the same 3,000 again")
        c.check(addTime < 3 && dupTime < 1 && refreshTime < 1, "3,000 files stay quick",
                String(format: "add %.2f s, re-add %.2f s, refresh %.2f s", addTime, dupTime, refreshTime))
        c.check(big.items.filter { $0.bookmark != nil }.count == ShelfModel.bookmarkLimit, "bookmarks only for the first \(ShelfModel.bookmarkLimit)")

        // Headless Float.
        do {
            let outs = try ShelfAndWelcome.float([a, a, b], options: ["view": "list"])
            c.check(outs.isEmpty, "Float run writes no files")
        } catch { c.check(false, "Float run with real files", error.localizedDescription) }
        do {
            _ = try ShelfAndWelcome.float([dir.appendingPathComponent("nope.png")], options: [:])
            c.check(false, "Float run with only missing files throws")
        } catch { c.check(error.localizedDescription.contains("nothing to float"), "Float run with only missing files throws", error.localizedDescription) }
    }

    private static func shelfGeometry(_ c: Checker) {
        typealias G = ShelfGeometry
        let vis = CGRect(x: 0, y: 80, width: 1440, height: 795)   // a Dock at the bottom, menu bar at the top
        let size = CGSize(width: 184, height: 210)
        func at(_ x: CGFloat, _ y: CGFloat) -> CGRect { CGRect(origin: CGPoint(x: x, y: y), size: size) }

        var s = G.snapped(at(600, 400), in: vis)
        c.check(s.edges.isEmpty && s.frame == at(600, 400), "in the middle: stays put, not docked")
        s = G.snapped(at(15, 400), in: vis)
        c.check(s.edges == .left && s.frame.minX == 0 && s.frame.minY == 400, "15 pt from the left: snaps left")
        s = G.snapped(at(1440 - 184 - 20, 400), in: vis)
        c.check(s.edges == .right && s.frame.maxX == 1440, "20 pt from the right: snaps right")
        s = G.snapped(at(1440 - 184 - 30, 400), in: vis)
        c.check(s.edges.isEmpty, "30 pt from the right: no snap (threshold \(Int(G.snapDistance)) pt)")
        s = G.snapped(at(600, 875 - 210 - 10), in: vis)
        c.check(s.edges == .top && s.frame.maxY == 875, "just under the menu bar: snaps to the top")
        s = G.snapped(at(600, 90), in: vis)
        c.check(s.edges == .bottom && s.frame.minY == 80, "just above the Dock: snaps to the bottom")
        s = G.snapped(at(5, 870), in: vis)
        c.check(s.edges == [.left, .top] && s.frame.origin == CGPoint(x: 0, y: 875 - 210), "in a corner: snaps to both edges")
        s = G.snapped(at(-300, -500), in: vis)
        c.check(s.frame.minX == 0 && s.frame.minY == 80 && s.edges == [.left, .bottom], "dragged off screen: pulled back and docked")
        s = G.snapped(at(1500, 400), in: vis)
        c.check(s.frame.maxX == 1440 && s.edges == .right, "past the right edge: pulled back to it")
        let huge = G.clamped(CGRect(x: 100, y: 100, width: 2000, height: 1000), in: vis)
        c.check(huge.minX == 0 && huge.maxY == 875, "bigger than the screen: top-left corner stays visible")

        let docked = CGRect(x: 1256, y: 400, width: 184, height: 210)
        var r = G.resized(docked, to: CGSize(width: 284, height: 300), keeping: .right)
        c.check(r.maxX == 1440 && r.maxY == docked.maxY, "growing while docked right keeps the right edge and the top")
        r = G.resized(CGRect(x: 600, y: 80, width: 184, height: 210), to: CGSize(width: 284, height: 300), keeping: .bottom)
        c.check(r.minY == 80 && r.minX == 600, "growing while docked to the bottom keeps the bottom")
        r = G.resized(CGRect(x: 600, y: 400, width: 184, height: 210), to: CGSize(width: 284, height: 300), keeping: [])
        c.check(r.minX == 600 && r.maxY == 610, "undocked: the top-left corner stays put")

        let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: 1440, y: 0, width: 1920, height: 1080)]
        c.check(G.bestScreen(for: CGRect(x: 1400, y: 300, width: 184, height: 210), among: screens) == 1, "mostly on the second screen")
        c.check(G.bestScreen(for: CGRect(x: 100, y: 300, width: 184, height: 210), among: screens) == 0, "on the first screen")
        c.check(G.bestScreen(for: CGRect(x: 5000, y: 300, width: 10, height: 10), among: screens) == 1, "off every screen: the nearest")
        c.check(G.bestScreen(for: .zero, among: []) == nil, "no screens")

        let first = G.initialFrame(size: size, pointer: CGPoint(x: 700, y: 500), visible: vis, others: [])
        c.check(first.midX == 700 && first.midY == 500, "a new shelf is centered on the pointer")
        let second = G.initialFrame(size: size, pointer: CGPoint(x: 700, y: 500), visible: vis, others: [first])
        c.check(second.minX == first.minX + 24 && second.maxY == first.maxY - 24, "the next one steps down and right")
        let corner = G.initialFrame(size: size, pointer: CGPoint(x: 1440, y: 875), visible: vis, others: [])
        c.check(vis.contains(corner), "opened at the screen corner: still fully visible")
        var stack: [CGRect] = []
        for _ in 0..<12 { stack.append(G.initialFrame(size: size, pointer: CGPoint(x: 1400, y: 120), visible: vis, others: stack)) }
        let distinct = Set(stack.map { "\(Int($0.minX)),\(Int($0.minY))" }).count
        c.check(distinct == 12 && stack.allSatisfy { vis.contains($0) }, "12 shelves opened at the same spot don't cover each other",
                "\(distinct) distinct")
        c.check(G.Edges(names: "Left, top") == [.left, .top] && G.Edges(names: "") == [], "edge names parse")
    }

    private static func shelfView(_ c: Checker) throws {
        let dir = try scratch("shelfview")
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try (1...4).map { i -> URL in
            let u = dir.appendingPathComponent("file \(i).txt")
            try touch(u)
            return u
        }
        let model = ShelfModel(Array(files.prefix(2)))
        let view = ShelfView(model: model, mode: .stack)
        c.check(view.preferredSize == CGSize(width: 184, height: 210), "stack size", "\(view.preferredSize)")
        view.mode = .list
        c.check(view.frame.size == CGSize(width: 284, height: 146), "list with 2 rows", "\(view.frame.size)")
        model.add(Array(files.suffix(2)))
        c.check(view.frame.size.height == 30 + 30 + 4 * 40 + 6 && view.table.numberOfRows == 4, "list grows with rows")
        c.check(view.item(atRow: 0)?.url.lastPathComponent == "file 4.txt", "the list shows the newest first")
        view.table.selectRowIndexes([0, 1], byExtendingSelection: false)
        c.check(Set(view.selectedURLs.map(\.lastPathComponent)) == ["file 4.txt", "file 3.txt"], "selected rows map to files")
        view.removeSelected()
        c.check(model.urls.map(\.lastPathComponent) == ["file 1.txt", "file 2.txt"], "Delete removes the selected rows")
        model.clear()
        c.check(view.table.numberOfRows == 0 && view.frame.size.height == 190, "cleared list keeps a drop area")

        let pb = NSPasteboard(name: .init("DropWheel.selftest.\(UUID().uuidString)"))
        pb.clearContents()
        pb.writeObjects(files as [NSURL])
        let back = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        c.check(back == files, "file URLs written for a drag read back as the same files")
        pb.releaseGlobally()
        // Dropping in, with a stand-in for AppKit's dragging info.
        let drop = ShelfView(model: ShelfModel([files[0]]), mode: .stack)
        var op = drop.draggingEntered(ShelfMockDrag(files, source: nil))
        c.check(op == .copy && drop.hoveringCount == 4, "files hovering from Finder: copy cursor, \"Add 4 files\"")
        c.check(drop.performDragOperation(ShelfMockDrag(files, source: nil)) && drop.model.count == 4 && drop.hoveringCount == nil,
                "dropping them adds the 3 new ones", "count \(drop.model.count)")
        _ = drop.performDragOperation(ShelfMockDrag([files[1]], source: nil))
        c.check(drop.model.count == 4 && drop.footerText == "Already on this shelf", "dropping a file that's already there says so",
                drop.footerText)
        op = drop.draggingEntered(ShelfMockDrag([dir.appendingPathComponent("x.png")], source: drop))
        c.check(op == [] && !drop.performDragOperation(ShelfMockDrag([files[0]], source: drop)), "a shelf ignores its own files dropped back on it")
        op = drop.draggingEntered(ShelfMockDrag([], source: nil, text: "hello"))
        c.check(op == [] && drop.hoveringCount == nil, "plain text isn't accepted")
        var owners: [String] = []
        func walk(_ v: NSView) {
            if v !== drop && !v.registeredDraggedTypes.isEmpty { owners.append(String(describing: type(of: v))) }
            v.subviews.forEach(walk)
        }
        drop.mode = .list
        walk(drop)
        c.check(owners.isEmpty, "no part of the shelf takes drops away from it", owners.joined(separator: ", "))
        c.check(drop.registeredDraggedTypes.contains(.fileURL), "the shelf takes file drops")

        // The controller on a panel that is never shown: docking and resizing.
        let savedMode = UserDefaults.standard.string(forKey: "shelf.viewMode")
        defer { UserDefaults.standard.set(savedMode, forKey: "shelf.viewMode") }
        let shelf = ShelfController(files: Array(files.prefix(2)), mode: .stack)
        let visible = ShelfController.visibleFrame(for: CGRect(x: 0, y: 0, width: 10, height: 10), pointer: nil)
        shelf.panel.setFrame(CGRect(x: visible.maxX - 184 - 10, y: visible.midY, width: 184, height: 210), display: false)
        shelf.settle(animated: false, pointer: nil)
        c.check(shelf.docked == .right && shelf.frame.maxX == visible.maxX, "let go 10 pt from the right: docks right",
                "\(shelf.frame) in \(visible)")
        c.check(shelf.view.docked == .right, "the view squares its right corners")
        shelf.setMode(.list)
        c.check(shelf.frame.width == 284 && shelf.frame.maxX == visible.maxX && shelf.docked == .right,
                "switching to the list grows leftward and stays docked", "\(shelf.frame)")
        c.check(ShelfViewMode.last == .list, "the next shelf opens as a list")
        shelf.moveBegan()
        shelf.panel.setFrameOrigin(CGPoint(x: visible.midX, y: visible.midY))
        shelf.moveEnded()
        c.check(shelf.docked.isEmpty && shelf.view.docked.isEmpty, "moved to the middle: undocked")
        shelf.model.add(Array(files.suffix(2)))
        c.check(shelf.frame.height == 30 + 30 + 4 * 40 + 6, "adding files grows the panel", "\(shelf.frame.height)")

        let menu = view.menu(for: [files[0]], wholeShelf: false)
        c.check(menu.items.map(\.title).contains("Remove from Shelf") && menu.items.allSatisfy { $0.isSeparatorItem || $0.target != nil },
                "row menu has Remove and every item has a target")
    }
}

/// A stand-in for AppKit's dragging info, so the shelf's drop handling can be tested without a real drag.
final class ShelfMockDrag: NSObject, NSDraggingInfo {
    private let pasteboard: NSPasteboard
    private let source: Any?

    init(_ urls: [URL], source: Any?, text: String? = nil) {
        pasteboard = NSPasteboard(name: .init("DropWheel.mockdrag.\(UUID().uuidString)"))
        pasteboard.clearContents()
        if !urls.isEmpty { pasteboard.writeObjects(urls as [NSURL]) }
        if let text { pasteboard.setString(text, forType: .string) }
        self.source = source
    }
    deinit { pasteboard.releaseGlobally() }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { [.copy, .move, .link, .generic] }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { source }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}
#endif
