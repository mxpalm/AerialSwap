import Foundation

/// A scene's `scene.json` with its layers' models, materials and effects loaded, and every property binding resolved
/// against the chosen property values. Anything the renderer can't draw is kept as a kind of its own, so
/// `SceneAnalysis` can say what a video would leave out.
public struct SceneDocument: Sendable {
    public struct General: Sendable {
        public var clearColor: SIMD3<Float> = [0, 0, 0]
        public var clearEnabled = true
        /// The scene's canvas in scene units (usually the author's screen size).
        public var width: Double = 1920
        public var height: Double = 1080
        public var bloom = false
        public var bloomStrength: Double = 2
        public var bloomThreshold: Double = 0.65
        public var cameraParallax = false
        public var cameraShake = false
        public var hdr = false
        /// The camera looks at a 3D scene instead of the flat canvas.
        public var perspectiveCamera = false
    }

    public struct Transform: Sendable, Equatable {
        public var origin: SIMD3<Double> = .zero
        public var scale: SIMD3<Double> = .one
        /// Euler angles in radians; layers use z.
        public var angles: SIMD3<Double> = .zero
        public var parallaxDepth: SIMD2<Double> = .one
    }

    public struct Object: Sendable {
        public let id: Int
        public let name: String
        public let parent: Int?
        public let transform: Transform
        public let visible: Bool
        public let kind: Kind
    }

    public enum Kind: Sendable {
        case image(ImageLayer)
        case particle(ParticleLayer)
        /// A transform-only object other objects hang from.
        case group
        case text
        case sound
        case model3D
        case light
        case unknown
    }

    public struct ImageLayer: Sendable {
        public let modelPath: String
        public let model: Model
        public let size: SIMD2<Double>?
        public let alignment: String
        public let alpha: Double
        public let color: SIMD3<Double>
        public let brightness: Double
        public let colorBlendMode: Int
        /// The layer draws the scene behind it through its effects (a "copy background" layer).
        public let copyBackground: Bool
        public let pointFilter: Bool
        public let clampUVs: Bool
        public let effects: [Effect]
        /// Material passes with the layer's own overrides (`instance` overrides on the image).
        public let material: Material
        /// A text layer's text: the renderer draws it as the layer's texture (`textTexture`).
        public var text: SceneText? = nil
        /// A puppet-warp layer's mesh and the animations it plays (`animationlayers`); nil when the model has none or
        /// its file can't be read.
        public var puppet: ScenePuppet? = nil
        public var puppetAnimations: [ScenePuppet.Layer] = []

        /// The texture name a text layer's material reads.
        static func textTexture(_ id: Int) -> String { "__text/\(id)" }
    }

    public struct ParticleLayer: Sendable {
        public let path: String
        /// The particle system's definition; the renderer reads its emitters, initializers and operators.
        public let definition: SceneJSON
        /// Per-instance changes the scene makes to the system (rate, alpha, color, size, count…).
        public let instanceOverride: [String: SceneJSON]
    }

    /// `models/x.json`: what an image layer draws.
    public struct Model: Sendable {
        public let materialPath: String?
        public let width: Double?
        public let height: Double?
        public let fullscreen: Bool
        public let autosize: Bool
        public let passthrough: Bool
        public let solidLayer: Bool
        /// A puppet-warp skeleton (`.mdl`), animated by bones.
        public let puppet: String?
        /// The layer shows the scene behind it (AerialSwap's utility models: compose, fullscreen and project layers).
        public let compose: Bool
    }

    public struct Material: Sendable {
        public var passes: [MaterialPass]

        init(passes: [MaterialPass]) { self.passes = passes }

        /// A material file's passes (bindings already resolved).
        init(json: SceneJSON) {
            passes = (json["passes"]?.array ?? []).prefix(SceneLimits.maxPasses).map { p in
                MaterialPass(
                    shader: p["shader"]?.string ?? "genericimage2", blending: p["blending"]?.string ?? "normal",
                    textures: (p["textures"]?.array ?? []).map(\.string),
                    combos: (p["combos"]?.object ?? [:]).compactMapValues { $0.number.map { Int($0) } },
                    constants: p["constantshadervalues"]?.object ?? [:], userTextures: p["usertextures"]?.object ?? [:])
            }
        }
    }

    public struct MaterialPass: Sendable {
        /// `genericimage2`, `effects/waterwaves`… → shaders/<shader>.vert and .frag.
        public var shader: String
        public var blending: String
        /// Texture slots; nil leaves the slot to the effect chain (slot 0 is usually the previous result).
        public var textures: [String?]
        public var combos: [String: Int]
        /// Material values (`speed`, `strength`…) keyed by the material name shader annotations refer to.
        public var constants: [String: SceneJSON]
        public var userTextures: [String: SceneJSON]
    }

    public struct Effect: Sendable {
        /// Position in the object's effect list in scene.json (scripts address effects by it).
        public let index: Int
        public let file: String
        public let name: String
        public let visible: Bool
        public let passes: [EffectPass]
        /// Offscreen buffers the effect's passes draw into.
        public let buffers: [Buffer]
    }

    public struct EffectPass: Sendable {
        public let materialPath: String?
        public var material: Material?
        /// The buffer this pass draws into (nil: the layer's ping-pong target).
        public let target: String?
        /// Buffers bound to texture slots: (buffer name or "previous", slot).
        public let binds: [(name: String, index: Int)]
        /// "copy" or "swap" passes move buffers instead of drawing.
        public let command: String?
        public let source: String?
        /// Which of the effect instance's pass overrides applies (passes with a material count, in order).
        public let instance: Int?
    }

    /// A SceneScript: JavaScript that computes one of an object's values every frame (see SceneScripts).
    public struct Script: Sendable {
        public let object: Int
        /// Where the value is below the object: "origin", "effects/0/visible",
        /// "effects/0/passes/1/constantshadervalues/strength".
        public let path: String
        public let source: String
        /// The saved value, used until the script changes it.
        public let value: SceneJSON
        /// The script's own settings (`scriptproperties`), with property bindings resolved.
        public let properties: [String: SceneJSON]
    }

    public struct Buffer: Sendable {
        public let name: String
        /// Divider of the layer's size (2 = half resolution).
        public let scale: Double
        public let format: String
    }

    public let project: SceneProject
    public let general: General
    public let objects: [Object]
    /// The property values bindings were resolved with.
    public let properties: [String: SceneJSON]
    /// Files the scene names that neither the wallpaper nor AerialSwap's core has.
    public let missingFiles: Set<String>
    /// Values a SceneScript computes (`{"script": …, "value": …}`), in scene order.
    public let scripts: [Script]

    /// Loads `project.file` (normally scene.json) and everything it references. `overrides` replace the project's
    /// property values (the user's choices in AerialSwap).
    public init(files: SceneFiles, project: SceneProject, overrides: [String: SceneJSON] = [:]) throws {
        self.project = project
        let properties = project.values.merging(overrides) { _, new in new }
        self.properties = properties
        let raw = try files.json(project.file)
        let scene = raw.resolvedDeep(properties)
        // Scripts first: values bound to them read as their saved value below, so text needs them to tell clocks.
        let scripts = try Self.scripts(in: raw["objects"]?.array ?? [], properties: properties)
        var loader = Loader(files: files, properties: properties,
                            liveText: Set(scripts.filter { $0.path == "text" && SceneText.isLive($0.source) }.map(\.object)))

        var general = General()
        if let g = scene["general"] {
            if let c = g["clearcolor"]?.vector, c.count >= 3 { general.clearColor = SIMD3(Float(c[0]), Float(c[1]), Float(c[2])) }
            general.clearEnabled = g["clearenabled"]?.bool ?? true
            // A 3D scene has `"orthogonalprojection": null`; without the key the canvas keeps its default size.
            if let ortho = g["orthogonalprojection"] {
                if ortho.object == nil {
                    general.perspectiveCamera = true
                } else {
                    general.width = Self.bounded(ortho["width"]?.number, default: 1920)
                    general.height = Self.bounded(ortho["height"]?.number, default: 1080)
                }
            }
            general.bloom = g["bloom"]?.bool ?? false
            general.bloomStrength = g["bloomstrength"]?.number ?? 2
            general.bloomThreshold = g["bloomthreshold"]?.number ?? 0.65
            general.cameraParallax = g["cameraparallax"]?.bool ?? false
            general.cameraShake = g["camerashake"]?.bool ?? false
            general.hdr = g["hdr"]?.bool ?? false
        }
        self.general = general

        let list = scene["objects"]?.array ?? []
        guard list.count <= SceneLimits.maxObjects else { throw SceneError.tooLarge("The scene's object list") }
        objects = list.compactMap { loader.object($0) }
        missingFiles = loader.missing
        self.scripts = scripts
    }

    /// The scripts in the objects' values, with where each value is.
    private static func scripts(in objects: [SceneJSON], properties: [String: SceneJSON]) throws -> [Script] {
        var scripts: [Script] = []
        func walk(_ value: SceneJSON, object: Int, path: [String], depth: Int) throws {
            guard depth < SceneLimits.maxJSONDepth else { return }
            switch value {
            case .object(let dictionary):
                if let source = dictionary["script"]?.string {
                    guard scripts.count < SceneLimits.maxScripts, source.utf8.count <= SceneLimits.maxScriptBytes else {
                        throw SceneError.tooLarge("The scene's scripts")
                    }
                    scripts.append(Script(object: object, path: path.joined(separator: "/"), source: source,
                                          value: (dictionary["value"] ?? .null).resolvedDeep(properties),
                                          properties: dictionary["scriptproperties"]?.resolvedDeep(properties).object ?? [:]))
                    return
                }
                for key in dictionary.keys.sorted() {
                    try walk(dictionary[key]!, object: object, path: path + [key], depth: depth + 1)
                }
            case .array(let array):
                for (index, element) in array.enumerated() {
                    try walk(element, object: object, path: path + [String(index)], depth: depth + 1)
                }
            default:
                break
            }
        }
        for object in objects {
            guard let id = object["id"]?.number else { continue }
            try walk(object, object: Int(id), path: [], depth: 0)
        }
        return scripts
    }

    static func bounded(_ value: Double?, default fallback: Double, range: ClosedRange<Double> = 1 ... 65_536) -> Double {
        guard let value, value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// Reads the files objects reference, remembering what's missing instead of failing the whole scene.
    private struct Loader {
        let files: SceneFiles
        let properties: [String: SceneJSON]
        /// Text objects whose script makes live text (clocks, now playing; see SceneText.isLive).
        let liveText: Set<Int>
        var missing: Set<String> = []

        mutating func json(_ path: String) -> SceneJSON? {
            guard let json = try? files.json(path) else {
                missing.insert(SceneFiles.normalized(path))
                return nil
            }
            return json.resolvedDeep(properties)
        }

        mutating func object(_ o: SceneJSON) -> Object? {
            guard o.object != nil else { return nil }
            let id = Int(o["id"]?.number ?? -1)
            let kind: Kind
            if let image = o["image"]?.string {
                kind = imageLayer(o, modelPath: image).map(Kind.image) ?? .unknown
            } else if let particle = o["particle"]?.string {
                kind = json(particle).map {
                    .particle(ParticleLayer(path: particle, definition: $0, instanceOverride: o["instanceoverride"]?.object ?? [:]))
                } ?? .unknown
            } else if let text = o["text"] {
                // Clocks (and text that can't be drawn) stay text objects, which aren't drawn.
                kind = textLayer(o, text: text, id: id).map(Kind.image) ?? .text
            } else if o["sound"] != nil {
                kind = .sound
            } else if o["model"] != nil {
                kind = .model3D
            } else if o["light"] != nil {
                kind = .light
            } else {
                kind = .group
            }
            return Object(id: id, name: o["name"]?.string ?? "", parent: o["parent"]?.number.map { Int($0) },
                          transform: transform(o), visible: o["visible"]?.bool ?? true, kind: kind)
        }

        func transform(_ o: SceneJSON) -> Transform {
            var t = Transform()
            if let v = o["origin"]?.vector, v.count >= 2 { t.origin = SIMD3(v[0], v[1], v.count > 2 ? v[2] : 0) }
            if let v = o["scale"]?.vector, v.count >= 2 { t.scale = SIMD3(v[0], v[1], v.count > 2 ? v[2] : 1) }
            if let v = o["angles"]?.vector, v.count >= 3 { t.angles = SIMD3(v[0], v[1], v[2]) }
            if let v = o["parallaxDepth"]?.vector, v.count >= 2 { t.parallaxDepth = SIMD2(v[0], v[1]) }
            return t
        }

        mutating func imageLayer(_ o: SceneJSON, modelPath: String) -> ImageLayer? {
            guard let m = json(modelPath) else { return nil }
            let model = Model(
                materialPath: m["material"]?.string, width: m["width"]?.number, height: m["height"]?.number,
                fullscreen: m["fullscreen"]?.bool ?? false, autosize: m["autosize"]?.bool ?? false,
                passthrough: m["passthrough"]?.bool ?? false, solidLayer: m["solidlayer"]?.bool ?? false,
                puppet: m["puppet"]?.string, compose: m["aerialswap"]?.string == "compose")
            var material = model.materialPath.flatMap { self.material($0) } ?? Material(passes: [])
            // The image's own "instance" overrides apply to its material's first pass.
            if let instance = o["instance"], !material.passes.isEmpty { Self.apply(instance, to: &material.passes[0]) }
            let effects = (o["effects"]?.array ?? []).prefix(SceneLimits.maxEffects).enumerated().compactMap { effect($1, index: $0) }
            let size = o["size"]?.vector.flatMap { $0.count >= 2 ? SIMD2($0[0], $0[1]) : nil }
            let color = o["color"]?.vector.flatMap { $0.count >= 3 ? SIMD3($0[0], $0[1], $0[2]) : nil } ?? .one
            var layer = ImageLayer(
                modelPath: modelPath, model: model, size: size, alignment: o["alignment"]?.string ?? "center",
                alpha: o["alpha"]?.number ?? 1, color: color, brightness: o["brightness"]?.number ?? 1,
                colorBlendMode: Int(o["colorBlendMode"]?.number ?? 0), copyBackground: o["copybackground"]?.bool ?? false,
                pointFilter: o["nointerpolation"]?.bool ?? false, clampUVs: o["clampuvs"]?.bool ?? false,
                effects: Array(effects), material: material)
            if let path = model.puppet {
                if let data = files.data(path), data.count <= SceneLimits.maxPuppetBytes {
                    layer.puppet = try? ScenePuppet(data: data, name: path)
                } else {
                    missing.insert(SceneFiles.normalized(path))
                }
                layer.puppetAnimations = (o["animationlayers"]?.array ?? []).prefix(16).compactMap { a in
                    guard let id = a["animation"]?.number else { return nil }
                    let rate = a["rate"]?.number ?? 1, blend = a["blend"]?.number ?? 1
                    return ScenePuppet.Layer(animation: Int(id), rate: rate.isFinite ? rate : 1, blend: blend.isFinite ? blend : 1,
                                             additive: a["additive"]?.bool ?? false, visible: a["visible"]?.bool ?? true)
                }
            }
            return layer
        }

        /// A text object as an image layer showing its text: static text, and scripted text that isn't live (its saved
        /// value is shown). nil for live text.
        mutating func textLayer(_ o: SceneJSON, text: SceneJSON, id: Int) -> ImageLayer? {
            guard !liveText.contains(id), let string = text.string else { return nil }
            func value(_ key: String) -> SceneJSON? { o[key] }
            let effects = (o["effects"]?.array ?? []).prefix(SceneLimits.maxEffects).enumerated().compactMap { effect($1, index: $0) }
            let color = value("color")?.vector.flatMap { $0.count >= 3 ? SIMD3($0[0], $0[1], $0[2]) : nil } ?? .one
            let opaque = value("opaquebackground")?.bool ?? false
            let background = value("backgroundcolor")?.vector.flatMap { $0.count >= 3 ? SIMD3($0[0], $0[1], $0[2]) : nil }
                .map { $0 * (value("backgroundbrightness")?.number ?? 1) }
            let horizontal = (value("horizontalalign")?.string ?? "center").lowercased()
            let vertical = (value("verticalalign")?.string ?? "center").lowercased()
            let spec = SceneText(
                string: string, font: value("font")?.string ?? "systemfont_arial",
                pointSize: value("pointsize")?.number ?? 32, padding: effects.isEmpty ? 0 : value("padding")?.number ?? 32,
                alignment: horizontal, maxWidth: value("limitwidth")?.bool == true ? value("maxwidth")?.number : nil,
                maxRows: value("limitrows")?.bool == true ? value("maxrows")?.number.map { max(1, Int($0)) } : nil,
                ellipsis: value("limituseellipsis")?.bool ?? false, background: opaque ? background ?? .zero : nil, color: color)
            let pass = MaterialPass(shader: "genericimage2", blending: "translucent", textures: [ImageLayer.textTexture(id)],
                                    combos: [:], constants: [:], userTextures: [:])
            let model = Model(materialPath: nil, width: nil, height: nil, fullscreen: false, autosize: false, passthrough: false,
                              solidLayer: false, puppet: nil, compose: false)
            // The origin is where the block is anchored: its left edge for left-aligned text, its top for top-aligned.
            let alignment = "\(vertical == "top" || vertical == "bottom" ? vertical : "") \(horizontal == "left" || horizontal == "right" ? horizontal : "")"
            return ImageLayer(
                modelPath: "", model: model, size: nil, alignment: alignment.trimmingCharacters(in: .whitespaces).isEmpty ? "center" : alignment,
                alpha: value("alpha")?.number ?? 1, color: opaque ? .one : color, brightness: value("brightness")?.number ?? 1,
                colorBlendMode: 0, copyBackground: false, pointFilter: false, clampUVs: true,
                effects: Array(effects), material: Material(passes: [pass]), text: spec)
        }

        mutating func material(_ path: String) -> Material? {
            json(path).map(Material.init(json:))
        }

        /// Overrides an effect instance or image instance makes on a material pass.
        static func apply(_ override: SceneJSON, to pass: inout MaterialPass) {
            for (key, value) in override["constantshadervalues"]?.object ?? [:] { pass.constants[key] = value }
            for (key, value) in override["combos"]?.object ?? [:] { if let n = value.number { pass.combos[key] = Int(n) } }
            for (index, texture) in (override["textures"]?.array ?? []).enumerated() where texture != .null {
                while pass.textures.count <= index { pass.textures.append(nil) }
                pass.textures[index] = texture.string
            }
            for (key, value) in override["usertextures"]?.object ?? [:] { pass.userTextures[key] = value }
        }

        mutating func effect(_ e: SceneJSON, index: Int) -> Effect? {
            guard let file = e["file"]?.string, let json = json(file) else { return nil }
            let overrides = e["passes"]?.array ?? []
            var materialIndex = 0
            let passes: [EffectPass] = (json["passes"]?.array ?? []).prefix(SceneLimits.maxPasses).map { p in
                let materialPath = p["material"]?.string
                var material = materialPath.flatMap { self.material($0) }
                // Instance overrides follow the effect's material passes in order.
                var instance: Int?
                if materialPath != nil {
                    if materialIndex < overrides.count, material?.passes.isEmpty == false {
                        Self.apply(overrides[materialIndex], to: &material!.passes[0])
                    }
                    instance = materialIndex
                    materialIndex += 1
                }
                let binds = (p["bind"]?.array ?? []).compactMap { b -> (String, Int)? in
                    guard let name = b["name"]?.string, let index = b["index"]?.number, (0 ... 15).contains(index) else { return nil }
                    return (name, Int(index))
                }
                return EffectPass(materialPath: materialPath, material: material, target: p["target"]?.string,
                                  binds: binds, command: p["command"]?.string, source: p["source"]?.string, instance: instance)
            }
            let buffers = (json["fbos"]?.array ?? []).compactMap { f -> Buffer? in
                guard let name = f["name"]?.string else { return nil }
                return Buffer(name: name, scale: SceneDocument.bounded(f["scale"]?.number, default: 1, range: 1 ... 64),
                              format: f["format"]?.string ?? "rgba8888")
            }
            return Effect(index: index, file: file, name: json["name"]?.string ?? e["name"]?.string ?? "", visible: e["visible"]?.bool ?? true,
                          passes: passes, buffers: buffers)
        }
    }
}

extension SceneJSON {
    /// The value with every property binding inside it resolved, all the way down.
    func resolvedDeep(_ properties: [String: SceneJSON]) -> SceneJSON {
        let value = resolved(properties)
        switch value {
        case .object(let dictionary) where value.userBinding == nil:
            return .object(dictionary.mapValues { $0.resolvedDeep(properties) })
        case .array(let array):
            return .array(array.map { $0.resolvedDeep(properties) })
        default:
            return value
        }
    }
}
