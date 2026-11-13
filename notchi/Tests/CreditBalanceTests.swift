import XCTest
@testable import notchi

@MainActor
final class CreditBalanceTests: XCTestCase {
    func testOpenAIPageOnlyAcceptsOfficialBalancePages() {
        for path in ["/home", "/usage", "/settings/organization/billing/overview/"] {
            XCTAssertTrue(OpenAICreditPage.accepts(URL(string: "https://platform.openai.com" + path)!))
        }
        for url in ["https://platform.openai.com/api-keys", "https://platform.openai.com/settings/proj_example/limits",
                    "https://platform.openai.com.evil.example/home", "http://platform.openai.com/home",
                    "https://openrouter.ai/settings/credits"] {
            XCTAssertFalse(OpenAICreditPage.accepts(URL(string: url)!))
        }
    }

    func testOpenAIBalanceDoesNotUseCostsOrProjectBudget() {
        XCTAssertEqual(OpenAICreditPage.balance(in: ["Usage", "$8.00", "Credit balance", "$137.42", "Monthly budget", "$1.00"]), 137.42)
        XCTAssertNil(OpenAICreditPage.balance(in: ["Total spend", "$8.00", "Project budget", "$1.00"]))
    }

    func testOpenAIBalanceSupportsLocalizedAmountAndZero() {
        XCTAssertEqual(OpenAICreditPage.balance(in: ["Saldo de créditos", "US$ 1.137,42"]), 1137.42)
        XCTAssertEqual(OpenAICreditPage.balance(in: ["Credit balance", "$1,137.42"]), 1137.42)
        XCTAssertEqual(OpenAICreditPage.balance(in: ["Credit balance", "$0.00"]), 0)
    }

    func testOpenAIBalanceRejectsMissingAndAmbiguousAmounts() {
        XCTAssertNil(OpenAICreditPage.balance(in: ["Credit balance", "137.42"]))
        XCTAssertNil(OpenAICreditPage.balance(in: ["Credit balance", "R$137,42"]))
        XCTAssertNil(OpenAICreditPage.balance(in: ["Credit balance", "$137.42", "Credit balance", "$20.00"]))
        XCTAssertNil(OpenAICreditPage.balance(in: ["Credit balance", "Monthly budget", "$100.00"]))
        XCTAssertNil(OpenAICreditPage.balance(in: ["Credit balance", "$1,2,3"]))
    }

    func testOpenAIReaderDoesNotRunBeforeUserEnablesIt() async {
        let suite = "notchi-credit-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let counter = CreditReadCounter()
        let service = OpenAICreditBalanceService(defaults: defaults, fetch: { await counter.read() })
        await service.refresh()
        XCTAssertNil(service.snapshot)
        let calls = await counter.calls
        XCTAssertEqual(calls, 0)
        service.enable()
        await service.refresh()
        XCTAssertEqual(service.snapshot?.balance, 137.42)
        XCTAssertFalse(service.isStale)
        let restored = OpenAICreditBalanceService(defaults: defaults, fetch: { 0 })
        XCTAssertEqual(restored.snapshot, service.snapshot)
        XCTAssertTrue(restored.isStale)
    }

    func testOpenAIFailureKeepsLastSnapshotAndTimestamp() async {
        let suite = "notchi-credit-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = OpenAICreditBalanceService(defaults: defaults, fetch: { 137.42 })
        service.enable()
        await service.refresh()
        let previous = service.snapshot
        let failing = OpenAICreditBalanceService(defaults: defaults, fetch: { throw OpenAICreditReadError.permission })
        await failing.refresh()
        XCTAssertEqual(failing.snapshot, previous)
        XCTAssertTrue(failing.isStale)
        XCTAssertEqual(failing.status, "Autorize o notchJP em Acessibilidade")
    }

    func testOpenRouterUsesPurchasedMinusUsedCredits() throws {
        let data = Data(#"{"data":{"total_credits":100.5,"total_usage":25.75}}"#.utf8)
        XCTAssertEqual(try OpenRouterCreditBalance.parse(data), 74.75)
    }

    func testOpenRouterRejectsInvalidFieldsInsteadOfShowingZero() {
        for payload in [#"{"data":{"total_credits":true,"total_usage":1}}"#,
                        #"{"data":{"total_credits":100}}"#,
                        #"{"data":{"total_credits":"100","total_usage":1}}"#,
                        #"{"data":{"total_credits":100,"total_usage":-1}}"#] {
            XCTAssertThrowsError(try OpenRouterCreditBalance.parse(Data(payload.utf8)))
        }
    }

    func testOpenRouterPermissionErrorExplainsRequiredKey() {
        XCTAssertEqual(OpenRouterCreditBalance.status(for: 403), "Use uma chave de gerenciamento")
        XCTAssertEqual(OpenRouterCreditBalance.status(for: 401), "Chave inválida ou expirada")
    }

    private actor CreditReadCounter {
        private(set) var calls = 0
        func read() -> Double { calls += 1; return 137.42 }
    }
}
