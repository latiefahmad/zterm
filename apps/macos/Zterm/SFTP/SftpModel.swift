import AppKit
import SwiftUI

/// Satu file / folder di panel lokal atau server.
struct FileItem: Identifiable, Hashable {
    var id: String { path }
    let name: String
    let path: String
    let isDir: Bool
    let size: UInt64
    let modified: Date?
    let permissions: UInt32
}

/// Satu transfer (upload / download) yang sedang berjalan atau selesai.
@MainActor
@Observable
final class Transfer: Identifiable {
    enum Kind { case upload, download }
    enum State: Equatable { case running, done, failed(String), cancelled }

    let id = UUID()
    let kind: Kind
    let name: String
    var done: UInt64 = 0
    var total: UInt64 = 0
    var currentFile = ""
    var state: State = .running
    let started = Date()

    var fraction: Double { total == 0 ? (state == .done ? 1 : 0) : min(1, Double(done) / Double(total)) }

    init(kind: Kind, name: String) {
        self.kind = kind
        self.name = name
    }
}

/// Jembatan progress dari core (thread Rust) ke UI (main thread), dengan throttle ±15 fps.
final class ProgressBridge: TransferProgress, @unchecked Sendable {
    private weak var transfer: Transfer?
    private let lock = NSLock()
    private var cancelled = false
    private var lastPush = Date.distantPast

    init(_ t: Transfer) { transfer = t }

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }

    func onProgress(done: UInt64, total: UInt64, currentFile: String) {
        let now = Date()
        lock.lock()
        let push = now.timeIntervalSince(lastPush) > 0.066 || done == total
        if push { lastPush = now }
        lock.unlock()
        guard push else { return }
        Task { @MainActor [weak transfer] in
            transfer?.done = done
            transfer?.total = total
            transfer?.currentFile = currentFile
        }
    }

    func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

/// Konflik host key: fingerprint lama vs baru, untuk dialog "Ganti key".
struct HostKeyConflict: Identifiable {
    let id = UUID()
    let host: String
    let port: UInt16
    let oldFingerprint: String
    let newFingerprint: String
    let oldKeyType: String
    let newKeyType: String

    var address: String { port == 22 ? host : "\(host):\(port)" }
}

@MainActor
@Observable
final class SftpModel {
    enum Status: Equatable { case idle, connecting, connected, failed(String) }

    var host: Host?
    var status: Status = .idle
    /// Diisi saat koneksi ditolak karena host key berubah; ditampilkan sebagai sheet.
    var hostKeyConflict: HostKeyConflict?
    var remotePath = ""
    var remoteItems: [FileItem] = []
    var remoteLoading = false
    var localPath = FileManager.default.homeDirectoryForCurrentUser.path
    var localItems: [FileItem] = []
    var showHidden = false
    var transfers: [Transfer] = []
    var error: String?
    /// Pesan sukses singkat (mis. "tersimpan ke server").
    var notice: String?
    /// File yang sedang dibuka di editor teks bawaan.
    var editor: RemoteEditorDoc?
    /// File yang dibuka di aplikasi lain dan diawasi untuk diunggah balik.
    var watched: [WatchedFile] = []

    /// Item yang sedang di-drag di dalam app (untuk drop antarpanel / banyak file sekaligus).
    @ObservationIgnored var dragging: (remote: Bool, paths: [String])?
    /// Pilihan di panel server (dipakai saat banyak file di-drag ke panel Mac).
    @ObservationIgnored var remoteSelection: Set<String> = []

    @ObservationIgnored private var client: SftpClient?
    @ObservationIgnored private var bridges: [UUID: ProgressBridge] = [:]
    @ObservationIgnored private var watchTimer: Timer?
    @ObservationIgnored private var lastKey: SshKey?

    init() { reloadLocal() }

    // MARK: Koneksi

    func connect(_ host: Host, key: SshKey?) async {
        await disconnect()
        self.host = host
        lastKey = key
        withAnimation(.zterm) { status = .connecting }
        let target = SshTarget(
            hostname: host.hostname, port: host.port, username: host.username,
            password: host.auth == .password ? host.password : nil,
            privateKey: host.auth == .key ? key?.privateKey : nil,
            passphrase: host.auth == .key ? key?.passphrase : nil,
            useAgent: true, proxy: host.proxy)
        do {
            let c = try await SftpClient.connect(target: target)
            client = c
            let home = try await c.home()
            withAnimation(.zterm) { status = .connected }
            await openRemote(home)
        } catch {
            if let core = error as? CoreError,
               case let .HostKeyChanged(host, port, oldFingerprint, newFingerprint, oldKeyType, newKeyType) = core {
                hostKeyConflict = HostKeyConflict(host: host, port: port, oldFingerprint: oldFingerprint,
                                                  newFingerprint: newFingerprint, oldKeyType: oldKeyType, newKeyType: newKeyType)
            }
            withAnimation(.zterm) { status = .failed(error.ztermMessage) }
        }
    }

    /// Hapus semua key host ini dari known_hosts, lalu coba sambung lagi.
    func replaceHostKey(_ conflict: HostKeyConflict) async {
        guard let host else { return }
        do {
            let removed = try forgetKnownHost(host: conflict.host, port: conflict.port)
            showNotice(L("{} key dihapus", Int(removed)))
        } catch {
            flashError(error)
            return
        }
        hostKeyConflict = nil
        await connect(host, key: lastKey)
    }

    func disconnect() async {
        bridges.values.forEach { $0.cancel() }
        editor = nil
        watched.forEach { try? FileManager.default.removeItem(at: $0.localURL.deletingLastPathComponent()) }
        watched = []
        watchTimer?.invalidate()
        watchTimer = nil
        if let c = client { await c.close() }
        client = nil
        remoteItems = []
        remotePath = ""
        hostKeyConflict = nil
        status = .idle
    }

    // MARK: Server

    func openRemote(_ path: String) async {
        guard let client else { return }
        remoteLoading = true
        defer { remoteLoading = false }
        do {
            let entries = try await client.list(path: path)
            withAnimation(.ztermSnappy) {
                remotePath = path
                remoteItems = entries
                    .filter { showHidden || !$0.name.hasPrefix(".") }
                    .map { FileItem(name: $0.name, path: $0.path, isDir: $0.isDir, size: $0.size,
                                    modified: $0.modified > 0 ? Date(timeIntervalSince1970: TimeInterval($0.modified)) : nil,
                                    permissions: $0.permissions) }
            }
        } catch {
            flashError(error)
        }
    }

    func refreshRemote() async { await openRemote(remotePath) }

    func remoteUp() async {
        guard remotePath != "/" else { return }
        let parent = (remotePath as NSString).deletingLastPathComponent
        await openRemote(parent.isEmpty ? "/" : parent)
    }

    func remoteHome() async {
        guard let client, let h = try? await client.home() else { return }
        await openRemote(h)
    }

    func mkdirRemote(_ name: String) async {
        guard let client, !name.isEmpty else { return }
        do { try await client.mkdir(path: join(remotePath, name)); await refreshRemote() } catch { flashError(error) }
    }

    func renameRemote(_ item: FileItem, to name: String) async {
        guard let client, !name.isEmpty, name != item.name else { return }
        do { try await client.rename(from: item.path, to: join(remotePath, name)); await refreshRemote() } catch { flashError(error) }
    }

    func chmodRemote(_ item: FileItem, mode: UInt32) async {
        guard let client else { return }
        do { try await client.chmod(path: item.path, mode: mode); await refreshRemote() } catch { flashError(error) }
    }

    /// Pindahkan item server ke folder server lain (drag di dalam panel server).
    func moveRemote(_ paths: [String], into dir: String) async {
        guard let client, !paths.isEmpty else { return }
        for p in paths {
            do { try await client.rename(from: p, to: join(dir, (p as NSString).lastPathComponent)) } catch { flashError(error) }
        }
        await refreshRemote()
    }

    func deleteRemote(_ items: [FileItem]) async {
        guard let client else { return }
        for i in items {
            do { try await client.remove(path: i.path) } catch { flashError(error) }
        }
        await refreshRemote()
    }

    // MARK: Lokal

    func reloadLocal() {
        let url = URL(fileURLWithPath: localPath)
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys,
                                                                   options: showHidden ? [] : [.skipsHiddenFiles])) ?? []
        let items = urls.compactMap { u -> FileItem? in
            let v = try? u.resourceValues(forKeys: Set(keys))
            let perms = (try? FileManager.default.attributesOfItem(atPath: u.path)[.posixPermissions] as? NSNumber)?.uint32Value ?? 0
            return FileItem(name: u.lastPathComponent, path: u.path, isDir: v?.isDirectory ?? false,
                            size: UInt64(v?.fileSize ?? 0), modified: v?.contentModificationDate, permissions: perms)
        }
        withAnimation(.ztermSnappy) {
            localItems = items.sorted { a, b in a.isDir != b.isDir ? a.isDir : a.name.localizedStandardCompare(b.name) == .orderedAscending }
        }
    }

    func openLocal(_ path: String) {
        localPath = path
        reloadLocal()
    }

    func localUp() {
        let parent = (localPath as NSString).deletingLastPathComponent
        openLocal(parent.isEmpty ? "/" : parent)
    }

    // MARK: Transfer

    func upload(_ paths: [String]) { upload(paths, into: remotePath) }

    /// Upload ke folder server tertentu (mis. saat file dilepas di atas sebuah folder).
    func upload(_ paths: [String], into dir: String) {
        guard let client else { return }
        for p in paths {
            let t = Transfer(kind: .upload, name: (p as NSString).lastPathComponent)
            start(t) { bridge in try await client.upload(local: p, remoteDir: dir, progress: bridge) } onDone: { [weak self] in
                if self?.remotePath == dir { await self?.refreshRemote() }
            }
        }
    }

    func download(_ items: [FileItem]) { download(items, into: localPath) }

    func download(_ items: [FileItem], into dir: String) {
        guard let client else { return }
        for i in items {
            let t = Transfer(kind: .download, name: i.name)
            start(t) { bridge in try await client.download(remote: i.path, localDir: dir, progress: bridge) } onDone: { [weak self] in
                if self?.localPath == dir { self?.reloadLocal() }
            }
        }
    }

    func cancel(_ t: Transfer) { bridges[t.id]?.cancel() }

    /// Dipanggil saat file server di-drag ke Finder: download ke folder sementara, kembalikan lokasinya.
    func exportForDrag(_ item: FileItem) async throws -> URL {
        guard let client else { throw CoreError.NotFound }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zterm-drag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let t = Transfer(kind: .download, name: item.name)
        let bridge = ProgressBridge(t)
        bridges[t.id] = bridge
        withAnimation(.ztermSnappy) { transfers.insert(t, at: 0) }
        defer { bridges[t.id] = nil }
        do {
            try await client.download(remote: item.path, localDir: dir.path, progress: bridge)
            withAnimation(.zterm) { t.state = .done; if t.total > 0 { t.done = t.total } }
        } catch {
            withAnimation(.zterm) { t.state = .failed(Lmsg(error.localizedDescription)) }
            throw error
        }
        return dir.appendingPathComponent(item.name)
    }

    /// File dari Finder dilepas di panel Mac: salin ke folder yang sedang dibuka.
    func copyIntoLocal(_ urls: [URL]) {
        for u in urls where u.deletingLastPathComponent().path != localPath {
            var dest = URL(fileURLWithPath: localPath).appendingPathComponent(u.lastPathComponent)
            var n = 1
            while FileManager.default.fileExists(atPath: dest.path) {
                dest = URL(fileURLWithPath: localPath).appendingPathComponent("\(u.deletingPathExtension().lastPathComponent) (\(n))" + (u.pathExtension.isEmpty ? "" : ".\(u.pathExtension)"))
                n += 1
            }
            try? FileManager.default.copyItem(at: u, to: dest)
        }
        reloadLocal()
    }

    func clearFinished() {
        withAnimation(.zterm) { transfers.removeAll { $0.state != .running } }
    }

    private func start(_ t: Transfer, _ work: @escaping (ProgressBridge) async throws -> Void, onDone: @escaping () async -> Void) {
        let bridge = ProgressBridge(t)
        bridges[t.id] = bridge
        withAnimation(.ztermSnappy) { transfers.insert(t, at: 0) }
        Task {
            do {
                try await work(bridge)
                withAnimation(.zterm) { t.state = .done; if t.total > 0 { t.done = t.total } }
            } catch CoreError.Cancelled {
                withAnimation(.zterm) { t.state = .cancelled }
            } catch {
                withAnimation(.zterm) { t.state = .failed(Lmsg(error.localizedDescription)) }
            }
            bridges[t.id] = nil
            await onDone()
        }
    }

    // MARK: Editor bawaan

    /// Buka file server di editor teks bawaan.
    func openEditor(_ item: FileItem) async {
        guard let client else { return }
        if item.size > RemoteFiles.editorLimit {
            flashError(CoreError.Io(msg: L("{} terlalu besar untuk editor (maks 5 MB) — pakai “Buka dengan”", item.name)))
            return
        }
        do {
            let data = try await client.readFile(path: item.path, maxBytes: RemoteFiles.editorLimit)
            guard let text = String(data: data, encoding: .utf8) else {
                flashError(CoreError.Io(msg: L("{} bukan file teks UTF-8 — pakai “Buka dengan”", item.name)))
                return
            }
            let st = try? await client.stat(path: item.path)
            withAnimation(.zterm) { editor = RemoteEditorDoc(path: item.path, name: item.name, text: text, modified: st?.modified ?? 0) }
        } catch {
            flashError(error)
        }
    }

    /// Simpan isi editor ke server. Mengembalikan `true` jika berhasil.
    @discardableResult
    func saveEditor(_ doc: RemoteEditorDoc, force: Bool = false) async -> Bool {
        guard let client, !doc.saving else { return false }
        doc.saving = true
        doc.error = nil
        defer { doc.saving = false }
        do {
            if !force, let st = try? await client.stat(path: doc.path), doc.remoteModified != 0, st.modified != doc.remoteModified {
                doc.conflict = true
                return false
            }
            let snapshot = doc.text
            try await client.writeFile(path: doc.path, data: Data(snapshot.utf8))
            doc.original = snapshot
            doc.remoteModified = (try? await client.stat(path: doc.path))?.modified ?? doc.remoteModified
            showNotice(L("✓ {} tersimpan ke server", doc.name))
            await refreshRemote()
            return true
        } catch {
            doc.error = error.ztermMessage
            return false
        }
    }

    // MARK: Buka dengan aplikasi lain

    /// Unduh ke folder sementara, buka di aplikasi pilihan (atau bawaan), lalu awasi untuk diunggah balik.
    func openWith(_ item: FileItem, app: URL? = nil) async {
        guard let client else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zterm-open/\(UUID().uuidString)", isDirectory: true)
        let local = dir.appendingPathComponent(item.name)
        do {
            try await client.downloadFileTo(remote: item.path, localPath: local.path)
        } catch {
            flashError(error)
            return
        }
        let appURL = app ?? NSWorkspace.shared.urlForApplication(toOpen: local)
        let w = WatchedFile(remotePath: item.path, localURL: local, appName: appURL.map(RemoteFiles.appName) ?? L("aplikasi bawaan"))
        withAnimation(.zterm) {
            watched.removeAll { $0.remotePath == item.path }
            watched.append(w)
        }
        startWatchTimer()
        if let appURL {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.open([local], withApplicationAt: appURL, configuration: cfg) { _, err in
                if let err { Task { @MainActor in self.flashError(err) } }
            }
        } else {
            NSWorkspace.shared.open(local)
        }
    }

    /// Pilih aplikasi lain lewat panel Finder, lalu buka.
    func chooseAppAndOpen(_ item: FileItem) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = L("Buka")
        panel.message = L("Pilih aplikasi untuk membuka {}", item.name)
        guard panel.runModal() == .OK, let app = panel.url else { return }
        Task { await openWith(item, app: app) }
    }

    func stopWatching(_ w: WatchedFile) {
        withAnimation(.zterm) { watched.removeAll { $0.id == w.id } }
        try? FileManager.default.removeItem(at: w.localURL.deletingLastPathComponent())
        if watched.isEmpty { watchTimer?.invalidate(); watchTimer = nil }
    }

    private func startWatchTimer() {
        guard watchTimer == nil else { return }
        watchTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkWatched() }
        }
    }

    /// Editor seperti VS Code menyimpan dengan mengganti file — cukup bandingkan waktu ubah.
    private func checkWatched() async {
        guard let client else { return }
        for w in watched where !w.uploading {
            guard let m = (try? w.localURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  m != w.lastModified else { continue }
            w.lastModified = m
            w.uploading = true
            do {
                try await client.uploadFileTo(localPath: w.localURL.path, remote: w.remotePath)
                withAnimation(.zterm) { w.lastUpload = Date() }
                showNotice(L("✓ {} tersimpan ke server", w.localURL.lastPathComponent))
                if (w.remotePath as NSString).deletingLastPathComponent == remotePath { await refreshRemote() }
            } catch {
                flashError(error)
            }
            w.uploading = false
        }
    }

    private func showNotice(_ msg: String) {
        withAnimation(.zterm) { notice = msg }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            if self?.notice == msg { withAnimation(.zterm) { self?.notice = nil } }
        }
    }

    private func flashError(_ e: Error) {
        withAnimation(.zterm) { error = e.ztermMessage }
        let msg = error
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.error == msg { withAnimation(.zterm) { self?.error = nil } }
        }
    }

    private func join(_ dir: String, _ name: String) -> String {
        dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }
}

extension UInt64 {
    var byteString: String { ByteCountFormatter.string(fromByteCount: Int64(self), countStyle: .file) }
}

/// "rwxr-xr-x" dari bit izin.
func permissionString(_ mode: UInt32, isDir: Bool) -> String {
    let chars: [(UInt32, Character)] = [(0o400, "r"), (0o200, "w"), (0o100, "x"), (0o040, "r"), (0o020, "w"), (0o010, "x"),
                                        (0o004, "r"), (0o002, "w"), (0o001, "x")]
    return (isDir ? "d" : "-") + String(chars.map { mode & $0.0 != 0 ? $0.1 : "-" })
}
