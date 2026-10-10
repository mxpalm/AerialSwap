// Draws AerialSwap's app icon (an original dusk landscape) as a 1024x1024 PNG.
// usage: swift Tools/make_icon.swift <out.png>
import AppKit

let size: CGFloat = 1024
let out = URL(fileURLWithPath: CommandLine.arguments[1])

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
// Work top-down (y = 0 at the top) to keep the coordinates readable.
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}
func gradient(_ stops: [(CGColor, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: srgb, colors: stops.map { $0.0 } as CFArray, locations: stops.map { $0.1 })!
}

// macOS icon grid: 824 pt body inset by 100 with a large corner radius.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
let horizon: CGFloat = 640

// Soft drop shadow under the body.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 28, color: color(0x000000, 0.35))
ctx.addPath(shape)
ctx.setFillColor(color(0x1B1F4B))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape)
ctx.clip()

// Sky: deep indigo -> violet -> warm amber at the horizon.
ctx.drawLinearGradient(gradient([(color(0x141842), 0), (color(0x3B2C77), 0.38), (color(0x9A4E8E), 0.68), (color(0xF4A261), 1)]),
                       start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: horizon), options: [])

// A few stars in the upper sky.
for (x, y, r) in [(250.0, 200.0, 4.0), (380, 160, 3), (700, 210, 4), (780, 300, 3), (560, 250, 2.5), (320, 300, 2.5)] {
    ctx.setFillColor(color(0xFFFFFF, 0.8))
    ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
}

// Sun glow and sun disc, sitting on the horizon.
let sun = CGPoint(x: 512, y: horizon - 40)
ctx.saveGState()
ctx.setBlendMode(.screen)
ctx.drawRadialGradient(gradient([(color(0xFFE2A8, 0.9), 0), (color(0xFFB36B, 0.35), 0.35), (color(0xFFB36B, 0), 1)]),
                       startCenter: sun, startRadius: 0, endCenter: sun, endRadius: 330, options: [])
ctx.restoreGState()
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: sun.x - 105, y: sun.y - 105, width: 210, height: 210))
ctx.clip()
ctx.drawLinearGradient(gradient([(color(0xFFF4CC), 0), (color(0xFFB45E), 1)]),
                       start: CGPoint(x: 0, y: sun.y - 105), end: CGPoint(x: 0, y: sun.y + 105), options: [])
ctx.restoreGState()

// Mountain ridges, far to near: smooth curves through the given points, closed at the base line.
func ridge(_ points: [(CGFloat, CGFloat)], base: CGFloat, fill: CGColor) {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 0, y: base))
    path.addLine(to: CGPoint(x: points[0].0, y: points[0].1))
    for i in 1..<points.count {
        let previous = CGPoint(x: points[i - 1].0, y: points[i - 1].1)
        let current = CGPoint(x: points[i].0, y: points[i].1)
        let mid = CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2)
        path.addQuadCurve(to: mid, control: previous)
        if i == points.count - 1 { path.addLine(to: current) }
    }
    path.addLine(to: CGPoint(x: size, y: base))
    path.closeSubpath()
    ctx.addPath(path)
    ctx.setFillColor(fill)
    ctx.fillPath()
}
ridge([(0, 515), (150, 455), (300, 525), (410, 565), (512, 592), (615, 560), (770, 445), (1024, 515)], base: horizon, fill: color(0x6B4C93))
ridge([(0, 580), (140, 522), (290, 595), (420, 610), (512, 622), (605, 608), (745, 522), (885, 588), (1024, 548)], base: horizon, fill: color(0x41306E))
ridge([(0, 625), (200, 585), (360, 640), (520, 600), (700, 645), (860, 595), (1024, 630)], base: horizon + 2, fill: color(0x241C47))

// Lake with the sun's reflection.
ctx.drawLinearGradient(gradient([(color(0x2A2257), 0), (color(0x161338), 1)]),
                       start: CGPoint(x: 0, y: horizon), end: CGPoint(x: 0, y: 924), options: [])
for (i, width) in [190.0, 150, 120, 92, 66, 44].enumerated() {
    let y = horizon + 26 + CGFloat(i) * 38
    let rect = CGRect(x: 512 - width / 2, y: y, width: width, height: 9)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 4.5, cornerHeight: 4.5, transform: nil))
    ctx.setFillColor(color(0xFFC27A, 0.75 - CGFloat(i) * 0.1))
    ctx.fillPath()
}

// Subtle top highlight, like system icons.
ctx.drawLinearGradient(gradient([(color(0xFFFFFF, 0.14), 0), (color(0xFFFFFF, 0), 1)]),
                       start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 420), options: [])
ctx.restoreGState()

// Thin light edge.
ctx.addPath(shape)
ctx.setStrokeColor(color(0xFFFFFF, 0.12))
ctx.setLineWidth(2)
ctx.strokePath()

try! rep.representation(using: .png, properties: [:])!.write(to: out)
print("wrote \(out.path)")
