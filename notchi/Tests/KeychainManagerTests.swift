import Foundation
import XCTest
import Security
import LocalAuthentication
@testable import notchi

final class KeychainManagerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        KeychainManager._resetCredentialResolutionStateForTesting()
    }

    override func tearDown() {
        KeychainManager._resetCredentialResolutionStateForTesting()
        super.tearDown()
    }

    func testDecodeClaudeOAuthCredentialsWithScopesAndExpiry() throws {
        let expiresAt = "2099-01-01T01:00:00Z"
        let data = makeCredentialPayload(
            accessToken: "token-123",
            expiresAt: expiresAt,
            scopes: ["user:profile", "openid"]
        )

        let credentials = try XCTUnwrap(KeychainManager.decodeClaudeOAuthCredentials(from: data))

        XCTAssertEqual(credentials.accessToken, "token-123")
        XCTAssertEqual(credentials.scopes, Set(["openid", "user:profile"]))
        XCTAssertEqual(
            credentials.expiresAt,
            ISO8601DateFormatter().date(from: expiresAt)
        )
    }

    func testDecodeClaudeOAuthCredentialsAllowsMissingUserProfileScope() throws {
        let data = makeCredentialPayload(
            accessToken: "token-123",
            scopes: ["openid"]
        )

        let credentials = try XCTUnwrap(KeychainManager.decodeClaudeOAuthCredentials(from: data))

        XCTAssertEqual(credentials.scopes, Set(["openid"]))
        XCTAssertFalse(credentials.scopes.contains("user:profile"))
    }

    func testDecodeClaudeOAuthCredentialsParsesExpiredEpochMetadata() throws {
        let data = makeCredentialPayload(
            accessToken: "token-123",
            expiresAt: 1
        )

        let credentials = try XCTUnwrap(KeychainManager.decodeClaudeOAuthCredentials(from: data))

        XCTAssertEqual(credentials.expiresAt, Date(timeIntervalSince1970: 1))
    }

    func testDecodeClaudeOAuthCredentialsAllowsAbsentOptionalMetadata() throws {
        let data = makeCredentialPayload(accessToken: "token-123")

        let credentials = try XCTUnwrap(KeychainManager.decodeClaudeOAuthCredentials(from: data))

        XCTAssertEqual(credentials.accessToken, "token-123")
        XCTAssertNil(credentials.expiresAt)
        XCTAssertTrue(credentials.scopes.isEmpty)
    }

    func testSilentCredentialReadNeverStartsSecurityCLIAndCachesFrameworkResult() throws {
        let json = makeCredentialJSON(accessToken: "fake-token")
        var frameworkCalls = 0
        KeychainManager._setSecurityCLIReadOverrideForTesting {
            XCTFail("Background reads must never launch security, which can show an ACL dialog")
            return nil
        }
        KeychainManager._setSecurityFrameworkReadOverrideForTesting { interactive in
            XCTAssertFalse(interactive)
            frameworkCalls += 1
            return json
        }
        XCTAssertEqual(KeychainManager.getOAuthCredentials(allowInteraction: false)?.accessToken, "fake-token")
        XCTAssertEqual(KeychainManager.getOAuthCredentials(allowInteraction: false)?.accessToken, "fake-token")
        XCTAssertEqual(frameworkCalls, 1)
    }

    func testDeniedBackgroundReadDoesNotRetryThroughInteractiveCLI() {
        KeychainManager._setSecurityCLIReadOverrideForTesting { XCTFail("Must not attempt CLI recovery"); return nil }
        KeychainManager._setSecurityFrameworkReadOverrideForTesting { interactive in
            XCTAssertFalse(interactive); return nil
        }
        XCTAssertNil(KeychainManager.getOAuthCredentials(allowInteraction: false))
        XCTAssertNil(KeychainManager.getOAuthCredentials(allowInteraction: false))
    }

    func testAuthenticationPolicySuppressesUIUnlessExplicitlyAllowed() throws {
        let query: [String: Any] = [kSecAttrService as String: "fixture-service",
                                    kSecUseAuthenticationUI as String: kSecUseAuthenticationUIAllow]
        let silent = KeychainAccessPolicy.query(query)
        XCTAssertTrue(try XCTUnwrap(silent[kSecUseAuthenticationContext as String] as? LAContext).interactionNotAllowed)
        XCTAssertNil(silent[kSecUseAuthenticationUI as String])
        XCTAssertEqual(silent[kSecAttrService as String] as? String, "fixture-service")
        let explicit = KeychainAccessPolicy.query(query, allowInteraction: true)
        XCTAssertFalse(try XCTUnwrap(explicit[kSecUseAuthenticationContext as String] as? LAContext).interactionNotAllowed)
    }

    func testGetOAuthCredentialsPassesInteractionPolicyToSecurityFrameworkFallback() throws {
        var seenAllowInteraction: [Bool] = []

        KeychainManager._setSecurityCLIReadOverrideForTesting {
            nil
        }
        KeychainManager._setSecurityFrameworkReadOverrideForTesting { allowInteraction in
            seenAllowInteraction.append(allowInteraction)
            return self.makeCredentialJSON(accessToken: allowInteraction ? "interactive" : "silent")
        }

        let interactive = try XCTUnwrap(KeychainManager.getOAuthCredentials(allowInteraction: true))

        KeychainManager._resetCredentialResolutionStateForTesting()
        KeychainManager._setSecurityCLIReadOverrideForTesting {
            nil
        }
        KeychainManager._setSecurityFrameworkReadOverrideForTesting { allowInteraction in
            seenAllowInteraction.append(allowInteraction)
            return self.makeCredentialJSON(accessToken: allowInteraction ? "interactive" : "silent")
        }

        let silent = try XCTUnwrap(KeychainManager.getOAuthCredentials(allowInteraction: false))

        XCTAssertEqual(interactive.accessToken, "interactive")
        XCTAssertEqual(silent.accessToken, "silent")
        XCTAssertEqual(seenAllowInteraction, [true, false])
    }

    private func makeCredentialPayload(
        accessToken: String,
        expiresAt: Any? = nil,
        scopes: [String]? = nil
    ) -> Data {
        var oauth: [String: Any] = [
            "accessToken": accessToken,
        ]
        if let expiresAt {
            oauth["expiresAt"] = expiresAt
        }
        if let scopes {
            oauth["scopes"] = scopes
        }

        let payload: [String: Any] = [
            "claudeAiOauth": oauth,
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    private func makeCredentialJSON(
        accessToken: String,
        expiresAt: Any? = nil,
        scopes: [String]? = nil
    ) -> [String: Any] {
        let data = makeCredentialPayload(accessToken: accessToken, expiresAt: expiresAt, scopes: scopes)
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
}
