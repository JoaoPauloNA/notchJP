// Ported from BlabberType (MIT, by the same author). The Painel CLI review step was left out.
import Foundation

enum DictationError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

enum DictationProvider: String, Codable, CaseIterable, Identifiable {
    case analyzer, apple, whisper, api
    var id: String { rawValue }
    var title: String {
        switch self {
        case .analyzer: return "Local · macOS (novo, recomendado)"
        case .apple: return "Local · macOS (clássico)"
        case .whisper: return "Local · Whisper"
        case .api: return "API de transcrição"
        }
    }
}

struct DictationSettings: Codable, Equatable {
    var provider: DictationProvider = .preferred
    var language = "pt-BR"
    var whisperEndpoint = "http://127.0.0.1:8080/inference"
    var apiEndpoint = "https://api.openai.com/v1/audio/transcriptions"
    var apiModel = "whisper-1"
    var correctWithPainel = false
    var painelProfileID: UUID?
    var painelModel = ""
    var keepHistory = true
    /// Show the words while you speak (new engine only).
    var liveText = true
    /// Names and terms the recognizer should expect (one per entry).
    var vocabulary: [String] = []
    var autoPaste = true
    var shortcut = DictationShortcut.standard

    init() { }
    // Keep existing settings when a newly introduced option is absent.
    private enum CodingKeys: String, CodingKey {
        case provider, language, whisperEndpoint, apiEndpoint, apiModel, correctWithPainel, liveText
        case painelProfileID, painelModel, keepHistory, autoPaste, shortcut, vocabulary
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        provider = try values.decodeIfPresent(DictationProvider.self, forKey: .provider) ?? .preferred
        language = try values.decodeIfPresent(String.self, forKey: .language) ?? "pt-BR"
        whisperEndpoint = try values.decodeIfPresent(String.self, forKey: .whisperEndpoint) ?? "http://127.0.0.1:8080/inference"
        apiEndpoint = try values.decodeIfPresent(String.self, forKey: .apiEndpoint) ?? "https://api.openai.com/v1/audio/transcriptions"
        apiModel = try values.decodeIfPresent(String.self, forKey: .apiModel) ?? "whisper-1"
        correctWithPainel = try values.decodeIfPresent(Bool.self, forKey: .correctWithPainel) ?? false
        painelProfileID = try values.decodeIfPresent(UUID.self, forKey: .painelProfileID)
        painelModel = try values.decodeIfPresent(String.self, forKey: .painelModel) ?? ""
        keepHistory = try values.decodeIfPresent(Bool.self, forKey: .keepHistory) ?? true
        autoPaste = try values.decodeIfPresent(Bool.self, forKey: .autoPaste) ?? true
        shortcut = try values.decodeIfPresent(DictationShortcut.self, forKey: .shortcut) ?? .standard
        vocabulary = try values.decodeIfPresent([String].self, forKey: .vocabulary) ?? []
        liveText = try values.decodeIfPresent(Bool.self, forKey: .liveText) ?? true
    }

    var endpoint: String { provider == .whisper ? whisperEndpoint : apiEndpoint }

    /// BlabberType's file keeps the classic engine; move to the new one once, where it exists.
    static func migratedProvider(current: DictationProvider, analyzerSupported: Bool, alreadyMigrated: Bool) -> DictationProvider {
        guard !alreadyMigrated, analyzerSupported, current == .apple else { return current }
        return .analyzer
    }
    var apiLanguage: String { String(language.prefix(2)) }
}

struct DictationRecord: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    let original: String
    let text: String
    let provider: String
    let duration: TimeInterval
}

struct DictationAPIConnection {
    let url: URL
    let key: String
    init(endpoint: String, key: String = "", localOnly: Bool = false) throws {
        guard let parts = URLComponents(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              let url = parts.url else {
            throw DictationError.message("Informe um endereço válido para a conexão.")
        }
        let loopback = ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)
        guard parts.scheme == "https" || (parts.scheme == "http" && loopback) else {
            throw DictationError.message("Use HTTPS para APIs ou HTTP em localhost para um modelo local.")
        }
        guard !localOnly || loopback else {
            throw DictationError.message("A conexão local precisa apontar para localhost ou 127.0.0.1.")
        }
        guard !key.contains(where: { $0.isNewline || $0.asciiValue.map { $0 < 32 } == true }) else {
            throw DictationError.message("A chave contém caracteres inválidos.")
        }
        self.url = url
        self.key = key
    }
}

/// A redirect must never send an audio file or a profile key to another endpoint.
final class DictationNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

final class DictationAPI {
    // Avoid Swift isolated-deinit back-deployment crashes (swiftlang/swift#88036).
    nonisolated deinit {}
    private let session: URLSession
    init(session: URLSession? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 180
        self.session = session ?? URLSession(configuration: config, delegate: DictationNoRedirects(), delegateQueue: nil)
    }

    func transcriptionRequest(audio: Data, settings: DictationSettings, key: String) throws -> URLRequest {
        guard audio.count > 44 else { throw DictationError.message("O áudio está vazio.") }
        guard audio.count < 24_000_000 else { throw DictationError.message("O áudio excedeu o limite de 24 MB.") }
        let connection = try DictationAPIConnection(endpoint: settings.endpoint, key: key,
                                           localOnly: settings.provider == .whisper)
        if settings.provider == .api && settings.apiModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw DictationError.message("Informe o modelo de transcrição.")
        }
        let boundary = "Ditado-\(UUID().uuidString)"
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        func field(_ name: String, _ value: String) {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        if settings.provider == .api { field("model", settings.apiModel) }
        field("language", settings.apiLanguage)
        field("response_format", "json")
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"ditado.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        body.append(audio)
        append("\r\n--\(boundary)--\r\n")
        var request = URLRequest(url: connection.url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.httpBody = body
        return request
    }

    func transcribe(audio: Data, settings: DictationSettings, key: String) async throws -> String {
        let request = try transcriptionRequest(audio: audio, settings: settings, key: key)
        let data = try await send(request)
        struct Response: Decodable { let text: String }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw DictationError.message("A conexão não devolveu uma transcrição JSON válida.")
        }
        return try nonempty(response.text)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw DictationError.message("Resposta inválida da conexão.") }
        guard (200...299).contains(http.statusCode) else {
            let detail: String
            switch http.statusCode {
            case 401, 403: detail = "A conexão recusou a chave ou a permissão."
            case 404: detail = "Endereço ou modelo não encontrado. Confira se o serviço oferece esta operação."
            case 413: detail = "O serviço recusou o tamanho do áudio."
            case 429: detail = "Limite de uso atingido. Aguarde antes de tentar novamente."
            case 300...399: detail = "O endereço redirecionou a requisição. Informe o endereço final nas conexões."
            default: detail = "O serviço não conseguiu concluir a solicitação."
            }
            throw DictationError.message("\(detail) (HTTP \(http.statusCode))")
        }
        return data
    }

    private func nonempty(_ value: String) throws -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw DictationError.message("Nenhuma fala foi reconhecida.") }
        return text
    }
}

/// Apply typography after recognition/review while retaining the original transcript.
enum DictationTextFormatting {
    private static let percentage = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_])([+-]?[0-9]+(?:[.,][0-9]+)*)\h+por\h+cento\b"#,
        options: [.caseInsensitive]
    )

    static func format(_ text: String, language: String) -> String {
        guard language.lowercased().split(separator: "-").first == "pt" else { return text }
        let digits = spokenPercentages(in: text)
        return percentage.stringByReplacingMatches(in: digits,
            range: NSRange(digits.startIndex..<digits.endIndex, in: digits), withTemplate: "$1%")
    }

    // MARK: Spoken numbers ("vinte e cinco por cento" -> "25 por cento")

    private static let numberWords: [String: Int] = [
        "zero": 0, "um": 1, "uma": 1, "dois": 2, "duas": 2, "três": 3, "tres": 3, "quatro": 4, "cinco": 5, "seis": 6,
        "sete": 7, "oito": 8, "nove": 9, "dez": 10, "onze": 11, "doze": 12, "treze": 13, "catorze": 14, "quatorze": 14,
        "quinze": 15, "dezesseis": 16, "dezasseis": 16, "dezessete": 17, "dezassete": 17, "dezoito": 18,
        "dezenove": 19, "dezanove": 19, "vinte": 20, "trinta": 30, "quarenta": 40, "cinquenta": 50, "sessenta": 60,
        "setenta": 70, "oitenta": 80, "noventa": 90, "cem": 100, "cento": 100, "duzentos": 200, "trezentos": 300,
        "quatrocentos": 400, "quinhentos": 500, "seiscentos": 600, "setecentos": 700, "oitocentos": 800,
        "novecentos": 900,
    ]
    private static let digitWords: [String: Int] = [
        "zero": 0, "um": 1, "dois": 2, "três": 3, "tres": 3, "quatro": 4, "cinco": 5, "seis": 6, "sete": 7, "oito": 8, "nove": 9,
    ]

    private static let spokenPercentage: NSRegularExpression = {
        let words = numberWords.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        let digits = digitWords.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        let pattern = #"(?<![\p{L}\p{N}_])((?:(?:"# + words + #")(?:\h+e\h+|\h+))*(?:"# + words + #"))(?:\h+v[ií]rgula\h+((?:"# + digits
            + #")(?:\h+(?:"# + digits + #"))*))?\h+por\h+cento\b"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// Integer value of "cento e vinte e cinco" (125); nil when a word is unknown.
    static func spokenInteger(_ phrase: String) -> Int? {
        let tokens = phrase.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { $0 != "e" }
        guard !tokens.isEmpty else { return nil }
        var total = 0
        for token in tokens {
            guard let value = numberWords[token] else { return nil }
            total += value
        }
        return total
    }

    static func spokenPercentages(in text: String) -> String {
        var result = text
        let matches = spokenPercentage.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
        for match in matches.reversed() {
            guard let whole = Range(match.range, in: result),
                  let integerRange = Range(match.range(at: 1), in: text),
                  let integer = spokenInteger(String(text[integerRange])) else { continue }
            var number = String(integer)
            if match.range(at: 2).location != NSNotFound, let fractionRange = Range(match.range(at: 2), in: text) {
                let fraction = text[fractionRange].lowercased().split(whereSeparator: { $0.isWhitespace })
                    .compactMap { digitWords[String($0)] }.map(String.init).joined()
                if !fraction.isEmpty { number += "," + fraction }
            }
            result.replaceSubrange(whole, with: number + " por cento")
        }
        return result
    }
}
