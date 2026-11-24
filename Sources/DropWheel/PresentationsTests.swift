#if DEBUG
// Self-tests: built into debug builds only (./test.sh); the shipped app leaves them out.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Headless checks for the PowerPoint code (`--selftest presentations`).
enum PresentationsTests {
    static func run() -> String {
        var failures: [String] = []
        var passed = 0
        func check(_ ok: Bool, _ what: String) { if ok { passed += 1 } else { failures.append(what) } }
        func close(_ a: Double, _ b: Double, _ tol: Double = 1e-6) -> Bool { abs(a - b) <= tol }

        // Guide formulas.
        let g = PPTXGuides(w: 200, h: 100)
        check(close(g.evaluate("*/ w 1 4"), 50), "*/ with a built-in")
        check(close(g.evaluate("+- 10 5 3"), 12), "+-")
        check(close(g.evaluate("pin 0 120000 100000"), 100000), "pin upper bound")
        check(close(g.evaluate("?: -1 3 4"), 4), "?: false branch")
        check(close(g.evaluate("at2 1 1"), 2_700_000), "at2 is 45° in 60000ths")
        check(close(g.evaluate("sat2 10 1 1"), 10 * sin(.pi / 4), 1e-9), "sat2")
        check(close(g.evaluate("mod 3 4 0"), 5), "mod")
        check(close(g.evaluate("sqrt 16"), 4), "sqrt")
        check(close(g.evaluate("val ssd2"), 50), "ssd2")

        // Colours.
        var c = PPTXColor.white; c.apply("lumMod", 0.75)
        check(c.hex == "BFBFBF", "lumMod 75% of white is BFBFBF (got \(c.hex))")
        c = PPTXColor(hex: "4472C4")!; c.apply("lumMod", 0.2); c.apply("lumOff", 0.8)
        check(c.hex == "DAE3F3", "accent1 20/80 is DAE3F3 (got \(c.hex))")
        c = .black; c.apply("tint", 0.5)
        check(c.hex == "BCBCBC", "tint 50% of black in linear light (got \(c.hex))")
        c = .white; c.apply("shade", 0.5)
        check(c.hex == "BCBCBC", "shade 50% of white (got \(c.hex))")
        let colors = PPTXColors(theme: PPTXTheme(), map: ["tx1": "dk1", "bg1": "lt1"])
        let scheme = PPTXXMLParser.parse(#"<a:schemeClr xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" val="bg1"><a:alpha val="50000"/></a:schemeClr>"#)!
        check(colors.color(scheme).map { $0.hex == "FFFFFF" && close($0.a, 0.5) } ?? false, "schemeClr through the colour map with alpha")

        // XML: custom prefixes, AlternateContent, entities.
        let xml = PPTXXMLParser.parse("""
        <x:sld xmlns:x="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:d="http://schemas.openxmlformats.org/drawingml/2006/main"
         xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" xmlns:rr="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <mc:AlternateContent><mc:Choice Requires="a14"><x:sp name="choice"/></mc:Choice><mc:Fallback><x:sp name="fallback"/></mc:Fallback></mc:AlternateContent>
        <d:t>A &amp; B &#8226;</d:t><d:blip rr:embed="rId9"/></x:sld>
        """)
        check(xml?.name == "p:sld", "custom prefix normalised to p:")
        check(xml?.child("p:sp")?["name"] == "fallback", "AlternateContent picks the fallback")
        check(xml?.child("a:t")?.text == "A & B •", "entities decoded")
        check(xml?.child("a:blip")?["r:embed"] == "rId9", "prefixed attribute normalised to r:")
        let truncated = PPTXXMLParser.parse("<p:sld xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\"><p:cSld><p:spTree><p:sp/>")
        check(truncated?.at("p:cSld", "p:spTree")?.child("p:sp") != nil, "truncated XML keeps what was read")
        check(PPTXPackage.resolve("../media/image1.png", from: "ppt/slides/slide1.xml") == "ppt/media/image1.png", "relative targets")
        check(PPTXPackage.resolve("/ppt/media/a%20b.png", from: "ppt/slides/slide1.xml") == "ppt/media/a b.png", "absolute, escaped targets")

        // Numbering.
        check(PPTXTextLayout.autoNumberLabel("romanUcPeriod", 4) == "IV.", "roman numerals")
        check(PPTXTextLayout.autoNumberLabel("alphaLcParenR", 28) == "bb)", "letters past z")
        check(PPTXTextLayout.autoNumberLabel("arabicParenBoth", 3) == "(3)", "(3)")

        // Every preset gives a non-empty outline that stays near its box.
        var badPresets: [String] = []
        for name in PPTXShapes.known {
            let geo = PPTXShapes.preset(name, w: 200, h: 100, adj: [:])
            let box = geo.paths.reduce(CGRect.null) { $0.union($1.path.boundingBoxOfPath) }
            // Callout leader lines reach outside the box by design.
            let slack: CGFloat = name.contains("allout") ? 200 : 60
            let ok = !geo.paths.isEmpty && !box.isNull && box.width.isFinite && box.height.isFinite
                && box.minX > -slack && box.minY > -slack && box.maxX < 200 + slack && box.maxY < 100 + slack
                && (box.width > 1 || box.height > 1)
            if !ok { badPresets.append(name) }
        }
        check(badPresets.isEmpty, "presets out of bounds: \(badPresets.joined(separator: ", "))")
        check(PPTXShapes.known.count >= 150, "at least 150 presets (\(PPTXShapes.known.count))")
        let arc = PPTXShapes.preset("ellipse", w: 100, h: 50, adj: [:]).paths[0].path.boundingBoxOfPath
        check(abs(arc.width - 100) < 0.5 && abs(arc.height - 50) < 0.5, "ellipse arcs fill the box")

        // Writer → reader → renderer round trip.
        do {
            let writer = PPTXWriter(width: 9_144_000, height: 6_858_000)
            writer.title = "Self test"
            let red = try solidPNG(red: 255, green: 0, blue: 0)
            let s1 = writer.addSlide(background: "0000FF")
            writer.addPicture(s1, data: red, ext: "png", frame: CGRect(x: 0, y: 0, width: 4_572_000, height: 6_858_000), name: "Red")
            writer.addSlide()
            writer.setHidden(1, true)
            let deck = try PPTXDeck(parts: PPTXMemoryParts(files: writer.parts()))
            check(deck.slides.count == 2, "round trip keeps 2 slides")
            check(abs(deck.size.width - 720) < 0.01 && abs(deck.size.height - 540) < 0.01, "slide size 720 × 540 pt")
            check(deck.slides[1].hidden, "hidden flag survives")
            check(deck.title == "Self test", "core title")
            let image = try Presentations.renderImage(PPTXRenderer(deck), deck.slides[0], scale: 0.5)
            let left = pixel(image, x: 90, y: 135), right = pixel(image, x: 270, y: 135)
            check(left.0 > 200 && left.1 < 40 && left.2 < 40, "picture drawn on the left half (got \(left))")
            check(right.2 > 200 && right.0 < 40, "background on the right half (got \(right))")
            for (name, data) in writer.parts() where name.hasSuffix(".xml") || name.hasSuffix(".rels") {
                if PPTXXMLParser.parse(data) == nil { failures.append("written part \(name) isn’t well-formed") }
            }
            check(PPTXWriter.clampedSize(100 * 914_400, 80 * 914_400).0 == PPTXWriter.maxSide, "oversized slides are scaled into PowerPoint's limits")
            check(PPTXWriter.clampedSize(36 * 12700, 72 * 12700).0 == PPTXWriter.minSide, "tiny slides are scaled up to PowerPoint's minimum")
        } catch {
            failures.append("round trip threw: \(error.localizedDescription)")
        }

        // Damaged numbers read as missing instead of trapping (NaN, infinities, beyond Int).
        let odd = PPTXNode("a:x", ["big": "1e20", "nan": "nan", "inf": "-inf", "max": "9223372036854775807",
                                   "min": "-9223372036854775808", "tiny": "-1e300", "int": "12", "dec": "12.0", "sp": " 7 "])
        check(["big", "nan", "inf", "max", "min", "tiny"].allSatisfy { odd.int($0) == nil }, "out-of-range int attributes read as nil")
        check(["big", "nan", "inf", "tiny"].allSatisfy { odd.double($0) == nil }, "non-finite or huge double attributes read as nil")
        check(odd.int("int") == 12 && odd.int("dec") == 12 && odd.int("sp") == 7 && odd.double("dec") == 12, "ordinary numbers still read")
        do {
            let writer = PPTXWriter(width: 9_144_000, height: 6_858_000)
            writer.addSlide()
            var parts = writer.parts()
            for (name, data) in parts where name.hasSuffix(".xml") {
                var text = String(decoding: data, as: UTF8.self)
                text = text.replacingOccurrences(of: "cx=\"9144000\"", with: "cx=\"1e20\"")
                    .replacingOccurrences(of: "lvl=\"0\"", with: "lvl=\"9.3e18\"")
                    .replacingOccurrences(of: "rIns=\"91440\"", with: "rIns=\"nan\"")
                parts[name] = Data(text.utf8)
            }
            let deck = try PPTXDeck(parts: PPTXMemoryParts(files: parts))
            check(abs(deck.size.width - 720) < 0.01, "a slide size of 1e20 falls back to the default (\(deck.size.width) pt)")
            _ = try Presentations.renderImage(PPTXRenderer(deck), deck.slides[0], scale: 0.25)
            _ = deck.text(of: deck.slides[0])
            check(true, "a deck with lvl=9.3e18 and rIns=nan renders and reads")
        } catch {
            failures.append("damaged-number deck threw: \(error.localizedDescription)")
        }

        // Compound-file reader rejects junk without crashing.
        check((try? PPTCompoundFile(Data(repeating: 0, count: 1024))) == nil, "non-compound data is rejected")

        let summary = "\(passed) checks passed"
        return failures.isEmpty ? "OK: \(summary)" : "FAIL: \(failures.count) failed (\(summary))\n- " + failures.joined(separator: "\n- ")
    }

    private static func solidPNG(red: UInt8, green: UInt8, blue: UInt8) throws -> Data {
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        guard CGImageDestinationFinalize(dest) else { throw ConversionError.toolFailed("PNG encode failed") }
        return out as Data
    }

    /// RGB of a pixel, with y measured from the top.
    private static func pixel(_ image: CGImage, x: Int, y: Int) -> (Int, Int, Int) {
        var buf = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &buf, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(buf[0]), Int(buf[1]), Int(buf[2]))
    }
}
#endif
