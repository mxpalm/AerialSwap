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

    /// In the Filters popover.
    var chipTitle: String { shortTitle ?? "Any" }

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
/// What the Workshop lists: video wallpapers, or scenes (rendered into a video, see SceneBaker).
enum WorkshopKind: String, Codable, CaseIterable, Sendable {
    case video, scene

    var title: String { self == .video ? "Videos" : "Scenes" }
    /// The Workshop tag of the type.
    var tag: String { self == .video ? "Video" : "Scene" }
}

struct DiscoverOptions: Codable, Equatable, Sendable {
    var sort = DiscoverSort.popular
    var workshopKind = WorkshopKind.video                // Workshop only
    var resolution = DiscoverResolution.any
    var category = PixabayCategory.any                 // Pixabay only
    var period: DiscoverPeriod?                         // Workshop only, with Popular
    var hideInLibrary = false                          // tiles of videos already in the library are left out
    /// Workshop genre tags whose wallpapers aren't listed ("Anime"…), see WorkshopClient.genres.
    var hiddenGenres: Set<String> = []                 // Workshop only
    /// Workshop: once the video is in the library, delete the copy Steam downloaded for it (see SteamDownload.removeCopy).
    /// Set in Settings → Workshop.
    var removeSteamCopy = true
    /// Workshop: also list wallpapers rated Questionable or Mature, not only Everyone. Set in Settings → Workshop.
    var showsMature = false

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
        workshopKind = try container.decodeIfPresent(WorkshopKind.self, forKey: .workshopKind) ?? .video
        period = try container.decodeIfPresent(DiscoverPeriod.self, forKey: .period)
        hideInLibrary = try container.decodeIfPresent(Bool.self, forKey: .hideInLibrary) ?? false
        hiddenGenres = try container.decodeIfPresent(Set<String>.self, forKey: .hiddenGenres) ?? []
        removeSteamCopy = try container.decodeIfPresent(Bool.self, forKey: .removeSteamCopy) ?? true
        showsMature = try container.decodeIfPresent(Bool.self, forKey: .showsMature) ?? false
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

    /// The filters in effect for a source, each with the options it takes off ("4K", "No Anime", Pixabay's
    /// category): the Filters badge and the chips under the topics. More than three hidden genres are one chip.
    func activeFilters(for source: DiscoverSource) -> [(id: String, title: String, without: DiscoverOptions)] {
        var filters: [(id: String, title: String, without: DiscoverOptions)] = []
        func add(_ id: String, _ title: String, _ change: (inout DiscoverOptions) -> Void) {
            var without = self
            change(&without)
            filters.append((id, title, without))
        }
        if let title = resolution.shortTitle { add("resolution", title) { $0.resolution = .any } }
        if source == .pixabay && category != .any { add("category", category.title) { $0.category = .any } }
        if source == .workshop {
            if hiddenGenres.count > 3 {
                add("genres", "\(hiddenGenres.count) Genres Hidden") { $0.hiddenGenres = [] }
            } else {
                for genre in hiddenGenres.sorted() { add("genre-\(genre)", "No \(genre)") { $0.hiddenGenres.remove(genre) } }
            }
        }
        if hideInLibrary { add("library", "Not in Library") { $0.hideInLibrary = false } }
        return filters
    }

    /// The options with a source's filters back to their defaults; sort, type and Settings' choices stay.
    func withoutFilters(for source: DiscoverSource) -> DiscoverOptions {
        var options = self
        options.resolution = .any
        options.hideInLibrary = false
        if source == .pixabay { options.category = .any } else { options.hiddenGenres = [] }
        return options
    }
}

/// A topic chip of either source.
struct TopicChoice: Identifiable {
    var id: String
    var title: String
}

/// Discover's controls under the search field: the Workshop's type, the sort order and the filters on one row, the
/// topics in a row that scrolls sideways, and the filters in effect as chips that take them off.
struct DiscoverControls: View {
    @Bindable var model: AppModel
    let topics: [TopicChoice]
    let selectedID: String?       // nil while a search is shown
    var enabled = true
    let select: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if model.discoverSource == .workshop {
                    PillPicker(options: WorkshopKind.allCases.map { .init(value: $0, title: $0.title) },
                               selection: Binding(get: { model.discoverOptions.workshopKind }, set: { model.setWorkshopKind($0) }),
                               label: "Show")
                        .fixedSize()
                }
                Spacer(minLength: 0)
                DiscoverSortMenu(model: model)
                DiscoverFiltersButton(model: model)
            }
            .disabled(model.isBusy || !enabled)
            TopicStrip(topics: topics, selectedID: selectedID, isSnapshot: model.isSnapshot, select: select)
                .disabled(model.isBusy || !enabled)
            ActiveFilterChips(model: model)
        }
    }
}

/// A capsule like the topic chips, for the row's menu and button.
private struct ControlCapsule: View {
    let icon: String
    let title: String
    var badge = 0
    var chevron = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
            Text(title)
            if badge > 0 {
                Text("\(badge)")
                    .font(.system(size: 10, weight: .bold)).monospacedDigit()
                    .foregroundStyle(Theme.ink)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(Circle().fill(Color.white))
            }
            if chevron { Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).opacity(0.7) }
        }
        .fixedSize()
        .font(.system(size: 12, weight: .semibold))
        .padding(.horizontal, 11)
        .frame(height: 28)
        .background(Capsule().fill(Color.white.opacity(badge > 0 ? 0.2 : 0.1)))
        .contentShape(Capsule())
    }
}

/// "Popular ⌄": the sort order, and for the Workshop's Popular the time it's popular in.
struct DiscoverSortMenu: View {
    @Bindable var model: AppModel

    var body: some View {
        let source = model.discoverSource
        let options = model.discoverOptions
        let title = options.sort.effective(for: source).title + (options.period(for: source).map { " · " + $0.title } ?? "")
        if model.isSnapshot {
            ControlCapsule(icon: "arrow.up.arrow.down", title: title, chevron: true)
        } else {
            Menu {
                Picker("Sort By", selection: Binding(get: { options.sort.effective(for: source) }, set: { model.setDiscoverSort($0) })) {
                    ForEach(DiscoverSort.choices(for: source), id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                if source == .workshop && options.sort == .popular {
                    Picker("Popular In", selection: Binding(get: { options.period }, set: { model.setDiscoverPeriod($0) })) {
                        Text("Any Time").tag(DiscoverPeriod?.none)
                        ForEach(DiscoverPeriod.allCases, id: \.self) { Text($0.title).tag(DiscoverPeriod?.some($0)) }
                    }
                    .pickerStyle(.inline)
                }
            } label: {
                ControlCapsule(icon: "arrow.up.arrow.down", title: title, chevron: true)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Sort order")
        }
    }
}

/// "Filters ②": opens the filters in a popover that stays open while several are changed; Discover searches again
/// once, when it closes.
struct DiscoverFiltersButton: View {
    @Bindable var model: AppModel
    @State private var isOpen = false

    var body: some View {
        let count = model.discoverOptions.activeFilters(for: model.discoverSource).count
        Button { isOpen = true } label: {
            ControlCapsule(icon: "line.3.horizontal.decrease", title: "Filters", badge: count)
        }
        .buttonStyle(.plain)
        .help("Resolution, \(model.discoverSource == .workshop ? "genres" : "category") and more")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            DiscoverFiltersPopover(model: model, draft: model.discoverOptions)
        }
    }
}

/// The filters of the source shown. Changes collect in a draft and apply when the popover closes.
struct DiscoverFiltersPopover: View {
    @Bindable var model: AppModel
    @State var draft: DiscoverOptions
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let source = model.discoverSource
        VStack(alignment: .leading, spacing: 16) {
            section("Resolution") {
                PillPicker(options: DiscoverResolution.allCases.map { .init(value: $0, title: $0.chipTitle) },
                           selection: $draft.resolution, label: "Resolution", fill: true)
            }
            if source == .pixabay {
                section("Category") {
                    FlowLayout(spacing: 6) {
                        ForEach(PixabayCategory.allCases, id: \.self) { category in
                            FilterChip(title: category == .any ? "All" : category.title, isOn: draft.category == category) {
                                draft.category = category
                            }
                        }
                    }
                }
            } else {
                section("Hide Genres", note: "Wallpapers whose creators didn't tag a genre still show.") {
                    FlowLayout(spacing: 6) {
                        ForEach(WorkshopClient.genres, id: \.self) { genre in
                            let hidden = draft.hiddenGenres.contains(genre)
                            FilterChip(title: genre, isOn: hidden, icon: hidden ? "eye.slash" : nil) {
                                if hidden { draft.hiddenGenres.remove(genre) } else { draft.hiddenGenres.insert(genre) }
                            }
                        }
                    }
                }
            }
            Toggle("Hide \(source == .workshop ? "wallpapers" : "videos") already in my library", isOn: $draft.hideInLibrary)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 12))
            HStack {
                Button("Reset") { draft = draft.withoutFilters(for: source) }
                    .buttonStyle(PillButtonStyle(kind: .secondary, height: 28))
                    .disabled(draft.withoutFilters(for: source) == draft)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(PillButtonStyle(kind: .primary, height: 28))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 340)
        .environment(\.colorScheme, .dark)
        .onDisappear { model.updateDiscoverOptions(draft) }
    }

    private func section<Content: View>(_ title: String, note: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
            content()
            if let note { Text(note).font(.system(size: 11)).foregroundStyle(Theme.secondary) }
        }
    }
}

/// A chip that switches a filter on and off.
private struct FilterChip: View {
    let title: String
    let isOn: Bool
    var icon: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon).font(.system(size: 10, weight: .semibold)) }
                Text(title)
            }
            .font(.system(size: 12, weight: isOn ? .semibold : .regular))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .foregroundStyle(isOn ? Theme.ink : .white)
            .background(Capsule().fill(isOn ? Color.white : Color.white.opacity(0.1)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// "No Anime ✕  4K ✕": the filters in effect; a click takes one off.
struct ActiveFilterChips: View {
    @Bindable var model: AppModel

    var body: some View {
        let source = model.discoverSource
        let filters = model.discoverOptions.activeFilters(for: source)
        if !filters.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(filters, id: \.id) { filter in
                    Button { model.updateDiscoverOptions(filter.without) } label: {
                        HStack(spacing: 5) {
                            Text(filter.title)
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).opacity(0.7)
                        }
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                        .background(Capsule().strokeBorder(Color.white.opacity(0.3)))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Remove this filter")
                }
                if filters.count > 1 {
                    Button("Clear All") { model.updateDiscoverOptions(model.discoverOptions.withoutFilters(for: source)) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                        .frame(height: 22)
                }
            }
            .disabled(model.isBusy)
        }
    }
}

/// Topic chips in one row that scrolls sideways, faded and with an arrow at an edge that has more behind it (for a
/// mouse without sideways scrolling). The selected topic is scrolled into view.
struct TopicStrip: View {
    let topics: [TopicChoice]
    let selectedID: String?
    let isSnapshot: Bool
    let select: (String) -> Void

    @State private var position = ScrollPosition(edge: .leading)
    @State private var offset: CGFloat = 0
    @State private var width: CGFloat = 0
    @State private var contentWidth: CGFloat = 0

    private var moreBefore: Bool { offset > 1 }
    private var moreAfter: Bool { offset + width < contentWidth - 1 }

    var body: some View {
        Group {
            if isSnapshot {
                // An overlay, so the row's full width doesn't widen the panel.
                Color.clear.overlay(alignment: .leading) { row.fixedSize() }.clipped().mask(fade)
            } else {
                ScrollView(.horizontal) { row.scrollTargetLayout() }
                    .scrollIndicators(.never)
                    .scrollPosition($position)
                    .onScrollGeometryChange(for: [CGFloat].self) { g in
                        [g.contentOffset.x, g.containerSize.width, g.contentSize.width]
                    } action: { _, values in
                        (offset, width, contentWidth) = (values[0], values[1], values[2])
                    }
                    .mask(fade)
                    .overlay(alignment: .leading) { if moreBefore { arrow("chevron.left", by: -1) } }
                    .overlay(alignment: .trailing) { if moreAfter { arrow("chevron.right", by: 1) } }
                    .onAppear { if let selectedID { position.scrollTo(id: selectedID, anchor: .center) } }
            }
        }
        .frame(height: 26)
    }

    private var row: some View {
        HStack(spacing: 6) {
            ForEach(topics) { chip($0).id($0.id) }
        }
    }

    private var fade: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [moreBefore ? .clear : .black, .black], startPoint: .leading, endPoint: .trailing).frame(width: 36)
            Color.black
            LinearGradient(colors: [.black, moreAfter ? .clear : .black], startPoint: .leading, endPoint: .trailing).frame(width: 36)
        }
    }

    /// Scrolls most of a width further.
    private func arrow(_ icon: String, by direction: CGFloat) -> some View {
        Button {
            let target = min(max(0, offset + direction * width * 0.7), max(0, contentWidth - width))
            withAnimation(.snappy) { position.scrollTo(x: target) }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.18)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(direction < 0 ? "Earlier topics" : "More topics")
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
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Lays its views out in rows, left to right, starting a new row when one is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // Asked for its ideal size, it's as narrow as its widest view: it never widens what it's in.
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let rows = rows(width: width, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func rows(width: CGFloat, subviews: Subviews) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if let last = rows.last, !last.indices.isEmpty, last.width + spacing + size.width <= width {
                rows[rows.count - 1].indices.append(index)
                rows[rows.count - 1].width += spacing + size.width
                rows[rows.count - 1].height = max(last.height, size.height)
            } else {
                rows.append(([index], size.width, size.height))
            }
        }
        return rows
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
