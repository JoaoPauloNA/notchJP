import Combine
import Foundation

/// What the dictation is doing, for the notch.
enum DictationPhase: Equatable {
    case idle
    case recording(since: Date)
    case transcribing
    case finished(at: Date, ok: Bool)
}

/// Owns the dictation model and its global shortcut, and turns its flags into a phase for the notch.
@MainActor
final class DictationController: ObservableObject {
    static let shared = DictationController()
    private(set) static var created = false

    /// How long the result stays beside the notch.
    static let finishedWindow: TimeInterval = 3.5

    let model = DictationModel()
    @Published private(set) var phase: DictationPhase = .idle
    private let hotKey = DictationHotKey()
    private var installed = false
    private var cancellables = Set<AnyCancellable>()

    private init() {
        Self.created = true
        model.$isRecording.combineLatest(model.$isProcessing)
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }
            .sink { [weak self] recording, processing in self?.update(recording: recording, processing: processing) }
            .store(in: &cancellables)
    }

    /// Starts or stops the shortcut to match the setting; never creates the controller while it is off.
    static func applySetting() {
        guard NJPSettings.dictationEnabled || created else { return }
        shared.apply()
    }

    func apply() {
        if NJPSettings.dictationEnabled {
            guard !installed else { return }
            hotKey.install(model: model)
            installed = true
        } else if installed {
            hotKey.uninstall()
            installed = false
            phase = .idle
        }
    }

    private func update(recording: Bool, processing: Bool, now: Date = Date()) {
        if recording {
            if case .recording = phase { return }
            phase = .recording(since: now)
        } else if processing {
            phase = .transcribing
        } else {
            switch phase {
            case .recording, .transcribing:
                let ok = model.error == nil && !model.canRetry
                phase = .finished(at: now, ok: ok)
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(Self.finishedWindow + 0.2))
                    if case .finished = self.phase { self.phase = .idle }
                }
            default: break
            }
        }
    }
}
