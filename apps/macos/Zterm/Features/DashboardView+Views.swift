import Charts
import SwiftUI

// MARK: - View

struct DashboardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var dash = model.dashboard
        let tiles = dash.ordered(model)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Dashboard", subtitle: L("Semua server dalam satu layar — CPU, RAM, disk & uptime, diperbarui tiap 5 detik")) {
                    if dash.tiles.values.contains(where: \.isOffline) {
                        PhIconButton(name: "arrows-clockwise", help: L("Coba lagi semua server yang offline")) {
                            dash.retryOffline(model)
                        }
                    }
                    Button { Task { await model.setDashboardAlerts(!dash.alerts) } } label: {
                        HStack(spacing: 6) {
                            PhosphorIcon(name: dash.alerts ? "bell-ringing" : "bell-slash", size: 13,
                                         tint: dash.alerts ? Theme.accent : .secondary)
                            Text(dash.alerts ? L("Notifikasi aktif") : L("Notifikasi"))
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .help(dash.alerts ? L("Dashboard terus memantau di latar belakang dan memberi notifikasi saat server mati atau CPU/RAM/disk di atas 90%. Klik untuk mematikan.")
                                      : L("Nyalakan notifikasi: pantau terus di latar belakang, beri tahu saat server mati atau CPU/RAM/disk di atas 90%"))
                    if !model.hosts.isEmpty {
                        Button { model.openRunMany(Array(dash.selection)) } label: {
                            HStack(spacing: 6) {
                                PhosphorIcon(name: "play", size: 11, tint: Color(hex: "#06231E"))
                                Text(L("Jalankan perintah"))
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .help(L("Jalankan satu perintah di banyak server sekaligus, hasilnya per server"))
                    }
                }
                if model.hosts.isEmpty {
                    EmptyState(ph: "hard-drives", title: L("Belum ada server"),
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
                            .font(.system(size: 12.5)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.top, 40)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                        ForEach(Array(tiles.enumerated()), id: \.element.id) { i, t in
                            ServerCard(tile: t).staggerIn(i, base: 0)
                        }
                    }
                }
            }
            .padding(24)
            .padding(.bottom, dash.selection.isEmpty ? 0 : 56)
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
        .onChange(of: model.hosts.map(\.id)) { dash.start(model) }
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
        HStack(spacing: 12) {
            stat(L("Online"), "\(dash.online)/\(dash.tiles.count)", icon: "pulse", tint: Theme.green)
            stat(L("Perlu perhatian"), "\(dash.attention)", icon: "warning",
                 tint: dash.attention > 0 ? Theme.red : .secondary)
            stat(L("CPU rata-rata"), live.isEmpty ? "—" : "\(Int(cpu.rounded()))%", icon: "cpu", tint: Theme.accent)
            stat(L("RAM terpakai"), total == 0 ? "—" : "\(bytes(used)) / \(bytes(total))", icon: "memory", tint: Theme.accent3)
        }
    }

    private func stat(_ title: String, _ value: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.10))
                PhosphorIcon(name: icon, size: 17, tint: tint)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Text(verbatim: value).font(.system(size: 17, weight: .semibold))
                    .monospacedDigit().contentTransition(.numericText())
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.cardStroke))
    }
}

private struct ServerCard: View {
    @Environment(AppModel.self) private var model
    let tile: ServerTile
    @State private var hover = false

    private var selected: Bool { model.dashboard.selection.contains(tile.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            header
            switch tile.state {
            case .connecting where tile.sample == nil:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L("Menghubungkan…")).font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 118)
            case .offline(let msg):
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        PhosphorIcon(name: "wifi-slash", size: 14, tint: Theme.red)
                        Text(L("Tidak bisa dihubungi")).font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Theme.red)
                    }
                    Text(msg).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .lineLimit(3).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button { tile.restart(target: model.sshTarget(forId: tile.id)) } label: {
                        HStack(spacing: 6) {
                            PhosphorIcon(name: "arrows-clockwise", size: 11)
                            Text(L("Coba lagi"))
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
            default:
                metrics
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hover ? Theme.cardHover : Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(stroke, lineWidth: selected ? 1.5 : 1))
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
        if tile.isOffline || tile.level == .critical { return Theme.red.opacity(0.55) }
        if tile.level == .warn { return Theme.orange.opacity(0.45) }
        return hover ? Theme.ink.opacity(0.18) : Theme.cardStroke
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
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(hex: tile.host.color).opacity(selected ? 0.22 : 0.14))
                    if selected || hover {
                        PhosphorIcon(name: selected ? "check" : "circle", size: 13, tint: Color(hex: tile.host.color))
                    } else {
                        Text(String(tile.host.title.prefix(1)).uppercased())
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(hex: tile.host.color))
                    }
                }
                .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .help(selected ? L("Batal pilih") : L("Pilih untuk dibuka bersama (split & broadcast)"))
            VStack(alignment: .leading, spacing: 1) {
                Text(tile.host.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if hover {
                PhIconButton(name: "terminal-window", help: L("Buka terminal"), size: 14) { model.connect([tile.id]) }
                PhIconButton(name: "folder-open", help: L("Buka SFTP"), size: 14) { Task { await model.openSftp(tile.host) } }
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
                Badge(text: issues.count > 1 ? "\(first) +\(issues.count - 1)" : first, color: Theme.red)
            } else {
                HStack(spacing: 5) {
                    PulseDot(color: Theme.green)
                    Text(L("Online")).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
        case .connecting:
            ProgressView().controlSize(.mini)
        case .offline:
            Badge(text: L("Offline"), color: Theme.red)
        }
    }

    @ViewBuilder private var metrics: some View {
        let s = tile.sample
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .bottom, spacing: 14) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("CPU").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                    Text(verbatim: "\(Int(tile.cpuNow.rounded()))%")
                        .font(.system(size: 23, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(tint(ServerTile.level(tile.cpuNow / 100), base: .primary))
                        .contentTransition(.numericText())
                }
                .frame(width: 58, alignment: .leading)
                let shift = 30 - tile.cpu.count
                Chart(Array(tile.cpu.enumerated()), id: \.offset) { p in
                    AreaMark(x: .value("t", p.offset + shift), y: .value("CPU", p.element))
                        .foregroundStyle(Theme.accent.opacity(0.12)).interpolationMethod(.monotone)
                    LineMark(x: .value("t", p.offset + shift), y: .value("CPU", p.element))
                        .foregroundStyle(Theme.accent).lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.monotone)
                }
                .chartXScale(domain: 0...29)
                .chartYScale(domain: 0...100)
                .chartXAxis(.hidden).chartYAxis(.hidden)
                .frame(height: 42)
            }
            bar("RAM", used: s?.memUsedBytes ?? 0, total: s?.memTotalBytes ?? 0, color: Theme.accent3)
            bar(L("Disk"), used: s?.diskUsedBytes ?? 0, total: s?.diskTotalBytes ?? 0, color: Theme.orange)
            HStack(spacing: 14) {
                foot("clock", s.map { uptime($0.uptimeSecs) } ?? "—")
                foot("gauge", s.map { String(format: "%.2f", $0.load1) } ?? "—")
                Spacer(minLength: 0)
                foot("arrow-down", rate(tile.rx))
                foot("arrow-up", rate(tile.tx))
            }
        }
    }

    private func tint(_ l: ServerTile.Level, base: Color) -> Color {
        switch l {
        case .ok: base
        case .warn: Theme.orange
        case .critical: Theme.red
        }
    }

    private func bar(_ label: String, used: UInt64, total: UInt64, color: Color) -> some View {
        let f = total > 0 ? min(1, Double(used) / Double(total)) : 0
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(label).font(.system(size: 11, weight: .medium))
                Text(verbatim: "\(Int((f * 100).rounded()))%").font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(tint(ServerTile.level(f), base: .secondary))
                Spacer()
                Text(total > 0 ? "\(bytes(used)) / \(bytes(total))" : "—")
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.ink.opacity(0.07))
                    Capsule().fill(tint(ServerTile.level(f), base: color)).frame(width: max(3, g.size.width * f))
                }
            }
            .frame(height: 4)
        }
    }

    private func foot(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            PhosphorIcon(name: icon, size: 11, tint: .secondary)
            Text(verbatim: text).font(.system(size: 10.5, design: .monospaced)).lineLimit(1)
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
        HStack(spacing: 12) {
            Text("\(ids.count)")
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .frame(minWidth: 22, minHeight: 22)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .foregroundStyle(Color(hex: "#06231E"))
                .contentTransition(.numericText())
            Text(L("server dipilih")).font(.system(size: 12.5))
            Divider().frame(height: 18)
            Button(L("Batal")) { withAnimation(.ztermSnappy) { dash.selection.removeAll() } }
                .buttonStyle(.borderless)
            Button {
                model.connect(ids)
                dash.selection.removeAll()
            } label: {
                HStack(spacing: 6) {
                    PhosphorIcon(name: "terminal-window", size: 11)
                    Text(L("Buka tab"))
                }
            }
            .buttonStyle(SecondaryButtonStyle())
            Button { model.openRunMany(ids) } label: {
                HStack(spacing: 6) {
                    PhosphorIcon(name: "play", size: 11)
                    Text(L("Jalankan perintah"))
                }
            }
            .buttonStyle(SecondaryButtonStyle())
            Button {
                model.openSplit(ids, broadcast: true)
                dash.selection.removeAll()
            } label: {
                HStack(spacing: 6) {
                    PhosphorIcon(name: "squares-four", size: 11, tint: Color(hex: "#06231E"))
                    Text(L("Split & broadcast"))
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(ids.count < 2 || ids.count > AppModel.maxSplit)
            .help(ids.count > AppModel.maxSplit ? L("Maksimal {} server dalam satu split", AppModel.maxSplit) : L("Buka berdampingan, ketikan dikirim ke semua"))
        }
        .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 8)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.cardStroke))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }
}

private func bytes(_ b: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(min(b, UInt64(Int64.max))), countStyle: .memory)
}
