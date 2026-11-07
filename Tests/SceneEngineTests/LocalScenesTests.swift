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
