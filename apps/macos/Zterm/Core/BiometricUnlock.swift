import Foundation
import LocalAuthentication
import Security

/// Buka vault dengan Touch ID.
///
/// Kunci vault disimpan di Keychain macOS, dan hanya dibaca setelah Touch ID / password Mac berhasil.
/// Catatan: karena app ditandatangani ad-hoc (tanpa Apple Developer), kita memakai keychain login biasa
/// + verifikasi LocalAuthentication, bukan access control biometrik di Secure Enclave.
enum BiometricUnlock {
    private static let service = "com.latiefahmad.zterm.vault"
    private static let account = "vault-key"

    static var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) && hasStoredKey
    }

    static var hasStoredKey: Bool {
        var q = baseQuery
        q[kSecReturnData as String] = false
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    static func store(key: Data) {
        SecItemDelete(baseQuery as CFDictionary)
        var q = baseQuery
        q[kSecValueData as String] = key
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    static func forget() { SecItemDelete(baseQuery as CFDictionary) }

    static func retrieve() async throws -> Data {
        let ctx = LAContext()
        ctx.localizedFallbackTitle = L("Pakai master password")
        try await ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                     localizedReason: L("membuka vault Zterm"))
        var q = baseQuery
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else {
            throw NSError(domain: "Zterm", code: 1, userInfo: [NSLocalizedDescriptionKey: L("Kunci Touch ID tidak ditemukan")])
        }
        return data
    }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}
