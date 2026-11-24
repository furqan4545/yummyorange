import AppKit
import UniformTypeIdentifiers

// Dropping files on the Clothesline. While Show New Files is On the Clothesline, a file dragged from anywhere (Finder,
// another app, a YummyOrange window) and held at the notch drops the line, even an empty one. Over the line a ghost card
// (the card to be, translucent, with an open clothespin) shows where the files will hang, the cards on either side
// slide apart to make room and the string glows brighter; releasing hangs the files there. Once the files have been
// over the line they can be let go anywhere over its area (its whole width, from the top of the screen down past the
// cards), and the line stays out while they are there; taken away, it goes a moment later (0.35 s), and comes back
// when they are brought back toward the notch (or over its area before it has gone). The files are only referred
// to (the line keeps a reference, as it does for a job's files): nothing is moved or copied, so the drop answers .link
// (or .generic), never copy or move. Files an app only promises (Photos, Mail, Safari images) are written by that app
// into a YummyOrange folder in the temporary directory and hang from there (that drop is a copy, and says so). Later the
// line drops again when the pointer rests on the notch, and a card dragged to a Finder folder moves the file there,
// the card following it. A card pressed and dragged along the string moves there (the same gap opens where it will go);
// dragged down off the line it becomes that drag to Finder, and brought back over the line it is hung again where it
// is let go (the engine's "Moving a card along the string").
//
// Who does what:
//   - ClotheslineDragWatch (here) decides from the left-button events whether a drag is a real file drag: the drag
//     pasteboard changed since the press and holds file URLs or file promises. It looks at the pasteboard only near the
//     top of the line's display, at most once per press. While the button is held the controller also polls the button
//     and the pointer, because a drag session's own loop (one started in a YummyOrange window) keeps its events from the
//     monitors.
//   - ClotheslineController (Clothesline.swift) owns the left-button monitors (installed from launch while the line
//     is the chosen place for new files, removed when another place is chosen), feeds the engine and makes the panel
//     accept the drag only while the files are over the line (the notch zone, the string or a card, then its area).
//   - ClotheslineEngine (the drop section) keeps the drop state: the reveal for a file drag, the gap, the ghost, the
//     insertion and the hold and retract after it.
//   - ClotheslineView takes the drop (NSDraggingDestination) and draws the ghost and the brighter string.

/// Whether a drag in progress is a file drag, from the left-button events alone (no event tap, no Accessibility
/// permission): the press records the drag pasteboard's change count, and a drag counts once the count moved since
/// then (a drag session wrote the pasteboard) and the pasteboard holds file URLs. Window moves and text selections
/// never write it; a drag of text or a picture without a file has no file URLs and stays "another drag".
struct ClotheslineDragWatch {
    enum Kind { case down, dragged, up }

    /// The drag pasteboard's count before this press could have started a drag: the smaller of the count at the last
    /// release and the count when the press arrived (a fast drag may write the pasteboard before the press's event is
    /// handled). nil before any press or release was seen.
    private(set) var baseline: Int?
    private var lastUpCount: Int?
    /// The press's dragged files once read (empty: the drag holds no files); nil until then.
    private(set) var files: [URL]?
    /// A press is held: its release hasn't been seen yet.
    private(set) var pressed = false
    /// This press's drag is over for the line (dropped on it, cancelled over it, Esc): it no longer counts.
    private(set) var finished = false
    /// When the pasteboard's count was last looked at while it hadn't moved (so a window dragged along the top of the
    /// screen asks at most every `recheck` seconds).
    private var lastCheck: Double?
    /// How many times the pasteboard's files were read (tests: at most once per press).
    private(set) var reads = 0

    static let recheck = 0.05

    /// Starts from the pasteboard as it is (the monitors were just installed).
    mutating func reset(changeCount: Int) {
        lastUpCount = changeCount
        baseline = nil
        files = nil
        finished = false
        lastCheck = nil
        pressed = false
    }

    /// A press. When the last press's release was never seen (a drag session's loop kept it), the count at the last
    /// release is stale (that drag wrote the pasteboard since), so this press starts from the count as it is: it gives
    /// up the fast-drag tolerance once rather than take a window or text drag for a drag of the old files.
    mutating func press(changeCount: Int) {
        baseline = pressed ? changeCount : min(lastUpCount ?? changeCount, changeCount)
        files = nil
        finished = false
        lastCheck = nil
        pressed = true
    }

    mutating func release(changeCount: Int) {
        lastUpCount = changeCount
        baseline = nil
        files = nil
        finished = false
        lastCheck = nil
        pressed = false
    }

    /// The drag ended for the line (dropped on it or cancelled over it); the rest of this press is not a file drag.
    mutating func finish() { finished = true }

    /// The files of the current press's drag when it is a real file drag and they were already read.
    var knownFiles: [URL]? { finished ? nil : files.flatMap { $0.isEmpty ? nil : $0 } }

    /// A drag event. Returns the dragged files when this is a real file drag. The pasteboard is looked at only when
    /// the pointer is near the top (`nearTop`), first its count (cheap) and, once that moved, its files (once per press).
    mutating func dragged(nearTop: Bool, time: Double, changeCount: () -> Int, readFiles: () -> [URL]) -> [URL]? {
        guard !finished else { return nil }
        if let files { return files.isEmpty ? nil : files }
        guard nearTop, let base = baseline ?? lastUpCount else { return nil }
        if let last = lastCheck, time - last < Self.recheck { return nil }
        guard changeCount() != base else { lastCheck = time; return nil }
        let read = readFiles()
        reads += 1
        files = read
        return read.isEmpty ? nil : read
    }
}

extension ClotheslineController {
    /// The operation the line answers a drag with: a link when the source offers one (the line keeps a reference to
    /// the file, which is what a link is, and no source deletes anything for a link), else generic; never copy or
    /// move (the file stays where it is, and the pointer shows no "+"). Nothing when the source offers neither.
    /// Promised files are different: their app writes a new file into YummyOrange's folder, which is a copy, so that
    /// drop answers copy (else generic).
    static func dropOperation(for mask: NSDragOperation, promised: Bool = false) -> NSDragOperation {
        if promised {
            if mask.contains(.copy) { return .copy }
            if mask.contains(.generic) { return .generic }
            return []
        }
        if mask.contains(.link) { return .link }
        if mask.contains(.generic) { return .generic }
        return []
    }

    /// ⌥ held without ⌘ or ⌃: AppKit then narrows a drag to copy, which the line never answers for a file. The monitors
    /// see this before AppKit asks the panel, so such a drag is "another drag" for the line from the start.
    static func narrowsToCopy(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.contains(.option) && !flags.contains(.command) && !flags.contains(.control)
    }

    /// The file URLs on a drag pasteboard (files and folders; nothing else).
    static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    /// What a drag carries for the line: its file URLs, or, when it has none, a stand-in for each file an app promises
    /// to write once it is dropped (`promiseURL`).
    static func dragItems(on pasteboard: NSPasteboard) -> [URL] {
        let files = fileURLs(on: pasteboard)
        if !files.isEmpty { return files }
        return promiseReceivers(on: pasteboard).enumerated().map { promiseURL(index: $0.offset, type: $0.element.fileTypes.first) }
    }

    /// The file promises on a drag pasteboard (Photos, Mail, Safari images).
    static func promiseReceivers(on pasteboard: NSPasteboard) -> [NSFilePromiseReceiver] {
        guard pasteboard.availableType(from: ClotheslineView.dropTypes.filter { $0 != .fileURL }) != nil else { return [] }
        return (pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver]) ?? []
    }

    /// A stand-in for a promised file (not a file URL): its place in the drag and the file's type.
    static func promiseURL(index: Int, type: String?) -> URL {
        var parts = URLComponents()
        parts.scheme = promiseScheme
        parts.host = "promise"
        parts.path = "/\(index)"
        if let type { parts.queryItems = [URLQueryItem(name: "type", value: type)] }
        return parts.url ?? URL(string: "\(promiseScheme)://promise/\(index)")!
    }

    static let promiseScheme = "x-dropwheel-promise"
    static func isPromise(_ url: URL) -> Bool { url.scheme == promiseScheme }

    /// The promised file's type, when the app named one.
    static func promisedType(_ url: URL) -> UTType? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "type" }?.value.flatMap(UTType.init)
    }

    /// The ghost's caption for a promised file: its kind ("JPEG image"), or "1 file".
    static func promisedTypeName(_ url: URL) -> String {
        promisedType(url)?.localizedDescription.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "1 file"
    }

    /// A new folder for promised files, in the temporary directory (session only, like the line).
    static func makePromiseFolder() -> URL? {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("YummyOrange Clothesline", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) == nil ? nil : folder
    }

    static let promiseQueue: OperationQueue = {
        let q = OperationQueue()
        q.qualityOfService = .userInitiated
        return q
    }()

    /// The system's drag pasteboard (one object for the app's life).
    static let dragPasteboard = NSPasteboard(name: .drag)
}

/// A stand-in for AppKit's dragging info (previews and self-tests drive the line's NSDraggingDestination methods with
/// it): a real named pasteboard holding the files (or real file promises of the given types), a location in the view's
/// window coordinates and a source mask.
final class ClotheslineDragInfo: NSObject, NSDraggingInfo {
    let pasteboard: NSPasteboard
    var location: CGPoint
    var mask: NSDragOperation
    var source: Any?
    /// Each stand-in is its own drag session (AppKit numbers its sessions the same way).
    let session: Int
    private static var sessions = 0
    /// The promise providers' delegate (the providers hold it weakly).
    private let promiser = Promiser()

    init(files: [URL], at location: CGPoint, mask: NSDragOperation = [.copy, .move, .link, .generic], text: String? = nil,
         promises: [String] = []) {
        pasteboard = NSPasteboard(name: .init("DropWheel.clothesline.drag.\(UUID().uuidString)"))
        pasteboard.clearContents()
        if !files.isEmpty { pasteboard.writeObjects(files as [NSURL]) }
        let delegate = promiser
        if !promises.isEmpty { pasteboard.writeObjects(promises.map { NSFilePromiseProvider(fileType: $0, delegate: delegate) }) }
        if let text { pasteboard.setString(text, forType: .string) }
        self.location = location
        self.mask = mask
        Self.sessions += 1
        session = Self.sessions
    }
    deinit { pasteboard.releaseGlobally() }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { mask }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { location }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { source }
    var draggingSequenceNumber: Int { session }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}

    /// Names and writes promised files (the stand-in's app).
    private final class Promiser: NSObject, NSFilePromiseProviderDelegate {
        func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
            "Promised.\(UTType(fileType)?.preferredFilenameExtension ?? "dat")"
        }
        func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
            completionHandler((try? Data("promised".utf8).write(to: url)) == nil ? CocoaError(.fileWriteUnknown) : nil)
        }
    }
}
