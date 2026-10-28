import AppKit
import AVKit
import SwiftUI
import UniformTypeIdentifiers

/// Switches between the full-window screens and shows the dialogs on top.
struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        ZStack {
            screen
            overlays
        }
        .frame(minWidth: 960, minHeight: 640)
        .background(Color.black)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)   // the video fills the window behind the toolbar
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .tint(Theme.accent)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, !model.isBusy else { return false }
            if url.isFileURL { model.loadSource(url) } else { model.importURL(url.absoluteString) }   // a link from a browser
            return true
        } isTargeted: { model.isDropTargeted = $0 }
        .animation(animation(.snappy(duration: 0.25)), value: model.screen)
        .animation(animation(.snappy(duration: 0.2)), value: model.section)
        .animation(animation(.snappy(duration: 0.2)), value: model.notice)
        .animation(animation(.snappy(duration: 0.2)), value: model.done)
        .animation(animation(.snappy(duration: 0.2)), value: model.showURLImport)
        .onAppear {
            model.refreshAssets()
            // Debug: `AerialSwap.app/Contents/MacOS/AerialSwap --open <video>` starts on the Configure screen.
            let args = CommandLine.arguments
            if !model.isSnapshot, let i = args.firstIndex(of: "--open"), i + 1 < args.count {
                model.showIntro = false
                model.loadSource(URL(fileURLWithPath: args[i + 1]))
            }
        }
        .task(id: model.notice) {
            // Confirmations go away by themselves; errors stay until dismissed.
            guard let notice = model.notice, notice.kind != .error else { return }
            try? await Task.sleep(for: .seconds(6))
            if model.notice == notice { model.notice = nil }
        }
        .fileImporter(isPresented: $model.showImporter, allowedContentTypes: [.movie, .video, .audiovisualContent]) { result in
            if case .success(let url) = result { model.loadSource(url) }
        }
        .confirmationDialog("Set as wallpaper?", isPresented: $model.confirmSetWallpaper) {
            Button("Set as Wallpaper") { model.setAsWallpaper() }
        } message: {
            Text(confirmText)
        }
        .confirmationDialog("Delete from your library?", isPresented: deleteBinding) {
            Button("Delete", role: .destructive) { if let item = model.deleteCandidate { model.deleteLibraryItem(item) } }
        } message: {
            Text(deleteText)
        }
        .alert("Install helpers?", isPresented: toolInstallBinding) {
            Button("Install") { model.installTools() }
            Button("Cancel", role: .cancel) { model.cancelToolInstall() }
        } message: {
            Text(model.toolInstallText)
        }
        .alert("Convert this video first?", isPresented: conversionBinding) {
            Button("Convert with ffmpeg") { model.convertPending() }
            Button("Cancel", role: .cancel) { model.pendingConversion = nil }
        } message: {
            Text(model.conversionPrompt)
        }
    }

    /// No animations in --snapshot renders: ImageRenderer would capture screens halfway through their transition.
    private func animation(_ animation: Animation) -> Animation? { model.isSnapshot ? nil : animation }

    @ViewBuilder private var screen: some View {
        switch model.screen {
        case .intro: IntroView(model: model)
        case .home: HomeView(model: model)
        case .configure: ConfigureView(model: model)
        case .working: WorkingView(model: model)
        }
    }

    @ViewBuilder private var overlays: some View {
        if model.screen == .configure, model.showResolutionAlert, let hint = model.resolutionHint {
            LowResolutionDialog(model: model, text: hint.text)
        }
        if model.screen == .home, let done = model.done {
            SuccessDialog(model: model, done: done)
        }
        if model.screen == .home, model.showURLImport {
            URLImportDialog(model: model)
        }
        if model.workFlow == .quick {
            QuickBusyOverlay(phase: model.phase)
        }
        if let notice = model.notice, model.screen != .working {
            NoticeToast(notice: notice) { model.notice = nil }
        }
        if model.isDropTargeted {
            DropHighlight()
        }
    }

    private var confirmText: String {
        let systemWarning = AerialStore.untestedSystemWarning.map { "\n\n\($0)" } ?? ""
        let place = "It's shown on your desktop and screen saver, and you'll find it in System Settings → Wallpaper → AerialSwap."
        if model.isUsingLibrary, let item = model.selectedLibraryItem {
            return "“\(prettyName(item.name))” from your library becomes your wallpaper. \(place)" + systemWarning
        }
        let video = model.displayName ?? ""
        var warning = model.enhances ? "\n\nEnhance detail: \(model.enhanceWarning)" : ""
        if let hint = model.resolutionHint, hint.severe { warning += "\n\n\(hint.text)" }
        return "“\(video)” becomes your wallpaper. \(place)\n\nPreparing the video takes \(model.estimateText)."
            + warning + systemWarning
    }

    private var deleteText: String {
        guard let item = model.deleteCandidate else { return "" }
        let removed = "“\(prettyName(item.name))” will be removed from your library and the AerialSwap group."
        if let role = model.roleTitle(for: item.id) {
            return removed + " It's your \(role.lowercased()) right now, so macOS will show something else there."
        }
        return removed
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { model.deleteCandidate != nil }, set: { if !$0 { model.deleteCandidate = nil } })
    }

    /// The buttons decide (Install / Cancel, which Esc triggers too), so dismissing alone changes nothing:
    /// SwiftUI may clear the binding before it runs the button's action.
    private var toolInstallBinding: Binding<Bool> {
        Binding(get: { model.toolInstallRequest != nil }, set: { _ in })
    }

    private var conversionBinding: Binding<Bool> {
        Binding(get: { model.pendingConversion != nil }, set: { if !$0 { model.pendingConversion = nil } })
    }
}

// MARK: - Shared chrome

/// Library | Discover, centered in the top bar.
struct SectionSwitcher: View {
    @Bindable var model: AppModel

    var body: some View {
        PillPicker(options: [.init(value: HomeSection.library, title: "Library"), .init(value: .discover, title: "Discover")],
                   selection: Binding(get: { model.section },
                                      set: { if $0 == .discover { model.openDiscover() } else { model.section = $0 } }),
                   label: "Section")
            .glassCapsule(opacity: 0.45)
            .disabled(model.isBusy)
    }
}

/// Add Video + the Settings menu, on the right of the top bar.
struct TopBarActions: View {
    @Bindable var model: AppModel

    var body: some View {
        AddVideoMenu(model: model, kind: .primary, height: 32)

        Menu {
            if let update = model.availableUpdate {
                Button("Download AerialSwap \(update.version)…") { model.openUpdate() }
                Divider()
            }
            Button("Open Wallpaper Settings") { model.openWallpaperSettings() }
            Button("Show Library in Finder") { model.revealLibrary() }
            Button("Open Log") { model.openLog() }
            Divider()
            Button("Check for Updates…") { model.checkForUpdates() }
            Button("Show Welcome Screen") { model.showIntroAgain() }
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(RoundGlassButtonStyle())
        .fixedSize()
        .help("More")
        .accessibilityLabel("More")
    }
}

/// "Add Video ⌄": a video file from this Mac, or a video from a web address. `before` runs first
/// (e.g. selecting the Aerial the video is for). ⌘O and ⌘⇧O do the same from the File menu.
struct AddVideoMenu: View {
    @Bindable var model: AppModel
    var title = "Add Video"
    var kind = PillButtonStyle.Kind.primary
    var height: CGFloat = 40
    var fullWidth = false
    var before: () -> Void = {}

    var body: some View {
        Menu {
            Button("Video File…", systemImage: "folder") { before(); model.showImporter = true }
            Button("From URL…", systemImage: "link") { before(); model.openURLImport() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                Text(title)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).opacity(0.8)
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(PillButtonStyle(kind: kind, height: height, fullWidth: fullWidth))
        .fixedSize(horizontal: !fullWidth, vertical: false)
        .disabled(model.isBusy)
        .help("Add a video file from this Mac, or a video from a web address")
    }
}

/// The video's name in a capsule, centered in the top bar while configuring or working.
struct TitleCapsule: View {
    let title: String
    var detail: String?
    var detailColor = Theme.secondary

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
            if let detail { Text(detail).font(.system(size: 13)).foregroundStyle(detailColor).lineLimit(1) }
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .glassCapsule()
        .frame(maxWidth: 520)
    }
}

/// AVKit's player view, used full-window as the live lock-screen preview.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    /// Starts transparent and fades in once the first frame is ready, so the still frame below turns into the video.
    var fadesIn = false

    @MainActor final class Coordinator {
        weak var view: AVPlayerView?
        var readiness: NSKeyValueObservation?

        func fadeInIfReady() {
            guard let view, view.isReadyForDisplay, view.alphaValue < 1 else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.8
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                view.animator().alphaValue = 1
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.showsFullScreenToggleButton = false
        view.videoGravity = .resizeAspectFill   // the same 16:9 center crop the wallpaper gets
        view.player = player
        context.coordinator.view = view
        if fadesIn { watchReadiness(view, context.coordinator) }
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        guard view.player !== player else { return }
        view.player = player
        if fadesIn { watchReadiness(view, context.coordinator) }
    }

    private func watchReadiness(_ view: AVPlayerView, _ coordinator: Coordinator) {
        view.alphaValue = 0
        coordinator.readiness = view.observe(\.isReadyForDisplay, options: [.initial]) { [weak coordinator] _, _ in
            DispatchQueue.main.async { coordinator?.fadeInIfReady() }
        }
    }
}
