import Foundation
import simd
import Testing
@testable import SceneEngine

struct ScenePuppetTests {
    @Test func rejectsGarbage() {
        #expect(throws: SceneError.self) { try ScenePuppet(data: Data("MDLV0023\0".utf8), name: "x.mdl") }
        #expect(throws: SceneError.self) { try ScenePuppet(data: Data(repeating: 0xFF, count: 64), name: "x.mdl") }
    }

    /// Puppets from a downloaded wallpaper (SCENE_PUPPET_DIR): they parse, and frame 0 leaves the mesh at rest.
    @Test func localPuppets() throws {
        guard let dir = ProcessInfo.processInfo.environment["SCENE_PUPPET_DIR"] else { return }
        let files = try FileManager.default.contentsOfDirectory(at: URL(filePath: dir), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "mdl" }
        #expect(!files.isEmpty)
        for file in files {
            let puppet = try ScenePuppet(data: Data(contentsOf: file), name: file.lastPathComponent)
            #expect(!puppet.vertices.isEmpty && !puppet.animations.isEmpty)
            let layers = puppet.animations.prefix(1).map { ScenePuppet.Layer(animation: $0.id, rate: 1, blend: 1, additive: false, visible: true) }
            let moved = puppet.positions(layers: layers, time: 0)
            let error = zip(moved, puppet.vertices).map { simd_length($0 - $1.position) }.max() ?? 0
            #expect(error < 0.5, "\(file.lastPathComponent): \(error)")
        }
    }
}
