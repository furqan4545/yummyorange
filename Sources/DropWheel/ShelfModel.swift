import Foundation
import CoreGraphics

/// One file or folder on a shelf.
struct ShelfItem {
    /// Where the file is now. Updated when the file is moved or renamed in Finder.
    var url: URL
    /// Device and inode, so the same file under two spellings ("A.png" and "a.png", "/x/./a.png") is one item.
    var key: String
    /// Lets the shelf follow the file after a move or rename. Only made for the first `ShelfModel.bookmarkLimit` items.
    var bookmark: Data?
    /// Size in bytes for regular files; nil for folders and packages.
    var size: Int64?
    var isFolder: Bool
}

/// The files on one shelf, oldest first (the newest is on top of the stack). No UI here, so `--selftest shelf`
/// can check it headlessly. Main thread only in the app.
final class ShelfModel {
    /// Beyond this many items, new ones get no bookmark (making one costs about 0.1 ms).
    static let bookmarkLimit = 2000

    private(set) var items: [ShelfItem] = []
    private var keys: Set<String> = []
    /// Called after every change that altered the items.
    var onChange: (() -> Void)?

    var urls: [URL] { items.map(\.url) }
    var count: Int { items.count }
    var isEmpty: Bool { items.isEmpty }

    init(_ urls: [URL] = []) { add(urls) }

    struct AddResult {
        var added: [URL] = []
        /// Already on the shelf, or listed twice in the same drop.
        var duplicates = 0
        /// Not a file URL, or nothing exists there.
        var missing = 0
    }

    /// The identity of whatever is at `url` without following a final symlink (a link and its target stay
    /// separate items), or nil when nothing is there.
    static func identity(of url: URL) -> String? {
        var st = stat()
        guard url.isFileURL, lstat(url.path, &st) == 0 else { return nil }
        return "\(st.st_dev):\(st.st_ino)"
    }

    /// Adds files to the end, skipping ones already here and ones that don't exist.
    @discardableResult
    func add(_ urls: [URL]) -> AddResult {
        var result = AddResult()
        for raw in urls {
            let url = raw.standardizedFileURL
            guard let key = Self.identity(of: url) else { result.missing += 1; continue }
            guard keys.insert(key).inserted else { result.duplicates += 1; continue }
            items.append(Self.makeItem(url, key: key, bookmark: items.count < Self.bookmarkLimit))
            result.added.append(url)
        }
        if !result.added.isEmpty { onChange?() }
        return result
    }

    private static func makeItem(_ url: URL, key: String, bookmark: Bool) -> ShelfItem {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .fileSizeKey, .totalFileSizeKey])
        let isFolder = values?.isDirectory ?? false
        let size = isFolder ? nil : (values?.totalFileSize ?? values?.fileSize).map(Int64.init)
        return ShelfItem(url: url, key: key, bookmark: bookmark ? try? url.bookmarkData(options: [.withoutImplicitSecurityScope]) : nil,
                         size: size, isFolder: isFolder)
    }

    /// Removes the items for these URLs (matched by path or by file identity). Returns how many went.
    @discardableResult
    func remove(_ urls: [URL]) -> Int {
        let paths = Set(urls.map { $0.standardizedFileURL.path })
        let ids = Set(urls.compactMap(Self.identity(of:)))
        return removeWhere { _, item in paths.contains(item.url.path) || ids.contains(item.key) }
    }

    /// Removes the items at these positions (out-of-range ones are ignored).
    @discardableResult
    func remove(at offsets: IndexSet) -> Int {
        removeWhere { index, _ in offsets.contains(index) }
    }

    func clear() {
        guard !items.isEmpty else { return }
        items.removeAll()
        keys.removeAll()
        onChange?()
    }

    private func removeWhere(_ match: (Int, ShelfItem) -> Bool) -> Int {
        let before = items.count
        items = items.enumerated().filter { !match($0.offset, $0.element) }.map(\.element)
        guard items.count != before else { return 0 }
        keys = Set(items.map(\.key))
        onChange?()
        return before - items.count
    }

    /// Catches up with Finder: an item whose file was moved or renamed (in Finder, or by dragging it out of the
    /// shelf into another folder) follows it through its bookmark; one whose file was deleted or put in the Trash is
    /// dropped. A file replaced in place (an app saving atomically) stays. Returns how many items followed a move
    /// and how many were dropped.
    @discardableResult
    func refresh() -> (followed: Int, dropped: Int) {
        var followed = 0, dropped = 0, changed = false
        var seen: Set<String> = []
        var kept: [ShelfItem] = []
        kept.reserveCapacity(items.count)
        for var item in items {
            if let key = Self.identity(of: item.url) {
                if key != item.key { item.key = key; changed = true }
            } else if let moved = Self.resolve(item.bookmark), let key = Self.identity(of: moved) {
                item = Self.makeItem(moved, key: key, bookmark: true)
                followed += 1
                changed = true
            } else {
                dropped += 1
                changed = true
                continue
            }
            if seen.insert(item.key).inserted { kept.append(item) } else { dropped += 1; changed = true }
        }
        if changed {
            items = kept
            keys = seen
            onChange?()
        }
        return (followed, dropped)
    }

    private static func resolve(_ bookmark: Data?) -> URL? {
        guard let bookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting, .withoutImplicitStartAccessing],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        // A file moved to the Trash isn't somewhere the user wants to drag from.
        if url.pathComponents.contains(".Trash") { return nil }
        return url.standardizedFileURL
    }

    /// "photo.png", or "3 items · 4.2 MB" (folders count as items but add no size).
    var summary: String {
        if items.isEmpty { return "Empty shelf" }
        if items.count == 1 { return items[0].url.lastPathComponent }
        let bytes = items.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        let count = "\(items.count.formatted()) items"
        return bytes > 0 ? "\(count) · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))" : count
    }

    /// Short text for the count badge.
    static func badge(_ count: Int) -> String { count > 999 ? "999+" : String(count) }
}

/// Window placement for shelves: keeping them on screen, snapping to screen edges and choosing a screen.
/// Plain geometry in AppKit's coordinates (origin bottom-left), so the self-test can check it.
enum ShelfGeometry {
    struct Edges: OptionSet, Hashable {
        let rawValue: Int
        static let left = Edges(rawValue: 1)
        static let right = Edges(rawValue: 2)
        static let top = Edges(rawValue: 4)
        static let bottom = Edges(rawValue: 8)

        /// Parses "left", "right,top" and so on (for `--opt edge=`).
        init(names: String) {
            var e: Edges = []
            for name in names.lowercased().split(whereSeparator: { $0 == "," || $0 == " " || $0 == "+" }) {
                switch name {
                case "left": e.insert(.left)
                case "right": e.insert(.right)
                case "top": e.insert(.top)
                case "bottom": e.insert(.bottom)
                default: break
                }
            }
            self = e
        }
        init(rawValue: Int) { self.rawValue = rawValue }
    }

    /// How close (in points) a released shelf must be to an edge to snap to it.
    static let snapDistance: CGFloat = 24

    /// Moves `frame` fully inside `visible`. A frame bigger than the area keeps its top-left corner in view.
    static func clamped(_ frame: CGRect, in visible: CGRect) -> CGRect {
        var f = frame
        f.origin.x = f.width >= visible.width ? visible.minX : min(max(f.minX, visible.minX), visible.maxX - f.width)
        f.origin.y = f.height >= visible.height ? visible.maxY - f.height : min(max(f.minY, visible.minY), visible.maxY - f.height)
        return f
    }

    /// Where a shelf settles when it's let go: inside the visible area, and flush with any edge it is within
    /// `distance` of. Returns the edges it now touches.
    static func snapped(_ frame: CGRect, in visible: CGRect, distance: CGFloat = snapDistance) -> (frame: CGRect, edges: Edges) {
        var f = clamped(frame, in: visible)
        var edges: Edges = []
        if f.minX - visible.minX <= distance { f.origin.x = visible.minX; edges.insert(.left) }
        else if visible.maxX - f.maxX <= distance { f.origin.x = visible.maxX - f.width; edges.insert(.right) }
        if visible.maxY - f.maxY <= distance { f.origin.y = visible.maxY - f.height; edges.insert(.top) }
        else if f.minY - visible.minY <= distance { f.origin.y = visible.minY; edges.insert(.bottom) }
        return (f, edges)
    }

    /// The same shelf at a new size: a docked edge stays docked, otherwise the top-left corner stays put.
    static func resized(_ frame: CGRect, to size: CGSize, keeping edges: Edges) -> CGRect {
        let x = edges.contains(.right) && !edges.contains(.left) ? frame.maxX - size.width : frame.minX
        let y = edges.contains(.bottom) && !edges.contains(.top) ? frame.minY : frame.maxY - size.height
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Index of the screen that holds most of `frame`, else the one nearest to its center.
    static func bestScreen(for frame: CGRect, among screens: [CGRect]) -> Int? {
        guard !screens.isEmpty else { return nil }
        let areas = screens.map { s -> CGFloat in
            let i = s.intersection(frame)
            return i.isNull ? 0 : i.width * i.height
        }
        if let best = areas.indices.max(by: { areas[$0] < areas[$1] }), areas[best] > 0 { return best }
        let c = CGPoint(x: frame.midX, y: frame.midY)
        return screens.indices.min { distance(c, screens[$0]) < distance(c, screens[$1]) }
    }

    private static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        hypot(max(r.minX - p.x, 0, p.x - r.maxX), max(r.minY - p.y, 0, p.y - r.maxY))
    }

    /// Where a new shelf opens: centered on the pointer, stepped down and right while it would cover another
    /// shelf exactly, and kept on screen.
    static func initialFrame(size: CGSize, pointer: CGPoint, visible: CGRect, others: [CGRect]) -> CGRect {
        var f = clamped(CGRect(x: pointer.x - size.width / 2, y: pointer.y - size.height / 2,
                               width: size.width, height: size.height), in: visible)
        for step in 1...16 {
            guard others.contains(where: { abs($0.minX - f.minX) < 10 && abs($0.maxY - f.maxY) < 10 }) else { break }
            var next = f.offsetBy(dx: 24, dy: -24)
            if next.maxX > visible.maxX || next.minY < visible.minY {   // ran out of room: start a new column
                next.origin = CGPoint(x: visible.minX + CGFloat(step) * 12, y: visible.maxY - size.height - CGFloat(step) * 6)
            }
            f = clamped(next, in: visible)
        }
        return f
    }
}
