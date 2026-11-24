import AppKit
import CryptoKit
import Foundation

/// Versi app & pengecekan rilis baru di GitHub Releases.
enum AppVersion {
    static var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0" }
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0" }

    /// Bandingkan versi semantik ("0.1.10" > "0.1.9"). Awalan "v" diabaikan.
    static func isNewer(_ remote: String, than local: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let a = parts(remote), b = parts(local)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

struct AvailableUpdate: Equatable, Sendable {
    let version: String
    let notes: String
    let page: URL
    let download: URL?
    let digest: String?
    let size: Int64
}

enum UpdateChecker {
    private static let api = URL(string: "https://api.github.com/repos/latiefahmad/zterm/releases/latest")!

    static func check() async throws -> AvailableUpdate? {
        var req = URLRequest(url: api)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil } // belum ada rilis
        struct Release: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: URL
                let digest: String?
                let size: Int64?
            }
            let tag_name: String; let html_url: URL; let body: String?; let assets: [Asset]
        }
        let r = try JSONDecoder().decode(Release.self, from: data)
        guard AppVersion.isNewer(r.tag_name, than: AppVersion.current) else { return nil }
        let dmg = r.assets.first { $0.name.lowercased().contains("macos") && $0.name.lowercased().hasSuffix(".dmg") }
            ?? r.assets.first { $0.name.lowercased().hasSuffix(".dmg") }
        return AvailableUpdate(version: r.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV")),
                               notes: r.body ?? "", page: r.html_url,
                               download: dmg?.browser_download_url, digest: dmg?.digest, size: dmg?.size ?? 0)
    }
}

/// Unduhan DMG dengan progress. Delegate disimpan sampai selesai agar URLSession tidak kehilangan target.
private final class UpdateDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<URL, Error>?
    private var destination: URL?
    private var progress: ((Double) -> Void)?
    private var session: URLSession?
    private var finished = false

    func download(from url: URL, to destination: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            self.continuation = cont
            self.destination = destination
            self.progress = progress
            let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
            self.session = session
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let value = min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        DispatchQueue.main.async { [weak self] in self?.progress?(value) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(.failure(UpdateInstaller.InstallError.http(http.statusCode)))
            return
        }
        guard let destination else {
            finish(.failure(UpdateInstaller.InstallError.badBundle))
            return
        }
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
        } else if let destination, FileManager.default.fileExists(atPath: destination.path) {
            finish(.success(destination))
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard !finished else { return }
        finished = true
        session?.finishTasksAndInvalidate()
        session = nil
        let cont = continuation
        continuation = nil
        switch result {
        case .success(let url): cont?.resume(returning: url)
        case .failure(let error): cont?.resume(throwing: error)
        }
    }
}

enum UpdateInstaller {
    enum InstallError: LocalizedError {
        case missingAsset
        case checksum
        case notWritable
        case badBundle
        case http(Int)
        case tool

        var errorDescription: String? {
            switch self {
            case .missingAsset: return L("Pembaruan tidak tersedia untuk arsitektur ini")
            case .checksum: return L("Checksum pembaruan tidak cocok")
            case .notWritable: return L("Zterm tidak bisa mengganti dirinya di lokasi ini. Pindahkan Zterm ke folder Applications lalu coba lagi.")
            case .badBundle: return L("Paket pembaruan tidak valid")
            case .http(let code): return L("Gagal mengunduh pembaruan: HTTP {}", code)
            case .tool: return L("Paket pembaruan tidak valid")
            }
        }
    }

    struct InstallPlan: Sendable {
        let target: URL
        let staged: URL
        let work: URL
    }

    /// Unduh DMG. Checksum diperiksa terpisah supaya status "memverifikasi" sempat tampil.
    static func download(_ update: AvailableUpdate, progress: @escaping (Double) -> Void) async throws -> URL {
        guard let url = update.download else { throw InstallError.missingAsset }
        let fm = FileManager.default
        let dir = Config.appSupport.appendingPathComponent("updates", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if let old = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for f in old where f.pathExtension.lowercased() == "dmg" { try? fm.removeItem(at: f) }
        }
        let dest = dir.appendingPathComponent(url.lastPathComponent)
        try? fm.removeItem(at: dest)
        let downloader = UpdateDownloader()
        return try await downloader.download(from: url, to: dest, progress: progress)
    }

    static func verify(_ update: AvailableUpdate, dmg: URL) throws {
        guard let digest = update.digest, digest.lowercased().hasPrefix("sha256:") else { return }
        let expected = String(digest.dropFirst(7)).lowercased()
        let actual = try sha256(of: dmg)
        guard actual == expected else {
            try? FileManager.default.removeItem(at: dmg)
            throw InstallError.checksum
        }
    }

    /// Pasang DMG sementara, ambil Zterm.app, dan siapkan bundle pengganti.
    static func prepare(dmg: URL, version: String) throws -> InstallPlan {
        let fm = FileManager.default
        let target = Bundle.main.bundleURL
        guard target.pathExtension == "app" else { throw InstallError.badBundle }
        if target.path.contains("/AppTranslocation/") { throw InstallError.notWritable }
        guard fm.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            throw InstallError.notWritable
        }

        let work = Config.appSupport
            .appendingPathComponent("updates", isDirectory: true)
            .appendingPathComponent("stage-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let mount = work.appendingPathComponent("mnt", isDirectory: true)
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)

        var attached = false
        var keep = false
        defer {
            if attached { try? run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"]) }
            try? fm.removeItem(at: mount)
            try? fm.removeItem(at: dmg)
            if !keep { try? fm.removeItem(at: work) }
        }

        try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-mountpoint", mount.path, dmg.path])
        attached = true

        let items = try fm.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)
        guard let source = items.first(where: { $0.pathExtension.lowercased() == "app" }) else {
            throw InstallError.badBundle
        }
        let infoURL = source.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let plist = object as? [String: Any],
              let stagedVersion = plist["CFBundleShortVersionString"] as? String,
              stagedVersion == version else {
            throw InstallError.badBundle
        }

        let staged = work.appendingPathComponent(target.lastPathComponent)
        try run("/usr/bin/ditto", [source.path, staged.path])
        keep = true
        return InstallPlan(target: target, staged: staged, work: work)
    }

    /// Helper menunggu Zterm keluar, mengganti bundle, lalu membuka Zterm lagi.
    static func launch(_ plan: InstallPlan) throws {
        let script = plan.work.appendingPathComponent("update.sh")
        let text = """
        #!/bin/bash
        set -u
        TARGET="$1"
        STAGE="$2"
        PID="$3"
        WORK="$4"
        while kill -0 "$PID" 2>/dev/null; do /bin/sleep 0.3; done
        OLD="${TARGET}.zterm-old-$$"
        if ! /bin/mv "$TARGET" "$OLD"; then
          /usr/bin/open "$TARGET"
          exit 1
        fi
        if /usr/bin/ditto "$STAGE" "$TARGET"; then
          /usr/bin/xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true
          /bin/rm -rf "$OLD"
          /usr/bin/open "$TARGET"
        else
          /bin/rm -rf "$TARGET"
          /bin/mv "$OLD" "$TARGET"
          /usr/bin/open "$TARGET"
        fi
        /bin/rm -rf "$STAGE" "$WORK"
        /bin/rm -f "$0"
        """
        try text.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path, plan.target.path, plan.staged.path,
                       String(ProcessInfo.processInfo.processIdentifier), plan.work.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
    }

    private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw InstallError.tool }
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1 << 20) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Konfirmasi sebelum menutup app dan memasang pembaruan.
@MainActor
func confirmAndInstallUpdate(_ model: AppModel, version: String) {
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = L("Update Zterm ke {}?", version)
    alert.informativeText = L("Zterm akan mengunduh pembaruan, menutup aplikasi, lalu membuka ulang.")
    alert.addButton(withTitle: L("Update sekarang"))
    alert.addButton(withTitle: L("Nanti"))
    if alert.runModal() == .alertFirstButtonReturn {
        Task { await model.installUpdate() }
    }
}
