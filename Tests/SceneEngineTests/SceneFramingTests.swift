import Testing
@testable import SceneEngine

struct SceneFramingTests {
    let scene16x9 = SIMD2(3840.0, 2160.0)

    @Test func defaultFillIsCenteredCover() {
        let p = SceneFraming.fill.placement(scene: SIMD2(3440, 1440), width: 3840, height: 2160)
        #expect(p.scale == 1.5)
        #expect(p.x == (3840 - 3440 * 1.5) / 2 && p.y == 0)
    }

    /// A 16:10 screen shows the middle 3456 pixels of a 4K video; filled, a 16:9 scene still covers the video.
    @Test func fillForNarrowerScreen() {
        let framing = SceneFraming(mode: .fill, position: 0, screenAspect: 1.6)
        let v = framing.visible(width: 3840, height: 2160)
        #expect(v.x == 192 && v.width == 3456 && v.height == 2160)
        let p = framing.placement(scene: scene16x9, width: 3840, height: 2160)
        #expect(p.scale == 1 && p.x == 192 && p.y == 0)   // the scene's left edge at the screen's left edge
        #expect(framing.cutsSides(scene: scene16x9, width: 3840, height: 2160))
    }

    @Test func wholeFitsInsideScreen() {
        let framing = SceneFraming(mode: .whole, screenAspect: 1.6)
        let p = framing.placement(scene: scene16x9, width: 3840, height: 2160)
        #expect(p.scale == 0.9)
        #expect(p.x == 192 && p.y == 108)
    }

    @Test func oddAspectsAreIgnored() {
        let v = SceneFraming(screenAspect: .nan).visible(width: 100, height: 50)
        #expect(v.width == 100 && v.height == 50)
        #expect(SceneFraming(screenAspect: 0).visible(width: 100, height: 50).width == 100)
    }
}
