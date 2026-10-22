import AppKit
import CoreImage

/// How a low-resolution video really looks once it fills the display: a piece of a frame enlarged to the
/// screen's native pixels (Lanczos), shown at exactly one image pixel per screen pixel, next to the whole frame.
/// No simulated blur: the softness you see is the real enlargement (only HEVC compression is left out).
struct ResolutionPreview {
    /// Size of both images in the dialog, in points.
    static let size = CGSize(width: 248, height: 140)

    let actualSize: NSImage     // `size` points backed by exactly that many screen pixels
    let frame: NSImage
    let region: CGRect          // the enlarged piece, in unit coordinates of `frame` (origin top-left)
    let factor: Double          // enlargement on this display

    /// `screenPixels` is the display's native pixel size; `backingScale` its pixels per point.
    @MainActor
    static func make(url: URL, screenPixels: CGSize, backingScale: CGFloat) async -> ResolutionPreview? {
        guard let cg = await WallpaperLibrary.middleFrame(of: url, maxSize: .zero) else { return nil }   // .zero = full size
        let width = CGFloat(cg.width), height = CGFloat(cg.height)
        let factor = max(screenPixels.width / width, screenPixels.height / height)   // aspect fill, like the wallpaper
        let scaled = CIImage(cgImage: cg).applyingFilter("CILanczosScaleTransform",
                                                         parameters: [kCIInputScaleKey: factor, kCIInputAspectRatioKey: 1])
        let extent = scaled.extent
        let crop = CGSize(width: min(size.width * backingScale, extent.width), height: min(size.height * backingScale, extent.height))
        let rect = CGRect(x: extent.midX - crop.width / 2, y: extent.midY - crop.height / 2,
                          width: crop.width, height: crop.height).integral
        guard let piece = CIContext().createCGImage(scaled, from: rect) else { return nil }
        let region = CGRect(x: (rect.minX - extent.minX) / extent.width, y: (extent.maxY - rect.maxY) / extent.height,
                            width: rect.width / extent.width, height: rect.height / extent.height)
        return ResolutionPreview(actualSize: NSImage(cgImage: piece, size: NSSize(width: CGFloat(piece.width) / backingScale,
                                                                                  height: CGFloat(piece.height) / backingScale)),
                                 frame: NSImage(cgImage: cg, size: NSSize(width: width, height: height)),
                                 region: region, factor: factor)
    }
}
