import AppKit
import QuickLookThumbnailing

/// A picture for a shelf item. `isIcon` is true for the Finder icon fallback, which is drawn smaller than a preview.
final class ShelfThumbnail {
    let image: NSImage
    let isIcon: Bool
    init(image: NSImage, isIcon: Bool) { self.image = image; self.isIcon = isIcon }
}

/// Thumbnails for shelf items: Quick Look's preview when it has one, the Finder icon otherwise.
/// Cached by path, modification date and size. Main thread; callbacks arrive on the main thread.
enum ShelfThumbnails {
    private static let cache: NSCache<NSString, ShelfThumbnail> = {
        let c = NSCache<NSString, ShelfThumbnail>()
        c.countLimit = 600
        return c
    }()
    private static var waiting: [NSString: [(ShelfThumbnail) -> Void]] = [:]

    /// The Finder icon, shown until (or instead of) a preview.
    static func icon(for url: URL) -> ShelfThumbnail {
        ShelfThumbnail(image: NSWorkspace.shared.icon(forFile: url.path), isIcon: true)
    }

    private static func key(_ url: URL, _ size: CGFloat) -> NSString {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return "\(url.path)|\(date?.timeIntervalSince1970 ?? 0)|\(Int(size))" as NSString
    }

    static func cached(_ url: URL, size: CGFloat) -> ShelfThumbnail? { cache.object(forKey: key(url, size)) }

    /// Loads a preview of about `size` points. Calls back right away when it's cached.
    static func load(_ url: URL, size: CGFloat, completion: @escaping (ShelfThumbnail) -> Void) {
        let k = key(url, size)
        if let t = cache.object(forKey: k) { completion(t); return }
        if waiting[k] != nil { waiting[k]?.append(completion); return }
        waiting[k] = [completion]

        let scale = max(NSScreen.main?.backingScaleFactor ?? 2, 2)
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size),
                                                   scale: scale, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            let image = rep?.nsImage
            DispatchQueue.main.async {
                let result = image.map { ShelfThumbnail(image: $0, isIcon: false) } ?? icon(for: url)
                cache.setObject(result, forKey: k)
                (waiting.removeValue(forKey: k) ?? []).forEach { $0(result) }
            }
        }
    }

    /// For snapshots and tests: loads previews and waits (spinning the run loop) until they arrive or time runs out.
    static func preload(_ urls: [URL], size: CGFloat, timeout: TimeInterval = 6) {
        var pending = urls.count
        for url in urls { load(url, size: size) { _ in pending -= 1 } }
        let deadline = Date().addingTimeInterval(timeout)
        while pending > 0 && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }
}
