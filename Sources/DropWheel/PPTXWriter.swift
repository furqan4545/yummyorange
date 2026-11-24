import Foundation
import CoreGraphics

/// Writes a complete, minimal PowerPoint package: content types, package and part relationships,
/// document properties, presentation, one master with a blank layout, a theme, and the slides with
/// their media. Shapes are given as `p:sp` / `p:pic` XML built with the helpers below.
final class PPTXWriter {
    /// Slide size in EMU (PowerPoint accepts 1 to 56 inches on each side).
    let width: Int
    let height: Int
    var title = ""

    private struct Slide {
        var shapes: [String] = []
        var rels: [(id: String, target: String, type: String)] = []
        var background: String?
        var hidden = false
        var nextShapeID = 2
    }

    private var slides: [Slide] = []
    private var media: [(name: String, data: Data)] = []

    static let minSide = 914_400, maxSide = 51_206_400

    /// Scales a size (in EMU) uniformly so both sides fit PowerPoint's limits.
    static func clampedSize(_ w: Double, _ h: Double) -> (Int, Int) {
        var w = max(1, w), h = max(1, h)
        let big = max(w, h) / Double(maxSide)
        if big > 1 { w /= big; h /= big }
        let small = Double(minSide) / min(w, h)
        if small > 1 { w = min(Double(maxSide), w * small); h = min(Double(maxSide), h * small) }
        return (Int(w.rounded()), Int(h.rounded()))
    }

    init(width: Int, height: Int) {
        let (w, h) = Self.clampedSize(Double(width), Double(height))
        self.width = w
        self.height = h
    }

    var slideCount: Int { slides.count }

    /// Adds an empty slide and returns its index. `background` is an "RRGGBB" fill.
    @discardableResult
    func addSlide(background: String? = nil) -> Int {
        slides.append(Slide(background: background))
        return slides.count - 1
    }

    /// Next free shape id on a slide (ids must be unique per slide).
    func nextID(_ slide: Int) -> Int {
        let id = slides[slide].nextShapeID
        slides[slide].nextShapeID += 1
        return id
    }

    /// Stores a media file and links it from the slide; returns the relationship id.
    func addMedia(_ slide: Int, data: Data, ext: String) -> String {
        let name = "image\(media.count + 1).\(ext.lowercased())"
        media.append((name, data))
        let rid = "rId\(slides[slide].rels.count + 2)"
        slides[slide].rels.append((rid, "../media/\(name)",
                                   "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"))
        return rid
    }

    func addShapeXML(_ slide: Int, _ xml: String) { slides[slide].shapes.append(xml) }

    func setHidden(_ slide: Int, _ hidden: Bool) { slides[slide].hidden = hidden }

    func setBackground(_ slide: Int, _ hex: String) { slides[slide].background = hex }

    /// The media linked from a slide, in relationship order (data and extension).
    func mediaOf(_ slide: Int) -> [(Data, String)] {
        slides[slide].rels.compactMap { rel in
            let name = (rel.target as NSString).lastPathComponent
            return media.first { $0.name == name }.map { ($0.data, ($0.name as NSString).pathExtension) }
        }
    }

    /// A picture shape. `crop` insets are fractions of the image (srcRect).
    func addPicture(_ slide: Int, data: Data, ext: String, frame: CGRect, name: String, description: String = "",
                    crop: (l: Double, t: Double, r: Double, b: Double)? = nil) {
        let rid = addMedia(slide, data: data, ext: ext)
        let id = nextID(slide)
        var src = ""
        if let c = crop, c.l != 0 || c.t != 0 || c.r != 0 || c.b != 0 {
            src = "<a:srcRect l=\"\(Int(c.l * 100000))\" t=\"\(Int(c.t * 100000))\" r=\"\(Int(c.r * 100000))\" b=\"\(Int(c.b * 100000))\"/>"
        }
        addShapeXML(slide, """
        <p:pic><p:nvPicPr><p:cNvPr id="\(id)" name="\(PPTXNode.escape(name))" descr="\(PPTXNode.escape(description))"/>\
        <p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>\
        <p:blipFill><a:blip r:embed="\(rid)"/>\(src)<a:stretch><a:fillRect/></a:stretch></p:blipFill>\
        <p:spPr>\(Self.xfrm(frame))<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic>
        """)
    }

    /// `a:xfrm` for a frame in EMU.
    static func xfrm(_ f: CGRect, rot: Double = 0, flipH: Bool = false, flipV: Bool = false) -> String {
        var attrs = ""
        if rot != 0 { attrs += " rot=\"\(Int((rot * 60000).rounded()))\"" }
        if flipH { attrs += " flipH=\"1\"" }
        if flipV { attrs += " flipV=\"1\"" }
        return "<a:xfrm\(attrs)><a:off x=\"\(Int(f.minX.rounded()))\" y=\"\(Int(f.minY.rounded()))\"/>"
            + "<a:ext cx=\"\(max(0, Int(f.width.rounded())))\" cy=\"\(max(0, Int(f.height.rounded())))\"/></a:xfrm>"
    }

    // MARK: Package

    private static let ns = "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" "
        + "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" "
        + "xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\""
    private static let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
    private static let relNS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    private static func rels(_ list: [(String, String, String)]) -> String {
        header + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + list.map { "<Relationship Id=\"\($0.0)\" Type=\"\($0.2)\" Target=\"\(PPTXNode.escape($0.1))\"/>" }.joined()
            + "</Relationships>"
    }

    private static let emptyTree = "<p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>"
        + "<p:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/><a:chOff x=\"0\" y=\"0\"/>"
        + "<a:chExt cx=\"0\" cy=\"0\"/></a:xfrm></p:grpSpPr>"

    private static func level(_ n: Int, size: Int, marL: Int = 0, indent: Int = 0, bullet: Bool = false, major: Bool = false) -> String {
        let bu = bullet ? "<a:buFont typeface=\"Arial\"/><a:buChar char=\"•\"/>" : "<a:buNone/>"
        let font = major ? "+mj-lt" : "+mn-lt"
        let color = major ? "tx1" : "tx1"
        return "<a:lvl\(n)pPr marL=\"\(marL)\" indent=\"\(indent)\" algn=\"l\" defTabSz=\"914400\" rtl=\"0\" eaLnBrk=\"1\" "
            + "latinLnBrk=\"0\" hangingPunct=\"1\"><a:lnSpc><a:spcPct val=\"\(major ? 90000 : 100000)\"/></a:lnSpc>"
            + "<a:spcBef><a:spcPts val=\"\(major || n == 1 && !bullet ? 0 : 500)\"/></a:spcBef>\(bu)"
            + "<a:defRPr sz=\"\(size)\" kern=\"1200\"><a:solidFill><a:schemeClr val=\"\(color)\"/></a:solidFill>"
            + "<a:latin typeface=\"\(font)\"/><a:ea typeface=\"+mn-ea\"/><a:cs typeface=\"+mn-cs\"/></a:defRPr></a:lvl\(n)pPr>"
    }

    private var defaultTextStyle: String {
        (1...9).map { Self.level($0, size: 1800, marL: ($0 - 1) * 457200) }.joined()
    }

    /// Text sizes scaled to the slide height (the defaults suit a 7.5-inch-tall slide).
    private func scaled(_ pts: Double) -> Int {
        let k = max(0.4, min(4, Double(height) / 6_858_000))
        return Int((pts * k).rounded()) * 100
    }

    private var masterXML: String {
        let w = width, h = height
        let mx = w / 20, my = h / 20
        let title = """
        <p:sp><p:nvSpPr><p:cNvPr id="2" name="Title Placeholder 1"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr>\
        <p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr><p:spPr>\(Self.xfrm(CGRect(x: mx, y: my, width: w - 2 * mx, height: h / 5)))\
        <a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr><p:txBody><a:bodyPr vert="horz" lIns="91440" tIns="45720" \
        rIns="91440" bIns="45720" rtlCol="0" anchor="ctr"><a:normAutofit/></a:bodyPr><a:lstStyle/><a:p><a:r><a:rPr lang="en-US"/>\
        <a:t>Title</a:t></a:r></a:p></p:txBody></p:sp>
        """
        let body = """
        <p:sp><p:nvSpPr><p:cNvPr id="3" name="Text Placeholder 2"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr>\
        <p:nvPr><p:ph type="body" idx="1"/></p:nvPr></p:nvSpPr><p:spPr>\
        \(Self.xfrm(CGRect(x: mx, y: my + h / 5 + my / 2, width: w - 2 * mx, height: h - 2 * my - h / 5 - my / 2)))\
        <a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr><p:txBody><a:bodyPr vert="horz" lIns="91440" tIns="45720" \
        rIns="91440" bIns="45720" rtlCol="0"><a:normAutofit/></a:bodyPr><a:lstStyle/><a:p><a:pPr lvl="0"/><a:r>\
        <a:rPr lang="en-US"/><a:t>Text</a:t></a:r></a:p></p:txBody></p:sp>
        """
        let titleStyle = "<a:lvl1pPr algn=\"l\" defTabSz=\"914400\" rtl=\"0\" eaLnBrk=\"1\" latinLnBrk=\"0\" hangingPunct=\"1\">"
            + "<a:lnSpc><a:spcPct val=\"90000\"/></a:lnSpc><a:spcBef><a:spcPct val=\"0\"/></a:spcBef><a:buNone/>"
            + "<a:defRPr sz=\"\(scaled(44))\" kern=\"1200\"><a:solidFill><a:schemeClr val=\"tx1\"/></a:solidFill>"
            + "<a:latin typeface=\"+mj-lt\"/><a:ea typeface=\"+mj-ea\"/><a:cs typeface=\"+mj-cs\"/></a:defRPr></a:lvl1pPr>"
        let bodyStyle = (1...9).map {
            Self.level($0, size: scaled([28, 24, 20, 18, 18, 18, 18, 18, 18][$0 - 1]) , marL: 228600 + ($0 - 1) * 457200,
                       indent: -228600, bullet: true)
        }.joined()
        return Self.header + """
        <p:sldMaster \(Self.ns)><p:cSld><p:bg><p:bgRef idx="1001"><a:schemeClr val="bg1"/></p:bgRef></p:bg><p:spTree>\
        \(Self.emptyTree)\(title)\(body)</p:spTree></p:cSld>\
        <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" \
        accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>\
        <p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst>\
        <p:txStyles><p:titleStyle>\(titleStyle)</p:titleStyle><p:bodyStyle>\(bodyStyle)</p:bodyStyle>\
        <p:otherStyle>\(defaultTextStyle)</p:otherStyle></p:txStyles></p:sldMaster>
        """
    }

    private static let layoutXML = header + """
    <p:sldLayout \(ns) type="blank" preserve="1"><p:cSld name="Blank"><p:spTree>\(emptyTree)</p:spTree></p:cSld>\
    <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>
    """

    static let themeXML = header + """
    <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Office Theme"><a:themeElements>\
    <a:clrScheme name="Office"><a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1>\
    <a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1><a:dk2><a:srgbClr val="44546A"/></a:dk2>\
    <a:lt2><a:srgbClr val="E7E6E6"/></a:lt2><a:accent1><a:srgbClr val="4472C4"/></a:accent1>\
    <a:accent2><a:srgbClr val="ED7D31"/></a:accent2><a:accent3><a:srgbClr val="A5A5A5"/></a:accent3>\
    <a:accent4><a:srgbClr val="FFC000"/></a:accent4><a:accent5><a:srgbClr val="5B9BD5"/></a:accent5>\
    <a:accent6><a:srgbClr val="70AD47"/></a:accent6><a:hlink><a:srgbClr val="0563C1"/></a:hlink>\
    <a:folHlink><a:srgbClr val="954F72"/></a:folHlink></a:clrScheme>\
    <a:fontScheme name="Office"><a:majorFont><a:latin typeface="Calibri Light"/><a:ea typeface=""/><a:cs typeface=""/>\
    </a:majorFont><a:minorFont><a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme>\
    <a:fmtScheme name="Office"><a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill>\
    <a:gradFill rotWithShape="1"><a:gsLst><a:gs pos="0"><a:schemeClr val="phClr"><a:lumMod val="110000"/>\
    <a:satMod val="105000"/><a:tint val="67000"/></a:schemeClr></a:gs><a:gs pos="50000"><a:schemeClr val="phClr">\
    <a:lumMod val="105000"/><a:satMod val="103000"/><a:tint val="73000"/></a:schemeClr></a:gs><a:gs pos="100000">\
    <a:schemeClr val="phClr"><a:lumMod val="105000"/><a:satMod val="109000"/><a:tint val="81000"/></a:schemeClr></a:gs>\
    </a:gsLst><a:lin ang="5400000" scaled="0"/></a:gradFill><a:gradFill rotWithShape="1"><a:gsLst><a:gs pos="0">\
    <a:schemeClr val="phClr"><a:satMod val="103000"/><a:lumMod val="102000"/><a:tint val="94000"/></a:schemeClr></a:gs>\
    <a:gs pos="50000"><a:schemeClr val="phClr"><a:satMod val="110000"/><a:lumMod val="100000"/><a:shade val="100000"/>\
    </a:schemeClr></a:gs><a:gs pos="100000"><a:schemeClr val="phClr"><a:lumMod val="99000"/><a:satMod val="120000"/>\
    <a:shade val="78000"/></a:schemeClr></a:gs></a:gsLst><a:lin ang="5400000" scaled="0"/></a:gradFill></a:fillStyleLst>\
    <a:lnStyleLst><a:ln w="6350" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill>\
    <a:prstDash val="solid"/><a:miter lim="800000"/></a:ln><a:ln w="12700" cap="flat" cmpd="sng" algn="ctr"><a:solidFill>\
    <a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/><a:miter lim="800000"/></a:ln><a:ln w="19050" \
    cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/>\
    <a:miter lim="800000"/></a:ln></a:lnStyleLst><a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle>\
    <a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst><a:outerShdw blurRad="57150" dist="19050" \
    dir="5400000" algn="ctr" rotWithShape="0"><a:srgbClr val="000000"><a:alpha val="63000"/></a:srgbClr></a:outerShdw>\
    </a:effectLst></a:effectStyle></a:effectStyleLst><a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill>\
    <a:solidFill><a:schemeClr val="phClr"><a:tint val="95000"/><a:satMod val="170000"/></a:schemeClr></a:solidFill>\
    <a:gradFill rotWithShape="1"><a:gsLst><a:gs pos="0"><a:schemeClr val="phClr"><a:tint val="93000"/><a:satMod val="150000"/>\
    <a:shade val="98000"/><a:lumMod val="102000"/></a:schemeClr></a:gs><a:gs pos="50000"><a:schemeClr val="phClr">\
    <a:tint val="98000"/><a:satMod val="130000"/><a:shade val="90000"/><a:lumMod val="103000"/></a:schemeClr></a:gs>\
    <a:gs pos="100000"><a:schemeClr val="phClr"><a:shade val="63000"/><a:satMod val="120000"/></a:schemeClr></a:gs></a:gsLst>\
    <a:lin ang="5400000" scaled="0"/></a:gradFill></a:bgFillStyleLst></a:fmtScheme></a:themeElements>\
    <a:objectDefaults/><a:extraClrSchemeLst/></a:theme>
    """

    private func slideXML(_ s: Slide) -> String {
        var bg = ""
        if let hex = s.background {
            bg = "<p:bg><p:bgPr><a:solidFill><a:srgbClr val=\"\(hex)\"/></a:solidFill><a:effectLst/></p:bgPr></p:bg>"
        }
        return Self.header + "<p:sld \(Self.ns)\(s.hidden ? " show=\"0\"" : "")><p:cSld>\(bg)<p:spTree>\(Self.emptyTree)\(s.shapes.joined())</p:spTree></p:cSld>"
            + "<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>"
    }

    /// Every part of the package, keyed by part name.
    func parts() -> [String: Data] {
        var out: [String: Data] = [:]
        func put(_ name: String, _ s: String) { out[name] = Data(s.utf8) }
        let pt = "application/vnd.openxmlformats-officedocument.presentationml"
        var overrides: [(String, String)] = [
            ("/ppt/presentation.xml", "\(pt).presentation.main+xml"),
            ("/ppt/slideMasters/slideMaster1.xml", "\(pt).slideMaster+xml"),
            ("/ppt/slideLayouts/slideLayout1.xml", "\(pt).slideLayout+xml"),
            ("/ppt/theme/theme1.xml", "application/vnd.openxmlformats-officedocument.theme+xml"),
            ("/ppt/presProps.xml", "\(pt).presProps+xml"),
            ("/ppt/viewProps.xml", "\(pt).viewProps+xml"),
            ("/ppt/tableStyles.xml", "\(pt).tableStyles+xml"),
            ("/docProps/core.xml", "application/vnd.openxmlformats-package.core-properties+xml"),
            ("/docProps/app.xml", "application/vnd.openxmlformats-officedocument.extended-properties+xml"),
        ]
        for i in slides.indices { overrides.append(("/ppt/slides/slide\(i + 1).xml", "\(pt).slide+xml")) }
        var defaults: [(String, String)] = [("rels", "application/vnd.openxmlformats-package.relationships+xml"),
                                            ("xml", "application/xml")]
        let mediaTypes = ["png": "image/png", "jpeg": "image/jpeg", "jpg": "image/jpeg", "gif": "image/gif",
                          "tif": "image/tiff", "tiff": "image/tiff", "bmp": "image/bmp", "emf": "image/x-emf", "wmf": "image/x-wmf"]
        for ext in Set(media.map { ($0.name as NSString).pathExtension.lowercased() }).sorted() {
            defaults.append((ext, mediaTypes[ext] ?? "application/octet-stream"))
        }
        put("[Content_Types].xml", Self.header + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
            + defaults.map { "<Default Extension=\"\($0.0)\" ContentType=\"\($0.1)\"/>" }.joined()
            + overrides.map { "<Override PartName=\"\($0.0)\" ContentType=\"\($0.1)\"/>" }.joined() + "</Types>")
        put("_rels/.rels", Self.rels([
            ("rId1", "ppt/presentation.xml", "\(Self.relNS)/officeDocument"),
            ("rId2", "docProps/core.xml", "http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties"),
            ("rId3", "docProps/app.xml", "\(Self.relNS)/extended-properties"),
        ]))
        let stamp = ISO8601DateFormatter().string(from: Date())
        put("docProps/core.xml", Self.header + """
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
        xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" \
        xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">\
        <dc:title>\(PPTXNode.escape(title))</dc:title><cp:revision>1</cp:revision>\
        <dcterms:created xsi:type="dcterms:W3CDTF">\(stamp)</dcterms:created>\
        <dcterms:modified xsi:type="dcterms:W3CDTF">\(stamp)</dcterms:modified></cp:coreProperties>
        """)
        put("docProps/app.xml", Self.header + """
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" \
        xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"><Application>YummyOrange</Application>\
        <Slides>\(slides.count)</Slides><PresentationFormat>Custom</PresentationFormat><AppVersion>16.0000</AppVersion></Properties>
        """)
        var presRels: [(String, String, String)] = [("rId1", "slideMasters/slideMaster1.xml", "\(Self.relNS)/slideMaster")]
        var ids = ""
        for i in slides.indices {
            presRels.append(("rId\(i + 2)", "slides/slide\(i + 1).xml", "\(Self.relNS)/slide"))
            ids += "<p:sldId id=\"\(256 + i)\" r:id=\"rId\(i + 2)\"/>"
        }
        let n = slides.count + 2
        presRels += [("rId\(n)", "presProps.xml", "\(Self.relNS)/presProps"), ("rId\(n + 1)", "viewProps.xml", "\(Self.relNS)/viewProps"),
                     ("rId\(n + 2)", "theme/theme1.xml", "\(Self.relNS)/theme"),
                     ("rId\(n + 3)", "tableStyles.xml", "\(Self.relNS)/tableStyles")]
        put("ppt/_rels/presentation.xml.rels", Self.rels(presRels))
        put("ppt/presentation.xml", Self.header + """
        <p:presentation \(Self.ns) saveSubsetFonts="1"><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/>\
        </p:sldMasterIdLst>\(slides.isEmpty ? "" : "<p:sldIdLst>\(ids)</p:sldIdLst>")<p:sldSz cx="\(width)" cy="\(height)"/>\
        <p:notesSz cx="6858000" cy="9144000"/><p:defaultTextStyle><a:defPPr><a:defRPr lang="en-US"/></a:defPPr>\
        \(defaultTextStyle)</p:defaultTextStyle></p:presentation>
        """)
        put("ppt/presProps.xml", Self.header + "<p:presentationPr \(Self.ns)/>")
        put("ppt/viewProps.xml", Self.header + "<p:viewPr \(Self.ns)><p:gridSpacing cx=\"76200\" cy=\"76200\"/></p:viewPr>")
        put("ppt/tableStyles.xml", Self.header + "<a:tblStyleLst xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" "
            + "def=\"{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}\"/>")
        put("ppt/theme/theme1.xml", Self.themeXML)
        put("ppt/slideMasters/slideMaster1.xml", masterXML)
        put("ppt/slideMasters/_rels/slideMaster1.xml.rels", Self.rels([
            ("rId1", "../slideLayouts/slideLayout1.xml", "\(Self.relNS)/slideLayout"),
            ("rId2", "../theme/theme1.xml", "\(Self.relNS)/theme"),
        ]))
        put("ppt/slideLayouts/slideLayout1.xml", Self.layoutXML)
        put("ppt/slideLayouts/_rels/slideLayout1.xml.rels", Self.rels([("rId1", "../slideMasters/slideMaster1.xml", "\(Self.relNS)/slideMaster")]))
        for (i, s) in slides.enumerated() {
            put("ppt/slides/slide\(i + 1).xml", slideXML(s))
            put("ppt/slides/_rels/slide\(i + 1).xml.rels",
                Self.rels([("rId1", "../slideLayouts/slideLayout1.xml", "\(Self.relNS)/slideLayout")] + s.rels.map { ($0.id, $0.target, $0.type) }))
        }
        for m in media { out["ppt/media/\(m.name)"] = m.data }
        return out
    }

    /// Writes the package; [Content_Types].xml goes first, as Office expects.
    func write(to url: URL) throws {
        let all = parts()
        let z = ZipWriter()
        let order = ["[Content_Types].xml", "_rels/.rels"]
        for name in order { if let d = all[name] { try z.add(name, data: d) } }
        for name in all.keys.sorted() where !order.contains(name) {
            let isMedia = name.hasPrefix("ppt/media/")
            // Media is already compressed; storing it keeps the write fast.
            try z.add(name, data: all[name]!, compress: !isMedia || name.hasSuffix(".bmp") || name.hasSuffix(".tiff"))
        }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).pptx")
        do {
            try z.write(to: tmp)
            try FileManager.default.moveItem(at: tmp, to: url)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw ConversionError.toolFailed("Couldn’t save \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
