import SwiftUI

enum DiscoverSort: String, Codable, CaseIterable, Sendable {
    case popular, newest

    var title: String {
        switch self {
        case .popular: "Popular"
        case .newest: "Newest"
        }
    }
}

/// Search options shared by Pixabay and the Workshop (the options menu in Discover's header), kept between launches.
struct DiscoverOptions: Codable, Equatable, Sendable {
    var sort = DiscoverSort.popular
    var only4K = false   // Pixabay: at least 3840 px wide; Workshop: tagged 3840 x 2160 by its creator

    private static let key = "DiscoverOptions"

    static func load() -> DiscoverOptions {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(DiscoverOptions.self, from: $0) } ?? DiscoverOptions()
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

/// "Popular · 4K ▾": sort order and resolution for both sources.
struct DiscoverOptionsMenu: View {
    @Bindable var model: AppModel

    private var label: String {
        model.discoverOptions.sort.title + (model.discoverOptions.only4K ? " · 4K" : "")
    }

    var body: some View {
        if model.isSnapshot {
            labelView
        } else {
            Menu {
                Picker("Sort", selection: Binding(get: { model.discoverOptions.sort }, set: { model.setDiscoverSort($0) })) {
                    ForEach(DiscoverSort.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("4K Only", isOn: Binding(get: { model.discoverOptions.only4K }, set: { model.setDiscoverOnly4K($0) }))
            } label: {
                labelView
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(model.isBusy)
            .help("Sort and resolution, for Pixabay and the Workshop")
        }
    }

    private var labelView: some View {
        HStack(spacing: 4) {
            Image(systemName: "line.3.horizontal.decrease")
            Text(label)
        }
        .font(.system(size: 12, weight: .semibold))
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Capsule().fill(Color.white.opacity(0.1)))
        .contentShape(Capsule())
    }
}

/// Where a Discover pick already is: in the library, or (Workshop) downloaded by Steam.
enum DiscoverItemStatus {
    case inLibrary, inSteam, downloading, downloaded

    var title: String {
        switch self {
        case .inLibrary: "In Library"
        case .inSteam: "In Steam"
        case .downloading: "Downloading"
        case .downloaded: "Downloaded"
        }
    }

    var help: String {
        switch self {
        case .inLibrary: "Already in your library"
        case .inSteam: "Steam already downloaded it: adding it is instant and doesn't count as a download"
        case .downloading: "Downloading in the background, see the top bar"
        case .downloaded: "Downloaded: open it from the top bar"
        }
    }

    var icon: String {
        switch self {
        case .inLibrary: "checkmark"
        case .inSteam, .downloading: "arrow.down.circle"
        case .downloaded: "checkmark.circle"
        }
    }
}

/// The status badge in a tile's top right corner.
struct DiscoverStatusBadge: View {
    let status: DiscoverItemStatus

    var body: some View {
        Label(status.title, systemImage: status.icon)
            .font(.system(size: 10, weight: .bold))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(status == .inLibrary || status == .downloaded ? Theme.accent.opacity(0.9) : .black.opacity(0.62)))
            .padding(5)
            .help(status.help)
    }
}

/// A Discover download running in the background (Pixabay or Steam), shown as a chip in the top bar.
struct BackgroundDownload: Equatable {
    enum State: Equatable {
        case waiting(String)   // e.g. "Waiting for Steam"
        case running(Double)   // 0...1
        case ready
    }

    let key: String            // the tile's: "discover-<id>" or "workshop-<id>"
    let title: String
    let source: String         // "Pixabay", "Steam"
    var state: State
    var detail: String         // what's going on, for the footer and the chip's tooltip

    var isReady: Bool { state == .ready }
}

/// The top bar's chip: progress of a Discover download, then Open. ✕ cancels it (or drops it once finished).
struct DownloadChip: View {
    @Bindable var model: AppModel
    let download: BackgroundDownload

    var body: some View {
        HStack(spacing: 8) {
            indicator
            VStack(alignment: .leading, spacing: 0) {
                Text(shortTitle).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(status).font(.system(size: 10)).foregroundStyle(Theme.secondary).monospacedDigit().lineLimit(1)
            }
            .fixedSize()   // as wide as its text: the toolbar's center (Library | Discover) stays clear
            if download.isReady {
                Button("Open") { model.openBackgroundDownload() }
                    .buttonStyle(PillButtonStyle(kind: .primary, height: 24))
                    .disabled(!model.canOpenBackgroundDownload)
                    .help(model.canOpenBackgroundDownload ? "Trim it and set it as your wallpaper" : "Available once the current work is done")
            }
            Button { model.cancelBackgroundDownload() } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).frame(width: 18, height: 18).contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.secondary)
            .help(download.isReady ? "Discard the download" : "Cancel the download")
            .accessibilityLabel(download.isReady ? "Discard download" : "Cancel download")
        }
        .padding(.leading, 6).padding(.trailing, 8)
        .frame(height: 32)
        .glassEffect(.regular, in: Capsule())
        .help(download.detail)
        .accessibilityElement(children: .contain)
    }

    private var shortTitle: String {
        let limit = download.isReady ? 16 : 22
        return download.title.count > limit ? download.title.prefix(limit - 1).trimmingCharacters(in: .whitespaces) + "…" : download.title
    }

    private var status: String {
        switch download.state {
        case .waiting(let text): text
        case .running(let p): p > 0 ? "\(Int(p * 100))% from \(download.source)" : "Starting \(download.source) download"
        case .ready: "Downloaded"
        }
    }

    @ViewBuilder private var indicator: some View {
        switch download.state {
        case .ready:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(Theme.accent)
        case .waiting:
            ProgressView().controlSize(.small).frame(width: 20, height: 20)
        case .running(let p):
            ZStack {
                Circle().stroke(.white.opacity(0.2), lineWidth: 2.5)
                Circle().trim(from: 0, to: max(0.02, p)).stroke(Theme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 18, height: 18)
            .padding(1)
        }
    }
}
