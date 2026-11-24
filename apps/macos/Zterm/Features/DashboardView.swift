import Charts
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

// MARK: - View

struct DashboardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var dash = model.dashboard
        let tiles = dash.ordered(model)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Dashboard", subtitle: L("Semua server dalam satu layar — CPU, RAM, disk & uptime, diperbarui tiap 5 detik")) {
                    if dash.tiles.values.contains(where: \.isOffline) {
                        Button { dash.retryOffline(model) } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(SecondaryButtonStyle())
                            .help(L("Coba lagi semua server yang offline"))
                    }
                    Button { Task { await model.setDashboardAlerts(!dash.alerts) } } label: {
                        Label(dash.alerts ? L("Notifikasi aktif") : L("Notifikasi"), systemImage: dash.alerts ? "bell.badge.fill" : "bell.slash")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .help(dash.alerts ? L("Dashboard terus memantau di latar belakang dan memberi notifikasi saat server mati atau CPU/RAM/disk di atas 90%. Klik untuk mematikan.")
                                      : L("Nyalakan notifikasi: pantau terus di latar belakang, beri tahu saat server mati atau CPU/RAM/disk di atas 90%"))
                    if !model.hosts.isEmpty {
                        Button { model.openRunMany(Array(dash.selection)) } label: { Label(L("Jalankan perintah"), systemImage: "play.rectangle.on.rectangle") }
                            .buttonStyle(PrimaryButtonStyle())
                            .help(L("Jalankan satu perintah di banyak server sekaligus, hasilnya per server"))
                    }
                }
                if model.hosts.isEmpty {
                    EmptyState(icon: "gauge.with.dots.needle.67percent", title: L("Belum ada server"),
                               text: L("Tambahkan host di menu Hosts — semua server langsung tampil di sini lengkap dengan pemakaian CPU, RAM, dan disk."))
                } else {
                    SummaryRow()
                    HStack(spacing: 12) {
                        Picker("", selection: $dash.filter) {
                            ForEach(DashboardModel.Filter.allCases) { f in Text(f.title).tag(f) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        Spacer()
                        SearchField(text: $dash.query, prompt: L("Cari server, OS, grup…")).frame(maxWidth: 260)
                    }
                    if tiles.isEmpty {
                        Text(dash.filter == .all ? L("Tidak ada server yang cocok.") : L("Semua server sehat 🎉"))
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 40)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                        ForEach(Array(tiles.enumerated()), id: \.element.id) { i, t in
                            ServerCard(tile: t).staggerIn(i, base: 0)
                        }
                    }
                }
            }
            .padding(28)
            .padding(.bottom, dash.selection.isEmpty ? 0 : 60)
        }
        .overlay(alignment: .bottom) {
            if !dash.selection.isEmpty {
                DashboardSelectionBar()
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.zterm, value: dash.filter)
        .animation(.ztermSnappy, value: dash.selection)
        .onAppear { dash.start(model) }
        .onChange(of: model.hosts) { dash.start(model) }
        .onDisappear { if !dash.alerts { dash.stop() } }
        .sheet(item: Binding(get: { model.runMany }, set: { model.runMany = $0 })) { RunManyView(run: $0) }
    }
}

/// Ringkasan di atas: online, perlu perhatian, CPU rata-rata, RAM terpakai.
private struct SummaryRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let dash = model.dashboard
        let live = dash.tiles.values.filter { $0.state == .online }
        let cpu = live.isEmpty ? 0 : live.map(\.cpuNow).reduce(0, +) / Double(live.count)
        let used = live.compactMap(\.sample).map(\.memUsedBytes).reduce(0, +)
        let total = live.compactMap(\.sample).map(\.memTotalBytes).reduce(0, +)
        HStack(spacing: 14) {
            stat(L("Online"), "\(dash.online)/\(dash.tiles.count)", icon: "dot.radiowaves.up.forward", tint: Color(hex: "#4ADE80"))
            stat(L("Perlu perhatian"), "\(dash.attention)", icon: "exclamationmark.triangle.fill",
                 tint: dash.attention > 0 ? Color(hex: "#F0616D") : .secondary)
            stat(L("CPU rata-rata"), live.isEmpty ? "—" : "\(Int(cpu.rounded()))%", icon: "cpu", tint: Theme.accent)
            stat(L("RAM terpakai"), total == 0 ? "—" : "\(bytes(used)) / \(bytes(total))", icon: "memorychip", tint: Theme.accent3)
        }
    }

    private func stat(_ title: String, _ value: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(verbatim: value).font(.system(size: 17, weight: .bold, design: .rounded))
                    .contentTransition(.numericText()).lineLimit(1).minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.cardStroke))
    }
}

private struct ServerCard: View {
    @Environment(AppModel.self) private var model
    let tile: ServerTile
    @State private var hover = false

    private var selected: Bool { model.dashboard.selection.contains(tile.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            switch tile.state {
            case .connecting where tile.sample == nil:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L("Menghubungkan…")).font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 118)
            case .offline(let msg):
                VStack(alignment: .leading, spacing: 10) {
                    Label(L("Tidak bisa dihubungi"), systemImage: "bolt.horizontal.circle").font(.callout.weight(.semibold))
                        .foregroundStyle(Color(hex: "#F0616D"))
                    Text(msg).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button(L("Coba lagi")) { tile.restart(target: model.sshTarget(forId: tile.id)) }
                        .buttonStyle(SecondaryButtonStyle())
                }
                .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
            default:
                metrics
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(hover ? Theme.cardHover : Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(stroke, lineWidth: selected ? 1.5 : 1))
        .shadow(color: Theme.shadow.opacity(hover ? 1 : 0), radius: 12, y: 6)
        .animation(.ztermHover, value: hover)
        .onHover { hover = $0 }
        .contextMenu {
            Button(L("Buka terminal")) { model.connect([tile.id]) }
            Button(L("Buka SFTP")) { Task { await model.openSftp(tile.host) } }
            Divider()
            Button(selected ? L("Batal pilih") : L("Pilih")) { toggle() }
            Button(L("Sambung ulang")) { tile.restart(target: model.sshTarget(forId: tile.id)) }
        }
    }

    private var stroke: Color {
        if selected { return Theme.accent }
        if tile.isOffline || tile.level == .critical { return Color(hex: "#F0616D").opacity(0.55) }
        if tile.level == .warn { return Color(hex: "#F2A65A").opacity(0.45) }
        return Theme.ink.opacity(hover ? 0.14 : 0.08)
    }

    private func toggle() {
        withAnimation(.ztermSnappy) {
            if selected { model.dashboard.selection.remove(tile.id) } else { model.dashboard.selection.insert(tile.id) }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: toggle) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(hex: tile.host.color).gradient)
                    if selected || hover {
                        Image(systemName: selected ? "checkmark" : "circle")
                            .font(.system(size: selected ? 13 : 12, weight: .bold)).foregroundStyle(.black.opacity(0.7))
                    } else {
                        Text(String(tile.host.title.prefix(1)).uppercased())
                            .font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(.black.opacity(0.7))
                    }
                }
                .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .help(selected ? L("Batal pilih") : L("Pilih untuk dibuka bersama (split & broadcast)"))
            VStack(alignment: .leading, spacing: 1) {
                Text(tile.host.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if hover {
                IconButton(symbol: "terminal", help: L("Buka terminal")) { model.connect([tile.id]) }
                IconButton(symbol: "folder", help: L("Buka SFTP")) { Task { await model.openSftp(tile.host) } }
            } else {
                status
            }
        }
    }

    private var subtitle: String {
        if let os = tile.info?.os, !os.isEmpty { return os }
        return tile.host.address
    }

    @ViewBuilder private var status: some View {
        switch tile.state {
        case .online:
            let issues = tile.issues
            if let first = issues.first {
                Badge(text: issues.count > 1 ? "\(first) +\(issues.count - 1)" : first, color: Color(hex: "#F0616D"))
            } else {
                HStack(spacing: 5) {
                    PulseDot(color: Color(hex: "#4ADE80"))
                    Text(L("Online")).font(.caption).foregroundStyle(.secondary)
                }
            }
        case .connecting:
            ProgressView().controlSize(.mini)
        case .offline:
            Badge(text: L("Offline"), color: Color(hex: "#F0616D"))
        }
    }

    @ViewBuilder private var metrics: some View {
        let s = tile.sample
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("CPU").font(.caption).foregroundStyle(.secondary)
                    Text(verbatim: "\(Int(tile.cpuNow.rounded()))%")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(tint(ServerTile.level(tile.cpuNow / 100), base: .primary))
                        .contentTransition(.numericText())
                }
                .frame(width: 64, alignment: .leading)
                let shift = 30 - tile.cpu.count
                Chart(Array(tile.cpu.enumerated()), id: \.offset) { p in
                    AreaMark(x: .value("t", p.offset + shift), y: .value("CPU", p.element))
                        .foregroundStyle(Theme.accent.opacity(0.16)).interpolationMethod(.monotone)
                    LineMark(x: .value("t", p.offset + shift), y: .value("CPU", p.element))
                        .foregroundStyle(Theme.accent).interpolationMethod(.monotone)
                }
                .chartXScale(domain: 0...29)
                .chartYScale(domain: 0...100)
                .chartXAxis(.hidden).chartYAxis(.hidden)
                .frame(height: 40)
            }
            bar("RAM", used: s?.memUsedBytes ?? 0, total: s?.memTotalBytes ?? 0, color: Theme.accent3)
            bar(L("Disk"), used: s?.diskUsedBytes ?? 0, total: s?.diskTotalBytes ?? 0, color: Color(hex: "#F2A65A"))
            HStack(spacing: 12) {
                foot("clock.arrow.circlepath", s.map { uptime($0.uptimeSecs) } ?? "—")
                foot("gauge.with.dots.needle.33percent", s.map { String(format: "%.2f", $0.load1) } ?? "—")
                Spacer(minLength: 0)
                foot("arrow.down", rate(tile.rx))
                foot("arrow.up", rate(tile.tx))
            }
        }
    }

    private func tint(_ l: ServerTile.Level, base: Color) -> Color {
        switch l {
        case .ok: base
        case .warn: Color(hex: "#F2A65A")
        case .critical: Color(hex: "#F0616D")
        }
    }

    private func bar(_ label: String, used: UInt64, total: UInt64, color: Color) -> some View {
        let f = total > 0 ? min(1, Double(used) / Double(total)) : 0
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.system(size: 11.5, weight: .medium))
                Text(verbatim: "\(Int((f * 100).rounded()))%").font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(tint(ServerTile.level(f), base: .secondary))
                Spacer()
                Text(total > 0 ? "\(bytes(used)) / \(bytes(total))" : "—")
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.ink.opacity(0.08))
                    Capsule().fill(tint(ServerTile.level(f), base: color).gradient).frame(width: max(4, g.size.width * f))
                }
            }
            .frame(height: 5)
        }
    }

    private func foot(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9.5, weight: .semibold))
            Text(verbatim: text).font(.system(size: 11, design: .monospaced)).lineLimit(1)
        }
        .foregroundStyle(.secondary)
    }

    private func uptime(_ s: UInt64) -> String {
        let d = s / 86_400, h = (s % 86_400) / 3_600, m = (s % 3_600) / 60
        if d > 0 { return L("{} hari", d) }
        if h > 0 { return L("{} jam", h) }
        return L("{} mnt", m)
    }

    private func rate(_ bps: Double) -> String {
        switch bps {
        case ..<1_000: L("{} B/s", Int(bps))
        case ..<1_000_000: String(format: L("%.0f KB/s"), bps / 1_000)
        default: String(format: L("%.1f MB/s"), bps / 1_000_000)
        }
    }
}

/// Bar mengambang saat ada server dipilih: buka terminal, atau split + broadcast (2–4 server).
private struct DashboardSelectionBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let dash = model.dashboard
        let ids = model.hosts.map(\.id).filter { dash.selection.contains($0) }
        HStack(spacing: 14) {
            Text("\(ids.count)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .frame(minWidth: 24, minHeight: 24)
                .background(Theme.accent, in: Circle())
                .foregroundStyle(.black)
                .contentTransition(.numericText())
            Text(L("server dipilih")).font(.callout)
            Divider().frame(height: 18)
            Button(L("Batal")) { withAnimation(.ztermSnappy) { dash.selection.removeAll() } }
                .buttonStyle(.borderless)
            Button {
                model.connect(ids)
                dash.selection.removeAll()
            } label: { Label(L("Buka tab"), systemImage: "terminal") }
                .buttonStyle(SecondaryButtonStyle())
            Button { model.openRunMany(ids) } label: { Label(L("Jalankan perintah"), systemImage: "play.rectangle.on.rectangle") }
                .buttonStyle(SecondaryButtonStyle())
            Button {
                model.openSplit(ids, broadcast: true)
                dash.selection.removeAll()
            } label: { Label(L("Split & broadcast"), systemImage: "dot.radiowaves.left.and.right") }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(ids.count < 2 || ids.count > AppModel.maxSplit)
                .help(ids.count > AppModel.maxSplit ? L("Maksimal {} server dalam satu split", AppModel.maxSplit) : L("Buka berdampingan, ketikan dikirim ke semua"))
        }
        .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 8)
        .background(.ultraThickMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.ink.opacity(0.1)))
        .shadow(color: Theme.shadow, radius: 24, y: 10)
    }
}

private func bytes(_ b: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(min(b, UInt64(Int64.max))), countStyle: .memory)
}
