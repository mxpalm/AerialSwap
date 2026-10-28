import SwiftUI

/// A new video: full-window live preview, options on the right, trim along the bottom.
struct ConfigureView: View {
    @Bindable var model: AppModel

    var body: some View {
        ZStack {
            background
            HeaderEdgeEffect()
            VStack(spacing: 0) {
                if model.sourceInfo == nil {
                    Spacer()
                    ProgressView("Loading…").controlSize(.large).padding(24).glassPanel()
                    Spacer()
                } else {
                    HStack(alignment: .top, spacing: 20) {
                        Spacer(minLength: 0)
                        OptionsPanel(model: model).frame(width: Self.panelWidth)
                    }
                    .padding(.horizontal, 18)
                    Spacer(minLength: 16)
                    TrimBar(model: model).padding(16)
                }
            }
        }
        .screenToolbar(snapshot: model.isSnapshot) {
            TitleCapsule(title: model.displayName ?? "", detail: detail)
        } trailing: {
            Button("Cancel") { model.clearSource() }
                .buttonStyle(PillButtonStyle(kind: .secondary, height: 32))
                .keyboardShortcut(model.showResolutionAlert ? nil : .cancelAction)
        }
    }

    private static let panelWidth: CGFloat = 340

    @ViewBuilder private var background: some View {
        if let player = model.player {
            PlayerView(player: player).ignoresSafeArea().overlay(scrim)
        } else {
            Backdrop(image: model.backdrops["source"])
        }
    }

    private var scrim: some View {
        let shade = Color(red: 0.03, green: 0.04, blue: 0.055)
        return LinearGradient(stops: [.init(color: shade.opacity(0.4), location: 0), .init(color: shade.opacity(0), location: 0.25),
                                      .init(color: shade.opacity(0), location: 0.6), .init(color: shade.opacity(0.5), location: 1)],
                              startPoint: .top, endPoint: .bottom)
            .allowsHitTesting(false)
            .ignoresSafeArea()
    }

    private var detail: String? {
        guard let info = model.sourceInfo else { return nil }
        let fps = info.fps.formatted(.number.precision(.fractionLength(0...2)))
        var parts = [clockText(info.duration), "\(info.width)×\(info.height)", "\(fps) fps"]
        if let hdr = info.hdr { parts.append(hdr) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Options

private struct OptionsPanel: View {
    @Bindable var model: AppModel

    /// Shown off (and disabled) when the clip is too short for the crossfade, whatever the stored choice is.
    private var loopBinding: Binding<Bool> {
        Binding(get: { model.smoothLoop && model.canSmoothLoop }, set: { model.smoothLoop = $0 })
    }

    private var nameBinding: Binding<String> {
        Binding(get: { model.displayName ?? "" }, set: { model.displayName = $0 })
    }

    var body: some View {
        FitOrScroll(flat: model.isSnapshot) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name in your library").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    RenderableTextField("Name", text: nameBinding, flat: model.isSnapshot)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.08)))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.18)))
                }
                if !model.availableMotionModes.isEmpty { motion }
                Toggle(isOn: loopBinding) {
                    OptionLabel(title: "Seamless loop",
                                subtitle: model.canSmoothLoop ? "No visible cut when it repeats" : "Needs a clip of at least 3 s")
                }
                .toggleStyle(AccentSwitchStyle())
                .disabled(!model.canSmoothLoop)
                if model.canEnhance {
                    Toggle(isOn: $model.enhanceDetail) {
                        OptionLabel(title: "Enhance detail", subtitle: "ML upscaling · experimental")
                    }
                    .toggleStyle(AccentSwitchStyle())
                    if model.enhanceDetail { callout(model.enhanceWarning, tint: Theme.warning) }
                }
                if let hint = model.resolutionHint, !hint.severe { callout(hint.text, tint: .white) }

                Rectangle().fill(.white.opacity(0.14)).frame(height: 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(becomes).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    Text("Takes \(model.estimateText) · then in System Settings → Wallpaper → AerialSwap")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                Button("Set as Wallpaper") { model.confirmSetWallpaper = true }
                    .buttonStyle(PillButtonStyle(kind: .primary, height: 44, fullWidth: true))
                    .keyboardShortcut(model.showResolutionAlert ? nil : .defaultAction)
                    .disabled(!model.canSetWallpaper)
                Button("Only save to library") { model.saveToLibraryOnly() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(maxWidth: .infinity)
                    .disabled(model.isBusy || model.sourceInfo == nil)
            }
            .padding(18)
        }
        .glassPanel(opacity: 0.7)
    }

    private var motion: some View {
        let fps = Int((model.sourceInfo?.fps ?? 30).rounded())
        let options = model.availableMotionModes.map { mode -> PillPicker<MotionMode>.Option in
            switch mode {
            case .original: .init(value: mode, title: "Original", subtitle: "\(fps) fps")
            case .smooth: .init(value: mode, title: "Smooth", subtitle: "60 fps")
            case .maximum: .init(value: mode, title: "Maximum", subtitle: "120 fps")
            }
        }
        return VStack(alignment: .leading, spacing: 8) {
            OptionLabel(title: "Motion")
            PillPicker(options: options, selection: $model.motionMode, label: "Motion", fill: true)
                .help("Smooth and Maximum generate real in-between frames, so motion and the slow-down after "
                      + "unlocking stay fluid. Maximum doubles the frames again and takes about twice as long.")
        }
    }

    private func callout(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(tint == .white ? Color.white.opacity(0.9) : Color(red: 1, green: 0.88, blue: 0.7))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(tint.opacity(tint == .white ? 0.1 : 0.18)))
    }

    private var becomes: String {
        guard let info = model.sourceInfo else { return "" }
        let fps = model.interpolates
            ? "\(model.outputFPS) fps smoothed from \(Int(info.fps.rounded()))" : "\(model.outputFPS) fps"
        var text = "4K HEVC · \(fps)"
        if model.enhances { text += " · enhanced detail" }
        if model.smoothLoop && model.canSmoothLoop { text += " · seamless loop" }
        if info.hdr != nil { text += " · converted to SDR" }
        return text
    }
}

// MARK: - Trim

/// Filmstrip with accent-colored handles; dragging a handle shows that frame in the preview.
struct TrimBar: View {
    @Bindable var model: AppModel

    var body: some View {
        let duration = max(model.sourceInfo?.duration ?? 1, 0.1)
        HStack(spacing: 14) {
            Button { model.togglePreviewPlayback() } label: {
                Image(systemName: model.isPreviewPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(RoundGlassButtonStyle())
            .accessibilityLabel(model.isPreviewPlaying ? "Pause preview" : "Play preview")
            Text(clockText(model.playhead)).monospacedDigit().fontWeight(.semibold)
                .frame(width: 52, alignment: .leading)
                .accessibilityLabel("Current position")
            GeometryReader { geo in
                strip(width: geo.size.width, duration: duration)
            }
            .frame(height: 44)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(clockText(model.trimStart)) – \(clockText(model.trimEnd))").monospacedDigit()
                Text("\(clockText(model.trimEnd - model.trimStart)) of \(clockText(duration))")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary).monospacedDigit()
                if model.isTrimmed {
                    Button("Use whole video") { model.resetTrim() }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.accent)
                }
            }
            .font(.system(size: 12))
            .frame(width: 118, alignment: .leading)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassPanel(cornerRadius: 18, opacity: 0.62)
    }

    private func strip(width: CGFloat, duration: Double) -> some View {
        let startX = width * model.trimStart / duration
        let endX = width * model.trimEnd / duration
        return ZStack(alignment: .leading) {
            HStack(spacing: 2) {
                ForEach(model.filmstrip.indices, id: \.self) { index in
                    Thumb(image: model.filmstrip[index], cornerRadius: 0)
                }
                if model.filmstrip.isEmpty { Color.white.opacity(0.08) }
            }
            .frame(width: width, height: 44)
            .background(Color.black)
            .contentShape(Rectangle())
            .gesture(scrubGesture(width: width, duration: duration))   // click or drag anywhere to jump there
            Rectangle().fill(.black.opacity(0.62)).frame(width: max(0, startX))
            Rectangle().fill(.black.opacity(0.62)).frame(width: max(0, width - endX)).offset(x: endX)
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Theme.accent, lineWidth: 3)
                .frame(width: max(20, endX - startX))
                .offset(x: startX)
                .allowsHitTesting(false)
            playheadView(duration: duration)
                .offset(x: min(max(width * model.playhead / duration - 7, startX + 4), endX - 18))
                .gesture(scrubGesture(width: width, duration: duration))
            handle.offset(x: startX)
                .gesture(drag(width: width, duration: duration) { model.setTrimStart($0) })
                .accessibilityLabel("Clip start")
                .accessibilityValue(clockText(model.trimStart))
            handle.offset(x: max(startX + 10, endX - 10))
                .gesture(drag(width: width, duration: duration) { model.setTrimEnd($0) })
                .accessibilityLabel("Clip end")
                .accessibilityValue(clockText(model.trimEnd))
        }
        .frame(width: width, height: 44, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .coordinateSpace(name: "trim")
    }

    /// A white line with a soft shadow, easy to grab (14 pt wide hit area).
    private func playheadView(duration: Double) -> some View {
        Capsule()
            .fill(.white)
            .frame(width: 4, height: 44)
            .shadow(color: .black.opacity(0.6), radius: 2)
            .frame(width: 14, height: 44)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
            }
            .accessibilityElement()
            .accessibilityLabel("Playback position")
            .accessibilityValue(clockText(model.playhead))
            .accessibilityAdjustableAction { direction in
                let step = direction == .increment ? 1.0 : -1.0
                model.scrubPlayhead(to: model.playhead + step)
                model.finishPlayheadDrag()
            }
    }

    private func scrubGesture(width: CGFloat, duration: Double) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("trim"))
            .onChanged { value in model.scrubPlayhead(to: Double(value.location.x / max(width, 1)) * duration) }
            .onEnded { _ in model.finishPlayheadDrag() }
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Theme.accent)
            .frame(width: 10, height: 44)
            .overlay(Capsule().fill(Theme.onAccent.opacity(0.6)).frame(width: 2, height: 16))
            .contentShape(Rectangle().inset(by: -6))
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
    }

    private func drag(width: CGFloat, duration: Double, _ set: @escaping (Double) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("trim"))
            .onChanged { value in set(Double(value.location.x / max(width, 1)) * duration) }
            .onEnded { _ in model.finishTrimDrag() }
    }
}
