import Foundation
import JavaScriptCore

/// An object's values in one frame, as the scene's scripts left them.
struct ObjectState {
    var transform: SceneDocument.Transform
    var visible: Bool
    var alpha: Double
    var color: SIMD3<Double>
    var brightness: Double
    /// By the effect's index in the object's list (`Effect.index`).
    var effectsVisible: [Bool]
    /// Other scripted values by path, like "effects/0/passes/1/constantshadervalues/strength".
    var values: [String: SceneJSON]
}

/// Runs a scene's SceneScripts (JavaScript that sets values every frame, see SceneScriptRuntime) with JavaScriptCore,
/// on a fixed 60 Hz tick. The scene keeps its own time: the time of day stays fixed, the clock and random numbers follow
/// scene time, and the cursor rests at the canvas center, so a time always gives the same values (a loop's two passes
/// must agree). Scripts run for `warmUp` seconds before time 0, so transitions they start with are over when the frames
/// begin. They get no file, network or system access; one that throws stops, and its value stays as it was.
final class SceneScripts {
    static let tick = 1.0 / 60
    static let warmUp = 5.0

    private let configuration: [String: Any]
    private let wrapped: [String]
    private var context: JSContext?
    private var host: JSValue?
    private var ticks = 0
    private var failures: [String] = []

    /// What went wrong: scripts that threw, API they use that isn't there.
    private(set) var problems: Set<String> = []

    /// `screen` is the output size in pixels; `clockStart` is what the scene's clock shows at time 0.
    init(document: SceneDocument, screen: SIMD2<Int>, timeOfDay: Double, clockStart: Date) {
        let objects = document.objects.map { object -> [String: Any] in
            let t = object.transform
            var entry: [String: Any] = [
                "id": object.id, "name": object.name, "parent": object.parent.map { $0 as Any } ?? NSNull(),
                "origin": [t.origin.x, t.origin.y, t.origin.z], "scale": [t.scale.x, t.scale.y, t.scale.z],
                "angles": [t.angles.x, t.angles.y, t.angles.z], "parallaxDepth": [t.parallaxDepth.x, t.parallaxDepth.y],
                "visible": object.visible, "alpha": 1.0, "color": [1.0, 1.0, 1.0], "brightness": 1.0,
                "size": [0.0, 0.0], "effects": [Any](),
            ]
            if case .image(let image) = object.kind {
                entry["alpha"] = image.alpha
                entry["color"] = [image.color.x, image.color.y, image.color.z]
                entry["brightness"] = image.brightness
                let size = image.size ?? SIMD2(image.model.width ?? 0, image.model.height ?? 0)
                entry["size"] = [size.x, size.y]
                // By index in the scene's list; effects that didn't load stay hidden.
                var effects = [[String: Any]](repeating: ["name": "", "visible": false], count: (image.effects.map(\.index).max() ?? -1) + 1)
                for effect in image.effects { effects[effect.index] = ["name": effect.name, "visible": effect.visible] }
                entry["effects"] = effects
            }
            return entry
        }
        configuration = [
            "tick": Self.tick, "warmUp": Self.warmUp, "timeOfDay": timeOfDay,
            "clockStart": clockStart.timeIntervalSince1970 * 1000,
            "canvas": [document.general.width, document.general.height], "screen": [screen.x, screen.y],
            "userProperties": document.properties.mapValues(\.foundation),
            "objects": objects,
            "scripts": document.scripts.map {
                ["object": $0.object, "path": $0.path, "value": $0.value.foundation,
                 "properties": $0.properties.mapValues(\.foundation)] as [String: Any]
            },
        ]
        wrapped = document.scripts.map { Self.wrap($0.source) }
    }

    /// Runs the scripts up to scene time `time` (starting over when it lies before the last one) and returns every
    /// object's values, by id.
    func advance(to time: Double) -> [Int: ObjectState] {
        let target = max(0, Int(((time + Self.warmUp) / Self.tick + 1e-6).rounded(.down)))
        if host == nil || target < ticks { start() }
        guard let host else { return [:] }
        if target > ticks {
            host.invokeMethod("run", withArguments: [target - ticks])
            ticks = target
        }
        let state = host.invokeMethod("state", withArguments: [])?.toString() ?? "[]"
        collectProblems()
        return Self.states(from: state)
    }

    /// A fresh context with every script loaded and initialized.
    private func start() {
        host = nil
        ticks = 0
        guard let context = JSContext() else { return }
        context.name = "AerialSwap scene scripts"
        context.exceptionHandler = { [weak self] _, exception in
            self?.failures.append(exception?.toString() ?? "unknown error")
        }
        self.context = context
        context.evaluateScript(SceneScriptRuntime.source)
        guard let host = context.objectForKeyedSubscript("__host"), !host.isUndefined else {
            problems.insert("The script runtime didn't start: \(failures.first ?? "unknown error")")
            return
        }
        host.invokeMethod("setup", withArguments: [configuration])
        for (index, source) in wrapped.enumerated() {
            failures = []
            let factory = context.evaluateScript(source, withSourceURL: URL(string: "scene-script:///\(index)"))
            if let error = failures.first {
                let script = (configuration["scripts"] as? [[String: Any]])?[index]
                problems.insert("Script \(script?["path"] ?? index) doesn't run: \(error)")
                continue
            }
            host.invokeMethod("load", withArguments: [index, factory as Any])
        }
        host.invokeMethod("start", withArguments: [])
        self.host = host
        collectProblems()
    }

    private func collectProblems() {
        for problem in host?.invokeMethod("problems", withArguments: [])?.toArray() ?? [] { problems.insert("\(problem)") }
        for failure in failures { problems.insert("Scripts stopped: \(failure)") }
        failures = []
    }

    /// The script as a function of the values Wallpaper Engine gives each script, returning what it exports. Scripts
    /// are ES modules; JavaScriptCore runs them as plain functions once their imports and exports are rewritten.
    static func wrap(_ source: String) -> String {
        var body = source
        body = replacing(#"(?m)^[ \t]*import\s+\*\s+as\s+([A-Za-z_$][\w$]*)\s+from\s+['"]([\w./-]+)['"][ \t]*;?"#, in: body) {
            "const \($0[1]) = __host.module('\($0[2])');"
        }
        body = replacing(#"(?m)^[ \t]*import\s*\{([^}]*)\}\s*from\s+['"]([\w./-]+)['"][ \t]*;?"#, in: body) {
            "const {\($0[1].replacingOccurrences(of: " as ", with: ": "))} = __host.module('\($0[2])');"
        }
        var exports: [String] = []
        body = replacing(#"\bexport\s+(?:default\s+)?(async\s+function\*?|function\*?|var|let|const|class)\s+([A-Za-z_$][\w$]*)"#, in: body) {
            exports.append($0[2])
            return "\($0[1]) \($0[2])"
        }
        body = replacing(#"\bexport\s*\{([^}]*)\}[ \t]*;?"#, in: body) {
            exports += $0[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            return ""
        }
        let names = exports.filter { $0.range(of: #"^[A-Za-z_$][\w$]*$"#, options: .regularExpression) != nil }
        let result = Set(names).sorted().map { "\($0): typeof \($0) === 'undefined' ? undefined : \($0)" }.joined(separator: ", ")
        return "(function (thisLayer, thisObject, createScriptProperties) {\n\(body)\n;return { \(result) };\n})"
    }

    private static func replacing(_ pattern: String, in text: String, with make: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var result = "", last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let groups = (0 ..< match.numberOfRanges).map { i -> String in
                let range = match.range(at: i)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
            result += make(groups)
            last = match.range.location + match.range.length
        }
        return result + ns.substring(from: last)
    }

    private static func states(from json: String) -> [Int: ObjectState] {
        guard let list = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]] else { return [:] }
        func vector3(_ value: Any?, _ fallback: SIMD3<Double>) -> SIMD3<Double> {
            guard let a = value as? [Double], a.count >= 3 else { return fallback }
            return SIMD3(a[0], a[1], a[2])
        }
        var states: [Int: ObjectState] = [:]
        for entry in list {
            guard let id = entry["id"] as? Int else { continue }
            var transform = SceneDocument.Transform()
            transform.origin = vector3(entry["origin"], .zero)
            transform.scale = vector3(entry["scale"], .one)
            transform.angles = vector3(entry["angles"], .zero)
            states[id] = ObjectState(
                transform: transform, visible: entry["visible"] as? Bool ?? true, alpha: entry["alpha"] as? Double ?? 1,
                color: vector3(entry["color"], .one), brightness: entry["brightness"] as? Double ?? 1,
                effectsVisible: entry["effects"] as? [Bool] ?? [],
                values: (entry["values"] as? [String: Any] ?? [:]).compactMapValues(SceneJSON.init(foundation:)))
        }
        return states
    }
}

extension SceneJSON {
    /// The value as Foundation objects (what JavaScriptCore and JSONSerialization take).
    public var foundation: Any {
        switch self {
        case .null: NSNull()
        case .bool(let b): b
        case .number(let n): n
        case .string(let s): s
        case .array(let a): a.map(\.foundation)
        case .object(let o): o.mapValues(\.foundation)
        }
    }

    /// A number, string, boolean or array of numbers from JSONSerialization.
    public init?(foundation value: Any) {
        switch value {
        case let number as NSNumber:
            self = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        case let string as String: self = .string(string)
        case let array as [Any]: self = .array(array.compactMap(SceneJSON.init(foundation:)))
        default: return nil
        }
    }
}
