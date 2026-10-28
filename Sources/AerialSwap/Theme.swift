import AppKit
import AVKit
import SwiftUI

/// The Lock Screen look: the video fills the window, controls sit on native Liquid Glass panels,
/// the main action is an Apple-blue glass pill.
enum Theme {
    static let accent = Color(red: 0.039, green: 0.518, blue: 1)          // #0a84ff, systemBlue in dark mode
    static let onAccent = Color.white
    static let ink = Color(red: 0.11, green: 0.11, blue: 0.118)           // #1c1c1e, text on white
    static let glass = Color(red: 0.063, green: 0.071, blue: 0.094)       // #101218
    static let secondary = Color(red: 0.788, green: 0.8, blue: 0.831)     // #c9ccd4, 4.5:1+ on the glass
    static let warning = Color(red: 1, green: 0.71, blue: 0.278)          // #ffb547
    static let onWarning = Color(red: 0.165, green: 0.114, blue: 0.031)
    static let success = Color(red: 0.369, green: 0.878, blue: 0.514)     // #5ee083
    static let successFill = Color(red: 0.204, green: 0.78, blue: 0.349)  // #34c759
    static let hairline = Color.white.opacity(0.14)
    /// How much of a panel's dark tint goes on the glass (1 = the old opaque frosted look, 0 = clear Liquid Glass).
    static let glassTint = 0.5
}

extension View {
    /// A native Liquid Glass panel. `opacity` adds a dark tint so text stays readable over bright video;
    /// the glass itself still refracts what's behind it.
    func glassPanel(cornerRadius: CGFloat = 22, opacity: Double = 0.66) -> some View {
        glassEffect(.regular.tint(Theme.glass.opacity(opacity * Theme.glassTint)),
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    func glassCapsule(opacity: Double = 0.6, interactive: Bool = false) -> some View {
        glassEffect(.regular.tint(Theme.glass.opacity(opacity * Theme.glassTint)).interactive(interactive), in: Capsule())
    }

    /// Text over the video: a soft shadow keeps it readable on bright frames.
    func overVideo() -> some View {
        shadow(color: .black.opacity(0.35), radius: 12, y: 2)
    }
}

// MARK: - Buttons

struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, light, quiet, warning }
    var kind: Kind = .primary
    var height: CGFloat = 40
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        PillLabel(configuration: configuration, kind: kind, height: height, fullWidth: fullWidth)
    }

    private struct PillLabel: View {
        let configuration: Configuration
        let kind: Kind
        let height: CGFloat
        let fullWidth: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: height >= 40 ? 14 : 13, weight: kind == .primary || kind == .warning ? .bold : .semibold))
                .lineLimit(1)
                .padding(.horizontal, height >= 40 ? 20 : 14)
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .frame(height: height)
                .foregroundStyle(foreground)
                .contentShape(Capsule())
                .modifier(PillGlass(kind: kind))
                .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
        }

        private var foreground: Color {
            switch kind {
            case .primary: Theme.onAccent
            case .warning: Theme.onWarning
            case .light: .white
            case .secondary, .quiet: .white
            }
        }

    }

    /// Prominent buttons are tinted glass, secondary ones clear glass; quiet ones have no background.
    private struct PillGlass: ViewModifier {
        let kind: Kind

        func body(content: Content) -> some View {
            switch kind {
            case .primary: content.glassEffect(.regular.tint(Theme.accent).interactive(), in: Capsule())
            case .warning: content.glassEffect(.regular.tint(Theme.warning).interactive(), in: Capsule())
            // A brighter clear glass: a white tint turns grey with dark text when the window is inactive.
            case .light: content.glassEffect(.regular.tint(.white.opacity(0.28)).interactive(), in: Capsule())
            case .secondary: content.glassEffect(.regular.interactive(), in: Capsule())
            case .quiet: content
            }
        }
    }
}

/// A round frosted icon button (Settings, close).
struct RoundGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .frame(width: 32, height: 32)
            .contentShape(Circle())
            .glassEffect(.regular.interactive(), in: Circle())
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

// MARK: - Controls

/// A row of pills where one is selected (section switcher, motion, album tabs).
struct PillPicker<Value: Hashable>: View {
    struct Option {
        var value: Value
        var title: String
        var subtitle: String? = nil
    }
    let options: [Option]
    @Binding var selection: Value
    var label: String
    var fill = false          // equal widths inside a track (motion), or hugging labels (sections)
    @Namespace private var namespace   // lets the white selection slide from one option to the next

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let isOn = option.value == selection
                Button {
                    withAnimation(.snappy(duration: 0.3)) { selection = option.value }
                } label: {
                    VStack(spacing: 1) {
                        Text(option.title).font(.system(size: 13, weight: isOn ? .semibold : .regular))
                        if let subtitle = option.subtitle {
                            Text(subtitle).font(.system(size: 11)).opacity(0.8)
                        }
                    }
                    .padding(.horizontal, fill ? 4 : 16)
                    .frame(maxWidth: fill ? .infinity : nil)
                    .frame(height: option.subtitle == nil ? 28 : 40)
                    .foregroundStyle(isOn ? Theme.ink : .white)
                    .background {
                        if isOn {
                            RoundedRectangle(cornerRadius: option.subtitle == nil ? 14 : 10, style: .continuous)
                                .fill(Color.white)
                                .matchedGeometryEffect(id: "selection", in: namespace)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(3)
        .background { RoundedRectangle(cornerRadius: options.first?.subtitle == nil ? 17 : 13, style: .continuous)
            .fill(Color.white.opacity(0.1)) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// The accent-colored switch from the design. Keeps the toggle's accessibility.
struct AccentSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(alignment: .center, spacing: 12) {
                configuration.label.frame(maxWidth: .infinity, alignment: .leading)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? Theme.accent : Color.white.opacity(0.22))
                    Circle().fill(configuration.isOn ? Theme.onAccent : .white).padding(3)
                }
                .frame(width: 44, height: 26)
                .animation(.snappy(duration: 0.18), value: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

/// Title + subtitle label for switches and rows.
struct OptionLabel: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 13, weight: .semibold))
            if let subtitle {
                Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Layout

/// A video frame filling the window, with a scrim so text and panels stay readable.
/// With a `player`, the video plays over the frame (the frame shows until the first video frame arrives).
struct Backdrop: View {
    enum Scrim { case standard, dark, side, clear }
    let image: NSImage?
    var player: AVPlayer? = nil
    var blur: CGFloat = 0
    var scrim = Scrim.standard

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Group {
                    if let image {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        LinearGradient(colors: [Color(red: 0.16, green: 0.22, blue: 0.34), Color(red: 0.05, green: 0.06, blue: 0.08)],
                                       startPoint: .top, endPoint: .bottom)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .scaleEffect(blur > 0 ? 1.12 : 1)
                .blur(radius: blur)
                if let player {
                    PlayerView(player: player, fadesIn: true).frame(width: geo.size.width, height: geo.size.height)
                        .transition(.opacity)
                }
                scrimView
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .animation(.easeOut(duration: 0.3), value: player.map(ObjectIdentifier.init))   // fade the video out on switch
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    @ViewBuilder private var scrimView: some View {
        let shade = Color(red: 0.03, green: 0.04, blue: 0.055)
        switch scrim {
        case .clear:
            Color.clear
        case .standard:
            LinearGradient(stops: [.init(color: shade.opacity(0.45), location: 0), .init(color: shade.opacity(0), location: 0.28),
                                   .init(color: shade.opacity(0.1), location: 0.5), .init(color: shade.opacity(0.75), location: 1)],
                           startPoint: .top, endPoint: .bottom)
        case .dark:
            shade.opacity(0.5)
        case .side:
            ZStack {
                LinearGradient(colors: [shade.opacity(0), shade.opacity(0.1), shade.opacity(0.6)], startPoint: .leading, endPoint: .trailing)
                LinearGradient(stops: [.init(color: shade.opacity(0.45), location: 0), .init(color: shade.opacity(0), location: 0.25),
                                       .init(color: shade.opacity(0.5), location: 1)], startPoint: .top, endPoint: .bottom)
            }
        }
    }
}

extension View {
    /// The window toolbar of a screen: `center` in the middle, `trailing` on the right, on the row of the traffic lights.
    /// ImageRenderer (--snapshot) can't draw window chrome, so there the same controls are drawn as a bar on top.
    func screenToolbar<Center: View, Trailing: View>(snapshot: Bool, @ViewBuilder center: () -> Center,
                                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        modifier(ScreenToolbar(snapshot: snapshot, center: center(), trailing: trailing()))
    }
}

private struct ScreenToolbar<Center: View, Trailing: View>: ViewModifier {
    let snapshot: Bool
    let center: Center
    let trailing: Trailing

    func body(content: Content) -> some View {
        if snapshot {
            content.safeAreaInset(edge: .top, spacing: 0) { TopBar { center } trailing: { trailing } }
        } else {
            // Our controls bring their own glass, so the toolbar's shared glass background is off.
            content.toolbar {
                ToolbarItem(placement: .principal) { GlassEffectContainer { center } }
                    .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .primaryAction) { GlassEffectContainer { HStack(spacing: 10) { trailing } } }
                    .sharedBackgroundVisibility(.hidden)
            }
        }
    }
}

/// The toolbar as a plain bar, for --snapshot renders (the real window uses the system toolbar, see screenToolbar).
struct TopBar<Center: View, Trailing: View>: View {
    let center: Center
    let trailing: Trailing

    init(@ViewBuilder center: () -> Center, @ViewBuilder trailing: () -> Trailing) {
        self.center = center()
        self.trailing = trailing()
    }

    var body: some View {
        // One container, so neighboring glass controls blend the way the system's toolbars do.
        GlassEffectContainer {
            ZStack {
                center
                HStack(spacing: 10) {
                    Spacer()
                    trailing
                }
            }
        }
        .padding(.leading, 84)      // the traffic lights
        .padding(.trailing, 18)
        .frame(height: 52)
    }
}

/// A soft blur under the toolbar that fades out downwards, like the scroll edge effect of macOS toolbars
/// (which only scroll views get). Kept light so the wallpaper still reads through it. Goes right above a screen's
/// background, so panels and text stay sharp.
struct HeaderEdgeEffect: View {
    var height: CGFloat = 84

    var body: some View {
        let fade = LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black.opacity(0.75), location: 0.45),
                                          .init(color: .clear, location: 1)],
                                  startPoint: .top, endPoint: .bottom)
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Color.black.opacity(0.12)
        }
        .mask(fade)
        .frame(height: height)
        .frame(maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A small status pill with an optional check.
struct StatusPill: View {
    let text: String
    var checked = false

    var body: some View {
        HStack(spacing: 5) {
            if checked {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.success)
            }
            Text(text)
        }
        .font(.system(size: 12))
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.white.opacity(0.1)))
    }
}

/// A TextField, or its text as a label when `flat` (--snapshot renders: ImageRenderer draws text fields as placeholders).
struct RenderableTextField: View {
    let placeholder: String
    @Binding var text: String
    var flat = false
    @Environment(\.multilineTextAlignment) private var alignment

    init(_ placeholder: String, text: Binding<String>, flat: Bool = false) {
        self.placeholder = placeholder
        self._text = text
        self.flat = flat
    }

    var body: some View {
        if flat {
            Text(text.isEmpty ? placeholder : text)
                .lineLimit(1)
                .opacity(text.isEmpty ? 0.45 : 1)
                .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : alignment == .trailing ? .trailing : .leading)
        } else {
            TextField(placeholder, text: $text)
        }
    }
}

/// A Link, or only its label when `flat` (--snapshot renders: ImageRenderer draws links as placeholders).
struct RenderableLink<Label: View>: View {
    let destination: URL
    var flat = false
    @ViewBuilder let label: Label

    var body: some View {
        if flat { label } else { Link(destination: destination) { label } }
    }
}

/// Shows the content as is when it fits, otherwise scrolls. `flat` skips scrolling entirely
/// (--snapshot renders: ImageRenderer can't draw scroll views).
struct FitOrScroll<Content: View>: View {
    var axes: Axis.Set = .vertical
    var flat = false
    let content: Content

    init(_ axes: Axis.Set = .vertical, flat: Bool = false, @ViewBuilder content: () -> Content) {
        self.axes = axes
        self.flat = flat
        self.content = content()
    }

    var body: some View {
        if flat {
            content
        } else {
            ViewThatFits(in: axes) {
                content
                ScrollView(axes) { content }.scrollIndicators(.never)
            }
        }
    }
}

/// A thumbnail image that fills its frame, or a placeholder gradient.
struct Thumb: View {
    let image: NSImage?
    var cornerRadius: CGFloat = 10

    var body: some View {
        Color.clear
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(colors: [.indigo.opacity(0.5), .teal.opacity(0.4)], startPoint: .top, endPoint: .bottom)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// "0:42.0" for short times, "12:05" for long ones.
func clockText(_ seconds: Double) -> String {
    let s = max(0, seconds)
    let minutes = Int(s) / 60
    if minutes >= 10 { return String(format: "%d:%02d", minutes, Int(s) % 60) }
    return String(format: "%d:%04.1f", minutes, s.truncatingRemainder(dividingBy: 60))
}

/// "Dolomites_drone_1080p.mp4" → "Dolomites_drone_1080p" (older library items kept the extension).
func prettyName(_ name: String) -> String {
    let ext = (name as NSString).pathExtension.lowercased()
    return ["mp4", "mov", "m4v", "webm", "mkv", "avi"].contains(ext) ? (name as NSString).deletingPathExtension : name
}
