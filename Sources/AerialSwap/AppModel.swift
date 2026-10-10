import AppKit
import AVKit

/// How motion is prepared: as recorded, or with generated in-between frames (see FrameInterpolator).
enum MotionMode: String, CaseIterable, Identifiable {
    case original, smooth, maximum
    var id: String { rawValue }
    var label: String {
        switch self {
        case .original: "Original"
        case .smooth: "Smooth · 60 fps"
        case .maximum: "Maximum · 120 fps"
        }
    }
}

/// A message shown in the bottom bar.
struct Notice: Equatable {
    enum Kind { case info, success, error }
    var kind: Kind
    var text: String
}

/// UI state and actions. All Apple-store writes go through AerialStore.
/// Transient UI state lives here too, because @State needs the SwiftUI macro plugin, which only ships with Xcode.
@MainActor @Observable
final class AppModel {
    let store = AerialStore()
    let library = WallpaperLibrary()

    // Source (sourceURL may be an ffmpeg-converted temp file; displayName is the user's original file name)
    var sourceURL: URL?
    var displayName: String?
    var sourceInfo: SourceInfo?
    var player: AVPlayer?
    @ObservationIgnored weak var playerView: AVPlayerView?
    private var convertedTempURL: URL?

    // Target
    var assets: [AerialAsset] = []
    var statuses: [String: AerialStatus] = [:]
    var thumbnails: [String: NSImage] = [:]
    @ObservationIgnored private var thumbnailKeys: [String: String] = [:]   // what each cached thumbnail shows
    var selectedID: String?
    var selectionNote = ""

    // Library of finished wallpapers (shown while no new video is loaded)
    var libraryItems: [LibraryItem] = []
    var libraryThumbnails: [String: NSImage] = [:]
    var selectedLibraryID: String?
    var hoveredLibraryID: String?
    var deleteCandidate: LibraryItem?
    @ObservationIgnored private var didImportLegacy = false

    // Options (output fps is chosen automatically from the source, see Transcoder.autoFPS)
    var trimStart = 0.0
    var trimEnd = 0.0
    var smoothLoop = true             // crossfade the end into the start (see Transcoder)
    var motionMode = MotionMode.smooth

    // Progress
    var isBusy = false
    var showsProgress = false         // a long-running transcode/conversion (vs. a quick install/restore)
    var phase = ""
    var progress = 0.0
    var progressStarted = Date.now
    var notice: Notice?
    private var transcodedURL: URL?
    private var transcoder: Transcoder?
    private var converter: FFmpegConverter?

    // Transient UI state
    var pendingConversion: URL?       // unreadable file waiting for the user's OK to convert with ffmpeg
    var conversionPrompt = ""
    var showImporter = false
    var confirmSetWallpaper = false
    var restoreCandidate: AerialAsset?
    var isDropTargeted = false
    var hoveredAssetID: String?

    var selectedAsset: AerialAsset? { assets.first { $0.id == selectedID } }
    var isTrimmed: Bool { sourceInfo.map { trimStart > 0.01 || trimEnd < $0.duration - 0.01 } ?? false }
    /// 60 for normal video, the source rate for real 120/240 fps footage, 120 for Maximum smoothness.
    var outputFPS: Int {
        let auto = Transcoder.autoFPS(forSource: sourceInfo?.fps ?? 60)
        return effectiveMotionMode == .maximum ? max(auto, 120) : auto
    }
    static let loopCrossfade = 1.0
    var canSmoothLoop: Bool { trimEnd - trimStart >= 3 * Self.loopCrossfade }
    /// Motion choices that make sense for this source (same 0.85 rule as the Transcoder); empty = no choice.
    var availableMotionModes: [MotionMode] {
        guard let fps = sourceInfo?.fps, fps > 0, FrameInterpolator.isSupported else { return [] }
        var modes: [MotionMode] = [.original]
        if Double(fps) < 60 * 0.85 { modes.append(.smooth) }
        if Double(fps) < 120 * 0.85 { modes.append(.maximum) }
        return modes.count > 1 ? modes : []
    }
    var effectiveMotionMode: MotionMode { availableMotionModes.contains(motionMode) ? motionMode : .original }
    var interpolates: Bool { effectiveMotionMode != .original }
    var selectedLibraryItem: LibraryItem? { libraryItems.first { $0.id == selectedLibraryID } }
    /// "Set as Wallpaper" installs the selected library item when no new video is loaded.
    var isUsingLibrary: Bool { sourceURL == nil && selectedLibraryItem != nil }
    var canSetWallpaper: Bool { !isBusy && selectedAsset != nil && (sourceInfo != nil || isUsingLibrary) }
    var libraryBytes: Int64 { libraryItems.reduce(0) { $0 + $1.bytes } }

    init() {
        Self.removeWorkDir()   // leftovers from a crash or a force quit
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
        // Statuses can change while we're in the background (macOS may reset a file), so refresh on activation.
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.isBusy == false { self?.refreshAssets() } }
        }
    }

    // MARK: - Target

    func refreshAssets() {
        do {
            assets = try store.listAssets()
            statuses = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, store.status(of: $0)) })
            refreshLibrary()
            for asset in assets { updateThumbnail(for: asset) }
            importLegacyInstallsIfNeeded()
            if selectedID == nil || !assets.contains(where: { $0.id == selectedID }) {
                let detected = store.detectSelection()
                if let id = detected.desktop, assets.contains(where: { $0.id == id }) {
                    selectedID = id; selectionNote = "Your current desktop wallpaper is preselected."
                } else if let id = detected.idle, assets.contains(where: { $0.id == id }) {
                    selectedID = id; selectionNote = "Your current screen saver is preselected."
                } else {
                    selectedID = assets.first?.id; selectionNote = ""
                }
            }
        } catch {
            fail(error)
        }
    }

    /// Apple's thumbnail for original Aerials; a frame of the user's video for replaced ones.
    private func updateThumbnail(for asset: AerialAsset) {
        var key = "apple"
        var video: URL?
        var saved: URL?
        if case .replaced(_, let date, _) = statuses[asset.id] ?? .original {
            key = "installed-\(date.timeIntervalSince1970)"
            if let id = store.libraryID(of: asset), let item = libraryItems.first(where: { $0.id == id }) {
                saved = library.thumbnailURL(item)
            }
            let copy = store.installedCopyURL(for: asset.id)
            video = FileManager.default.fileExists(atPath: copy.path) ? copy : asset.videoURL
        }
        guard thumbnailKeys[asset.id] != key else { return }
        thumbnailKeys[asset.id] = key
        let appleThumbnail = NSImage(contentsOf: asset.thumbnailURL)
        if let saved, let image = NSImage(contentsOf: saved) { thumbnails[asset.id] = image; return }
        guard let video else { thumbnails[asset.id] = appleThumbnail; return }
        Task {
            let frame = await WallpaperLibrary.middleFrame(of: video)
            guard thumbnailKeys[asset.id] == key else { return }   // status changed meanwhile
            thumbnails[asset.id] = frame.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
                ?? appleThumbnail
        }
    }

    // MARK: - Library

    func refreshLibrary() {
        libraryItems = library.load()
        for item in libraryItems where libraryThumbnails[item.id] == nil {
            libraryThumbnails[item.id] = NSImage(contentsOf: library.thumbnailURL(item))
        }
        if let id = selectedLibraryID, !libraryItems.contains(where: { $0.id == id }) { selectedLibraryID = nil }
    }

    func selectLibraryItem(_ item: LibraryItem) {
        guard !isBusy else { return }
        selectedLibraryID = selectedLibraryID == item.id ? nil : item.id   // click again to deselect
    }

    /// Names of the Aerials currently playing this library item.
    func playingAerials(for item: LibraryItem) -> [String] {
        assets.filter { asset in
            if case .replaced = statuses[asset.id] ?? .original { return store.libraryID(of: asset) == item.id }
            return false
        }.map(\.name)
    }

    func deleteLibraryItem(_ item: LibraryItem) {
        do {
            try library.remove(item)
            libraryThumbnails[item.id] = nil
            notice = Notice(kind: .info, text: "“\(item.name)” was removed from your library.")
        } catch {
            fail(error)
        }
        refreshLibrary()
    }

    func revealLibrary() {
        let dir = library.directory
        NSWorkspace.shared.activateFileViewerSelecting([FileManager.default.fileExists(atPath: dir.path) ? dir : store.supportDir])
    }

    /// Installs from before the library existed have a Reinstall copy; import it once so it shows up.
    private func importLegacyInstallsIfNeeded() {
        guard !didImportLegacy, !library.exists else { return }
        didImportLegacy = true
        let candidates = assets.compactMap { asset -> (AerialAsset, InstallRecord, URL)? in
            let copy = store.installedCopyURL(for: asset.id)
            guard let record = store.loadState()[asset.id], record.libraryID == nil,
                  FileManager.default.fileExists(atPath: copy.path) else { return nil }
            return (asset, record, copy)
        }
        Task {
            for (asset, record, copy) in candidates {
                do {
                    let item = try await library.add(copy, name: record.sourceName)
                    try store.setLibraryID(item.id, for: asset)
                } catch {
                    Log.error("Library import of \(record.sourceName) failed: \(error.localizedDescription)")
                }
            }
            try? library.createIfMissing()
            refreshLibrary()
            thumbnailKeys.removeAll()          // let replaced cards pick up the saved thumbnails
            for asset in assets { updateThumbnail(for: asset) }
        }
    }

    func select(_ asset: AerialAsset) {
        guard !isBusy else { return }
        selectedID = asset.id
    }

    // MARK: - Source

    /// Loads a user-chosen file. If macOS can't read it, offers an ffmpeg conversion instead.
    func loadSource(_ url: URL, displayName: String? = nil) {
        guard !isBusy else { return }
        if displayName == nil, let old = convertedTempURL {
            try? FileManager.default.removeItem(at: old)   // a new user file replaces the last conversion
            convertedTempURL = nil
        }
        sourceURL = url
        self.displayName = displayName ?? url.lastPathComponent
        sourceInfo = nil
        transcodedURL = nil
        if notice?.kind != .success { notice = nil }
        player = nil
        Task {
            do {
                let info = try await Transcoder.inspect(url)
                sourceInfo = info
                trimStart = 0
                trimEnd = info.duration
                // Smooth by default when it's cheap enough to matter; 60 fps sources stay as recorded.
                motionMode = availableMotionModes.contains(.smooth) ? .smooth : .original
                let player = AVPlayer(url: url)
                player.isMuted = true   // the wallpaper has no sound either
                self.player = player
                player.play()
            } catch {
                handleUnreadable(url, error)
            }
        }
    }

    func clearSource() {
        guard !isBusy else { return }
        player?.pause()
        player = nil; sourceURL = nil; sourceInfo = nil; displayName = nil
        if let old = convertedTempURL { try? FileManager.default.removeItem(at: old); convertedTempURL = nil }
    }

    private func handleUnreadable(_ url: URL, _ error: Error) {
        sourceURL = nil
        let reason = error.localizedDescription
        Log.error("Cannot read \(url.path): \(reason)")
        guard let ffmpeg = FFmpeg.find() else {
            notice = Notice(kind: .error, text: "macOS can't read “\(url.lastPathComponent)”. Convert it to MP4 (H.264 or HEVC), "
                + "or install ffmpeg (brew install ffmpeg) so AerialSwap can convert it for you.")
            return
        }
        pendingConversion = url
        conversionPrompt = "macOS can't play “\(url.lastPathComponent)” directly (\(reason)).\n\n"
            + "AerialSwap can convert it with ffmpeg (\(ffmpeg.path)) first. This takes roughly as long as the "
            + "video, needs a few GB of temporary disk space and drops the audio."
    }

    /// Runs the ffmpeg conversion the user agreed to, then loads the result as the source.
    func convertPending() {
        guard let source = pendingConversion, let ffmpeg = FFmpeg.find() else { return }
        pendingConversion = nil
        let destination = Self.workDir().appending(path: "converted-\(UUID().uuidString).mov")
        let converter = FFmpegConverter()
        self.converter = converter
        transcodedURL = nil
        startProgress("Converting “\(source.lastPathComponent)” with ffmpeg")

        Task.detached {
            do {
                try await converter.run(ffmpeg: ffmpeg, source: source, destination: destination) { p in
                    Task { @MainActor in self.progress = p }
                }
                await MainActor.run {
                    self.stopProgress()
                    if let old = self.convertedTempURL { try? FileManager.default.removeItem(at: old) }
                    self.convertedTempURL = destination
                    self.loadSource(destination, displayName: source.lastPathComponent)
                    self.notice = Notice(kind: .info, text: "Converted. Trim if you like, then set it as your wallpaper.")
                }
            } catch {
                await MainActor.run {
                    self.stopProgress()
                    if case ConvertError.cancelled = error { self.notice = Notice(kind: .info, text: "Conversion cancelled.") }
                    else { self.fail(error) }
                }
            }
        }
    }

    // MARK: - Trim

    /// Opens AVKit's QuickTime-style trim bar on the preview; the result becomes the clip range.
    func beginTrim() {
        guard let view = playerView, let item = player?.currentItem, let info = sourceInfo else { return }
        // Start the trim bar from the current range.
        item.reversePlaybackEndTime = trimStart > 0 ? CMTime(seconds: trimStart, preferredTimescale: 600) : .invalid
        item.forwardPlaybackEndTime = trimEnd < info.duration ? CMTime(seconds: trimEnd, preferredTimescale: 600) : .invalid
        guard view.canBeginTrimming else {
            notice = Notice(kind: .info, text: "Trimming isn't available yet. Wait until the preview has loaded.")
            return
        }
        player?.pause()
        Task {
            guard await view.beginTrimming() == .okButton else { return }
            let start = item.reversePlaybackEndTime, end = item.forwardPlaybackEndTime
            trimStart = start.isNumeric ? max(0, start.seconds) : 0
            trimEnd = end.isNumeric ? min(info.duration, end.seconds) : info.duration
        }
    }

    func resetTrim() {
        guard let info = sourceInfo else { return }
        trimStart = 0; trimEnd = info.duration
        player?.currentItem?.reversePlaybackEndTime = .invalid
        player?.currentItem?.forwardPlaybackEndTime = .invalid
    }

    // MARK: - Set as wallpaper

    /// Rough duration estimate for the confirmation: ~1.15x real time at 60 fps, scaling with fps,
    /// plus ~70 ms per generated 4K frame for Smooth motion (measured on Apple Silicon).
    var estimateText: String {
        let length = max(1, trimEnd - trimStart)
        var seconds = length * Double(outputFPS) / 60 * 1.15
        if interpolates, let fps = sourceInfo?.fps {
            seconds += length * max(0, Double(outputFPS) - Double(fps)) * 0.07
        }
        return seconds < 90 ? "about \(Int(seconds.rounded())) seconds" : "about \(Int((seconds / 60).rounded())) minutes"
    }

    var remainingText: String {
        let elapsed = Date.now.timeIntervalSince(progressStarted)
        guard progress > 0.03, elapsed > 3 else { return "Estimating…" }
        let left = elapsed * (1 - progress) / progress
        return left < 90 ? "\(Int(left)) s left" : "\(Int((left / 60).rounded())) min left"
    }

    private func startProgress(_ text: String) {
        isBusy = true; showsProgress = true
        progress = 0; progressStarted = .now
        phase = text; notice = nil
    }

    private func stopProgress() {
        isBusy = false; showsProgress = false; phase = ""
    }

    /// Called after the user confirmed: installs the selected library item, or prepares the new video.
    func setAsWallpaper() {
        if isUsingLibrary, let item = selectedLibraryItem, let asset = selectedAsset {
            isBusy = true; notice = nil
            install(library.videoURL(item), name: item.name, libraryID: item.id, over: asset)
            return
        }
        transcodeAndInstall()
    }

    /// Transcodes the source, saves it to the library, then installs it over the selected Aerial.
    private func transcodeAndInstall() {
        guard let source = sourceURL, let info = sourceInfo, let asset = selectedAsset else { return }
        let options = TranscodeOptions(fps: outputFPS, trimStart: trimStart,
                                       trimEnd: trimEnd < info.duration ? trimEnd : nil,
                                       loopCrossfade: canSmoothLoop && smoothLoop ? Self.loopCrossfade : 0,
                                       interpolate: interpolates)
        let destination = Self.workDir().appending(path: "\(UUID().uuidString).mov")
        let transcoder = Transcoder()
        self.transcoder = transcoder
        if let old = transcodedURL { try? FileManager.default.removeItem(at: old) }
        transcodedURL = nil
        player?.pause()
        startProgress("Preparing your video in 4K")

        Task.detached {
            do {
                try await transcoder.run(source: source, destination: destination, options: options) { p in
                    Task { @MainActor in self.progress = p }
                }
                await MainActor.run {
                    self.transcodedURL = destination
                    self.saveAndInstall(destination, over: asset)
                }
            } catch {
                await MainActor.run {
                    self.stopProgress()
                    try? FileManager.default.removeItem(at: destination)
                    if case TranscodeError.cancelled = error { self.notice = Notice(kind: .info, text: "Cancelled. Nothing was changed.") }
                    else { self.fail(error) }
                }
            }
        }
    }

    func cancel() {
        transcoder?.cancel()
        converter?.cancel()
    }

    /// Keeps the finished video in the library (non-fatal if that fails), then installs it.
    private func saveAndInstall(_ file: URL, over asset: AerialAsset) {
        let name = displayName ?? "your video"
        showsProgress = false; phase = "Saving to your library"
        Task {
            do {
                let item = try await library.add(file, name: name)
                install(library.videoURL(item), name: name, libraryID: item.id, over: asset)
            } catch {
                Log.error("Could not save to library: \(error.localizedDescription)")
                install(file, name: name, libraryID: nil, over: asset)
            }
        }
    }

    private func install(_ file: URL, name: String, libraryID: String?, over asset: AerialAsset) {
        showsProgress = false; phase = "Installing"
        Task {
            do {
                try await store.install(file, sourceName: name, over: asset, protect: false, libraryID: libraryID)
                removeTempFilesAfterInstall()
                selectedLibraryID = nil
                notice = Notice(kind: .success, text: "“\(asset.name)” now plays “\(name)”. Lock your Mac to see it.")
            } catch {
                fail(error)
            }
            stopProgress()
            refreshAssets()
        }
    }

    /// Puts our last installed video back after macOS reset the file.
    func reinstall(_ asset: AerialAsset) {
        isBusy = true; phase = "Reinstalling"; notice = nil
        Task {
            do {
                try await store.reinstall(asset)
                notice = Notice(kind: .success, text: "Your video is back on “\(asset.name)”.")
            } catch {
                fail(error)
            }
            stopProgress()
            refreshAssets()
        }
    }

    func restore(_ asset: AerialAsset) {
        notice = nil
        do {
            try store.restore(asset)
            notice = Notice(kind: .success, text: "Apple's original “\(asset.name)” is back.")
        } catch {
            fail(error)
        }
        refreshAssets()
    }

    // MARK: - Finder helpers

    func revealBackups() {
        let dir = store.backupsDir
        NSWorkspace.shared.activateFileViewerSelecting([FileManager.default.fileExists(atPath: dir.path) ? dir : store.supportDir])
    }

    func openLog() {
        NSWorkspace.shared.open(Log.url)
    }

    // MARK: - Temp files

    /// Temp folder for ffmpeg intermediates and transcodes (can be several GB). Never inside the aerials folder.
    private static let workDirURL = FileManager.default.temporaryDirectory
        .appending(path: "AerialSwap", directoryHint: .isDirectory)

    private static func workDir() -> URL {
        try? FileManager.default.createDirectory(at: workDirURL, withIntermediateDirectories: true)
        return workDirURL
    }

    /// Stops running work (ffmpeg is a separate process and would outlive the app) and deletes temp files.
    private func shutdown() {
        cancel()
        Self.removeWorkDir()
    }

    private static func removeWorkDir() {
        guard FileManager.default.fileExists(atPath: workDirURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: workDirURL)
            Log.info("Removed temp folder \(workDirURL.path)")
        } catch {
            Log.error("Could not remove temp folder \(workDirURL.path): \(error.localizedDescription)")
        }
    }

    /// After a successful install the transcode and any ffmpeg intermediate are no longer needed.
    private func removeTempFilesAfterInstall() {
        if let file = transcodedURL { try? FileManager.default.removeItem(at: file) }
        transcodedURL = nil
        if let converted = convertedTempURL {
            try? FileManager.default.removeItem(at: converted)
            convertedTempURL = nil
            // The loaded source was that intermediate, so it is gone now.
            player = nil; sourceURL = nil; sourceInfo = nil; displayName = nil
        }
        Self.removeWorkDir()   // nothing in it is needed any more
    }

    private func fail(_ error: Error) {
        let text = error.localizedDescription
        notice = Notice(kind: .error, text: text)
        Log.error(text)
    }
}
