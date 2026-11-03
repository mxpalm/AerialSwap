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

/// Where Discover's videos come from: Pixabay, or Wallpaper Engine's Steam Workshop (downloaded by the user's Steam).
enum DiscoverSource { case pixabay, workshop }

/// What the Add from URL dialog gets from a link: one video, or the videos of a playlist, board, … to pick from.
enum URLImportMode { case video, collection }

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
    var discoverSource = DiscoverSource.pixabay
    // Discover: Wallpaper Engine's Workshop (see WorkshopClient, SteamDownloader)
    let workshop = WorkshopClient(proxy: PixabayClient().proxy)
    var discoverOptions = DiscoverOptions.load()
    /// Workshop items Steam already downloaded (any library), for the "In Steam" badge.
    var steamDownloadedIDs: Set<String> = []
    var workshopTopic = WorkshopTopic.all[0]
    var workshopSearch = ""               // what's typed; searched on Return
    var workshopQuery = ""                // the search the results are for ("" = the topic)
    var workshopItems: [WorkshopItem] = []
    var workshopItemThumbnails: [String: NSImage] = [:]
    var workshopTotal = 0
    var isWorkshopLoading = false
    var workshopError: String?
    var selectedWorkshopItemID: String?
    var confirmSteamDownload = false      // the one-time "Download with Steam?" question
    var showSteamNeeded = false           // Workshop picked without Steam for Mac
    /// Whether the Steam account owns Wallpaper Engine (nil: not known, e.g. Steam isn't running). Checked when the Workshop
    /// opens, so a missing license shows before a download is tried (see checkWallpaperEngineOwnership).
    var ownsWallpaperEngine: Bool?
    @ObservationIgnored private var ownershipCheckedAt: Date?
    @ObservationIgnored private var workshopPage = 0
    @ObservationIgnored private var workshopRequest = 0
    private var steamDownloader: SteamDownloader?
    /// A Discover download (Pixabay or Steam) running while the user keeps browsing: the chip in the top bar.
    var backgroundDownload: BackgroundDownload?
    /// Opens the finished download like a video the user added (set when it's ready).
    @ObservationIgnored private var openFinishedDownload: (() -> Void)?
    @ObservationIgnored private var discardFinishedDownload: (() -> Void)?   // the chip's ✕ on a finished download
    /// The Workshop folder Steam for Mac has the loaded video in, removed once it's saved (Remove Steam's Copy option).
    /// removeCopy leaves subscribed items alone (Steam would download them again).
    @ObservationIgnored private var steamCopyToRemove: URL?
    /// Set while the loaded source is a Pixabay or Workshop video, so the library keeps the credit and its page.
    @ObservationIgnored private var sourceCredit: (credit: String, page: String?)?
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
    /// Where the notice toast is (window coordinates, top left origin), so clicks outside it can dismiss an error.
    @ObservationIgnored var noticeFrame = CGRect.zero
    var done: DoneInfo?
    private var transcodedURL: URL?
    private var transcoder: Transcoder?
    private var converter: FFmpegConverter?

    // Transient UI state
    var showIntro: Bool
    var section = HomeSection.library
    var isPreviewingWallpaper = false   // the Library's or Discover's panels are hidden for a clean look at the wallpaper
    var showsPreviewHandle = false
    var pendingConversion: URL?       // unreadable file waiting for the user's OK to convert with ffmpeg
    @ObservationIgnored private var pendingConversionName: String?   // its title, kept for the converted copy
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
    var urlImportMode = URLImportMode.video   // kept between openings of the dialog
    var isInspectingLink = false          // yt-dlp is looking at the link (the dialog stays open meanwhile)
    /// The videos at a link that holds several (a playlist, board, channel, …), to pick one from.
    var linkCollection: LinkCollection?
    var selectedLinkVideoID: String?
    var linkThumbnails: [String: NSImage] = [:]
    /// The Wallpaper Engine dialog: video wallpapers the user's Steam downloaded (see WallpaperEngine).
    var showWorkshopImport = false
    var workshopScan = WorkshopScan()
    var isWorkshopScanning = false
    var workshopThumbnails: [String: NSImage] = [:]

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
                notice = Notice(kind: .info, text: "AerialSwap \(update.version) is available. "
                                + (canInstallUpdate ? "Update from the ⚙ menu." : "Get it from the ⚙ menu."))
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

    var selectedDiscoverVideo: DiscoverVideo? {
        discoverSource == .pixabay ? discoverVideos.first { $0.id == selectedDiscoverID } : nil
    }
    /// Pixabay serves at most 500 results per search.
    var canLoadMoreDiscover: Bool { discoverVideos.count < min(discoverTotal, 500) && discoverError == nil }

    func openDiscover() {
        guard !isBusy else { return }
        section = .discover
        loadDiscoverSourceIfEmpty()
    }

    func selectDiscoverSource(_ source: DiscoverSource) {
        guard !isBusy, source != discoverSource else { return }
        // The Workshop's wallpapers can only be downloaded with Steam for Mac: without it, say what to do instead.
        if source == .workshop, !SteamDownload.isInstalled, !isSnapshot { showSteamNeeded = true; return }
        discoverSource = source
        loadDiscoverSourceIfEmpty()
        showBackgroundVideo()
    }

    func setDiscoverSort(_ sort: DiscoverSort) {
        var options = discoverOptions
        options.sort = sort
        applyDiscoverOptions(options)
    }

    func setRemoveSteamCopy(_ remove: Bool) {
        discoverOptions.removeSteamCopy = remove
        discoverOptions.save()
    }

    func setDiscoverResolution(_ resolution: DiscoverResolution) {
        var options = discoverOptions
        options.resolution = resolution
        applyDiscoverOptions(options)
    }

    func setDiscoverPeriod(_ period: DiscoverPeriod?) {
        var options = discoverOptions
        options.period = period
        applyDiscoverOptions(options)
    }

    func setDiscoverCategory(_ category: PixabayCategory) {
        var options = discoverOptions
        options.category = category
        applyDiscoverOptions(options)
    }

    /// Only hides tiles: nothing is loaded again.
    func setHideInLibrary(_ hide: Bool) {
        discoverOptions.hideInLibrary = hide
        discoverOptions.save()
    }

    /// The tiles shown: without videos already in the library when Hide Videos in Library is on.
    var shownDiscoverVideos: [DiscoverVideo] {
        guard discoverOptions.hideInLibrary else { return discoverVideos }
        let pages = libraryPages
        return discoverVideos.filter { !pages.contains($0.pageURL) }
    }

    var shownWorkshopItems: [WorkshopItem] {
        guard discoverOptions.hideInLibrary else { return workshopItems }
        let pages = libraryPages
        return workshopItems.filter { item in item.page.map { !pages.contains($0.absoluteString) } ?? true }
    }

    /// Both sources search with the same options: the visible one reloads now, the other when it's shown next.
    private func applyDiscoverOptions(_ options: DiscoverOptions) {
        guard !isBusy, options != discoverOptions else { return }
        discoverOptions = options
        options.save()
        switch discoverSource {
        case .pixabay:
            workshopItems = []
            loadDiscover()
        case .workshop:
            discoverVideos = []
            loadWorkshop()
        }
    }

    /// Whether a Discover pick is already in the library (by its page), or downloaded by Steam.
    func status(of video: DiscoverVideo) -> DiscoverItemStatus? {
        if backgroundDownload?.key == "discover-\(video.id)" { return backgroundDownload?.isReady == true ? .downloaded : .downloading }
        return libraryPages.contains(video.pageURL) ? .inLibrary : nil
    }

    func status(of item: WorkshopItem) -> DiscoverItemStatus? {
        if backgroundDownload?.key == "workshop-\(item.id)" { return backgroundDownload?.isReady == true ? .downloaded : .downloading }
        if let page = item.page?.absoluteString, libraryPages.contains(page) { return .inLibrary }
        return steamDownloadedIDs.contains(item.id) ? .inSteam : nil
    }

    private var libraryPages: Set<String> { Set(libraryItems.compactMap(\.sourcePage)) }

    /// Reads which Workshop items Steam has, off the main thread (libraries can be on slow drives).
    func refreshSteamDownloads() {
        guard !isSnapshot else { return }
        Task {
            let ids = await Task.detached { WallpaperEngine.downloadedIDs() }.value
            if ids != steamDownloadedIDs { steamDownloadedIDs = ids }
        }
    }

    private func loadDiscoverSourceIfEmpty() {
        switch discoverSource {
        case .pixabay: if discoverVideos.isEmpty, !isDiscoverLoading { loadDiscover() }
        case .workshop: if workshopItems.isEmpty, !isWorkshopLoading { loadWorkshop() }
        }
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
        let options = discoverOptions
        let page = more ? discoverPage + 1 : 1
        discoverRequest += 1
        let request = discoverRequest
        if !more {
            discoverQuery = query
            cancelThumbnails("discover-")
            discoverVideos = []
            discoverTotal = 0
            selectDiscoverVideo(nil)
        }
        isDiscoverLoading = true
        discoverError = nil
        Task {
            do {
                let result = try await pixabay.search(query.isEmpty ? discoverTopic.query : query,
                                                      editorsChoice: editorsChoice, page: page, options: options)
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
        loadThumbnail("discover-\(video.id)", from: url) { self.discoverThumbnails[video.id] = $0 }
    }

    /// Tile pictures still downloading, by "<source>-<id>". A new topic or search cancels the previous one's, so they
    /// don't hold up the new tiles.
    @ObservationIgnored private var thumbnailTasks: [String: Task<Void, Never>] = [:]

    private func loadThumbnail(_ key: String, from url: URL, then use: @escaping (NSImage) -> Void) {
        guard thumbnailTasks[key] == nil else { return }
        thumbnailTasks[key] = Task {
            let image = await Self.remoteImage(url)   // nil when cancelled
            guard !Task.isCancelled else { return }
            thumbnailTasks[key] = nil
            if let image { use(image) }
        }
    }

    private func cancelThumbnails(_ prefix: String) {
        for (key, task) in thumbnailTasks where key.hasPrefix(prefix) {
            task.cancel()
            thumbnailTasks[key] = nil
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

    /// Downloads the selected video (4K when available) in the background, then opens it like a video the user added.
    /// Again on a finished download opens it.
    func downloadSelectedDiscover() {
        guard let video = selectedDiscoverVideo else { return }
        if backgroundDownload?.key == "discover-\(video.id)" { openBackgroundDownload(); return }
        guard !isBusy, backgroundDownload == nil, let url = URL(string: video.download.url) else { return }
        let destination = Self.workDir().appending(path: "pixabay-\(video.id).mp4")
        let downloader = VideoDownloader()
        self.downloader = downloader
        let key = "discover-\(video.id)"
        backgroundDownload = BackgroundDownload(
            key: key, title: video.title, source: "Pixabay", state: .running(0),
            detail: "Getting the \(video.is4K ? "4K" : "1080p") version (\(video.download.size.formatted(.byteCount(style: .file)))). "
                + "Keep browsing meanwhile; then you trim it and set it as your wallpaper.")
        notice = nil
        Log.info("Discover: downloading \(video.id) (\(video.download.width)x\(video.download.height), \(video.download.size) bytes)")

        Task.detached {
            do {
                try await downloader.run(url, to: destination) { p in
                    Task { @MainActor in self.updateBackgroundDownload(key, .running(p)) }
                }
                await MainActor.run {
                    self.downloader = nil
                    self.finishBackgroundDownload(key, stillWanted: self.selectedDiscoverID == video.id) {
                        if let old = self.convertedTempURL { try? FileManager.default.removeItem(at: old) }
                        self.convertedTempURL = destination   // deleted once it's saved, like an ffmpeg conversion
                        self.sourceCredit = (video.credit, video.pageURL)
                        self.loadSource(destination, displayName: video.title)
                    } discard: {
                        try? FileManager.default.removeItem(at: destination)
                    }
                }
            } catch {
                await MainActor.run {
                    self.downloader = nil
                    try? FileManager.default.removeItem(at: destination)
                    self.failBackgroundDownload(key, error, cancelled: { if case DiscoverError.cancelled = $0 { true } else { false } })
                }
            }
        }
    }

    // MARK: - Discover: downloads in the background

    private func updateBackgroundDownload(_ key: String, _ state: BackgroundDownload.State, detail: String? = nil) {
        guard backgroundDownload?.key == key else { return }
        backgroundDownload?.state = state
        if let detail { backgroundDownload?.detail = detail }
    }

    /// Opens the finished download right away when the user is still looking at it (and free), else the chip offers it.
    private func finishBackgroundDownload(_ key: String, stillWanted: Bool, open: @escaping () -> Void, discard: @escaping () -> Void) {
        guard let download = backgroundDownload, download.key == key else { discard(); return }
        Log.info("Discover: \(download.source) download of \(key) finished")
        openFinishedDownload = open
        discardFinishedDownload = discard
        backgroundDownload?.state = .ready
        if stillWanted, canOpenBackgroundDownload, section == .discover {
            openBackgroundDownload()
        }
    }

    private func failBackgroundDownload(_ key: String, _ error: Error, cancelled: (Error) -> Bool) {
        guard backgroundDownload?.key == key else { return }
        backgroundDownload = nil
        if cancelled(error) { notice = Notice(kind: .info, text: "Download cancelled.") }
        else { fail(error) }
    }

    /// Only from Home, with nothing else running: opening replaces what's on the trim screen.
    var canOpenBackgroundDownload: Bool {
        backgroundDownload?.isReady == true && !isBusy && screen == .home && done == nil
    }

    func openBackgroundDownload() {
        guard canOpenBackgroundDownload, let open = openFinishedDownload else { return }
        backgroundDownload = nil
        openFinishedDownload = nil; discardFinishedDownload = nil
        open()
    }

    /// The chip's ✕: stops a running download, or drops a finished one that wasn't opened.
    func cancelBackgroundDownload() {
        guard let download = backgroundDownload else { return }
        if download.isReady {
            backgroundDownload = nil
            discardFinishedDownload?()
            openFinishedDownload = nil; discardFinishedDownload = nil
        } else {
            downloader?.cancel()
            steamDownloader?.cancel()
        }
    }

    // MARK: - Discover: Steam Workshop

    var selectedWorkshopItem: WorkshopItem? {
        discoverSource == .workshop ? workshopItems.first { $0.id == selectedWorkshopItemID } : nil
    }
    /// Steam's QueryFiles pages through at most 100 pages.
    var canLoadMoreWorkshop: Bool {
        workshopItems.count < min(workshopTotal, 100 * WorkshopClient.pageSize) && workshopError == nil
    }

    func selectWorkshopTopic(_ topic: WorkshopTopic) {
        workshopTopic = topic
        workshopSearch = ""
        loadWorkshop()
    }

    func submitWorkshopSearch() {
        let query = workshopSearch.trimmingCharacters(in: .whitespaces)
        guard query != workshopQuery || workshopItems.isEmpty else { return }
        loadWorkshop()
    }

    func clearWorkshopSearch() {
        workshopSearch = ""
        loadWorkshop()
    }

    /// Loads the first page of the current topic or search, or (more: true) the next page.
    func loadWorkshop(more: Bool = false) {
        guard !isSnapshot else { return }
        let query = more ? workshopQuery : workshopSearch.trimmingCharacters(in: .whitespaces)
        let page = more ? workshopPage + 1 : 1
        workshopRequest += 1
        let request = workshopRequest
        if !more {
            cancelThumbnails("workshop-")
            workshopQuery = query
            workshopItems = []
            workshopTotal = 0
            selectedWorkshopItemID = nil
            showBackgroundVideo()
        }
        isWorkshopLoading = true
        workshopError = nil
        let topic = workshopTopic
        let options = discoverOptions
        if !more { refreshSteamDownloads(); checkWallpaperEngineOwnership() }
        Task {
            do {
                let result = try await workshop.search(query, topic: topic, page: page, options: options)
                guard request == workshopRequest else { return }
                let known = Set(workshopItems.map(\.id))
                let items = result.items.filter { !known.contains($0.id) }
                workshopItems += items
                workshopTotal = result.total
                workshopPage = page
                for item in items { loadWorkshopItemThumbnail(item) }
            } catch {
                guard request == workshopRequest else { return }
                workshopError = error.localizedDescription
                Log.error("Discover Workshop: \(error.localizedDescription)")
            }
            isWorkshopLoading = false
        }
    }

    private func loadWorkshopItemThumbnail(_ item: WorkshopItem) {
        guard workshopItemThumbnails[item.id] == nil, let url = item.thumbnailURL else { return }
        loadThumbnail("workshop-\(item.id)", from: url) { image in
            self.workshopItemThumbnails[item.id] = image
            if item.id == self.selectedWorkshopItemID { self.updateWorkshopPreview() }
        }
    }

    /// The picture behind the panel for a Workshop pick: the largest of the creator's screenshot, the full-size preview
    /// (loaded on selection) and the tile's (GIF previews are 160-256 px).
    func workshopBackdrop(for item: WorkshopItem) -> NSImage? {
        [backdrops["workshop-\(item.id)"], backdrops["workshop-preview-\(item.id)"], workshopItemThumbnails[item.id]]
            .compactMap { $0 }.max { $0.pixelWidth < $1.pixelWidth }
    }

    /// The tile's picture is the full preview when it's a GIF (Steam doesn't scale those); a JPG's comes on selection.
    private func hasFullWorkshopPreview(_ item: WorkshopItem) -> Bool {
        item.previewURL == nil || backdrops["workshop-preview-\(item.id)"] != nil || workshopItemThumbnails[item.id]?.isAnimated == true
    }

    /// A Workshop pick whose best picture is under 1000 px: its frames, played full-window (Backdrop) and labelled
    /// "Low-res preview"; `upscaled` once PreviewUpscaler is done.
    struct WorkshopPreview {
        var id: String
        var source: ObjectIdentifier   // the picture the frames come from
        var frames: PreviewFrames
        var upscaled = false
    }
    var workshopPreview: WorkshopPreview?
    @ObservationIgnored private var workshopUpscaleTask: Task<Void, Never>?

    var selectedWorkshopPreview: WorkshopPreview? {
        guard let preview = workshopPreview, preview.id == selectedWorkshopItem?.id else { return nil }
        return preview
    }

    /// Small pictures play as frames right away and are replaced by their 4x ML upscale when it's ready.
    private func updateWorkshopPreview() {
        // Until the full-size preview is in, the 360 px tile picture isn't judged (or upscaled) as low-res.
        guard !isSnapshot, let item = selectedWorkshopItem, hasFullWorkshopPreview(item), let image = workshopBackdrop(for: item),
              image.pixelWidth < 1000 else {
            workshopUpscaleTask?.cancel()
            workshopPreview = nil
            return
        }
        let source = ObjectIdentifier(image)
        guard workshopPreview?.id != item.id || workshopPreview?.source != source else { return }
        workshopUpscaleTask?.cancel()
        guard let frames = PreviewFrames(image) else { workshopPreview = nil; return }
        workshopPreview = WorkshopPreview(id: item.id, source: source, frames: frames)
        workshopUpscaleTask = Task {
            // Runs off the main actor (a nonisolated async function) and stops when this task is cancelled.
            let upscaled = await PreviewUpscaler.upscale(frames)
            guard !Task.isCancelled, let upscaled, workshopPreview?.id == item.id else { return }
            workshopPreview = WorkshopPreview(id: item.id, source: source, frames: upscaled, upscaled: true)
        }
    }

    /// Selecting shows the item's screenshot full-window, else its preview picture (Steam has no streamable video);
    /// again deselects it.
    func selectWorkshopItem(_ item: WorkshopItem) {
        guard !isBusy else { return }
        if ownsWallpaperEngine == false { checkWallpaperEngineOwnership() }
        selectedWorkshopItemID = item.id == selectedWorkshopItemID ? nil : item.id
        if selectedWorkshopItemID != nil {
            let full = hasFullWorkshopPreview(item) ? nil : item.previewURL
            for (key, url) in [("workshop-\(item.id)", item.screenshotURL), ("workshop-preview-\(item.id)", full)] {
                guard backdrops[key] == nil, let url else { continue }
                Task {
                    guard let image = await Self.remoteImage(url) else { return }
                    backdrops[key] = image
                    if item.id == selectedWorkshopItemID { updateWorkshopPreview() }
                }
            }
        }
        updateWorkshopPreview()
        showBackgroundVideo()
    }

    /// Asks a running Steam whether the account owns Wallpaper Engine: once per launch while it does, every minute at
    /// most while it doesn't (it may have been bought meanwhile). Only after the user agreed to Download with Steam: the
    /// check briefly shows them as playing Wallpaper Engine, which that question explains.
    func checkWallpaperEngineOwnership() {
        guard !isSnapshot, UserDefaults.standard.bool(forKey: Self.steamConsentKey), ownsWallpaperEngine != true,
              ownershipCheckedAt.map({ Date.now.timeIntervalSince($0) > 60 }) ?? true else { return }
        ownershipCheckedAt = .now
        Task {
            let owned = await SteamDownload.checkOwnership()
            if let owned { ownsWallpaperEngine = owned } else { ownershipCheckedAt = nil }   // unknown: ask again next time
        }
    }

    private static let steamConsentKey = "SteamDownloadConfirmed"

    /// Download with Steam: asks once whether that's okay (see `confirmSteamDownload`), then downloads.
    func downloadSelectedWorkshopItem() {
        guard let item = selectedWorkshopItem else { return }
        if backgroundDownload?.key == "workshop-\(item.id)" { openBackgroundDownload(); return }
        guard !isBusy, backgroundDownload == nil else { return }
        guard SteamDownload.isInstalled else { fail(SteamDownloadError.notInstalled); return }
        guard UserDefaults.standard.bool(forKey: Self.steamConsentKey) else { confirmSteamDownload = true; return }
        startSteamDownload(item)
    }

    func confirmAndDownloadWithSteam() {
        UserDefaults.standard.set(true, forKey: Self.steamConsentKey)
        if let item = selectedWorkshopItem { startSteamDownload(item) }
    }

    /// The user's Steam downloads the item; then it opens like a video from the Wallpaper Engine dialog.
    private func startSteamDownload(_ item: WorkshopItem) {
        guard !isBusy else { return }
        Task {
            // Already downloaded: used as it is, Steam isn't asked. Looked up off the main thread: Steam libraries can be
            // on drives that take seconds to wake up.
            let existing = await Task.detached { WallpaperEngine.downloadedVideo(id: item.id) }.value
            guard !isBusy, backgroundDownload == nil else { return }
            if let video = existing {
                guard video.rating == nil else { fail(SteamDownloadError.notForEveryone); return }
                Log.info("Steam: Workshop item \(item.id) is already downloaded")
                useWorkshopVideo(video, credit: item.credit)
                // E.g. one AerialSwap downloaded earlier: removeCopy still keeps subscribed ones and other Steam installs'.
                steamCopyToRemove = SteamDownload.itemFolder(item.id, containing: video.video)
            } else {
                downloadWithSteam(item)
            }
        }
    }

    private func downloadWithSteam(_ item: WorkshopItem) {
        if let reason = SteamDownload.limitReason() { notice = Notice(kind: .info, text: reason); return }
        let downloader = SteamDownloader()
        steamDownloader = downloader
        let key = "workshop-\(item.id)"
        let detail = "Your Steam app downloads it\(item.size > 0 ? " (\(item.size.formatted(.byteCount(style: .file))))" : ""). "
            + "Meanwhile Steam shows you as playing Wallpaper Engine. Keep browsing; then you trim it and set it as your wallpaper."
        backgroundDownload = BackgroundDownload(key: key, title: item.title, source: "Steam", state: .running(0), detail: detail)
        notice = nil

        let proxy = workshop.proxy
        Task.detached {
            do {
                guard await SteamDownload.downloadsAllowed(proxy: proxy) else { throw SteamDownloadError.paused }
                let folder = try await downloader.run(id: item.id, waiting: {
                    Task { @MainActor in
                        self.updateBackgroundDownload(key, .waiting("Waiting for Steam"),
                                                      detail: "Waiting for Steam to open and log in (up to 90 seconds). If Steam asks you to "
                                                          + "log in, do that, and the download starts.")
                    }
                }, started: {
                    SteamDownload.recordDownload()
                    Task { @MainActor in
                        self.ownsWallpaperEngine = true   // Steam accepted the download
                        self.updateBackgroundDownload(key, .running(0), detail: detail)
                    }
                }) { p in
                    Task { @MainActor in self.updateBackgroundDownload(key, .running(p)) }
                }
                guard let video = WallpaperEngine.video(in: folder) else { throw SteamDownloadError.notAVideo }
                guard video.rating == nil else { throw SteamDownloadError.notForEveryone }
                await MainActor.run {
                    self.steamDownloader = nil
                    self.refreshSteamDownloads()
                    let stillWanted = self.discoverSource == .workshop && self.selectedWorkshopItemID == item.id
                    self.finishBackgroundDownload(key, stillWanted: stillWanted) {
                        self.useWorkshopVideo(video, credit: item.credit)
                        self.steamCopyToRemove = folder   // after loadSource, which forgets the last one
                    } discard: {}   // Steam's copy stays, like any Workshop download
                }
            } catch {
                await MainActor.run {
                    self.steamDownloader = nil
                    if case SteamDownloadError.notOwned = error { self.ownsWallpaperEngine = false; self.ownershipCheckedAt = .now }
                    self.failBackgroundDownload(key, error, cancelled: { if case SteamDownloadError.cancelled = $0 { true } else { false } })
                }
            }
        }
    }

    // MARK: - Add from URL

    /// Opens the Add from URL dialog, filled in with a web address from the clipboard if there is one.
    func openURLImport() {
        guard !isBusy, !isInspectingLink else { return }
        closeLinkCollection()
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
        if linkCollection != nil, let duration = selectedLinkVideo?.duration, let start, start >= duration {
            return "The video is only \(clockText(duration)) long."
        }
        return nil
    }

    /// Downloads one video from a web address (a video file, or a page via yt-dlp) and opens it like an added video.
    /// With a start or end time, only that part is downloaded.
    func importURL(_ text: String) {
        guard !isBusy, !isInspectingLink else { return }
        guard let url = URLImporter.webAddress(text) else { fail(URLImportError.notAWebAddress); return }
        downloadURL(url, section: YTDLP.canDownloadSections ? urlImportSection : nil)
    }

    /// Lists the videos at a playlist, board, channel, … link to pick one from (LinkCollectionDialog).
    /// A link to a single video is downloaded right away.
    func findLinkVideos(_ text: String) {
        guard !isBusy, !isInspectingLink else { return }
        guard let url = URLImporter.webAddress(text) else { fail(URLImportError.notAWebAddress); return }
        guard YTDLP.find() != nil else { requestURLImportTools(); return }
        isInspectingLink = true
        let importer = URLImporter()
        urlImporter = importer
        let directory = Self.workDir()
        Task.detached {
            do {
                let contents = try await importer.inspect(url, into: directory)
                await MainActor.run {
                    guard self.urlImporter === importer else { return }   // cancelled meanwhile
                    self.isInspectingLink = false
                    switch contents {
                    case .video(let info): self.downloadURL(url, section: nil, info: info)
                    case .collection(let collection) where collection.videos.isEmpty:
                        self.fail(URLImportError.noVideos)
                    case .collection(let collection): self.showLinkCollection(collection)
                    }
                }
            } catch {
                await MainActor.run {
                    guard self.urlImporter === importer else { return }
                    self.isInspectingLink = false
                    if case URLImportError.cancelled = error { return }
                    self.fail(error)
                }
            }
        }
    }

    /// Cancel in the Add from URL dialog: also stops looking at the link.
    func closeURLImport() {
        if isInspectingLink {
            urlImporter?.cancel()
            urlImporter = nil
            isInspectingLink = false
        }
        showURLImport = false
    }

    private func showLinkCollection(_ collection: LinkCollection) {
        showURLImport = false
        linkCollection = collection
        selectedLinkVideoID = collection.videos.count == 1 ? collection.videos[0].id : nil
        linkThumbnails = [:]
        urlImportStart = ""
        urlImportEnd = ""
        for video in collection.videos {
            guard let url = video.thumbnail else { continue }
            Task { if let image = await Self.remoteImage(url), linkCollection == collection { linkThumbnails[video.id] = image } }
        }
    }

    var selectedLinkVideo: LinkVideo? { linkCollection?.videos.first { $0.id == selectedLinkVideoID } }

    /// Selecting a video again deselects it. The part to download is asked per video, so it starts empty.
    func selectLinkVideo(_ video: LinkVideo) {
        selectedLinkVideoID = video.id == selectedLinkVideoID ? nil : video.id
        urlImportStart = ""
        urlImportEnd = ""
    }

    /// Downloads the picked video (only the part typed under the grid, if any): from what the list knew about it,
    /// or else through its own link.
    func importSelectedLinkVideo() {
        guard !isBusy, let video = selectedLinkVideo, urlImportSectionProblem == nil else { return }
        let section = YTDLP.canDownloadSections ? urlImportSection : nil
        closeLinkCollection()
        var info: URL?
        if let data = video.info {
            let file = Self.workDir().appending(path: "url-\(UUID().uuidString).info.json")
            if (try? data.write(to: file)) != nil { info = file }
        }
        downloadURL(video.url, section: section, info: info)
    }

    /// Back: the Add from URL dialog with the link again.
    func backFromLinkCollection() {
        let link = linkCollection?.link.absoluteString
        closeLinkCollection()
        urlImportStart = ""
        urlImportEnd = ""
        if let link { urlImportText = link }
        showURLImport = true
    }

    func closeLinkCollection() {
        linkCollection = nil
        selectedLinkVideoID = nil
        linkThumbnails = [:]
    }

    /// Downloads one video from a web address; `info` is yt-dlp's look at it from `importURL`.
    private func downloadURL(_ url: URL, section: (start: Double?, end: Double?)?, info: URL? = nil) {
        guard !isBusy else { return }
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
                let (file, title) = try await importer.run(url, section: section, info: info, into: directory) { p in
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

    // MARK: - Wallpaper Engine (Steam Workshop)

    /// Opens the Wallpaper Engine dialog and looks for downloads again (new subscriptions show up this way).
    func openWorkshopImport() {
        guard !isBusy else { return }
        showWorkshopImport = true
        rescanWorkshop()
    }

    func rescanWorkshop() {
        guard !isWorkshopScanning else { return }
        isWorkshopScanning = true
        Task.detached {
            let scan = WallpaperEngine.scan()
            await MainActor.run {
                self.workshopScan = scan
                self.isWorkshopScanning = false
                Log.info("Wallpaper Engine: \(scan.videos.count) video wallpapers, \(scan.skipped) others in \(scan.sources)")
                self.loadWorkshopThumbnails(scan.videos)
            }
        }
    }

    private func loadWorkshopThumbnails(_ videos: [WorkshopVideo]) {
        let missing = videos.filter { workshopThumbnails[$0.id] == nil }
        guard !missing.isEmpty else { return }
        Task.detached {
            for video in missing {
                guard let preview = video.preview, let image = WallpaperEngine.thumbnail(preview) else { continue }
                await MainActor.run { self.workshopThumbnails[video.id] = image }
            }
        }
    }

    /// Add Folder…: a Steam folder somewhere else (another bottle, an external disk) or a folder of wallpapers.
    func addWorkshopFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a Steam folder, its Wallpaper Engine downloads, or any folder of wallpapers."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        if !WallpaperEngine.addedFolders.contains(folder) { WallpaperEngine.addedFolders.append(folder) }
        rescanWorkshop()
    }

    /// The Workshop's video wallpapers, in Steam when it handles steam:// links, else in the browser.
    func openWorkshopPage() {
        let steam = NSWorkspace.shared.urlForApplication(toOpen: WallpaperEngine.workshopSteamPage) != nil
        NSWorkspace.shared.open(steam ? WallpaperEngine.workshopSteamPage : WallpaperEngine.workshopWebPage)
    }

    /// Opens a Workshop video like a video the user added. The file stays where Steam put it and is only read.
    /// `credit` is the creator from Discover ("<name> on the Steam Workshop"); a downloaded item alone doesn't name them.
    func useWorkshopVideo(_ video: WorkshopVideo, credit: String? = nil) {
        guard !isBusy else { return }
        showWorkshopImport = false
        if let old = convertedTempURL { try? FileManager.default.removeItem(at: old); convertedTempURL = nil }
        sourceCredit = (credit ?? "a Steam Workshop creator", video.page?.absoluteString)
        loadSource(video.video, displayName: video.title)
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

    /// Downloads and decodes off the main actor (nonisolated).
    nonisolated private static func remoteImage(_ url: URL) async -> NSImage? {
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
        // A Workshop pick shows its still preview: Steam has no video to stream.
        if section == .discover, selectedWorkshopItem != nil { return nil }
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
        steamCopyToRemove = nil
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
        steamCopyToRemove = nil
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
        pendingConversionName = displayName   // set on both paths, so an earlier, cancelled conversion's title never sticks
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
        let name = pendingConversionName ?? source.deletingPathExtension().lastPathComponent
        pendingConversionName = nil
        displayName = name
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
                    self.loadSource(destination, displayName: name)
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
                                       credit: sourceCredit?.credit, sourcePage: sourceCredit?.page)
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

    /// The manual check (⚙ menu, app menu): offers the update when there is a newer version (or opens the release
    /// page when it can't be installed from here).
    func checkForUpdates() {
        Task {
            do {
                if let update = try await UpdateChecker.check(force: true) {
                    availableUpdate = update
                    if canInstallUpdate {
                        notice = Notice(kind: .info, text: "AerialSwap \(update.version) is available. Update from the ⚙ menu.")
                    } else {
                        NSWorkspace.shared.open(update.page)
                    }
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

    /// The available update can be installed right here (it has a signed zip and this copy can be replaced).
    var canInstallUpdate: Bool { availableUpdate?.zip != nil && availableUpdate?.signature != nil && Updater.canInstall }

    /// Downloads, checks and installs the update, then relaunches. Falls back to the release page when that fails.
    func installUpdate() {
        guard let update = availableUpdate, let zip = update.zip, let signature = update.signature, Updater.canInstall else {
            openUpdate(); return
        }
        guard !isBusy else { return }
        isBusy = true; workFlow = .quick; phase = "Updating to AerialSwap \(update.version)"; notice = nil
        Task {
            do {
                let app = try await Updater.install(zip: zip, signature: signature)
                Updater.relaunch(app)
            } catch {
                Log.error("Update failed: \(error.localizedDescription)")
                stopProgress()
                notice = Notice(kind: .error, text: "Couldn't update: \(error.localizedDescription) "
                                + "You can download it from the ⚙ menu instead.")
                availableUpdate?.zip = nil   // the ⚙ menu now offers the download page
            }
        }
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
        downloader?.cancel()        // Discover downloads in the background (cancelBackgroundDownload)
        steamDownloader?.cancel()
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
        if backgroundDownload == nil { Self.removeWorkDir() }   // nothing in it is needed any more (a Pixabay download may be)
        if let folder = steamCopyToRemove, discoverOptions.removeSteamCopy {
            Task {
                await Task.detached { SteamDownload.removeCopy(folder) }.value
                refreshSteamDownloads()
            }
        }
        steamCopyToRemove = nil
    }

    private func fail(_ error: Error) {
        let text = error.localizedDescription
        notice = Notice(kind: .error, text: text)
        Log.error(text)
    }
}
