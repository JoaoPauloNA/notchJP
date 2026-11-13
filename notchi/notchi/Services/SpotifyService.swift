import AppKit
import SwiftUI

/// Serializes AppleScript reads and commands so polling cannot race a user action.
@MainActor enum SpotifyService {
    private static var refreshing = false
    nonisolated private static let queue = DispatchQueue(label: "com.ruban.notchi.spotify", qos: .userInitiated)
    nonisolated static func diagnostic(code: Int) -> String {
        switch code {
        case -1743: "Permita ao notchJP controlar o Spotify em Automação."
        case -600: "Spotify fechado. Use Reproduzir para abri-lo."
        case -1712: "Spotify não respondeu. Tente reconectar ou reinicie o Spotify."
        default: "O comando do Spotify falhou (\(code)). Tente reconectar."
        }
    }
    static func command(_ command: String, state: NotchState) {
        let running = NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.spotify.client" })
        if !running {
            // Only play brings a closed Spotify back; skipping tracks in an app nobody opened would be surprising.
            guard command == "playpause", let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") else { return }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.hides = true
            let previous = NSWorkspace.shared.frontmostApplication
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { spotify, error in
                guard error == nil else {
                    DispatchQueue.main.async { state.spotifyStatus = "Não foi possível abrir o Spotify." }
                    return
                }
                queue.async {
                    // Spotify answers AppleScript only after it finishes loading, so try for a few seconds.
                    // It shows its own window when it finishes loading, so keep it hidden and give the focus back.
                    // Playing does not mean it is done: the window can still appear a few seconds later,
                    // so only stop once it has stayed hidden for a while after the music started.
                    var played = false
                    var quiet = 0
                    for _ in 0..<60 {
                        if !played {
                            var failure: NSDictionary?
                            NSAppleScript(source: "tell application \"Spotify\" to play")?.executeAndReturnError(&failure)
                            played = failure == nil
                        }
                        let hidAgain: Bool = DispatchQueue.main.sync {
                            guard let spotify, spotify.isActive || !spotify.isHidden else { return false }
                            spotify.hide()
                            if previous?.isTerminated == false { previous?.activate() }
                            return true
                        }
                        quiet = played && !hidAgain ? quiet + 1 : 0
                        if quiet >= 15 { break }
                        Thread.sleep(forTimeInterval: 0.3)
                    }
                    DispatchQueue.main.async { refresh(state) }
                }
            }
            return
        }
        queue.async {
            let script = NSAppleScript(source: "with timeout of 5 seconds\ntell application \"Spotify\" to \(command)\nend timeout")
            var failure: NSDictionary?
            script?.executeAndReturnError(&failure)
            let problem = failure.flatMap { diagnostic(code: ($0[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0) }
            DispatchQueue.main.async { state.spotifyStatus = problem }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { refresh(state) }
        }
    }

    static func refresh(_ state: NotchState) {
    guard !refreshing else { return }
    guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.spotify.client" }) else {
        state.spotifyStatus = "Spotify fechado. Use Reproduzir para abri-lo."
        state.track = "Spotify não está aberto"
        state.artist = ""
        state.album = ""
        state.artworkURL = ""
        state.artworkTint = nil
        state.playing = false
        state.position = 0
        state.duration = 0
        return
    }
    refreshing = true
    queue.async {
        let source = """
        with timeout of 5 seconds
        tell application "Spotify"
            if player state is stopped then return {"Nenhuma faixa em reprodução", "", "", false, "", 0, 0}
            return {name of current track, artist of current track, album of current track, player state is playing, artwork url of current track, player position, duration of current track}
        end tell
        end timeout
        """
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        let problem = error.flatMap { diagnostic(code: ($0[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0) }
        let title = result?.atIndex(1)?.stringValue
        let artist = result?.atIndex(2)?.stringValue
        let album = result?.atIndex(3)?.stringValue
        let playing = result?.atIndex(4)?.booleanValue ?? false
        let artwork = result?.atIndex(5)?.stringValue ?? ""
        let position = result?.atIndex(6)?.doubleValue ?? 0
        let rawDuration = result?.atIndex(7)?.doubleValue ?? 0
        let duration = rawDuration > 10000 ? rawDuration / 1000 : rawDuration
        DispatchQueue.main.async {
            refreshing = false
            state.spotifyStatus = problem
            state.track = title ?? "Não foi possível acessar o Spotify"
            state.artist = title == nil ? "Verifique a permissão em Ajustes do Sistema" : (artist ?? "")
            state.album = album ?? ""
            state.playing = playing
            if state.artworkURL != artwork {
                state.artworkURL = artwork
                state.artworkTint = nil
                Task { @MainActor in
                    let tint = await ArtworkTintLoader.shared.tint(for: artwork)
                    if state.artworkURL == artwork { withAnimation(.easeInOut(duration: 0.5)) { state.artworkTint = tint } }
                }
            }
            if !state.seeking { state.position = max(0, position) }
            state.duration = max(0, duration)
        }
    }
}

}
