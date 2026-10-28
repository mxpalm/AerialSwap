import AppKit
import SwiftUI

// Renders the README header (docs/images/header.jpg): a video frame behind the app icon, name and tagline.
// The icon comes from the installed /Applications/AerialSwap.app, as macOS draws it (Liquid Glass, 1024 px).
//   swiftc -o /tmp/make_header Tools/make_header.swift && /tmp/make_header <frame.png> <header.png>
// then: sips -s format jpeg -s formatOptions 85 header.png --out docs/images/header.jpg
let args = CommandLine.arguments
guard args.count == 3 else { print("usage: make_header <frame.png> <out.png>"); exit(2) }

func appIcon(side: CGFloat) -> NSImage {
    let icon = NSWorkspace.shared.icon(forFile: "/Applications/AerialSwap.app")
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1,
              respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    NSGraphicsContext.restoreGraphicsState()
    let image = NSImage(size: NSSize(width: side, height: side)); image.addRepresentation(rep); return image
}

struct Banner: View {
    let frame: NSImage
    let icon: NSImage
    var body: some View {
        ZStack {
            Image(nsImage: frame).resizable().aspectRatio(contentMode: .fill)
                .frame(width: 1280, height: 400).blur(radius: 2).clipped()
            LinearGradient(colors: [Color(red: 0.03, green: 0.05, blue: 0.12).opacity(0.92),
                                    Color(red: 0.03, green: 0.05, blue: 0.12).opacity(0.55),
                                    Color(red: 0.03, green: 0.05, blue: 0.12).opacity(0.15)],
                           startPoint: .leading, endPoint: .trailing)
            LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .top, endPoint: .bottom)
            HStack(spacing: 36) {
                Image(nsImage: icon).resizable().frame(width: 168, height: 168)
                    .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
                VStack(alignment: .leading, spacing: 10) {
                    Text("FOR macOS 27 · APPLE SILICON")
                        .font(.system(size: 15, weight: .semibold)).tracking(2.2)
                        .foregroundStyle(Color(red: 0.55, green: 0.75, blue: 1))
                    Text("AerialSwap").font(.system(size: 76, weight: .bold)).tracking(-1.6)
                    Text("Your own videos as moving wallpapers\non your Mac's lock screen and desktop.")
                        .font(.system(size: 25, weight: .regular)).lineSpacing(3).opacity(0.88)
                }
                .foregroundStyle(.white)
                Spacer()
            }
            .padding(.leading, 84)
        }
        .frame(width: 1280, height: 400)
        .environment(\.colorScheme, .dark)
    }
}

MainActor.assumeIsolated {
    let frame = NSImage(contentsOf: URL(fileURLWithPath: args[1]))!
    let renderer = ImageRenderer(content: Banner(frame: frame, icon: appIcon(side: 1024)))
    renderer.scale = 2
    let png = NSBitmapImageRep(cgImage: renderer.cgImage!).representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: args[2]))
}
