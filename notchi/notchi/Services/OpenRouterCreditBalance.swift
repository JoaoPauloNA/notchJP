import Foundation

nonisolated enum OpenRouterCreditBalance {
    static func parse(_ data: Data) throws -> Double {
        guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = document["data"] as? [String: Any],
              let credits = number(values["total_credits"]), let usage = number(values["total_usage"]) else {
            throw URLError(.cannotParseResponse)
        }
        return credits - usage
    }

    static func status(for code: Int) -> String {
        switch code {
        case 401: "Chave inválida ou expirada"
        case 403: "Use uma chave de gerenciamento"
        case 429: "Limite de consultas; tente novamente depois"
        default: "OpenRouter indisponível (HTTP \(code))"
        }
    }

    private static func number(_ raw: Any?) -> Double? {
        guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite, value.doubleValue >= 0 else { return nil }
        return value.doubleValue
    }
}
