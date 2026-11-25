#if DEBUG
// Self-tests: built into debug builds only (./test.sh); the shipped app leaves them out.
import AppKit
import ImageIO
import SwiftUI

/// Headless checks for `--selftest welcome`.
enum WelcomeTests {
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

    static func run() -> String {
        let c = Checker()
        let saved = Settings.defaults
        Settings.defaults = SettingsMemoryStore()
        defer { Settings.defaults = saved }
        pages(c)
        copy(c)
        keys(c)
        demo(c)
        transitions(c)
        navigation(c)
        chrome(c)
        palette(c)
        sample(c)
        window(c)
        renders(c)
        return c.report
    }

    // MARK: Pages and copy

    private static func pages(_ c: Checker) {
        let all = WelcomePage.allCases
        c.check(all == [.welcome, .demo, .convert, .tools, .actions, .saved, .setup], "7 pages: welcome, demo, 3 wheels, saved, setup")
        c.check(all.filter(\.isWheelPage) == [.convert, .tools, .actions] && WelcomePage.tools.wheel == .tools, "wheel pages")
        c.check(WelcomePage.parse("3") == .convert && WelcomePage.parse("setup") == .setup && WelcomePage.parse("99") == .setup
                && WelcomePage.parse("0") == .welcome && WelcomePage.parse("nope") == nil, "pages by number or name")
    }

    private static func copy(_ c: Checker) {
        var strings = [WelcomeCopy.windowTitle, WelcomeCopy.helloLead, WelcomeCopy.appName, WelcomeCopy.start, WelcomeCopy.demoTitle,
                       WelcomeCopy.dragNote, WelcomeCopy.tapLead, WelcomeCopy.savedNote, WelcomeCopy.anywhere, WelcomeCopy.noWheel,
                       WelcomeCopy.stepOne, WelcomeCopy.stepTwo, WelcomeCopy.keyOff, WelcomeCopy.savedTitle, WelcomeCopy.savedBody,
                       WelcomeCopy.revealTitle, WelcomeCopy.revealDetail, WelcomeCopy.savedCaption, WelcomeCopy.setupTitle,
                       WelcomeCopy.setupBody, WelcomeCopy.menuBarHint, WelcomeCopy.loginTitle, WelcomeCopy.loginDetail,
                       WelcomeCopy.loginApproval, WelcomeCopy.keysTitle]
        for w in WheelMode.allCases {
            strings += [WelcomeCopy.tapTrail(w), WelcomeCopy.dropNote(w), WelcomeCopy.wheelTitle(w)]
        }
        strings += FileAction.allCases.map { WelcomeCopy.actionNote($0.rawValue) } + [WelcomeCopy.actionNote("Float"), WelcomeCopy.actionNote("?")]
        c.check(strings.allSatisfy { !$0.lowercased().contains("tangerine") }, "no other product's name in the copy")
        c.check(strings.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty }, "every string has text")
        c.check(WelcomeCopy.savedBody.contains(WelcomeSample.fileName) && WelcomeCopy.savedBody.contains("overwritten"),
                "the saved page says results sit next to the original and never overwrite")
        c.check(Set(FileAction.allCases.map { WelcomeCopy.actionNote($0.rawValue) }).count == FileAction.allCases.count,
                "each file action has its own done note")
    }

    // MARK: Keys

    private static func keys(_ c: Checker) {
        let maps: [(String, WheelKeyMap)] = [
            ("defaults", .defaults),
            ("swapped", WheelKeyMap(convert: .option, tools: .shift, actions: .command)),
            ("Convert off", WheelKeyMap(convert: .off, tools: .command, actions: .control)),
            ("all off", WheelKeyMap(convert: .off, tools: .off, actions: .off)),
        ]
        for (label, map) in maps {
            Settings.wheelKeys = map
            let follows = WheelMode.allCases.allSatisfy { mode in
                let k = map.key(for: mode)
                return WelcomeKeys.capKey(mode) == (k == .off ? nil : k) && WelcomeKeys.symbol(mode) == AppShell.keySymbol(for: mode)
            }
            c.check(follows, "[\(label)] key caps follow Settings.wheelKeys through AppShell.keySymbol")
            let expected = [WheelMode.convert, .tools, .actions].first { map.key(for: $0) != .off }
            let demo = WelcomeDemoModel(live: false)
            c.check(WelcomeKeys.practiceWheel == expected && demo.practiceWheel == expected, "[\(label)] the demo asks for \(expected?.rawValue ?? "no wheel")")
            let hint = WelcomeCopy.hint(.shortcut, wheel: expected)
            if let expected, let key = WelcomeKeys.capKey(expected) {
                c.check(hint.contains(key.name) && hint.contains(expected.rawValue), "[\(label)] the spoken hint names \(key.name)", hint)
            } else {
                c.check(hint == WelcomeCopy.noWheel, "[\(label)] with every wheel off the demo says to pick a key", hint)
            }
        }
        Settings.wheelKeys = .defaults
        c.check(WelcomeKeys.cap(.shift) == (nil, "shift", 108) && WelcomeKeys.cap(.command) == ("⌘", "command", 70)
                && WelcomeKeys.cap(.option).width == 56 && WelcomeKeys.cap(.control).symbol == "⌃", "key cap glyphs and widths")
        c.check(WelcomeKeys.name("⇧") == "shift" && WelcomeKeys.name("⌘") == "command" && WelcomeKeys.name("") == "off",
                "key names")
        c.check(WelcomeKeys.flags("⌥⇧") == [.option, .shift] && WelcomeKeys.flags("").isEmpty, "key symbols map to modifier flags")
    }

    // MARK: Demo

    private static func demo(_ c: Checker) {
        Settings.wheelKeys = .defaults
        let m = WelcomeDemoModel(live: false)
        let center = WelcomeDemoModel.center
        let r = WelcomeDemoModel.wheelSize * 0.36
        let overPetal = CGPoint(x: center.x + r * sin(.pi / 4), y: center.y - r * cos(.pi / 4))
        let aside = CGPoint(x: center.x + 200, y: center.y + 120)

        c.check(m.step == .drag, "the demo starts by asking for a drag")
        m.dragChanged(to: aside, flags: [])
        c.check(m.step == .shortcut && m.wheel == nil, "dragging asks for the key")
        m.modifiersChanged([.shift])
        c.check(m.step == .drop && m.wheel == .convert, "tapping ⇧ opens the Convert wheel")
        m.modifiersChanged([])
        c.check(m.wheel == .convert, "it stays open when the key is let go")
        m.dragChanged(to: overPetal, flags: [])
        c.check(m.highlighted != nil, "the petal under the pointer lights up", "\(String(describing: m.highlighted))")
        m.modifiersChanged([.command])
        c.check(m.wheel == .tools, "tapping ⌘ switches to Tools")
        m.cancelWheel()
        c.check(m.step == .shortcut && m.highlighted == nil, "Esc closes the wheel and the drag goes on")
        m.modifiersChanged([.command, .option])
        c.check(m.wheel == .actions, "tapping ⌥ opens Actions")
        m.modifiersChanged([.command])
        m.modifiersChanged([.command, .shift])
        m.modifiersChanged([.command])
        c.check(m.wheel == .convert, "tapping ⇧ switches back to Convert")
        m.modifiersChanged([.command, .control])
        c.check(m.wheel == .actions, "tapping ⌃ still opens Actions (no wheel uses ⌃)")
        m.dragChanged(to: overPetal, flags: [.command, .control])
        let petal = m.highlighted
        m.dragEnded()
        c.check(m.step == .done && m.result?.wheel == .actions && m.result?.fileName == nil && petal != nil,
                "dropping on an Actions petal finishes without a new file", "\(String(describing: m.result))")
        m.retry()
        c.check(m.step == .drag && m.result == nil, "Try again starts over")

        m.dragChanged(to: aside, flags: [])
        m.modifiersChanged([.shift])
        m.dragChanged(to: center, flags: [.shift])
        c.check(m.highlighted == nil, "the centre of the wheel is no petal")
        m.dragEnded()
        c.check(m.step == .drag && m.result == nil, "letting go off the petals puts the photo back")

        let held = WelcomeDemoModel(live: false)
        held.dragChanged(to: aside, flags: [.option])
        c.check(held.wheel == .actions, "⌥ held as the drag starts opens Actions")
        held.dragEnded()
        held.dragChanged(to: aside, flags: [.control])
        c.check(held.wheel == nil, "⌃ held as the drag starts opens nothing (a ⌃-press is a right-click)")
        held.dragEnded()

        m.dragChanged(to: overPetal, flags: [.shift])
        c.check(m.wheel == .convert, "a key held as the drag starts opens its wheel")
        m.dragEnded()
        c.check(m.result?.fileName == "lake.\((m.result?.title ?? "").lowercased())" || m.result?.fileName?.hasPrefix("lake.") == true,
                "a conversion saves lake.<format> next to the sample", m.result?.fileName ?? "nil")

        Settings.wheelKeys = WheelKeyMap(convert: .option, tools: .off, actions: .shift)
        let custom = WelcomeDemoModel(live: false)
        custom.dragChanged(to: aside, flags: [])
        custom.modifiersChanged([.command])
        c.check(custom.wheel == nil, "[custom keys] ⌘ opens nothing when no wheel uses it")
        custom.modifiersChanged([.command, .option])
        c.check(custom.wheel == .convert, "[custom keys] ⌥ opens Convert")
        Settings.wheelKeys = .defaults

        let convert = WelcomeSample.items(for: .convert).map(\.title)
        c.check(convert.contains("JPG") && !convert.contains("PNG"), "the Convert wheel offers JPG and not PNG for lake.png",
                convert.joined(separator: ", "))
        c.check(!WelcomeSample.items(for: .tools).isEmpty && !WelcomeSample.items(for: .actions).isEmpty, "Tools and Actions have petals")
        c.check(WelcomeSample.outputName(for: "JPG", wheel: .convert) == "lake.jpg"
                && WelcomeSample.outputName(for: FileTool.rotate.rawValue, wheel: .tools) == "lake rotated.png"
                && WelcomeSample.outputName(for: FileTool.compress.rawValue, wheel: .tools) == "lake compressed.jpg"
                && WelcomeSample.outputName(for: "Copy", wheel: .actions) == nil, "result names follow YummyOrange's naming")

        for (state, step) in [("drag", WelcomeDemoModel.Step.drag), ("shortcut", .shortcut), ("drop", .drop), ("done", .done),
                              ("drop-tools", .drop), ("done-actions", .done)] {
            let p = WelcomeDemoModel(live: false)
            p.apply(preview: state)
            c.check(p.step == step, "preview \(state) shows the \(step) step")
        }
        let tools = WelcomeDemoModel(live: false)
        tools.apply(preview: "drop-tools")
        c.check(tools.wheel == .tools && tools.highlighted != nil, "preview drop-tools highlights a Tools petal")
    }

    // MARK: Motion

    private static func transitions(_ c: Checker) {
        let f = WelcomeTransition.between(.convert, .tools, reduceMotion: false)
        c.check(f.out == .init(duration: 0.22, veil: 1, offset: -6, rotation: 6, rotationDuration: 0.22)
                && f.swap.offset == 12 && f.swap.rotation == -10 && f.pause == 0.034
                && f.into == .init(duration: 0.32, veil: 0, offset: 0, rotation: 0, rotationDuration: 0.32),
                "forward between wheels: out 0.22 s, −6 pt / +6°, swap +12 pt / −10°, 34 ms, in 0.32 s")
        let b = WelcomeTransition.between(.tools, .convert, reduceMotion: false)
        c.check(b.out.offset == 6 && b.out.rotation == -6 && b.swap.offset == -12 && b.swap.rotation == 10, "backward mirrors it")
        let toWheel = WelcomeTransition.between(.demo, .convert, reduceMotion: false)
        let fromWheel = WelcomeTransition.between(.actions, .saved, reduceMotion: false)
        c.check(toWheel.out.rotation == 0 && toWheel.swap.rotation == -10 && fromWheel.out.rotation == 6 && fromWheel.swap.rotation == 0,
                "only wheel pages turn")
        let rm = WelcomeTransition.between(.convert, .tools, reduceMotion: true)
        c.check(rm.out.duration == 0.14 && rm.into.duration == 0.18 && rm.out.offset == 0 && rm.swap.offset == 0
                && rm.out.rotation == 0 && rm.swap.rotation == 0 && rm.into.rotationDuration == 0,
                "Reduce Motion keeps only a quicker fade")
    }

    // MARK: Navigation

    private static func navigation(_ c: Checker) {
        let defaults = SelfTestDefaults.scratch()
        c.check(SelfTestDefaults.isScratch(defaults), "the tour's preferences stay in memory (no YummyOrange.selftest.<UUID>.plist)")

        let m = WelcomeModel(page: .welcome, live: false)
        m.defaults = defaults
        var finished = 0
        m.onFinish = { finished += 1 }
        m.back()
        c.check(m.page == .welcome, "Back on the first page stays there")
        var visited = [m.page]
        for _ in 0..<6 { m.next(); visited.append(m.page) }
        c.check(visited == WelcomePage.allCases, "Continue walks every page in order", visited.map(\.name).joined(separator: ","))
        m.next()
        c.check(finished == 1 && defaults.bool(forKey: WelcomeModel.completedKey), "Done on the last page finishes and records it")
        m.back()
        c.check(m.page == .saved, "Back goes back")
        m.go(to: .convert)
        c.check(m.page == .convert, "jumping to a page")

        let live = WelcomeModel(page: .demo, live: true)
        live.next()
        live.next()
        c.check(live.page == .convert && live.isChangingPage, "a second Continue during a transition is ignored")
        live.pageChangeFinished()
        live.next()
        c.check(live.page == .tools, "Continue works again once the transition ends")

        c.check(WelcomeTour.shouldShowOnLaunch(defaults), "first launch shows the tour")
        WelcomeTour.markShown(defaults)
        c.check(!WelcomeTour.shouldShowOnLaunch(defaults), "later launches don't")
    }

    // MARK: Chrome and palette

    private static func chrome(_ c: Checker) {
        let measured = [CGPoint(x: 161.5, y: 72.5), CGPoint(x: 192.0, y: 59.0), CGPoint(x: 224.4, y: 50.6)]
        let got = WelcomeChrome.dotCenters
        let close = zip(got, measured).allSatisfy { hypot($0.x - $1.x, $0.y - $1.y) < 1.5 }
        c.check(got.count == 3 && close, "window dots sit 40 pt inside the capsule's edge",
                got.map { String(format: "(%.1f, %.1f)", $0.x, $0.y) }.joined(separator: " "))
    }

    private static func palette(_ c: Checker) {
        c.check(DWPalette.hex(DWPalette.base) == "#E2669C" && DWPalette.hex(DWPalette.glow) == "#FFE1A1", "base and glow seeds (dahlia)")
        func near(_ a: NSColor, _ hex: String) -> Bool {
            guard let b = NSColor(hex: hex)?.usingColorSpace(.sRGB), let x = a.usingColorSpace(.sRGB) else { return false }
            return abs(x.redComponent - b.redComponent) < 3 / 255 && abs(x.greenComponent - b.greenComponent) < 3 / 255
                && abs(x.blueComponent - b.blueComponent) < 3 / 255
        }
        c.check(near(DWPalette.accent, "#E266BA") && near(DWPalette.button, "#E2668A") && near(DWPalette.folderTop, "#E29B8E"),
                "derived tones", [DWPalette.accent, DWPalette.button, DWPalette.folderTop].map(DWPalette.hex).joined(separator: " "))
        let deep = DWPalette.hsb(DWPalette.accentDeep), acc = DWPalette.hsb(DWPalette.accent)
        c.check(abs(deep.b - acc.b * 0.74) < 0.01 && abs(deep.s - min(acc.s * 1.12, 1)) < 0.01, "deep accent: saturation × 1.12, brightness × 0.74")
    }

    // MARK: Sample, window, renders

    private static func sample(_ c: Checker) {
        let fm = FileManager.default
        do {
            let url = try WelcomeSample.make()
            let src = CGImageSourceCreateWithURL(url as CFURL, nil)
            let props = src.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] } ?? [:]
            let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
            c.check(w == 600 && h == 600 && url.lastPathComponent == WelcomeSample.fileName, "the sample photo is a 600 × 600 PNG", "\(w)×\(h)")
            c.check(url.path.hasPrefix(fm.temporaryDirectory.path), "it lives in a temporary folder", url.path)
            let backup = url.path + ".selftest-backup"
            try? fm.removeItem(atPath: backup)
            try fm.copyItem(atPath: url.path, toPath: backup)
            defer { try? fm.removeItem(at: url); try? fm.moveItem(atPath: backup, toPath: url.path) }
            try Data("x".utf8).write(to: url)
            c.check((try? WelcomeSample.make()) != nil && CGImageSourceCreateWithURL(url as CFURL, nil).map { CGImageSourceGetCount($0) } == 1,
                    "a damaged sample is made again")
        } catch { c.check(false, "sample photo", error.localizedDescription) }
    }

    private static func window(_ c: Checker) {
        let panel = WelcomeTour.makePanel(model: WelcomeModel(page: .welcome, live: false))
        c.check(!panel.styleMask.contains(.titled) && panel.styleMask.contains(.closable) && panel.styleMask.contains(.miniaturizable),
                "borderless, closable and miniaturizable")
        c.check(!panel.isOpaque && panel.hasShadow && panel.backgroundColor == .clear && !panel.hidesOnDeactivate
                && panel.canBecomeKey && panel.animationBehavior == .documentWindow, "clear, shadowed, can become key")
        c.check(panel.contentRect(forFrameRect: panel.frame).size == WelcomeTour.size, "700 × 452 points")
        let clip = panel.contentViewController?.view.subviews.first
        c.check(clip?.layer?.cornerRadius == 226 && clip?.layer?.masksToBounds == true, "clipped to a stadium of radius 226")
    }

    /// Each page renders offscreen: drawn inside the capsule, clear outside it.
    private static func renders(_ c: Checker) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("YummyOrange welcome selftest \(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for page in WelcomePage.allCases {
            let out = dir.appendingPathComponent("\(page.name).png")
            let view = WelcomeTour.snapshotView(page: page, demoState: page == .demo ? "drop" : nil)
            do {
                try Snapshot.writePNG(view, to: out)
                guard let src = CGImageSourceCreateWithURL(out as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
                      let rep = Optional(NSBitmapImageRep(cgImage: image)) else { c.check(false, "\(page.name) renders"); continue }
                let sx = CGFloat(rep.pixelsWide) / WelcomeTour.size.width
                func alpha(_ x: CGFloat, _ y: CGFloat) -> CGFloat { rep.colorAt(x: Int(x * sx), y: Int(y * sx))?.alphaComponent ?? -1 }
                let inside = alpha(350, 226), corner = alpha(3, 3)
                c.check(inside > 0.99 && corner < 0.01, "\(page.name) renders inside the capsule only", "inside \(inside) corner \(corner)")
                if page == .welcome, let mid = rep.colorAt(x: Int(350 * sx), y: Int(120 * sx))?.usingColorSpace(.sRGB) {
                    c.check(mid.redComponent > 0.75 && mid.greenComponent < mid.redComponent && mid.blueComponent > 0.45,
                            "the welcome page is dahlia pink", DWPalette.hex(mid))
                }
            } catch { c.check(false, "\(page.name) renders", error.localizedDescription) }
        }
    }
}
#endif
