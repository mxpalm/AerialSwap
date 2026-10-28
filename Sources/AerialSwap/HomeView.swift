import SwiftUI

/// The Library (home) and Discover panels. The window shows the selected video full size.
struct HomeView: View {
    @Bindable var model: AppModel

    private var backgroundImage: NSImage? {
        if model.section == .discover {
            return model.selectedDiscoverVideo.flatMap { model.backdrops["discover-\($0.id)"] ?? model.discoverThumbnails[$0.id] }
        }
        if let item = model.selectedLibraryItem, let image = model.backdrops["lib-\(item.id)"] { return image }
        return model.desktopAsset.flatMap { model.backdrops[model.backdropKey(for: $0)] }
    }

    var body: some View {
        ZStack {
            Backdrop(image: backgroundImage, player: model.visibleBackgroundPlayer, scrim: .side)
            HeaderEdgeEffect()
            VStack(spacing: 0) {
                if model.assets.isEmpty {
                    NoAerialsState(model: model)
                } else if model.section == .discover {
                    DiscoverLayout(model: model)
                } else {
                    LibraryLayout(model: model)
                }
            }
        }
        .screenToolbar(snapshot: model.isSnapshot) { SectionSwitcher(model: model) } trailing: { TopBarActions(model: model) }
    }
}

/// Where macOS shows a library wallpaper. Checked = in use; to stop using it, pick another wallpaper for that role.
private struct UseForItems: View {
    @Bindable var model: AppModel
    let item: LibraryItem

    var body: some View {
        let isDesktop = item.id == model.desktopID, isIdle = item.id == model.idleID
        Toggle("Desktop", isOn: Binding(get: { isDesktop }, set: { if $0 { model.use(item, desktop: true, screenSaver: false) } }))
            .disabled(isDesktop)
        Toggle("Screen Saver", isOn: Binding(get: { isIdle }, set: { if $0 { model.use(item, desktop: false, screenSaver: true) } }))
            .disabled(isIdle)
        Button("Desktop & Screen Saver") { model.use(item, desktop: true, screenSaver: true) }
            .disabled(isDesktop && isIdle)
        Divider()
        Button("Open Wallpaper Settings") { model.openWallpaperSettings() }
    }
}

// MARK: - Library

private struct LibraryLayout: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(alignment: .bottom, spacing: 20) {
            previewCaption
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 8)
                .padding(.bottom, 12)
            LibraryPanel(model: model)
                .frame(width: 460)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 16)
        .onAppear { model.showBackgroundVideo() }
        .onDisappear { model.pauseBackgroundVideo(in: .library) }
    }

    @ViewBuilder private var previewCaption: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let item = model.selectedLibraryItem {
                Text(model.role(of: item).map { "On \($0)" } ?? "Previewing").font(.system(size: 13, weight: .semibold)).opacity(0.9)
                Text(prettyName(item.name)).font(.system(size: 40, weight: .bold)).tracking(-0.8).lineLimit(2)
                Text(details(item)).font(.system(size: 14)).opacity(0.9)
            } else {
                Text("Your library").font(.system(size: 13, weight: .semibold)).opacity(0.9)
                Text("\(model.libraryItems.count) wallpaper\(model.libraryItems.count == 1 ? "" : "s")")
                    .font(.system(size: 40, weight: .bold)).tracking(-0.8)
                Text("Pick one to preview it here. Switching takes seconds — it's already prepared.")
                    .font(.system(size: 14)).opacity(0.9)
            }
        }
        .overVideo()
    }

    private func details(_ item: LibraryItem) -> String {
        var parts = [clockText(item.duration), item.bytes.formatted(.byteCount(style: .file))]
        if let settings = item.settingsSummary { parts.append(settings) }
        if item.enhanced == true { parts.append("Enhanced") }
        if let credit = item.credit { parts.append(credit) }
        return parts.joined(separator: " · ")
    }
}

private struct LibraryPanel: View {
    @Bindable var model: AppModel

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !model.libraryItems.isEmpty { searchField }
            if model.libraryItems.isEmpty {
                emptyState
            } else {
                Group {
                    if model.isSnapshot {
                        grid
                    } else {
                        ScrollView { grid }.scrollIndicators(.never)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            footer
        }
        .padding(16)
        .frame(maxHeight: .infinity)
        .glassPanel(opacity: 0.72)
    }

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(model.filteredLibraryItems) { item in LibraryTile(model: model, item: item) }
        }
        .padding(3)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Your wallpapers").font(.system(size: 17, weight: .bold))
            Spacer()
            if !model.libraryItems.isEmpty {
                Text("\(model.libraryItems.count) · \(model.libraryBytes.formatted(.byteCount(style: .file)))")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary).accessibilityHidden(true)
            TextField("Search your wallpapers", text: $model.librarySearch)
                .textFieldStyle(.plain)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Capsule().fill(Color.white.opacity(0.1)))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "film.stack").font(.system(size: 30, weight: .light)).foregroundStyle(Theme.secondary)
            Text("No saved wallpapers yet").font(.system(size: 15, weight: .semibold))
            Text("Every video you set is kept here, so you can switch back to it in seconds.")
                .font(.system(size: 13)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    @ViewBuilder private var footer: some View {
        VStack(spacing: 8) {
            if model.libraryItems.isEmpty {
                AddVideoMenu(model: model, height: 44, fullWidth: true)
            } else {
                Button(model.isSelectedItemPlaying ? "Playing on Desktop" : "Set as Wallpaper") {
                    model.confirmSetWallpaper = true
                }
                .buttonStyle(PillButtonStyle(kind: .primary, height: 44, fullWidth: true))
                .disabled(!model.canSetWallpaper)
                .keyboardShortcut(model.done == nil ? .defaultAction : nil)
                Text(footerCaption).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
        }
        .padding(.top, 12)
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.12)).frame(height: 1) }
    }

    private var footerCaption: String {
        if model.selectedLibraryItem == nil { return "Pick a wallpaper above" }
        if model.isSelectedItemPlaying { return "Already on your desktop · pick another wallpaper" }
        return "Desktop & screen saver · already prepared, takes a few seconds"
    }
}

private struct LibraryTile: View {
    @Bindable var model: AppModel
    let item: LibraryItem

    var body: some View {
        let isSelected = model.selectedLibraryID == item.id
        let role = model.role(of: item)
        Button { model.selectLibraryItem(item) } label: {
            VStack(alignment: .leading, spacing: 5) {
                ZStack(alignment: .topLeading) {
                    Thumb(image: model.libraryThumbnails[item.id], cornerRadius: 9)
                    if let role {
                        Text("On \(role)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color(red: 0.02, green: 0.14, blue: 0.06))
                            .padding(.horizontal, 7).padding(.vertical, 1)
                            .background(Capsule().fill(Theme.successFill))
                            .lineLimit(1)
                            .padding(5)
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(isSelected ? Theme.accent : .white.opacity(0.12), lineWidth: isSelected ? 2.5 : 1)
                }
                Text(prettyName(item.name)).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu {
            Menu("Use For") { UseForItems(model: model, item: item) }
                .disabled(model.isBusy)
            Divider()
            if let page = item.sourcePage.flatMap(URL.init(string:)) { Link("View on Pixabay", destination: page) }
            Button("Delete from Library…", role: .destructive) { model.deleteCandidate = item }
        }
        .help("\(prettyName(item.name))\nSaved \(item.addedAt.formatted(date: .abbreviated, time: .shortened))"
              + (item.settingsSummary.map { "\n\($0)" } ?? "") + (item.credit.map { "\nVideo by \($0)" } ?? ""))
    }
}

// MARK: - No Aerials

private struct NoAerialsState: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "arrow.down.circle").font(.system(size: 40, weight: .light)).accessibilityHidden(true)
            Text("First, download one Aerial").font(.system(size: 26, weight: .bold))
            Text("AerialSwap adds your videos next to Apple's Aerials, so macOS needs to have set those up once: "
                 + "open System Settings → Wallpaper, choose any Aerial, wait for the download, then come back.")
                .font(.system(size: 14)).foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 520)
            HStack(spacing: 10) {
                Button("Open Wallpaper Settings") { model.openWallpaperSettings() }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                Button("Check Again") { model.refreshAssets() }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
            }
            Spacer()
        }
        .padding(32)
        .frame(maxWidth: 640)
        .glassPanel()
        .padding(40)
    }
}
