import Foundation
import Security

/// Token Google: refresh token disimpan di Keychain macOS, access token hanya di memori.
@MainActor
enum GoogleTokens {
    private static let service = "com.latiefahmad.zterm.google"
    private static let account = "refresh-token"
    private static var accessToken: String?
    private static var expiry = Date.distantPast

    static var hasRefreshToken: Bool { readRefreshToken() != nil }

    /// Login Google sudah mengizinkan drive.file (file Tim). Login lama hanya punya drive.appdata.
    static var hasDriveFileScope: Bool { UserDefaults.standard.bool(forKey: "google.driveFile") }
    static func markDriveFileScope(_ granted: Bool) { UserDefaults.standard.set(granted, forKey: "google.driveFile") }

    static func store(refreshToken: String?, accessToken: String?, expiresIn: Double?) {
        if let refreshToken { saveRefreshToken(refreshToken) }
        if let accessToken {
            self.accessToken = accessToken
            expiry = Date().addingTimeInterval((expiresIn ?? 3600) - 60)
        }
    }

    static func forget() {
        accessToken = nil
        expiry = .distantPast
        markDriveFileScope(false)
        SecItemDelete(query as CFDictionary)
    }

    /// Access token yang masih berlaku; diperbarui otomatis memakai refresh token.
    static func validAccessToken() async throws -> String {
        if let accessToken, Date() < expiry { return accessToken }
        guard let refresh = readRefreshToken() else { throw DriveError.notSignedIn }

        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = ["client_id": Config.googleClientID, "grant_type": "refresh_token", "refresh_token": refresh]
        req.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        struct R: Decodable { let access_token: String?; let expires_in: Double? }
        let r = try JSONDecoder().decode(R.self, from: data)
        guard let token = r.access_token else {
            if (response as? HTTPURLResponse)?.statusCode == 400 { forget() }
            throw DriveError.notSignedIn
        }
        store(refreshToken: nil, accessToken: token, expiresIn: r.expires_in)
        return token
    }

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func saveRefreshToken(_ token: String) {
        SecItemDelete(query as CFDictionary)
        var q = query
        q[kSecValueData as String] = Data(token.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    private static func readRefreshToken() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
}

enum DriveError: LocalizedError {
    case notSignedIn, http(Int, String)
    var errorDescription: String? {
        switch self {
        case .notSignedIn: L("Sesi Google berakhir. Masuk lagi untuk melanjutkan sync.")
        case .http(let code, let msg): L("Google Drive error {}: {}", code, msg)
        }
    }
}

/// Akses file `vault.zterm` di appDataFolder Google Drive (folder tersembunyi khusus app).
@MainActor
enum DriveClient {
    static let fileName = "vault.zterm"
    struct RemoteFile { let id: String; let modified: Date? }

    static func find() async throws -> RemoteFile? {
        var c = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        c.queryItems = [
            .init(name: "spaces", value: "appDataFolder"),
            .init(name: "q", value: "name = '\(fileName)' and trashed = false"),
            .init(name: "fields", value: "files(id,modifiedTime)"),
            .init(name: "orderBy", value: "modifiedTime desc"),
        ]
        let data = try await send(URLRequest(url: c.url!))
        struct List: Decodable { struct F: Decodable { let id: String; let modifiedTime: String? }; let files: [F] }
        guard let f = try JSONDecoder().decode(List.self, from: data).files.first else { return nil }
        return RemoteFile(id: f.id, modified: f.modifiedTime.flatMap { ISO8601DateFormatter.drive.date(from: $0) })
    }

    static func download(_ file: RemoteFile) async throws -> Data {
        try await send(URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/\(file.id)?alt=media")!))
    }

    /// Upload vault: ganti isi file lama, atau buat file baru di appDataFolder.
    static func upload(_ blob: Data, replacing file: RemoteFile?) async throws {
        if let file {
            var req = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files/\(file.id)?uploadType=media")!)
            req.httpMethod = "PATCH"
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            req.httpBody = blob
            _ = try await send(req)
            return
        }
        let boundary = "zterm-\(UUID().uuidString)"
        var body = Data()
        let meta = #"{"name":"\#(fileName)","parents":["appDataFolder"]}"#
        body.append("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n\(meta)\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\nContent-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(blob)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart")!)
        req.httpMethod = "POST"
        req.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        _ = try await send(req)
    }

    private static func send(_ request: URLRequest) async throws -> Data {
        var req = request
        req.setValue("Bearer \(try await GoogleTokens.validAccessToken())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            if code == 401 { GoogleTokens.forget(); throw DriveError.notSignedIn }
            let msg = String(data: data, encoding: .utf8).map { String($0.prefix(200)) } ?? ""
            throw DriveError.http(code, msg)
        }
        return data
    }
}

extension ISO8601DateFormatter {
    static let drive: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
