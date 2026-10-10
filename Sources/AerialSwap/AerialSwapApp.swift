import AppKit
import SwiftUI
import Synchronization

/// Entry point: runs the SwiftUI app, or a small CLI when started with --transcode / --list.
@main
enum Main {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "--transcode" || args.first == "--list" {
            Task { exit(await CLI.run(args)) }
            dispatchMain()
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
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Headless helpers for testing without the UI. Never touches the aerials folder.
///   AerialSwap --list
///   AerialSwap --transcode <in> <out.mov> [--fps auto|60|120|240] [--start s] [--end s] [--freeze s]
enum CLI {
    static func run(_ args: [String]) async -> Int32 {
        let store = AerialStore()
        if args.first == "--list" {
            do {
                let selection = store.detectSelection()
                print("Selected: desktop=\(selection.desktop ?? "-") idle=\(selection.idle ?? "-")")
                for asset in try store.listAssets() {
                    print("\(asset.id)  \(asset.name)  status=\(store.status(of: asset))  backup=\(store.hasBackup(asset))")
                }
                return 0
            } catch {
                print("error: \(error.localizedDescription)"); return 1
            }
        }

        guard args.count >= 3 else {
            print("usage: AerialSwap --transcode <in> <out.mov> [--fps auto|60|120|240] [--start s] [--end s] [--freeze s]")
            return 2
        }
        var options = TranscodeOptions()
        var fixedFPS: Int?   // nil = pick from the source like the app does
        var i = 3
        while i + 1 < args.count {
            let value = Double(args[i + 1])
            switch args[i] {
            case "--fps": fixedFPS = args[i + 1] == "auto" ? nil : Int(value ?? 60)
            case "--start": options.trimStart = value ?? 0
            case "--end": options.trimEnd = value
            case "--freeze": options.freezeSeconds = value ?? 0
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
