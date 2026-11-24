import AppKit

// Command-line mode, for testing without the drag gesture:
//   DropWheel --targets <file>...                    what each wheel would offer
//   DropWheel --list                                  every command feature modules add
//   DropWheel --convert <format> [--opt k=v]... <file>...
//   DropWheel --tool "<Tool Name or id>" [--opt k=v]... <file>...   (combining tools run once on all files)
//   DropWheel --protect|--unlock <password> <file>...
//   DropWheel --snapshot <id> <out.png> [--opt k=v]... [<file>...]   render a module's window offscreen
//   DropWheel --selftest <name>                       a module's headless checks
let args = Array(CommandLine.arguments.dropFirst())
if let flag = args.first, flag.hasPrefix("--") {
    func fail(_ message: String) -> Never {
        FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
        exit(2)
    }
    func warn(_ message: String) { FileHandle.standardError.write((message + "\n").data(using: .utf8)!) }

    // AppKit, WebKit and printing need an NSApplication even without a run loop. No Dock icon.
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)

    // Positional values after the flag, then files; `--opt key=value` may appear anywhere after the flag.
    let valueCount: Int
    switch flag {
    case "--convert", "--tool", "--protect", "--unlock", "--selftest", "--petal-sounds": valueCount = 1
    case "--snapshot", "--render-sound": valueCount = 2
    default: valueCount = 0
    }
    var values: [String] = []
    var files: [URL] = []
    var options: ToolOptions = [:]
    var rest = args.dropFirst()[...]
    while let a = rest.first {
        rest = rest.dropFirst()
        if a == "--opt" {
            guard let pair = rest.first, let eq = pair.firstIndex(of: "=") else { fail("--opt needs key=value") }
            options[String(pair[..<eq])] = String(pair[pair.index(after: eq)...])
            rest = rest.dropFirst()
        } else if values.count < valueCount {
            values.append(a)
        } else {
            files.append(URL(fileURLWithPath: a))
        }
    }
    guard values.count == valueCount else { fail("\(flag) needs \(valueCount) value(s) before the files") }

    var status: Int32 = 0
    func report(_ outs: [URL]) { outs.forEach { print($0.path) } }
    func runAll(_ op: Operation, on targets: [URL]) {
        if op.combinesInputs {
            do { report(try Converter.performCombined(op, on: targets) { _ in }) }
            catch { warn(error.localizedDescription); status = 1 }
            return
        }
        for file in targets {
            do { report(try Converter.perform(op, on: file) { _ in }) }
            catch { warn("\(file.lastPathComponent): \(error.localizedDescription)"); status = 1 }
        }
    }

    switch flag {
    case "--targets":
        guard let first = files.first else { fail("usage: --targets <file>...") }
        let kind = FileKind.of(first)
        let formats = OutputFormat.targets(forAll: files)
        print("kind: \(kind.rawValue)")
        // The petals the app's Convert wheel shows, in its order (module petals with a repeated title appear once there).
        print("convert: " + (formats.map(\.rawValue)
                             + Registry.convertCommands(for: files, besides: formats).map(\.id)).joined(separator: " "))
        print("tools: " + (FileTool.tools(for: files).map(\.rawValue)
                           + Registry.commands(for: .tools, files: files).map(\.title)).joined(separator: ", "))
        print("actions: " + (FileAction.allCases.map(\.rawValue)
                             + Registry.commands(for: .actions, files: files).map(\.title)).joined(separator: ", "))
    case "--list":
        for m in Registry.modules {
            for c in m.commands {
                print("\(m)\t\(c.wheel.rawValue)\t\(c.id)\t\(c.title)\(c.combinesInputs ? "\t(combines)" : "")\(c.present != nil ? "\t(window)" : "")")
            }
        }
    case "--convert":
        guard !files.isEmpty else { fail("usage: --convert <format> [--opt k=v]... <file>...") }
        let id = values[0].lowercased()
        // Built-in formats first, when they apply to the file; otherwise a module's conversion.
        let builtIn: (URL) -> OutputFormat? = { file in
            guard let f = OutputFormat(rawValue: id) else { return nil }
            return OutputFormat.targets(for: FileKind.of(file), source: file.pathExtension).contains(f) ? f : nil
        }
        if let command = Registry.command(.convert, named: id, files: files), command.combinesInputs,
           files.allSatisfy({ builtIn($0) == nil }) {
            runAll(.command(command, options), on: files)
        } else if let mixed = Registry.mixedConvertCommands(for: files, besides: OutputFormat.targets(forAll: files))
                    .first(where: { $0.id == id }) {
            // Files that different modules convert: the petal the app shows for them, which runs each file
            // through the command that converts it.
            runAll(.command(mixed, options), on: files)
        } else {
            // A module command that applies to the whole selection runs per file, as a drop in the app would.
            let shared = Registry.command(.convert, named: id, files: files).flatMap { $0.applies(files) ? $0 : nil }
            for file in files {
                if let f = builtIn(file) { runAll(.convert(f), on: [file]) }
                else if let c = shared ?? Registry.command(.convert, named: id, files: [file]).flatMap({ $0.applies([file]) ? $0 : nil }) {
                    runAll(.command(c, options), on: [file])
                } else { warn("\(file.lastPathComponent): no \(id) conversion for this file"); status = 1 }
            }
        }
    case "--tool":
        guard !files.isEmpty else { fail("usage: --tool <name> [--opt k=v]... <file>...") }
        if let tool = FileTool(rawValue: values[0]) {
            runAll(.tool(tool), on: files)
        } else if let c = Registry.command(.tools, named: values[0], files: files)
                    ?? Registry.command(.actions, named: values[0], files: files)
                    // A tool these files wouldn't get as a whole still runs (after the note below) when it runs as it
                    // would here: one that combines the files, so its own check can say why (Merge with a video and a
                    // sound, or one file), or one that runs per file and takes each file alone (Channels on several).
                    // Others stay unknown for these files, as before (Visualize isn't run on a video).
                    ?? Registry.commands.first(where: { c in
                        c.wheel != .convert && (c.id == values[0] || c.title == values[0] || c.plainTitle == values[0])
                            && (c.combinesInputs || files.allSatisfy { c.applies([$0]) })
                    }) {
            if !c.applies(files) { warn("note: \(c.plainTitle) wouldn’t be offered for these files") }
            runAll(.command(c, options), on: files)
        } else {
            let names = FileTool.allCases.map(\.rawValue) + Registry.commands.filter { $0.wheel != .convert }.map(\.id)
            fail("unknown tool \(values[0]). Known: \(names.joined(separator: ", "))")
        }
    case "--protect", "--unlock":
        guard !files.isEmpty else { fail("usage: \(flag) <password> <file>...") }
        runAll(flag == "--protect" ? .protect(password: values[0]) : .unlock(password: values[0]), on: files)
    case "--snapshot":
        let out = URL(fileURLWithPath: values[1])
        // A plain loop: `lazy.compactMap(...).first` would run the matching module's closure twice.
        var found: NSView?
        for m in Registry.modules { if let v = m.snapshot(values[0], files: files, options: options) { found = v; break } }
        guard let view = found else {
            fail("no module renders snapshot \(values[0])")
        }
        if out.pathExtension.lowercased() == "mp4", let video = view as? SnapshotVideoRendering {
            do { try video.writeVideo(to: out); print(out.path) } catch { warn(error.localizedDescription); status = 1 }
        } else {
            do { try Snapshot.writePNG(view, to: out, dark: options.bool("dark", false)); print(out.path) }
            catch { warn(error.localizedDescription); status = 1 }
        }
    case "--petal-sounds":
        // Previews of every petal sound: one tick, and a sweep that starts slow, spins fast round an 8-petal
        // wheel (skipping a few petals at the fastest point) and slows down again.
        let dir = URL(fileURLWithPath: values[0], isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var moves: [(interval: Double, steps: Int)] = Array(repeating: (0.4, 1), count: 3)
        moves += [0.25, 0.18, 0.13, 0.1, 0.08, 0.065, 0.055].map { ($0, 1) }
        moves += Array(repeating: (0.045, 1), count: 14) + [(0.05, 2), (0.05, 3), (0.05, 2)]
        moves += [0.055, 0.07, 0.09, 0.12, 0.16, 0.22, 0.32, 0.45].map { ($0, 1) }
        for style in PetalSoundStyle.allCases {
            for (name, samples) in [(style.rawValue, PetalSound.samples(style)),
                                    ("\(style.rawValue)-sweep", PetalSound.sweep(style, moves: moves))] {
                let out = dir.appendingPathComponent(name + ".wav")
                do { try PetalSound.wav(samples).write(to: out); print(out.path) } catch { warn(error.localizedDescription); status = 1 }
            }
        }
    case "--render-sound":
        // A design-kit recipe (JSON) rendered by the app's own synthesis, to check a port sample for sample.
        guard let data = FileManager.default.contents(atPath: values[0]), let recipe = PetalSound.Recipe(json: data) else {
            fail("can’t read recipe \(values[0])")
        }
        do {
            try PetalSound.wav(PetalSound.render(recipe)).write(to: URL(fileURLWithPath: values[1]))
            print(values[1])
        } catch { warn(error.localizedDescription); status = 1 }
    case "--selftest":
        var found: String?
        for m in Registry.modules { if let r = m.selfTest(values[0]) { found = r; break } }
        guard let result = found else {
            fail("no module has self-test \(values[0])")
        }
        print(result)
        if result.hasPrefix("FAIL") { status = 1 }
    default:
        fail("unknown option \(flag)")
    }
    exit(status)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
app.run()
