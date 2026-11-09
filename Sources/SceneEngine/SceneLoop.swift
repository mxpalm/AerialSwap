import Foundation
import Metal

/// How a scene's video loops: its length, and how long its start fades in from the frame one period later (zero when
/// the scene repeats exactly).
public struct SceneLoop: Sendable, Equatable {
    public var period: Double
    public var crossfade: Double
    /// Where in the scene the loop begins (seconds): the video shows `start` to `start + period`.
    public var start: Double

    public init(period: Double, crossfade: Double, start: Double = 0) {
        self.period = period
        self.crossfade = crossfade
        self.start = start
    }

    /// A loop chosen for the scene, and how far its frames one period apart differ (0…1, in the part of the picture
    /// that differs most).
    public struct Plan: Sendable {
        public let loop: SceneLoop
        public let seam: Double
        /// Nothing in the scene changes over time except particles (which loop exactly at any length).
        public let isStill: Bool
    }

    /// Finds the period in `range` (seconds, on a 0.1 s grid, so it's a whole number of frames at 30, 60, 120 and
    /// 240 fps) after which the scene looks most like it did. Sprite sheets and effects that repeat are matched by
    /// what's rendered, not by reading their speeds; particles are left out of the comparison because they repeat
    /// at any period. Close scores go to the period nearest `preferred`. Effects that never repeat get a crossfade.
    public static func plan(document: SceneDocument, files: SceneFiles, range: ClosedRange<Double> = 10 ... 30,
                            preferred: Double = 20, device: MTLDevice? = nil) throws -> Plan {
        // Grid steps per second (0.1 s); times are made by dividing, so 19.9 stays 19.9.
        let perSecond = 10.0
        let samples = [0.0, 0.7, 1.4]
        let (renderer, width, height) = try probe(document: document, files: files, device: device)
        let lowest = Int((range.lowerBound * perSecond).rounded()), highest = Int((range.upperBound * perSecond).rounded())
        let last = highest + Int((samples.last! * perSecond).rounded())

        var frames: [[UInt8]] = []
        frames.reserveCapacity(last + 1)
        for index in 0 ... last {
            let texture = try renderer.render(time: Double(index) / perSecond)
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            frames.append(bytes)
        }
        func difference(_ a: [UInt8], _ b: [UInt8]) -> Double { Self.difference(a, b, width: width, height: height) }

        var scores: [(period: Int, score: Double)] = []
        for period in lowest ... highest {
            let score = samples.map { s -> Double in
                let start = Int((s * perSecond).rounded())
                return difference(frames[start], frames[start + period])
            }.reduce(0, +) / Double(samples.count)
            scores.append((period, score))
        }
        let best = scores.map(\.score).min() ?? 0
        let isStill = (scores.map(\.score).max() ?? 0) < 0.5 / 255
        // Scores this close to the best look the same; take the one nearest the preferred length.
        let tolerance = max(0.5 / 255, best * 0.15)
        let chosen = scores.filter { $0.score <= best + tolerance }
            .min { abs(Double($0.period) / perSecond - preferred) < abs(Double($1.period) / perSecond - preferred) } ?? scores[0]
        let period = Double(chosen.period) / perSecond
        return Plan(loop: SceneLoop(period: period, crossfade: crossfade(seam: chosen.score, period: period)), seam: chosen.score,
                    isStill: isStill)
    }

    /// The loop for a part the user chose (`start`, `period` seconds): crossfaded unless the scene looks the same at
    /// both ends (a whole animation cycle).
    public static func chosen(start: Double, period: Double, document: SceneDocument, files: SceneFiles,
                              device: MTLDevice? = nil) throws -> SceneLoop {
        let (renderer, width, height) = try probe(document: document, files: files, device: device)
        func frame(_ time: Double) throws -> [UInt8] {
            let texture = try renderer.render(time: time)
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            return bytes
        }
        // Forward only, so scripts don't start over: each sample's start, then its frame one period on.
        let samples = [0.0, 0.7, 1.4]
        let starts = try samples.map { try frame(start + $0) }
        let ends = try samples.map { try frame(start + period + $0) }
        let seam = zip(starts, ends).map { difference($0, $1, width: width, height: height) }.reduce(0, +) / Double(samples.count)
        return SceneLoop(period: period, crossfade: crossfade(seam: seam, period: period), start: start)
    }

    private static func crossfade(seam: Double, period: Double) -> Double { seam < 0.5 / 255 ? 0 : min(2, period / 4) }

    /// A small, quick renderer for comparing frames (no particles: they repeat at any period).
    private static func probe(document: SceneDocument, files: SceneFiles, device: MTLDevice?) throws
        -> (renderer: SceneRenderer, width: Int, height: Int)
    {
        let width = 160, height = max(1, Int((160 * document.general.height / document.general.width).rounded()))
        let renderer = try SceneRenderer(document: document, files: files, width: width, height: height,
                                         bufferScale: 0.25, particles: false, device: device)
        return (renderer, width, height)
    }

    /// The mean difference of the 8×8 block that differs most, so a small sprite out of step counts as much as a
    /// whole sky.
    private static func difference(_ a: [UInt8], _ b: [UInt8], width: Int, height: Int) -> Double {
        let block = 8
        var worst = 0
        for by in stride(from: 0, to: height, by: block) {
            for bx in stride(from: 0, to: width, by: block) {
                var total = 0
                for y in by ..< min(by + block, height) {
                    for x in bx ..< min(bx + block, width) {
                        let i = (y * width + x) * 4
                        total += abs(Int(a[i]) - Int(b[i])) + abs(Int(a[i + 1]) - Int(b[i + 1])) + abs(Int(a[i + 2]) - Int(b[i + 2]))
                    }
                }
                worst = max(worst, total)
            }
        }
        return Double(worst) / Double(block * block * 3) / 255
    }
}
