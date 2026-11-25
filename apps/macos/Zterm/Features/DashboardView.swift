import SwiftUI

// MARK: - Model

/// Satu server di Dashboard: koneksi SSH (ServerMonitor) yang mengambil sampel tiap 5 detik
/// dan menyambung ulang sendiri saat server tidak bisa dihubungi.
@MainActor
@Observable
final class ServerTile: Identifiable {
    enum State: Equatable { case connecting, online, offline(String) }
    enum Level: Int, Comparable {
        case ok, warn, critical
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    var host: Host
    var id: String { host.id }
    var state: State = .connecting
    var info: ServerInfo?
    var sample: ServerSample?
    /// Riwayat CPU untuk grafik kecil (30 sampel ≈ 2,5 menit).
    var cpu: [Double] = []
    var rx = 0.0
    var tx = 0.0

    @ObservationIgnored private var monitor: ServerMonitor?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var prev: (ServerSample, Date)?
    /// Dipanggil saat ada kejadian yang layak dinotifikasi: (judul, isi, kunci).
    @ObservationIgnored var onAlert: ((String, String, String) -> Void)?
    @ObservationIgnored private var wasOnline = false
    /// Metrik yang sedang di atas 90% (sudah dinotifikasi; dilepas lagi di bawah 85%).
    @ObservationIgnored private var alerting: Set<String> = []

    static let interval: Duration = .seconds(5)
    static let retry: Duration = .seconds(20)

    init(host: Host) { self.host = host }

    var running: Bool { task != nil }

    func start(target: SshTarget?) {
        guard task == nil else { return }
        if case .offline = state { state = .connecting }
        task = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    guard let target else { throw CoreError.NotFound }
                    let m = try await ServerMonitor.connect(target: target)
                    guard let self, !Task.isCancelled else { await m.close(); return }
                    self.monitor = m
                    if self.info == nil { self.info = try? await m.info() }
                    while !Task.isCancelled {
                        let s = try await m.sample()
                        self.add(s)
                        try await Task.sleep(for: Self.interval)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard let self, !Task.isCancelled else { return }
                    let m = self.monitor
                    self.monitor = nil
                    await m?.close()
                    self.prev = nil
                    if self.state == .online {
                        self.onAlert?(L("{} tidak bisa dihubungi", self.host.title), error.ztermMessage, "down:\(self.id)")
                    }
                    self.alerting.removeAll()
                    withAnimation(.zterm) { self.state = .offline(error.ztermMessage) }
                    try? await Task.sleep(for: Self.retry)
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        let m = monitor
        monitor = nil
        Task { await m?.close() }
    }

    func restart(target: SshTarget?) {
        stop()
        withAnimation(.zterm) { state = .connecting }
        start(target: target)
    }

    private func add(_ s: ServerSample) {
        let now = Date()
        var r = 0.0, t = 0.0
        if let (p, at) = prev, s.netRxBytes >= p.netRxBytes, s.netTxBytes >= p.netTxBytes {
            let dt = max(0.5, now.timeIntervalSince(at))
            r = Double(s.netRxBytes - p.netRxBytes) / dt
            t = Double(s.netTxBytes - p.netTxBytes) / dt
        }
        prev = (s, now)
        if isOffline, wasOnline { onAlert?(L("{} kembali online", host.title), L("Server bisa dihubungi lagi."), "down:\(id)") }
        wasOnline = true
        defer { checkAlerts() }
        withAnimation(.easeOut(duration: 0.4)) {
            sample = s
            state = .online
            rx = r; tx = t
            cpu.append(Double(s.cpuPercent))
            if cpu.count > 30 { cpu.removeFirst(cpu.count - 30) }
        }
    }

    /// Notifikasi sekali saat CPU / RAM / disk melewati 90%; aktif lagi setelah turun di bawah 85%.
    private func checkAlerts() {
        guard let s = sample else { return }
        let metrics: [(String, Double, String)] = [
            ("CPU", cpu.count >= 3 ? cpuNow / 100 : 0, L("rata-rata 15 detik terakhir")),
            ("RAM", memFraction, L("{} dari {} terpakai", Self.bytes(s.memUsedBytes), Self.bytes(s.memTotalBytes))),
            (L("Disk"), diskFraction, L("{} dari {} terpakai", Self.bytes(s.diskUsedBytes), Self.bytes(s.diskTotalBytes))),
        ]
        for (name, f, detail) in metrics {
            if f >= 0.9, !alerting.contains(name) {
                alerting.insert(name)
                onAlert?("\(host.title): \(name) \(Int((f * 100).rounded()))%", detail, "\(name):\(id)")
            } else if f < 0.85 {
                alerting.remove(name)
            }
        }
    }

    private static func bytes(_ b: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(b, UInt64(Int64.max))), countStyle: .memory)
    }

    // MARK: Kesehatan

    /// CPU rata-rata 3 sampel terakhir — lonjakan sesaat tidak langsung dianggap masalah.
    var cpuNow: Double {
        let tail = cpu.suffix(3)
        return tail.isEmpty ? 0 : tail.reduce(0, +) / Double(tail.count)
    }

    var memFraction: Double {
        guard let s = sample, s.memTotalBytes > 0 else { return 0 }
        return Double(s.memUsedBytes) / Double(s.memTotalBytes)
    }

    var diskFraction: Double {
        guard let s = sample, s.diskTotalBytes > 0 else { return 0 }
        return Double(s.diskUsedBytes) / Double(s.diskTotalBytes)
    }

    static func level(_ f: Double) -> Level { f >= 0.9 ? .critical : f >= 0.75 ? .warn : .ok }

    var level: Level {
        guard state == .online else { return .ok }
        return max(Self.level(cpuNow / 100), Self.level(memFraction), Self.level(diskFraction))
    }

    var isOffline: Bool { if case .offline = state { true } else { false } }

    /// Masalah yang perlu dilihat, mis. ["Disk 93%", "RAM 91%"].
    var issues: [String] {
        guard state == .online else { return [] }
        var out: [String] = []
        if Self.level(cpuNow / 100) == .critical { out.append(L("CPU {}%", Int(cpuNow.rounded()))) }
        if Self.level(memFraction) == .critical { out.append(L("RAM {}%", Int((memFraction * 100).rounded()))) }
        if Self.level(diskFraction) == .critical { out.append(L("Disk {}%", Int((diskFraction * 100).rounded()))) }
        return out
    }

    var needsAttention: Bool { isOffline || level == .critical }
}

@MainActor
@Observable
final class DashboardModel {
    enum Filter: String, CaseIterable, Identifiable {
        case all, attention, offline
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: L("Semua")
            case .attention: L("Perlu perhatian")
            case .offline: L("Offline")
            }
        }
    }

    var tiles: [String: ServerTile] = [:]
    var selection: Set<String> = []
    /// Pantau terus di latar belakang & kirim notifikasi (tersimpan di Mac ini).
    var alerts = UserDefaults.standard.bool(forKey: "dashboard.alerts") {
        didSet { UserDefaults.standard.set(alerts, forKey: "dashboard.alerts") }
    }
    var filter: Filter = .all
    var query = ""

    /// Sambungkan semua host (yang baru ditambahkan ikut, yang dihapus dilepas).
    func start(_ app: AppModel) {
        let ids = Set(app.hosts.map(\.id))
        for (id, t) in tiles where !ids.contains(id) { t.stop(); tiles[id] = nil }
        selection.formIntersection(ids)
        for h in app.hosts {
            let t = tiles[h.id] ?? ServerTile(host: h)
            if t.onAlert == nil {
                t.onAlert = { [weak self] title, body, key in
                    if self?.alerts == true { Notifier.shared.send(title: title, body: body, key: key) }
                }
            }
            if t.host != h {
                let reconnect = t.host.hostname != h.hostname || t.host.port != h.port || t.host.username != h.username
                    || t.host.auth != h.auth || t.host.keyId != h.keyId || t.host.password != h.password
                t.host = h
                if reconnect { t.info = nil; t.restart(target: app.sshTarget(forId: h.id)); continue }
            }
            tiles[h.id] = t
            t.start(target: app.sshTarget(forId: h.id))
        }
    }

    func stop() { tiles.values.forEach { $0.stop() } }

    /// Saat vault dikunci: putus semua dan lupakan datanya.
    func reset() {
        stop()
        tiles = [:]
        selection = []
    }

    /// Coba lagi semua server yang offline sekarang juga.
    func retryOffline(_ app: AppModel) {
        for t in tiles.values where t.isOffline { t.restart(target: app.sshTarget(forId: t.id)) }
    }

    func ordered(_ app: AppModel) -> [ServerTile] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return app.hosts.compactMap { tiles[$0.id] }.filter { t in
            switch filter {
            case .all: true
            case .attention: t.needsAttention || t.level == .warn
            case .offline: t.isOffline
            }
        }.filter { t in
            q.isEmpty || [t.host.title, t.host.hostname, t.host.group ?? "", t.info?.os ?? ""].contains { $0.lowercased().contains(q) }
        }
    }

    var online: Int { tiles.values.filter { $0.state == .online }.count }
    var attention: Int { tiles.values.filter(\.needsAttention).count }
}
