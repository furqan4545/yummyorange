import AppKit

/// Channels… : changes the sound's channels, in the file's own format; a video's picture is copied untouched (as
/// Bleep copies it, `MediaBleep.copyVideoArgs`).
/// - Mono: both channels mixed at half level each (−6 dB, so nothing clips); surround is downmixed.
/// - Stereo: a mono file in both ears (surround: a stereo downmix).
/// - Swap Left and Right.
/// - Left Only / Right Only: that channel alone, as a mono file.
///
/// The form only offers what makes sense for the file: a mono file only Stereo; a stereo file everything but Stereo.
enum MediaChannels {
    enum Layout: String, CaseIterable {
        case mono, stereo, swap, left, right

        var title: String {
            switch self {
            case .mono: return "Mono"
            case .stereo: return "Stereo"
            case .swap: return "Swap Left and Right"
            case .left: return "Left Only"
            case .right: return "Right Only"
            }
        }

        var suffix: String {
            switch self {
            case .mono: return " mono"
            case .stereo: return " stereo"
            case .swap: return " swapped"
            case .left: return " left"
            case .right: return " right"
            }
        }
    }

    /// What makes sense for a sound with `channels` channels.
    static func layouts(forChannels channels: Int) -> [Layout] {
        switch channels {
        case ...1: return [.stereo]
        case 2: return [.mono, .swap, .left, .right]
        default: return [.mono, .stereo, .left, .right]
        }
    }

    /// Mono files become stereo, everything else mono.
    static func defaultLayout(forChannels channels: Int) -> Layout { channels <= 1 ? .stereo : .mono }

    static func ask(_ files: [URL]) -> ToolOptions? {
        guard let sources = MediaTools.probeForForm(files, tool: "change the channels of") else { return nil }
        let withSound = sources.filter(\.hasAudio)
        guard !withSound.isEmpty else {
            HUD.shared.flash(files.count == 1 ? "\(files[0].lastPathComponent) has no sound." : "None of these files has sound.", isError: true)
            return nil
        }
        // Offer what makes sense for at least one file (files it doesn't fit say so in the HUD).
        let counts = withSound.map { $0.channels ?? 2 }
        let offered = Layout.allCases.filter { layout in counts.contains { layouts(forChannels: $0).contains(layout) } }
        let last = Layout(rawValue: ImageExtras.remembered("channels").string("layout", "")) ?? .mono
        let selected = offered.contains(last) ? last : (offered.first ?? .mono)
        let describe = withSound.count == 1 ? channelDescription(withSound[0]) : ""
        guard let answer = Ask.form(title: "Change Channels", message: MediaTools.formMessage(files, describe),
                                    fields: [.choice(key: "layout", label: "Make:", options: offered.map(\.title), selected: selected.title)],
                                    button: "Change") else { return nil }
        let layout = offered.first { $0.title == answer["layout"] } ?? selected
        ImageExtras.remember(["layout": layout.rawValue], as: "channels")
        return ["layout": layout.rawValue]
    }

    /// "The sound is stereo." for the form.
    static func channelDescription(_ source: MediaSource) -> String {
        switch source.channels ?? 2 {
        case 1: return "The sound is mono."
        case 2: return "The sound is stereo."
        case let n: return "The sound has \(n) channels."
        }
    }

    /// Options: layout (mono | stereo | swap | left | right; default stereo for mono files, mono otherwise).
    /// Writes "<name> mono.<ext>", " stereo", " swapped", " left" or " right".
    static func channels(_ url: URL, options: ToolOptions, progress: @escaping (Double) -> Void) throws -> URL {
        let ff = try MediaKit.ffmpeg()
        let source = try MediaSource.load(url)
        guard source.hasAudio else { throw ConversionError.unsupported("The file has no sound, so it has no channels to change.") }
        let count = source.channels ?? 2
        let text = options.string("layout", defaultLayout(forChannels: count).rawValue).lowercased()
        guard let layout = Layout(rawValue: text) else {
            throw ConversionError.unsupported("Choose layout=mono, stereo, swap, left or right (not “\(text)”).")
        }
        guard layouts(forChannels: count).contains(layout) else {
            switch (count, layout) {
            case (...1, _):
                throw ConversionError.unsupported("The sound is mono, so it has no left and right to \(layout == .mono ? "mix" : layout == .swap ? "swap" : "pick"). Choose Stereo.")
            case (2, .stereo):
                throw ConversionError.unsupported("The sound is already stereo. Choose Mono, Swap Left and Right, Left Only or Right Only.")
            default:
                throw ConversionError.unsupported("The sound has \(count) channels; swapping works on stereo sound. Choose Mono, Stereo, Left Only or Right Only.")
            }
        }
        let filter = self.filter(layout, channels: count)
        let ext = MediaEncode.outputExtension(for: source)
        let out = outputURL(for: url, ext: ext, suffix: layout.suffix)
        // The filter sets the layout, so drop any channel count the codec rules add for the source (-ac 2 for 5.1).
        var audio = MediaEncode.audioCodecArgs(for: source, ext: ext, filters: [filter])
        while let i = audio.firstIndex(of: "-ac"), i + 1 < audio.count { audio.removeSubrange(i...(i + 1)) }
        let args: [String]
        if source.hasVideo {
            args = MediaBleep.copyVideoArgs(source, ext: ext) + audio + MediaEncode.containerArgs(ext)
        } else {
            args = ["-map", "0:a:0", "-vn"] + audio + MediaEncode.containerArgs(ext)
        }
        try ff.run(input: url, output: out, args: args, duration: source.duration, progress: progress)
        return out
    }

    /// The `pan` (or downmix) filter for `layout` on a sound with `channels` channels.
    static func filter(_ layout: Layout, channels: Int) -> String {
        switch layout {
        case .mono: return channels == 2 ? "pan=mono|c0=0.5*c0+0.5*c1" : "aformat=channel_layouts=mono"
        case .stereo: return channels <= 1 ? "pan=stereo|c0=c0|c1=c0" : "aformat=channel_layouts=stereo"
        case .swap: return "pan=stereo|c0=c1|c1=c0"
        case .left: return "pan=mono|c0=FL"
        case .right: return "pan=mono|c0=FR"
        }
    }
}
