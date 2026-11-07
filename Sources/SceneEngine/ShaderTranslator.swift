import Foundation

/// What a scene shader's comments say about its inputs: which material value feeds each uniform, defaults, and the
/// combos (compile-time switches) it offers.
public struct ShaderAnnotations: Sendable {
    public struct Uniform: Sendable {
        /// The key in a material's `constantshadervalues` that sets this uniform.
        public let material: String?
        public let defaultValue: SceneJSON?
    }

    public struct TextureSlot: Sendable {
        public let material: String?
        /// A texture used when the material leaves the slot empty (`util/white`…).
        public let defaultTexture: String?
        /// A combo that's 1 when a texture is bound to the slot.
        public let combo: String?
    }

    /// Uniform name → annotation (samplers excluded).
    public var uniforms: [String: Uniform] = [:]
    /// g_TextureN slot → annotation.
    public var textures: [Int: TextureSlot] = [:]
    /// Combo name → default value, from `// [COMBO]` lines.
    public var combos: [String: Int] = [:]
}

/// A shader pair translated to GLSL 450 that glslang compiles: includes expanded, combos defined, `attribute`/
/// `varying`/`gl_FragColor` turned into explicit `in`/`out`, and a prelude with the helpers Wallpaper Engine's dialect
/// assumes (HLSL type names, `mul`, `saturate`, scalar-first overloads of built-ins…).
public struct TranslatedShader: Sendable {
    public let vertex: String
    public let fragment: String
    public let annotations: ShaderAnnotations
    /// Vertex attribute name → location.
    public let attributes: [String: Int]
}

public enum ShaderTranslator {
    /// Attribute locations the renderer feeds; other attributes get a location from 8 up and read as zero.
    public static let knownAttributes = ["a_Position": 0, "a_TexCoord": 1, "a_TexCoordVec4": 2, "a_Color": 3,
                                         "a_TexCoordVec4C1": 4, "a_TexCoordC2": 5, "a_Normal": 6]

    /// The raw sources of `shaders/<name>.vert` and `.frag` with includes expanded.
    public static func sources(_ name: String, files: SceneFiles) throws -> (vertex: String, fragment: String) {
        func load(_ ext: String) throws -> String {
            let path = "shaders/\(name).\(ext)"
            guard let text = files.text(path) else { throw SceneError.missing(path) }
            var total = 0
            return try expand(text, files: files, depth: 0, total: &total)
        }
        return (try load("vert"), try load("frag"))
    }

    public static func annotations(vertex: String, fragment: String) -> ShaderAnnotations {
        var result = ShaderAnnotations()
        for line in (vertex + "\n" + fragment).split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(line)
            if let range = line.range(of: "[COMBO]") {
                if let json = json(String(line[range.upperBound...])), let combo = json["combo"]?.string {
                    result.combos[combo.uppercased()] = Int(json["default"]?.number ?? 0)
                }
                continue
            }
            guard let declaration = uniformDeclaration(line) else { continue }
            let annotation = line.range(of: "//").flatMap { json(String(line[$0.upperBound...])) }
            if declaration.type.hasPrefix("sampler") {
                guard declaration.name.hasPrefix("g_Texture"), let slot = Int(declaration.name.dropFirst(9)) else { continue }
                result.textures[slot] = .init(material: annotation?["material"]?.string,
                                              defaultTexture: annotation?["default"]?.string,
                                              combo: annotation?["combo"]?.string?.uppercased())
            } else if result.uniforms[declaration.name] == nil || annotation != nil {
                result.uniforms[declaration.name] = .init(material: annotation?["material"]?.string,
                                                          defaultValue: annotation?["default"])
            }
        }
        return result
    }

    /// Translates the pair with `combos` (name → value; names are upper-cased like Wallpaper Engine does).
    public static func translate(vertex: String, fragment: String, combos: [String: Int]) -> TranslatedShader {
        let annotations = annotations(vertex: vertex, fragment: fragment)
        var defines = annotations.combos
        for (name, value) in combos { defines[name.uppercased()] = value }

        // Varyings get the same location in both stages, by name; one the fragment reads but the vertex stage
        // doesn't declare is added to the vertex stage (it reads as zero).
        let vertexVaryings = declarations(of: "varying", in: vertex)
        let fragmentVaryings = declarations(of: "varying", in: fragment)
        var locations: [String: Int] = [:]
        var nextLocation = 0
        for v in vertexVaryings + fragmentVaryings where locations[v.name] == nil {
            locations[v.name] = nextLocation
            nextLocation += max(1, v.count) * (v.type.hasPrefix("mat") ? Int(String(v.type.last ?? "4")) ?? 4 : 1)
        }
        let extra = fragmentVaryings.filter { v in !vertexVaryings.contains { $0.name == v.name } }

        var attributes: [String: Int] = [:]
        for (_, name, _) in declarations(of: "attribute", in: vertex) where attributes[name] == nil {
            attributes[name] = knownAttributes[name] ?? 8 + attributes.values.filter { $0 >= 8 }.count
        }

        func stage(_ source: String, isVertex: Bool) -> String {
            var body = clean(source)
            var inputs: [String] = []
            let source = body
            body = rewrite(body, keyword: "varying") { type, name, suffix in
                let location = "layout(location = \(locations[name] ?? 0))"
                if isVertex { return "\(location) out \(type) \(name)\(suffix);" }
                // HLSL lets a fragment shader change its inputs, so those it assigns to are copied into globals of the
                // same name.
                let assigned = #"\b\#(name)\s*(\.\w+)?\s*(\[[^\]]*\])?\s*([-+*/]?=(?!=)|\+\+|--)"#
                guard source.range(of: assigned, options: .regularExpression) != nil else { return "\(location) in \(type) \(name)\(suffix);" }
                inputs.append(name)
                return "\(location) in \(type) as_in_\(name)\(suffix); \(type) \(name)\(suffix);"
            }
            if !inputs.isEmpty, let main = body.range(of: #"\bvoid\s+main\s*\(\s*(void)?\s*\)\s*\{"#, options: .regularExpression) {
                body.insert(contentsOf: inputs.map { " \($0) = as_in_\($0);" }.joined(), at: main.upperBound)
            }
            if isVertex {
                body = rewrite(body, keyword: "attribute") { type, name, _ in
                    "layout(location = \(attributes[name] ?? 0)) in \(type) \(name);"
                }
                for v in extra {
                    body = "layout(location = \(locations[v.name] ?? 0)) out \(v.type) \(v.name)\(v.count > 0 ? "[\(v.count)]" : "");\n" + body
                }
            } else {
                body = replaceWord("gl_FragColor", with: "as_FragColor", in: body)
                body = "layout(location = 0) out vec4 as_FragColor;\n" + body
            }
            var stageDefines = defines
            // Undefined names in #if count as 0, as in C.
            let defined = Set(matches(#"#\s*define\s+(\w+)"#, in: body).map { $0[1] }).union(stageDefines.keys)
            for line in body.split(separator: "\n") where line.range(of: #"^\s*#\s*(el)?if\b"#, options: .regularExpression) != nil {
                // `defined(X)` must stay false for an undefined X, so its operand isn't defined as 0.
                let expression = String(line).replacingOccurrences(of: #"//.*|/\*.*?\*/"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"defined\s*\(?\s*\w+\s*\)?"#, with: "", options: .regularExpression)
                for name in matches(#"\b([A-Za-z_]\w*)\b"#, in: expression).map({ $0[1] })
                where !["if", "elif", "defined"].contains(name) && !defined.contains(name) {
                    stageDefines[name] = 0
                }
            }
            let defineLines = stageDefines.sorted { $0.key < $1.key }.map { "#define \($0.key) \($0.value)" }.joined(separator: "\n")
            return prelude + defineLines + "\n" + body
        }
        return TranslatedShader(vertex: stage(vertex, isVertex: true), fragment: stage(fragment, isVertex: false),
                                annotations: annotations, attributes: attributes)
    }

    // MARK: - Compiling with repairs

    /// Compiles a translated stage to Metal. When glslang rejects HLSL-isms (a vec4 assigned to a vec3, a float used as a
    /// condition), the offending lines are repaired the way HLSL reads them and compiling is retried.
    public static func compile(_ source: String, stage: ShaderStage) throws -> MetalShader {
        var source = source
        var lastError: ShaderCompileError?
        for _ in 0 ..< 8 {
            do {
                return try ShaderCompiler.metal(source, stage: stage)
            } catch let error as ShaderCompileError {
                lastError = error
                guard let repaired = repair(source, log: error.description), repaired != source else { throw error }
                source = repaired
            }
        }
        throw lastError ?? ShaderCompileError(description: "too many errors")
    }

    /// Repairs the lines glslang's log complains about, or nil when no error is one it knows how to fix.
    static func repair(_ source: String, log: String) -> String? {
        var lines = source.components(separatedBy: "\n")
        var changed = false
        for error in matches(#"ERROR: \d+:(\d+): (.*)"#, in: log) {
            guard let number = Int(error[1]), number >= 1, number <= lines.count else { continue }
            let message = error[2]
            let index = number - 1
            var line = lines[index]
            if message.contains("boolean expression expected") {
                line = wrapCondition(line)
            } else if message.contains("cannot convert"), let target = targetType(message) {
                line = wrapAssignment(line, in: target)
            } else if message.contains("no matching overloaded function found") {
                line = floatLiterals(line)
            } else if message.contains("wrong operand types"), let sizes = operandSizes(message), sizes.0 != sizes.1,
                      let op = matches(#"no operation '([^']+)'"#, in: message).first?[1] {
                line = truncateOperands(line, operator: op, to: min(sizes.0, sizes.1))
            } else if message.contains("type does not match, or is not convertible to, the function's return type"),
                      let type = enclosingReturnType(lines, before: index) {
                line = wrapReturn(line, in: type)
            }
            if line != lines[index] {
                lines[index] = line
                changed = true
            }
        }
        return changed ? lines.joined(separator: "\n") : nil
    }

    /// Integer literals as float literals (HLSL converts them where GLSL finds `max(x, 0)` ambiguous), except in
    /// subscripts, int declarations and loops.
    private static func floatLiterals(_ line: String) -> String {
        guard line.range(of: #"\b(int|ivec\d|uint|for)\b|%|<<|>>|&|\|"#, options: .regularExpression) == nil else { return line }
        var result = ""
        var depth = 0
        var i = line.startIndex
        while i < line.endIndex {
            let c = line[i]
            if c == "[" { depth += 1 } else if c == "]" { depth -= 1 }
            if c.isNumber, depth == 0, i == line.startIndex || !(line[line.index(before: i)].isLetter || line[line.index(before: i)].isNumber
                || line[line.index(before: i)] == "_" || line[line.index(before: i)] == ".") {
                var j = i
                while j < line.endIndex, line[j].isNumber { j = line.index(after: j) }
                let next = j < line.endIndex ? line[j] : " "
                result += line[i ..< j]
                if !(next == "." || next.isLetter || next == "_") { result += ".0" }
                i = j
                continue
            }
            result.append(c)
            i = line.index(after: i)
        }
        return result
    }

    /// The vector sizes of the two operands in a "wrong operand types" message.
    private static func operandSizes(_ message: String) -> (Int, Int)? {
        let sizes = matches(#"operand of type '([^']*)'"#, in: message).map { type in
            matches(#"(\d)-component vector"#, in: type[1]).first.flatMap { Int($0[1]) } ?? 1
        }
        return sizes.count >= 2 ? (sizes[0], sizes[1]) : nil
    }

    /// HLSL drops the extra components when vectors of different sizes meet: `a3 - b2` → `vec2(a3) - b2`. Simple operands
    /// (names, swizzles, calls) next to `op` are truncated to `size`.
    private static func truncateOperands(_ line: String, operator op: String, to size: Int) -> String {
        guard size >= 2 else { return line }
        let escaped = NSRegularExpression.escapedPattern(for: op)
        let operand = #"[A-Za-z_][\w.]*(?:\([^()]*\))?"#
        let pattern = "(\(operand))\\s*\(escaped)\\s*(\(operand))"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return line }
        let ns = line as NSString
        guard let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return line }
        let a = ns.substring(with: m.range(at: 1)), b = ns.substring(with: m.range(at: 2))
        return ns.replacingCharacters(in: m.range, with: "vec\(size)(\(a)) \(op) vec\(size)(\(b))")
    }

    /// The GLSL type an error message says a value should become ("to ' temp highp 3-component vector of float'").
    private static func targetType(_ message: String) -> String? {
        guard let to = message.range(of: " to ") else { return nil }
        let rest = message[to.upperBound...]
        if let n = rest.range(of: #"(\d)-component vector of float"#, options: .regularExpression) {
            return "vec" + rest[n].prefix(1)
        }
        if let n = rest.range(of: #"(\d)-component vector of int"#, options: .regularExpression) {
            return "ivec" + rest[n].prefix(1)
        }
        if rest.contains(" float") { return "float" }
        if rest.contains(" int") { return "int" }
        return nil
    }

    /// `a = b;` → `a = T(b);` (also `+=`, declarations).
    private static func wrapAssignment(_ line: String, in type: String) -> String {
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            if chars[i] == "=", !(i + 1 < chars.count && chars[i + 1] == "="),
               !(i > 0 && "=!<>".contains(chars[i - 1])) {
                guard let end = line.lastIndex(of: ";"), line.index(line.startIndex, offsetBy: i + 1) < end else { return line }
                let start = line.index(line.startIndex, offsetBy: i + 1)
                return String(line[..<start]) + " \(type)(" + line[start ..< end].trimmingCharacters(in: .whitespaces) + ")"
                    + String(line[end...])
            }
            i += 1
        }
        return line
    }

    private static func wrapReturn(_ line: String, in type: String) -> String {
        guard let r = line.range(of: #"\breturn\b"#, options: .regularExpression), let end = line.lastIndex(of: ";"),
              r.upperBound < end else { return line }
        return String(line[..<r.upperBound]) + " \(type)(" + line[r.upperBound ..< end].trimmingCharacters(in: .whitespaces) + ")"
            + String(line[end...])
    }

    /// A float used as a condition: `if (x)` → `if (as_bool(x))`, `y = x ? a : b` → `y = as_bool(x) ? a : b`.
    private static func wrapCondition(_ line: String) -> String {
        let chars = Array(line)
        if let q = chars.firstIndex(of: "?") {
            var depth = 0, start = q - 1
            while start >= 0 {
                let c = chars[start]
                if c == ")" { depth += 1 } else if c == "(" {
                    if depth == 0 { break }
                    depth -= 1
                } else if depth == 0, c == "=" || c == "," { break }
                start -= 1
            }
            var condition = String(chars[(start + 1) ..< q])
            var prefix = String(chars[0 ... max(start, 0)])
            if start < 0 { prefix = "" }
            if let r = condition.range(of: #"^\s*return\b"#, options: .regularExpression) {
                prefix += condition[r]
                condition = String(condition[r.upperBound...])
            }
            return prefix + " as_bool(" + condition.trimmingCharacters(in: .whitespaces) + ") " + String(chars[q...])
        }
        if let r = line.range(of: #"\bif\s*\("#, options: .regularExpression) {
            let open = line.index(before: r.upperBound)
            var depth = 0
            var i = open
            while i < line.endIndex {
                if line[i] == "(" { depth += 1 } else if line[i] == ")" {
                    depth -= 1
                    if depth == 0 {
                        return String(line[...open]) + "as_bool(" + line[line.index(after: open) ..< i] + ")" + String(line[i...])
                    }
                }
                i = line.index(after: i)
            }
        }
        return line
    }

    private static func enclosingReturnType(_ lines: [String], before index: Int) -> String? {
        for i in stride(from: index, through: 0, by: -1) {
            if let m = matches(#"^\s*(vec[234]|float|int|ivec[234]|bool|mat[234])\s+\w+\s*\("#, in: lines[i]).first { return m[1] }
        }
        return nil
    }

    // MARK: - Source handling

    private static func expand(_ text: String, files: SceneFiles, depth: Int, total: inout Int) throws -> String {
        guard depth <= SceneLimits.maxIncludeDepth else { throw SceneError.tooLarge("Shader includes") }
        total += text.utf8.count
        guard total <= SceneLimits.maxShaderBytes else { throw SceneError.tooLarge("A shader") }
        var output: [String] = []
        for line in text.components(separatedBy: "\n") {
            if let m = matches(#"^\s*#\s*include\s+"([^"]+)""#, in: line).first {
                let path = "shaders/\(m[1])"
                guard let included = files.text(path) else { throw SceneError.missing(path) }
                output.append(try expand(included, files: files, depth: depth + 1, total: &total))
            } else {
                output.append(line)
            }
        }
        return output.joined(separator: "\n")
    }

    /// Strips directives GLSL 450 rejects or we replace, and renames identifiers that are reserved words in GLSL 450.
    private static func clean(_ source: String) -> String {
        var lines = source.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#version") || trimmed.hasPrefix("#extension") || trimmed.hasPrefix("#require") { return "" }
            return line
        }
        lines = lines.map { line in
            var line = line
            for word in reservedWords where line.contains(word) { line = replaceWord(word, with: "as_" + word, in: line) }
            return line
        }
        // Wallpaper Engine's preprocessor tolerates an #endif too many, or one missing at the end.
        var depth = 0
        for (i, line) in lines.enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.range(of: #"^#\s*if"#, options: .regularExpression) != nil { depth += 1 }
            if t.range(of: #"^#\s*endif"#, options: .regularExpression) != nil {
                if depth == 0 { lines[i] = "" } else { depth -= 1 }
            }
        }
        lines += Array(repeating: "#endif", count: depth)
        return lines.joined(separator: "\n")
    }

    static let reservedWords = ["sample", "input", "output", "filter", "active", "common", "partition", "noise", "buffer",
                                "shared", "resource", "subroutine", "precise", "coherent", "superp", "packed"]

    /// `varying vec2 a, b[4];` → (type, name, array count: 0 when not an array).
    private static func declarations(of keyword: String, in source: String) -> [(type: String, name: String, count: Int)] {
        matches(#"\b\#(keyword)\s+(?:(?:lowp|mediump|highp)\s+)?(\w+)\s+([^;]+);"#, in: source).flatMap { m in
            m[2].split(separator: ",").map { part in
                let (name, suffix) = splitArray(part.trimmingCharacters(in: .whitespaces))
                return (m[1], name, Int(suffix.dropFirst().dropLast()) ?? 0)
            }
        }
    }

    /// `name[4]` → ("name", "[4]").
    private static func splitArray(_ declarator: String) -> (String, String) {
        guard let bracket = declarator.firstIndex(of: "[") else { return (declarator, "") }
        return (String(declarator[..<bracket]).trimmingCharacters(in: .whitespaces), String(declarator[bracket...]).replacingOccurrences(of: " ", with: ""))
    }

    /// Replaces each `keyword type a, b;` with one line per name from `make(type, name, array suffix)`.
    private static func rewrite(_ source: String, keyword: String, make: (String, String, String) -> String) -> String {
        let regex = try! NSRegularExpression(pattern: #"\b\#(keyword)\s+(?:(?:lowp|mediump|highp)\s+)?(\w+)\s+([^;]+);"#)
        var result = source
        for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
            let ns = source as NSString
            let type = ns.substring(with: match.range(at: 1))
            let names = ns.substring(with: match.range(at: 2)).split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let replacement = names.map { name in
                let (base, suffix) = splitArray(name)
                return make(type, base, suffix)
            }.joined(separator: " ")
            result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
        }
        return result
    }

    private static func uniformDeclaration(_ line: String) -> (type: String, name: String)? {
        matches(#"^\s*uniform\s+(?:(?:lowp|mediump|highp)\s+)?(\w+)\s+(\w+)"#, in: line).first.map { ($0[1], $0[2]) }
    }

    private static func json(_ text: String) -> SceneJSON? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{") else { return nil }
        return try? SceneJSON(data: Data(trimmed.utf8), name: "annotation")
    }

    static func replaceWord(_ word: String, with replacement: String, in text: String) -> String {
        text.replacingOccurrences(of: #"\b\#(word)\b"#, with: replacement, options: .regularExpression)
    }

    /// Capture groups of every match (index 0 is the whole match).
    static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (0 ..< m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
        }
    }

    // MARK: - Prelude

    static let prelude: String = {
        var p = """
            #version 450
            #define float2 vec2
            #define float3 vec3
            #define float4 vec4
            #define float2x2 mat2
            #define float3x3 mat3
            #define float4x4 mat4
            #define int2 ivec2
            #define int3 ivec3
            #define int4 ivec4
            #define mul(x, y) ((y) * (x))
            #define frac fract
            #define lerp mix
            #define saturate(x) clamp(x, 0.0, 1.0)
            #define atan2 atan
            #define rsqrt inversesqrt
            #define ddx dFdx
            #define ddy dFdy
            #define fmod as_fmod
            #define log10(x) (log(x) * 0.4342944819)
            #define CAST2(x) (vec2(x))
            #define CAST3(x) (vec3(x))
            #define CAST4(x) (vec4(x))
            #define CAST3X3(x) (mat3(x))
            #define texSample2D texture
            #define texSample2DLod textureLod
            #define texture2D texture
            #define texture2DLod textureLod
            #define GLSL 1
            #define HLSL 0
            bool as_bool(bool x) { return x; }
            bool as_bool(float x) { return x != 0.0; }
            bool as_bool(int x) { return x != 0; }
            float as_fmod(float x, float y) { return x - y * trunc(x / y); }

            """
        // HLSL broadcasts a scalar against a vector in any argument; GLSL's built-ins only take the scalar second.
        for n in 2 ... 4 {
            let v = "vec\(n)"
            p += """
                \(v) max(float a, \(v) b) { return max(\(v)(a), b); }
                \(v) min(float a, \(v) b) { return min(\(v)(a), b); }
                \(v) pow(\(v) a, float b) { return pow(a, \(v)(b)); }
                \(v) pow(float a, \(v) b) { return pow(\(v)(a), b); }
                \(v) mod(float a, \(v) b) { return mod(\(v)(a), b); }
                \(v) step(\(v) e, float x) { return step(e, \(v)(x)); }
                \(v) as_fmod(\(v) x, \(v) y) { return x - y * trunc(x / y); }
                \(v) as_fmod(\(v) x, float y) { return x - y * trunc(x / y); }
                \(v) atan(\(v) y, float x) { return atan(y, \(v)(x)); }
                \(v) clamp(float x, \(v) lo, \(v) hi) { return clamp(\(v)(x), lo, hi); }
                \(v) mix(float a, \(v) b, float t) { return mix(\(v)(a), b, t); }
                \(v) mix(\(v) a, float b, float t) { return mix(a, \(v)(b), t); }

                """
        }
        return p
    }()
}
