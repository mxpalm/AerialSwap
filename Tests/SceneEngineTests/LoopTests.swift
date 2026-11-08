import Foundation
import Metal
import Testing
@testable import SceneEngine

/// Particle systems in a loop repeat bit for bit.
@Suite struct ParticleLoopTests {
    static let definition = try! SceneJSON(data: Data("""
        {
          "maxcount": 40, "starttime": 3,
          "emitter": [
            {"name": "sphererandom", "rate": 30, "distancemax": 200, "directions": "1 0.5 0"},
            {"name": "boxrandom", "rate": 7.3, "distancemax": "300 50 0", "origin": "0 400 0"}
          ],
          "initializer": [
            {"name": "lifetimerandom", "min": 1.5, "max": 4},
            {"name": "sizerandom", "min": 5, "max": 30},
            {"name": "velocityrandom", "min": "-50 -20 0", "max": "50 80 0"},
            {"name": "turbulentvelocityrandom", "speedmin": 10, "speedmax": 40, "scale": 0.5},
            {"name": "angularvelocityrandom", "min": "0 0 -2", "max": "0 0 2"}
          ],
          "operator": [
            {"name": "movement", "gravity": "0 -30 0", "drag": 0.2},
            {"name": "angularmovement"},
            {"name": "turbulence", "speedmin": 20, "speedmax": 60, "scale": 0.01, "timescale": 2},
            {"name": "oscillateposition", "frequencymax": 2, "scalemax": 10},
            {"name": "alphafade", "fadeintime": 0.2, "fadeouttime": 0.7},
            {"name": "sizechange", "endvalue": 0.3}
          ],
          "renderer": [{"name": "sprite"}]
        }
        """.utf8), name: "test")

    static func system() -> ParticleSystem {
        ParticleSystem(definition: definition, overrides: .init([:]), seed: 9) { _ in nil }
    }

    static func same(_ a: [ParticleSystem.Sprite], _ b: [ParticleSystem.Sprite]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.position == $1.position && $0.size == $1.size && $0.color == $1.color
            && $0.rotation == $1.rotation }
    }

    @Test func aLoopRepeatsExactly() {
        let system = Self.system()
        system.loop(every: 5)
        for time in [0.0, 1.3, 4.9] {
            system.advance(to: time)
            let first = system.sprites()
            system.advance(to: time + 5)
            #expect(!first.isEmpty)
            #expect(Self.same(first, system.sprites()), "at \(time)")
        }
        // Going back in a loop gives the same frame as going forward to it.
        system.advance(to: 1.3)
        let again = system.sprites()
        let fresh = Self.system()
        fresh.loop(every: 5)
        fresh.advance(to: 1.3)
        #expect(Self.same(again, fresh.sprites()))
    }

    @Test func aLoopKeepsTheCountNearMaxcount() {
        let system = Self.system()
        system.loop(every: 6)
        var counts: [Int] = []
        for i in 0 ..< 60 {
            system.advance(to: Double(i) * 0.1)
            counts.append(system.particles.count)
        }
        let mean = Double(counts.reduce(0, +)) / Double(counts.count)
        #expect(mean > 25 && mean < 55, "mean \(mean)")
    }

    @Test func runningFreelyIsRepeatable() {
        let a = Self.system(), b = Self.system()
        a.advance(to: 2)
        a.advance(to: 3.5)
        b.advance(to: 3.5)
        #expect(Self.same(a.sprites(), b.sprites()))
    }
}

/// Loops planned for the local scenes, and how their seams compare with ordinary frame-to-frame changes.
@Suite struct LocalLoopTests {
    @Test(.enabled(if: !LocalScenesTests.scenes.isEmpty), arguments: LocalScenesTests.scenes)
    func loopIsSeamless(_ folder: URL) throws {
        let project = try SceneProject(folder: folder)
        let files = try SceneFiles(folder: folder, entry: project.file)
        let document = try SceneDocument(files: files, project: project)
        let plan = try SceneLoop.plan(document: document, files: files)

        let width = 320, height = max(1, Int((320 * document.general.height / document.general.width).rounded()))
        let renderer = try SceneRenderer(document: document, files: files, width: width, height: height, bufferScale: 0.5)
        renderer.loop = plan.loop
        func frame(_ time: Double) throws -> [UInt8] {
            let texture = try renderer.render(time: time)
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            return bytes
        }
        func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
            var total = 0
            for i in stride(from: 0, to: a.count, by: 4) {
                total += abs(Int(a[i]) - Int(b[i])) + abs(Int(a[i + 1]) - Int(b[i + 1])) + abs(Int(a[i + 2]) - Int(b[i + 2]))
            }
            return Double(total) / Double(a.count / 4 * 3)
        }
        let dt = 1.0 / 30
        // The jump from the last frame to the first, against steps elsewhere in the loop.
        let seam = difference(try frame(plan.loop.period - dt), try frame(0))
        var steps: [Double] = []
        for start in [0.5, 3.0, plan.loop.period / 2, plan.loop.period - 1] {
            steps.append(difference(try frame(start), try frame(start + dt)))
        }
        let typical = steps.sorted()[steps.count / 2]
        print("\(folder.lastPathComponent) “\(project.title)”: period \(plan.loop.period) s, crossfade \(plan.loop.crossfade) s, "
              + "planned seam \(String(format: "%.2f", plan.seam * 255)), still \(plan.isStill), "
              + "seam step \(String(format: "%.2f", seam)), typical step \(String(format: "%.2f", typical))")
        #expect(seam <= max(typical * 3, 0.5))
    }
}
