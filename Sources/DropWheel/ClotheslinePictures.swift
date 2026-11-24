import AppKit
import ImageIO
import UniformTypeIdentifiers

/// The pictures on the Clothesline's cards. A picture file ImageIO reads (a screenshot, a photo) is decoded off the main
/// thread straight to the size the card shows, with CGImageSourceCreateThumbnailAtIndex, so nothing large is ever
/// decoded on the main thread and a card's picture is ready sooner (a 3456 × 2234 screenshot in about 40 ms here, where
/// Quick Look took about 100 ms: the time a screenshot's card waits before it takes off). Everything else gets Quick
/// Look's thumbnail (ShelfThumbnails), as the Float shelf does. Cached by path, modification date and size; a picture
/// ShelfThumbnails already has (the previews and self-tests preload it) is used as it is. Main thread; callbacks arrive
/// on the main thread.
enum ClotheslinePictures {
    private static let cache: NSCache<NSString, ShelfThumbnail> = {
        let c = NSCache<NSString, ShelfThumbnail>()
        c.countLimit = 200
        return c
    }()
    private static var waiting: [NSString: [(ShelfThumbnail) -> Void]] = [:]
    private static let queue = DispatchQueue(label: "DropWheel.ClotheslinePictures", qos: .userInitiated, attributes: .concurrent)

    /// Pictures decoded so far by ImageIO, and how many went to Quick Look instead (tests).
    private(set) static var decoded = 0, quickLooked = 0

    private static func key(_ url: URL, _ size: CGFloat) -> NSString {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return "\(url.path)|\(date?.timeIntervalSince1970 ?? 0)|\(Int(size))" as NSString
    }

    /// The picture, when it is ready.
    static func cached(_ url: URL, size: CGFloat) -> ShelfThumbnail? {
        cache.object(forKey: key(url, size)) ?? ShelfThumbnails.cached(url, size: size)
    }

    /// Whether ImageIO decodes this file (by its name: the decode itself is tried off the main thread, and a file it
    /// can't read goes to Quick Look after all).
    static func decodesDirectly(_ url: URL) -> Bool {
        guard url.isFileURL, let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return [UTType.png, .jpeg, .heic, .heif, .tiff, .gif, .bmp, .webP].contains { type.conforms(to: $0) }
    }

    /// Loads a picture of about `size` points (twice that in pixels). Calls back right away when it's cached.
    static func load(_ url: URL, size: CGFloat, completion: @escaping (ShelfThumbnail) -> Void) {
        if let t = cached(url, size: size) { completion(t); return }
        guard decodesDirectly(url) else { quickLooked += 1; ShelfThumbnails.load(url, size: size, completion: completion); return }
        let k = key(url, size)
        if waiting[k] != nil { waiting[k]?.append(completion); return }
        waiting[k] = [completion]
        let pixels = Int((size * max(NSScreen.main?.backingScaleFactor ?? 2, 2)).rounded())
        queue.async {
            let image = thumbnail(url, maxPixels: pixels)
            DispatchQueue.main.async {
                let callbacks = waiting.removeValue(forKey: k) ?? []
                guard let image else {
                    // Not a picture ImageIO reads after all: Quick Look's thumbnail (or the Finder icon).
                    quickLooked += 1
                    for c in callbacks { ShelfThumbnails.load(url, size: size, completion: c) }
                    return
                }
                decoded += 1
                // Points at 2 pixels each, like Quick Look's thumbnails (only the aspect matters to the card).
                let picture = ShelfThumbnail(image: NSImage(cgImage: image, size: CGSize(width: CGFloat(image.width) / 2,
                                                                                        height: CGFloat(image.height) / 2)),
                                             isIcon: false)
                cache.setObject(picture, forKey: k)
                callbacks.forEach { $0(picture) }
            }
        }
    }

    /// The picture at most `maxPixels` on its longer side, upright (its EXIF orientation applied), decoded now (any
    /// thread).
    static func thumbnail(_ url: URL, maxPixels: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxPixels, 1),
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }
}
