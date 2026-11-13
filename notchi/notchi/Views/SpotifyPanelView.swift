import SwiftUI
import AppKit

struct SpotifyPanelView: View {
    @Environment(\.panelComposition) private var composition
    @ObservedObject var state: NotchState
    var body: some View {
        let layout = composition.isVertical ? AnyLayout(VStackLayout(alignment: .center, spacing: 16)) : AnyLayout(HStackLayout(spacing: 18))
        return layout {
            AsyncImage(url: URL(string: state.artworkURL)) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                RoundedRectangle(cornerRadius: 28, style: .continuous).fill(.white.opacity(0.08))
                    .overlay { Image(systemName: "music.note").font(.system(size: 26)).foregroundStyle(Color.primary.opacity(0.7)) }
            }
            .frame(width: composition.isVertical ? 210 : (composition == .top ? 150 : 108), height: composition.isVertical ? 210 : (composition == .top ? 150 : 108))
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .shadow(color: .black.opacity(0.3), radius: 8, y: 4)

            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.track).font(.system(size: 17, weight: .bold)).lineLimit(2)
                    Text(state.artist.isEmpty ? "Spotify" : state.artist)
                        .font(.system(size: 13)).foregroundStyle(Color.primary.opacity(0.7)).lineLimit(1)
                }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 10) {
                    Button { SpotifyService.command("previous track", state: state) } label: {
                        Image(systemName: "backward.end.fill").frame(width: 34, height: 34).background(NJP.surfaceStrong, in: Circle())
                    }
                    .help(AppLanguage.text("Faixa anterior"))
                    Button { SpotifyService.command("playpause", state: state) } label: {
                        Image(systemName: state.playing ? "pause.fill" : "play.fill").font(.system(size: 18))
                            .frame(width: 42, height: 42).background(spotifyTint, in: Circle())
                            .foregroundStyle(playButtonForeground)
                    }.help(state.playing ? AppLanguage.text("Pausar") : AppLanguage.text("Reproduzir"))
                    Button { SpotifyService.command("next track", state: state) } label: {
                        Image(systemName: "forward.end.fill").frame(width: 34, height: 34).background(NJP.surfaceStrong, in: Circle())
                    }
                    .help(AppLanguage.text("Próxima faixa"))
                    if !composition.isVertical { Spacer(minLength: 8); albumButton }
                }.font(.system(size: 14))
                    .frame(maxWidth: .infinity, alignment: composition.isVertical ? .center : .leading)
                if composition.isVertical { albumButton.frame(maxWidth: .infinity) }
                if let status = state.spotifyStatus {
                    HStack {
                        Text(status).font(.system(size: 10)).foregroundStyle(NJP.warn).lineLimit(2)
                        Button(AppLanguage.text("Reconectar")) { SpotifyService.refresh(state) }
                        Button(AppLanguage.text("Permissões")) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") { NSWorkspace.shared.open(url) }
                        }
                    }
                }
                if state.duration > 0 {
                    VStack(spacing: 2) {
                        Slider(value: Binding(
                            get: { min(state.position, state.duration) },
                            set: { state.position = $0 }
                        ), in: 0...max(state.duration, 1), onEditingChanged: { editing in
                            state.seeking = editing
                            if !editing { seekSpotify(to: state.position) }
                        })
                        .controlSize(.mini)
                        .labelsHidden()
                        .frame(minWidth: 0, maxWidth: .infinity)
                        .tint(spotifyTint)
                        .help(AppLanguage.text("Posição da música"))
                        HStack {
                            Text(formatTime(state.position))
                            Spacer()
                            Text(formatTime(state.duration))
                        }
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(Color.primary.opacity(0.7))
                    }
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .buttonStyle(.plain)
        .foregroundStyle(Color.primary)
        .padding(.horizontal, composition.isExternal ? 16 : 14)
        .padding(.vertical, composition.isVertical ? 16 : 8)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(LinearGradient(colors: [spotifyTint.opacity(0.30), spotifyTint.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay { RoundedRectangle(cornerRadius: 28).stroke(spotifyTint.opacity(0.18), lineWidth: 1) }
    }

    private var albumButton: some View {
                    Button {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") {
                            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                        }
                    } label: {
                        HStack(spacing: 4) { Text(AppLanguage.text("Escolher álbum")); Image(systemName: "arrow.up.right") }
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.primary.opacity(0.75))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(NJP.surfaceStrong, in: Capsule())
                    }
    }

    /// Cover-derived accent while a track plays, otherwise the app accent.
    private var spotifyTint: Color { state.artworkTint ?? NJP.accent }

    private var playButtonForeground: Color {
        guard let color = NSColor(spotifyTint).usingColorSpace(.deviceRGB) else { return .white }
        let luminance = 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
        return luminance > 0.6 ? .black.opacity(0.88) : .white
    }

    private func formatTime(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.isFinite ? seconds : 0))
        return String(format: "%d:%02d", value / 60, value % 60)
    }

    private func seekSpotify(to position: Double) {
        guard position.isFinite else { return }
        SpotifyService.command("set player position to \(max(0, position))", state: state)
    }


}
