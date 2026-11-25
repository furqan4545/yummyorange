import AppKit

/// Merge (two or more videos, or two or more sounds): joins the files into one new file, "<first name> merged.<ext>",
/// next to the first file. It runs at once (no form, no window); the HUD shows its progress.
///
/// Order: exactly the order YummyOrange receives the files in, never sorted: on a drop, the order of the files on the
/// drag's pasteboard (the app the drag comes from decides it); on the command line, the order of the arguments
/// (`--tool merge a.mp4 b.mkv c.wmv` gives a, then b, then c).
///
/// Videos (every file has a picture):
/// - The result keeps the first file's container when it can hold it (mp4, m4v, mov, mkv), else it is an .mp4.
/// - Fast path, lossless: when every file has the same streams with the same parameters (container family, H.264 or
///   HEVC with byte-identical parameter sets, profile, size, pixel format and colour tags, pixel aspect, base frame
///   rate, time base, rotation; same audio codec, rate and layout), the pictures are joined with ffmpeg's concat
///   demuxer and copied packet for packet. The sound is decoded and encoded once more (the first file's codec, its bit
///   rate; PCM stays PCM): copying AAC packets keeps each file's encoder priming at the joins, which put 2800 extra
///   samples (63 ms) into clip.mp4 + clip.mp4 and moved the second file's sound off its picture. The result is checked
///   (frame count equal to the sum, picture and sound lengths within a frame of the sum) and re-encoded when it isn't
///   right.
/// - Otherwise (re-encode): ffmpeg's concat filter. Each file's picture is turned upright, scaled to fit the first
///   video's display size (never stretched: letterboxed or pillarboxed in black, square pixels, even sizes; a fit
///   within 2 pixels of the frame fills it, so even-size rounding leaves no hairline bar), at the first video's frame
///   rate (constant), BT.709, H.264 through VideoToolbox with the settings Convert uses (`-q:v 65`), AAC 48 kHz,
///   stereo (mono when every file with sound is mono), 192 kb/s (128 for mono).
/// - Each file is one stretch of the result as long as its picture (the end of its last frame on its own clock).
///   Its sound is placed on that clock (sound that starts late keeps its place, `MediaKit.soundFromZero`), padded
///   with silence or cut to the stretch, so picture and sound line up at every join and the next file starts right
///   after the previous one. A file without sound gets silence. Sound that runs on a little after a file's last
///   frame is cut there (sample.wmv's runs 0.04 s past its last frame: 4.086 s of sound, 4.046 s of picture); sound
///   that runs on more than two frames and 0.1 s (a still picture with a song) keeps the stretch going to its end,
///   with the last frame held.
/// - A file cut with `-c copy` between key frames (an edit list hiding the frames before the cut) is re-encoded:
///   copied into the middle of the result, its hidden frames would show at the join.
/// - The result goes next to the first file; a folder YummyOrange can't write to is reported before anything runs.
///
/// Sounds (no file has a picture): the first file's format when YummyOrange writes it, else .m4a; its sample rate
/// (48 kHz at most for MP3 and WMA, 48 kHz for Opus); its channel layout when every file has it, mono when every file
/// is mono, else stereo (mono files go to both ears at full level). Every file's decoded samples follow the previous
/// file's, sample for sample (always decoded and encoded once: copying MP3 or AAC packets can't join exactly; PCM and
/// FLAC stay lossless).
///
/// All or nothing: inputs are only read, the output never overwrites anything (`outputURL`), and a failed merge
/// leaves no file. A video and a sound together are refused (the petal isn't offered; the command line says so).
enum MediaMerge {
    static let command = WheelCommand(
        wheel: .tools, id: "merge", title: "Merge", symbol: MediaTools.symbol("arrow.triangle.merge", or: "rectangle.stack"),
        combinesInputs: true, applies: applies,
        run: { files, _, progress in [try merge(files, progress: progress)] })

    /// Two or more files, all video or all sound only (by type, so it’s cheap), and ffmpeg is installed or YummyOrange can get it.
    static func applies(_ files: [URL]) -> Bool {
        guard files.count >= 2, Capabilities.shared.mediaAvailable else { return false }
        let kind = MoreFormats.kind(files[0])
        return (kind == .video || kind == .audio) && files.allSatisfy { MoreFormats.kind($0) == kind }
    }

    enum Method: String { case copy, reencode, sound }
    /// How the last merge was written, and why the fast path wasn't taken (for the self-test and the report).
    static var lastMethod: Method?
    static var lastCopyRefusal: String?

    static let suffix = " merged"
    /// Containers a merged video keeps; anything else becomes an .mp4.
    static let videoContainers: Set<String> = ["mp4", "m4v", "mov", "mkv"]

    // MARK: Inputs

    /// One file as the merge sees it: the probe, ffmpeg's report (file name and tags removed) and a packet scan.
    struct Input {
        let source: MediaSource
        let report: String
        /// The container's start time ("Duration: …, start: 0.000000").
        let formatStart: Double
        var scan = Scan()
        var name: String { source.name }
    }

    /// What reading every packet (no decoding) tells: the picture's frame count and where its last frame ends, where
    /// the sound ends, both on the file's clock, and each stream's codec configuration (size and CRC of its extradata).
    struct Scan {
        var videoPackets = 0
        /// Picture packets before the file's start: marked to be discarded (`F=0x4`, an edit list that starts between
        /// key frames, as `-c copy` cuts and passthrough trims make) or with a time before 0. A player never shows them.
        var videoPreroll = 0
        /// When the first frame is shown (its pts), and where the last one ends.
        var videoStart: Double?
        var videoEnd: Double?
        var audioEnd: Double?
        var extradata: [String] = []
    }

    /// Merges `files` in the given order. `allowCopy: false` always re-encodes videos (tests compare the two paths).
    static func merge(_ files: [URL], allowCopy: Bool = true, progress: @escaping (Double) -> Void) throws -> URL {
        let ff = try MediaKit.ffmpeg()
        guard files.count >= 2 else {
            throw ConversionError.unsupported("Merge joins two or more files. Select two or more videos, or two or more sounds, and merge them together.")
        }
        let inputs = try files.map { try inspect($0, ff: ff) }
        let pictures = inputs.filter { $0.source.hasVideo }
        if !pictures.isEmpty, pictures.count < inputs.count, let sound = inputs.first(where: { !$0.source.hasVideo }) {
            throw ConversionError.unsupported("Merge joins videos with videos, or sounds with sounds, but \(pictures[0].name) is a video and "
                                              + "\(sound.name) is sound only. Select only videos, or only sounds, and merge again.")
        }
        // The result goes next to the first file. Say so plainly when that folder can't take it (ffmpeg's "Permission
        // denied" on the output path read as if an input were at fault).
        let folder = files[0].deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            throw ConversionError.unsupported("YummyOrange can’t save the merged file in “\(folder.lastPathComponent)”, the folder of "
                                              + "\(files[0].lastPathComponent), because it’s read-only. Move the files to a folder you can write to, then merge again.")
        }
        if pictures.isEmpty { return try mergeSounds(inputs, ff: ff, progress: progress) }
        return try mergeVideos(inputs, allowCopy: allowCopy, ff: ff, progress: progress)
    }

    /// Probes a file and reads all its packets in one ffmpeg run (nothing is decoded): the stream report from stderr
    /// (what `MediaSource.load` reads), and from stdout every packet of the first video and first audio stream
    /// (`-c copy -f framecrc`). Times are on the file's clock (ffmpeg subtracts the container's start). The messages
    /// name the file and say what to do.
    static func inspect(_ url: URL, ff: FFmpeg) throws -> Input {
        let name = url.lastPathComponent
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw ConversionError.unsupported("Couldn’t read \(name). Check that it still exists and that you can open it, then merge again.")
        }
        var parser = PacketParser()
        let run = try runReading(ff.tool, ["-hide_banner", "-nostdin", "-nostats", "-i", url.path, "-map", "0:v:0?", "-map", "0:a:0?",
                                           "-c", "copy", "-f", "framecrc", "-"]) { parser.feed($0) }
        parser.finish()
        // Only the input's part of the report: ffmpeg goes on to describe its output, with stream lines of its own.
        var text = run.stderr
        for marker in ["\nStream mapping:", "\nOutput #"] {
            if let r = text.range(of: marker) { text = String(text[..<r.lowerBound]) }
        }
        let source = MediaSource.parse(text, url: url)
        guard source.probe.opened else {
            throw ConversionError.unsupported("\(name) can’t be read as video or audio. It may be damaged, incomplete or not a media file. "
                                              + "Leave it out, or convert it first, then merge again.")
        }
        guard source.hasVideo || source.hasAudio else {
            throw ConversionError.unsupported("\(name) has no picture or sound to merge. Leave it out and merge the others.")
        }
        guard run.status == 0 else {
            throw ConversionError.unsupported("Couldn’t read all of \(name); it may be damaged. Convert it first, then merge the copy.")
        }
        let report = MediaSource.withoutTags(url.path.isEmpty ? text : text.replacingOccurrences(of: url.path, with: "<file>"))
        var start = 0.0
        if let m = report.firstMatch(of: #/Duration: [^,]*, start: (-?[0-9.]+)/#), let v = Double(m.1) { start = v }
        var scan = Scan()
        let streams = parser.mediaType.keys.sorted()
        if source.hasVideo, let v = streams.first(where: { parser.mediaType[$0] == "video" }) {
            scan.videoPackets = parser.packets[v] ?? 0
            scan.videoPreroll = parser.preroll[v] ?? 0
            scan.videoEnd = parser.end(of: v, frame: source.frameDuration)
            scan.videoStart = parser.start(of: v)
        }
        if source.hasAudio, let a = streams.first(where: { parser.mediaType[$0] == "audio" }) {
            scan.audioEnd = parser.end(of: a, frame: 0)
        }
        scan.extradata = streams.compactMap { i in parser.extradata[i].map { "\(parser.mediaType[i] ?? "?") extradata \($0)" } }
        return Input(source: source, report: report, formatStart: start, scan: scan)
    }

    /// Reads ffmpeg's framecrc lines as they arrive, byte by byte (a long film has hundreds of thousands): per stream
    /// its time base, media type, extradata, packet count and the latest end (pts + duration; a packet without a
    /// duration ends a frame after its pts).
    struct PacketParser {
        var timeBase: [Int: Double] = [:]
        var mediaType: [Int: String] = [:]
        var extradata: [Int: String] = [:]
        var packets: [Int: Int] = [:]
        /// Packets marked to be discarded (flag 0x4) or timed before 0, per stream.
        var preroll: [Int: Int] = [:]
        private var ends: [Int: Int64] = [:]
        private var undated: [Int: Int64] = [:]
        private var starts: [Int: Int64] = [:]
        private var line: [UInt8] = []

        mutating func feed(_ data: Data) {
            data.withUnsafeBytes { raw in
                for byte in raw.bindMemory(to: UInt8.self) {
                    if byte == 0x0A { take(); line.removeAll(keepingCapacity: true) } else { line.append(byte) }
                }
            }
        }

        mutating func finish() {
            if !line.isEmpty { take(); line.removeAll() }
        }

        /// The earliest pts of the stream in seconds.
        func start(of stream: Int) -> Double? {
            guard let tb = timeBase[stream], tb > 0, let s = starts[stream] else { return nil }
            return Double(s) * tb
        }

        /// The end of the stream's last packet in seconds (`frame` is the length of a packet without a duration).
        func end(of stream: Int, frame: Double) -> Double? {
            guard let tb = timeBase[stream], tb > 0 else { return nil }
            var best = ends[stream].map { Double($0) * tb }
            if let u = undated[stream] { best = max(best ?? -.infinity, Double(u) * tb + frame) }
            return best
        }

        private mutating func take() {
            guard let first = line.first else { return }
            if first == UInt8(ascii: "#") { header(String(decoding: line, as: UTF8.self)); return }
            // "stream, dts, pts, duration, size, crc[, flags…]": the first four are integers (AV_NOPTS_VALUE wraps to Int64.min).
            var values: [Int64] = []
            var value: Int64 = 0, negative = false
            scanning: for byte in line {
                switch byte {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): value = value &* 10 &+ Int64(byte &- 48)
                case UInt8(ascii: "-"): negative = true
                case UInt8(ascii: ","):
                    values.append(negative ? 0 &- value : value)
                    value = 0; negative = false
                    if values.count == 4 { break scanning }
                default: break
                }
            }
            guard values.count == 4 else { return }
            let stream = Int(values[0]), pts = values[2], duration = values[3]
            packets[stream, default: 0] += 1
            if (flags() ?? 0) & 0x4 != 0 || (pts != Int64.min && pts < 0) { preroll[stream, default: 0] += 1 }
            guard pts != Int64.min else { return }
            starts[stream] = min(starts[stream] ?? .max, pts)
            if duration > 0 { ends[stream] = max(ends[stream] ?? .min, pts &+ duration) }
            else { undated[stream] = max(undated[stream] ?? .min, pts) }
        }

        /// The packet's flags from "…, F=0x5" (1 key frame, 4 discard); nil when the line has none.
        private func flags() -> Int? {
            let n = line.count
            var i = 0
            while i + 4 <= n {
                if line[i] == UInt8(ascii: "F"), line[i + 1] == UInt8(ascii: "="), line[i + 2] == UInt8(ascii: "0"), line[i + 3] == UInt8(ascii: "x") {
                    var value = 0, j = i + 4
                    while j < n, j - i < 12 {
                        let b = line[j]
                        let digit: Int
                        switch b {
                        case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = Int(b - UInt8(ascii: "0"))
                        case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = Int(b - UInt8(ascii: "a")) + 10
                        case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = Int(b - UInt8(ascii: "A")) + 10
                        default: return value
                        }
                        value = value * 16 + digit
                        j += 1
                    }
                    return value
                }
                i += 1
            }
            return nil
        }

        private mutating func header(_ s: String) {
            if let m = s.firstMatch(of: #/^#tb (\d+): (\d+)\/(\d+)/#), let i = Int(m.1), let n = Double(m.2), let d = Double(m.3), d > 0 {
                timeBase[i] = n / d
            } else if let m = s.firstMatch(of: #/^#media_type (\d+): (\w+)/#), let i = Int(m.1) {
                mediaType[i] = String(m.2)
            } else if let m = s.firstMatch(of: #/^#extradata (\d+):\s*(.*)$/#), let i = Int(m.1) {
                extradata[i] = String(m.2).split(separator: " ").joined(separator: " ")
            }
        }
    }

    /// Runs a tool, handing its stdout to `onStdout` as it arrives, and returns its exit status and stderr.
    private static func runReading(_ tool: URL, _ args: [String], onStdout: (Data) -> Void) throws -> (status: Int32, stderr: String) {
        let process = Process()
        process.executableURL = tool
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let lock = NSLock()
        var errData = Data()
        err.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            lock.lock(); errData.append(chunk); lock.unlock()
        }
        try process.run()
        let handle = out.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            onStdout(chunk)
        }
        process.waitUntilExit()
        err.fileHandleForReading.readabilityHandler = nil
        let rest = err.fileHandleForReading.readDataToEndOfFile()
        lock.lock(); errData.append(rest); lock.unlock()
        return (process.terminationStatus, String(decoding: errData, as: UTF8.self))
    }

    // MARK: Videos

    private static func mergeVideos(_ inputs: [Input], allowCopy: Bool, ff: FFmpeg, progress: @escaping (Double) -> Void) throws -> URL {
        let first = inputs[0].source
        let pictures = try inputs.map(pictureLength)
        let lengths = zip(inputs, pictures).map { stretchLength($0, picture: $1) }
        let ext = videoContainers.contains(first.ext) ? first.ext : "mp4"
        let out = outputURL(for: first.url, ext: ext, suffix: suffix)
        lastCopyRefusal = allowCopy ? copyRefusal(inputs) : "the fast path was turned off"
        if lastCopyRefusal == nil {
            if try copyVideos(inputs, pictures: pictures, lengths: lengths, ext: ext, to: out, ff: ff, progress: progress) {
                lastMethod = .copy
                return out
            }
        }
        try reencodeVideos(inputs, pictures: pictures, lengths: lengths, ext: ext, to: out, ff: ff, progress: progress)
        lastMethod = .reencode
        return out
    }

    /// Where a video's picture ends: from 0 on its own clock to the end of its last frame (from the packet scan; the
    /// container's length when the scan found no times), never more than a second past the container's length (a
    /// damaged time stamp mustn't turn a clip into hours of its last frame).
    static func pictureLength(_ input: Input) throws -> Double {
        let s = input.source
        var length = input.scan.videoEnd ?? s.duration
        if s.duration > 0 { length = min(length, s.duration + 1) }
        guard length.isFinite, length > 0.0005 else {
            throw ConversionError.unsupported("\(s.name) reports no length, so it can’t be merged. Convert it first, then merge the copy.")
        }
        return length
    }

    /// The stretch a video takes in the result: its picture, or its sound when that runs on more than two frames (and
    /// 0.1 s) past the last frame, as in a still picture with a song: the last frame is held, so no sound is lost.
    /// A shorter overhang (sample.wmv's 0.04 s, an AAC packet's padding) ends with the picture.
    static func stretchLength(_ input: Input, picture: Double) -> Double {
        let s = input.source
        guard s.hasAudio, var sound = input.scan.audioEnd, sound.isFinite else { return picture }
        if s.duration > 0 { sound = min(sound, s.duration + 1) }
        return sound - picture > max(2 * s.frameDuration, 0.1) ? sound : picture
    }

    /// The parameters that must match for the pictures to be copied: every stream line of the report without bit
    /// rates, average frame rates (a phone's variable-rate clips report slightly different ones) and start times,
    /// plus the rotation, Dolby Vision records and each stream's codec configuration.
    static func streamSignature(_ input: Input) -> [String] {
        var sig: [String] = []
        for line in input.report.split(separator: "\n") {
            if line.contains("DOVI") { sig.append(line.trimmingCharacters(in: .whitespaces)); continue }
            guard line.contains("Stream #"), let m = line.firstMatch(of: #/Stream #\d+:\d+[^:]*: (\w+): (.*)$/#) else { continue }
            var fields = splitFields(String(m.2))
            if let last = fields.indices.last {
                fields[last] = fields[last].replacing(#/(\s*\([a-z ]+\))+$/#, with: "")
            }
            fields.removeAll { $0.hasSuffix("kb/s") || $0.hasSuffix(" fps") || $0.hasPrefix("start ") }
            sig.append("\(m.1): " + fields.joined(separator: ", "))
        }
        sig.append("rotation \(input.source.rotation)")
        sig += input.scan.extradata
        return sig
    }

    /// Why the pictures can't be copied (nil when they can).
    static func copyRefusal(_ inputs: [Input]) -> String? {
        let first = inputs[0]
        guard videoContainers.contains(first.source.ext) else { return "\(first.name) isn’t an mp4, m4v, mov or mkv" }
        func family(_ ext: String) -> String { ext == "mkv" ? "mkv" : MediaEncode.isISO(ext) ? "iso" : ext }
        let signature = streamSignature(first)
        for input in inputs {
            if family(input.source.ext) != family(first.source.ext) { return "\(input.name) is in another kind of container" }
            if abs(input.formatStart) > 0.001 { return "\(input.name) starts at \(input.formatStart) s" }
            if input.source.url.path.contains(where: { $0 == "\n" || $0 == "\r" }) { return "\(input.name)’s path has a line break" }
            guard let codec = input.source.videoCodec, ["h264", "hevc"].contains(codec) else {
                return "\(input.name)’s picture is \(input.source.videoCodec ?? "unknown"), not H.264 or HEVC"
            }
            if input.scan.videoPackets == 0 { return "\(input.name) has no picture packets" }
            // Copied into the middle of the result, frames a file hides before its start would show at the join.
            if input.scan.videoPreroll > 0 {
                return "\(input.name) has \(input.scan.videoPreroll) hidden frames before its start (a copy cut between key frames)"
            }
            if streamSignature(input) != signature { return "\(input.name)’s streams differ from \(first.name)’s" }
        }
        return nil
    }

    /// The fast path: pictures copied through the concat demuxer (each file's stretch set to its length, so a held
    /// last frame shows until the next file's first), sound rebuilt from the files. Returns false, leaving nothing
    /// behind, when the result doesn't check out.
    private static func copyVideos(_ inputs: [Input], pictures: [Double], lengths: [Double], ext: String, to out: URL, ff: FFmpeg,
                                   progress: @escaping (Double) -> Void) throws -> Bool {
        let first = inputs[0].source
        let list = FileManager.default.temporaryDirectory.appendingPathComponent("dropwheel-merge-\(UUID().uuidString).ffconcat")
        var text = "ffconcat version 1.0\n"
        for (input, length) in zip(inputs, lengths) {
            text += "file '" + ("file:" + input.source.url.path).replacingOccurrences(of: "'", with: "'\\''") + "'\n"
            text += "duration \(MediaTime.arg(length))\n"
        }
        try text.write(to: list, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: list) }

        var extra: [String] = []
        var args: [String] = []
        let total = lengths.reduce(0, +)
        if first.hasAudio {
            let rate = first.sampleRate ?? 48_000
            var graph: [String] = []
            var pads = ""
            for (k, input) in inputs.enumerated() {
                extra += ["-i", input.source.url.path]
                let n = samples(in: k, lengths: lengths, rate: rate)
                let chain = MediaKit.soundFromZero(input.source) + ["apad=whole_len=\(n)", "atrim=end_sample=\(n)", "asetpts=N/SR/TB"]
                graph.append("[\(k + 1):a:0]" + chain.joined(separator: ",") + "[a\(k)]")
                pads += "[a\(k)]"
            }
            graph.append(pads + "concat=n=\(inputs.count):v=0:a=1[a]")
            args += ["-filter_complex", graph.joined(separator: ";"), "-map", "0:v:0", "-map", "[a]"]
        } else {
            args += ["-map", "0:v:0", "-an"]
        }
        args += ["-c:v", "copy"]
        if first.videoCodec == "hevc", MediaEncode.isISO(ext) { args += ["-tag:v", "hvc1"] }
        if first.hasAudio { args += copySoundArgs(first, ext: ext) }
        args += ["-map_chapters", "-1"] + MediaEncode.containerArgs(ext)
        do {
            // -copyts: the concat demuxer's start is the first file's earliest packet (AAC priming, -0.023 s), which
            // ffmpeg would otherwise subtract, moving every picture 23 ms late.
            try ff.run(input: list, output: out, args: args, duration: total,
                       inputOptions: ["-copyts", "-f", "concat", "-safe", "0", "-auto_convert", "0"],
                       extraInputs: extra, progress: { progress($0 * 0.9) })
        } catch {
            try? FileManager.default.removeItem(at: out)
            lastCopyRefusal = "the copy failed: \(error.localizedDescription)"
            return false
        }
        // Check: every frame is there, and the picture and sound end where the stretches add up to.
        let fd = first.frameDuration
        let frames = inputs.map(\.scan.videoPackets).reduce(0, +)
        var problem: String?
        if let result = (try? inspect(out, ff: ff))?.scan {
            // The picture starts where the first file's does (within 2 ms) and ends within half a frame of where the last
            // file's picture ends; the sound ends within half a frame of the stretches' sum.
            let start = inputs[0].scan.videoStart ?? 0
            let pictureEnd = total - (lengths.last ?? 0) + (pictures.last ?? 0)
            if result.videoPackets != frames { problem = "\(result.videoPackets) frames instead of \(frames)" }
            else if abs((result.videoStart ?? -1) - start) > 0.002 { problem = "the picture starts at \(result.videoStart ?? -1) s instead of \(start) s" }
            else if let end = result.videoEnd, abs(end - pictureEnd) > fd / 2 { problem = "the picture ends at \(end) s instead of \(pictureEnd) s" }
            else if first.hasAudio, abs((result.audioEnd ?? 0) - total) > fd / 2 { problem = "the sound ends at \(result.audioEnd ?? 0) s instead of \(total) s" }
        } else {
            problem = "the result can’t be read"
        }
        progress(1)
        if let problem {
            try? FileManager.default.removeItem(at: out)
            lastCopyRefusal = "the copy didn’t check out: \(problem)"
            return false
        }
        return true
    }

    /// The sound of a copied merge: the first file's codec (PCM stays PCM in mov and mkv; AAC otherwise, at about the
    /// source's bit rate), with its rate and layout (the files share them).
    private static func copySoundArgs(_ source: MediaSource, ext: String) -> [String] {
        if let codec = source.audioCodec, codec.hasPrefix("pcm_"), ["mov", "mkv"].contains(ext), Capabilities.shared.has(codec) {
            return ["-c:a", codec]
        }
        return codecArgs(MediaEncode.audioCodecArgs(for: source, ext: ext))
    }

    /// The samples stretch `k` gets at `rate`: from the rounded start of the stretch to the rounded end, so the sound
    /// never drifts from the picture by more than half a sample however many files there are.
    static func samples(in k: Int, lengths: [Double], rate: Int) -> Int {
        let start = lengths.prefix(k).reduce(0, +), end = start + lengths[k]
        return Int((end * Double(rate)).rounded()) - Int((start * Double(rate)).rounded())
    }

    /// The re-encode: the concat filter over every file's picture (upright, fitted, constant rate) and sound.
    private static func reencodeVideos(_ inputs: [Input], pictures: [Double], lengths: [Double], ext: String, to out: URL, ff: FFmpeg,
                                       progress: @escaping (Double) -> Void) throws {
        let first = inputs[0].source
        let frame = first.displaySize
        let width = max(2, Int(frame.width) / 2 * 2), height = max(2, Int(frame.height) / 2 * 2)
        let rateText = first.probe.constantRate
        let fps = rateValue(rateText)
        let withSound = inputs.contains { $0.source.hasAudio }
        let mono = inputs.filter { $0.source.hasAudio }.allSatisfy { ($0.source.channels ?? 2) == 1 }
        let layout = mono ? "mono" : "stereo"
        // Every stretch is a whole number of frames; the sound follows the frames' times.
        let frames = lengths.map { max(1, Int(($0 * fps).rounded())) }
        let stretches = frames.map { Double($0) / fps }

        var graph: [String] = []
        var pads = ""
        for (k, input) in inputs.enumerated() {
            let s = input.source
            let fit = fitted(s.displaySize, into: width, height)
            var scale = "scale=\(fit.width):\(fit.height)"
            if s.colorMatrix == nil {
                let hd = s.pixelSize.height >= 720 || s.pixelSize.width >= 1280
                scale += ":in_color_matrix=" + (hd ? "bt709" : "bt601")
            }
            scale += ":out_color_matrix=bt709:out_range=tv"
            let x = (width - fit.width) / 4 * 2, y = (height - fit.height) / 4 * 2
            // The last frame is held to the end of the stretch (two frames of slack, or to the end of a longer sound).
            let hold = max(2, frames[k] - Int((pictures[k] * fps).rounded(.down)) + 2)
            graph.append("[\(k):v:0]fps=\(rateText):start_time=0,\(scale),setsar=1,pad=\(width):\(height):\(x):\(y):black,format=yuv420p,"
                         + "setparams=colorspace=bt709:color_primaries=bt709:color_trc=bt709:range=tv,"
                         + "tpad=stop_mode=clone:stop=\(hold),trim=end_frame=\(frames[k]),setpts=PTS-STARTPTS[v\(k)]")
            pads += "[v\(k)]"
            guard withSound else { continue }
            let n = samples(in: k, lengths: stretches, rate: 48_000)
            if s.hasAudio {
                var chain = MediaKit.soundFromZero(s) + ["aresample=48000"]
                if !mono, (s.channels ?? 2) == 1 { chain.append("pan=stereo|c0=c0|c1=c0") }
                chain += ["aformat=sample_fmts=fltp:channel_layouts=\(layout)", "apad=whole_len=\(n)", "atrim=end_sample=\(n)", "asetpts=N/SR/TB"]
                graph.append("[\(k):a:0]" + chain.joined(separator: ",") + "[a\(k)]")
            } else {
                graph.append("anullsrc=r=48000:cl=\(layout),aformat=sample_fmts=fltp,atrim=end_sample=\(n),asetpts=N/SR/TB[a\(k)]")
            }
            pads += "[a\(k)]"
        }
        graph.append(pads + "concat=n=\(inputs.count):v=1:a=\(withSound ? 1 : 0)[v]" + (withSound ? "[a]" : ""))

        var args = ["-filter_complex", graph.joined(separator: ";"), "-map", "[v]"] + (withSound ? ["-map", "[a]"] : [])
        args += MediaEncode.videoCodecArgs(for: first, ext: ext, quality: 65)
        args += withSound ? ["-c:a", "aac", "-b:a", mono ? "128k" : "192k"] : ["-an"]
        args += ["-map_chapters", "-1"] + MediaEncode.containerArgs(ext)
        let extra = inputs.dropFirst().flatMap { ["-i", $0.source.url.path] }
        do {
            try ff.run(input: first.url, output: out, args: args, duration: stretches.reduce(0, +), extraInputs: extra, progress: progress)
        } catch {
            throw failure(error, writing: out, what: "videos")
        }
    }

    /// `size` scaled to fit `width` × `height` without changing its shape, in even pixels; a fit within 2 pixels of
    /// the frame (the rounding to even sizes) fills it.
    static func fitted(_ size: CGSize, into width: Int, _ height: Int) -> (width: Int, height: Int) {
        guard size.width > 0, size.height > 0 else { return (width, height) }
        let scale = min(Double(width) / Double(size.width), Double(height) / Double(size.height))
        func even(_ v: Double, _ limit: Int) -> Int { min(limit, max(2, Int((v / 2).rounded()) * 2)) }
        let w = even(Double(size.width) * scale, width), h = even(Double(size.height) * scale, height)
        return abs(w - width) <= 2 && abs(h - height) <= 2 ? (width, height) : (w, h)
    }

    /// "30000/1001" → 29.97…, "25" → 25.
    static func rateValue(_ text: String) -> Double {
        let parts = text.split(separator: "/").compactMap { Double($0) }
        if parts.count == 2, parts[1] > 0 { return parts[0] / parts[1] }
        return parts.first.flatMap { $0 > 0 ? $0 : nil } ?? 30
    }

    // MARK: Sounds

    private static func mergeSounds(_ inputs: [Input], ff: FFmpeg, progress: @escaping (Double) -> Void) throws -> URL {
        let first = inputs[0].source
        let ext = MediaEncode.outputExtension(for: first)
        var rate = first.sampleRate ?? 48_000
        if ["mp3", "wma", "asf", "wmv"].contains(ext) { rate = min(rate, 48_000) }
        if ext == "opus" || ext == "webm" { rate = 48_000 }
        let counts = inputs.map { $0.source.channels ?? 2 }
        var layout = "stereo"
        if counts.allSatisfy({ $0 == 1 }) {
            layout = "mono"
        } else if let own = first.info.audioLayout, !own.contains(" "), inputs.allSatisfy({ $0.source.info.audioLayout == own }) {
            layout = own
        }
        if (counts.first ?? 2) > 2, layout != "stereo", ["mp3", "wma", "asf", "wmv"].contains(ext) { layout = "stereo" }
        var graph: [String] = []
        var pads = ""
        for (k, input) in inputs.enumerated() {
            // Each file's samples as decoded, back to back (no padding for where its sound "starts").
            var chain = ["asetpts=N/SR/TB", "aresample=\(rate)"]
            if layout == "stereo", (input.source.channels ?? 2) == 1 { chain.append("pan=stereo|c0=c0|c1=c0") }
            chain += ["aformat=channel_layouts=\(layout)", "asetpts=N/SR/TB"]
            graph.append("[\(k):a:0]" + chain.joined(separator: ",") + "[a\(k)]")
            pads += "[a\(k)]"
        }
        graph.append(pads + "concat=n=\(inputs.count):v=0:a=1[a]")
        let out = outputURL(for: first.url, ext: ext, suffix: suffix)
        let args = ["-filter_complex", graph.joined(separator: ";"), "-map", "[a]", "-vn"]
            + codecArgs(MediaEncode.audioCodecArgs(for: first, ext: ext)) + ["-map_chapters", "-1"] + MediaEncode.containerArgs(ext)
        let total = inputs.map { $0.scan.audioEnd ?? $0.source.duration }.reduce(0, +)
        let extra = inputs.dropFirst().flatMap { ["-i", $0.source.url.path] }
        do {
            try ff.run(input: first.url, output: out, args: args, duration: total, extraInputs: extra, progress: progress)
        } catch {
            throw failure(error, writing: out, what: "sounds")
        }
        lastMethod = .sound
        lastCopyRefusal = nil
        return out
    }

    /// ffmpeg's failure as a sentence that says what to do: about the result when ffmpeg names it or the disk is full,
    /// else about the input it names.
    private static func failure(_ error: Error, writing out: URL, what: String) -> ConversionError {
        let text = sentence(error.localizedDescription)
        if text.contains(out.path) || text.localizedCaseInsensitiveContains("No space left") {
            return .toolFailed("Couldn’t write \(out.lastPathComponent): \(text.replacingOccurrences(of: out.path, with: out.lastPathComponent)) "
                               + "Make room on the disk, or move the files to a folder you can write to, then merge again.")
        }
        return .toolFailed("Couldn’t merge the \(what): \(text) Convert the file it names first, then merge again.")
    }

    /// `text` ending in a full stop (ffmpeg's messages have none).
    private static func sentence(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.last.map { ".!?".contains($0) } == true ? t : t + "."
    }

    /// Encoder options without the ones the filter graph decides (`-af` can't be used with `-filter_complex`; the
    /// graph sets the rate and channels).
    private static func codecArgs(_ args: [String]) -> [String] {
        var out: [String] = []
        var i = 0
        while i < args.count {
            if ["-af", "-ac", "-ar"].contains(args[i]), i + 1 < args.count { i += 2; continue }
            out.append(args[i]); i += 1
        }
        return out
    }

    /// Splits "h264 (High) (avc1 / 0x31637661), yuv420p(tv, bt709), 1280x720 [SAR 1:1 DAR 16:9]" at the commas
    /// outside brackets.
    static func splitFields(_ s: String) -> [String] {
        var parts: [String] = [], current = "", depth = 0
        for ch in s {
            if ch == "(" || ch == "[" { depth += 1 } else if ch == ")" || ch == "]" { depth = max(0, depth - 1) }
            if ch == ",", depth == 0 {
                parts.append(current.trimmingCharacters(in: .whitespaces)); current = ""
            } else { current.append(ch) }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(current.trimmingCharacters(in: .whitespaces)) }
        return parts
    }
}
