import Foundation

extension SceneProject.Property {
    /// The label as text: HTML tags, direction marks and entities removed, a `ui_…` key turned into words
    /// ("ui_browse_properties_scheme_color" → "Scheme color"). The property's ID when nothing is left.
    public var title: String { Self.displayText(label, fallback: id) }

    /// A label from a wallpaper's settings (a property's or a choice's) as plain text; `fallback` when nothing is left.
    public static func displayText(_ label: String, fallback: String) -> String {
        var text = label.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
        for (entity, character) in ["&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&amp;": "&"] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        let invisible = CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{200E}\u{200F}\u{2060}\u{FEFF}")
            .union(.controlCharacters)
        text = String(String.UnicodeScalarView(text.unicodeScalars.filter { !invisible.contains($0) }))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if text.hasPrefix("ui_"), !text.contains(" ") {
            let words = text.replacingOccurrences(of: "ui_browse_properties_", with: "")
                .replacingOccurrences(of: "ui_editor_properties_", with: "")
                .replacingOccurrences(of: "ui_", with: "")
                .replacingOccurrences(of: "_", with: " ")
            text = words.prefix(1).uppercased() + words.dropFirst()
        }
        return String((text.isEmpty ? fallback : text).prefix(80))
    }

    /// Whether the wallpaper's settings show this property with these values (its `condition`, like
    /// `clock.value == true && style.value != 2`). Shown when there's no condition or it can't be read.
    public func isShown(values: [String: SceneJSON]) -> Bool {
        guard let condition, !condition.trimmingCharacters(in: .whitespaces).isEmpty else { return true }
        return SceneCondition.evaluate(condition, values: values) ?? true
    }
}

/// The expressions in properties' `condition`s: property values (`name.value`, or just `name`), numbers, strings,
/// `true`/`false`, comparisons, `!`, `&&`, `||` and parentheses, compared loosely like JavaScript's `==`. Anything
/// else is nil: it's read here, never run.
enum SceneCondition {
    private indirect enum Node {
        case value(SceneJSON)
        case not(Node)
        case and(Node, Node), or(Node, Node)
        case compare(String, Node, Node)
    }

    static func evaluate(_ text: String, values: [String: SceneJSON]) -> Bool? {
        guard text.count <= 2000, let tokens = tokenize(text) else { return nil }
        var parser = Parser(tokens: tokens, values: values)
        guard let node = parser.or(), parser.index == tokens.count else { return nil }
        return truthy(value(node))
    }

    private enum Token: Equatable { case word(String), number(Double), string(String), symbol(String) }

    private static func tokenize(_ text: String) -> [Token]? {
        var tokens: [Token] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c.isLetter || c == "_" || c == "$" {
                var j = i
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || "_$.".contains(chars[j]) { j += 1 }
                tokens.append(.word(String(chars[i..<j]))); i = j
            } else if c.isNumber || (c == "." && i + 1 < chars.count && chars[i + 1].isNumber)
                        || (c == "-" && i + 1 < chars.count && chars[i + 1].isNumber && !(tokens.last.map(isOperand) ?? false)) {
                var j = i + 1
                while j < chars.count, chars[j].isNumber || chars[j] == "." { j += 1 }
                guard let n = Double(String(chars[i..<j])) else { return nil }
                tokens.append(.number(n)); i = j
            } else if c == "'" || c == "\"" {
                guard let end = chars[(i + 1)...].firstIndex(of: c) else { return nil }
                tokens.append(.string(String(chars[(i + 1)..<end]))); i = end + 1
            } else {
                let rest = String(chars[i..<min(i + 3, chars.count)])
                guard let symbol = ["===", "!==", "==", "!=", "<=", ">=", "&&", "||", "<", ">", "!", "(", ")"]
                    .first(where: { rest.hasPrefix($0) }) else { return nil }
                tokens.append(.symbol(symbol)); i += symbol.count
            }
        }
        return tokens
    }

    private static func isOperand(_ token: Token) -> Bool {
        if case .symbol(let s) = token { return s == ")" }
        return true
    }

    private struct Parser {
        let tokens: [Token]
        let values: [String: SceneJSON]
        var index = 0
        var depth = 0

        mutating func or() -> Node? {
            guard var node = and() else { return nil }
            while accept("||") { guard let right = and() else { return nil }; node = .or(node, right) }
            return node
        }

        mutating func and() -> Node? {
            guard var node = comparison() else { return nil }
            while accept("&&") { guard let right = comparison() else { return nil }; node = .and(node, right) }
            return node
        }

        /// A comparison, or one value; `!` binds tighter, as in JavaScript.
        mutating func comparison() -> Node? {
            guard let left = unary() else { return nil }
            for op in ["===", "!==", "==", "!=", "<=", ">=", "<", ">"] where accept(op) {
                return unary().map { .compare(op, left, $0) }
            }
            return left
        }

        mutating func unary() -> Node? {
            if accept("!") {
                depth += 1
                guard depth < 32 else { return nil }
                defer { depth -= 1 }
                return unary().map(Node.not)
            }
            return primary()
        }

        mutating func primary() -> Node? {
            guard index < tokens.count else { return nil }
            let token = tokens[index]
            index += 1
            switch token {
            case .number(let n): return .value(.number(n))
            case .string(let s): return .value(.string(s))
            case .word("true"): return .value(.bool(true))
            case .word("false"): return .value(.bool(false))
            case .word(let word):
                let name = word.hasSuffix(".value") ? String(word.dropLast(6)) : word
                guard !name.contains(".") else { return nil }
                return .value(values[name] ?? .null)
            case .symbol("("):
                depth += 1
                guard depth < 32, let node = or(), accept(")") else { return nil }
                depth -= 1
                return node
            default: return nil
            }
        }

        mutating func accept(_ symbol: String) -> Bool {
            guard index < tokens.count, tokens[index] == .symbol(symbol) else { return false }
            index += 1
            return true
        }
    }

    private static func value(_ node: Node) -> SceneJSON {
        switch node {
        case .value(let v): v
        case .not(let n): .bool(!truthy(value(n)))
        case .and(let a, let b): .bool(truthy(value(a)) && truthy(value(b)))
        case .or(let a, let b): .bool(truthy(value(a)) || truthy(value(b)))
        case .compare(let op, let a, let b): .bool(compare(op, value(a), value(b)))
        }
    }

    private static func truthy(_ v: SceneJSON) -> Bool {
        switch v {
        case .null: false
        case .bool(let b): b
        case .number(let n): n != 0 && !n.isNaN
        case .string(let s): !s.isEmpty
        case .array, .object: true
        }
    }

    /// Strings that read as numbers compare as numbers, booleans as 0 and 1.
    private static func compare(_ op: String, _ a: SceneJSON, _ b: SceneJSON) -> Bool {
        func number(_ v: SceneJSON) -> Double? {
            switch v {
            case .number(let n): n
            case .bool(let b): b ? 1 : 0
            case .string(let s): Double(s.trimmingCharacters(in: .whitespaces))
            default: nil
            }
        }
        let equal: Bool
        if let x = number(a), let y = number(b) {
            switch op {
            case "<": return x < y
            case ">": return x > y
            case "<=": return x <= y
            case ">=": return x >= y
            default: equal = x == y
            }
        } else {
            if ["<", ">", "<=", ">="].contains(op) { return false }
            equal = a == b
        }
        return op.hasPrefix("!") ? !equal : equal
    }
}

extension SceneProject {
    /// IDs of the settings a video can't honor, so they aren't offered: ones labelled as being about a clock or the
    /// date, ones that only change live objects (whose scripts read the clock, the music playing, the sound or the
    /// cursor: clocks, now playing, visualizers; album covers; and groups of them), and ones only shown under such a
    /// setting. Labels
    /// decide over IDs: wallpapers reuse IDs (one's "clock" switches butterflies).
    public func liveSettings(files: SceneFiles) -> Set<String> {
        guard let raw = try? files.json(file), let objects = raw["objects"]?.array else { return [] }
        let live = Set(((try? SceneDocument.scripts(in: objects, properties: values)) ?? [])
            .filter { SceneText.isLive($0.source) }.map(\.object))
            .union(objects.filter(SceneDocument.showsAlbumArt).compactMap { $0["id"]?.number.map { Int($0) } })

        // Live objects, and groups whose objects all are.
        var children: [Int: [Int]] = [:]
        var isGroup: [Int: Bool] = [:]
        for o in objects {
            guard let id = o["id"]?.number.map({ Int($0) }) else { continue }
            if let parent = o["parent"]?.number { children[Int(parent), default: []].append(id) }
            isGroup[id] = ["image", "particle", "text", "sound", "model", "light"].allSatisfy { o[$0] == nil }
        }
        var memo: [Int: Bool] = [:]
        func showsTime(_ id: Int, depth: Int = 0) -> Bool {
            if let known = memo[id] { return known }
            guard depth < 32 else { return false }
            let kids = children[id] ?? []
            let result = live.contains(id) || (isGroup[id] == true && !kids.isEmpty && kids.allSatisfy { showsTime($0, depth: depth + 1) })
            memo[id] = result
            return result
        }

        // The objects each setting is bound to anywhere in them.
        var uses: [String: [Int]] = [:]
        func walk(_ value: SceneJSON, object: Int, depth: Int) {
            guard depth < SceneLimits.maxJSONDepth else { return }
            if let binding = value.userBinding { uses[binding.name, default: []].append(object) }
            switch value {
            case .object(let dictionary): dictionary.values.forEach { walk($0, object: object, depth: depth + 1) }
            case .array(let array): array.forEach { walk($0, object: object, depth: depth + 1) }
            default: break
            }
        }
        for o in objects {
            guard let id = o["id"]?.number.map({ Int($0) }) else { continue }
            walk(o, object: id, depth: 0)
        }

        let clockWords = #"\b(clocks?|date|time ?format|(12|24) ?-?h(ou)?rs?|seconds|weekdays?|calendar|am ?/ ?pm)\b"#
        var hidden = Set(properties.filter { property in
            if property.title.range(of: clockWords, options: [.regularExpression, .caseInsensitive]) != nil { return true }
            guard let objects = uses[property.id], !objects.isEmpty else { return false }
            return objects.allSatisfy { showsTime($0) }
        }.map(\.id))
        // Settings that only show under a hidden one.
        var changed = true
        while changed {
            changed = false
            for property in properties where !hidden.contains(property.id) {
                guard let condition = property.condition,
                      hidden.contains(where: { condition.range(of: #"\b\#(NSRegularExpression.escapedPattern(for: $0))\b"#, options: .regularExpression) != nil })
                else { continue }
                hidden.insert(property.id)
                changed = true
            }
        }
        return hidden
    }
}
