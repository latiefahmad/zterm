import Charts
import SwiftUI

/// Info & grafik satu server: satu koneksi SSH (ServerMonitor) yang tetap terbuka selama panel tampil.
@MainActor
@Observable
final class ServerStats {
    enum State: Equatable { case connecting, ready, failed(String) }

    struct Point: Identifiable {
        let id: Int
        let cpu: Double
        let mem: Double
        let rx: Double
        let tx: Double
    }

    let host: Host
    var state: State = .connecting
    var info: ServerInfo?
    var latest: ServerSample?
    var points: [Point] = []

    @ObservationIgnored private var monitor: ServerMonitor?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var prev: (ServerSample, Date)?
    @ObservationIgnored private var counter = 0

    /// Jumlah titik grafik (3 detik × 60 = 3 menit).
    static let window = 60

    init(host: Host) { self.host = host }

    func start(target: SshTarget) {
        task = Task { [weak self] in
            do {
                let m = try await ServerMonitor.connect(target: target)
                self?.monitor = m
                let info = try await m.info()
                guard let self, !Task.isCancelled else { await m.close(); return }
                withAnimation(.zterm) { self.info = info; self.state = .ready }
                while !Task.isCancelled {
                    let s = try await m.sample()
                    self.add(s)
                    try await Task.sleep(for: .seconds(3))
                }
            } catch is CancellationError {
            } catch {
                guard let self, !Task.isCancelled else { return }
                withAnimation(.zterm) { self.state = .failed(error.ztermMessage) }
            }
        }
    }

    func stop() {
        task?.cancel()
        let m = monitor
        monitor = nil
        Task { await m?.close() }
    }

    func retry(target: SshTarget) {
        stop()
        state = .connecting
        start(target: target)
    }

    private func add(_ s: ServerSample) {
        let now = Date()
        var rx = 0.0, tx = 0.0
        if let (p, t) = prev {
            let dt = max(0.5, now.timeIntervalSince(t))
            rx = Double(s.netRxBytes &- p.netRxBytes) / dt
            tx = Double(s.netTxBytes &- p.netTxBytes) / dt
            if s.netRxBytes < p.netRxBytes || s.netTxBytes < p.netTxBytes { rx = 0; tx = 0 }
        }
        prev = (s, now)
        counter += 1
        let mem = s.memTotalBytes > 0 ? Double(s.memUsedBytes) / Double(s.memTotalBytes) * 100 : 0
        withAnimation(.easeOut(duration: 0.4)) {
            latest = s
            points.append(Point(id: counter, cpu: Double(s.cpuPercent), mem: mem, rx: rx, tx: tx))
            if points.count > Self.window { points.removeFirst(points.count - Self.window) }
        }
    }
}

// MARK: - Panel

struct ServerInfoPanel: View {
    @Environment(AppModel.self) private var model
    let stats: ServerStats

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch stats.state {
            case .connecting:
                VStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text(L("Membaca info server…")).font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let msg):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(.orange)
                    Text(msg).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).textSelection(.enabled)
                    Button(L("Coba lagi")) { model.retryServerStats() }.buttonStyle(SecondaryButtonStyle())
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready:
                if let info = stats.info {
                    ScrollView { content(info).padding(14) }
                }
            }
        }
        .background(Theme.panel)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(hex: stats.host.color).gradient)
                Image(systemName: "cpu").font(.system(size: 14, weight: .bold)).foregroundStyle(.black.opacity(0.7))
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(stats.info?.hostname.isEmpty == false ? stats.info!.hostname : stats.host.title)
                    .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                HStack(spacing: 5) {
                    if stats.state == .ready { PulseDot(color: Color(hex: "#4ADE80")) }
                    Text(stats.state == .ready ? L("Live · tiap 3 detik") : L("Info server")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            IconButton(symbol: "xmark", help: L("Tutup panel")) { withAnimation(.zterm) { model.showServerInfo = false } }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    @ViewBuilder private func content(_ i: ServerInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Spesifikasi
            VStack(spacing: 0) {
                spec("macwindow", "OS", i.os.isEmpty ? "—" : i.os)
                spec("gearshape.2", "Kernel", i.kernel)
                spec("cpu", "CPU", cpuText(i))
                spec("clock.arrow.circlepath", "Uptime", i.uptimeSecs.map(uptime) ?? "—")
                if !i.load.isEmpty { spec("gauge.with.dots.needle.33percent", "Load", i.load, last: true) }
            }
            .background(Theme.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            // Grafik live
            chartCard("CPU", value: stats.latest.map { String(format: "%.0f%%", $0.cpuPercent) } ?? "—", color: Theme.accent) {
                Chart(stats.points) { p in
                    AreaMark(x: .value("t", p.id), y: .value("CPU", p.cpu)).foregroundStyle(Theme.accent.opacity(0.18)).interpolationMethod(.monotone)
                    LineMark(x: .value("t", p.id), y: .value("CPU", p.cpu)).foregroundStyle(Theme.accent).interpolationMethod(.monotone)
                }
                .chartYScale(domain: 0...100)
            }
            chartCard("RAM", value: stats.latest.map { "\(bytes($0.memUsedBytes)) / \(bytes($0.memTotalBytes))" } ?? "—", color: Color(hex: "#9D7CF2")) {
                Chart(stats.points) { p in
                    AreaMark(x: .value("t", p.id), y: .value("RAM", p.mem)).foregroundStyle(Color(hex: "#9D7CF2").opacity(0.18)).interpolationMethod(.monotone)
                    LineMark(x: .value("t", p.id), y: .value("RAM", p.mem)).foregroundStyle(Color(hex: "#9D7CF2")).interpolationMethod(.monotone)
                }
                .chartYScale(domain: 0...100)
            }
            chartCard(L("Jaringan"), value: stats.points.last.map { "↓ \(rate($0.rx))  ↑ \(rate($0.tx))" } ?? "—", color: Color(hex: "#5B9CF5")) {
                Chart(stats.points) { p in
                    LineMark(x: .value("t", p.id), y: .value("B/s", p.rx), series: .value("arah", "Masuk")).foregroundStyle(Color(hex: "#5B9CF5"))
                    LineMark(x: .value("t", p.id), y: .value("B/s", p.tx), series: .value("arah", "Keluar")).foregroundStyle(Color(hex: "#F2A65A"))
                }
            }

            // Memori & storage
            VStack(alignment: .leading, spacing: 12) {
                usage("RAM", used: stats.latest?.memUsedBytes ?? i.memUsedBytes, total: stats.latest?.memTotalBytes ?? i.memTotalBytes, color: Color(hex: "#9D7CF2"))
                if i.swapTotalBytes > 0 {
                    usage("Swap", used: i.swapUsedBytes, total: i.swapTotalBytes, color: Color(hex: "#94A3B8"))
                }
                ForEach(i.disks, id: \.mount) { d in
                    usage(d.mount == "/" ? L("Storage (/)") : d.mount, used: d.usedBytes, total: d.totalBytes, color: Color(hex: "#F2A65A"))
                }
            }
            .padding(12)
            .background(Theme.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func spec(_ icon: String, _ label: String, _ value: String, last: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 18)
                Text(label).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                Text(value).font(.system(size: 12, weight: .medium)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            if !last { Divider().opacity(0.5).padding(.leading, 40) }
        }
    }

    private func chartCard<C: View>(_ title: String, value: String, color: Color, @ViewBuilder chart: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(value).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary).contentTransition(.numericText())
            }
            chart()
                .chartXScale(domain: xDomain)
                .chartXAxis(.hidden)
                .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in AxisGridLine().foregroundStyle(Theme.ink.opacity(0.08)) } }
                .chartLegend(.hidden)
                .frame(height: 70)
        }
        .padding(12)
        .background(Theme.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func usage(_ label: String, used: UInt64, total: UInt64, color: Color) -> some View {
        let f = total > 0 ? min(1, Double(used) / Double(total)) : 0
        let tint = f > 0.9 ? Color(hex: "#F0616D") : color
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text("\(bytes(used)) / \(bytes(total))").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.ink.opacity(0.08))
                    Capsule().fill(tint.gradient).frame(width: max(4, g.size.width * f))
                }
            }
            .frame(height: 6)
            .animation(.zterm, value: f)
        }
    }

    /// Jendela waktu tetap (3 menit) agar grafik berjalan dari kanan.
    private var xDomain: ClosedRange<Int> {
        let last = stats.points.last?.id ?? 0
        return (last - ServerStats.window + 1)...last
    }

    private func cpuText(_ i: ServerInfo) -> String {
        let model = i.cpuModel.isEmpty ? i.arch : "\(i.cpuModel) · \(i.arch)"
        return i.cpuCores > 0 ? L("{} · {} core", model, i.cpuCores) : model
    }

    private func bytes(_ b: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(min(b, UInt64(Int64.max))), countStyle: .memory) }

    private func rate(_ bps: Double) -> String {
        bps < 1 ? L("0 B/s") : ByteCountFormatter.string(fromByteCount: Int64(bps), countStyle: .file) + "/s"
    }

    private func uptime(_ s: UInt64) -> String {
        let d = s / 86_400, h = (s % 86_400) / 3_600, m = (s % 3_600) / 60
        if d > 0 { return L("{} hari {} jam", d, h) }
        if h > 0 { return L("{} jam {} menit", h, m) }
        return L("{} menit", m)
    }
}
