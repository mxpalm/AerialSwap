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
            ("02-now-playing", { m in m.showIntro = false; m.dismissedResetIDs = ["iceland"] }),
            ("03-reset", { m in m.dismissedResetIDs = [] }),
            ("04-library", { m in
                m.dismissedResetIDs = ["iceland"]
                m.section = .library
                m.selectedLibraryID = m.libraryItems[1].id
            }),
            ("04b-library-playing", { m in m.selectedLibraryID = m.libraryItems[0].id }),   // already on Tahoe Day
            ("04c-discover", { m in
                m.section = .discover
                m.selectedDiscoverID = m.discoverVideos[2].id
            }),
            ("04d-url-import", { m in
                m.section = .nowPlaying
                m.urlImportText = "https://www.youtube.com/watch?v=aqz-KE-bpKQ"
                m.urlImportStart = "1:30"; m.urlImportEnd = "1:45"
                m.showURLImport = true
            }),
            ("04e-role-move", { m in
                m.showURLImport = false
                m.section = .nowPlaying
                m.desktopID = "tahoe"; m.idleID = "tahoe"
                m.roleMove = RoleMove(role: .screenSaver, fromID: "tahoe", choiceID: "sonoma")
            }),
            ("05-configure", { m in
                m.roleMove = nil; m.idleID = "sonoma"
                await load(m, footage.appending(path: "scene_1080p30.mov"))
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
                m.done = DoneInfo(assetID: "tahoe", assetName: "Tahoe Day", videoName: "Dolomites drone",
                                  took: 114, summary: "60 fps · Smooth · Loop", savedToLibrary: true)
            }),
            ("10-toast", { m in
                m.done = nil
                m.notice = Notice(kind: .success, text: "Your video is back on “Iceland”.")
            }),
        ]
        for (name, setup) in scenes {
            await setup(model)
            let renderer = ImageRenderer(content: ContentView(model: model).frame(width: 1180, height: 760))
            renderer.scale = 1
            guard let image = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                print("could not render \(name)"); return 1
            }
            let file = out.appending(path: "\(name).png")
            do { try png.write(to: file) } catch { print("error: \(error.localizedDescription)"); return 1 }
            print("wrote \(file.path)")
        }
        return 0
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
        let samples: [(id: String, name: String, file: String, status: AerialStatus)] = [
            ("tahoe", "Tahoe Day", "scene_2160p30.mov", .replaced(sourceName: "Lofoten fjord", installedAt: date, protected: false)),
            ("sonoma", "Sonoma Horizon", "src_2160p24.mov", .original),
            ("iceland", "Iceland", "hdr_hlg2160.mov", .resetByMacOS),
            ("hawaii", "Hawaii", "src_2160p60.mov", .original),
            ("earth", "Africa & Middle East", "src_wide24.mov", .original),
        ]
        for s in samples {
            let url = footage.appending(path: s.file)
            let asset = AerialAsset(id: s.id, name: s.name, manifestURL: nil, videoURL: url, thumbnailURL: url)
            model.assets.append(asset)
            model.statuses[s.id] = s.status
            let thumb = await frame(url, large: false)
            model.thumbnails[s.id] = thumb
            model.appleThumbnails[s.id] = thumb
            model.backdrops[model.backdropKey(for: asset)] = await frame(url, large: true)
        }
        model.installRecords["tahoe"] = InstallRecord(installedAt: date, installedSize: 1, sourceName: "Lofoten fjord",
                                                      protected: false, libraryID: "lib0")
        model.installRecords["iceland"] = InstallRecord(installedAt: date, installedSize: 1, sourceName: "Svalbard glacier",
                                                        protected: false, libraryID: "lib3")
        model.reinstallableIDs = ["iceland"]
        model.backdrops["installed-iceland"] = await frame(footage.appending(path: "scene_720p30.mov"), large: true)
        model.desktopID = "tahoe"
        model.idleID = "sonoma"
        model.selectedID = "tahoe"

        let items: [(String, String)] = [
            ("Lofoten fjord", "scene_2160p30.mov"), ("Patagonia ridge", "scene_1080p30.mov"),
            ("Big Sur coast", "src_1080p24.mov"), ("Svalbard glacier", "scene_720p30.mov"),
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
