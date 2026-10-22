import SwiftUI

/// Now Playing (what each Aerial plays) and the Library panel. The window shows the selected video full size.
struct HomeView: View {
    @Bindable var model: AppModel

    private var backgroundImage: NSImage? {
        if model.section == .library, let item = model.selectedLibraryItem, let image = model.backdrops["lib-\(item.id)"] {
            return image
        }
        if model.section == .discover {
            return model.selectedDiscoverVideo.flatMap { model.backdrops["discover-\($0.id)"] ?? model.discoverThumbnails[$0.id] }
        }
        guard let asset = model.selectedAsset else { return nil }
        return model.backdrops[model.backdropKey(for: asset)] ?? model.thumbnails[asset.id]
    }

    var body: some View {
        ZStack {
            Backdrop(image: backgroundImage, player: model.visibleBackgroundPlayer,
                     scrim: model.section == .nowPlaying ? .standard : .side)
            HeaderEdgeEffect()
            VStack(spacing: 0) {
                if model.assets.isEmpty {
                    NoAerialsState(model: model)
                } else if model.section == .library {
                    LibraryLayout(model: model)
                } else if model.section == .discover {
                    DiscoverLayout(model: model)
                } else {
                    NowPlayingLayout(model: model)
                }
            }
        }
        .screenToolbar(snapshot: model.isSnapshot) { SectionSwitcher(model: model) } trailing: { TopBarActions(model: model) }
    }
}

// MARK: - Now Playing

private struct NowPlayingLayout: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer(minLength: 0)
            if let asset = model.selectedAsset { PlayingNow(model: model, asset: asset) }
            AerialShelf(model: model)
        }
        .padding(.horizontal, 24)
        .padding(.top, 4)
        .padding(.bottom, 16)
    }
}

/// Where macOS shows an Aerial.
enum AerialRole {
    case desktop, screenSaver, both

    var title: String {
        switch self {
        case .desktop: "Desktop"
        case .screenSaver: "Screen Saver"
        case .both: "Desktop & Screen Saver"
        }
    }

    var icon: String {
        switch self {
        case .desktop, .both: "menubar.dock.rectangle"
        case .screenSaver: "moon.stars"
        }
    }
}

/// The big title: what the selected Aerial plays right now, and what you can do about it.
private struct PlayingNow: View {
    @Bindable var model: AppModel
    let asset: AerialAsset

    private var role: String { model.roleTitle(for: asset.id).map { "\($0) · " } ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch model.statuses[asset.id] ?? .original {
            case .replaced(let name, let date, _):
                eyebrow("\(role)\(asset.name) plays")
                title(prettyName(name))
                subtitle("Since \(date.formatted(date: .abbreviated, time: .shortened)) · Apple's original is backed up")
                HStack(spacing: 10) {
                    Button("Change…") { model.openLibrary(for: asset) }
                        .buttonStyle(PillButtonStyle(kind: .light))
                    if model.store.hasBackup(asset) || model.isSnapshot {
                        Button("Restore Apple's Original…") { model.restoreCandidate = asset }
                            .buttonStyle(PillButtonStyle(kind: .secondary))
                    }
                    UseForMenu(model: model, asset: asset)
                }
                .padding(.top, 6)
            case .original:
                eyebrow("\(role)Apple original")
                title(asset.name)
                subtitle("Pick one of your wallpapers, or add a new video to play here instead.")
                HStack(spacing: 10) {
                    Button("Choose from Library…") { model.openLibrary(for: asset) }
                        .buttonStyle(PillButtonStyle(kind: .light))
                    Button("Add Video…") { model.select(asset); model.showImporter = true }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                    UseForMenu(model: model, asset: asset)
                }
                .padding(.top, 6)
            case .resetByMacOS:
                eyebrow("\(role)macOS put Apple's video back", color: Theme.warning)
                title(asset.name)
                subtitle("Usually after a macOS update. Your video is still in the library.")
                HStack(spacing: 10) {
                    if model.reinstallableIDs.contains(asset.id) {
                        Button("Reinstall My Video") { model.reinstall(asset) }
                            .buttonStyle(PillButtonStyle(kind: .primary))
                    }
                    Button("Change…") { model.openLibrary(for: asset) }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                    UseForMenu(model: model, asset: asset)
                }
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
        .disabled(model.isBusy)
    }

    private func eyebrow(_ text: String, color: Color = .white.opacity(0.9)) -> some View {
        Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(color).overVideo()
    }

    private func title(_ text: String) -> some View {
        Text(text).font(.system(size: 48, weight: .bold)).tracking(-1.2).lineLimit(2).overVideo()
    }

    private func subtitle(_ text: String) -> some View {
        Text(text).font(.system(size: 15)).foregroundStyle(.white.opacity(0.9)).overVideo()
    }
}

/// Switches which Aerial macOS shows on the desktop and as the screen saver.
private struct UseForMenu: View {
    @Bindable var model: AppModel
    let asset: AerialAsset

    var body: some View {
        Menu {
            UseForItems(model: model, asset: asset)
        } label: {
            Label("Use For…", systemImage: "menubar.dock.rectangle")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(PillButtonStyle(kind: .secondary))
        .fixedSize()
        .help("Show \(asset.name) on the desktop or as the screen saver")
    }
}

/// The menu items, shared by the Use For… button and the Aerial tile's context menu.
private struct UseForItems: View {
    @Bindable var model: AppModel
    let asset: AerialAsset

    var body: some View {
        let isDesktop = asset.id == model.desktopID, isIdle = asset.id == model.idleID
        // Checked = in use. Unchecking asks which Aerial takes over, since something always has to fill the role.
        Toggle("Desktop", isOn: Binding(get: { isDesktop }, set: { on in
            if on { model.useAerial(asset, desktop: true, screenSaver: false) } else { model.beginRoleMove(.desktop, from: asset) }
        }))
        Toggle("Screen Saver", isOn: Binding(get: { isIdle }, set: { on in
            if on { model.useAerial(asset, desktop: false, screenSaver: true) } else { model.beginRoleMove(.screenSaver, from: asset) }
        }))
        Button("Desktop & Screen Saver") { model.useAerial(asset, desktop: true, screenSaver: true) }
            .disabled(isDesktop && isIdle)
        Divider()
        Button("Open Wallpaper Settings") { model.openWallpaperSettings() }
    }
}

/// Every downloaded Aerial and what it plays.
private struct AerialShelf: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Every Aerial on this Mac").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("Each Aerial plays one video, on every display that uses it")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            FitOrScroll(.horizontal, flat: model.isSnapshot) {
                HStack(spacing: 12) {
                    ForEach(model.assets) { asset in AerialTile(model: model, asset: asset) }
                }
                .padding(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .glassPanel()
        .padding(.horizontal, -8)
    }
}

private struct AerialTile: View {
    @Bindable var model: AppModel
    let asset: AerialAsset

    var body: some View {
        let status = model.statuses[asset.id] ?? .original
        let isSelected = model.selectedID == asset.id
        Button { model.select(asset) } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topLeading) {
                    Thumb(image: model.thumbnails[asset.id])
                    if case .replaced = status, let apple = model.appleThumbnails[asset.id] {
                        Thumb(image: apple, cornerRadius: 5)
                            .frame(width: 58, height: 33)
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white, lineWidth: 1.5))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(6)
                    }
                    roleBadges
                    if status == .resetByMacOS {
                        Text("Reset by macOS")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.onWarning)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Capsule().fill(Theme.warning))
                            .padding(6)
                    }
                }
                .frame(width: 196, height: 110)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(ringColor(status, isSelected), lineWidth: isSelected || status == .resetByMacOS ? 2.5 : 1)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(asset.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    statusLine(status).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                }
                .frame(width: 196, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isBusy)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu {
            Menu("Use For") { UseForItems(model: model, asset: asset) }
            Button("Choose from Library…") { model.openLibrary(for: asset) }
            if case .replaced = status, model.store.hasBackup(asset) {
                Button("Restore Apple's Original…") { model.restoreCandidate = asset }
            }
            if status == .resetByMacOS, model.reinstallableIDs.contains(asset.id) {
                Button("Reinstall My Video") { model.reinstall(asset) }
            }
        }
    }

    /// "Desktop" / "Screen Saver" / "Desktop & Screen Saver" in the thumbnail's bottom-left corner.
    @ViewBuilder private var roleBadges: some View {
        let role: AerialRole? = switch (asset.id == model.desktopID, asset.id == model.idleID) {
        case (true, true): .both
        case (true, false): .desktop
        case (false, true): .screenSaver
        case (false, false): nil
        }
        if let role {
            Label(role.title, systemImage: role.icon)
                .font(.system(size: 10, weight: .bold))
                .lineLimit(1)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(.black.opacity(0.62)))
                .padding(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }

    private func ringColor(_ status: AerialStatus, _ isSelected: Bool) -> Color {
        if isSelected { return Theme.accent }
        if status == .resetByMacOS { return Theme.warning }
        return .white.opacity(0.12)
    }

    @ViewBuilder private func statusLine(_ status: AerialStatus) -> some View {
        switch status {
        case .original: Text("Apple original").foregroundStyle(Theme.secondary)
        case .replaced(let name, _, _): Text(prettyName(name)).foregroundStyle(Theme.success)
        case .resetByMacOS:
            Text(model.installRecords[asset.id].map { "Reinstall \(prettyName($0.sourceName))" } ?? "Apple's video is back")
                .foregroundStyle(Theme.warning)
        }
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
                Text("Previewing").font(.system(size: 13, weight: .semibold)).opacity(0.9)
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
            Text("Choose for").font(.system(size: 17, weight: .bold))
            Menu {
                targetItems
            } label: {
                HStack(spacing: 4) {
                    Text(model.selectedAsset.map { model.targetTitle(for: $0) } ?? "an Aerial").font(.system(size: 17, weight: .bold))
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
                }
                .foregroundStyle(Theme.accent)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            Spacer()
            if !model.libraryItems.isEmpty {
                Text("\(model.libraryItems.count) · \(model.libraryBytes.formatted(.byteCount(style: .file)))")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
        }
    }

    /// Desktop and Screen Saver first, by role; every other Aerial by name.
    @ViewBuilder private var targetItems: some View {
        let roles = model.assets.filter { model.roleTitle(for: $0.id) != nil }
        ForEach(roles) { asset in
            Button("\(model.roleTitle(for: asset.id) ?? "") · \(asset.name)") { model.selectedID = asset.id }
        }
        let others = model.assets.filter { model.roleTitle(for: $0.id) == nil }
        if !others.isEmpty {
            if !roles.isEmpty { Divider() }
            Menu("Other Aerials") {
                ForEach(others) { asset in Button(asset.name) { model.selectedID = asset.id } }
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
                Button("Add Video…") { model.showImporter = true }
                    .buttonStyle(PillButtonStyle(kind: .primary, height: 44, fullWidth: true))
            } else {
                let target = model.selectedAsset.map { model.targetTitle(for: $0) } ?? "Aerial"
                Button(model.isSelectedItemPlaying ? "Playing on \(target)" : "Use for \(target)") {
                    model.confirmSetWallpaper = true
                }
                .buttonStyle(PillButtonStyle(kind: .primary, height: 44, fullWidth: true))
                .disabled(!model.canSetWallpaper)
                .keyboardShortcut(model.resetAlertAsset == nil && model.done == nil && model.roleMove == nil ? .defaultAction : nil)
                Text(footerCaption).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
        }
        .padding(.top, 12)
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.12)).frame(height: 1) }
    }

    private var footerCaption: String {
        if model.selectedLibraryItem == nil { return "Pick a wallpaper above" }
        let aerial = model.selectedAsset?.name ?? "the Aerial"
        if model.isSelectedItemPlaying { return "Already playing on \(aerial) · pick another wallpaper" }
        return "Plays on \(aerial) · already prepared, takes a few seconds"
    }
}

private struct LibraryTile: View {
    @Bindable var model: AppModel
    let item: LibraryItem

    var body: some View {
        let isSelected = model.selectedLibraryID == item.id
        let playing = model.playingAerials(for: item)
        Button { model.selectLibraryItem(item) } label: {
            VStack(alignment: .leading, spacing: 5) {
                ZStack(alignment: .topLeading) {
                    Thumb(image: model.libraryThumbnails[item.id], cornerRadius: 9)
                    if !playing.isEmpty {
                        Text("On \(playing.joined(separator: ", "))")
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
            Text("AerialSwap replaces an Aerial that's already on this Mac. macOS only downloads them when you pick one: "
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
