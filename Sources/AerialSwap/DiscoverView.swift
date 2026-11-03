import SwiftUI

/// Free videos from Pixabay, or video wallpapers from Wallpaper Engine's Steam Workshop: pick one to preview it
/// full-window, then download it and set it up like any added video.
struct DiscoverLayout: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(alignment: .bottom, spacing: 20) {
            previewCaption
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 8)
                .padding(.bottom, 12)
            Group {
                if model.discoverSource == .workshop { WorkshopPanel(model: model) } else { DiscoverPanel(model: model) }
            }
            .frame(width: 460)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 16)
        .onAppear { model.showBackgroundVideo() }
        .onDisappear { model.pauseBackgroundVideo(in: .discover) }
    }

    @ViewBuilder private var previewCaption: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let item = model.selectedWorkshopItem {
                HStack(spacing: 8) {
                    Text("Previewing").font(.system(size: 13, weight: .semibold)).opacity(0.9)
                    if let preview = model.selectedWorkshopPreview {
                        // The creator's preview is all Steam has before downloading; the video itself is full size.
                        Text(preview.upscaled ? "Low-res preview, upscaled" : "Low-res preview")
                            .font(.system(size: 11, weight: .bold))
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Capsule().fill(.white.opacity(0.2)))
                            .help("Steam only has this small preview picture. The wallpaper itself is \(item.resolutionText ?? "full size").")
                    }
                }
                Text(item.title).font(.system(size: 40, weight: .bold)).tracking(-0.8).lineLimit(2)
                Text(workshopDetails(item)).font(.system(size: 14)).opacity(0.9)
                if let page = item.page {
                    RenderableLink(destination: page, flat: model.isSnapshot) {
                        Label("On the Steam Workshop", systemImage: "arrow.up.right")
                            .labelStyle(TrailingIconLabelStyle())
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.top, 2)
                }
            } else if model.discoverSource == .workshop {
                Text("Discover").font(.system(size: 13, weight: .semibold)).opacity(0.9)
                Text("Wallpaper Engine").font(.system(size: 40, weight: .bold)).tracking(-0.8)
                Text("Video wallpapers from the Steam Workshop, downloaded by your own Steam. Pick one to see its preview.")
                    .font(.system(size: 14)).opacity(0.9)
            } else if let video = model.selectedDiscoverVideo {
                Text("Previewing").font(.system(size: 13, weight: .semibold)).opacity(0.9)
                Text(video.title).font(.system(size: 40, weight: .bold)).tracking(-0.8).lineLimit(2)
                Text(details(video)).font(.system(size: 14)).opacity(0.9)
                if let page = video.page {
                    RenderableLink(destination: page, flat: model.isSnapshot) {
                        Label("Video by \(video.credit)", systemImage: "arrow.up.right")
                            .labelStyle(TrailingIconLabelStyle())
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.top, 2)
                }
            } else {
                Text("Discover").font(.system(size: 13, weight: .semibold)).opacity(0.9)
                Text("Free videos").font(.system(size: 40, weight: .bold)).tracking(-0.8)
                Text("Footage from Pixabay, free to use. Pick one to preview it here.")
                    .font(.system(size: 14)).opacity(0.9)
            }
        }
        .overVideo()
    }

    private func workshopDetails(_ item: WorkshopItem) -> String {
        ([item.resolutionText, item.size > 0 ? item.size.formatted(.byteCount(style: .file)) : nil] + item.genres.prefix(2).map(Optional.some))
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func details(_ video: DiscoverVideo) -> String {
        let file = video.download
        return [minutesText(video.duration), "\(file.width)×\(file.height)", file.size.formatted(.byteCount(style: .file))]
            .joined(separator: " · ")
    }
}

/// "0:24": Pixabay durations are whole seconds.
private func minutesText(_ seconds: Double) -> String {
    String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
}

/// "Title ↗": the icon after the text, for links.
struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon.font(.system(size: 11, weight: .bold))
        }
    }
}

private struct DiscoverPanel: View {
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
            Spacer()
            // Pixabay asks for a visible link wherever its results are shown.
            RenderableLink(destination: PixabayClient.homepage, flat: model.isSnapshot) {
                Label("pixabay.com", systemImage: "arrow.up.right").labelStyle(TrailingIconLabelStyle())
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.secondary)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary).accessibilityHidden(true)
            RenderableTextField("Search Pixabay videos", text: $model.discoverSearch, flat: model.isSnapshot)
                .textFieldStyle(.plain)
                .onSubmit { model.submitDiscoverSearch() }
            if !model.discoverQuery.isEmpty || !model.discoverSearch.isEmpty {
                Button { model.clearDiscoverSearch() } label: {
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
        .disabled(!model.pixabay.isAvailable)
    }

    /// Topic chips; none is highlighted while a search is shown.
    private var topics: some View {
        FitOrScroll(.horizontal, flat: model.isSnapshot) {
            HStack(spacing: 6) {
                ForEach(DiscoverTopic.all) { topic in
                    let isOn = model.discoverQuery.isEmpty && model.discoverTopic == topic
                    Button { model.selectDiscoverTopic(topic) } label: {
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
        .disabled(!model.pixabay.isAvailable && !model.isSnapshot)
    }

    @ViewBuilder private var content: some View {
        if !model.pixabay.isAvailable && !model.isSnapshot {
            message(icon: "key", title: "Discover isn't set up",
                    text: "This build has no Discover proxy. To use your own free Pixabay API key, run\n"
                        + "defaults write io.github.mxpalm.AerialSwap PixabayKey <key>\nand reopen AerialSwap.")
        } else if model.discoverVideos.isEmpty, let error = model.discoverError {
            message(icon: "wifi.exclamationmark", title: "Couldn't load videos", text: error) {
                Button("Try Again") { model.loadDiscover() }
                    .buttonStyle(PillButtonStyle(kind: .secondary, height: 32))
            }
        } else if model.discoverVideos.isEmpty, model.isDiscoverLoading {
            ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.discoverVideos.isEmpty {
            message(icon: "magnifyingglass", title: "No videos found",
                    text: "Try another word, or pick a topic above.")
        } else if model.isSnapshot {
            grid
        } else {
            ScrollView { grid }.scrollIndicators(.never)
        }
    }

    private var grid: some View {
        VStack(spacing: 12) {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(model.discoverVideos) { video in DiscoverTile(model: model, video: video) }
            }
            .padding(3)
            if model.isDiscoverLoading {
                ProgressView().controlSize(.small).padding(.vertical, 6)
            } else if model.canLoadMoreDiscover {
                Button("Show More") { model.loadDiscover(more: true) }
                    .buttonStyle(PillButtonStyle(kind: .secondary, height: 32))
            } else if let error = model.discoverError {
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

    private var footer: some View {
        VStack(spacing: 8) {
            Button("Use This Video") { model.downloadSelectedDiscover() }
                .buttonStyle(PillButtonStyle(kind: .primary, height: 44, fullWidth: true))
                .disabled(model.selectedDiscoverVideo == nil || model.isBusy)
                .keyboardShortcut(model.selectedDiscoverVideo != nil && model.done == nil ? .defaultAction : nil)
            Text(footerCaption).font(.system(size: 12)).foregroundStyle(Theme.secondary)
        }
        .padding(.top, 12)
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.12)).frame(height: 1) }
    }

    private var footerCaption: String {
        guard let video = model.selectedDiscoverVideo else { return "Pick a video above" }
        let size = video.download.size.formatted(.byteCount(style: .file))
        return "Downloads \(size) (\(video.is4K ? "4K" : "1080p")), then you trim it and pick an Aerial"
    }
}

private struct DiscoverTile: View {
    @Bindable var model: AppModel
    let video: DiscoverVideo

    var body: some View {
        let isSelected = model.selectedDiscoverID == video.id
        Button { model.selectDiscoverVideo(video) } label: {
            VStack(alignment: .leading, spacing: 5) {
                ZStack {
                    Thumb(image: model.discoverThumbnails[video.id], cornerRadius: 9)
                    badge(video.is4K ? "4K" : "HD")
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    badge(minutesText(video.duration))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(isSelected ? Theme.accent : .white.opacity(0.12), lineWidth: isSelected ? 2.5 : 1)
                }
                Text(video.title).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.tail)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isBusy)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu {
            if let page = video.page { Link("View on Pixabay", destination: page) }
        }
        .help("\(video.title)\nVideo by \(video.credit)\n\(video.download.width)×\(video.download.height)")
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
