import SwiftUI

enum DiscoverSort: String, Codable, CaseIterable, Sendable {
    case popular, newest, mostSubscribed   // Most Subscribed: Workshop only (Pixabay sorts it as Popular)

    var title: String {
        switch self {
        case .popular: "Popular"
        case .newest: "Newest"
        case .mostSubscribed: "Most Subscribed"
        }
    }

    static func choices(for source: DiscoverSource) -> [DiscoverSort] {
        source == .workshop ? allCases : [.popular, .newest]
    }

    /// What a source sorts by: Pixabay has no subscriptions.
    func effective(for source: DiscoverSource) -> DiscoverSort {
        self == .mostSubscribed && source == .pixabay ? .popular : self
    }
}

/// The smallest resolution listed. Pixabay: by width; Workshop: by the resolution tag every item has.
enum DiscoverResolution: String, Codable, CaseIterable, Sendable {
    case any, qhd, uhd

    var title: String {
        switch self {
        case .any: "Any Resolution"
        case .qhd: "1440p and Up"
        case .uhd: "4K Only"
        }
    }

    var shortTitle: String? {
        switch self {
        case .any: nil
        case .qhd: "1440p+"
        case .uhd: "4K"
        }
    }

    /// Pixabay's `min_width`: Discover lists 1080p and up anyway.
    var minWidth: Int {
        switch self {
        case .any: 1920
        case .qhd: 2560
        case .uhd: 3840
        }
    }
}

/// Workshop, sorted by Popular: most popular over this time (Steam's trend ranking, `days`). nil (Any Time): the
/// topic's own ranking (Trending: this month's trend; tags: all-time votes; searches: relevance).
enum DiscoverPeriod: Int, Codable, CaseIterable, Sendable {
    case week = 7, month = 30, year = 365

    var title: String {
        switch self {
        case .week: "This Week"
        case .month: "This Month"
        case .year: "This Year"
        }
    }
}

/// Pixabay's own categories (its `category` parameter), the ones that make wallpapers.
enum PixabayCategory: String, Codable, CaseIterable, Sendable {
    case any = "", nature, places, travel, animals, backgrounds, buildings, science, transportation

    var title: String { self == .any ? "All Categories" : rawValue.capitalized }
}

/// Search options shared by Pixabay and the Workshop (the options menu at the end of the topic row), kept between
/// launches.
struct DiscoverOptions: Codable, Equatable, Sendable {
    var sort = DiscoverSort.popular
    var resolution = DiscoverResolution.any
    var category = PixabayCategory.any                 // Pixabay only
    var period: DiscoverPeriod?                         // Workshop only, with Popular
    var hideInLibrary = false                          // tiles of videos already in the library are left out
    /// Workshop: once the video is in the library, delete the copy Steam downloaded for it (see SteamDownload.removeCopy).
    /// Set in Settings → Workshop.
    var removeSteamCopy = true

    private static let key = "DiscoverOptions"

    init() {}

    private enum LegacyKeys: String, CodingKey { case only4K }   // before the resolution choice: a 4K Only switch

    /// Options saved by older versions lack newer keys: those get their defaults instead of resetting everything.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        sort = try container.decodeIfPresent(DiscoverSort.self, forKey: .sort) ?? .popular
        resolution = try container.decodeIfPresent(DiscoverResolution.self, forKey: .resolution)
            ?? (try legacy.decodeIfPresent(Bool.self, forKey: .only4K) == true ? .uhd : .any)
        category = try container.decodeIfPresent(PixabayCategory.self, forKey: .category) ?? .any
        period = try container.decodeIfPresent(DiscoverPeriod.self, forKey: .period)
        hideInLibrary = try container.decodeIfPresent(Bool.self, forKey: .hideInLibrary) ?? false
        removeSteamCopy = try container.decodeIfPresent(Bool.self, forKey: .removeSteamCopy) ?? true
    }

    static func load() -> DiscoverOptions {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(DiscoverOptions.self, from: $0) } ?? DiscoverOptions()
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    /// The time range a source uses: only the Workshop's Popular has one.
    func period(for source: DiscoverSource) -> DiscoverPeriod? {
        source == .workshop && sort == .popular ? period : nil
    }

    /// The menu's label for a source: "Nature · Popular · 4K", "Popular This Week · 1440p+".
    func label(for source: DiscoverSource) -> String {
        let category = source == .pixabay && category != .any ? category.title : nil
        let sort = sort.effective(for: source).title + (period(for: source).map { " " + $0.title } ?? "")
        return [category, sort, resolution.shortTitle].compactMap { $0 }.joined(separator: " · ")
    }
}

/// A topic chip of either source.
struct TopicChoice: Identifiable {
    var id: String
    var title: String
}

/// Topic chips that fit the panel, then the options menu, which holds the topics that don't fit ("More Topics").
/// The selected topic always stays a chip: it takes the place of the last one that fits.
struct TopicRow: View {
    @Bindable var model: AppModel
    let topics: [TopicChoice]
    let selectedID: String?       // nil while a search is shown
    var enabled = true
    let select: (String) -> Void

    private static let spacing: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let (visible, more) = split(width: geo.size.width)
            HStack(spacing: Self.spacing) {
                ForEach(visible) { chip($0) }
                DiscoverOptionsMenu(model: model, moreTopics: more, selectedID: selectedID, select: select)
            }
        }
        .frame(height: 26)
    }

    private func chip(_ topic: TopicChoice) -> some View {
        let isOn = topic.id == selectedID
        return Button { select(topic.id) } label: {
            Text(topic.title)
                .font(.system(size: 12, weight: isOn ? .semibold : .regular))
                .fixedSize()
                .padding(.horizontal, 11)
                .frame(height: 26)
                .foregroundStyle(isOn ? Theme.ink : .white)
                .background(Capsule().fill(isOn ? Color.white : Color.white.opacity(0.1)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    /// The chips that fit next to the menu, in order, and the rest for the menu.
    private func split(width: CGFloat) -> ([TopicChoice], [TopicChoice]) {
        let available = width - DiscoverOptionsMenu.width(label: model.discoverOptions.label(for: model.discoverSource)) - Self.spacing
        var visible: [TopicChoice] = [], used: CGFloat = 0
        for topic in topics {
            let needed = Self.chipWidth(topic.title) + (visible.isEmpty ? 0 : Self.spacing)
            guard used + needed <= available else { break }
            visible.append(topic); used += needed
        }
        if let selected = topics.first(where: { $0.id == selectedID }), !visible.contains(where: { $0.id == selected.id }) {
            let needed = Self.chipWidth(selected.title) + Self.spacing
            while let last = visible.last, used + needed > available {
                visible.removeLast(); used -= Self.chipWidth(last.title) + Self.spacing
            }
            visible.append(selected)
        }
        let shown = Set(visible.map(\.id))
        return (visible, topics.filter { !shown.contains($0.id) })
    }

    /// Measured semibold (the selected weight), so a chip never grows past its slot when selected.
    static func chipWidth(_ title: String) -> CGFloat {
        ceil((title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width) + 22
    }
}

/// "Popular · 4K ⌄": the topics that don't fit the row, sort order and filters, for both sources.
struct DiscoverOptionsMenu: View {
    @Bindable var model: AppModel
    var moreTopics: [TopicChoice] = []
    var selectedID: String?
    var select: (String) -> Void = { _ in }

    /// The label's width: icon, text, chevron and padding (TopicRow leaves room for it).
    static func width(label: String) -> CGFloat {
        ceil((label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width) + 62
    }

    var body: some View {
        if model.isSnapshot {
            labelView
        } else {
            Menu {
                if !moreTopics.isEmpty {
                    Section("More Topics") {
                        ForEach(moreTopics) { topic in
                            Toggle(topic.title, isOn: Binding(get: { topic.id == selectedID }, set: { _ in select(topic.id) }))
                        }
                    }
                    Divider()
                }
                Picker("Sort", selection: Binding(get: { model.discoverOptions.sort.effective(for: model.discoverSource) },
                                                  set: { model.setDiscoverSort($0) })) {
                    ForEach(DiscoverSort.choices(for: model.discoverSource), id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                if model.discoverSource == .workshop, model.discoverOptions.sort == .popular {
                    Picker("Popular In", selection: Binding(get: { model.discoverOptions.period }, set: { model.setDiscoverPeriod($0) })) {
                        Text("Any Time").tag(DiscoverPeriod?.none)
                        ForEach(DiscoverPeriod.allCases, id: \.self) { Text($0.title).tag(DiscoverPeriod?.some($0)) }
                    }
                    .pickerStyle(.menu)
                }
                Divider()
                Picker("Resolution", selection: Binding(get: { model.discoverOptions.resolution }, set: { model.setDiscoverResolution($0) })) {
                    ForEach(DiscoverResolution.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                if model.discoverSource == .pixabay {
                    Picker("Category", selection: Binding(get: { model.discoverOptions.category }, set: { model.setDiscoverCategory($0) })) {
                        ForEach(PixabayCategory.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
                Toggle("Hide Videos in Library", isOn: Binding(get: { model.discoverOptions.hideInLibrary }, set: { model.setHideInLibrary($0) }))
            } label: {
                labelView
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(model.isBusy)
            .help(moreTopics.isEmpty ? "Sort and filters" : "More topics, sort and filters")
        }
    }

    private var labelView: some View {
        HStack(spacing: 4) {
            Image(systemName: "line.3.horizontal.decrease")
            Text(model.discoverOptions.label(for: model.discoverSource))
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).opacity(0.7)
        }
        .fixedSize()
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
