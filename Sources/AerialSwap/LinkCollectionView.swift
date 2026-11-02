import SwiftUI

/// The videos at a link that holds several (a playlist, board, channel, …), found by yt-dlp: pick one to import it.
struct LinkCollectionDialog: View {
    @Bindable var model: AppModel
    let collection: LinkCollection

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

    var body: some View {
        DialogContainer(maxWidth: 860) {
            VStack(alignment: .leading, spacing: 16) {
                header
                grid.frame(maxHeight: 440, alignment: .top)
                footer
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(collection.title).font(.system(size: 22, weight: .bold)).lineLimit(1)
            Text(countText).font(.system(size: 14)).foregroundStyle(Theme.secondary)
        }
    }

    /// "24 videos on pinterest.ca", "The first 200 of 1,450 videos on youtube.com".
    private var countText: String {
        let host = collection.link.host()?.replacingOccurrences(of: "www.", with: "") ?? "this page"
        let shown = collection.videos.count
        let count = collection.total > shown ? "The first \(shown) of \(collection.total.formatted()) videos" : "\(shown) videos"
        return "\(count) on \(host). Pick one to download it."
    }

    @ViewBuilder private var grid: some View {
        let tiles = LazyVGrid(columns: columns, spacing: 14) {
            ForEach(collection.videos) { video in LinkVideoTile(model: model, video: video) }
        }
        .padding(3)
        if model.isSnapshot { tiles } else { ScrollView { tiles }.scrollIndicators(.never) }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("Only use videos you're allowed to use.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            Spacer(minLength: 0)
            Button("Back") { model.backFromLinkCollection() }
                .buttonStyle(PillButtonStyle(kind: .quiet, height: 42))
                .fixedSize()
                .keyboardShortcut(.cancelAction)
            Button("Download") { model.importSelectedLinkVideo() }
                .buttonStyle(PillButtonStyle(kind: .primary, height: 42))
                .fixedSize()
                .keyboardShortcut(model.selectedLinkVideo != nil ? .defaultAction : nil)
                .disabled(model.selectedLinkVideo == nil)
        }
    }
}

private struct LinkVideoTile: View {
    @Bindable var model: AppModel
    let video: LinkVideo

    var body: some View {
        let isSelected = model.selectedLinkVideoID == video.id
        Button { model.selectLinkVideo(video) } label: {
            VStack(alignment: .leading, spacing: 5) {
                ZStack {
                    Thumb(image: model.linkThumbnails[video.id], cornerRadius: 9)
                    if let badge = sizeBadge {
                        self.badge(badge).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    if let duration = video.duration {
                        badge(clockText(duration).replacingOccurrences(of: #"\.\d$"#, with: "", options: .regularExpression))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(isSelected ? Theme.accent : .white.opacity(0.12), lineWidth: isSelected ? 2.5 : 1)
                }
                Text(video.title).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                // Always a line, so tiles without an uploader line up with the others.
                Text(video.uploader ?? " ").font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu { Link("Open in Browser", destination: video.url) }
        .help(video.title)
    }

    /// "720p · Portrait": portrait videos fill a landscape screen only when cropped a lot.
    private var sizeBadge: String? {
        let parts = [video.resolutionText, video.isPortrait ? "Portrait" : nil].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
