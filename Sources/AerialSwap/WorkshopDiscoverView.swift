import SwiftUI

/// Pixabay | Workshop, at the top of the Discover panel.
struct DiscoverSourcePicker: View {
    @Bindable var model: AppModel

    var body: some View {
        PillPicker(options: [.init(value: DiscoverSource.pixabay, title: "Pixabay"), .init(value: .workshop, title: "Workshop")],
                   selection: Binding(get: { model.discoverSource }, set: { model.selectDiscoverSource($0) }),
                   label: "Videos from")
            .padding(3)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            .fixedSize()
            .disabled(model.isBusy)
    }
}

/// Wallpaper Engine's Workshop in Discover: video wallpapers rated for everyone. Picking one shows its preview picture;
/// Download with Steam has the user's own Steam download it (SteamDownloader).
struct WorkshopPanel: View {
    @Bindable var model: AppModel

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            searchField
            topics
            content.frame(maxHeight: .infinity, alignment: .top)
            footer
        }
        .padding(16)
        .frame(maxHeight: .infinity)
        .glassPanel(opacity: 0.72)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            DiscoverSourcePicker(model: model)
            DiscoverOptionsMenu(model: model)
            Spacer()
            RenderableLink(destination: WorkshopClient.homepage, flat: model.isSnapshot) {
                Label("Workshop", systemImage: "arrow.up.right").labelStyle(TrailingIconLabelStyle())
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.secondary)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary).accessibilityHidden(true)
            RenderableTextField("Search Wallpaper Engine videos", text: $model.workshopSearch, flat: model.isSnapshot)
                .textFieldStyle(.plain)
                .onSubmit { model.submitWorkshopSearch() }
            if !model.workshopQuery.isEmpty || !model.workshopSearch.isEmpty {
                Button { model.clearWorkshopSearch() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Capsule().fill(Color.white.opacity(0.1)))
        .disabled(!model.workshop.isAvailable)
    }

    private var topics: some View {
        FitOrScroll(.horizontal, flat: model.isSnapshot) {
            HStack(spacing: 6) {
                ForEach(WorkshopTopic.all) { topic in
                    let isOn = model.workshopQuery.isEmpty && model.workshopTopic == topic
                    Button { model.selectWorkshopTopic(topic) } label: {
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
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
        .disabled(!model.workshop.isAvailable && !model.isSnapshot)
    }

    @ViewBuilder private var content: some View {
        if !model.workshop.isAvailable && !model.isSnapshot {
            message(icon: "key", title: "Workshop search isn't set up",
                    text: "This build has no Discover proxy. To use your own Steam Web API key, run\n"
                        + "defaults write io.github.mxpalm.AerialSwap SteamKey <key>\nand reopen AerialSwap.")
        } else if model.workshopItems.isEmpty, let error = model.workshopError {
            message(icon: "wifi.exclamationmark", title: "Couldn't load wallpapers", text: error) {
                Button("Try Again") { model.loadWorkshop() }
                    .buttonStyle(PillButtonStyle(kind: .secondary, height: 32))
            }
        } else if model.workshopItems.isEmpty, model.isWorkshopLoading {
            ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.workshopItems.isEmpty {
            message(icon: "magnifyingglass", title: "No video wallpapers found", text: "Try another word, or pick a topic above.")
        } else if model.isSnapshot {
            grid
        } else {
            ScrollView { grid }.scrollIndicators(.never)
        }
    }

    private var grid: some View {
        VStack(spacing: 12) {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(model.workshopItems) { item in WorkshopTile(model: model, item: item) }
            }
            .padding(3)
            if model.isWorkshopLoading {
                ProgressView().controlSize(.small).padding(.vertical, 6)
            } else if model.canLoadMoreWorkshop {
                Button("Show More") { model.loadWorkshop(more: true) }
                    .buttonStyle(PillButtonStyle(kind: .secondary, height: 32))
            } else if let error = model.workshopError {
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
            }
        }
    }

    private func message(icon: String, title: String, text: String,
                         @ViewBuilder action: () -> some View = { EmptyView() }) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 30, weight: .light)).foregroundStyle(Theme.secondary)
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
                .textSelection(.enabled)
            action()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    /// Without Steam for Mac there's nothing to download with: the button gets Steam instead.
    private var footer: some View {
        VStack(spacing: 8) {
            if SteamDownload.isInstalled || model.isSnapshot {
                Button("Download with Steam") { model.downloadSelectedWorkshopItem() }
                    .buttonStyle(PillButtonStyle(kind: .primary, height: 44, fullWidth: true))
                    .disabled(model.selectedWorkshopItem == nil || model.isBusy)
                    .keyboardShortcut(model.selectedWorkshopItem != nil && model.done == nil && !model.isPreviewingWallpaper ? .defaultAction : nil)
            } else {
                Link(destination: SteamDownload.getSteamPage) {
                    Label("Get Steam for Mac", systemImage: "arrow.up.right").labelStyle(TrailingIconLabelStyle())
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle(kind: .secondary, height: 44, fullWidth: true))
            }
            Text(footerCaption).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 12)
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.12)).frame(height: 1) }
    }

    private var footerCaption: String {
        guard SteamDownload.isInstalled || model.isSnapshot else {
            return "Downloading needs Steam for Mac and a Steam account that owns Wallpaper Engine."
        }
        guard let item = model.selectedWorkshopItem else { return "Pick a wallpaper above. Needs Wallpaper Engine on your Steam account." }
        let size = item.size > 0 ? " (\(item.size.formatted(.byteCount(style: .file))))" : ""
        return "Steam downloads it\(size), then you trim it and pick an Aerial"
    }
}

private struct WorkshopTile: View {
    @Bindable var model: AppModel
    let item: WorkshopItem

    var body: some View {
        let isSelected = model.selectedWorkshopItemID == item.id
        Button { model.selectWorkshopItem(item) } label: {
            VStack(alignment: .leading, spacing: 5) {
                ZStack {
                    Thumb(image: model.workshopItemThumbnails[item.id], cornerRadius: 9, animates: !model.isSnapshot)
                    if let resolution = item.resolutionText {
                        badge(resolution).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    if item.size > 0 {
                        badge(item.size.formatted(.byteCount(style: .file)))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    }
                    if let status = model.status(of: item) {
                        DiscoverStatusBadge(status: status).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(isSelected ? Theme.accent : .white.opacity(0.12), lineWidth: isSelected ? 2.5 : 1)
                }
                Text(item.title).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.tail)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isBusy)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu {
            if let page = item.page { Link("View on the Steam Workshop", destination: page) }
        }
        .help("\(item.title)\(item.creatorName.map { "\nVideo by \($0)" } ?? "")\n\(item.genres.joined(separator: ", "))")
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .monospacedDigit()
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(.black.opacity(0.62)))
            .padding(5)
    }
}
