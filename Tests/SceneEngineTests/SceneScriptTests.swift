import Foundation
import Testing
@testable import SceneEngine

/// A scene with one image object (id 1) whose values are given as JSON, scripts included.
private func document(values: String) throws -> SceneDocument {
    let folder = FileManager.default.temporaryDirectory.appending(path: "scene-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder.appending(path: "models"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try Data(#"{"width": 100, "height": 100}"#.utf8).write(to: folder.appending(path: "models/m.json"))
    try Data("""
        {"general": {"orthogonalprojection": {"width": 1920, "height": 1080}},
         "objects": [{"id": 1, "name": "Layer", "image": "models/m.json", \(values)}]}
        """.utf8).write(to: folder.appending(path: "scene.json"))
    let files = try SceneFiles(folder: folder)
    return try SceneDocument(files: files, project: SceneProject(json: try SceneJSON(data: Data(#"{"file": "scene.json"}"#.utf8), name: "p")))
}

/// A script value: `source` as a JSON string, with the value it starts from and the scene's script properties.
private func script(_ source: String, value: String, properties: String = "{}") throws -> String {
    let encoded = String(decoding: try JSONSerialization.data(withJSONObject: source, options: .fragmentsAllowed), as: UTF8.self)
    return #"{"script": \#(encoded), "value": \#(value), "scriptproperties": \#(properties)}"#
}

private func scripts(_ document: SceneDocument) -> SceneScripts {
    SceneScripts(document: document, screen: SIMD2(1920, 1080), timeOfDay: 0.5, clockStart: Date(timeIntervalSince1970: 1000))
}

@Suite struct SceneScriptTests {
    @Test func wrapRewritesModules() {
        let wrapped = SceneScripts.wrap("""
            import * as WEMath from 'WEMath';
            import { mix as blend, smoothStep } from "WEMath"
            export var scriptProperties = 1;
            export function update(value) { return value; }
            const a = 1, b = 2;
            export { a, b };
            """)
        #expect(wrapped.contains("const WEMath = __host.module('WEMath');"))
        #expect(wrapped.contains("const { mix: blend, smoothStep } = __host.module('WEMath');"))
        #expect(!wrapped.contains("export"))
        #expect(wrapped.contains("return { a: typeof a"))
        #expect(wrapped.contains("update: typeof update"))
    }

    @Test func valuesFollowSceneTime() throws {
        // engine.runtime counts the warm-up too; the clock shows clockStart at time 0.
        let doc = try document(values: """
            "origin": \(try script("""
                import * as WEMath from 'WEMath';
                export function update(value) { value.x = WEMath.mix(0, engine.runtime * 10, 1); return value; }
                """, value: #""0 5 0""#)),
            "alpha": \(try script("export function update() { return (Date.now() / 1000 - 1000) / 10; }", value: "1"))
            """)
        #expect(doc.scripts.map(\.path).sorted() == ["alpha", "origin"])
        let runner = scripts(doc)
        let later = try #require(runner.advance(to: 1)[1])
        #expect(abs(later.transform.origin.x - 60) < 1e-6 && later.transform.origin.y == 5)
        #expect(abs(later.alpha - 0.1) < 1e-6)
        // Going back starts over and lands on the same values as a fresh run.
        let earlier = try #require(runner.advance(to: 0.5)[1])
        #expect(abs(earlier.transform.origin.x - 55) < 1e-6)
        #expect(abs(earlier.alpha - 0.05) < 1e-6)
        #expect(runner.problems.isEmpty)
    }

    @Test func randomNumbersRepeat() throws {
        let doc = try document(values: """
            "alpha": \(try script("""
                let r = 0;
                export function init() { r = Math.random(); }
                export function update() { return (r + Math.random()) / 2; }
                """, value: "1"))
            """)
        let a = try #require(scripts(doc).advance(to: 2)[1]?.alpha)
        let b = try #require(scripts(doc).advance(to: 2)[1]?.alpha)
        #expect(a == b && a > 0 && a < 1)
    }

    @Test func otherValuesAndScriptProperties() throws {
        let doc = try document(values: """
            "effects": [{"file": "effects/missing/effect.json", "passes": [{"constantshadervalues": {"strength": \(try script("""
                export var scriptProperties = createScriptProperties()
                    .addSlider({name: 'amount', value: 2, min: 0, max: 5})
                    .addCheckbox({name: 'on', value: true})
                    .finish();
                export function update(value) { return scriptProperties.on ? 3 * scriptProperties.amount : 0; }
                """, value: "3", properties: #"{"amount": 4}"#)) }}]}]
            """)
        let path = "effects/0/passes/0/constantshadervalues/strength"
        #expect(doc.scripts.map(\.path) == [path])
        let state = try #require(scripts(doc).advance(to: 0)[1])
        #expect(state.values[path] == .number(12))
    }

    @Test func aFailingScriptStopsAlone() throws {
        let doc = try document(values: """
            "alpha": \(try script("export function update() { throw new Error('boom'); }", value: "0.5")),
            "brightness": \(try script("export function update() { return 2; }", value: "1")),
            "visible": \(try script("this is not JavaScript", value: "true"))
            """)
        let runner = scripts(doc)
        let state = try #require(runner.advance(to: 1)[1])
        #expect(state.alpha == 0.5 && state.brightness == 2 && state.visible)
        #expect(runner.problems.contains { $0.contains("boom") })
        #expect(runner.problems.contains { $0.contains("visible") })
    }
}
