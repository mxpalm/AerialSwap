import AppKit
import SwiftUI
import Synchronization

/// Entry point: runs the SwiftUI app, or a small CLI when started with --transcode / --list / --snapshot.
@main
enum Main {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if ["--transcode", "--list", "--sync-group", "--remove-group"].contains(args.first ?? "") {
            Task { exit(await CLI.run(args)) }
            dispatchMain()
        }
        if args.first == "--snapshot" {
            // ImageRenderer needs the real main thread, so keep its run loop going (dispatchMain would exit it).
            Task { @MainActor in exit(await Snapshot.run(args)) }
            RunLoop.main.run()
        }
        AerialSwapApp.main()
    }
}

struct AerialSwapApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    private let model = AppModel()

    var body: some Scene {
        Window("AerialSwap", id: "main") {
            ContentView(model: model)
        }
        .windowToolbarStyle(.unified(showsTitle: false))   // controls on the row of the traffic lights
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { model.checkForUpdates() }
            }
            CommandGroup(replacing: .newItem) {
                Button("Add Video File…") { model.showImporter = true }
                    .keyboardShortcut("o")
                    .disabled(model.isBusy)
                Button("Add Video from URL…") { model.openURLImport() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(model.isBusy || model.screen != .home)
            }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1180, height: 760)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Headless helpers. --list and --transcode never touch the aerials folder; --sync-group (run by GroupWatcher's
/// LaunchAgent) and --remove-group write the AerialSwap group (see AerialGroup).
///   AerialSwap --list
///   AerialSwap --transcode <in> <out.mov> [--fps auto|60|120|240] [--start s] [--end s] [--loop s] [--interpolate] [--enhance] [--freeze s]
///   AerialSwap --sync-group
///   AerialSwap --remove-group
enum CLI {
    static func run(_ args: [String]) async -> Int32 {
        let store = AerialStore()
        if args.first == "--sync-group" { return await syncGroup() }
        if args.first == "--remove-group" {
            do {
                GroupWatcher.uninstall()
                try await AerialGroup().remove()
                print("AerialSwap group removed")
                return 0
            } catch {
                print("error: \(error.localizedDescription)"); return 1
            }
        }
        if args.first == "--list" {
            do {
                let selection = store.detectSelection()
                print("Selected: desktop=\(selection.desktop ?? "-") idle=\(selection.idle ?? "-")")
                for asset in try store.listAssets() {
                    print("\(asset.id)  \(asset.name)\(asset.isOwn ? "  (AerialSwap)" : "")")
                }
                return 0
            } catch {
                print("error: \(error.localizedDescription)"); return 1
            }
        }

        guard args.count >= 3 else {
            print("usage: AerialSwap --list | --sync-group | --remove-group | --transcode <in> <out.mov> [--fps auto|60|120|240] [--start s] [--end s] [--loop s] [--interpolate] [--enhance] [--freeze s]")
            return 2
        }
        var options = TranscodeOptions()
        var fixedFPS: Int?   // nil = pick from the source like the app does
        var i = 3
        while i < args.count {
            if args[i] == "--interpolate" { options.interpolate = true; i += 1; continue }   // flag without value
            if args[i] == "--enhance" { options.enhance = true; i += 1; continue }
            guard i + 1 < args.count else { print("missing value for \(args[i])"); return 2 }
            let value = Double(args[i + 1])
            switch args[i] {
            case "--fps": fixedFPS = args[i + 1] == "auto" ? nil : Int(value ?? 60)
            case "--start": options.trimStart = value ?? 0
            case "--end": options.trimEnd = value
            case "--freeze": options.freezeSeconds = value ?? 0
            case "--loop": options.loopCrossfade = value ?? 0
            default: print("unknown option \(args[i])"); return 2
            }
            i += 2
        }
        let source = URL(fileURLWithPath: args[1]), destination = URL(fileURLWithPath: args[2])
        if destination.path.hasPrefix(store.aerialsDir.path) {
            print("error: output must not be inside the aerials folder"); return 2
        }
        if let fixedFPS {
            options.fps = fixedFPS
        } else {
            do {
                let info = try await Transcoder.inspect(source)
                options.fps = Transcoder.autoFPS(forSource: info.fps)
                print("source \(info.fps) fps -> output \(options.fps) fps (auto)")
            } catch {
                print("error: \(error.localizedDescription)"); return 1
            }
        }
        do {
            let started = Date.now
            let lastPrinted = Mutex(-1)
            try await Transcoder().run(source: source, destination: destination, options: options) { p in
                let pct = Int(p * 100)
                lastPrinted.withLock { last in
                    if pct / 10 != last / 10 { print("progress \(pct)%"); last = pct }
                }
            }
            print(String(format: "done in %.1fs -> %@", Date.now.timeIntervalSince(started), destination.path))
            return 0
        } catch {
            print("error: \(error.localizedDescription)"); return 1
        }
    }
}

extension CLI {
    /// Puts the group back after macOS replaced entries.json. If it had to do that 3 times within 10 minutes, something
    /// keeps undoing it (e.g. a newer macOS that rejects the group), so it stops instead of restarting WallpaperAgent
    /// over and over; opening the app syncs again.
    static func syncGroup() async -> Int32 {
        let defaults = UserDefaults.standard
        let recent = (defaults.array(forKey: "groupSyncTimes") as? [Double] ?? []).filter { Date.now.timeIntervalSince1970 - $0 < 600 }
        let items = WallpaperLibrary().load()
        let group = AerialGroup()
        if recent.count >= 3, !items.isEmpty, !group.isInstalled {
            Log.error("Group: macOS removed the AerialSwap group 3 times in 10 minutes; not adding it again until AerialSwap is opened")
            return 1
        }
        do {
            if try await group.sync(items) {
                defaults.set(recent + [Date.now.timeIntervalSince1970], forKey: "groupSyncTimes")
            }
            return 0
        } catch {
            Log.error("Group: \(error.localizedDescription)")
            return 1
        }
    }
}
