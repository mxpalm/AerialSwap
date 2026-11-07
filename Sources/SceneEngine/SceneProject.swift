import Foundation

/// A wallpaper's `project.json`: its title, type, entry file, preview and the properties its author lets users change.
public struct SceneProject: Sendable {
    public enum Kind: String, Sendable { case scene, video, web, application, unknown }

    /// One user property, as the wallpaper's settings show it.
    public struct Property: Sendable, Equatable, Identifiable {
        public enum Kind: Sendable, Equatable {
            case color
            case slider(min: Double, max: Double, step: Double?, integer: Bool)
            case toggle
            case choice([(label: String, value: SceneJSON)])
            case text
            /// Text input, files, folders, scene textures, shortcuts: shown, but not changeable in AerialSwap.
            case other(String)

            public static func == (a: Kind, b: Kind) -> Bool {
                switch (a, b) {
                case (.color, .color), (.toggle, .toggle), (.text, .text): true
                case let (.slider(a1, a2, a3, a4), .slider(b1, b2, b3, b4)): a1 == b1 && a2 == b2 && a3 == b3 && a4 == b4
                case let (.choice(a), .choice(b)): a.map(\.label) == b.map(\.label) && a.map(\.value) == b.map(\.value)
                case let (.other(a), .other(b)): a == b
                default: false
                }
            }
        }

        public let id: String
        /// The label as the author wrote it (may contain HTML or a `ui_…` localization key).
        public let label: String
        public let kind: Kind
        public let value: SceneJSON
        public let order: Int
        /// A JavaScript-like expression over other properties deciding whether this one shows (kept verbatim).
        public let condition: String?
    }

    public let title: String
    public let kind: Kind
    /// The entry file named in the project (`scene.json` for scenes), relative to the folder.
    public let file: String
    public let preview: String?
    public let properties: [Property]
    public let tags: [String]
    public let contentRating: String?

    public init(json: SceneJSON) {
        title = (json["title"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        kind = Kind(rawValue: (json["type"]?.string ?? "").lowercased()) ?? .unknown
        file = json["file"]?.string ?? "scene.json"
        preview = json["preview"]?.string
        tags = json["tags"]?.array?.compactMap(\.string) ?? []
        contentRating = json["contentrating"]?.string
        let raw = json["general"]?["properties"]?.object ?? [:]
        properties = raw.compactMap { Self.property(id: $0.key, $0.value) }
            .sorted { ($0.order, $0.id) < ($1.order, $1.id) }
    }

    public init(folder: URL) throws {
        let url = folder.appending(path: "project.json")
        try self.init(json: SceneJSON(data: SceneFiles.read(url, name: "project.json"), name: "project.json"))
    }

    /// Property name → current value: what bindings in the scene resolve against.
    public var values: [String: SceneJSON] {
        Dictionary(properties.map { ($0.id, $0.value) }, uniquingKeysWith: { a, _ in a })
    }

    private static func property(id: String, _ json: SceneJSON) -> Property? {
        guard json.object != nil else { return nil }
        let type = (json["type"]?.string ?? "").lowercased()
        let kind: Property.Kind = switch type {
        case "color": .color
        case "slider":
            .slider(min: json["min"]?.number ?? 0, max: json["max"]?.number ?? 100, step: json["step"]?.number,
                    integer: json["fraction"]?.bool == false)
        case "bool": .toggle
        case "combo":
            .choice((json["options"]?.array ?? []).compactMap { option in
                guard let value = option["value"] else { return nil }
                return (option["label"]?.string ?? value.string ?? "", value)
            })
        case "text": .text
        default: .other(type)
        }
        return Property(id: id, label: json["text"]?.string ?? id, kind: kind, value: json["value"] ?? .null,
                        order: Int(json["order"]?.number ?? 0), condition: json["condition"]?.string)
    }
}
