import Foundation
import Security
import LocalAuthentication

/// Background work must never open an authentication dialog. Only an explicit user action may allow it.
nonisolated enum KeychainAccessPolicy {
    static func query(_ query: [String: Any], allowInteraction: Bool = false) -> [String: Any] {
        var query = query
        query.removeValue(forKey: kSecUseAuthenticationUI as String)
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        query[kSecUseAuthenticationContext as String] = context
        return query
    }
}
