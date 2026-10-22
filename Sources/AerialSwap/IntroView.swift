import AppKit
import SwiftUI

/// First launch: a quiet welcome with the app's name, one sentence and the way in.
struct IntroView: View {
    @Bindable var model: AppModel

    /// The bundle's icon; the raw binary (snapshot mode) falls back to the icon file in Resources/.
    private var appIcon: NSImage? {
        if let icon = NSImage(named: "AppIcon") { return icon }
        return NSImage(contentsOfFile: "Resources/AppIcon.icns")
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            if let appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .accessibilityHidden(true)
            }
            Text("AerialSwap")
                .font(.system(size: 34, weight: .bold)).tracking(-0.5)
                .padding(.top, 20)
            Text("Your own video as a native Aerial on the lock screen and desktop.")
                .font(.system(size: 15)).foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)

            VStack(spacing: 10) {
                Button("Choose a Video…") {
                    model.finishIntro()
                    model.showImporter = true
                }
                .buttonStyle(PillButtonStyle(kind: .primary, height: 44))
                .keyboardShortcut(.defaultAction)
                Button("Look Around First") { model.finishIntro() }
                    .buttonStyle(PillButtonStyle(kind: .quiet, height: 32))
            }
            .padding(.top, 36)
            Spacer()

            if model.assets.isEmpty {
                // The one thing that blocks everything else.
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                        .accessibilityHidden(true)
                    Text("No Aerials downloaded yet.").foregroundStyle(Theme.secondary)
                    Button("Open Wallpaper Settings") { model.openWallpaperSettings() }
                        .buttonStyle(.link)
                }
                .font(.system(size: 12))
                .padding(.bottom, 28)
            }
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.07, green: 0.075, blue: 0.09))
    }
}
