import AppKit
import SwiftUI

/// Renders every screen with sample data to PNGs, for checking the UI without opening a window:
///   AerialSwap --snapshot <outDir> [footageDir]
/// Uses the test clips in TestFootage/ as stand-ins for Aerials and library items. Never touches the aerials folder,
/// the library or the temp folder.
@MainActor
enum Snapshot {
    static func run(_ args: [String]) async -> Int32 {
        guard args.count >= 2 else { print("usage: AerialSwap --snapshot <outDir> [footageDir]"); return 2 }
        let out = URL(fileURLWithPath: args[1], isDirectory: true)
        let footage = URL(fileURLWithPath: args.count > 2 ? args[2] : "TestFootage", isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        _ = NSApplication.shared

        let model = AppModel(snapshot: true)
        await fill(model, footage: footage)

        let scenes: [(String, (AppModel) async -> Void)] = [
            ("01-intro", { $0.showIntro = true }),
            ("02-library", { m in
                m.showIntro = false
                m.selectedLibraryID = m.libraryItems[1].id
            }),
            ("04b-library-playing", { m in m.selectedLibraryID = m.libraryItems[0].id }),   // already on the desktop
            ("04c-discover", { m in
                m.section = .discover
                m.selectedDiscoverID = m.discoverVideos[2].id
            }),
            ("04d-url-import", { m in
                m.section = .library
                m.urlImportText = "https://www.youtube.com/watch?v=aqz-KE-bpKQ"
                m.urlImportStart = "1:30"; m.urlImportEnd = "1:45"
                m.showURLImport = true
            }),
            ("05-configure", { m in
                m.showURLImport = false
                await load(m, footage.appending(path: "scene_1080p30.mov"))
                m.displayName = "Mountain clouds"
                m.trimStart = min(2, m.trimEnd / 5); m.trimEnd *= 0.85
                m.playhead = (m.trimStart + m.trimEnd) / 2
            }),
            ("06-configure-enhance", { $0.enhanceDetail = true }),
            ("07-low-resolution", { m in
                await load(m, footage.appending(path: "src_low30.mov"))
                m.resolutionPreview = await ResolutionPreview.make(url: footage.appending(path: "src_low30.mov"),
                                                                   screenPixels: CGSize(width: 3024, height: 1964), backingScale: 1)
                m.showResolutionAlert = true
            }),
            ("08-working", { m in
                m.showResolutionAlert = false
                await load(m, footage.appending(path: "scene_1080p30.mov"))
                m.workFlow = .newVideo; m.showsProgress = true; m.isBusy = true
                m.workStep = .prepare; m.progress = 0.46; m.phase = "Preparing your video in 4K"
            }),
            ("09-success", { m in
                m.workFlow = nil; m.showsProgress = false; m.isBusy = false
                m.sourceURL = nil; m.sourceInfo = nil
                m.done = DoneInfo(assetID: "lib0", role: "Desktop & Screen Saver", videoName: "Lofoten fjord",
                                  took: 114, summary: "60 fps · Smooth · Loop", savedToLibrary: true)
            }),
            ("10-toast", { m in
                m.done = nil
                m.notice = Notice(kind: .success, text: "“Sonoma Horizon” is now your screen saver.")
            }),
        ]
        for (name, setup) in scenes {
            await setup(model)
            guard let image = render(model),
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                print("could not render \(name)"); return 1
            }
            let file = out.appending(path: "\(name).png")
            do { try png.write(to: file) } catch { print("error: \(error.localizedDescription)"); return 1 }
            print("wrote \(file.path)")
        }
        return 0
    }

    private static func render(_ model: AppModel) -> CGImage? {
        // ImageRenderer draws Liquid Glass only when the view also has an AppKit-backed control in it, so a hidden
        // text field is added. (Without one, every glass panel, button and the toolbar are missing.)
        let content = ContentView(model: model)
            .background(alignment: .topLeading) { TextField("", text: .constant("")).frame(width: 1, height: 1).opacity(0.01) }
            .frame(width: 1180, height: 760)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2   // Retina, like the real window
        return renderer.cgImage
    }

    private static func frame(_ url: URL, large: Bool) async -> NSImage? {
        let size = large ? CGSize(width: 1920, height: 1080) : CGSize(width: 480, height: 270)
        guard let cg = await WallpaperLibrary.middleFrame(of: url, maxSize: size) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private static func load(_ model: AppModel, _ url: URL) async {
        guard let info = try? await Transcoder.inspect(url) else { print("cannot read \(url.path)"); return }
        model.sourceURL = url
        model.displayName = url.deletingPathExtension().lastPathComponent
        model.sourceInfo = info
        model.trimStart = 0; model.trimEnd = info.duration
        model.motionMode = model.availableMotionModes.contains(.smooth) ? .smooth : .original
        model.enhanceDetail = false
        model.backdrops["source"] = await frame(url, large: true)
        var strip: [NSImage] = []
        for _ in 0..<12 { if let f = model.backdrops["source"] { strip.append(f) } }
        model.filmstrip = strip
    }

    private static func fill(_ model: AppModel, footage: URL) async {
        let date = Date.now.addingTimeInterval(-6 * 86_400)
        // Apple's Aerials, plus the first library item as our group's wallpaper on the desktop.
        let samples: [(id: String, name: String, file: String, own: Bool)] = [
            ("lib0", "Lofoten fjord", "scene_2160p30.mov", true),
            ("sonoma", "Sonoma Horizon", "src_2160p24.mov", false),
            ("iceland", "Iceland", "hdr_hlg2160.mov", false),
            ("hawaii", "Hawaii", "src_2160p60.mov", false),
            ("earth", "Africa & Middle East", "src_wide24.mov", false),
        ]
        for s in samples {
            let url = footage.appending(path: s.file)
            let asset = AerialAsset(id: s.id, name: s.name, manifestURL: nil, videoURL: url, thumbnailURL: url, isOwn: s.own)
            model.assets.append(asset)
            model.backdrops[model.backdropKey(for: asset)] = await frame(url, large: true)
        }
        model.desktopID = "lib0"
        model.idleID = "sonoma"

        let items: [(String, String)] = [
            ("Lofoten fjord", "scene_2160p30.mov"), ("Patagonia ridge", "scene_1080p30.mov"),
            ("Misty forest", "src_1080p24.mov"), ("Svalbard glacier", "scene_720p30.mov"),
            ("Night over Lisbon", "hdr_hlg1080.mov"), ("Kyoto evening", "src_2160p120.mov"),
        ]
        for (index, (name, file)) in items.enumerated() {
            let url = footage.appending(path: file)
            let item = LibraryItem(id: "lib\(index)", name: name, addedAt: date.addingTimeInterval(Double(-index) * 86_400),
                                   duration: 28 + Double(index) * 4, bytes: 96_000_000 + Int64(index) * 31_000_000,
                                   fps: 60, motion: "Smooth", enhanced: index == 5, smoothLoop: true)
            model.libraryItems.append(item)
            model.libraryThumbnails[item.id] = await frame(url, large: false)
            model.backdrops["lib-\(item.id)"] = await frame(url, large: true)
        }

        let discover: [(String, String, Int)] = [
            ("mountains, lake, sunrise", "scene_2160p30.mov", 3840), ("ocean, waves, beach", "src_2160p24.mov", 3840),
            ("clouds, sky, timelapse", "scene_1080p30.mov", 3840), ("forest, fog, trees", "src_1080p24.mov", 1920),
            ("city, night, lights", "hdr_hlg1080.mov", 3840), ("earth, space, planet", "src_2160p60.mov", 3840),
            ("aerial, coast, cliffs", "src_wide24.mov", 3840), ("desert, dunes, sand", "src_1080p30.mov", 1920),
            ("river, valley, drone", "src_2160p30.mov", 3840),
        ]
        for (index, (tags, file, width)) in discover.enumerated() {
            let url = footage.appending(path: file)
            let large = DiscoverVideo.File(url: "https://example.invalid/\(index).mp4", width: width, height: width * 9 / 16,
                                           size: 40_000_000 + Int64(index) * 17_000_000)
            let medium = DiscoverVideo.File(url: "", width: 1920, height: 1080, size: 0)
            let video = DiscoverVideo(id: 1000 + index, pageURL: "https://pixabay.com/videos/id-\(1000 + index)/", tags: tags,
                                      duration: 12 + Double(index) * 3, videos: .init(large: large, medium: medium, small: medium, tiny: medium),
                                      user: "Photographer\(index)")
            model.discoverVideos.append(video)
            model.discoverThumbnails[video.id] = await frame(url, large: false)
            model.backdrops["discover-\(video.id)"] = await frame(url, large: true)
        }
        model.discoverTotal = 240
    }
}
