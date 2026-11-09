import Foundation
import Testing
@testable import SceneEngine

@Suite struct LiveSettingsTests {
    /// A clock group (a time text and a static text, both scripted to read the clock), butterflies on a setting whose ID
    /// is "clock", a clock switch labelled by its ID only, and settings under them.
    @Test func clockSettingsAreFound() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "scene-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = #"{"script": "export function update() { return new Date().getHours(); }", "value": "12"}"#
        try Data("""
            {"general": {"orthogonalprojection": {"width": 1920, "height": 1080}},
             "objects": [
               {"id": 1, "name": "Clock", "visible": {"user": "showtime", "value": true}},
               {"id": 2, "name": "Time", "parent": 1, "text": \(clock)},
               {"id": 3, "name": "Date", "parent": 1, "text": \(clock), "color": {"user": "textcolor", "value": "1 1 1"}},
               {"id": 4, "name": "Butterflies", "particle": "particles/b.json", "visible": {"user": "clock", "value": true}},
               {"id": 5, "name": "Sky", "image": "models/sky.json", "color": {"user": "textcolor", "value": "1 1 1"}}]}
            """.utf8).write(to: folder.appending(path: "scene.json"))
        let project = try SceneProject(json: try SceneJSON(data: Data("""
            {"file": "scene.json", "general": {"properties": {
              "showtime": {"text": "Show it", "type": "bool", "value": true},
              "clock": {"text": "Butterflies", "type": "bool", "value": true},
              "fmt": {"text": "<small>24 Hour Format</small>", "type": "bool", "value": false},
              "seconds": {"text": "With dots", "type": "bool", "value": false, "condition": "showtime.value == true"},
              "textcolor": {"text": "Color", "type": "color", "value": "1 1 1"}}}}
            """.utf8), name: "project.json"))
        let hidden = project.liveSettings(files: try SceneFiles(folder: folder))
        #expect(hidden == ["showtime", "fmt", "seconds"])
    }
}
