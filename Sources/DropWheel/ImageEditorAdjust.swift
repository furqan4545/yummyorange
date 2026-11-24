import CoreImage
import Foundation

extension ImageEditors {
    /// The Adjust editor's slider values. Zero is neutral for every one, and a neutral value skips its filter,
    /// so untouched sliders never change a pixel.
    ///
    /// Command-line options use the key names: exposure (EV, −3…3); contrast, brightness, highlights,
    /// shadows, warmth (also "temperature"), tint, saturation, vibrance (−100…100); sharpness (0…100);
    /// quality (0.1…1, for JPEG, HEIC and AVIF output; default 0.92).
    struct Adjustments: Equatable {
        enum Key: String, CaseIterable {
            case exposure, contrast, brightness, highlights, shadows, warmth, tint, saturation, vibrance, sharpness

            var title: String {
                switch self {
                case .exposure: return "Exposure"
                case .contrast: return "Contrast"
                case .brightness: return "Brightness"
                case .highlights: return "Highlights"
                case .shadows: return "Shadows"
                case .warmth: return "Warmth"
                case .tint: return "Tint"
                case .saturation: return "Saturation"
                case .vibrance: return "Vibrance"
                case .sharpness: return "Sharpness"
                }
            }

            var range: ClosedRange<Double> {
                switch self {
                case .exposure: return -3...3
                case .sharpness: return 0...100
                default: return -100...100
                }
            }

            /// Other option names accepted on the command line.
            var aliases: [String] { self == .warmth ? ["temperature", "temp"] : [] }

            /// "+0.50", "−25", "0".
            func format(_ value: Double) -> String {
                if abs(value) < 0.0001 { return self == .exposure ? "0.00" : "0" }
                let body = self == .exposure ? String(format: "%.2f", abs(value)) : String(Int(abs(value).rounded()))
                return (value < 0 ? "−" : "+") + body
            }

            /// Reads what someone typed in a value field: "+0.5", "−20", "-20", "0,5 EV".
            static func parse(_ text: String) -> Double? {
                var s = text.trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: ",", with: ".")
                    .replacingOccurrences(of: "EV", with: "", options: .caseInsensitive)
                    .trimmingCharacters(in: .whitespaces)
                if s.hasPrefix("+") { s.removeFirst() }
                return Double(s)
            }
        }

        /// Groups for the sidebar, in order.
        static let groups: [(title: String, symbol: String, keys: [Key])] = [
            ("Light", "sun.max", [.exposure, .contrast, .brightness, .highlights, .shadows]),
            ("Color", "drop", [.warmth, .tint, .saturation, .vibrance]),
            ("Detail", "triangle", [.sharpness]),
        ]

        private var values: [Key: Double] = [:]

        init() {}

        /// Values from command-line or snapshot options. Missing keys are neutral; out-of-range values are clamped.
        init(options: ToolOptions) throws {
            for key in Key.allCases {
                guard let name = ([key.rawValue] + key.aliases).first(where: { options[$0] != nil }),
                      let raw = options[name], !raw.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                guard let value = Key.parse(raw), value.isFinite else {
                    throw ConversionError.unsupported("\(name) must be a number from \(Ask.formatNumber(key.range.lowerBound)) "
                                                      + "to \(Ask.formatNumber(key.range.upperBound)), not “\(raw)”.")
                }
                self[key] = value
            }
        }

        subscript(key: Key) -> Double {
            get { values[key] ?? 0 }
            set {
                let clamped = min(key.range.upperBound, max(key.range.lowerBound, newValue))
                values[key] = abs(clamped) < 0.0001 ? nil : clamped
            }
        }

        var isNeutral: Bool { values.isEmpty }

        /// The values as options, for logs and tests ("exposure=0.5 contrast=20").
        var description: String {
            Key.allCases.filter { self[$0] != 0 }.map { "\($0.rawValue)=\(Ask.formatNumber(self[$0]))" }.joined(separator: " ")
        }

        // MARK: Pipeline

        /// Applies the adjustments. `scale` is the preview's size relative to the full image (1 when saving),
        /// so radius-based filters look the same on the proxy as on the result; `fullLongSide` is the full
        /// image's longer side in pixels.
        ///
        /// Order follows a raw developer: white balance, exposure, local highlights and shadows, the tone
        /// curve (contrast and highlight lift), brightness (a midtone gamma), color, then sharpening.
        /// CIToneCurve and CIGammaAdjust work on gamma-encoded values, so 50% gray stays put under contrast.
        func apply(to input: CIImage, scale: CGFloat = 1, fullLongSide: CGFloat) -> CIImage {
            let extent = input.extent
            var image = input

            let warmth = self[.warmth] / 100, tint = self[.tint] / 100
            if warmth != 0 || tint != 0 {
                // A lower target temperature warms the picture; a positive neutral tint pushes toward magenta.
                // Warmth moves in mireds so both directions feel equally strong.
                let mired = 1_000_000 / 6500 + warmth * 60
                image = image.applyingFilter("CITemperatureAndTint", parameters: [
                    "inputNeutral": CIVector(x: 6500, y: tint * 100),
                    "inputTargetNeutral": CIVector(x: 1_000_000 / mired, y: 0),
                ])
            }
            if self[.exposure] != 0 {
                image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: self[.exposure]])
            }
            let highlights = self[.highlights] / 100, shadows = self[.shadows] / 100
            if highlights < 0 || shadows != 0 {
                // Negative shadow amounts bite much harder than positive ones, so they get half the range.
                image = image.applyingFilter("CIHighlightShadowAdjust", parameters: [
                    "inputHighlightAmount": 1 + 0.7 * min(highlights, 0),
                    "inputShadowAmount": shadows < 0 ? shadows * 0.5 : shadows,
                ])
            }
            let contrast = self[.contrast] / 100
            if contrast != 0 || highlights != 0 {
                let lift = max(highlights, 0), recover = min(highlights, 0)
                image = image.applyingFilter("CIToneCurve", parameters: [
                    "inputPoint0": CIVector(x: 0, y: 0),
                    "inputPoint1": CIVector(x: 0.25, y: 0.25 - 0.09 * contrast),
                    "inputPoint2": CIVector(x: 0.5, y: 0.5 + 0.03 * lift),
                    "inputPoint3": CIVector(x: 0.75, y: 0.75 + 0.09 * contrast + 0.10 * lift + 0.05 * recover),
                    "inputPoint4": CIVector(x: 1, y: 1),
                ])
            }
            if self[.brightness] != 0 {
                image = image.applyingFilter("CIGammaAdjust", parameters: ["inputPower": pow(2, -0.8 * self[.brightness] / 100)])
            }
            if self[.saturation] != 0 {
                image = image.applyingFilter("CIColorControls", parameters: [
                    kCIInputSaturationKey: 1 + self[.saturation] / 100, kCIInputBrightnessKey: 0, kCIInputContrastKey: 1,
                ])
            }
            if self[.vibrance] != 0 {
                image = image.applyingFilter("CIVibrance", parameters: ["inputAmount": self[.vibrance] / 100])
            }
            if self[.sharpness] > 0 {
                let radius = max(0.5, 1.7 * max(1, fullLongSide / 2500) * scale)
                image = image.clampedToExtent().applyingFilter("CISharpenLuminance", parameters: [
                    "inputSharpness": self[.sharpness] / 100 * 1.6, "inputRadius": radius,
                ])
            }
            return image.cropped(to: extent)
        }

        // MARK: Saving

        /// Headless entry point (`--tool adjust --opt exposure=0.5 photo.jpg`): writes "<name> adjusted.<ext>".
        static func save(_ url: URL, options: ToolOptions) throws -> URL {
            let adjustments = try Adjustments(options: options)
            guard !adjustments.isNeutral else {
                throw ConversionError.unsupported("Every adjustment is at its neutral value, so there’s nothing to save. "
                                                  + "Pass values such as exposure=0.5 or contrast=20.")
            }
            return try adjustments.save(try SourceImage(url), quality: options.double("quality", 0.92))
        }

        /// Renders at full resolution and writes the copy next to the source, keeping its metadata.
        func save(_ source: SourceImage, quality: Double = 0.92) throws -> URL {
            let full = try source.fullImage()
            let input = CIImage(cgImage: full)
            let output = apply(to: input, scale: 1, fullLongSide: CGFloat(max(full.width, full.height)))
            let result = try ImageEditors.render(output, like: full)
            return try source.save(result, suffix: " adjusted", quality: quality)
        }
    }
}
