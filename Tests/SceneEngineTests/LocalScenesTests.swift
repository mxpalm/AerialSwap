import Foundation
import Testing
@testable import SceneEngine

/// Loads every scene Steam has downloaded on this Mac (none are in the repository: they're other people's work).
/// Skipped when there are none.
@Suite struct LocalScenesTests {
    static let workshop = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Steam/steamapps/workshop/content/431960")

    static var scenes: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: workshop, includingPropertiesForKeys: nil)) ?? [])
            .filter { (try? SceneProject(folder: $0))?.kind == .scene }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    @Test(.enabled(if: !scenes.isEmpty), arguments: scenes)
    func sceneLoads(_ folder: URL) throws {
        let project = try SceneProject(folder: folder)
        let files = try SceneFiles(folder: folder, entry: project.file)
        let document = try SceneDocument(files: files, project: project)
        let analysis = SceneAnalysis(document, files: files)

        // Every texture an image layer names must read (textures live in materials/<name>.tex).
        var textures = 0
        for object in document.objects {
            guard case .image(let layer) = object.kind else { continue }
            let passes = layer.material.passes + layer.effects.flatMap { $0.passes.compactMap(\.material).flatMap(\.passes) }
            for name in passes.flatMap(\.textures).compactMap({ $0 }) where !name.hasPrefix("_rt_") {
                let path = "materials/\(name).tex"
                guard let data = files.data(path) else { continue }
                _ = try SceneTexture(data: data, name: path)
                textures += 1
            }
        }
        print("\(folder.lastPathComponent) “\(project.title)”: \(document.objects.count) objects, \(textures) textures, "
              + "missing \(document.missingFiles.sorted()), blockers \(analysis.blockers), left out \(analysis.leftOut)")
    }
}

import Metal

/// Every shader pass the local scenes use, translated and compiled through to a Metal library.
@Suite struct LocalShadersTests {
    @Test(.enabled(if: !LocalScenesTests.scenes.isEmpty)) func shadersCompile() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var ok = 0
        var failures: [String] = []
        for folder in LocalScenesTests.scenes {
            let project = try SceneProject(folder: folder)
            let files = try SceneFiles(folder: folder, entry: project.file)
            let document = try SceneDocument(files: files, project: project)
            var seen = Set<String>()
            for object in document.objects {
                guard case .image(let layer) = object.kind else { continue }
                let passes = layer.material.passes + layer.effects.flatMap { $0.passes.compactMap(\.material).flatMap(\.passes) }
                for pass in passes {
                    let key = pass.shader + pass.combos.sorted { $0.key < $1.key }.description
                    guard seen.insert(key).inserted else { continue }
                    do {
                        let source = try ShaderTranslator.sources(pass.shader, files: files)
                        let translated = ShaderTranslator.translate(vertex: source.vertex, fragment: source.fragment, combos: pass.combos)
                        if let dir = ProcessInfo.processInfo.environment["SCENE_SHADER_DUMP"] {
                            let base = URL(fileURLWithPath: dir).appending(path: folder.lastPathComponent + "_" + pass.shader.replacingOccurrences(of: "/", with: "_"))
                            try? translated.vertex.write(to: base.appendingPathExtension("vert"), atomically: true, encoding: .utf8)
                            try? translated.fragment.write(to: base.appendingPathExtension("frag"), atomically: true, encoding: .utf8)
                        }
                        for (text, stage) in [(translated.vertex, ShaderStage.vertex), (translated.fragment, .fragment)] {
                            do {
                                let metal = try ShaderTranslator.compile(text, stage: stage)
                                _ = try device.makeLibrary(source: metal.source, options: nil)
                            } catch let error as ShaderCompileError {
                                // Show the lines the log points at.
                                let lines = text.components(separatedBy: "\n")
                                let numbers = ShaderTranslator.matches(#"ERROR: \d+:(\d+):"#, in: error.description).compactMap { Int($0[1]) }
                                let context = Set(numbers).sorted().prefix(3).map { n in "[\(n)] " + (n <= lines.count ? lines[n - 1].trimmingCharacters(in: .whitespaces) : "") }
                                throw ShaderCompileError(description: "\(stage) " + error.description.prefix(160) + " >> " + context.joined(separator: " >> "))
                            }
                        }
                        ok += 1
                    } catch {
                        failures.append("\(folder.lastPathComponent) \(pass.shader): \(String(describing: error).prefix(300))")
                    }
                }
            }
        }
        print("shaders: \(ok) ok, \(failures.count) failed")
        for f in failures { print("  " + f.replacingOccurrences(of: "\n", with: " | ")) }
    }
}
