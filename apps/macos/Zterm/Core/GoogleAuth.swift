import AuthenticationServices
import CryptoKit
import Foundation

/// Login Google (OAuth 2.0 + PKCE) lewat ASWebAuthenticationSession.
/// Scope: email + drive.appdata (folder tersembunyi khusus app untuk sync vault).
@MainActor
final class GoogleAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    struct Result { let email: String; let name: String?; let picture: String?; let refreshToken: String? }

    enum AuthError: LocalizedError {
        case notConfigured, cancelled, failed(String)
        var errorDescription: String? {
            switch self {
            case .notConfigured:
                L("Login Google belum dikonfigurasi. Isi Config.googleClientID dengan OAuth Client ID dari Google Cloud Console.")
            case .cancelled: L("Login dibatalkan")
            case .failed(let m): m
            }
        }
    }

    private var session: ASWebAuthenticationSession?

    static var isConfigured: Bool { !Config.googleClientID.isEmpty }

    func signIn() async throws -> Result {
        let clientID = Config.googleClientID
        guard !clientID.isEmpty else { throw AuthError.notConfigured }

        // Skema redirect untuk client tipe iOS: com.googleusercontent.apps.<id>
        let scheme = clientID.components(separatedBy: ".").reversed().joined(separator: ".")
        let redirect = "\(scheme):/oauth2redirect"
        let verifier = Self.randomString()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL

        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: "openid email profile https://www.googleapis.com/auth/drive.appdata https://www.googleapis.com/auth/drive.file"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]

        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: c.url!, callbackURLScheme: scheme) { url, error in
                if let url { cont.resume(returning: url) }
                else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin { cont.resume(throwing: AuthError.cancelled) }
                else { cont.resume(throwing: AuthError.failed(error?.localizedDescription ?? L("Login gagal"))) }
            }
            s.presentationContextProvider = self
            s.prefersEphemeralWebBrowserSession = false
            session = s
            s.start()
        }

        guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value
        else { throw AuthError.failed(L("Kode otorisasi tidak diterima")) }

        // Tukar kode dengan token
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = ["code": code, "client_id": clientID, "redirect_uri": redirect,
                    "grant_type": "authorization_code", "code_verifier": verifier]
        req.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: req)
        let token = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard let idToken = token.id_token, let claims = Self.claims(fromIDToken: idToken),
              let email = claims["email"] as? String else {
            throw AuthError.failed(L("Tidak bisa membaca email akun Google"))
        }
        GoogleTokens.store(refreshToken: token.refresh_token, accessToken: token.access_token,
                           expiresIn: token.expires_in)
        GoogleTokens.markDriveFileScope(token.scope?.contains("auth/drive.file") == true)
        return Result(email: email, name: claims["name"] as? String, picture: claims["picture"] as? String,
                      refreshToken: token.refresh_token)
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { NSApp.keyWindow ?? ASPresentationAnchor() }
    }

    private struct TokenResponse: Decodable {
        let id_token: String?
        let refresh_token: String?
        let access_token: String?
        let expires_in: Double?
        let scope: String?
    }

    /// Isi (claims) ID token Google: email, name, picture.
    private static func claims(fromIDToken jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    private static func randomString() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URL
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
