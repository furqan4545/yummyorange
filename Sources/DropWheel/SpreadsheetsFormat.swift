import Foundation

/// Excel-style number format codes ("#,##0.00", "0%", "yyyy-mm-dd h:mm"): which ones are dates, and
/// how a value looks with one. Covers sections (positive;negative;zero;text), digit placeholders,
/// grouping and scaling commas, percent, scientific notation, simple fractions, quoted and escaped
/// literals, [$€-x] currency, colours and conditions (ignored), and every date and time token.
enum SheetNumberFormat {
    /// Excel's built-in formats by id. 14 and 22 are locale-dependent in Excel; ISO order is used here.
    static func builtIn(_ id: Int) -> String? {
        switch id {
        case 0: return "General"
        case 1: return "0"
        case 2: return "0.00"
        case 3: return "#,##0"
        case 4: return "#,##0.00"
        case 5: return "\"$\"#,##0_);(\"$\"#,##0)"
        case 6: return "\"$\"#,##0_);[Red](\"$\"#,##0)"
        case 7: return "\"$\"#,##0.00_);(\"$\"#,##0.00)"
        case 8: return "\"$\"#,##0.00_);[Red](\"$\"#,##0.00)"
        case 9: return "0%"
        case 10: return "0.00%"
        case 11: return "0.00E+00"
        case 12: return "# ?/?"
        case 13: return "# ??/??"
        case 14: return "yyyy-mm-dd"
        case 15: return "d-mmm-yy"
        case 16: return "d-mmm"
        case 17: return "mmm-yy"
        case 18: return "h:mm AM/PM"
        case 19: return "h:mm:ss AM/PM"
        case 20: return "h:mm"
        case 21: return "h:mm:ss"
        case 22: return "yyyy-mm-dd h:mm"
        case 27...31, 50...58: return "yyyy-mm-dd"        // East Asian date formats
        case 32...35: return "h:mm:ss"                     // East Asian time formats
        case 36: return "yyyy-mm-dd"
        case 37: return "#,##0 ;(#,##0)"
        case 38: return "#,##0 ;[Red](#,##0)"
        case 39: return "#,##0.00;(#,##0.00)"
        case 40: return "#,##0.00;[Red](#,##0.00)"
        case 41: return "_(* #,##0_);_(* (#,##0);_(* \"-\"_);_(@_)"
        case 42: return "_(\"$\"* #,##0_);_(\"$\"* (#,##0);_(\"$\"* \"-\"_);_(@_)"
        case 43: return "_(* #,##0.00_);_(* (#,##0.00);_(* \"-\"??_);_(@_)"
        case 44: return "_(\"$\"* #,##0.00_);_(\"$\"* (#,##0.00);_(\"$\"* \"-\"??_);_(@_)"
        case 45: return "mm:ss"
        case 46: return "[h]:mm:ss"
        case 47: return "mm:ss.0"
        case 48: return "##0.0E+0"
        case 49: return "@"
        default: return nil
        }
    }

    /// The built-in id for a code, so writers can refer to it instead of declaring it.
    static func builtInID(_ code: String) -> Int? {
        switch code {
        case "General": return 0
        case "0": return 1
        case "0.00": return 2
        case "#,##0": return 3
        case "#,##0.00": return 4
        case "0%": return 9
        case "0.00%": return 10
        case "0.00E+00": return 11
        case "# ?/?": return 12
        case "# ??/??": return 13
        case "h:mm AM/PM": return 18
        case "h:mm:ss AM/PM": return 19
        case "h:mm": return 20
        case "h:mm:ss": return 21
        case "mm:ss": return 45
        case "[h]:mm:ss": return 46
        case "@": return 49
        default: return nil
        }
    }

    // MARK: Tokens

    enum Token: Equatable {
        case literal(String)
        case general
        case digit(Character)          // 0 # ?
        case point
        case comma
        case percent
        case exponent(String)          // "E+", "E-"
        case slash
        case text                      // @
        case date(String)              // "yyyy", "mm" (month or minute, see `minuteIndices`), "d", "h", "s"
        case elapsed(Character, Int)   // [h], [mm], [ss]
        case ampm(String)              // "AM/PM", "am/pm", "A/P"
        case fraction(Int)             // ".000" after seconds
    }

    struct Section {
        var tokens: [Token]
        var isDate: Bool { tokens.contains { if case .date = $0 { return true }; if case .elapsed = $0 { return true }; if case .ampm = $0 { return true }; return false } }
        var hasText: Bool { tokens.contains(.text) }
        var isGeneral: Bool { tokens.contains(.general) }
    }

    private static var cache: [String: [Section]] = [:]
    private static let cacheLock = NSLock()

    /// The code split into sections and tokens (cached; codes repeat across millions of cells).
    static func sections(_ code: String) -> [Section] {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let s = cache[code] { return s }
        let parsed = splitSections(code).map { Section(tokens: tokenize($0)) }
        if cache.count > 2000 { cache.removeAll() }
        cache[code] = parsed
        return parsed
    }

    private static func splitSections(_ code: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuote = false, inBracket = false, escape = false
        for ch in code {
            if escape { current.append(ch); escape = false; continue }
            switch ch {
            case "\\" where !inQuote: escape = true; current.append(ch)
            case "\"": inQuote.toggle(); current.append(ch)
            case "[" where !inQuote: inBracket = true; current.append(ch)
            case "]" where !inQuote: inBracket = false; current.append(ch)
            case ";" where !inQuote && !inBracket: parts.append(current); current = ""
            default: current.append(ch)
            }
        }
        parts.append(current)
        return parts
    }

    private static func tokenize(_ section: String) -> [Token] {
        var tokens: [Token] = []
        let chars = Array(section)
        var i = 0
        func lit(_ s: String) {
            if case .literal(let prev)? = tokens.last { tokens[tokens.count - 1] = .literal(prev + s) } else { tokens.append(.literal(s)) }
        }
        while i < chars.count {
            let ch = chars[i]
            let lower = Character(ch.lowercased())
            switch ch {
            case "\"":
                var j = i + 1, s = ""
                while j < chars.count, chars[j] != "\"" { s.append(chars[j]); j += 1 }
                lit(s); i = j + 1; continue
            case "\\":
                if i + 1 < chars.count { lit(String(chars[i + 1])) }
                i += 2; continue
            case "_":
                lit(" "); i += 2; continue
            case "*":
                i += 2; continue
            case "[":
                var j = i + 1, s = ""
                while j < chars.count, chars[j] != "]" { s.append(chars[j]); j += 1 }
                i = j + 1
                let l = s.lowercased()
                if let first = l.first, "hms".contains(first), l.allSatisfy({ $0 == first }) {
                    tokens.append(.elapsed(first, l.count))
                } else if s.hasPrefix("$") {
                    let body = s.dropFirst()
                    let symbol = body.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
                    if !symbol.isEmpty { lit(String(symbol)) }
                }
                continue   // colours, conditions, [DBNum1]…
            case "0", "#", "?":
                tokens.append(.digit(ch))
            case ".":
                // A point right after seconds starts fractional seconds.
                var j = i + 1, zeros = 0
                while j < chars.count, chars[j] == "0" { zeros += 1; j += 1 }
                if zeros > 0, let last = tokens.last(where: { if case .literal = $0 { return false }; return true }),
                   case .date(let d) = last, d.hasPrefix("s") {
                    tokens.append(.fraction(zeros)); i = j; continue
                }
                if zeros > 0, let last = tokens.last, case .elapsed("s", _) = last {
                    tokens.append(.fraction(zeros)); i = j; continue
                }
                tokens.append(.point)
            case ",": tokens.append(.comma)
            case "%": tokens.append(.percent)
            case "/":
                tokens.append(.slash)
            case "@": tokens.append(.text)
            default:
                if lower == "e", i + 1 < chars.count, chars[i + 1] == "+" || chars[i + 1] == "-",
                   tokens.contains(where: { if case .digit = $0 { return true }; return false }) {
                    tokens.append(.exponent("E" + String(chars[i + 1]))); i += 2; continue
                }
                if lower == "g", String(chars[i...].prefix(7)).lowercased() == "general" {
                    tokens.append(.general); i += 7; continue
                }
                if lower == "a" {
                    let rest = String(chars[i...].prefix(5))
                    if rest.lowercased() == "am/pm" { tokens.append(.ampm(rest)); i += 5; continue }
                    let short = String(chars[i...].prefix(3))
                    if short.lowercased() == "a/p" { tokens.append(.ampm(short)); i += 3; continue }
                }
                if "ymdhs".contains(lower) {
                    var j = i
                    while j < chars.count, Character(chars[j].lowercased()) == lower { j += 1 }
                    tokens.append(.date(String(repeating: lower, count: j - i)))
                    i = j; continue
                }
                lit(String(ch))
            }
            i += 1
        }
        // A "/" in a date section is a literal separator.
        if tokens.contains(where: { if case .date = $0 { return true }; return false }) {
            tokens = tokens.map { $0 == .slash ? .literal("/") : $0 }
        }
        return tokens
    }

    /// Indices of "m"/"mm" tokens that mean minutes: right after an hour, or right before seconds.
    private static func minuteIndices(_ tokens: [Token]) -> Set<Int> {
        var result = Set<Int>()
        let dateIdx = tokens.indices.filter { if case .date = tokens[$0] { return true }; if case .elapsed = tokens[$0] { return true }; return false }
        for (k, i) in dateIdx.enumerated() {
            guard case .date(let d) = tokens[i], d.hasPrefix("m"), d.count <= 2 else { continue }
            let prev = k > 0 ? tokens[dateIdx[k - 1]] : nil
            let next = k + 1 < dateIdx.count ? tokens[dateIdx[k + 1]] : nil
            var afterHour = false, beforeSecond = false
            if case .date(let p)? = prev, p.hasPrefix("h") { afterHour = true }
            if case .elapsed("h", _)? = prev { afterHour = true }
            if case .date(let n)? = next, n.hasPrefix("s") { beforeSecond = true }
            if case .elapsed("s", _)? = next { beforeSecond = true }
            if afterHour || beforeSecond { result.insert(i) }
        }
        return result
    }

    // MARK: Classification

    /// Whether a code shows dates, times or both; nil for every other code.
    static func dateKind(_ code: String) -> SheetDateKind? {
        guard let first = sections(code).first, first.isDate else { return nil }
        let minutes = minuteIndices(first.tokens)
        var hasDate = false, hasTime = false
        for (i, t) in first.tokens.enumerated() {
            switch t {
            case .date(let d):
                if d.hasPrefix("y") || d.hasPrefix("d") || (d.hasPrefix("m") && !minutes.contains(i)) { hasDate = true }
                else { hasTime = true }
            case .elapsed, .ampm, .fraction: hasTime = true
            default: break
            }
        }
        if hasDate && hasTime { return .dateTime }
        return hasDate ? .date : .time
    }

    /// Whether a time code counts elapsed time ("[h]:mm:ss", "[mm]:ss") rather than showing a clock time.
    static func isElapsed(_ code: String) -> Bool {
        sections(code).first?.tokens.contains { if case .elapsed = $0 { return true }; return false } ?? false
    }

    /// A short description of a numeric code for writers that need structure (ODS number styles).
    struct NumberShape {
        var decimals = 0
        var minInteger = 1
        var grouping = false
        var percent = false
        var scientific = false
        var prefix = ""
        var suffix = ""
    }

    /// The shape of a plain numeric code's first section, or nil for General, dates, text and fractions.
    static func numberShape(_ code: String) -> NumberShape? {
        guard let s = sections(code).first, !s.isDate, !s.isGeneral, !s.hasText,
              s.tokens.contains(where: { if case .digit = $0 { return true }; return false }),
              !s.tokens.contains(.slash) else { return nil }
        var shape = NumberShape()
        var seenDigit = false, afterPoint = false, intZeros = 0
        var lastDigitIndex = 0
        for (i, t) in s.tokens.enumerated() { if case .digit = t { lastDigitIndex = i } }
        for (i, t) in s.tokens.enumerated() {
            switch t {
            case .digit(let d):
                seenDigit = true
                if afterPoint { shape.decimals += 1 } else if d == "0" { intZeros += 1 }
            case .point: afterPoint = true
            case .comma: if seenDigit && i < lastDigitIndex && !afterPoint { shape.grouping = true }
            case .percent: shape.percent = true
            case .exponent: shape.scientific = true
            case .literal(let l):
                if !seenDigit { shape.prefix += l } else if i > lastDigitIndex { shape.suffix += l }
            default: break
            }
        }
        shape.minInteger = intZeros
        return shape
    }

    // MARK: Display

    /// How a value looks in a cell with `code`.
    static func display(_ value: SheetValue, code: String) -> String {
        switch value {
        case .empty: return ""
        case .bool(let b): return b ? "TRUE" : "FALSE"
        case .error(let e): return e
        case .text(let s):
            let secs = sections(code)
            if let textSection = secs.count >= 4 ? secs[3] : secs.first(where: { $0.hasText }) {
                return render(text: s, textSection)
            }
            return s
        case .number(let v):
            return formatNumber(v, code: code)
        case .date(let d, let kind):
            if code != "General", let first = sections(code).first, first.isDate {
                return renderDate(d, first.tokens)
            }
            if code != "General", !(sections(code).first?.isGeneral ?? true) {
                return formatNumber(d, code: code)
            }
            return defaultDate(d, kind)
        }
    }

    /// The ISO-like form used when a date carries no format of its own.
    static func defaultDate(_ d: Double, _ kind: SheetDateKind) -> String {
        switch kind {
        case .date: return SheetDate.iso(d, .date)
        case .dateTime: return SheetDate.iso(d, .dateTime, separator: " ")
        case .time: return SheetDate.iso(d, .time)
        }
    }

    static func formatNumber(_ v: Double, code: String) -> String {
        guard v.isFinite else { return v.isNaN ? "#NUM!" : (v > 0 ? "∞" : "-∞") }
        let secs = sections(code)
        guard !secs.isEmpty, !(secs.count == 1 && secs[0].isGeneral) else { return general(v) }
        var section = secs[0]
        var signed = true
        if secs.count >= 2 && v < 0 { section = secs[1]; signed = false }
        if secs.count >= 3 && v == 0 { section = secs[2] }
        if section.isGeneral { return general(signed ? v : abs(v)) }
        if section.isDate { return renderDate(v, section.tokens) }
        if section.tokens.allSatisfy({ if case .literal = $0 { return true }; return false }) {
            return section.tokens.map { if case .literal(let l) = $0 { return l }; return "" }.joined()
        }
        if section.hasText && !section.tokens.contains(where: { if case .digit = $0 { return true }; return false }) {
            return render(text: general(v), section)
        }
        return renderNumber(v, section.tokens, signed: signed)
    }

    /// Excel's General: up to 11 characters, switching to scientific notation for very large or small numbers.
    static func general(_ v: Double) -> String {
        if v == 0 { return "0" }
        // Whole numbers print in full up to 15 digits (Excel abbreviates them only in narrow columns).
        if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
        let a = abs(v)
        if a >= 1e-4 && a < 1e11 {
            let intDigits = a >= 1 ? Int(log10(a)) + 1 : 1
            let decimals = max(0, 10 - intDigits)
            var s = String(format: "%.\(decimals)f", v)
            if s.contains(".") {
                while s.hasSuffix("0") { s.removeLast() }
                if s.hasSuffix(".") { s.removeLast() }
            }
            return s
        }
        var s = String(format: "%.5E", v)       // 1.23457E+11
        if let e = s.range(of: "E") {
            var mantissa = String(s[..<e.lowerBound])
            if mantissa.contains(".") {
                while mantissa.hasSuffix("0") { mantissa.removeLast() }
                if mantissa.hasSuffix(".") { mantissa.removeLast() }
            }
            var exp = String(s[e.upperBound...])
            let sign = exp.first.map(String.init) ?? "+"
            exp.removeFirst()
            while exp.count > 2 && exp.hasPrefix("0") { exp.removeFirst() }
            s = mantissa + "E" + sign + exp
        }
        return s
    }

    private static func render(text: String, _ section: Section) -> String {
        section.tokens.map { t -> String in
            switch t {
            case .text: return text
            case .literal(let l): return l
            default: return ""
            }
        }.joined()
    }

    private static func renderNumber(_ value: Double, _ tokens: [Token], signed: Bool) -> String {
        var v = abs(value)
        let negative = value < 0 && signed
        let percents = tokens.filter { $0 == .percent }.count
        for _ in 0..<percents { v *= 100 }
        guard v.isFinite else { return general(value) }    // a huge value times 100 per "%"

        // Split tokens at the exponent, then at the point.
        let expIndex = tokens.firstIndex { if case .exponent = $0 { return true }; return false }
        let mantissaTokens = expIndex.map { Array(tokens[..<$0]) } ?? tokens
        let exponentTokens = expIndex.map { Array(tokens[($0 + 1)...]) } ?? []

        if mantissaTokens.contains(.slash) { return (negative ? "-" : "") + fraction(v, mantissaTokens) }

        // Commas straight after the last integer placeholder divide by 1,000 each.
        let pointIndex = mantissaTokens.firstIndex(of: .point)
        let intTokens = pointIndex.map { Array(mantissaTokens[..<$0]) } ?? mantissaTokens
        let fracTokens = pointIndex.map { Array(mantissaTokens[($0 + 1)...]) } ?? []
        var grouping = false, scale = 0
        if let lastDigit = intTokens.lastIndex(where: { if case .digit = $0 { return true }; return false }) {
            var j = lastDigit + 1
            while j < intTokens.count, intTokens[j] == .comma { scale += 1; j += 1 }
            let firstDigit = intTokens.firstIndex(where: { if case .digit = $0 { return true }; return false }) ?? 0
            grouping = intTokens[firstDigit..<lastDigit].contains(.comma)
        }
        for _ in 0..<scale { v /= 1000 }

        let decimals = fracTokens.filter { if case .digit = $0 { return true }; return false }.count
        var exponent = 0
        if let expIndex, case .exponent(let sign) = tokens[expIndex] {
            let intPlaces = max(1, intTokens.filter { if case .digit = $0 { return true }; return false }.count)
            if v != 0 {
                exponent = Int(floor(log10(v)))
                // "##0.0E+0" (engineering notation) keeps the exponent a multiple of the integer places.
                if intPlaces > 1 { exponent = Int(floor(Double(exponent) / Double(intPlaces))) * intPlaces }
                // Two steps for subnormal values, whose power of ten is itself below the smallest double.
                func scaled(_ e: Int) -> Double { e < -300 ? v * 1e100 / pow(10, Double(e + 100)) : v / pow(10, Double(e)) }
                var mant = scaled(exponent)
                let rounded = (mant * pow(10, Double(decimals))).rounded() / pow(10, Double(decimals))
                if rounded >= pow(10, Double(intPlaces)) { exponent += intPlaces; mant = scaled(exponent) }
                v = mant
            }
            let expDigits = max(1, exponentTokens.filter { if case .digit = $0 { return true }; return false }.count)
            var e = String(abs(exponent))
            while e.count < expDigits { e = "0" + e }
            let expText = (exponent < 0 ? "-" : (sign == "E+" ? "+" : "")) + e
            let body = digits(v, intTokens, fracTokens, decimals: decimals, grouping: grouping)
            let tail = exponentTokens.compactMap { if case .literal(let l) = $0 { return l }; return nil }.joined()
            return (negative ? "-" : "") + body + "E" + expText + tail
        }
        let body = digits(v, intTokens, fracTokens, decimals: decimals, grouping: grouping)
        let allZero = !body.contains { $0.isNumber && $0 != "0" }
        return (negative && !allZero ? "-" : "") + body
    }

    /// Places the integer and fraction digits into their placeholders, keeping literals where they stand.
    private static func digits(_ v: Double, _ intTokens: [Token], _ fracTokens: [Token], decimals: Int, grouping: Bool) -> String {
        let rounded = String(format: "%.\(decimals)f", v)
        let parts = rounded.split(separator: ".", omittingEmptySubsequences: false)
        var intDigits = String(parts[0])
        var fracDigits = parts.count > 1 ? String(parts[1]) : ""

        // Integer part.
        func isDigit(_ t: Token) -> Bool { if case .digit = t { return true }; return false }
        func plain(_ ts: ArraySlice<Token>) -> String {
            ts.map { t -> String in
                switch t {
                case .literal(let l): return l
                case .percent: return "%"
                default: return ""
                }
            }.joined()
        }
        var intOut: String
        if let firstPH = intTokens.firstIndex(where: isDigit), let lastPH = intTokens.lastIndex(where: isDigit) {
            let minDigits = intTokens.filter { $0 == .digit("0") }.count
            if intDigits == "0" && minDigits == 0 { intDigits = "" }
            while intDigits.count < minDigits { intDigits = "0" + intDigits }
            let middle = intTokens[firstPH...lastPH]
            let prefix = plain(intTokens[..<firstPH]), suffix = plain(intTokens[(lastPH + 1)...])
            if grouping || !middle.contains(where: { if case .literal = $0 { return true }; return false }) {
                if grouping, intDigits.count > 3 {
                    var grouped = ""
                    for (k, ch) in intDigits.reversed().enumerated() {
                        if k > 0 && k % 3 == 0 { grouped.append(",") }
                        grouped.append(ch)
                    }
                    intDigits = String(grouped.reversed())
                }
                // Leading "?" placeholders pad with spaces.
                let questionPad = max(0, middle.filter { $0 == .digit("?") }.count - intDigits.count)
                intOut = prefix + String(repeating: " ", count: questionPad) + intDigits + suffix
            } else {
                // Literals between placeholders ("000-0000"): fill from the right.
                var remaining = Array(intDigits)
                var body = ""
                for idx in stride(from: lastPH, through: firstPH, by: -1) {
                    switch intTokens[idx] {
                    case .digit(let d):
                        if idx == firstPH { body = String(remaining) + body; remaining = [] }
                        else if let last = remaining.popLast() { body = String(last) + body }
                        else if d == "?" { body = " " + body }
                    case .literal(let l): body = l + body
                    default: break
                    }
                }
                intOut = prefix + body + suffix
            }
        } else {
            intOut = plain(intTokens[...]) + (intDigits == "0" ? "" : intDigits)
        }

        // Fraction part: trim zeros that only # or ? asked for.
        var fracOut = ""
        let fracPlaceholders = fracTokens.compactMap { t -> Character? in if case .digit(let d) = t { return d }; return nil }
        var chars = Array(fracDigits)
        var k = chars.count - 1
        while k >= 0, k < fracPlaceholders.count, chars[k] == "0", fracPlaceholders[k] != "0" {
            chars[k] = fracPlaceholders[k] == "?" ? " " : "\u{0}"
            k -= 1
        }
        fracDigits = String(chars.filter { $0 != "\u{0}" })
        var fi = fracDigits.startIndex
        for t in fracTokens {
            switch t {
            case .digit:
                if fi < fracDigits.endIndex { fracOut.append(fracDigits[fi]); fi = fracDigits.index(after: fi) }
            case .literal(let l): fracOut += l
            case .percent: fracOut += "%"
            default: break
            }
        }
        let hasPoint = !fracTokens.isEmpty || decimals > 0
        return intOut + (hasPoint && (decimals > 0 || !fracOut.isEmpty) ? "." : "") + fracOut
    }

    /// "# ?/?" style fractions, with the best denominator that fits the placeholders. Everything is computed in
    /// doubles, so no value can overflow an integer; values too big to have a fraction (15 digits and more) are
    /// shown in General.
    private static func fraction(_ v: Double, _ tokens: [Token]) -> String {
        guard let slash = tokens.firstIndex(of: .slash), v.isFinite, v < 1e15 else { return general(v) }
        let denTokens = tokens[(slash + 1)...]
        let denPlaces = denTokens.filter { if case .digit = $0 { return true }; return false }.count
        let fixed = denTokens.compactMap { if case .literal(let l) = $0 { return Double(l.trimmingCharacters(in: .whitespaces)) }; return nil }.first
        let before = tokens[..<slash]
        // A whole-number part exists when placeholders are separated from the numerator by a literal space.
        let hasWhole = before.contains(.literal(" ")) || before.contains { if case .literal(let l) = $0 { return l.contains(" ") }; return false }
        var whole = hasWhole ? floor(v) : 0
        let frac = v - whole
        var num = 0.0, den = 1.0
        if let fixed, fixed >= 1, fixed < 1e15, fixed == fixed.rounded() {
            den = fixed; num = (frac * fixed).rounded()
        } else {
            // Excel's denominators have as many digits as the code's placeholders (at most 15 here).
            let maxDen = pow(10, Double(min(15, max(1, denPlaces)))) - 1
            (num, den) = closestFraction(frac, maxDenominator: maxDen)
        }
        if num == den && den > 0 { whole += 1; num = 0 }
        func digits(_ x: Double) -> String { String(format: "%.0f", x) }
        if hasWhole {
            if num == 0 { return digits(whole) }
            return (whole > 0 ? "\(digits(whole)) " : "") + "\(digits(num))/\(digits(den))"
        }
        return "\(digits(num))/\(digits(den))"
    }

    /// The fraction closest to `x` (≥ 0) with a denominator up to `maxDenominator`: the best of the last
    /// continued-fraction convergent that fits and its semiconvergent, so it takes a few steps for any limit.
    static func closestFraction(_ x: Double, maxDenominator: Double) -> (Double, Double) {
        guard x.isFinite, x >= 0, maxDenominator >= 1 else { return (0, 1) }
        var p0 = 0.0, q0 = 1.0, p1 = 1.0, q1 = 0.0
        var r = x
        for _ in 0..<64 {
            let a = floor(r)
            let q2 = q0 + a * q1
            if q2 > maxDenominator { break }
            (p0, q0, p1, q1) = (p1, q1, p0 + a * p1, q2)
            let f = r - a
            if f < 1e-12 || abs(x - p1 / q1) < 1e-15 * max(1, x) { break }
            r = 1 / f
        }
        guard q1 > 0 else { return (x.rounded(), 1) }
        let k = floor((maxDenominator - q0) / q1)
        let semi = (p0 + k * p1, q0 + k * q1)
        if k >= 1, semi.1 > 0, abs(x - semi.0 / semi.1) < abs(x - p1 / q1) { return semi }
        return (p1, q1)
    }

    /// Whether date tokens include a year, month or day (not only hours, minutes and seconds).
    private static func hasCalendarPart(_ tokens: [Token]) -> Bool {
        let minutes = minuteIndices(tokens)
        for (i, t) in tokens.enumerated() {
            if case .date(let d) = t, d.hasPrefix("y") || d.hasPrefix("d") || (d.hasPrefix("m") && !minutes.contains(i)) { return true }
        }
        return false
    }

    private static let monthNames = ["January", "February", "March", "April", "May", "June", "July", "August",
                                     "September", "October", "November", "December"]
    private static let dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    private static func renderDate(_ days: Double, _ tokens: [Token]) -> String {
        // Out of the date range (Excel shows "####"): the number itself, so nothing is lost.
        guard SheetDate.inRange(days) else { return general(days) }
        // A negative time or duration: the same amount with a minus sign (pre-1900 dates stay dates).
        if days < 0, !hasCalendarPart(tokens) { return "-" + renderDate(-days, tokens) }
        let hasAMPM = tokens.contains { if case .ampm = $0 { return true }; return false }
        // Round to what the code shows: whole seconds unless fractional seconds are asked for.
        let fracDigits = tokens.compactMap { if case .fraction(let n) = $0 { return n }; return nil }.first ?? 0
        let unit = 86400 * pow(10, Double(fracDigits))
        let value = (days * unit).rounded() / unit
        let p = SheetDate.parts(value)
        let minutes = minuteIndices(tokens)
        func pad(_ n: Int, _ width: Int) -> String {
            let s = String(n)
            return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
        }
        var out = ""
        for (i, t) in tokens.enumerated() {
            switch t {
            case .literal(let l): out += l
            case .date(let d):
                let n = d.count
                switch d.first! {
                case "y": out += n <= 2 ? pad(p.year % 100, 2) : pad(p.year, 4)
                case "m" where minutes.contains(i): out += n >= 2 ? pad(p.minute, 2) : String(p.minute)
                case "m":
                    switch n {
                    case 1: out += String(p.month)
                    case 2: out += pad(p.month, 2)
                    case 3: out += String(monthNames[p.month - 1].prefix(3))
                    case 5: out += String(monthNames[p.month - 1].prefix(1))
                    default: out += monthNames[p.month - 1]
                    }
                case "d":
                    switch n {
                    case 1: out += String(p.day)
                    case 2: out += pad(p.day, 2)
                    case 3: out += String(dayNames[p.weekday].prefix(3))
                    default: out += dayNames[p.weekday]
                    }
                case "h":
                    var h = p.hour
                    if hasAMPM { h = h % 12; if h == 0 { h = 12 } }
                    out += n >= 2 ? pad(h, 2) : String(h)
                case "s": out += n >= 2 ? pad(p.second, 2) : String(p.second)
                default: out += d
                }
            case .elapsed(let unitChar, let n):
                let totalSeconds = Int((value * 86400).rounded(.down))
                let amount: Int
                switch unitChar {
                case "h": amount = totalSeconds / 3600
                case "m": amount = totalSeconds / 60
                default: amount = totalSeconds
                }
                out += pad(amount, n)
            case .ampm(let style):
                let pm = p.hour >= 12
                if style.count == 3 {
                    let a = pm ? "P" : "A"
                    out += style.first!.isLowercase ? a.lowercased() : a
                } else {
                    let a = pm ? "PM" : "AM"
                    out += style.first!.isLowercase ? a.lowercased() : a
                }
            case .fraction(let n):
                out += "." + String(pad(p.millisecond, 3).prefix(n)).padding(toLength: n, withPad: "0", startingAt: 0)
            case .digit(let d): out += d == "0" ? "0" : ""
            case .point: out += "."
            case .comma: out += ","
            case .percent: out += "%"
            case .slash: out += "/"
            default: break
            }
        }
        return out
    }
}
