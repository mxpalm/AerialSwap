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
    case inLibrary, inSteam

    var title: String {
        switch self {
        case .inLibrary: "In Library"
        case .inSteam: "In Steam"
        }
    }

    var help: String {
        switch self {
        case .inLibrary: "Already in your library"
        case .inSteam: "Steam already downloaded it: adding it is instant and doesn't count as a download"
        }
    }

    var icon: String {
        switch self {
        case .inLibrary: "checkmark"
        case .inSteam: "arrow.down.circle"
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
            .background(Capsule().fill(status == .inLibrary ? Theme.accent.opacity(0.9) : .black.opacity(0.62)))
            .padding(5)
            .help(status.help)
    }
}
