import AppKit
import IOKit.ps
import SwiftUI

/// AerialSwap → Settings… (⌘,). Plain UserDefaults keys, so the settings window (@AppStorage) and the code that acts
/// on them read the same values. Removing Steam's copy is part of DiscoverOptions (it was in Discover's menu first).
enum Preferences {
    static let startSteamForWorkshopKey = "StartSteamForWorkshop"
    static let quitSteamKey = "QuitSteamItStarted"
    static let previewUpscalingKey = "PreviewUpscaling"
    static let defaultMotionKey = "DefaultMotion"
    static let defaultSeamlessLoopKey = "DefaultSeamlessLoop"
    static let defaultEnhanceDetailKey = "DefaultEnhanceDetail"
    static let checksForUpdatesKey = "ChecksForUpdates"

    /// Opening the Workshop in Discover starts Steam, so a download doesn't wait for it to open and log in.
    static var startsSteamForWorkshop: Bool { bool(startSteamForWorkshopKey, default: false) }
    /// Quitting AerialSwap quits Steam too, when AerialSwap started it (see SteamDownload.quitIfStarted).
    static var quitsSteam: Bool { bool(quitSteamKey, default: true) }
    static var previewUpscaling: PreviewUpscaling {
        UserDefaults.standard.string(forKey: previewUpscalingKey).flatMap(PreviewUpscaling.init) ?? .always
    }
    static var defaultMotion: MotionMode {
        UserDefaults.standard.string(forKey: defaultMotionKey).flatMap(MotionMode.init) ?? .smooth
    }
    static var defaultSeamlessLoop: Bool { bool(defaultSeamlessLoopKey, default: true) }
    static var defaultEnhanceDetail: Bool { bool(defaultEnhanceDetailKey, default: false) }
    /// The daily check at launch; Check for Updates… works either way.
    static var checksForUpdates: Bool { bool(checksForUpdatesKey, default: true) }

    private static func bool(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }
}

/// When small Workshop previews are upscaled with Apple's ML upscaler (see PreviewUpscaler).
enum PreviewUpscaling: String, CaseIterable, Identifiable {
    case always, pluggedIn, never
    var id: String { rawValue }
    var title: String {
        switch self {
        case .always: "Always"
        case .pluggedIn: "Only When Plugged In"
        case .never: "Never"
        }
    }

    var isAllowedNow: Bool {
        switch self {
        case .always: true
        case .pluggedIn: !Self.isOnBattery
        case .never: false
        }
    }

    /// A Mac without a battery always reports AC power.
    static var isOnBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return type as String == kIOPSBatteryPowerValue
    }
}

/// Temp files and caches that "Delete Temporary Files" removes. Downloads and transcodes in progress live in the work
/// folder, so that is left alone while AerialSwap is working.
enum TemporaryData {
    private static var caches: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches") }
    /// Discover's cached results and macOS's compiled ML models (both made again when needed); `local.aerialswap` is
    /// from before 1.0.
    private static var cacheFolders: [URL] {
        var folders = [caches.appending(path: "AerialSwap"), caches.appending(path: "local.aerialswap")]
        if let id = Bundle.main.bundleIdentifier { folders.append(caches.appending(path: id)) }
        return folders
    }
    /// URLCache's own files: emptied with removeAllCachedResponses, never deleted under it.
    private static let urlCacheFiles: Set<String> = ["Cache.db", "Cache.db-shm", "Cache.db-wal", "fsCachedData"]

    static func size(workDir: URL) -> Int64 {
        ([workDir] + cacheFolders).reduce(0) { $0 + bytes(in: $1) }
    }

    static func remove(workDir: URL?) {
        let fm = FileManager.default
        URLCache.shared.removeAllCachedResponses()
        if let workDir { try? fm.removeItem(at: workDir) }
        for folder in cacheFolders {
            for item in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            where !urlCacheFiles.contains(item.lastPathComponent) {
                try? fm.removeItem(at: item)
            }
        }
        Log.info("Removed temporary files and caches")
    }

    private static func bytes(in folder: URL) -> Int64 {
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

// MARK: - Window

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings(model: model) }
            Tab("New Wallpapers", systemImage: "photo.on.rectangle") { WallpaperSettings() }
            Tab("Workshop", systemImage: "square.stack.3d.down.right") { WorkshopSettings(model: model) }
        }
        .frame(width: 520)
    }
}

private struct GeneralSettings: View {
    @Bindable var model: AppModel
    @AppStorage(Preferences.checksForUpdatesKey) private var checksForUpdates = true
    @State private var temporaryBytes: Int64?

    var body: some View {
        Form {
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $checksForUpdates)
                Text("Once a day, when AerialSwap opens. Check for Updates… in the ⚙ menu works either way.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Storage") {
                LabeledContent("Temporary files and caches") {
                    HStack {
                        Text(temporaryBytes.map { $0.formatted(.byteCount(style: .file)) } ?? "…").foregroundStyle(.secondary)
                        Button("Delete") {
                            model.removeTemporaryData()
                            measure()
                        }
                        .disabled(temporaryBytes == 0)
                    }
                }
                Text("Discover's cached results, compiled ML models and leftovers of conversions. Your library isn't touched; "
                     + "AerialSwap makes these again when it needs them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: measure)
    }

    private func measure() {
        let workDir = AppModel.workDirURL
        Task {
            temporaryBytes = await Task.detached { TemporaryData.size(workDir: workDir) }.value
        }
    }
}

private struct WallpaperSettings: View {
    @AppStorage(Preferences.defaultMotionKey) private var motion = MotionMode.smooth
    @AppStorage(Preferences.defaultSeamlessLoopKey) private var seamlessLoop = true
    @AppStorage(Preferences.defaultEnhanceDetailKey) private var enhanceDetail = false

    var body: some View {
        Form {
            Section {
                Picker("Motion", selection: $motion) {
                    Text("Original").tag(MotionMode.original)
                    Text("Smooth · 60 fps").tag(MotionMode.smooth)
                    Text("Maximum · 120 fps").tag(MotionMode.maximum)
                }
                Toggle("Seamless loop", isOn: $seamlessLoop)
                Toggle("Enhance detail", isOn: $enhanceDetail)
            } header: {
                Text("Defaults for a new video")
            } footer: {
                Text("What a video starts with before you change it. Motion applies where the video's frame rate allows it, "
                     + "Enhance detail to videos up to 1080p; it's slow: about a second per frame.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct WorkshopSettings: View {
    @Bindable var model: AppModel
    @AppStorage(Preferences.startSteamForWorkshopKey) private var startsSteam = false
    @AppStorage(Preferences.quitSteamKey) private var quitsSteam = true
    @AppStorage(Preferences.previewUpscalingKey) private var upscaling = PreviewUpscaling.always

    var body: some View {
        Form {
            Section("Steam") {
                Toggle("Start Steam when opening the Workshop", isOn: $startsSteam)
                Toggle("Quit Steam with AerialSwap if AerialSwap started it", isOn: $quitsSteam)
                Toggle("Remove Steam's copy after saving",
                       isOn: Binding(get: { model.discoverOptions.removeSteamCopy }, set: { model.setRemoveSteamCopy($0) }))
                Text("Otherwise AerialSwap starts Steam, hidden, only when you download. Steam keeps running in the background "
                     + "and uses power, so quitting it saves battery. Removing the copy keeps items you're subscribed to.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Previews") {
                Picker("Upscale small previews", selection: $upscaling) {
                    ForEach(PreviewUpscaling.allCases) { Text($0.title).tag($0) }
                }
                Text("Small Workshop previews are sharpened 4x with Apple's ML upscaler: 2-4 seconds of work for each one you select.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }
}
