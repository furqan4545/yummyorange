import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Broad category of a dropped file, decided from its UTType.
enum FileKind: String {
    case image, video, audio, pdf, other

    static func of(_ url: URL) -> FileKind {
        let ext = Ext.of(url)
        if Ext.rawImages.contains(ext) || Ext.svg.contains(ext) || svgExtensions.contains(ext) { return .image }
        // MIDI is a score, not sound: ffmpeg can't decode it, so no audio petal could work.
        if midiExtensions.contains(ext) { return .other }
        // Illustrator saves "PDF compatible" .ai files (its default): a PDF inside, drawn by the PDF path.
        // ImageIO opens them as images with no pixel size, which used to give 1 × 1 results.
        if illustratorExtensions.contains(ext), startsLikePDF(url) { return .pdf }
        // .ts and .mts are MPEG transport streams to macOS, but also TypeScript source files: look inside.
        if transportStreamExtensions.contains(ext), let looksLikeVideo = isTransportStream(url), !looksLikeVideo { return .other }
        if let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension) {
            if type.conforms(to: .pdf) { return .pdf }
            if type.conforms(to: .midi) { return .other }
            if type.conforms(to: .image) { return .image }
            if type.conforms(to: .movie) || type.conforms(to: .video) {
                // An .mp4 or .mov holding only sound (a podcast, a voice memo export) gets the audio wheel.
                if isoMovieExtensions.contains(ext), let tracks = movieTracks(url), !tracks.video, tracks.audio { return .audio }
                return .video
            }
            if type.conforms(to: .audio) { return .audio }
        }
        // Media types this macOS doesn't declare (they resolve to dyn.* types) but ffmpeg reads.
        switch ext {
        case "mkv", "asf", "vob", "divx", "ogm": return .video
        case "mka", "ape", "wv": return .audio
        default: return .other
        }
    }

    /// Extensions shared by MPEG transport streams (video) and other files (TypeScript uses .ts, .mts).
    static let transportStreamExtensions: Set<String> = ["ts", "mts", "m2ts", "m2t"]

    /// SVG spellings: plain and gzip-compressed (.svgz, which SVGRenderer unpacks).
    static let svgExtensions: Set<String> = ["svg", "svgz"]
    /// Standard MIDI files (and karaoke MIDI): notes, not audio.
    static let midiExtensions: Set<String> = ["mid", "midi", "kar", "smf", "rmi"]
    /// Adobe Illustrator documents and templates.
    static let illustratorExtensions: Set<String> = ["ai", "ait"]
    /// QuickTime / ISO base media files, whose track list can be read without ffmpeg.
    static let isoMovieExtensions: Set<String> = ["mp4", "m4v", "mov", "qt", "3gp", "3g2"]

    /// Whether the file is PDF data: "%PDF-" within its first 1024 bytes (where PDF readers look for it).
    static func startsLikePDF(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 1024) else { return false }
        return data.range(of: Data("%PDF-".utf8)) != nil
    }

    /// The handler types of a QuickTime / MP4 file's tracks ('vide', 'soun'), read from moov/trak/mdia/hdlr
    /// by seeking from box to box (the media data is never read). nil when the file isn't laid out that way
    /// (damaged, compressed movie header, fragments only), so callers keep the extension's meaning.
    static func movieTracks(_ url: URL) -> (video: Bool, audio: Bool)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }

        /// The boxes directly inside [start, stop): (type, payload start, box end), up to and including the
        /// first `until` box. Stops at the first box that doesn't fit (trailing junk, a truncated download),
        /// keeping the ones before it.
        func children(_ start: UInt64, _ stop: UInt64, until: String? = nil) -> [(type: String, payload: UInt64, end: UInt64)] {
            var boxes: [(String, UInt64, UInt64)] = []
            var at = start
            while at + 8 <= stop, boxes.count < 10_000 {
                guard (try? handle.seek(toOffset: at)) != nil, let head = try? handle.read(upToCount: 16), head.count >= 8 else { break }
                let b = [UInt8](head)
                var size = UInt64(b[0]) << 24 | UInt64(b[1]) << 16 | UInt64(b[2]) << 8 | UInt64(b[3])
                let type = String(decoding: b[4..<8], as: UTF8.self)
                var header: UInt64 = 8
                if size == 1 {
                    guard b.count >= 16 else { break }
                    size = b[8..<16].reduce(0) { $0 << 8 | UInt64($1) }
                    header = 16
                } else if size == 0 {
                    size = stop - at
                }
                guard size >= header, size <= stop - at else { break }
                boxes.append((type, at + header, at + size))
                if type == until { break }
                at += size
            }
            return boxes
        }

        guard let moov = children(0, end, until: "moov").first(where: { $0.type == "moov" }) else { return nil }
        var video = false, audio = false, found = 0
        for trak in children(moov.payload, moov.end) where trak.type == "trak" {
            guard let mdia = children(trak.payload, trak.end, until: "mdia").first(where: { $0.type == "mdia" }),
                  let hdlr = children(mdia.payload, mdia.end, until: "hdlr").first(where: { $0.type == "hdlr" }),
                  hdlr.end >= hdlr.payload + 12,
                  (try? handle.seek(toOffset: hdlr.payload + 8)) != nil,
                  let handler = try? handle.read(upToCount: 4), handler.count == 4 else { continue }
            found += 1
            switch String(decoding: handler, as: UTF8.self) {
            case "vide": video = true
            case "soun": audio = true
            default: break
            }
        }
        return found > 0 ? (video, audio) : nil
    }

    /// Whether the file's first bytes are MPEG-TS packets: a 0x47 sync byte every 188 bytes
    /// (every 192 in Blu-ray/AVCHD .m2ts/.mts, which put a 4-byte time code before each packet),
    /// found within the first packet in case a capture starts mid-packet. nil when it can't be read
    /// (a missing file keeps its extension's meaning).
    static func isTransportStream(_ url: URL) -> Bool? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 192 * 6) else { return nil }
        let b = [UInt8](data)
        for stride in [188, 192] {
            let packets = min(5, b.count / stride)
            guard packets >= 2 else { continue }
            for start in 0..<stride where start + (packets - 1) * stride < b.count {
                if (0..<packets).allSatisfy({ b[start + $0 * stride] == 0x47 }) { return true }
            }
        }
        return false
    }

    /// The kind shared by every file in a selection, or `.other` when mixed.
    static func common(_ urls: [URL]) -> FileKind {
        let kinds = Set(urls.map(FileKind.of))
        return kinds.count == 1 ? kinds.first! : .other
    }
}

/// An output format a file can be converted to.
enum OutputFormat: String, CaseIterable {
    // images
    case jpg, png, heic, tiff, avif, gif, bmp, webp, pdf
    // video
    case mp4, mov, mkv, webm
    // audio
    case mp3, m4a, wav, flac, ogg, opus, aiff

    var label: String { rawValue.uppercased() }
    var fileExtension: String { rawValue }

    var isVideo: Bool { [.mp4, .mov, .mkv, .webm].contains(self) }
    var isAudio: Bool { [.mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff].contains(self) }

    /// ImageIO destination type, for formats ImageIO can write.
    var imageIOType: String? {
        switch self {
        case .jpg: return UTType.jpeg.identifier
        case .png: return UTType.png.identifier
        case .heic: return UTType.heic.identifier
        case .tiff: return UTType.tiff.identifier
        case .avif: return "public.avif"
        case .gif: return UTType.gif.identifier
        case .bmp: return UTType.bmp.identifier
        default: return nil
        }
    }

    /// Formats offered on the conversion wheel for a given input kind.
    static func targets(for kind: FileKind, source ext: String) -> [OutputFormat] {
        let list: [OutputFormat]
        switch kind {
        case .image: list = [.jpg, .png, .heic, .webp, .tiff, .avif, .gif, .bmp, .pdf]
        case .video: list = [.mp4, .mov, .mkv, .webm, .gif, .mp3, .m4a]
        case .audio: list = [.mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff]
        // A PDF in another wrapper (a PDF-compatible Illustrator file) can also be saved as a plain .pdf.
        case .pdf: list = ext.lowercased() == "pdf" ? [.png, .jpg] : [.png, .jpg, .pdf]
        case .other: list = []
        }
        let src = canonicalExtension(ext)
        return list.filter { $0.rawValue != src && Capabilities.shared.canWrite($0, from: kind) }
    }

    /// The format's own spelling for other spellings of the same format (tif → tiff, aif → aiff,
    /// jpeg → jpg), so a file is never offered a "conversion" into the format it already is.
    static func canonicalExtension(_ ext: String) -> String {
        let e = ext.lowercased()
        switch e {
        case "jpeg", "jpe", "jfif": return "jpg"
        case "tif": return "tiff"
        case "dib": return "bmp"
        case "aif", "aifc": return "aiff"
        case "qt": return "mov"
        default: return e
        }
    }
}

/// Which optional encoders are available on this Mac. Probed once at launch, and again when YummyOrange's own ffmpeg
/// arrives (FFmpegHelper.swift).
final class Capabilities {
    static let shared = Capabilities()

    /// One ffmpeg and what it can do. A new one replaces it whole (under `lock`) when YummyOrange's copy is installed.
    final class FFmpegProbe {
        let found: FFmpegLookup.Found?
        let encoders: Set<String>
        private let filterLock = NSLock()
        private var filterNames: Set<String>?

        private let decoderLock = NSLock()
        private var decoderNames: Set<String>?

        init(_ found: FFmpegLookup.Found?) {
            self.found = found
            encoders = found.map { Self.codecs($0.ffmpeg, "-encoders") } ?? []
        }

        /// Made up, for self-tests: nothing is run.
        init(found: FFmpegLookup.Found?, encoders: Set<String>, filters: Set<String>, decoders: Set<String>? = nil) {
            self.found = found
            self.encoders = encoders
            filterNames = filters
            decoderNames = decoders
        }

        /// The first of `candidates` (FFmpegLookup's order) that runs and lists its encoders. A person's own ffmpeg that
        /// doesn't (a Homebrew ffmpeg missing one of its libraries) is passed over for the next, then YummyOrange's
        /// copy; when none runs there is none, so YummyOrange gets its own.
        static func first(of candidates: [FFmpegLookup.Found]) -> FFmpegProbe {
            for found in candidates {
                let probe = FFmpegProbe(found)
                if !probe.encoders.isEmpty { return probe }
                FFmpegHelper.log.error("ffmpeg at \(found.ffmpeg.path, privacy: .public) doesn’t run; passing it over")
            }
            return FFmpegProbe(nil)
        }

        /// " A....D aac  AAC (Advanced Audio Coding)": the six flag letters, then the name.
        static func codecs(_ ffmpeg: URL, _ list: String) -> Set<String> {
            let out = (try? ProcessRunner.run(ffmpeg, ["-hide_banner", list]).stdout) ?? ""
            var names = Set<String>()
            for line in out.split(separator: "\n") {
                let cols = line.split(separator: " ", omittingEmptySubsequences: true)
                if cols.count >= 2, cols[0].count == 6, cols[0] != "------" { names.insert(String(cols[1])) }
            }
            return names
        }

        /// ffmpeg's decoders, probed the first time one is asked about.
        func decoders() -> Set<String> {
            decoderLock.lock(); defer { decoderLock.unlock() }
            if let decoderNames { return decoderNames }
            let names = found.map { Self.codecs($0.ffmpeg, "-decoders") } ?? []
            decoderNames = names
            return names
        }

        /// ffmpeg's filters, probed the first time one is asked about (older builds lack some).
        func filters() -> Set<String> {
            filterLock.lock(); defer { filterLock.unlock() }
            if let filterNames { return filterNames }
            var names = Set<String>()
            if let ffmpeg = found?.ffmpeg {
                let out = (try? ProcessRunner.run(ffmpeg, ["-hide_banner", "-filters"]).stdout) ?? ""
                for line in out.split(separator: "\n") {
                    let cols = line.split(separator: " ", omittingEmptySubsequences: true)
                    // " TS aap  AA->A  …": a flags column (2 or 3 of . T S C), the name, then the in->out pads.
                    if cols.count >= 3, cols[2].contains("->"), cols[0].allSatisfy({ ".TSC".contains($0) }) { names.insert(String(cols[1])) }
                }
            }
            filterNames = names
            return names
        }
    }

    private let lock = NSLock()
    private var probe: FFmpegProbe
    private var current: FFmpegProbe {
        lock.lock(); defer { lock.unlock() }
        return probe
    }

    /// The ffmpeg in use: the person's own, else YummyOrange's (FFmpegLookup). nil when this Mac has none yet.
    var ffmpeg: URL? { current.found?.ffmpeg }
    /// Which ffmpeg is in use and whose it is.
    var ffmpegFound: FFmpegLookup.Found? { current.found }

    /// `ffmpegFound`, looked for again first when its file has gone since (the Helpers folder deleted, a copy replaced
    /// by a newer YummyOrange, Homebrew's ffmpeg uninstalled): what jobs and the helper ask before they run. A file
    /// check while it is there; the search (which runs ffmpeg) only once it has gone.
    var liveFFmpegFound: FFmpegLookup.Found? {
        let found = current.found
        guard let found, !FileManager.default.isExecutableFile(atPath: found.ffmpeg.path) else { return found }
        refreshFFmpeg()
        return current.found
    }
    let cwebp: URL?
    /// libwebp's animation encoder (ships with cwebp), for animated GIF/PNG → animated WebP.
    let img2webp: URL?
    private let imageIOTypes: Set<String>

    private init() {
        probe = FFmpegProbe.first(of: FFmpegLookup.currentCandidates())
        cwebp = Capabilities.findTool("cwebp")
        img2webp = Capabilities.findTool("img2webp")
        imageIOTypes = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
    }

    /// Looks for ffmpeg again and probes it (any thread but the main one: it runs ffmpeg once). YummyOrange's own copy
    /// calls this once it is in place.
    func refreshFFmpeg() {
        let fresh = FFmpegProbe.first(of: FFmpegLookup.currentCandidates())
        lock.lock(); probe = fresh; lock.unlock()
    }

    #if DEBUG
    /// Self-tests: makes `probe` the ffmpeg in use and returns the one it replaces (to put back).
    @discardableResult
    func swapFFmpegProbe(_ replacement: FFmpegProbe) -> FFmpegProbe {
        lock.lock(); defer { lock.unlock() }
        let old = probe
        probe = replacement
        return old
    }
    #endif

    func has(_ encoder: String) -> Bool { current.encoders.contains(encoder) }

    /// Whether this Mac's ffmpeg has the filter `name` (e.g. "pixelize", "showcqt", "aeval").
    func hasFilter(_ name: String) -> Bool { current.filters().contains(name) }

    /// A box blur: boxblur (a GPL-only filter, in Homebrew's ffmpeg), or avgblur, which every build has (YummyOrange's
    /// own LGPL copy among them). BoxBlur.filter writes whichever is here.
    var hasBoxBlur: Bool { hasFilter("boxblur") || hasFilter("avgblur") }

    /// Whether this Mac's ffmpeg decodes AV1 in software (dav1d or libaom). FFmpeg's own AV1 decoder, the only one in
    /// YummyOrange's copy, needs the Mac's hardware decoder (M3 and later), asked for with `-hwaccel videotoolbox`.
    var decodesAV1InSoftware: Bool { !current.decoders().isDisjoint(with: ["libdav1d", "libaom-av1"]) }

    /// Audio and video work can be offered: ffmpeg is here, or YummyOrange can get its own copy the moment a task needs
    /// it. Cheap: the wheels ask it while they open.
    var mediaAvailable: Bool { ffmpeg != nil || FFmpegHelper.shared.canFetch }

    /// `has(encoder)`, or, while this Mac has no ffmpeg, whether YummyOrange's own copy (which it can download) has it.
    func offers(_ encoder: String) -> Bool {
        let probe = current
        if probe.found != nil { return probe.encoders.contains(encoder) }
        return FFmpegHelper.shared.canFetch && FFmpegHelper.buildIncludes(encoder: encoder)
    }

    func canWrite(_ format: OutputFormat, from kind: FileKind) -> Bool {
        switch kind {
        case .image, .pdf:
            if format == .pdf { return true }
            if format == .webp { return cwebp != nil || offers("libwebp") }
            if let t = format.imageIOType { return imageIOTypes.contains(t) }
            return false
        case .video, .audio:
            guard mediaAvailable else { return false }
            if format == .webm { return offers("libvpx-vp9") }
            if format == .gif { return kind == .video }
            return format.isVideo ? kind == .video : format.isAudio
        case .other:
            return false
        }
    }

    /// Looks for a command-line tool: inside the app bundle first, then common install locations.
    static func findTool(_ name: String) -> URL? {
        for dir in FFmpegLookup.userFolders() {
            let candidate = dir.appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}

/// Picks an unused file name next to the source: "photo.png", then "photo 2.png", ...
func outputURL(for source: URL, ext: String, suffix: String = "") -> URL {
    let dir = source.deletingLastPathComponent()
    let base = source.deletingPathExtension().lastPathComponent + suffix
    var candidate = dir.appendingPathComponent(base).appendingPathExtension(ext)
    var n = 2
    while FileManager.default.fileExists(atPath: candidate.path) {
        candidate = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
        n += 1
    }
    return candidate
}
