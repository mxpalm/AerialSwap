import SwiftUI

// MARK: - Working

/// Preparing a new video (or converting one with ffmpeg): progress ring over the blurred video.
struct WorkingView: View {
    @Bindable var model: AppModel

    private var steps: [(WorkStep, String)] {
        switch model.workFlow {
        case .download: [(.download, "Download from \(model.downloadSource)")]
        case .tools: [(.download, "Install from \(model.downloadSource)")]
        case .convert: [(.convert, "Convert with ffmpeg")]
        case .saveOnly: [(.prepare, "Prepare 4K"), (.save, "Save to library")]
        default: [(.prepare, "Prepare 4K"), (.save, "Save to library"), (.show, "Set as wallpaper")]
        }
    }

    var body: some View {
        ZStack {
            Backdrop(image: model.backdrops["source"] ?? model.desktopAsset.flatMap { model.backdrops[model.backdropKey(for: $0)] },
                     blur: 28, scrim: .dark)
            VStack(spacing: 0) {
                Spacer()
                VStack(spacing: 26) {
                    ring
                    VStack(spacing: 6) {
                        Text(model.phase.isEmpty ? "Working" : model.phase)
                            .font(.system(size: 26, weight: .bold)).multilineTextAlignment(.center)
                        Text(explanation)
                            .font(.system(size: 15)).foregroundStyle(Theme.secondary)
                            .multilineTextAlignment(.center).frame(maxWidth: 520)
                    }
                    if steps.count > 1 { stepPills }
                    if model.showsProgress || model.workFlow == .download || model.workFlow == .tools {
                        Button("Cancel") { model.cancel() }
                            .buttonStyle(PillButtonStyle(kind: .secondary, height: 38))
                            .keyboardShortcut(.cancelAction)
                    }
                }
                .padding(.horizontal, 24)
                Spacer()
            }
        }
        .screenToolbar(snapshot: model.isSnapshot) {
            if model.workFlow == .convert || model.workFlow == .download || model.workFlow == .tools {
                TitleCapsule(title: model.displayName ?? "")
            } else {
                TitleCapsule(title: model.displayName ?? "",
                             detail: model.workFlow == .saveOnly ? "→ Library" : "→ Wallpaper")
            }
        } trailing: { EmptyView() }
    }

    private var ring: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.16), lineWidth: 9)
            Circle()
                .trim(from: 0, to: model.showsProgress ? model.progress : 1)
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.3), value: model.progress)
            VStack(spacing: 2) {
                if model.showsProgress {
                    Text("\(Int(model.progress * 100))%").font(.system(size: 52, weight: .bold)).monospacedDigit()
                    // Re-render once per second so the estimate stays current.
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(model.remainingText).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    }
                } else {
                    ProgressView().controlSize(.large)
                    Text(model.workFlow == .tools ? "Installing" : model.workStep == .download ? "Downloading" : "Almost done")
                        .font(.system(size: 13)).foregroundStyle(Theme.secondary).padding(.top, 6)
                }
            }
        }
        .frame(width: 220, height: 220)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.phase)
        .accessibilityValue(model.showsProgress ? "\(Int(model.progress * 100)) percent, \(model.remainingText)" : "Almost done")
    }

    private var stepPills: some View {
        HStack(spacing: 4) {
            ForEach(steps, id: \.0) { step, title in
                let state: Int = step < model.workStep ? -1 : (step == model.workStep ? 0 : 1)
                HStack(spacing: 6) {
                    if state < 0 {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(Theme.success)
                    } else {
                        Circle()
                            .fill(state == 0 ? Theme.accent : .clear)
                            .overlay(Circle().strokeBorder(state == 0 ? .clear : Theme.secondary, lineWidth: 1.5))
                            .frame(width: 7, height: 7)
                    }
                    Text(title)
                }
                .font(.system(size: 13, weight: state == 0 ? .semibold : .regular))
                .foregroundStyle(state == 0 ? Theme.onAccent : (state < 0 ? .white.opacity(0.85) : Theme.secondary))
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Capsule().fill(state == 0 ? Color.white : .clear))
            }
        }
        .padding(5)
        .glassCapsule(opacity: 0.55)
    }

    private var explanation: String {
        switch model.workStep {
        case .download:
            return model.downloadDetail
        case .convert:
            return "Making a temporary copy macOS can read. Your original file isn't touched."
        case .prepare:
            let motion = model.interpolates ? "Generating in-between frames for smooth \(model.outputFPS) fps motion. "
                : "Encoding 4K HEVC with the frame layers macOS needs. "
            let tail = model.workFlow == .saveOnly ? "Your wallpaper stays as it is." : "Keep working — nothing changes on your Mac until the last step."
            return motion + tail
        case .save:
            return "Keeping it in your library, so switching back later takes seconds."
        case .show:
            return "Adding it to the AerialSwap group and switching your desktop and screen saver to it."
        }
    }
}

// MARK: - Dialogs

/// A frosted dialog centered over a dimmed screen.
private struct DialogContainer<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea().accessibilityHidden(true)
            content
                .padding(24)
                .frame(maxWidth: 560)
                .glassPanel(cornerRadius: 24, opacity: 0.76)
                .shadow(color: .black.opacity(0.4), radius: 40, y: 20)
                .padding(24)
        }
        .transition(.opacity)
    }
}

/// Add from URL: a link to a video file, or a web page that yt-dlp can download from.
struct URLImportDialog: View {
    @Bindable var model: AppModel
    @FocusState private var fieldFocused: Bool

    private var isValid: Bool { URLImporter.webAddress(model.urlImportText) != nil }

    var body: some View {
        DialogContainer {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Add from URL").font(.system(size: 22, weight: .bold))
                    Text("A link to a video file, or a page on YouTube, Vimeo and many other sites.")
                        .font(.system(size: 14)).foregroundStyle(Theme.secondary)
                }
                HStack(spacing: 8) {
                    Image(systemName: "link").foregroundStyle(Theme.secondary).accessibilityHidden(true)
                    RenderableTextField("https://", text: $model.urlImportText, flat: model.isSnapshot)
                        .textFieldStyle(.plain)
                        .focused($fieldFocused)
                        .onSubmit { if isValid && model.urlImportSectionProblem == nil { model.importURL(model.urlImportText) } }
                }
                .font(.system(size: 14))
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(Capsule().fill(Color.white.opacity(0.1)))
                toolHint
                sectionFields
                HStack(spacing: 10) {
                    Text("Only use videos you're allowed to use.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    Spacer(minLength: 0)
                    Button("Cancel") { model.showURLImport = false }
                        .buttonStyle(PillButtonStyle(kind: .quiet, height: 42))
                        .fixedSize()
                        .keyboardShortcut(.cancelAction)
                    Button("Download") { model.importURL(model.urlImportText) }
                        .buttonStyle(PillButtonStyle(kind: .primary, height: 42))
                        .fixedSize()
                        .keyboardShortcut(.defaultAction)
                        .disabled(!isValid || model.urlImportSectionProblem != nil)
                }
            }
        }
        .onAppear { fieldFocused = true }
    }

    /// Optional start and end, so a long video isn't downloaded whole (needs yt-dlp and ffmpeg).
    @ViewBuilder private var sectionFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("Only download").font(.system(size: 13, weight: .semibold))
                timeField("start", text: $model.urlImportStart)
                Text("to").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                timeField("end", text: $model.urlImportEnd)
                Spacer(minLength: 0)
            }
            .disabled(!YTDLP.canDownloadSections)
            Group {
                if !YTDLP.canDownloadSections {
                    Text("Downloading only part of a video needs yt-dlp and ffmpeg (Install… above).")
                        .foregroundStyle(Theme.secondary)
                } else if let problem = model.urlImportSectionProblem {
                    Text(problem).foregroundStyle(Theme.warning)
                } else {
                    Text("Optional, e.g. 1:30 to 1:45. Leave empty for the whole video.").foregroundStyle(Theme.secondary)
                }
            }
            .font(.system(size: 12))
        }
    }

    private func timeField(_ placeholder: String, text: Binding<String>) -> some View {
        RenderableTextField(placeholder, text: text, flat: model.isSnapshot)
            .textFieldStyle(.plain)
            .font(.system(size: 13).monospacedDigit())
            .multilineTextAlignment(.center)
            .frame(width: 72, height: 30)
            .background(Capsule().fill(Color.white.opacity(0.1)))
            .onSubmit { if isValid && model.urlImportSectionProblem == nil { model.importURL(model.urlImportText) } }
    }

    /// Whether web pages work: yt-dlp (with deno and ffmpeg) is optional, direct video links always work.
    /// Missing helpers can be installed from here.
    @ViewBuilder private var toolHint: some View {
        let missing = Tool.missingForURLImport
        if missing.isEmpty {
            Label("Pages are downloaded with yt-dlp: the best video up to 4K, without sound.", systemImage: "checkmark.circle")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
        } else {
            HStack(spacing: 10) {
                Label(YTDLP.find() == nil
                      ? "Only direct video links work right now. YouTube, Vimeo and others need yt-dlp."
                      : "Missing \(ListFormatter.localizedString(byJoining: missing.map(\.rawValue))) for some sites and for parts of videos.",
                      systemImage: "info.circle")
                    .font(.system(size: 12)).foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Install…") { model.requestURLImportTools() }
                    .buttonStyle(PillButtonStyle(kind: .secondary, height: 30))
                    .fixedSize()
            }
        }
    }
}

/// After Set as Wallpaper: what now plays where, over the Library.
struct SuccessDialog: View {
    @Bindable var model: AppModel
    let done: DoneInfo

    var body: some View {
        DialogContainer {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .heavy))
                        .foregroundStyle(Color(red: 0.02, green: 0.14, blue: 0.06))
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Theme.successFill))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title)
                            .font(.system(size: 20, weight: .bold))
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(subtitle).font(.system(size: 14)).foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if done.summary != nil || done.savedToLibrary {
                            HStack(spacing: 6) {
                                if let summary = done.summary { StatusPill(text: summary, checked: true) }
                                if done.savedToLibrary { StatusPill(text: "In your library", checked: true) }
                            }
                            .padding(.top, 4)
                        }
                    }
                }
                Text(hint)
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Spacer()
                    Button("Open Wallpaper Settings") { model.openWallpaperSettings() }
                        .buttonStyle(PillButtonStyle(kind: .secondary, height: 40))
                        .fixedSize()
                    Button("Done") { model.finishDone() }
                        .buttonStyle(PillButtonStyle(kind: .primary, height: 40))
                        .fixedSize()
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .onExitCommand { model.finishDone() }
    }

    private var title: String {
        if done.role.isEmpty { return "\(prettyName(done.videoName)) is in the AerialSwap group" }
        return "\(done.role) now plays \(prettyName(done.videoName))"
    }

    private var hint: String {
        if done.role.isEmpty {
            return "Your desktop doesn't show an Aerial right now, so pick it yourself: System Settings → Wallpaper → AerialSwap."
        }
        return "It's in System Settings → Wallpaper → AerialSwap, next to Apple's Aerials."
    }

    private var subtitle: String {
        guard let took = done.took else { return "Lock your Mac to see it." }
        let time = took < 90 ? "\(Int(took.rounded())) s" : "\(Int(took / 60)) min \(Int(took.truncatingRemainder(dividingBy: 60))) s"
        return "Took \(time). Lock your Mac to see it."
    }
}

/// Right after choosing a video that has to be enlarged a lot: show roughly how soft it will look.
struct LowResolutionDialog: View {
    @Bindable var model: AppModel
    let text: String

    var body: some View {
        DialogContainer {
            VStack(alignment: .leading, spacing: 18) {
                previews
                VStack(alignment: .leading, spacing: 6) {
                    Text("This video will look blurry").font(.system(size: 22, weight: .bold))
                    Text(text).font(.system(size: 14)).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.canEnhance {
                    Label("Enhance detail can help a little. About \(model.enhanceMinutes) min for this clip, results vary.",
                          systemImage: "sparkles")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(red: 0.89, green: 0.86, blue: 1))
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color(red: 0.7, green: 0.6, blue: 1).opacity(0.16)))
                }
                HStack(spacing: 10) {
                    Button("Choose Another Video…") {
                        model.showResolutionAlert = false
                        model.showImporter = true
                    }
                    .buttonStyle(PillButtonStyle(kind: .primary, height: 42))
                    .fixedSize()
                    .keyboardShortcut(.defaultAction)
                    if model.canEnhance {
                        Button("Use Enhance") {
                            model.enhanceDetail = true
                            model.showResolutionAlert = false
                        }
                        .buttonStyle(PillButtonStyle(kind: .secondary, height: 42))
                        .fixedSize()
                    }
                    Spacer(minLength: 0)
                    Button("Continue Anyway") { model.showResolutionAlert = false }
                        .buttonStyle(PillButtonStyle(kind: .quiet, height: 42))
                        .fixedSize()
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
    }

    /// Left: a piece of the frame at real size on this display. Right: the whole frame, with that piece outlined.
    private var previews: some View {
        let size = ResolutionPreview.size
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    Color.black
                    if let preview = model.resolutionPreview {
                        Image(nsImage: preview.actualSize).interpolation(.none)   // 1 image pixel = 1 screen pixel
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(width: size.width, height: size.height)
                .clipShape(shape)
                Text(model.resolutionPreview.map {
                    "Actual size on this display · \($0.factor.formatted(.number.precision(.fractionLength(1))))× enlarged"
                } ?? "Actual size on this display")
                .font(.system(size: 12)).foregroundStyle(Color(red: 1, green: 0.81, blue: 0.54)).lineLimit(2)
            }
            .frame(width: size.width, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    Color.black
                    if let preview = model.resolutionPreview {
                        Image(nsImage: preview.frame).resizable().aspectRatio(contentMode: .fit)
                            .overlay {
                                GeometryReader { geo in
                                    Rectangle()
                                        .strokeBorder(Theme.accent, lineWidth: 2)
                                        .frame(width: max(8, geo.size.width * preview.region.width),
                                               height: max(6, geo.size.height * preview.region.height))
                                        .offset(x: geo.size.width * preview.region.minX, y: geo.size.height * preview.region.minY)
                                }
                            }
                    }
                }
                .frame(width: size.width, height: size.height)
                .clipShape(shape)
                Text("The whole video · outlined part shown left").font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(2)
            }
            .frame(width: size.width, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of a part of the video at actual size on this display")
    }
}

// MARK: - Small overlays

/// Quick switches (a library wallpaper, Use For) take seconds; no full screen for those.
struct QuickBusyOverlay: View {
    let phase: String

    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text("\(phase)…").font(.system(size: 14, weight: .semibold))
        }
        .padding(.horizontal, 20)
        .frame(height: 48)
        .glassCapsule(opacity: 0.75)
        .transition(.opacity)
    }
}

struct NoticeToast: View {
    let notice: Notice
    let dismiss: () -> Void

    var body: some View {
        VStack {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: icon).foregroundStyle(color).accessibilityHidden(true)
                Text(notice.text)
                    .font(.system(size: 13))
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 11, weight: .bold)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.secondary)
                    .help("Dismiss")
                    .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(maxWidth: 640)
            .glassPanel(cornerRadius: 16, opacity: 0.8)
            .padding(.top, 44)          // under the toolbar and the Desktop / Screen Saver chips
            Spacer()
        }
        .transition(.move(edge: .top).combined(with: .opacity))
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
        case .info: Theme.secondary
        case .success: Theme.success
        case .error: Color(red: 1, green: 0.48, blue: 0.42)
        }
    }
}

struct DropHighlight: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18).fill(Theme.accent.opacity(0.08))
            RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.accent, lineWidth: 3)
            Label("Drop to use this video", systemImage: "arrow.down.circle.fill")
                .font(.system(size: 20, weight: .semibold))
                .padding(.horizontal, 20)
                .frame(height: 50)
                .glassCapsule(opacity: 0.75)
        }
        .padding(8)
        .allowsHitTesting(false)
    }
}
