import Accelerate
import CoreGraphics
import CoreText
import Foundation

/// A text layer's words and how they're set. The renderer draws it into a texture (`raster`) and shows that like an
/// image layer, so transforms, parents, effects and scripts work on it as on any image.
public struct SceneText: Sendable, Equatable {
    public let string: String
    /// A font file in the wallpaper (`fonts/x.ttf`) or one of Wallpaper Engine's `systemfont_<name>`.
    public let font: String
    public let pointSize: Double
    /// Empty space around the text, in pixels (Wallpaper Engine adds it when the text has effects, for shadows and glows).
    public let padding: Double
    /// "left", "center" or "right": lines within the block.
    public let alignment: String
    /// Lines wrap at this width (pixels), and only this many are kept, the last one ending in "…" when `ellipsis`.
    public let maxWidth: Double?
    public let maxRows: Int?
    public let ellipsis: Bool
    /// An opaque background behind the text, and the text's color then (it's drawn in, not tinted).
    public let background: SIMD3<Double>?
    public let color: SIMD3<Double>

    /// Wallpaper Engine sets point sizes at 300 dpi: measured against the box sizes it saves (4.12–4.17 px per point).
    static let pixelsPerPoint = 300.0 / 72
    static let maxCharacters = 4000
    static let maxLines = 200

    /// Scripts that read the clock or the date, the music playing, the sound or the cursor make live text (clocks, now playing):
    /// a video can't show it, so it's left out.
    static func isLive(_ script: String) -> Bool {
        script.range(of: #"\bDate\b|timeOfDay|getHours|getMinutes|toLocale(Time|Date)String|Media(Properties|Playback|Thumbnail|Status)|registerAudioBuffers|audioData|cursor(World|Screen)Position"#,
                     options: .regularExpression) != nil
    }

    /// The text as straight (not premultiplied) RGBA8 pixels, rows from the top, or nil when there's nothing to draw.
    func raster(files: SceneFiles) -> (pixels: [UInt8], width: Int, height: Int)? {
        let text = String(string.prefix(Self.maxCharacters)).replacingOccurrences(of: "\r\n", with: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let size = CGFloat(min(max(pointSize, 1), 500) * Self.pixelsPerPoint)
        let font = Self.loadFont(font, size: size, files: files)
        let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let textColor = background == nil ? white : CGColor(srgbRed: color.x, green: color.y, blue: color.z, alpha: 1)
        let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font,
                          NSAttributedString.Key(kCTForegroundColorAttributeName as String): textColor]

        // Lines: the text's own, each wrapped at the width limit; at most maxRows.
        let wrap = maxWidth.map { CGFloat(min(max($0, 1), 16_000)) }
        var lines: [CTLine] = []
        var truncated = false
        paragraphs: for paragraph in text.components(separatedBy: "\n") {
            let attributed = NSAttributedString(string: paragraph, attributes: attributes)
            let typesetter = CTTypesetterCreateWithAttributedString(attributed)
            let length = attributed.length
            var start = 0
            repeat {
                if lines.count >= min(maxRows ?? Self.maxLines, Self.maxLines) { truncated = true; break paragraphs }
                let count = wrap.map { max(1, CTTypesetterSuggestLineBreak(typesetter, start, Double($0))) } ?? (length - start)
                lines.append(CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count)))
                start += count
            } while start < length
        }
        if truncated, ellipsis, let last = lines.last {
            let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
            let width = wrap.map(Double.init) ?? CTLineGetTypographicBounds(last, nil, nil, nil)
            lines[lines.count - 1] = CTLineCreateTruncatedLine(last, width, .end, token) ?? last
        }

        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font), leading = CTFontGetLeading(font)
        let lineHeight = ceil(ascent + descent + leading)
        let widths = lines.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) }
        let pad = CGFloat(min(max(padding, 0), 512)).rounded()
        let blockWidth = ceil(min(widths.max() ?? 0, wrap ?? .greatestFiniteMagnitude))
        let width = Int(blockWidth + 2 * pad), height = Int(lineHeight * CGFloat(lines.count) + 2 * pad)
        guard width >= 1, height >= 1, width <= SceneLimits.maxTextureSide, height <= SceneLimits.maxTextureSide,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        if let background {
            context.setFillColor(CGColor(srgbRed: background.x, green: background.y, blue: background.z, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        context.setShouldSmoothFonts(false)
        for (index, line) in lines.enumerated() {
            let x: CGFloat = switch alignment {
            case "right": pad + blockWidth - widths[index]
            case "center": pad + (blockWidth - widths[index]) / 2
            default: pad
            }
            // Core Graphics counts from the bottom.
            context.textPosition = CGPoint(x: x, y: CGFloat(height) - pad - lineHeight * CGFloat(index) - ascent - leading / 2)
            CTLineDraw(line, context)
        }
        guard let data = context.data else { return nil }
        // The bitmap's first row in memory is the top of the image.
        var buffer = vImage_Buffer(data: data, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
        vImageUnpremultiplyData_RGBA8888(&buffer, &buffer, vImage_Flags(kvImageNoFlags))
        return (Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4)), width, height)
    }

    /// The wallpaper's font file, or the system font Wallpaper Engine's name stands for; Helvetica when neither works.
    private static func loadFont(_ name: String, size: CGFloat, files: SceneFiles) -> CTFont {
        if name.lowercased().hasPrefix("systemfont_") {
            let family = switch name.lowercased().dropFirst("systemfont_".count) {
            case "arial": "Arial"
            case "serif", "timesnewroman", "times": "Times New Roman"
            case "monospace", "courier", "couriernew", "consolas": "Menlo"
            case "verdana": "Verdana"
            case "georgia": "Georgia"
            case "tahoma": "Tahoma"
            case "comicsans", "comicsansms": "Comic Sans MS"
            case "impact": "Impact"
            case "trebuchetms", "trebuchet": "Trebuchet MS"
            default: "Helvetica Neue"
            }
            return CTFontCreateWithName(family as CFString, size, nil)
        }
        if let data = files.data(name), data.count < 32 << 20,
           let descriptor = CTFontManagerCreateFontDescriptorFromData(data as CFData) {
            return CTFontCreateWithFontDescriptor(descriptor, size, nil)
        }
        return CTFontCreateWithName("Helvetica Neue" as CFString, size, nil)
    }
}
