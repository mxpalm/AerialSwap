import Compression
import Foundation
import Testing
@testable import SceneEngine

/// Builds little-endian test files.
struct Bytes {
    var data = Data()
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
    mutating func f32(_ v: Float) { u32(v.bitPattern) }
    mutating func string(_ s: String) { u32(UInt32(s.utf8.count)); data.append(contentsOf: s.utf8) }
    mutating func magic(_ s: String) { data.append(contentsOf: s.utf8); data.append(0) }
    mutating func raw(_ d: Data) { data.append(d) }
}

func package(_ files: [String: Data]) -> Data {
    var b = Bytes()
    b.string("PKGV0001")
    b.u32(UInt32(files.count))
    var offset = 0
    let sorted = files.sorted { $0.key < $1.key }
    for (name, data) in sorted {
        b.string(name); b.u32(UInt32(offset)); b.u32(UInt32(data.count))
        offset += data.count
    }
    for (_, data) in sorted { b.raw(data) }
    return b.data
}

/// A TEXB0003 texture with one image of one mip.
func texture(format: Int32 = 0, flags: Int32 = 2, width: Int32, height: Int32, pixels: Data, lz4: Bool = false,
             imageFormat: Int32 = -1, sprite: ((inout Bytes) -> Void)? = nil) -> Data {
    var b = Bytes()
    b.magic("TEXV0005"); b.magic("TEXI0001")
    b.i32(format); b.i32(flags); b.i32(width); b.i32(height); b.i32(width); b.i32(height); b.u32(0)
    b.magic("TEXB0003"); b.i32(1); b.i32(imageFormat)
    b.i32(1); b.i32(width); b.i32(height)
    if lz4 {
        var out = Data(count: pixels.count + 1024)
        let n = out.withUnsafeMutableBytes { o in
            pixels.withUnsafeBytes { i in
                compression_encode_buffer(o.bindMemory(to: UInt8.self).baseAddress!, o.count,
                                          i.bindMemory(to: UInt8.self).baseAddress!, pixels.count, nil, COMPRESSION_LZ4_RAW)
            }
        }
        b.i32(1); b.i32(Int32(pixels.count)); b.i32(Int32(n)); b.raw(out.prefix(n))
    } else {
        b.i32(0); b.i32(0); b.i32(Int32(pixels.count)); b.raw(pixels)
    }
    sprite?(&b)
    return b.data
}

@Suite struct PackageTests {
    @Test func readsEntriesAndNormalizesPaths() throws {
        let pkg = try ScenePackage(data: package(["scene.json": Data("{}".utf8), "materials\\a.json": Data("[1]".utf8)]))
        #expect(pkg.paths == ["materials/a.json", "scene.json"])
        #expect(pkg.file("./materials/a.json") == Data("[1]".utf8))
    }

    @Test func rejectsEntriesPastTheEnd() {
        var b = Bytes()
        b.string("PKGV0001"); b.u32(1); b.string("x"); b.u32(0); b.u32(1000)
        #expect(throws: SceneError.self) { try ScenePackage(data: b.data) }
    }

    @Test func rejectsTruncatedTables() {
        var b = Bytes()
        b.string("PKGV0001"); b.u32(3); b.string("x")
        #expect(throws: SceneError.self) { try ScenePackage(data: b.data) }
    }
}

@Suite struct TextureTests {
    @Test func rawPixels() throws {
        let tex = try SceneTexture(data: texture(width: 2, height: 2, pixels: Data(repeating: 7, count: 16)), name: "t")
        #expect(tex.format == .rgba8 && tex.encoding == .raw)
        #expect(tex.images[0][0].data == Data(repeating: 7, count: 16))
        #expect(tex.flags.contains(.clampUVs))
    }

    @Test func lz4Pixels() throws {
        let pixels = Data((0 ..< 4096).map { UInt8($0 % 7) })
        let tex = try SceneTexture(data: texture(width: 32, height: 32, pixels: pixels, lz4: true), name: "t")
        #expect(tex.images[0][0].data == pixels)
    }

    @Test func dxtNeedsWholeBlocks() throws {
        let ok = try SceneTexture(data: texture(format: 7, width: 8, height: 8, pixels: Data(count: 32)), name: "t")
        #expect(ok.format == .dxt1)
        #expect(throws: SceneError.self) {
            try SceneTexture(data: texture(format: 7, width: 8, height: 8, pixels: Data(count: 31)), name: "t")
        }
    }

    @Test func embeddedImages() throws {
        let tex = try SceneTexture(data: texture(width: 4, height: 4, pixels: Data([0x89, 0x50, 0x4E, 0x47]), imageFormat: 13), name: "t")
        #expect(tex.encoding == .png)
    }

    @Test func spriteSheet() throws {
        let data = texture(flags: 4, width: 4, height: 4, pixels: Data(count: 64)) { b in
            b.magic("TEXS0003"); b.i32(2); b.i32(4); b.i32(4)
            for i in 0 ..< 2 { b.i32(0); b.f32(0.1); for v: Float in [Float(i) * 2, 0, 2, 0, 0, 4] { b.f32(v) } }
        }
        let tex = try SceneTexture(data: data, name: "t")
        #expect(tex.frames == [
            .init(image: 0, duration: Double(Float(0.1)), x: 0, y: 0, width: 2, height: 4),
            .init(image: 0, duration: Double(Float(0.1)), x: 2, y: 0, width: 2, height: 4),
        ])
    }

    @Test func rejectsHugeSizes() {
        #expect(throws: SceneError.self) {
            try SceneTexture(data: texture(width: 100_000, height: 2, pixels: Data(count: 16)), name: "t")
        }
    }

    @Test func rejectsTruncatedData() {
        let data = texture(width: 2, height: 2, pixels: Data(count: 16))
        #expect(throws: SceneError.self) { try SceneTexture(data: data.prefix(data.count - 4), name: "t") }
    }
}

@Suite struct JSONTests {
    @Test func looseValues() throws {
        let json = try SceneJSON(data: Data("\u{FEFF}{\"v\": \"1 0.5 -2\", \"n\": \"3\", \"b\": 1, /* c */ \"x\": [1,],}".utf8), name: "j")
        #expect(json["v"]?.vector == [1, 0.5, -2])
        #expect(json["n"]?.number == 3)
        #expect(json["b"]?.bool == true)
        #expect(json["x"]?.array?.count == 1)
    }

    @Test func nonFiniteNumbersAreDropped() throws {
        let json = try SceneJSON(data: Data("{\"a\": Infinity, \"v\": \"1 inf\"}".utf8), name: "j")
        #expect(json["a"]?.number == nil)
        #expect(json["v"]?.vector == nil)
    }

    @Test func bindingsResolve() throws {
        let json = try SceneJSON(data: Data("""
            {"a": {"user": "speed", "value": 1}, "b": {"user": {"name": "mode", "condition": "2"}, "value": false},
             "c": {"user": "unknown", "value": 5}, "d": {"value": 7, "script": "x"}}
            """.utf8), name: "j").resolvedDeep(["speed": .number(4), "mode": .string("2")])
        #expect(json["a"]?.number == 4)
        #expect(json["b"]?.bool == true)
        #expect(json["c"]?.number == 5)
        #expect(json["d"]?.number == 7)
    }
}

@Suite struct FilesTests {
    @Test func pathsStayInsideTheFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "scene-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("in".utf8).write(to: folder.appending(path: "a.txt"))
        let files = try SceneFiles(folder: folder)
        #expect(files.text("a.txt") == "in")
        #expect(files.contained("../a.txt") == nil)
        #expect(files.data("../../etc/hosts") == nil)
        #expect(files.isCore("shaders/common.h"))
    }

    @Test func projectProperties() throws {
        let project = SceneProject(json: try SceneJSON(data: Data("""
            {"title": " Rain ", "type": "Scene", "file": "scene.json", "general": {"properties": {
              "rain": {"type": "bool", "value": true, "text": "Rain", "order": 2},
              "speed": {"type": "slider", "min": 0, "max": 10, "value": 3, "text": "Speed", "order": 1},
              "mode": {"type": "combo", "value": "1", "options": [{"label": "A", "value": "0"}, {"label": "B", "value": "1"}]}
            }}}
            """.utf8), name: "p"))
        #expect(project.title == "Rain" && project.kind == .scene)
        #expect(project.properties.map(\.id) == ["mode", "speed", "rain"])
        #expect(project.values["speed"]?.number == 3)
        if case .choice(let options) = project.properties[0].kind { #expect(options.map(\.label) == ["A", "B"]) }
        else { Issue.record("mode should be a choice") }
    }
}
