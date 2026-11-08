import SceneEngine
import SwiftUI

/// A new scene: full-window live preview, the wallpaper's settings and the frame rate on the right.
struct SceneConfigureView: View {
    @Bindable var model: AppModel
    @Bindable var setup: SceneSetup

    var body: some View {
        ZStack {
            background
            HeaderEdgeEffect()
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 20) {
                    Spacer(minLength: 0)
                    SceneOptionsPanel(model: model, setup: setup).frame(width: 340)
                }
                .padding(.horizontal, 18)
                Spacer(minLength: 16)
                if let problem = setup.previewProblem {
                    HStack {
                        Label("The preview stopped: \(problem)", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12)).lineLimit(2)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .glassPanel(cornerRadius: 14, opacity: 0.62)
                        Spacer(minLength: 0)
                    }
                    .padding(16)
                }
            }
        }
        .screenToolbar(snapshot: model.isSnapshot) {
            TitleCapsule(title: model.displayName ?? "", detail: "Scene · live preview")
        } trailing: {
            Button("Cancel") { model.clearSource() }
                .buttonStyle(PillButtonStyle(kind: .secondary, height: 32))
                .keyboardShortcut(.cancelAction)
        }
        .onAppear { if !model.isSnapshot { setup.startPreview() } }
        .onDisappear { setup.stopPreview() }
    }

    @ViewBuilder private var background: some View {
        if let frame = setup.frame {
            GeometryReader { geo in
                Image(nsImage: frame).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.height).clipped()
            }
            .ignoresSafeArea()
            .overlay(scrim)
            .accessibilityLabel("Live preview of the scene")
        } else {
            Backdrop(image: model.backdrops["source"])
                .overlay { ProgressView().controlSize(.large) }
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
}

private struct SceneOptionsPanel: View {
    @Bindable var model: AppModel
    @Bindable var setup: SceneSetup

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
                if case .worksWithout = setup.verdict {
                    Text(setup.verdict.detail)
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.1)))
                }
                if !setup.properties.isEmpty { settings }
                frameRate

                Rectangle().fill(.white.opacity(0.14)).frame(height: 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text("4K HEVC · \(setup.fps) fps · seamless loop").font(.system(size: 13))
                    Text("Takes \(model.estimateText) · then in System Settings → Wallpaper → AerialSwap")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Set as Wallpaper") { model.confirmSetWallpaper = true }
                    .buttonStyle(PillButtonStyle(kind: .primary, height: 44, fullWidth: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSetWallpaper)
                Button("Only save to library") { model.saveToLibraryOnly() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(maxWidth: .infinity)
                    .disabled(model.isBusy)
            }
            .padding(18)
        }
        .glassPanel(opacity: 0.7)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                OptionLabel(title: "Wallpaper settings")
                Spacer()
                if setup.isChanged {
                    Button("Reset") { setup.reset() }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.accent)
                }
            }
            ForEach(setup.visibleProperties) { property in
                ScenePropertyRow(property: property, setup: setup)
            }
        }
    }

    private var frameRate: some View {
        VStack(alignment: .leading, spacing: 8) {
            OptionLabel(title: "Frame rate")
            PillPicker(options: [.init(value: 60, title: "60 fps", subtitle: "Smooth"),
                                 .init(value: 120, title: "120 fps", subtitle: "ProMotion")],
                       selection: $setup.fps, label: "Frame rate", fill: true)
                .help("Scenes are drawn frame by frame, so 120 fps is real motion, not in-between frames. "
                      + "It takes about twice as long and twice the space.")
        }
    }
}

/// One of the wallpaper's settings, as its kind needs: a switch, a slider, a menu or a color well.
private struct ScenePropertyRow: View {
    let property: SceneProject.Property
    @Bindable var setup: SceneSetup

    private var value: SceneJSON { setup.values[property.id] ?? property.value }

    var body: some View {
        switch property.kind {
        case .toggle:
            Toggle(isOn: Binding(get: { value.bool ?? false }, set: { setup.set(property.id, .bool($0)) })) {
                Text(property.title).font(.system(size: 13))
            }
            .toggleStyle(AccentSwitchStyle())
        case .slider(let low, let high, let step, let integer):
            slider(low: low, high: high, step: integer ? max(1, step ?? 1) : step, integer: integer)
        case .choice(let options):
            HStack {
                Text(property.title).font(.system(size: 13))
                Spacer(minLength: 8)
                Picker(property.title, selection: Binding(
                    get: { options.firstIndex { Self.same($0.value, value) } ?? -1 },
                    set: { index in if options.indices.contains(index) { setup.set(property.id, options[index].value) } }
                )) {
                    ForEach(options.indices, id: \.self) { index in
                        Text(SceneProject.Property.displayText(options[index].label, fallback: "Option \(index + 1)")).tag(index)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        case .color:
            HStack {
                Text(property.title).font(.system(size: 13))
                Spacer(minLength: 8)
                ColorPicker(property.title, selection: Binding(
                    get: { Color(nsColor: value.sceneColor ?? .white) },
                    set: { setup.set(property.id, SceneJSON(sceneColor: NSColor($0))) }
                ), supportsOpacity: false)
                .labelsHidden()
            }
        case .text, .other:
            EmptyView()
        }
    }

    private func slider(low: Double, high: Double, step: Double?, integer: Bool) -> some View {
        let range = low < high ? low...high : low...(low + 1)
        let binding = Binding(get: { min(max(value.number ?? low, range.lowerBound), range.upperBound) },
                              set: { setup.set(property.id, .number(integer ? $0.rounded() : $0)) })
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(property.title).font(.system(size: 13))
                Spacer(minLength: 8)
                Text(binding.wrappedValue.formatted(.number.precision(integer ? .fractionLength(0) : .fractionLength(0...2))))
                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.secondary)
            }
            if let step, step > 0 {
                Slider(value: binding, in: range, step: step).tint(Theme.accent)
            } else {
                Slider(value: binding, in: range).tint(Theme.accent)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Choice values are written loosely: "1" and 1 are the same option.
    private static func same(_ a: SceneJSON, _ b: SceneJSON) -> Bool {
        if a == b { return true }
        if let x = a.number, let y = b.number { return x == y }
        if let x = a.string, let y = b.string { return x == y }
        return false
    }
}
