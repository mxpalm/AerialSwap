import AppKit
import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 26) {
                sourceSection
                targetSection
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
            .disabled(model.isBusy)
            bottomBar
        }
        .frame(width: 780)
        .fixedSize(horizontal: false, vertical: true)
        .containerBackground(.regularMaterial, for: .window)
        .overlay { if model.isDropTargeted { dropHighlight } }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, !model.isBusy else { return false }
            model.loadSource(url)
            return true
        } isTargeted: { model.isDropTargeted = $0 }
        .animation(.snappy(duration: 0.25), value: model.sourceInfo == nil)
        .animation(.snappy(duration: 0.2), value: model.selectedID)
        .animation(.snappy(duration: 0.2), value: model.notice)
        .animation(.snappy(duration: 0.2), value: model.showsProgress)
        .onAppear { model.refreshAssets() }
        .fileImporter(isPresented: $model.showImporter, allowedContentTypes: [.movie, .video, .audiovisualContent]) { result in
            if case .success(let url) = result { model.loadSource(url) }
        }
        .confirmationDialog("Set as wallpaper?", isPresented: $model.confirmSetWallpaper) {
            Button("Set as Wallpaper") { model.setAsWallpaper() }
        } message: {
            Text(confirmText)
        }
        .confirmationDialog("Restore Apple's original?", isPresented: restoreBinding) {
            Button("Restore Original") { if let a = model.restoreCandidate { model.restore(a) } }
        } message: {
            Text("“\(model.restoreCandidate?.name ?? "")” will play Apple's video again.")
        }
        .alert("Convert this video?", isPresented: conversionBinding) {
            Button("Convert with ffmpeg") { model.convertPending() }
            Button("Cancel", role: .cancel) { model.pendingConversion = nil }
        } message: {
            Text(model.conversionPrompt)
        }
    }

    private var confirmText: String {
        let target = model.selectedAsset?.name ?? ""
        let video = model.displayName ?? ""
        return "“\(target)” will play “\(video)”.\n\nPreparing the video takes \(model.estimateText). "
            + "Apple's original is backed up first and can be restored at any time."
    }

    private var restoreBinding: Binding<Bool> {
        Binding(get: { model.restoreCandidate != nil }, set: { if !$0 { model.restoreCandidate = nil } })
    }

    private var conversionBinding: Binding<Bool> {
        Binding(get: { model.pendingConversion != nil }, set: { if !$0 { model.pendingConversion = nil } })
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text("AerialSwap").font(.title2.weight(.bold))
                Text("Turn any video into a native macOS Aerial wallpaper.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.top, 38)      // room for the traffic lights (hidden title bar)
        .padding(.bottom, 22)
    }

    // MARK: - Video

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Video")
            if let info = model.sourceInfo {
                loadedSource(info)
            } else {
                emptySource
            }
        }
    }

    private var emptySource: some View {
        VStack(spacing: 10) {
            Image(systemName: "film.stack")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
            Text(model.sourceURL == nil ? "Drop a video here" : "Loading…")
                .font(.title3.weight(.semibold))
            Text("Any length works. MP4 and MOV are used directly; MKV, WebM and others are converted with ffmpeg.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button("Choose Video…") { model.showImporter = true }
                .controlSize(.large)
                .keyboardShortcut("o")
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 236)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(.quaternary.opacity(0.5))
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
        }
    }

    private func loadedSource(_ info: SourceInfo) -> some View {
        HStack(alignment: .top, spacing: 22) {
            preview
            details(info)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 245, alignment: .top)
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Color.black
                if let player = model.player {
                    PlayerView(player: player, model: model)
                }
            }
            .frame(width: 400, height: 225)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.08)))
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            Text("Preview shows the 16:9 crop your screen will get.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func details(_ info: SourceInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.displayName ?? "")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.displayName ?? "")
                Spacer(minLength: 8)
                Button { model.clearSource() } label: {
                    Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Remove this video")
            }

            FlowChips(chips: chips(for: info))

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                FieldLabel("Clip")
                Text(clipText(info)).font(.callout).monospacedDigit()
                HStack(spacing: 8) {
                    Button { model.beginTrim() } label: { Label("Trim…", systemImage: "timeline.selection") }
                        .disabled(model.player == nil)
                    if model.isTrimmed {
                        Button("Use Whole Video") { model.resetTrim() }
                    }
                }
                .controlSize(.small)
                .padding(.top, 2)
                Toggle("Smooth loop", isOn: $model.smoothLoop)
                    .toggleStyle(.checkbox)
                    .font(.callout)
                    .disabled(!model.canSmoothLoop)
                    .help("The lock screen loops your clip. This crossfades its last second into the first, "
                          + "so the loop has no visible cut. Needs a clip of at least 3 seconds.")
                    .padding(.top, 4)
            }

            VStack(alignment: .leading, spacing: 4) {
                FieldLabel("Becomes")
                Text(outputText(info))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)   // wrap instead of truncating
            }

            Spacer(minLength: 0)
            Button("Choose Another Video…") { model.showImporter = true }
                .buttonStyle(.link)
                .font(.callout)
                .keyboardShortcut("o")
        }
    }

    private func chips(for info: SourceInfo) -> [Chip] {
        let fps = info.fps.formatted(.number.precision(.fractionLength(0...2)))
        var chips = [
            Chip(icon: "clock", text: clock(info.duration)),
            Chip(icon: "rectangle.dashed", text: "\(info.width)×\(info.height)"),
            Chip(icon: "film", text: "\(fps) fps"),
        ]
        if let hdr = info.hdr { chips.append(Chip(icon: "sun.max.fill", text: hdr, tint: .orange)) }
        return chips
    }

    private func clipText(_ info: SourceInfo) -> String {
        guard model.isTrimmed else { return "Whole video · \(clock(info.duration))" }
        let length = clock(model.trimEnd - model.trimStart)
        return "\(clock(model.trimStart)) – \(clock(model.trimEnd))  ·  \(length)"
    }

    private func outputText(_ info: SourceInfo) -> String {
        let loop = model.smoothLoop && model.canSmoothLoop ? " · seamless loop" : ""
        let base = "4K HEVC · \(model.outputFPS) fps · no sound" + loop
        return info.hdr == nil ? base : base + " · converted to SDR"
    }

    // MARK: - Target

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle("Wallpaper to replace")
                Spacer()
                if !model.selectionNote.isEmpty {
                    Text(model.selectionNote).font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.assets.isEmpty {
                Text("No downloaded Aerials found. Pick any Aerial in System Settings → Wallpaper first, then come back.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                cards
                if let asset = model.selectedAsset {
                    selectedAssetActions(asset)
                }
            }
        }
    }

    private var cards: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 16) {
                ForEach(model.assets) { asset in
                    AerialCard(asset: asset,
                               image: model.thumbnails[asset.id],
                               status: model.statuses[asset.id] ?? .original,
                               isSelected: model.selectedID == asset.id,
                               isHovered: model.hoveredAssetID == asset.id)
                        .onTapGesture { model.select(asset) }
                        .onHover { model.hoveredAssetID = $0 ? asset.id : nil }
                }
            }
            .padding(4)     // room for the selection ring and shadow
        }
        .scrollIndicators(.never)
    }

    private func selectedAssetActions(_ asset: AerialAsset) -> some View {
        HStack(spacing: 10) {
            switch model.statuses[asset.id] ?? .original {
            case .original:
                Image(systemName: "lock.shield").foregroundStyle(.secondary)
                Text("Apple's original is backed up automatically before it's replaced.")
                    .foregroundStyle(.secondary)
                Spacer()
            case .replaced(let name, let date, let protected):
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                Text(playingText(name: name, date: date, protected: protected))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Restore Apple's Original") { model.restoreCandidate = asset }
            case .resetByMacOS:
                Image(systemName: "exclamationmark.arrow.circlepath").foregroundStyle(.orange)
                Text("macOS put Apple's video back, e.g. after an update.")
                Spacer()
                if model.store.canReinstall(asset) {
                    Button("Reinstall My Video") { model.reinstall(asset) }
                        .buttonStyle(.borderedProminent)
                }
                if model.store.hasBackup(asset) {
                    Button("Keep Apple's") { model.restoreCandidate = asset }
                }
            }
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.6)))
    }

    private func playingText(name: String, date: Date, protected: Bool) -> String {
        let when = date.formatted(date: .abbreviated, time: .shortened)
        return "Playing “\(name)” since \(when)" + (protected ? " · protected" : "")
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 14) {
            statusArea
            if !model.showsProgress {
                moreMenu
                Button { model.confirmSetWallpaper = true } label: {
                    Label("Set as Wallpaper", systemImage: "sparkles").padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSetWallpaper)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .frame(minHeight: 66)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder private var statusArea: some View {
        if model.showsProgress {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(model.phase).font(.callout.weight(.medium)).lineLimit(1)
                    Spacer()
                    // Re-render once per second so the estimate stays current.
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text("\(Int(model.progress * 100)) %  ·  \(model.remainingText)")
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                ProgressView(value: model.progress)
            }
            Button("Cancel") { model.cancel() }
        } else if model.isBusy {
            ProgressView().controlSize(.small)
            Text("\(model.phase)…").font(.callout)
            Spacer()
        } else if let notice = model.notice {
            NoticeView(notice: notice) { model.notice = nil }
            Spacer(minLength: 8)
        } else {
            Text(hint).font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var moreMenu: some View {
        Menu {
            Button("Show Backups in Finder") { model.revealBackups() }
            Button("Open Log") { model.openLog() }
        } label: {
            Image(systemName: "ellipsis.circle").font(.title3)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More options")
        .disabled(model.isBusy)
    }

    private var hint: String {
        if model.sourceInfo == nil { return "Add a video to get started." }
        guard let asset = model.selectedAsset else { return "Pick the wallpaper to replace." }
        return "Ready: your video will replace “\(asset.name)”."
    }

    private var dropHighlight: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16).fill(Color.accentColor.opacity(0.08))
            RoundedRectangle(cornerRadius: 16).strokeBorder(Color.accentColor, lineWidth: 3)
            Label("Drop to use this video", systemImage: "arrow.down.circle.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(Capsule().fill(.regularMaterial))
        }
        .padding(8)
        .allowsHitTesting(false)
    }

    /// 1:05.3 style for short times, 12:05 for long ones.
    private func clock(_ seconds: Double) -> String {
        let s = max(0, seconds)
        let minutes = Int(s) / 60
        if minutes >= 10 { return String(format: "%d:%02d", minutes, Int(s) % 60) }
        return String(format: "%d:%04.1f", minutes, s.truncatingRemainder(dividingBy: 60))
    }
}

// MARK: - Components

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }
}

private struct FieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }
}

private struct Chip: Hashable {
    var icon: String
    var text: String
    var tint: Color? = nil
}

private struct FlowChips: View {
    let chips: [Chip]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(chips, id: \.self) { chip in
                HStack(spacing: 4) {
                    Image(systemName: chip.icon).imageScale(.small)
                    Text(chip.text)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(chip.tint ?? .primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(chip.tint?.opacity(0.15) ?? Color.secondary.opacity(0.14)))
                .fixedSize()
            }
        }
    }
}

/// Lays out children left to right and wraps to a new row when the width runs out.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, maxWidth: proposal.width ?? .infinity)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.map { $0.height }.reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, maxWidth: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > maxWidth && !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

private struct AerialCard: View {
    let asset: AerialAsset
    let image: NSImage?
    let status: AerialStatus
    let isSelected: Bool
    let isHovered: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            thumbnail
            VStack(alignment: .leading, spacing: 1) {
                Text(asset.name).font(.callout.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, 2)
        }
        .frame(width: 200)
        .contentShape(Rectangle())
        .help(asset.name)
    }

    private var thumbnail: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(colors: [.indigo.opacity(0.5), .teal.opacity(0.4)], startPoint: .top, endPoint: .bottom)
                }
            }
            .frame(width: 200, height: 112)
            .clipped()
            badge.padding(7)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(ringColor, lineWidth: isSelected ? 3 : 1)
        }
        .overlay(alignment: .topTrailing) {
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
                    .padding(7)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .shadow(color: .black.opacity(isSelected ? 0.3 : 0.15), radius: isSelected ? 8 : 4, y: 3)
        .scaleEffect(isHovered && !isSelected ? 1.02 : 1)
        .animation(.snappy(duration: 0.15), value: isHovered)
    }

    private var ringColor: Color {
        if isSelected { return .accentColor }
        return .white.opacity(isHovered ? 0.35 : 0.1)
    }

    @ViewBuilder private var badge: some View {
        switch status {
        case .original: EmptyView()
        case .replaced: Badge(text: "Your video", color: .green)
        case .resetByMacOS: Badge(text: "Reset by macOS", color: .orange)
        }
    }

    private var subtitle: String {
        switch status {
        case .original: "Apple original"
        case .replaced(let name, _, _): name
        case .resetByMacOS: "Apple's video is back"
        }
    }
}

private struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.gradient))
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
    }
}

private struct NoticeView: View {
    let notice: Notice
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            Text(notice.text)
                .font(.callout)
                .lineLimit(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: dismiss) { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9).fill(color.opacity(0.12)))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var icon: String {
        switch notice.kind {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch notice.kind {
        case .info: .blue
        case .success: .green
        case .error: .red
        }
    }
}

/// AVKit's AppKit player view (needed for its built-in QuickTime-style trim bar).
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    let model: AppModel

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = false
        view.videoGravity = .resizeAspectFill   // show the same 16:9 center crop the wallpaper gets
        view.player = player
        model.playerView = view
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
        model.playerView = view
    }
}
