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

/// A message shown as a toast at the bottom of the window.
struct Notice: Equatable {
    enum Kind { case info, success, error }
    var kind: Kind
    var text: String
}

/// The full-window screens. Dialogs (success, low resolution) are overlays on top of these.
enum Screen { case intro, home, configure, working }

/// The sections of the home screen (the switcher in the top bar).
enum HomeSection { case library, discover }

/// Long-running work and which screen shows it.
enum WorkFlow { case download, tools, convert, newVideo, saveOnly, quick }

/// Installing missing helpers (yt-dlp, deno, ffmpeg) after the user agreed, and what to do once they're there.
struct ToolInstallRequest: Equatable {
    enum Then: Equatable { case reopenURLImport, convert(URL) }
    var tools: [Tool]
    var purpose: String        // "import videos from web pages", shown in the confirmation
    var then: Then
}

/// Steps of preparing a new video, in order (shown as pills on the working screen).
enum WorkStep: Int, Comparable {
    case download, convert, prepare, save, show
    static func < (a: WorkStep, b: WorkStep) -> Bool { a.rawValue < b.rawValue }
}

/// Shown in the success dialog over the Library after Set as Wallpaper.
struct DoneInfo: Equatable {
    var assetID: String
    var role: String               // "Desktop & Screen Saver", "Desktop", …; "" when no role could be switched and the
                                   // user has to pick it in System Settings
    var videoName: String
    var took: TimeInterval?        // nil when a library wallpaper was switched in seconds
    var summary: String?           // "60 fps · Smooth · Loop"
    var savedToLibrary: Bool
}

/// UI state and actions. All Apple-store writes go through AerialStore.
/// Transient UI state lives here too, because @State needs the SwiftUI macro plugin, which only ships with Xcode.
@MainActor @Observable
final class AppModel {
    let store = AerialStore()
    let library = WallpaperLibrary()
    let group = AerialGroup()
    @ObservationIgnored let isSnapshot: Bool   // rendering PNGs with sample data (--snapshot): no disk writes

    // Source (sourceURL may be an ffmpeg-converted temp file; displayName is the user's original file name)
    var sourceURL: URL?
    var displayName: String?
    var sourceInfo: SourceInfo?
    var player: AVPlayer?
    var isPreviewPlaying = false
    /// Where the preview is, in seconds; follows playback and the playhead drag.
    var playhead: Double = 0
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var scrubbing = false
    @ObservationIgnored private var playAfterScrub = false
    var filmstrip: [NSImage] = []
    private var convertedTempURL: URL?
    @ObservationIgnored private var loopObserver: NSObjectProtocol?

    // Aerials: Apple's and our group's (see AerialGroup)
    var assets: [AerialAsset] = []
    var desktopID: String?
    var idleID: String?
    @ObservationIgnored private var isSyncingGroup = false
    @ObservationIgnored private var groupSyncPending = false

    // Large frames for full-window backgrounds, keyed by backdropKey(for:), "lib-<id>", "source"
    var backdrops: [String: NSImage] = [:]
    @ObservationIgnored private var pendingBackdrops: Set<String> = []

    // Library of finished wallpapers
    var libraryItems: [LibraryItem] = []
    var libraryThumbnails: [String: NSImage] = [:]
    var selectedLibraryID: String?
    var deleteCandidate: LibraryItem?
    var librarySearch = ""
    @ObservationIgnored private var didCheckLibrary = false
    @ObservationIgnored private var didPreselect = false

    /// A newer release on GitHub (see UpdateChecker), offered in the ⚙ menu.
    var availableUpdate: AppUpdate?

    // Discover: free videos from Pixabay (see PixabayClient)
    let pixabay = PixabayClient()
    var discoverTopic = DiscoverTopic.all[0]
    var discoverSearch = ""               // what's typed; searched on Return
    var discoverQuery = ""                // the search the results are for ("" = the topic)
    var discoverVideos: [DiscoverVideo] = []
    var discoverThumbnails: [Int: NSImage] = [:]
    var discoverTotal = 0
    var isDiscoverLoading = false
    var discoverError: String?
    var selectedDiscoverID: Int?
    @ObservationIgnored private var discoverPage = 0
    @ObservationIgnored private var discoverRequest = 0   // newer requests win over slower older ones
    /// Set while the loaded source is a Pixabay download, so the library keeps the credit.
    @ObservationIgnored private var sourceCredit: DiscoverVideo?
    private var downloader: VideoDownloader?
    private var urlImporter: URLImporter?
    private var toolInstaller: ToolInstaller?
    /// Waiting for the user's OK to install helpers (the confirmation alert).
    var toolInstallRequest: ToolInstallRequest?
    /// Shown on the working screen while downloading: where from ("Pixabay", "youtube.com") and what happens.
    var downloadSource = ""
    var downloadDetail = ""

    // Options (output fps is chosen automatically from the source, see Transcoder.autoFPS)
    var trimStart = 0.0
    var trimEnd = 0.0
    var smoothLoop = true             // crossfade the end into the start (see Transcoder)
    var motionMode = MotionMode.smooth
    var enhanceDetail = false         // opt-in per video: ML upscaling for sources up to 1080p (see DetailEnhancer)

    // Progress
    var isBusy = false
    var showsProgress = false         // a long-running transcode/conversion (vs. a quick switch)
    var workFlow: WorkFlow?
    var workStep = WorkStep.prepare
    var phase = ""
    var progress = 0.0
    var progressStarted = Date.now
    @ObservationIgnored private var workStarted: Date?
    var notice: Notice?
    var done: DoneInfo?
    private var transcodedURL: URL?
    private var transcoder: Transcoder?
    private var converter: FFmpegConverter?

    // Transient UI state
    var showIntro: Bool
    var section = HomeSection.library
    var isPreviewingWallpaper = false   // the Library's panels are hidden for a clean look at the wallpaper
    var showsPreviewHandle = false
    var pendingConversion: URL?       // unreadable file waiting for the user's OK to convert with ffmpeg
    var conversionPrompt = ""
    var showImporter = false
    var confirmSetWallpaper = false
    var showResolutionAlert = false   // dialog right after choosing a very low-resolution video
    /// The low-resolution dialog's actual-size preview of the current video.
    var resolutionPreview: ResolutionPreview?
    var isDropTargeted = false
    /// The Add from URL dialog and what's typed in it.
    var showURLImport = false
    var urlImportText = ""
    var urlImportStart = ""               // optional part of the video, e.g. "1:00"
    var urlImportEnd = ""

    /// What the desktop shows: the window's background when no library wallpaper is picked.
    var desktopAsset: AerialAsset? { assets.first { $0.id == desktopID } }
    /// Where macOS shows this Aerial: "Desktop", "Screen Saver", "Desktop & Screen Saver", or nil when it isn't in use.
    func roleTitle(for id: String) -> String? {
        switch (id == desktopID, id == idleID) {
        case (true, true): "Desktop & Screen Saver"
        case (true, false): "Desktop"
        case (false, true): "Screen Saver"
        case (false, false): nil
        }
    }
    var screen: Screen {
        if showIntro { return .intro }
        switch workFlow {
        case .download, .tools, .convert, .newVideo, .saveOnly: return .working
        case .quick, nil: break
        }
        if sourceURL != nil { return .configure }
        return .home
    }
    var isTrimmed: Bool { sourceInfo.map { trimStart > 0.01 || trimEnd < $0.duration - 0.01 } ?? false }
    /// 60 for normal video, the source rate for real 120/240 fps footage, 120 for Maximum smoothness.
    var outputFPS: Int {
        let auto = Transcoder.autoFPS(forSource: sourceInfo?.fps ?? 60)
        return effectiveMotionMode == .maximum ? max(auto, 120) : auto
    }
    static let loopCrossfade = 1.0
    static let minimumClip = 1.0
    var canSmoothLoop: Bool { trimEnd - trimStart >= 3 * Self.loopCrossfade }
    /// Motion choices that make sense for this source (same 0.85 rule as the Transcoder); empty = no choice.
    var availableMotionModes: [MotionMode] {
        guard let fps = sourceInfo?.fps, fps > 0, FrameInterpolator.isSupported || isSnapshot else { return [] }
        var modes: [MotionMode] = [.original]
        if Double(fps) < 60 * 0.85 { modes.append(.smooth) }
        if Double(fps) < 120 * 0.85 { modes.append(.maximum) }
        return modes.count > 1 ? modes : []
    }
    var effectiveMotionMode: MotionMode { availableMotionModes.contains(motionMode) ? motionMode : .original }
    var interpolates: Bool { effectiveMotionMode != .original }
    /// Up to 1920x1080 in the stored orientation; upright phone videos (1080x1920 shown) are stored as 1920x1080.
    var canEnhance: Bool {
        guard let info = sourceInfo, DetailEnhancer.isSupported || isSnapshot else { return false }
        return (info.width <= 1920 && info.height <= 1080) || (info.width <= 1080 && info.height <= 1920)
    }
    var enhances: Bool { canEnhance && enhanceDetail }

    /// How much the video has to be enlarged to fill a 3840x2160 screen (aspect fill), e.g. 2.0 for 1080p.
    var upscaleFactor: Double? {
        guard let info = sourceInfo, info.width > 0, info.height > 0 else { return nil }
        return max(Double(Transcoder.width) / Double(info.width), Double(Transcoder.height) / Double(info.height))
    }

    /// A hint about the source resolution: nil for 1080p and above, mild up to ~3x, severe beyond.
    var resolutionHint: (severe: Bool, text: String)? {
        guard let info = sourceInfo, let factor = upscaleFactor, factor > 2.05 else { return nil }
        let size = "\(info.width)×\(info.height)"
        let times = factor.formatted(.number.precision(.fractionLength(factor < 10 ? 1 : 0)))
        if factor > 3 {
            return (true, "At \(size) it has to be enlarged about \(times)× to fill a 4K screen, so the wallpaper will "
                + "look blurry. A higher-quality version will look much sharper, or upscale it first with a tool "
                + "like Topaz Video AI or Video2X.")
        }
        return (false, "Below 4K quality: this \(size) video is enlarged about \(times)×, so fine detail will look "
            + "a little soft. A higher-resolution version would look sharper.")
    }

    var enhanceMinutes: Int {
        max(1, Int(((trimEnd - trimStart) * Double(sourceInfo?.fps ?? 30) * 1.25 / 60).rounded()))
    }
    /// Shown under the switch and in the confirmation: Enhance detail is slow and its benefit varies.
    var enhanceWarning: String {
        "About \(enhanceMinutes) min extra for this clip, with the Mac working hard. "
            + "Some videos look clearly sharper, others only slightly."
    }
    var selectedLibraryItem: LibraryItem? { libraryItems.first { $0.id == selectedLibraryID } }
    /// "Set as Wallpaper" uses the selected library item when no new video is loaded.
    var isUsingLibrary: Bool { sourceURL == nil && selectedLibraryItem != nil }
    var canSetWallpaper: Bool {
        !isBusy && (sourceInfo != nil || isUsingLibrary) && !(isUsingLibrary && isSelectedItemPlaying)
    }
    /// The chosen library wallpaper is already on the desktop, so using it again would change nothing.
    var isSelectedItemPlaying: Bool { selectedLibraryItem.map { $0.id == desktopID } ?? false }
    var libraryBytes: Int64 { libraryItems.reduce(0) { $0 + $1.bytes } }
    var filteredLibraryItems: [LibraryItem] {
        let query = librarySearch.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return libraryItems }
        return libraryItems.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    init(snapshot: Bool = false) {
        isSnapshot = snapshot
        showIntro = snapshot ? false : !UserDefaults.standard.bool(forKey: "didFinishIntro")
        guard !snapshot else { return }
        Self.removeWorkDir()   // leftovers from a crash or a force quit
        let pixabay = pixabay
        Task.detached(priority: .background) { pixabay.pruneCache() }
        Task {
            guard let update = try? await UpdateChecker.check() else { return }
            availableUpdate = update
            if notice == nil {
                notice = Notice(kind: .info, text: "AerialSwap \(update.version) is available. Get it from the ⚙ menu.")
            }
        }
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
        // Statuses can change while we're in the background (macOS may reset a file), so refresh on activation.
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.isBusy == false { self?.refreshAssets() } }
        }
        GroupWatcher.install()
        if GroupWatcher.isTranslocated {
            notice = Notice(kind: .error, text: "Move AerialSwap to your Applications folder and open it from there, "
                            + "so the AerialSwap group comes back after macOS updates its Aerials.")
        }
    }

    // MARK: - Intro

    func finishIntro() {
        showIntro = false
        if !isSnapshot { UserDefaults.standard.set(true, forKey: "didFinishIntro") }
    }

    func showIntroAgain() { showIntro = true }

    // MARK: - Aerials

    func refreshAssets() {
        guard !isSnapshot else { return }
        do {
            assets = try store.listAssets()
            refreshLibrary()
            syncGroup()
            repairLibraryIfNeeded()
            let detected = store.detectSelection()
            desktopID = detected.desktop.flatMap { id in assets.contains { $0.id == id } ? id : nil }
            idleID = detected.idle.flatMap { id in assets.contains { $0.id == id } ? id : nil }
            if let asset = desktopAsset { loadBackdrop(backdropKey(for: asset), from: asset.videoURL) }
            preselectPlayingItem()
        } catch {
            fail(error)
        }
    }

    func backdropKey(for asset: AerialAsset) -> String { "asset-\(asset.id)" }

    /// Loads a large frame of a video once; views read it from `backdrops`.
    func loadBackdrop(_ key: String, from url: URL) {
        guard backdrops[key] == nil, !pendingBackdrops.contains(key) else { return }
        pendingBackdrops.insert(key)
        Task {
            let frame = await WallpaperLibrary.middleFrame(of: url, maxSize: CGSize(width: 1920, height: 1080))
            pendingBackdrops.remove(key)
            if let frame { backdrops[key] = NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height)) }
        }
    }

    // MARK: - Library

    func refreshLibrary() {
        guard !isSnapshot else { return }
        libraryItems = library.load()
        for item in libraryItems where libraryThumbnails[item.id] == nil {
            libraryThumbnails[item.id] = NSImage(contentsOf: library.thumbnailURL(item))
        }
        if let id = selectedLibraryID, !libraryItems.contains(where: { $0.id == id }) { selectedLibraryID = nil }
    }

    /// On launch, picks the library wallpaper macOS shows, so the window opens on what's playing.
    private func preselectPlayingItem() {
        guard !didPreselect else { return }
        didPreselect = true
        guard selectedLibraryID == nil, let item = libraryItems.first(where: { $0.id == desktopID || $0.id == idleID }) else { return }
        selectLibraryItem(item)
    }

    /// Adds every library wallpaper to the AerialSwap group in System Settings (see AerialGroup), in the background.
    /// Runs again afterwards when asked while a sync is running, so the last library change always gets through.
    func syncGroup() {
        guard !isSnapshot else { return }
        guard !isSyncingGroup else { groupSyncPending = true; return }
        isSyncingGroup = true
        let group = group, items = libraryItems
        Task {
            do {
                let changed = try await Task.detached { try await group.sync(items) }.value
                if changed && !isBusy { refreshAssets() }
            } catch {
                Log.error("Group: \(error.localizedDescription)")
            }
            isSyncingGroup = false
            if groupSyncPending { groupSyncPending = false; syncGroup() }
        }
    }

    func selectLibraryItem(_ item: LibraryItem) {
        guard !isBusy else { return }
        selectedLibraryID = selectedLibraryID == item.id ? nil : item.id   // click again to deselect
        if selectedLibraryID != nil, !isSnapshot { loadBackdrop("lib-\(item.id)", from: library.videoURL(item)) }
        showBackgroundVideo()
    }

    /// Where macOS shows this library item: "Desktop", "Screen Saver", "Desktop & Screen Saver", or nil.
    func role(of item: LibraryItem) -> String? { roleTitle(for: item.id) }

    func deleteLibraryItem(_ item: LibraryItem) {
        if backgroundVideoKey == "lib-\(item.id)" { stopBackgroundVideo(immediately: true) }   // don't hold the file open
        do {
            try library.remove(item)
            libraryThumbnails[item.id] = nil
            notice = Notice(kind: .info, text: "“\(item.name)” was removed from your library.")
        } catch {
            fail(error)
        }
        refreshLibrary()
        syncGroup()
    }

    func revealLibrary() {
        let dir = library.directory
        NSWorkspace.shared.activateFileViewerSelecting([FileManager.default.fileExists(atPath: dir.path) ? dir : store.supportDir])
    }

    /// Rebuilds an unreadable library index from the videos in the folder (once per launch).
    private func repairLibraryIfNeeded() {
        guard !didCheckLibrary else { return }
        didCheckLibrary = true
        Task {
            guard let count = await library.repairIfNeeded() else { return }
            refreshLibrary()
            notice = Notice(kind: .error, text: "Your library's index was damaged. \(count) wallpaper(s) were recovered as "
                            + "“Recovered wallpaper”; the old index is kept in the library folder.")
        }
    }

    // MARK: - Discover

    var selectedDiscoverVideo: DiscoverVideo? { discoverVideos.first { $0.id == selectedDiscoverID } }
    /// Pixabay serves at most 500 results per search.
    var canLoadMoreDiscover: Bool { discoverVideos.count < min(discoverTotal, 500) && discoverError == nil }

    func openDiscover() {
        guard !isBusy else { return }
        section = .discover
        if discoverVideos.isEmpty, !isDiscoverLoading { loadDiscover() }
    }

    func selectDiscoverTopic(_ topic: DiscoverTopic) {
        discoverTopic = topic
        discoverSearch = ""
        loadDiscover()
    }

    func submitDiscoverSearch() {
        let query = discoverSearch.trimmingCharacters(in: .whitespaces)
        guard query != discoverQuery || discoverVideos.isEmpty else { return }
        loadDiscover()
    }

    func clearDiscoverSearch() {
        discoverSearch = ""
        loadDiscover()
    }

    /// Loads the first page of the current topic or search, or (more: true) the next page.
    func loadDiscover(more: Bool = false) {
        guard !isSnapshot else { return }
        let query = more ? discoverQuery : discoverSearch.trimmingCharacters(in: .whitespaces)
        let editorsChoice = query.isEmpty && discoverTopic.editorsChoice
        let page = more ? discoverPage + 1 : 1
        discoverRequest += 1
        let request = discoverRequest
        if !more {
            discoverQuery = query
            discoverVideos = []
            discoverTotal = 0
            selectDiscoverVideo(nil)
        }
        isDiscoverLoading = true
        discoverError = nil
        Task {
            do {
                let result = try await pixabay.search(query.isEmpty ? discoverTopic.query : query,
                                                      editorsChoice: editorsChoice, page: page)
                guard request == discoverRequest else { return }
                let known = Set(discoverVideos.map(\.id))
                let videos = result.hits.filter { !known.contains($0.id) }
                discoverVideos += videos
                discoverTotal = result.totalHits
                discoverPage = page
                for video in videos { loadDiscoverThumbnail(video) }
            } catch {
                guard request == discoverRequest else { return }
                discoverError = error.localizedDescription
                Log.error("Discover: \(error.localizedDescription)")
            }
            isDiscoverLoading = false
        }
    }

    private func loadDiscoverThumbnail(_ video: DiscoverVideo) {
        guard discoverThumbnails[video.id] == nil, let url = video.thumbnailURL else { return }
        Task {
            if let image = await Self.remoteImage(url) { discoverThumbnails[video.id] = image }
        }
    }

    /// Selecting a video plays a preview of it full-window; selecting it again deselects it.
    func selectDiscoverVideo(_ video: DiscoverVideo?) {
        guard !isBusy else { return }
        selectedDiscoverID = video.flatMap { $0.id == selectedDiscoverID ? nil : $0.id }
        if let video, selectedDiscoverID != nil {
            let key = "discover-\(video.id)"
            if backdrops[key] == nil, let url = video.largeThumbnailURL {
                Task { if let image = await Self.remoteImage(url) { backdrops[key] = image } }
            }
        }
        showBackgroundVideo()
    }

    /// Downloads the selected video (4K when available) and opens it like a video the user added.
    func downloadSelectedDiscover() {
        guard !isBusy, let video = selectedDiscoverVideo, let url = URL(string: video.download.url) else { return }
        pauseBackgroundVideo(in: .discover)
        let destination = Self.workDir().appending(path: "pixabay-\(video.id).mp4")
        let downloader = VideoDownloader()
        self.downloader = downloader
        displayName = video.title
        backdrops["source"] = backdrops["discover-\(video.id)"]
        downloadSource = "Pixabay"
        downloadDetail = "Getting the \(video.is4K ? "4K" : "1080p") version (\(video.download.size.formatted(.byteCount(style: .file)))). "
            + "Then you can trim it and set it as your wallpaper."
        startProgress("Downloading from Pixabay", flow: .download, step: .download)
        Log.info("Discover: downloading \(video.id) (\(video.download.width)x\(video.download.height), \(video.download.size) bytes)")

        Task.detached {
            do {
                try await downloader.run(url, to: destination) { p in
                    Task { @MainActor in self.progress = p }
                }
                await MainActor.run {
                    self.stopProgress()
                    if let old = self.convertedTempURL { try? FileManager.default.removeItem(at: old) }
                    self.convertedTempURL = destination   // deleted once it's saved, like an ffmpeg conversion
                    self.sourceCredit = video
                    self.loadSource(destination, displayName: video.title)
                }
            } catch {
                await MainActor.run {
                    self.stopProgress()
                    self.displayName = nil
                    try? FileManager.default.removeItem(at: destination)
                    if case DiscoverError.cancelled = error { self.notice = Notice(kind: .info, text: "Download cancelled.") }
                    else { self.fail(error) }
                    self.showBackgroundVideo()
                }
            }
        }
    }

    // MARK: - Add from URL

    /// Opens the Add from URL dialog, filled in with a web address from the clipboard if there is one.
    func openURLImport() {
        guard !isBusy else { return }
        let clipboard = NSPasteboard.general.string(forType: .string) ?? ""
        urlImportText = URLImporter.webAddress(clipboard) != nil ? clipboard.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        urlImportStart = ""
        urlImportEnd = ""
        showURLImport = true
    }

    /// The part of the video typed in the dialog: nil when both fields are empty, or when it isn't valid
    /// (`urlImportSectionProblem` says why).
    var urlImportSection: (start: Double?, end: Double?)? {
        let start = URLImporter.seconds(urlImportStart), end = URLImporter.seconds(urlImportEnd)
        guard urlImportSectionProblem == nil, start != nil || end != nil else { return nil }
        return (start, end)
    }

    var urlImportSectionProblem: String? {
        let startText = urlImportStart.trimmingCharacters(in: .whitespaces), endText = urlImportEnd.trimmingCharacters(in: .whitespaces)
        if startText.isEmpty && endText.isEmpty { return nil }
        let start = URLImporter.seconds(startText), end = URLImporter.seconds(endText)
        if (!startText.isEmpty && start == nil) || (!endText.isEmpty && end == nil) { return "Use times like 1:30 or 90." }
        if let start, let end, end <= start { return "The end has to be after the start." }
        return nil
    }

    /// Downloads a video from a web address (a video file, or a page via yt-dlp) and opens it like an added video.
    /// With a start or end time, only that part is downloaded.
    func importURL(_ text: String) {
        guard !isBusy else { return }
        guard let url = URLImporter.webAddress(text) else { fail(URLImportError.notAWebAddress); return }
        let section = YTDLP.canDownloadSections ? urlImportSection : nil
        showURLImport = false
        let importer = URLImporter()
        urlImporter = importer
        let host = url.host()?.replacingOccurrences(of: "www.", with: "") ?? "the web"
        displayName = host
        downloadSource = host
        let part = section.map { " (\(clockText($0.start ?? 0)) to \($0.end.map(clockText) ?? "the end"))" } ?? ""
        downloadDetail = "Getting the best version up to 4K, without sound\(part). Then you can trim it and set it as your wallpaper."
        backdrops["source"] = nil
        pauseBackgroundVideo(in: self.section)
        startProgress("Downloading from \(host)", flow: .download, step: .download)
        if section != nil { showsProgress = false }   // yt-dlp reports a section only when it's done
        let directory = Self.workDir()

        Task.detached {
            do {
                let (file, title) = try await importer.run(url, section: section, into: directory) { p in
                    Task { @MainActor in self.progress = p }
                }
                await MainActor.run {
                    self.stopProgress()
                    if let old = self.convertedTempURL { try? FileManager.default.removeItem(at: old) }
                    self.convertedTempURL = file   // deleted once it's saved, like an ffmpeg conversion
                    self.sourceCredit = nil
                    self.loadSource(file, displayName: title)
                }
            } catch {
                await MainActor.run {
                    self.stopProgress()
                    self.displayName = nil
                    if case URLImportError.cancelled = error { self.notice = Notice(kind: .info, text: "Download cancelled.") }
                    else { self.fail(error) }
                    self.showBackgroundVideo()
                }
            }
        }
    }

    // MARK: - Helpers (yt-dlp, deno, ffmpeg)

    /// From the URL dialog: install whatever web imports still need, then come back to the dialog.
    func requestURLImportTools() {
        let missing = Tool.missingForURLImport
        guard !missing.isEmpty else { return }
        showURLImport = false
        toolInstallRequest = ToolInstallRequest(tools: missing, purpose: "import videos from web pages and download parts of them",
                                                then: .reopenURLImport)
    }

    var toolInstallText: String {
        guard let request = toolInstallRequest else { return "" }
        let names = ListFormatter.localizedString(byJoining: request.tools.map(\.rawValue))
        return "AerialSwap needs \(names) to \(request.purpose).\n\n\(ToolInstaller.plan(for: request.tools))"
    }

    func cancelToolInstall() {
        if toolInstallRequest?.then == .reopenURLImport { showURLImport = true }
        toolInstallRequest = nil
    }

    func installTools() {
        guard let request = toolInstallRequest, !isBusy else { return }
        toolInstallRequest = nil
        let installer = ToolInstaller()
        toolInstaller = installer
        let names = ListFormatter.localizedString(byJoining: request.tools.filter { Homebrew.location == nil || $0 != .deno }.map(\.rawValue))
        displayName = names
        downloadSource = Homebrew.location != nil ? "Homebrew" : "the web"
        downloadDetail = ToolInstaller.plan(for: request.tools)
        pauseBackgroundVideo(in: section)
        startProgress("Installing \(names)", flow: .tools, step: .download)
        showsProgress = false
        Log.info("Installing helpers: \(request.tools.map(\.rawValue))")

        Task.detached {
            do {
                try await installer.install(request.tools) { line, fraction in
                    Task { @MainActor in
                        self.downloadDetail = line
                        self.showsProgress = fraction != nil
                        if let fraction { self.progress = fraction }
                    }
                }
                await MainActor.run {
                    self.stopProgress()
                    self.displayName = nil
                    self.notice = Notice(kind: .success, text: "Installed \(names).")
                    switch request.then {
                    case .reopenURLImport: self.showURLImport = true
                    case .convert(let url): self.pendingConversion = url; self.convertPending()
                    }
                }
            } catch {
                await MainActor.run {
                    self.stopProgress()
                    self.displayName = nil
                    if case ToolInstallError.cancelled = error { self.notice = Notice(kind: .info, text: "Installation cancelled.") }
                    else { self.fail(error) }
                    if request.then == .reopenURLImport { self.showURLImport = true }
                }
            }
        }
    }

    private static func remoteImage(_ url: URL) async -> NSImage? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return NSImage(data: data)
    }

    // MARK: - Background video (Library and Discover previews)

    /// The video behind the Library or Discover panel: the selected item, looping and muted.
    /// Keys match `backdrops`: "lib-<id>" or "discover-<id>".
    var backgroundPlayer: AVQueuePlayer?
    var backgroundVideoKey: String?
    var isBackgroundVideoPlaying = false   // the player is only shown once it plays, so a failed one never shows black
    @ObservationIgnored private var backgroundLooper: AVPlayerLooper?
    @ObservationIgnored private var backgroundObservations: [NSKeyValueObservation] = []

    /// The library wallpaper behind the panels when nothing is picked in Discover: the selected one, else the desktop's.
    var backgroundLibraryItem: LibraryItem? { selectedLibraryItem ?? libraryItems.first { $0.id == desktopID } }

    /// What the current section should play: the selected Discover video (streamed), else `backgroundLibraryItem`
    /// (local file), so switching sections or deselecting never goes black.
    private var wantedBackgroundVideo: (key: String, url: URL)? {
        if section == .discover, let video = selectedDiscoverVideo {
            guard let url = video.previewURL else { return nil }
            return ("discover-\(video.id)", url)
        }
        guard let item = backgroundLibraryItem else { return nil }
        return ("lib-\(item.id)", library.videoURL(item))
    }

    /// Plays the current section's selection: resumes it when it's already loaded, otherwise starts it.
    /// Called when the selection changes and when the Library or Discover layout appears.
    func showBackgroundVideo() {
        guard !isSnapshot else { return }
        guard let wanted = wantedBackgroundVideo else { stopBackgroundVideo(); return }
        if backgroundVideoKey == wanted.key, let backgroundPlayer {
            backgroundPlayer.play()
            return
        }
        stopBackgroundVideo()
        startBackgroundVideo(wanted.url, key: wanted.key, attempt: 0)
    }

    /// The background video to show now: only once it plays, and only while the current section wants it.
    var visibleBackgroundPlayer: AVPlayer? {
        guard isBackgroundVideoPlaying, let key = backgroundVideoKey, key == wantedBackgroundVideo?.key else { return nil }
        return backgroundPlayer
    }

    private static func backgroundKeyPrefix(_ section: HomeSection) -> String {
        switch section {
        case .library: "lib-"
        case .discover: "discover-"
        }
    }

    /// The layouts pause their video while they're hidden (it keeps its place for when they're back).
    /// Only that section's video: the next section's layout may already have started its own,
    /// or kept playing this one (Discover without a pick shows the Library's video).
    func pauseBackgroundVideo(in section: HomeSection) {
        guard let key = backgroundVideoKey, key.hasPrefix(Self.backgroundKeyPrefix(section)) else { return }
        if section != self.section, key == wantedBackgroundVideo?.key { return }
        backgroundPlayer?.pause()
    }

    private func startBackgroundVideo(_ url: URL, key: String, attempt: Int) {
        let player = AVQueuePlayer()
        player.isMuted = true
        let looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        let playerID = ObjectIdentifier(player)
        backgroundObservations = [
            player.observe(\.timeControlStatus) { [weak self] player, _ in
                guard player.timeControlStatus == .playing else { return }
                Task { @MainActor in
                    guard let self, self.backgroundPlayer.map(ObjectIdentifier.init) == playerID else { return }
                    self.isBackgroundVideoPlaying = true
                }
            },
            looper.observe(\.status) { [weak self] looper, _ in
                guard looper.status == .failed else { return }
                let reason = looper.error?.localizedDescription ?? "unknown error"
                Task { @MainActor in self?.backgroundVideoFailed(url, key: key, attempt: attempt, playerID: playerID, reason: reason) }
            },
        ]
        backgroundLooper = looper
        backgroundPlayer = player
        backgroundVideoKey = key
        player.play()
    }

    /// Pixabay's CDN sometimes fails the first request for a video it hasn't cached yet (AVFoundation -11850)
    /// and serves it fine a moment later, so streamed videos are retried twice. Meanwhile the still frame stays visible.
    private func backgroundVideoFailed(_ url: URL, key: String, attempt: Int, playerID: ObjectIdentifier, reason: String) {
        guard backgroundPlayer.map(ObjectIdentifier.init) == playerID else { return }
        stopBackgroundVideo()
        Log.error("Preview of \(key) failed (attempt \(attempt + 1)): \(reason)")
        guard !url.isFileURL, attempt < 2 else { return }
        Task {
            try? await Task.sleep(for: .seconds(1.5 * Double(attempt + 1)))
            guard backgroundPlayer == nil, wantedBackgroundVideo?.key == key, !isBusy else { return }
            startBackgroundVideo(url, key: key, attempt: attempt + 1)
        }
    }

    /// Also stops the looper's queued copies of the item, so no old preview keeps downloading or holds a file open.
    /// The items go once the backdrop has faded the video out (0.3 s): a player view without them turns black.
    /// `immediately` drops them right away, e.g. before the file is deleted.
    func stopBackgroundVideo(immediately: Bool = false) {
        backgroundObservations = []
        backgroundLooper?.disableLooping()
        backgroundPlayer?.pause()
        if immediately {
            backgroundPlayer?.removeAllItems()
        } else if let player = backgroundPlayer, let looper = backgroundLooper {
            Task {
                try? await Task.sleep(for: .seconds(0.5))
                withExtendedLifetime(looper) { player.removeAllItems() }
            }
        }
        backgroundLooper = nil
        backgroundPlayer = nil
        backgroundVideoKey = nil
        isBackgroundVideoPlaying = false
    }

    // MARK: - Source

    /// Loads a user-chosen file. If macOS can't read it, offers an ffmpeg conversion instead.
    func loadSource(_ url: URL, displayName: String? = nil) {
        guard !isBusy else { return }
        if displayName == nil, let old = convertedTempURL {
            try? FileManager.default.removeItem(at: old)   // a new user file replaces the last conversion
            convertedTempURL = nil
        }
        if displayName == nil { sourceCredit = nil }       // the user's own file
        showIntro = false
        done = nil
        sourceURL = url
        self.displayName = displayName ?? url.deletingPathExtension().lastPathComponent
        sourceInfo = nil
        transcodedURL = nil
        filmstrip = []
        backdrops["source"] = nil
        resolutionPreview = nil
        if notice?.kind != .success { notice = nil }
        stopPreview()
        Task {
            do {
                let info = try await Transcoder.inspect(url)
                sourceInfo = info
                trimStart = 0
                trimEnd = info.duration
                // Smooth by default when it's cheap enough to matter; 60 fps sources stay as recorded.
                motionMode = availableMotionModes.contains(.smooth) ? .smooth : .original
                enhanceDetail = false   // opt-in for each video: it is slow
                // Tell the user right away, not only in the window, when the video is too small for 4K.
                if resolutionHint?.severe == true {
                    showResolutionAlert = true
                    if let screen = NSScreen.main ?? NSScreen.screens.first {
                        let scale = screen.backingScaleFactor
                        let pixels = CGSize(width: screen.frame.width * scale, height: screen.frame.height * scale)
                        let preview = await ResolutionPreview.make(url: url, screenPixels: pixels, backingScale: scale)
                        if sourceURL == url { resolutionPreview = preview }
                    }
                }
                loadBackdrop("source", from: url)
                loadFilmstrip(url, duration: info.duration)
                guard !isSnapshot else { return }
                startPreview(url)
            } catch {
                handleUnreadable(url, error)
            }
        }
    }

    func clearSource() {
        guard !isBusy else { return }
        stopPreview()
        sourceURL = nil; sourceInfo = nil; displayName = nil; filmstrip = []
        showResolutionAlert = false
        if let old = convertedTempURL { try? FileManager.default.removeItem(at: old); convertedTempURL = nil }
    }

    /// Frames for the trim bar.
    func loadFilmstrip(_ url: URL, duration: Double, count: Int = 12) {
        Task {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.maximumSize = CGSize(width: 240, height: 135)
            generator.appliesPreferredTrackTransform = true
            var frames: [NSImage] = []
            for i in 0..<count {
                let time = CMTime(seconds: duration * (Double(i) + 0.5) / Double(count), preferredTimescale: 600)
                if let image = try? await generator.image(at: time).image {
                    frames.append(NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
                }
            }
            guard sourceURL == url else { return }   // a different video was loaded meanwhile
            filmstrip = frames
        }
    }

    private func handleUnreadable(_ url: URL, _ error: Error) {
        sourceURL = nil
        let reason = error.localizedDescription
        Log.error("Cannot read \(url.path): \(reason)")
        guard let ffmpeg = FFmpeg.find() else {
            // Offer to install ffmpeg; once it's there, the conversion starts right away.
            toolInstallRequest = ToolInstallRequest(tools: [.ffmpeg],
                                                    purpose: "convert “\(url.lastPathComponent)”, which macOS can't read directly",
                                                    then: .convert(url))
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
        displayName = source.deletingPathExtension().lastPathComponent
        startProgress("Converting “\(source.lastPathComponent)” with ffmpeg", flow: .convert, step: .convert)

        Task.detached {
            do {
                try await converter.run(ffmpeg: ffmpeg, source: source, destination: destination) { p in
                    Task { @MainActor in self.progress = p }
                }
                await MainActor.run {
                    self.stopProgress()
                    if let old = self.convertedTempURL { try? FileManager.default.removeItem(at: old) }
                    self.convertedTempURL = destination
                    self.loadSource(destination, displayName: source.deletingPathExtension().lastPathComponent)
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

    // MARK: - Preview and trim

    /// Muted, looping preview of the clip range (the wallpaper has no sound either).
    private func startPreview(_ url: URL) {
        let player = AVPlayer(url: url)
        player.isMuted = true
        self.player = player
        loopObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                              object: player.currentItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartPreview() }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.scrubbing, time.isNumeric else { return }
                self.playhead = time.seconds
            }
        }
        playhead = 0
        player.play()
        isPreviewPlaying = true
    }

    private func stopPreview() {
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player = nil
        isPreviewPlaying = false
        if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
        loopObserver = nil
    }

    private func restartPreview() {
        guard let player else { return }
        player.seek(to: CMTime(seconds: trimStart, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        if isPreviewPlaying { player.play() }
    }

    func togglePreviewPlayback() {
        guard let player else { return }
        if isPreviewPlaying { player.pause() } else { player.play() }
        isPreviewPlaying.toggle()
    }

    /// Called while dragging the trim handles: moves the edge and shows that frame.
    func setTrimStart(_ seconds: Double) {
        guard let info = sourceInfo else { return }
        trimStart = max(0, min(seconds, trimEnd - min(Self.minimumClip, info.duration)))
        scrub(to: trimStart)
    }

    func setTrimEnd(_ seconds: Double) {
        guard let info = sourceInfo else { return }
        trimEnd = min(info.duration, max(seconds, trimStart + min(Self.minimumClip, info.duration)))
        scrub(to: trimEnd)
    }

    /// After a drag: play the new range from its start.
    func finishTrimDrag() {
        guard let player, let info = sourceInfo else { return }
        player.currentItem?.forwardPlaybackEndTime = trimEnd < info.duration - 0.01
            ? CMTime(seconds: trimEnd, preferredTimescale: 600) : .invalid
        isPreviewPlaying = true
        restartPreview()
    }

    private func scrub(to seconds: Double) {
        player?.pause()
        playhead = seconds
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Dragging the playhead (or clicking the filmstrip): shows that moment, within the clip range.
    func scrubPlayhead(to seconds: Double) {
        guard player != nil else { return }
        if !scrubbing {
            scrubbing = true
            playAfterScrub = isPreviewPlaying
        }
        scrub(to: min(max(seconds, trimStart), trimEnd))
    }

    /// After the playhead drag: carry on playing from there if it was playing before.
    func finishPlayheadDrag() {
        scrubbing = false
        if playAfterScrub { player?.play() }
        isPreviewPlaying = playAfterScrub
    }

    func resetTrim() {
        guard let info = sourceInfo else { return }
        trimStart = 0; trimEnd = info.duration
        player?.currentItem?.forwardPlaybackEndTime = .invalid
        restartPreview()
    }

    // MARK: - Set as wallpaper

    /// Rough duration estimate for the confirmation: ~1.15x real time at 60 fps, scaling with fps,
    /// plus ~40 ms per source frame for Smooth motion: all in-between frames of a pair come from one optical-flow pass
    /// (measured on an M3 Pro: 25 -> 60 fps adds ~1.1x the clip length, 25 -> 120 fps less, as it overlaps the encoder).
    var estimateText: String {
        let length = max(1, trimEnd - trimStart)
        var seconds = length * Double(outputFPS) / 60 * 1.15
        if interpolates, let fps = sourceInfo?.fps {
            seconds += length * Double(fps) * 0.04
        }
        if enhances, let fps = sourceInfo?.fps {
            seconds += length * Double(fps) * 1.25   // ~1.25 s per source frame (ML 4x via 8K), measured
        }
        return seconds < 90 ? "about \(Int(seconds.rounded())) seconds" : "about \(Int((seconds / 60).rounded())) minutes"
    }

    var remainingText: String {
        let elapsed = Date.now.timeIntervalSince(progressStarted)
        guard progress > 0.03, elapsed > 3 else { return "Estimating…" }
        let left = elapsed * (1 - progress) / progress
        return left < 90 ? "\(Int(left)) s left" : "\(Int((left / 60).rounded())) min left"
    }

    private func startProgress(_ text: String, flow: WorkFlow, step: WorkStep) {
        isBusy = true; showsProgress = true
        workFlow = flow; workStep = step
        progress = 0; progressStarted = .now
        phase = text; notice = nil
    }

    private func stopProgress() {
        isBusy = false; showsProgress = false; phase = ""; workFlow = nil
    }

    /// Called after the user confirmed: shows the selected library item, or prepares the new video first.
    func setAsWallpaper() {
        if isUsingLibrary, let item = selectedLibraryItem {
            isBusy = true; workFlow = .quick; phase = "Switching"; notice = nil
            show(item, savedToLibrary: false)
            return
        }
        transcode(thenShow: true)
    }

    /// Prepares the new video and keeps it in the library (and so the AerialSwap group) without switching to it.
    func saveToLibraryOnly() {
        transcode(thenShow: false)
    }

    /// Transcodes the source, saves it to the library, then (optionally) shows it on the desktop and screen saver.
    private func transcode(thenShow: Bool) {
        guard let source = sourceURL, let info = sourceInfo else { return }
        let options = TranscodeOptions(fps: outputFPS, trimStart: trimStart,
                                       trimEnd: trimEnd < info.duration ? trimEnd : nil,
                                       loopCrossfade: canSmoothLoop && smoothLoop ? Self.loopCrossfade : 0,
                                       interpolate: interpolates,
                                       enhance: enhances)
        let settings = LibrarySettings(fps: outputFPS,
                                       motion: interpolates ? (effectiveMotionMode == .maximum ? "Maximum" : "Smooth") : nil,
                                       enhanced: enhances, smoothLoop: options.loopCrossfade > 0,
                                       credit: sourceCredit?.credit, sourcePage: sourceCredit?.pageURL)
        let destination = Self.workDir().appending(path: "\(UUID().uuidString).mov")
        let transcoder = Transcoder()
        self.transcoder = transcoder
        if let old = transcodedURL { try? FileManager.default.removeItem(at: old) }
        transcodedURL = nil
        player?.pause(); isPreviewPlaying = false
        var phase = enhances ? "Preparing your video in 4K with enhanced detail" : "Preparing your video in 4K"
        if enhances && !DetailEnhancer.isModelReady(width: 1920, height: 1080) {
            phase += " (first time: downloading Apple's enhancement model)"
        }
        workStarted = .now
        startProgress(phase, flow: thenShow ? .newVideo : .saveOnly, step: .prepare)

        Task.detached {
            do {
                try await transcoder.run(source: source, destination: destination, options: options) { p in
                    Task { @MainActor in self.progress = p }
                }
                await MainActor.run {
                    self.transcodedURL = destination
                    self.save(destination, settings: settings, thenShow: thenShow)
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
        downloader?.cancel()
        urlImporter?.cancel()
        toolInstaller?.cancel()
    }

    /// Keeps the finished video in the library, then shows it, or (thenShow: false) opens it in the library.
    private func save(_ file: URL, settings: LibrarySettings, thenShow: Bool) {
        let name = displayName ?? "your video"
        showsProgress = false; phase = "Saving to your library"; workStep = .save
        Task {
            do {
                let item = try await library.add(file, name: name, settings: settings)
                if thenShow { show(item, savedToLibrary: true); return }
                removeTempFilesAfterSaving()
                stopPreview()
                sourceURL = nil; sourceInfo = nil; displayName = nil; filmstrip = []
                refreshLibrary()
                syncGroup()
                section = .library
                selectLibraryItem(item)
                notice = Notice(kind: .success, text: "Saved “\(name)” to your library. It's in System Settings → Wallpaper → AerialSwap.")
            } catch {
                fail(error)
            }
            workStarted = nil
            stopProgress()
        }
    }

    /// Adds the library item to the AerialSwap group and points the desktop and screen saver at it. Only choices that
    /// already show an Aerial can be switched (see AerialStore.setSelection); otherwise the user picks it in System Settings.
    private func show(_ item: LibraryItem, savedToLibrary: Bool) {
        showsProgress = false; phase = "Adding to your wallpapers"; workStep = .show
        refreshLibrary()
        let group = group, store = store, items = libraryItems
        Task {
            do {
                let switched = try await Task.detached { () -> Int in
                    let changed = try await group.sync(items, restart: false)
                    let switched = try store.setSelection(item.id, desktop: true, idle: true)   // restarts WallpaperAgent
                    if switched == 0 && changed { store.restartWallpaperAgent() }
                    return switched
                }.value
                // WallpaperAgent restarts and may rewrite the file; see which roles took the change.
                if switched > 0 { try? await Task.sleep(for: .seconds(1.5)) }
                let now = store.detectSelection()
                let role = switch (now.desktop == item.id, now.idle == item.id) {
                case (true, true): "Desktop & Screen Saver"
                case (true, false): "Desktop"
                case (false, true): "Screen Saver"
                case (false, false): ""
                }
                removeTempFilesAfterSaving()
                stopPreview()
                sourceURL = nil; sourceInfo = nil; displayName = nil; filmstrip = []
                section = .library
                selectedLibraryID = item.id   // shows what now plays (selectLibraryItem waits while busy)
                loadBackdrop("lib-\(item.id)", from: library.videoURL(item))
                showBackgroundVideo()
                done = DoneInfo(assetID: item.id, role: role, videoName: item.name,
                                took: savedToLibrary ? workStarted.map { Date.now.timeIntervalSince($0) } : nil,
                                summary: item.settingsSummary, savedToLibrary: savedToLibrary)
                Log.info("Group: \(item.name) (\(item.id)) shown on \(role.isEmpty ? "nothing yet" : role)")
            } catch {
                fail(error)
            }
            workStarted = nil
            stopProgress()
            refreshAssets()
        }
    }

    func finishDone() { done = nil }

    /// Makes macOS show this library wallpaper on the desktop and/or as the screen saver, without the success dialog.
    /// To take a role away, the user picks another wallpaper for it (here or in System Settings).
    func use(_ item: LibraryItem, desktop: Bool, screenSaver: Bool) {
        guard !isBusy, desktop || screenSaver else { return }
        isBusy = true; workFlow = .quick; phase = "Switching"; notice = nil
        let group = group, store = store, items = libraryItems
        let name = prettyName(item.name)
        let role = desktop && screenSaver ? "desktop and screen saver" : (desktop ? "desktop" : "screen saver")
        Task {
            do {
                let switched = try await Task.detached { () -> Int in
                    let synced = try await group.sync(items, restart: false)
                    let switched = try store.setSelection(item.id, desktop: desktop, idle: screenSaver)   // restarts WallpaperAgent
                    if switched == 0 && synced { store.restartWallpaperAgent() }
                    return switched
                }.value
                if switched == 0 {
                    notice = Notice(kind: .error, text: "Your \(role) doesn't show an Aerial right now. Pick “\(name)” in "
                                    + "System Settings → Wallpaper → AerialSwap instead.")
                } else {
                    // WallpaperAgent restarts and may rewrite the file; check that our choice stuck.
                    try? await Task.sleep(for: .seconds(1.5))
                    let now = store.detectSelection()
                    if (desktop && now.desktop != item.id) || (screenSaver && now.idle != item.id) {
                        notice = Notice(kind: .error, text: "macOS didn't take the change. Pick “\(name)” in System Settings → Wallpaper → AerialSwap instead.")
                    } else {
                        notice = Notice(kind: .success, text: "“\(name)” is now your \(role).")
                    }
                }
            } catch {
                fail(error)
            }
            stopProgress()
            refreshAssets()
        }
    }

    // MARK: - Finder helpers

    /// The manual check (⚙ menu, app menu): opens the release page when there is a newer version.
    func checkForUpdates() {
        Task {
            do {
                if let update = try await UpdateChecker.check(force: true) {
                    availableUpdate = update
                    NSWorkspace.shared.open(update.page)
                } else if let version = UpdateChecker.currentVersion {
                    notice = Notice(kind: .info, text: "AerialSwap \(version) is the latest version.")
                }
            } catch {
                notice = Notice(kind: .error, text: "Couldn't check for updates: \(error.localizedDescription)")
            }
        }
    }

    func openUpdate() {
        NSWorkspace.shared.open(availableUpdate?.page ?? UpdateChecker.releasesPage)
    }

    func openLog() {
        NSWorkspace.shared.open(Log.url)
    }

    func openWallpaperSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
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

    /// Once the video is in the library, the transcode and any ffmpeg intermediate are no longer needed.
    private func removeTempFilesAfterSaving() {
        if let file = transcodedURL { try? FileManager.default.removeItem(at: file) }
        transcodedURL = nil
        if let converted = convertedTempURL {
            try? FileManager.default.removeItem(at: converted)
            convertedTempURL = nil
            // The loaded source was that intermediate, so it is gone now.
            stopPreview(); sourceURL = nil; sourceInfo = nil; displayName = nil
        }
        Self.removeWorkDir()   // nothing in it is needed any more
    }

    private func fail(_ error: Error) {
        let text = error.localizedDescription
        notice = Notice(kind: .error, text: text)
        Log.error(text)
    }
}
