import AppKit
import Observation
import SceneEngine

/// A scene being set up in Configure: its properties as the user changes them, the frame rate, and the live preview.
@MainActor @Observable
final class SceneSetup {
    let scene: WorkshopScene
    let verdict: SceneVerdict
    /// The wallpaper's own settings (its project.json properties).
    let properties: [SceneProject.Property]
    let defaults: [String: SceneJSON]
    /// The current values, by property ID.
    private(set) var values: [String: SceneJSON]
    var fps = 60
    /// How the scene fills the screen (the main display's shape); the preview shows it without restarting.
    var framing = SceneFraming(screenAspect: SceneSetup.screenAspect)
    /// The longest animation's cycle (SceneDocument.animationLength) when it's longer than a loop chosen by itself:
    /// then the user can choose the part of it to loop.
    let animationLength: Double?
    /// A loop chosen by itself (10–30 s), or the part of the animation in `part`.
    var choosesPart = false { didSet { if choosesPart != oldValue { scheduleRestart() } } }
    var part: ClosedRange<Double> = 0 ... 1 { didSet { if part != oldValue, choosesPart { scheduleRestart() } } }
    /// Where in the scene the preview's newest frame is (seconds).
    private(set) var playhead: Double?
    /// The newest preview frame, and why the preview stopped when it did.
    var frame: NSImage?   // set by the preview (and Snapshot)
    /// A preview frame for the window's blurred background, renewed every few seconds (blurring the whole window costs
    /// more than showing a frame); nil uses `frame`.
    private(set) var backdrop: NSImage?
    @ObservationIgnored private var backdropTime = Date.distantPast
    private(set) var previewProblem: String?

    @ObservationIgnored private let preview = ScenePreviewProcess()
    @ObservationIgnored private var restart: Task<Void, Never>?
    @ObservationIgnored private var isPreviewing = false

    static let frameRates = [60, 120]

    /// The main display's width / height (the wallpaper fills it, cutting the video to that shape).
    static var screenAspect: Double {
        guard let size = NSScreen.screens.first?.frame.size, size.width > 0, size.height > 0 else { return 16.0 / 9 }
        return size.width / size.height
    }

    /// Whether the scene, filling the screen, is cut left and right (true) or top and bottom (false); nil when it fits
    /// the screen as is or its shape isn't known yet (it comes with the first preview frame).
    var cutsSides: Bool? {
        guard let size = frame?.size, size.width > 0, size.height > 0, let screen = framing.screenAspect else { return nil }
        let aspect = size.width / size.height
        guard abs(aspect / screen - 1) > 0.01 else { return nil }
        return aspect > screen
    }

    /// `hidden`: settings left out because a video can't honor them (SceneProject.liveSettings: clocks, now playing).
    init(scene: WorkshopScene, project: SceneProject, verdict: SceneVerdict, hidden: Set<String> = [],
         animationLength: Double? = nil) {
        self.scene = scene
        self.verdict = verdict
        let length = animationLength.map { min($0, SceneChildOptions.maxPart) }
        self.animationLength = length.flatMap { $0 > 30 ? $0 : nil }
        if let length = self.animationLength { part = 0 ... length }
        properties = project.properties.filter { Self.isEditable($0) && !hidden.contains($0.id) }
        defaults = project.values
        values = project.values
    }

    /// Text and the kinds AerialSwap can't use (files, shortcuts, …) aren't offered.
    private static func isEditable(_ property: SceneProject.Property) -> Bool {
        switch property.kind {
        case .color, .slider, .toggle: true
        case .choice(let options): !options.isEmpty
        case .text, .other: false
        }
    }

    /// The properties the wallpaper's settings show with the current values (some only show when others are on).
    var visibleProperties: [SceneProject.Property] { properties.filter { $0.isShown(values: values) } }

    /// Values that differ from the wallpaper's own: what the preview and the video are made with.
    var changes: [String: SceneJSON] { values.filter { defaults[$0.key] != $0.value } }

    var isChanged: Bool { !changes.isEmpty }

    /// The part to loop (start, length), when the user chose one.
    var chosenPart: (start: Double, length: Double)? {
        guard choosesPart, animationLength != nil else { return nil }
        return (part.lowerBound, max(1, part.upperBound - part.lowerBound))
    }

    func set(_ id: String, _ value: SceneJSON) {
        guard values[id] != value else { return }
        values[id] = value
        scheduleRestart()
    }

    func reset() {
        guard isChanged else { return }
        values = defaults
        scheduleRestart()
    }

    // MARK: Preview

    func startPreview() {
        isPreviewing = true
        previewProblem = nil
        playhead = nil
        preview.start(folder: scene.folder, properties: changes, part: chosenPart,
                      frame: { [weak self] image, time in
                          guard let self, self.isPreviewing else { return }
                          self.frame = image
                          self.playhead = time
                          if -self.backdropTime.timeIntervalSinceNow > 2 {
                              self.backdrop = image
                              self.backdropTime = .now
                          }
                      },
                      failed: { [weak self] text in
                          guard let self, self.isPreviewing else { return }
                          self.previewProblem = text
                          Log.error("Scene preview: \(text)")
                      })
    }

    func stopPreview() {
        isPreviewing = false
        restart?.cancel()
        preview.stop()
    }

    /// The preview starts over with the new values once the user pauses (a dragged slider changes many times).
    private func scheduleRestart() {
        restart?.cancel()
        guard isPreviewing else { return }
        restart = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self, self.isPreviewing else { return }
            self.startPreview()
        }
    }
}

extension SceneJSON {
    /// A color property's value ("r g b", 0–1) as a color, and back.
    var sceneColor: NSColor? {
        guard let v = vector, v.count >= 3 else { return nil }
        let scale = v.prefix(3).max()! > 1 ? 255.0 : 1   // some wallpapers write 0–255
        let c = v.map { min(max($0 / scale, 0), 1) }
        return NSColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: 1)
    }

    init(sceneColor color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? color
        let parts = [c.redComponent, c.greenComponent, c.blueComponent].map { String(format: "%.5f", Double($0)) }
        self = .string(parts.joined(separator: " "))
    }
}
