import Foundation

nonisolated struct ProviderCapabilities: Sendable {
    let supportsPermissionPrompts: Bool
    let supportsUsageResumeTriggers: Bool
    let supportsPromptEmotionAnalysis: Bool
    let supportsDerivedTranscriptFallback: Bool
}

nonisolated enum AgentProvider: String, Codable, CaseIterable, Hashable, Sendable {
    case claude
    case codex
    case devin
    case agy

    var displayName: String {
        switch self {
        case .claude:
            "Claude"
        case .codex:
            "Codex"
        case .devin:
            "Devin"
        case .agy:
            "AGY"
        }
    }

    var capabilities: ProviderCapabilities {
        switch self {
        case .claude:
            ProviderCapabilities(
                supportsPermissionPrompts: true,
                supportsUsageResumeTriggers: true,
                supportsPromptEmotionAnalysis: true,
                supportsDerivedTranscriptFallback: true
            )
        case .codex:
            ProviderCapabilities(
                supportsPermissionPrompts: true,
                supportsUsageResumeTriggers: false,
                supportsPromptEmotionAnalysis: true,
                supportsDerivedTranscriptFallback: false
            )
        case .devin, .agy:
            ProviderCapabilities(
                supportsPermissionPrompts: false,
                supportsUsageResumeTriggers: false,
                supportsPromptEmotionAnalysis: true,
                supportsDerivedTranscriptFallback: false
            )
        }
    }
}
