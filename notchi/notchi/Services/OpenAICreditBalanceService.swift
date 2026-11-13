import AppKit
import ApplicationServices
import Foundation

nonisolated struct OpenAICreditSnapshot: Codable, Equatable, Sendable {
    let balance: Double
    let observedAt: Date
}

nonisolated enum OpenAICreditPage {
    static func accepts(_ url: URL) -> Bool {
        guard url.scheme == "https", url.host == "platform.openai.com" else { return false }
        var path = url.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return ["/home", "/usage", "/settings/organization/billing/overview"].contains(path)
    }

    // Match only the amount immediately following the credit-balance label.
    // Usage totals, budgets, project limits and API keys are not balances.
    static func balance(in texts: [String]) -> Double? {
        let lines = texts.flatMap { $0.components(separatedBy: .newlines) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var matches: [Double] = []
        for (index, line) in lines.enumerated() {
            guard ["credit balance", "saldo de créditos", "saldo de creditos"]
                .contains(line.lowercased()) else { continue }
            for value in lines.dropFirst(index + 1).prefix(1) {
                guard let amount = amount(value) else { continue }
                matches.append(amount)
                break
            }
        }
        guard let first = matches.first, matches.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    private static func amount(_ text: String) -> Double? {
        let text = text.replacingOccurrences(of: "\u{00a0}", with: " ").trimmingCharacters(in: .whitespaces)
        guard text.range(of: #"^(?:US\$|USD|\$)\s*[0-9][0-9.,]*$"#, options: .regularExpression) != nil else { return nil }
        var number = text.replacingOccurrences(of: #"^(?:US\$|USD|\$)\s*"#, with: "", options: .regularExpression)
        if number.range(of: #"^[0-9]+(?:,[0-9]{3})*(?:\.[0-9]{2})?$"#, options: .regularExpression) != nil {
            number = number.replacingOccurrences(of: ",", with: "")
        } else if number.range(of: #"^[0-9]+(?:\.[0-9]{3})*(?:,[0-9]{2})?$"#, options: .regularExpression) != nil {
            number = number.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
        } else { return nil }
        guard let value = Double(number), value.isFinite, value >= 0 else { return nil }
        return value
    }
}

nonisolated enum OpenAICreditReadError: Error, LocalizedError {
    case permission, safariClosed, billingPageMissing, balanceMissing, timedOut
    var errorDescription: String? {
        switch self {
        case .permission: "Autorize o notchJP em Acessibilidade"
        case .safariClosed: "Abra o painel da OpenAI no Safari"
        case .billingPageMissing: "Deixe a página de saldo da OpenAI selecionada no Safari"
        case .balanceMissing: "O saldo de créditos não está visível na página"
        case .timedOut: "Safari demorou para responder; use Atualizar"
        }
    }
}

nonisolated enum OpenAICreditSafariReader {
    static func read() throws -> Double {
        guard AXIsProcessTrusted() else { throw OpenAICreditReadError.permission }
        guard let safari = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").first else {
            throw OpenAICreditReadError.safariClosed
        }
        let application = AXUIElementCreateApplication(safari.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.25)
        guard let rawWindow = attribute(application, kAXFocusedWindowAttribute),
              CFGetTypeID(rawWindow) == AXUIElementGetTypeID() else {
            throw OpenAICreditReadError.billingPageMissing
        }
        let selectedWindow = rawWindow as! AXUIElement
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        var queue = [selectedWindow], visited = Set<AXUIElement>(), webArea: AXUIElement?
        while !queue.isEmpty, visited.count < 1200 {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw OpenAICreditReadError.timedOut }
            let element = queue.removeLast()
            guard visited.insert(element).inserted else { continue }
            let role = attribute(element, kAXRoleAttribute) as? String
            if role == "AXWebArea" {
                let rawURL = attribute(element, kAXURLAttribute)
                let url = (rawURL as? URL) ?? (rawURL as? String).flatMap(URL.init(string:))
                if let url, OpenAICreditPage.accepts(url) { webArea = element; break }
                // Never inspect the content of other sites or API-key pages.
                continue
            }
            queue.append(contentsOf: children(element).reversed())
        }
        guard let webArea else { throw OpenAICreditReadError.billingPageMissing }
        var texts: [String] = []
        queue = [webArea]; visited.removeAll()
        while !queue.isEmpty, visited.count < 4000 {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw OpenAICreditReadError.timedOut }
            let element = queue.removeLast()
            guard visited.insert(element).inserted else { continue }
            let role = attribute(element, kAXRoleAttribute) as? String
            if role == "AXStaticText", let value = attribute(element, kAXValueAttribute) as? String,
               value.utf8.count < 500 {
                texts.append(value)
            }
            queue.append(contentsOf: children(element).reversed())
        }
        guard let balance = OpenAICreditPage.balance(in: texts) else { throw OpenAICreditReadError.balanceMissing }
        return balance
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }
}

@MainActor @Observable
final class OpenAICreditBalanceService {
    static let shared = OpenAICreditBalanceService()
    private static let snapshotKey = "openAICreditBalanceSnapshot"
    private static let enabledKey = "openAICreditSafariEnabled"
    private(set) var snapshot: OpenAICreditSnapshot?
    private(set) var status = "Conecte o painel nas configurações"
    private(set) var isRefreshing = false
    private(set) var isStale = true
    private(set) var enabled: Bool
    private let fetch: @Sendable () async throws -> Double
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, fetch: @escaping @Sendable () async throws -> Double = {
        try await Task.detached(priority: .utility) { try OpenAICreditSafariReader.read() }.value
    }) {
        self.defaults = defaults
        self.fetch = fetch
        enabled = defaults.bool(forKey: Self.enabledKey)
        if let data = defaults.data(forKey: Self.snapshotKey),
           let saved = try? JSONDecoder().decode(OpenAICreditSnapshot.self, from: data),
           saved.balance.isFinite, saved.balance >= 0, saved.observedAt <= Date() {
            snapshot = saved
        }
    }

    func enable() {
        enabled = true
        defaults.set(true, forKey: Self.enabledKey)
    }

    func disable() {
        enabled = false
        defaults.set(false, forKey: Self.enabledKey)
        isStale = true
        status = "Leitura do Safari desativada"
    }

    func refresh() async {
        guard enabled, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let balance = try await fetch()
            guard enabled else { return }
            guard balance.isFinite, balance >= 0 else { throw OpenAICreditReadError.balanceMissing }
            let value = OpenAICreditSnapshot(balance: balance, observedAt: Date())
            snapshot = value
            isStale = false
            status = "Saldo lido no Safari"
            if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: Self.snapshotKey) }
        } catch {
            isStale = true
            status = error.localizedDescription
        }
    }
}
