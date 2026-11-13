import SwiftUI

/// What the collapsed notch announces beside the camera housing.
enum NotchAlert: Equatable {
    case event(title: String, start: Date)
    case lowDisk(freeGB: Int)
    case agentApproval(project: String, agent: String)
    case agentDone(project: String)
    case timer(end: Date)
    case timerDone
    case nowPlaying(title: String)
    case privacy(mic: Bool, camera: Bool)
    case dictation(DictationPhase)

    var symbol: String {
        switch self {
        case .event: "calendar"
        case .lowDisk: "internaldrive"
        case .agentApproval: "hand.raised.fill"
        case .agentDone: "checkmark.circle.fill"
        case .timer: "timer"
        case .timerDone: "bell.fill"
        case .nowPlaying: "waveform"
        case .privacy(_, let camera): camera ? "video.fill" : "mic.fill"
        case .dictation(let phase):
            switch phase {
            case .recording: "mic.fill"
            case .transcribing: "waveform"
            case .finished(_, let ok): ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            case .idle: "mic"
            }
        }
    }

    var tint: Color {
        switch self {
        case .event: NJP.accentSoft
        case .lowDisk: NJP.warn
        case .agentApproval: NJP.accentSoft
        case .agentDone: NJP.good
        case .timer: NJP.accentSoft
        case .timerDone: NJP.good
        case .nowPlaying: NJP.accent
        case .privacy: NJP.bad
        case .dictation(let phase):
            switch phase {
            case .recording: NJP.bad
            case .transcribing: NJP.accentSoft
            case .finished(_, let ok): ok ? NJP.good : NJP.warn
            case .idle: NJP.accentSoft
            }
        }
    }

    /// Short text for the right wing, relative to `now`.
    func label(now: Date) -> String {
        switch self {
        case .event(_, let start):
            let minutes = Int((start.timeIntervalSince(now) / 60).rounded(.up))
            return minutes <= 0 ? "agora" : "\(minutes) min"
        case .lowDisk(let freeGB):
            return "\(freeGB) GB"
        case .agentApproval: return "aprovar"
        case .agentDone: return "pronto"
        case .timer(let end): return FocusTimerService.format(end.timeIntervalSince(now))
        case .timerDone: return "fim"
        case .nowPlaying(let title): return title
        case .privacy(let mic, let camera): return mic && camera ? "mic+cam" : (camera ? "câmera" : "mic")
        case .dictation(let phase):
            switch phase {
            case .recording(let since):
                let seconds = max(0, Int(now.timeIntervalSince(since)))
                return String(format: "%d:%02d", seconds / 60, seconds % 60)
            case .transcribing: return "…"
            case .finished(_, let ok): return ok ? "colado" : "falhou"
            case .idle: return ""
            }
        }
    }

    var accessibilityText: String {
        switch self {
        case .event(let title, _): "Próximo compromisso: \(title)"
        case .lowDisk(let freeGB): "Pouco espaço em disco: \(freeGB) GB livres"
        case .agentApproval(let project, let agent): "\(agent) precisa de aprovação em \(project)"
        case .agentDone(let project): "Sessão concluída em \(project)"
        case .timer: "Cronômetro em andamento"
        case .timerDone: "O cronômetro terminou"
        case .nowPlaying(let title): "Tocando: \(title)"
        case .dictation(let phase):
            switch phase {
            case .recording: "Ditado: gravando"
            case .transcribing: "Ditado: transcrevendo"
            case .finished(_, let ok): ok ? "Ditado concluído" : "O ditado falhou"
            case .idle: "Ditado"
            }
        case .privacy(let mic, let camera): "Em uso: " + [mic ? "microfone" : nil, camera ? "câmera" : nil].compactMap { $0 }.joined(separator: " e ")
        }
    }

    /// The waveform keeps moving while music plays.
    var animatesIcon: Bool {
        switch self {
        case .nowPlaying, .dictation(.transcribing): true
        default: false
        }
    }

    /// The countdown needs a redraw every second.
    var ticksEverySecond: Bool {
        switch self {
        case .timer, .dictation(.recording): true
        default: false
        }
    }

    /// Approval requests draw the eye with a pulsing icon.
    var pulses: Bool {
        switch self {
        case .agentApproval, .dictation(.recording): true
        default: false
        }
    }
}
