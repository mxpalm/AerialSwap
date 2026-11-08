import Foundation
import Testing
@testable import SceneEngine

@Suite struct SceneTextTests {
    private let files = try! SceneFiles(folder: FileManager.default.temporaryDirectory)   // system fonts only

    private func text(_ string: String, size: Double = 10, padding: Double = 0, maxWidth: Double? = nil, maxRows: Int? = nil,
                      background: SIMD3<Double>? = nil) -> SceneText {
        SceneText(string: string, font: "systemfont_arial", pointSize: size, padding: padding, alignment: "left",
                  maxWidth: maxWidth, maxRows: maxRows, ellipsis: true, background: background, color: .one)
    }

    @Test func sizeFollowsPointsAt300DPI() throws {
        let small = try #require(text("Hello").raster(files: files))
        let big = try #require(text("Hello", size: 20).raster(files: files))
        // Arial's line is about 1.15 em: 10 pt is 41.7 px.
        #expect((44 ... 52).contains(small.height))
        #expect(abs(Double(big.width) / Double(small.width) - 2) < 0.1)
        let padded = try #require(text("Hello", padding: 32).raster(files: files))
        #expect(padded.width == small.width + 64 && padded.height == small.height + 64)
    }

    @Test func wrapsAndLimitsRows() throws {
        let one = try #require(text("one two three four five six").raster(files: files))
        let wrapped = try #require(text("one two three four five six", maxWidth: 200).raster(files: files))
        #expect(wrapped.width <= 200 && wrapped.height >= 3 * one.height)
        let limited = try #require(text("one two three four five six", maxWidth: 200, maxRows: 2).raster(files: files))
        #expect(limited.height == 2 * one.height)
        #expect(text("a\nb\nc").raster(files: files)?.height == 3 * one.height)
    }

    @Test func pixelsAreStraightWhite() throws {
        let raster = try #require(text("Hello").raster(files: files))
        // Edges have partial coverage but stay white, as a non-premultiplied texture should.
        let pixels = stride(from: 0, to: raster.pixels.count, by: 4).map { Array(raster.pixels[$0 ..< $0 + 4]) }
        #expect(pixels.contains { $0[3] > 20 && $0[3] < 235 })
        #expect(pixels.filter { $0[3] > 20 }.allSatisfy { $0[0] > 240 && $0[1] > 240 && $0[2] > 240 })
        let boxed = try #require(text("Hi", background: SIMD3(1, 0, 0)).raster(files: files))
        #expect(boxed.pixels[0 ..< 4] == [255, 0, 0, 255])
    }

    @Test func emptyAndLive() {
        #expect(text("  \n ").raster(files: files) == nil)
        #expect(SceneText.isLive("export function update() { return new Date().getHours(); }"))
        #expect(SceneText.isLive("engine.registerAudioBuffers(16)"))
        #expect(SceneText.isLive("export function mediaPropertiesChanged(event) { /* MediaPropertiesEvent */ }"))
        #expect(!SceneText.isLive("export function update(value) { return value.toUpperCase(); }"))
    }
}
