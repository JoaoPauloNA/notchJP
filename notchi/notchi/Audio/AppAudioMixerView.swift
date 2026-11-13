import AppKit
import SwiftUI

struct AppAudioMixerView: View {
    @Environment(\.panelComposition) private var composition
    @ObservedObject private var mixer = AppAudioMixer.shared
    @ObservedObject private var profiles = AudioProfiles.shared
    @State private var profileName = ""
    @State private var editingProfile: String?
    @State private var onlyPlaying = false

    private var apps: [AudioApp] { mixer.apps.filter { !onlyPlaying || $0.isPlaying || mixer.isControlled($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let headerLayout = composition.isVertical ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
            headerLayout {
                VStack(alignment: .leading, spacing: 3) {
                    Text(AppLanguage.text("Volume por aplicativo")).font(.system(size: 15, weight: .semibold))
                    Label(AppLanguage.text(mixer.outputName), systemImage: "speaker.wave.2")
                        .font(.system(size: 10)).foregroundStyle(Color.primary.opacity(0.7)).lineLimit(1)
                }
                if !composition.isVertical { Spacer() }
                Toggle(AppLanguage.text("Com áudio"), isOn: $onlyPlaying).toggleStyle(.checkbox).font(.system(size: 10))
                Button(AppLanguage.text("Restaurar")) { mixer.restoreAll() }
                    .help(AppLanguage.text("Restaurar todos os aplicativos para 100% e liberar o áudio original"))
                Toggle(AppLanguage.text("Ativar mixer"), isOn: Binding(get: { mixer.enabled }, set: { mixer.setEnabled($0) }))
                    .toggleStyle(.switch).controlSize(.small)
            }
            .font(.system(size: 11))

            let profileLayout = composition.isVertical ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(spacing: 8))
            profileLayout {
                Menu(AppLanguage.text("Perfis de áudio")) {
                    ForEach(profiles.profiles) { profile in
                        Button(profile.name) { mixer.apply(profile) }
                    }
                    Divider()
                    ForEach(profiles.profiles) { profile in
                        Menu(profile.name) {
                            Button(AppLanguage.text("Renomear")) { editingProfile = profile.id; profileName = profile.name }
                            Button(AppLanguage.text("Excluir"), role: .destructive) { profiles.delete(profile.id) }
                        }
                    }
                }
                TextField(AppLanguage.text("Trabalho, Música, Reunião…"), text: $profileName)
                    .textFieldStyle(.roundedBorder)
                Button(editingProfile == nil ? AppLanguage.text("Salvar perfil") : AppLanguage.text("Renomear")) {
                    if let id = editingProfile { profiles.rename(id, to: profileName) }
                    else { _ = profiles.save(name: profileName, mixer: mixer) }
                    profileName = ""; editingProfile = nil
                }.disabled(profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || profileName.trimmingCharacters(in: .whitespacesAndNewlines).count > 60)
                if editingProfile != nil { Button(AppLanguage.text("Cancelar")) { editingProfile = nil; profileName = "" } }
            }.font(.caption)
            if let status = mixer.status {
                Text(status).font(.system(size: 11)).foregroundStyle(NJP.warn)
            }
            if !mixer.enabled {
                Text(AppLanguage.text("Ative para ajustar cada app. O macOS poderá pedir acesso ao áudio do sistema; nada é salvo em arquivo."))
                    .font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.7))
            }
            if apps.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 25)).foregroundStyle(NJP.accent)
                    Text(onlyPlaying ? AppLanguage.text("Nenhum aplicativo está usando áudio agora") : AppLanguage.text("Abra um aplicativo para ajustar seu som"))
                        .font(.system(size: 12))
                    Text(AppLanguage.text("Inicie uma música, vídeo ou chamada para o app aparecer com áudio."))
                        .font(.system(size: 10)).foregroundStyle(Color.primary.opacity(0.7))
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(apps) { app in row(app) }
                    }.padding(.bottom, 3)
                }
            }
            Text(AppLanguage.text("0% silencia · destino e volume independentes por aplicativo"))
                .font(.system(size: 9)).foregroundStyle(Color.primary.opacity(0.7))
        }
        .foregroundStyle(Color.primary)
        .tint(NJP.accent)
        .onAppear { if !CommandLine.arguments.contains(where: { $0.hasPrefix("--render") }) { mixer.show() } }
        .onDisappear { if !CommandLine.arguments.contains(where: { $0.hasPrefix("--render") }) { mixer.hide() } }
        .accessibilityIdentifier("app-audio-mixer")
    }

    private func row(_ app: AudioApp) -> some View {
        let level = mixer.level(for: app.id)
        let error = mixer.errors[app.id]
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Group {
                    if let icon = app.icon { Image(nsImage: icon).resizable().scaledToFit() }
                    else { Image(systemName: "app.fill").resizable().scaledToFit().padding(4) }
                }.frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    Text(error != nil ? AppLanguage.text("Ajuste não aplicado") : (mixer.isControlled(app.id) ? AppLanguage.text("Volume ajustado") : (app.isPlaying ? AppLanguage.text("Com áudio") : AppLanguage.text("Aguardando áudio"))))
                        .font(.system(size: 9)).foregroundStyle(error != nil ? NJP.warn : .white.opacity(0.45))
                }.frame(width: 135, alignment: .leading)
                Button { mixer.toggleMute(app.id) } label: {
                    Image(systemName: level.gain == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(level.gain == 0 ? NJP.accent : .white.opacity(0.7))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(level.muted ? "Restaurar som de" : AppLanguage.text("Silenciar")) \(app.name)")
                if !composition.isVertical {
                Slider(value: Binding(get: { Double(level.volume) }, set: { mixer.setVolume(Float($0), for: app.id) }), in: 0...1)
                    .accessibilityLabel("Volume de \(app.name)")
                    .accessibilityValue("\(Int(level.gain * 100)) por cento")
                }
                Text("\(Int((level.gain * 100).rounded()))%")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .frame(width: 38, alignment: .trailing)
            }.disabled(!mixer.enabled)
            if composition.isVertical {
                Slider(value: Binding(get: { Double(level.volume) }, set: { mixer.setVolume(Float($0), for: app.id) }), in: 0...1)
                    .accessibilityLabel("Volume de \(app.name)")
                    .accessibilityValue("\(Int(level.gain * 100)) por cento")
                    .disabled(!mixer.enabled)
            }
            let outputLayout = composition.isVertical ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 10))
            outputLayout {
                TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                    AudioPeakMeter(mixer: mixer, appID: app.id)
                }.frame(width: composition.isVertical ? nil : 65)
                Picker(AppLanguage.text("Saída"), selection: Binding(get: { mixer.destination(for: app.id) }, set: { mixer.setDestination($0, for: app.id) })) {
                    Text(AppLanguage.text("Seguir padrão do Mac")).tag("")
                    ForEach(mixer.outputs) { output in Text(output.name).tag(output.uid) }
                    if !mixer.destination(for: app.id).isEmpty && !mixer.outputs.contains(where: { $0.uid == mixer.destination(for: app.id) }) {
                        Text(AppLanguage.text("Saída indisponível")).tag(mixer.destination(for: app.id))
                    }
                }.font(.system(size: 10)).disabled(!mixer.enabled)
            }
            if let error {
                HStack(alignment: .top) {
                    Text(error).font(.system(size: 10)).foregroundStyle(NJP.warn)
                    Spacer(minLength: 4)
                    Button(AppLanguage.text("Tentar novamente")) { mixer.retry(app.id) }.font(.system(size: 10))
                    Button(AppLanguage.text("Permissões")) {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    }.font(.system(size: 10))
                }
            }
        }.padding(8).njpCard(radius: 12)
    }
}

private struct AudioPeakMeter: View {
    let mixer: AppAudioMixer
    let appID: String
    var body: some View {
        let peak = min(1, max(0, mixer.takePeak(appID)))
        GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach(0..<16) { index in
                    RoundedRectangle(cornerRadius: 1).fill(index < Int(ceil(peak * 16)) ? (index >= 12 ? NJP.warn : NJP.good) : Color.white.opacity(0.1))
                }
            }
        }.frame(height: 5).accessibilityLabel(AppLanguage.text("Nível de áudio"))
    }
}
