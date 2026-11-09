import Foundation

/// Where a scene goes in the output. A screen whose shape differs from the video's shows only the middle of it (the
/// wallpaper fills the screen), so the scene is framed for that part: `screenAspect` (width / height; nil means the
/// output's own shape). Filled, it covers that part and `position` picks which side of it shows where it's cut
/// (0 left or top, 1 right or bottom). Whole, all of it shows and the bars around it get a blurred copy.
public struct SceneFraming: Sendable, Equatable, Codable {
    public enum Mode: String, Sendable, Codable { case fill, whole }

    public var mode: Mode
    public var position: Double
    public var screenAspect: Double?

    public init(mode: Mode = .fill, position: Double = 0.5, screenAspect: Double? = nil) {
        self.mode = mode
        self.position = position
        self.screenAspect = screenAspect
    }

    public static let fill = SceneFraming()

    /// The part of a `width`×`height` output the screen shows: the middle, in the screen's shape.
    public func visible(width: Double, height: Double) -> (x: Double, y: Double, width: Double, height: Double) {
        guard let aspect = screenAspect, aspect.isFinite, aspect > 0.1, aspect < 10 else { return (0, 0, width, height) }
        let w = min(width, height * aspect), h = min(height, width / aspect)
        return ((width - w) / 2, (height - h) / 2, w, h)
    }

    /// Where a `scene`-sized canvas lands in a `width`×`height` output: its scale (output pixels per scene unit) and
    /// its top left corner, in pixels from the output's top left.
    public func placement(scene: SIMD2<Double>, width: Double, height: Double) -> (scale: Double, x: Double, y: Double) {
        let v = visible(width: width, height: height)
        guard scene.x > 0, scene.y > 0 else { return (1, v.x, v.y) }
        let scale = mode == .whole ? min(v.width / scene.x, v.height / scene.y) : max(v.width / scene.x, v.height / scene.y)
        let p = mode == .whole ? 0.5 : min(max(position.isFinite ? position : 0.5, 0), 1)
        return (scale, v.x + (v.width - scene.x * scale) * p, v.y + (v.height - scene.y * scale) * p)
    }

    /// Whether the scene, filled, is cut left and right (or else top and bottom), for a position control's direction.
    public func cutsSides(scene: SIMD2<Double>, width: Double, height: Double) -> Bool {
        let v = visible(width: width, height: height)
        return scene.x / scene.y > v.width / v.height
    }
}
