import Foundation

/// What a video of a scene would show and leave out, for the import list ("works", "works without …", "not supported").
public struct SceneAnalysis: Sendable, Equatable {
    /// Reasons the scene can't be made into a video at all (it would look wrong).
    public let blockers: [String]
    /// Things the video leaves out, with how often they occur ("text and clocks": 3).
    public let leftOut: [String: Int]

    public var canRender: Bool { blockers.isEmpty }

    public init(_ document: SceneDocument, files: SceneFiles) {
        var blockers: Set<String> = []
        var leftOut: [String: Int] = [:]
        if document.general.perspectiveCamera { blockers.insert("a 3D camera") }
        for object in document.objects where object.visible {
            switch object.kind {
            case .image(let layer):
                if layer.model.puppet != nil && layer.puppet == nil { blockers.insert("puppet-warp animation it can't read") }
                for pass in Self.passes(of: layer) {
                    if !pass.userTextures.isEmpty { leftOut["pictures from your Mac (album art, slideshows)", default: 0] += 1 }
                    for stage in ["vert", "frag"] {
                        let source = files.text("shaders/\(pass.shader).\(stage)") ?? ""
                        if source.contains("g_AudioSpectrum") { leftOut["audio visualizers", default: 0] += 1 }
                    }
                }
            case .text: leftOut["clocks and now playing", default: 0] += 1   // other text is drawn (SceneDocument.textLayer)
            case .sound: leftOut["sound", default: 0] += 1
            case .model3D: leftOut["3D models", default: 0] += 1
            case .light: leftOut["lights", default: 0] += 1
            case .particle, .group, .unknown: break
            }
        }
        if document.general.cameraParallax { leftOut["mouse parallax", default: 0] += 1 }
        let missingShaders = document.missingFiles.filter { $0.hasPrefix("effects/") || $0.hasPrefix("shaders/") }
        if !missingShaders.isEmpty { leftOut["effects AerialSwap doesn't have", default: 0] += missingShaders.count }
        self.blockers = blockers.sorted()
        self.leftOut = leftOut
    }

    private static func passes(of layer: SceneDocument.ImageLayer) -> [SceneDocument.MaterialPass] {
        layer.material.passes + layer.effects.filter(\.visible).flatMap { $0.passes.compactMap(\.material).flatMap(\.passes) }
    }
}
