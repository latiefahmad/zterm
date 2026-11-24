import SwiftUI

// MARK: - Model

/// Kelola Server: proses, service systemd, crontab, dan log satu server lewat SSH (ServerAdmin).
@MainActor
@Observable
final class AdminModel {
    enum Tab: String, CaseIterable, Identifiable {
        case processes, services, cron, logs
        var id: String { rawValue }
        var title: String {
            switch self {
            case .processes: L("Proses")
            case .services: L("Service")
            case .cron: "Cron"
            case .logs: L("Log")
            }
        }
        var icon: String {
            switch self {
            case .processes: "cpu"
            case .services: "gearshape.2"
            case .cron: "calendar.badge.clock"
            case .logs: "doc.text.magnifyingglass"
            }
        }
    }

    enum ProcSort: String, CaseIterable, Identifiable {
        case cpu, mem, pid
        var id: String { rawValue }
        var title: String { switch self { case .cpu: "CPU"; case .mem: L("Memori"); case .pid: "PID" } }
    }

    enum SvcFilter: String, CaseIterable, Identifiable {
        case all, running, failed, boot
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: L("Semua")
            case .running: L("Berjalan")
            case .failed: L("Gagal")
            case .boot: L("Saat boot")
            }
        }
    }

    var targetId: String?
    var system: AdminSystem?
    var connecting = false
    var error: String?
    var tab: Tab = .processes

    var processes: [ServerProcess] = []
    var procQuery = ""
    var procSort: ProcSort = .cpu
    var services: [ServiceUnit] = []
    var svcQuery = ""
    var svcFilter: SvcFilter = .all
    var selectedService: String?
    var serviceStatus: String?
    var cron: [CronLine] = []
    var cronLoaded = false
    var sources: [LogSource] = []
    var logSource = ""
    var logUnit = ""
    var logPriority = ""
    var logLines: UInt32 = 500
    var logText: [String] = []
    var logQuery = ""
    var follow = true
    var logViaSudo = false
    var busy: Set<String> = []

    @ObservationIgnored private var admin: ServerAdmin?
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var logCursor = ""
    @ObservationIgnored private var tick = 0

    static let maxLogLines = 5000

    var connected: Bool { admin != nil && system != nil }

    func select(_ id: String?, model: AppModel) async {
        generation += 1
        let gen = generation
        let old = admin
        admin = nil
        Task { await old?.close() }
        withAnimation(.zterm) {
            targetId = id; system = nil; error = nil
            processes = []; services = []; cron = []; cronLoaded = false; sources = []; logText = []
            selectedService = nil; serviceStatus = nil; logSource = ""; logUnit = ""; logCursor = ""
        }
        guard let id else { return }
        guard let target = model.sshTarget(forId: id) else { error = L("Host tidak ditemukan"); return }
        connecting = true
        do {
            let a = try await ServerAdmin.connect(target: target)
            guard gen == generation else { await a.close(); return }
            let sys = try await a.system()
            guard gen == generation else { await a.close(); return }
            admin = a
            withAnimation(.zterm) { system = sys; connecting = false }
            await load()
        } catch {
            guard gen == generation else { return }
            withAnimation(.zterm) { self.error = error.ztermMessage; connecting = false }
        }
    }

    /// Muat isi tab yang sedang tampil.
    func load() async {
        guard let a = admin else { return }
        do {
            switch tab {
            case .processes:
                processes = try await a.processes()
            case .services:
                guard system?.systemd == true else { return }
                services = try await a.services()
                if let s = selectedService { await loadStatus(s) }
            case .cron:
                guard system?.crontab == true else { return }
                cron = try await a.cronList()
                cronLoaded = true
            case .logs:
                if sources.isEmpty {
                    sources = try await a.logSources()
                    if logSource.isEmpty { logSource = sources.first?.id ?? "" }
                }
                if system?.systemd == true, services.isEmpty { services = (try? await a.services()) ?? [] }
                await reloadLog()
            }
            error = nil
        } catch {
            self.error = error.ztermMessage
        }
    }

    func startPolling() {
        poller?.cancel()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled, self.connected else { continue }
                self.tick += 1
                switch self.tab {
                case .processes where self.tick % 2 == 0: if let a = self.admin, let p = try? await a.processes() { self.processes = p }
                case .services where self.tick % 3 == 0: if let a = self.admin, let s = try? await a.services() { self.services = s }
                case .logs where self.follow: await self.appendLog()
                default: break
                }
            }
        }
    }

    func stopPolling() { poller?.cancel(); poller = nil }

    // MARK: Proses

    var filteredProcesses: [ServerProcess] {
        let q = procQuery.trimmingCharacters(in: .whitespaces).lowercased()
        let list = q.isEmpty ? processes : processes.filter { "\($0.pid) \($0.user) \($0.command)".lowercased().contains(q) }
        switch procSort {
        case .cpu: return list
        case .mem: return list.sorted { $0.rssBytes > $1.rssBytes }
        case .pid: return list.sorted { $0.pid < $1.pid }
        }
    }

    func kill(_ p: ServerProcess, force: Bool, model: AppModel) async {
        guard let a = admin else { return }
        busy.insert("pid:\(p.pid)")
        defer { busy.remove("pid:\(p.pid)") }
        do {
            try await a.kill(pid: p.pid, force: force)
            model.flash(force ? L("Proses {} dihentikan paksa", p.pid) : L("Sinyal berhenti dikirim ke proses {}", p.pid))
            try? await Task.sleep(for: .milliseconds(400))
            processes = (try? await a.processes()) ?? processes
        } catch {
            model.flash(error.ztermMessage)
        }
    }

    // MARK: Service

    var filteredServices: [ServiceUnit] {
        let q = svcQuery.trimmingCharacters(in: .whitespaces).lowercased()
        return services.filter { s in
            switch svcFilter {
            case .all: true
            case .running: s.active == "active"
            case .failed: s.active == "failed"
            case .boot: s.enabled == "enabled"
            }
        }.filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.description.lowercased().contains(q) }
    }

    func loadStatus(_ name: String) async {
        guard let a = admin else { return }
        let s = try? await a.serviceStatus(name: name)
        if selectedService == name { serviceStatus = s }
    }

    func chooseService(_ name: String?) {
        withAnimation(.ztermSnappy) { selectedService = name; serviceStatus = nil }
        if let name { Task { await loadStatus(name) } }
    }

    func serviceAction(_ name: String, _ action: String, model: AppModel) async {
        guard let a = admin else { return }
        busy.insert("svc:\(name)")
        defer { busy.remove("svc:\(name)") }
        do {
            try await a.serviceAction(name: name, action: action)
            let done = ["start": "{} dinyalakan", "stop": "{} dihentikan", "restart": "{} dimulai ulang", "reload": "{} dimuat ulang",
                        "enable": "{} aktif saat boot", "disable": "{} tidak aktif saat boot"][action]
            model.flash(done.map { L($0, name) } ?? "\(name) \(action)")
        } catch {
            model.flash(error.ztermMessage)
        }
        services = (try? await a.services()) ?? services
        await loadStatus(name)
    }

    func showLogs(unit: String) {
        withAnimation(.ztermSnappy) {
            tab = .logs
            if sources.contains(where: { $0.isJournal }) || system?.journal == true { logSource = "journal" }
            logUnit = unit
        }
        Task { await load() }
    }

    // MARK: Cron

    var jobs: [(index: Int, job: CronJob)] {
        cron.enumerated().compactMap { i, l in l.job.map { (i, $0) } }
    }

    /// Simpan perubahan (tambah, ubah, hapus, aktif/nonaktif) — seluruh crontab ditulis ulang.
    func saveCron(_ lines: [CronLine], model: AppModel, message: String) async {
        guard let a = admin else { return }
        busy.insert("cron")
        defer { busy.remove("cron") }
        do {
            try await a.cronSave(lines: lines)
            cron = try await a.cronList()
            model.flash(message)
        } catch {
            model.flash(error.ztermMessage)
        }
    }

    func setJob(at index: Int?, _ job: CronJob, model: AppModel) async {
        var lines = cron
        if let index { lines[index].job = job } else { lines.append(CronLine(raw: "", job: job)) }
        await saveCron(lines, model: model, message: index == nil ? L("Jadwal ditambahkan") : L("Jadwal disimpan"))
    }

    func deleteJob(at index: Int, model: AppModel) async {
        var lines = cron
        lines.remove(at: index)
        await saveCron(lines, model: model, message: L("Jadwal dihapus"))
    }

    // MARK: Log

    func reloadLog() async {
        guard let a = admin, !logSource.isEmpty else { return }
        logCursor = ""
        do {
            let c = try await a.readLog(source: logSource, lines: logLines, cursor: "", unit: logSource == "journal" ? logUnit : "",
                                        priority: logSource == "journal" ? logPriority : "")
            logCursor = c.cursor
            logViaSudo = c.viaSudo
            logText = Self.split(c.text)
            error = nil
        } catch {
            logText = []
            self.error = error.ztermMessage
        }
    }

    private func appendLog() async {
        guard let a = admin, !logSource.isEmpty, !logCursor.isEmpty else { return }
        let source = logSource
        guard let c = try? await a.readLog(source: source, lines: logLines, cursor: logCursor, unit: source == "journal" ? logUnit : "",
                                           priority: source == "journal" ? logPriority : ""),
              source == logSource else { return }
        logCursor = c.cursor
        let new = Self.split(c.text)
        guard !new.isEmpty else { return }
        logText.append(contentsOf: new)
        if logText.count > Self.maxLogLines { logText.removeFirst(logText.count - Self.maxLogLines) }
    }

    private static func split(_ s: String) -> [String] {
        var lines = s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    func close() {
        stopPolling()
        let a = admin
        admin = nil
        Task { await a?.close() }
    }
}

// MARK: - View

struct AdminView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var admin = model.admin
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: L("Kelola Server"), subtitle: L("Proses, service, cron, dan log server — tanpa hafal perintah")) {
                    if admin.connected {
                        Button { Task { await admin.load() } } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(SecondaryButtonStyle()).help(L("Muat ulang"))
                    }
                }
                if !model.hosts.isEmpty {
                    HStack(spacing: 12) {
                        HostPicker()
                        if let s = admin.system { SystemBadge(system: s) }
                        if admin.connecting { ProgressView().controlSize(.small) }
                        Spacer()
                        TabPills(tab: $admin.tab)
                    }
                }
            }
            .padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 16)

            if model.hosts.isEmpty {
                EmptyState(icon: "wrench.and.screwdriver", title: L("Belum ada server"), text: L("Tambahkan host di menu Hosts, lalu kelola proses, service, cron, dan log-nya dari sini."))
                Spacer()
            } else if admin.targetId == nil {
                EmptyState(icon: "server.rack", title: L("Pilih server"), text: L("Pilih server di atas untuk melihat proses, service systemd, crontab, dan log-nya."))
                Spacer()
            } else if let e = admin.error, !admin.connected {
                VStack(spacing: 12) {
                    Image(systemName: "bolt.horizontal.circle").font(.largeTitle).foregroundStyle(Color(hex: "#F0616D"))
                    Text(e).foregroundStyle(.secondary).multilineTextAlignment(.center).textSelection(.enabled).frame(maxWidth: 460)
                    Button(L("Coba lagi")) { Task { await admin.select(admin.targetId, model: model) } }.buttonStyle(SecondaryButtonStyle())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if admin.connected {
                if let s = admin.system, !s.isRoot, !s.sudo {
                    Label(L("User {} tanpa sudo: bisa melihat, tapi aksi yang butuh root (service, proses user lain, log sistem) akan ditolak.", s.user), systemImage: "lock.trianglebadge.exclamationmark")
                        .font(.caption).foregroundStyle(Color(hex: "#F2A65A"))
                        .padding(.horizontal, 28).padding(.bottom, 10)
                }
                Group {
                    switch admin.tab {
                    case .processes: ProcessesTab()
                    case .services: ServicesTab()
                    case .cron: CronTab()
                    case .logs: LogsTab()
                    }
                }
                .padding(.horizontal, 28).padding(.bottom, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                ProgressView(L("Menghubungkan…")).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .animation(.zterm, value: admin.tab)
        .onChange(of: admin.tab) { Task { await admin.load() } }
        .onAppear {
            admin.startPolling()
            if admin.targetId == nil, let first = model.hosts.first(where: { model.dashboard.tiles[$0.id]?.state == .online }) ?? model.hosts.first {
                Task { await admin.select(first.id, model: model) }
            }
        }
        .onDisappear { admin.stopPolling() }
    }
}

private struct HostPicker: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let admin = model.admin
        let current = model.host(id: admin.targetId)
        Menu {
            ForEach(model.hosts) { h in
                Button { Task { await admin.select(h.id, model: model) } } label: { Label(h.title, systemImage: "server.rack") }
            }
        } label: {
            HStack(spacing: 7) {
                Circle().fill(Color(hex: current?.color ?? "#94A3B8")).frame(width: 8, height: 8)
                Text(current?.title ?? L("Pilih server")).font(.system(size: 13, weight: .semibold))
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Theme.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.cardStroke))
        .fixedSize()
    }
}

private struct SystemBadge: View {
    let system: AdminSystem
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: system.isRoot ? "crown.fill" : system.sudo ? "key.fill" : "person.fill")
                .foregroundStyle(system.isRoot || system.sudo ? Color(hex: "#4ADE80") : Color(hex: "#F2A65A"))
            Text(verbatim: "\(system.user) · \(system.isRoot ? "root" : system.sudo ? "sudo" : L("tanpa sudo"))")
            if !system.os.isEmpty { Text("· \(system.os)").foregroundStyle(.secondary) }
        }
        .font(.system(size: 11.5))
        .lineLimit(1)
    }
}

private struct TabPills: View {
    @Binding var tab: AdminModel.Tab
    var body: some View {
        HStack(spacing: 2) {
            ForEach(AdminModel.Tab.allCases) { t in
                Button { tab = t } label: {
                    Label(t.title, systemImage: t.icon)
                        .font(.system(size: 12.5, weight: tab == t ? .semibold : .regular))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(tab == t ? Theme.ink.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(tab == t ? .primary : .secondary)
            }
        }
        .padding(3)
        .background(Theme.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: Proses

private struct ProcessesTab: View {
    @Environment(AppModel.self) private var model
    @State private var confirm: (ServerProcess, Bool)?

    var body: some View {
        @Bindable var admin = model.admin
        let list = admin.filteredProcesses
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                SearchField(text: $admin.procQuery, prompt: L("Cari PID, user, perintah…")).frame(maxWidth: 300)
                Picker(L("Urut"), selection: $admin.procSort) {
                    ForEach(AdminModel.ProcSort.allCases) { s in Text(s.title).tag(s) }
                }
                .pickerStyle(.segmented).fixedSize()
                Spacer()
                Text(L("{} proses · diperbarui tiap 4 detik", list.count)).font(.caption).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                row(header: true, pid: "PID", user: "USER", cpu: "CPU", mem: L("MEMORI"), time: L("WAKTU"), cmd: L("PERINTAH"))
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(list, id: \.pid) { p in ProcessRow(process: p) { force in confirm = (p, force) } }
                    }
                }
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.cardStroke))
        }
        .confirmationDialog(confirm.map { $0.1 ? L("Hentikan paksa proses {}?", $0.0.pid) : L("Hentikan proses {}?", $0.0.pid) } ?? "",
                            isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            if let (p, force) = confirm {
                Button(force ? L("Kill -9") : L("Hentikan"), role: .destructive) { Task { await admin.kill(p, force: force, model: model) } }
            }
        } message: {
            if let (p, force) = confirm {
                Text("\(p.command)\n\n" + (force ? L("SIGKILL: proses langsung dimatikan tanpa sempat menyimpan data.") : L("SIGTERM: proses diminta berhenti dengan rapi.")))
            }
        }
    }

    fileprivate func row(header: Bool, pid: String, user: String, cpu: String, mem: String, time: String, cmd: String) -> some View {
        HStack(spacing: 10) {
            Text(pid).frame(width: 56, alignment: .trailing)
            Text(user).frame(width: 90, alignment: .leading)
            Text(cpu).frame(width: 64, alignment: .trailing)
            Text(mem).frame(width: 80, alignment: .trailing)
            Text(time).frame(width: 86, alignment: .trailing)
            Text(cmd).frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: 60)
        }
        .font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

private struct ProcessRow: View {
    @Environment(AppModel.self) private var model
    let process: ServerProcess
    let onKill: (Bool) -> Void
    @State private var hover = false

    var body: some View {
        let p = process
        let busy = model.admin.busy.contains("pid:\(p.pid)")
        HStack(spacing: 10) {
            Text(verbatim: "\(p.pid)").frame(width: 56, alignment: .trailing).foregroundStyle(.secondary)
            Text(p.user).lineLimit(1).frame(width: 90, alignment: .leading)
            Text(String(format: "%.1f%%", p.cpuPercent)).frame(width: 64, alignment: .trailing)
                .foregroundStyle(p.cpuPercent >= 50 ? Color(hex: "#F0616D") : p.cpuPercent >= 15 ? Color(hex: "#F2A65A") : .primary)
            Text(ByteCountFormatter.string(fromByteCount: Int64(p.rssBytes), countStyle: .memory)).frame(width: 80, alignment: .trailing)
            Text(p.elapsed).frame(width: 86, alignment: .trailing).foregroundStyle(.secondary)
            Text(p.command).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading).help(p.command)
            HStack(spacing: 4) {
                if busy { ProgressView().controlSize(.mini) }
                else if hover {
                    IconButton(symbol: "stop.circle", help: L("Hentikan (SIGTERM)")) { onKill(false) }
                    IconButton(symbol: "xmark.octagon", help: L("Hentikan paksa (kill -9)"), tint: Color(hex: "#F0616D")) { onKill(true) }
                }
            }
            .frame(width: 60, alignment: .trailing)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.horizontal, 12).frame(height: 32)
        .background(hover ? Theme.ink.opacity(0.05) : .clear)
        .onHover { hover = $0 }
    }
}

// MARK: Service

private struct ServicesTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var admin = model.admin
        if admin.system?.systemd != true {
            EmptyState(icon: "gearshape.2", title: L("Tanpa systemd"), text: L("Server ini tidak memakai systemd, jadi daftar service tidak tersedia."))
        } else {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Picker("", selection: $admin.svcFilter) {
                            ForEach(AdminModel.SvcFilter.allCases) { f in Text(f.title).tag(f) }
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                        SearchField(text: $admin.svcQuery, prompt: L("Cari service"))
                    }
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(admin.filteredServices, id: \.name) { s in ServiceRow(service: s) }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                if let name = admin.selectedService, let s = admin.services.first(where: { $0.name == name }) {
                    ServiceDetail(service: s)
                        .frame(width: 400)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
    }
}

private func serviceColor(_ s: ServiceUnit) -> Color {
    switch s.active {
    case "active": s.sub == "running" ? Color(hex: "#4ADE80") : Color(hex: "#5B9CF5")
    case "failed": Color(hex: "#F0616D")
    case "activating", "deactivating", "reloading": Color(hex: "#F2A65A")
    default: Color.secondary.opacity(0.5)
    }
}

private struct ServiceRow: View {
    @Environment(AppModel.self) private var model
    let service: ServiceUnit
    @State private var hover = false

    var body: some View {
        let s = service
        let selected = model.admin.selectedService == s.name
        Button { model.admin.chooseService(selected ? nil : s.name) } label: {
            HStack(spacing: 10) {
                Circle().fill(serviceColor(s)).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.name).font(.system(size: 12.5, weight: .semibold, design: .monospaced)).lineLimit(1)
                    if !s.description.isEmpty { Text(s.description).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 6)
                if s.enabled == "enabled" { Badge(text: "BOOT", color: Theme.accent2) }
                Text(s.active == "active" ? s.sub : s.active).font(.system(size: 11)).foregroundStyle(serviceColor(s))
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Theme.accent.opacity(0.12) : hover ? Theme.ink.opacity(0.05) : Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Theme.accent.opacity(0.5) : Theme.cardStroke))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct ServiceDetail: View {
    @Environment(AppModel.self) private var model
    let service: ServiceUnit
    @State private var confirmStop: String?

    var body: some View {
        let admin = model.admin
        let s = service
        let busy = admin.busy.contains("svc:\(s.name)")
        let running = s.active == "active" || s.active == "activating"
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle().fill(serviceColor(s)).frame(width: 10, height: 10)
                Text(s.name).font(.system(size: 15, weight: .bold, design: .monospaced)).lineLimit(1)
                Spacer()
                IconButton(symbol: "xmark", help: L("Tutup")) { admin.chooseService(nil) }
            }
            if !s.description.isEmpty { Text(s.description).font(.callout).foregroundStyle(.secondary) }
            HStack(spacing: 6) {
                Badge(text: s.active.uppercased(), color: serviceColor(s))
                Badge(text: s.sub.uppercased(), color: .secondary)
                if !s.enabled.isEmpty { Badge(text: s.enabled == "enabled" ? L("AKTIF SAAT BOOT") : s.enabled.uppercased(), color: s.enabled == "enabled" ? Theme.accent2 : .secondary) }
            }
            HStack(spacing: 8) {
                if running {
                    action(L("Stop"), "stop.fill", "stop", danger: true)
                    action(L("Restart"), "arrow.clockwise", "restart")
                    action(L("Reload"), "arrow.triangle.2.circlepath", "reload")
                } else {
                    action(L("Start"), "play.fill", "start", primary: true)
                }
                if busy { ProgressView().controlSize(.small) }
            }
            .disabled(busy)
            HStack(spacing: 8) {
                if s.enabled == "enabled" { action(L("Jangan jalan saat boot"), "power", "disable") }
                else if s.enabled == "disabled" { action(L("Jalankan saat boot"), "power", "enable") }
                Button { admin.showLogs(unit: s.name) } label: { Label(L("Lihat log"), systemImage: "doc.text.magnifyingglass") }
                    .buttonStyle(SecondaryButtonStyle())
            }
            .disabled(busy)
            Text("STATUS").font(.system(size: 10.5, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
            ScrollView([.vertical, .horizontal]) {
                Text(admin.serviceStatus ?? L("Memuat…"))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(10)
            }
            .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.cardStroke))
        .confirmationDialog(L("Hentikan {}?", confirmStop ?? ""), isPresented: Binding(get: { confirmStop != nil }, set: { if !$0 { confirmStop = nil } })) {
            Button(L("Hentikan"), role: .destructive) { run("stop") }
        } message: {
            Text(L("Ini service SSH. Bila dihentikan, kamu bisa tidak bisa login lagi ke server ini sampai dinyalakan dari konsol."))
        }
    }

    private func run(_ action: String) {
        Task { await model.admin.serviceAction(service.name, action, model: model) }
    }

    @ViewBuilder private func action(_ title: String, _ icon: String, _ action: String, primary: Bool = false, danger: Bool = false) -> some View {
        let b = Button {
            if action == "stop", ["ssh", "sshd"].contains(service.name) { confirmStop = service.name } else { run(action) }
        } label: { Label(title, systemImage: icon) }
        if primary { b.buttonStyle(PrimaryButtonStyle()) } else { b.buttonStyle(SecondaryButtonStyle()).foregroundStyle(danger ? Color(hex: "#F0616D") : .primary) }
    }
}

// MARK: Cron

private struct CronTab: View {
    @Environment(AppModel.self) private var model
    @State private var editing: CronEdit?

    var body: some View {
        let admin = model.admin
        if admin.system?.crontab != true {
            EmptyState(icon: "calendar.badge.clock", title: L("crontab tidak tersedia"), text: L("Pasang paket cron di server ini (mis. apt install cron) untuk memakai jadwal."))
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(L("Jadwal milik user {}", admin.system?.user ?? "")).font(.callout).foregroundStyle(.secondary)
                    if admin.busy.contains("cron") { ProgressView().controlSize(.small) }
                    Spacer()
                    Button { editing = CronEdit(index: nil, job: CronJob(schedule: "0 2 * * *", command: "", enabled: true)) } label: {
                        Label(L("Tambah jadwal"), systemImage: "plus")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
                if admin.cronLoaded && admin.jobs.isEmpty {
                    EmptyState(icon: "calendar.badge.clock", title: L("Belum ada jadwal"), text: L("Tambahkan jadwal untuk menjalankan perintah otomatis, mis. backup tiap malam."))
                }
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(admin.jobs, id: \.index) { item in
                            CronRow(index: item.index, job: item.job) { editing = CronEdit(index: item.index, job: item.job) }
                        }
                    }
                }
            }
            .sheet(item: $editing) { e in CronEditor(edit: e) }
        }
    }
}

struct CronEdit: Identifiable {
    let id = UUID()
    let index: Int?
    var job: CronJob
}

private struct CronRow: View {
    @Environment(AppModel.self) private var model
    let index: Int
    let job: CronJob
    let onEdit: () -> Void
    @State private var hover = false
    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 14) {
            Toggle("", isOn: Binding(get: { job.enabled }, set: { on in
                var j = job; j.enabled = on
                Task { await model.admin.setJob(at: index, j, model: model) }
            }))
            .toggleStyle(.switch).labelsHidden().controlSize(.small)
            .help(job.enabled ? L("Nonaktifkan (baris dijadikan komentar)") : L("Aktifkan"))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(Lmsg(cronDescribe(schedule: job.schedule))).font(.system(size: 13, weight: .semibold))
                    Text(job.schedule).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
                Text(job.command).font(.system(size: 12, design: .monospaced)).lineLimit(2).foregroundStyle(job.enabled ? .primary : .secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            if hover {
                IconButton(symbol: "pencil", help: L("Ubah")) { onEdit() }
                IconButton(symbol: "trash", help: L("Hapus"), tint: Color(hex: "#F0616D")) { confirmDelete = true }
            }
        }
        .padding(12)
        .opacity(job.enabled ? 1 : 0.6)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.cardStroke))
        .onHover { hover = $0 }
        .contextMenu {
            Button(L("Ubah")) { onEdit() }
            Button(L("Hapus"), role: .destructive) { confirmDelete = true }
        }
        .confirmationDialog(L("Hapus jadwal ini?"), isPresented: $confirmDelete) {
            Button(L("Hapus"), role: .destructive) { Task { await model.admin.deleteJob(at: index, model: model) } }
        } message: { Text(job.command) }
    }
}

private struct CronEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var edit: CronEdit

    private static let presets: [(String, String)] = [
        (L("Tiap menit"), "* * * * *"), (L("Tiap 5 menit"), "*/5 * * * *"), (L("Tiap 15 menit"), "*/15 * * * *"),
        (L("Tiap jam"), "0 * * * *"), (L("Tiap hari 02.00"), "0 2 * * *"), (L("Senin–Jumat 08.00"), "0 8 * * 1-5"),
        (L("Tiap Minggu"), "0 3 * * 0"), (L("Tiap tanggal 1"), "0 3 1 * *"), (L("Saat server menyala"), "@reboot"),
    ]

    var body: some View {
        let valid = cronValid(schedule: edit.job.schedule)
        let canSave = valid && !edit.job.command.trimmingCharacters(in: .whitespaces).isEmpty && !edit.job.command.contains("\n")
        FormSheet(title: edit.index == nil ? L("Tambah jadwal") : L("Ubah jadwal"), canSave: canSave, onSave: {
            Task { await model.admin.setJob(at: edit.index, edit.job, model: model) }
        }) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Kapan")).font(.callout.weight(.semibold))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(Self.presets, id: \.1) { p in
                        Button(p.0) { edit.job.schedule = p.1 }
                            .buttonStyle(.plain)
                            .font(.system(size: 12))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .frame(maxWidth: .infinity)
                            .background(edit.job.schedule == p.1 ? Theme.accent.opacity(0.18) : Theme.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                TextField(L("menit jam tanggal bulan hari"), text: $edit.job.schedule)
                    .textFieldStyle(.roundedBorder).font(.system(size: 13, design: .monospaced))
                Label(valid ? Lmsg(cronDescribe(schedule: edit.job.schedule)) : L("Format: menit jam tanggal bulan hari — mis. 30 2 * * 1-5"), systemImage: valid ? "clock" : "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(valid ? Theme.accent : Color(hex: "#F2A65A"))
                Text(L("Perintah")).font(.callout.weight(.semibold)).padding(.top, 6)
                TextField(L("mis. /usr/local/bin/backup.sh >> /var/log/backup.log 2>&1"), text: $edit.job.command)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12.5, design: .monospaced))
                Toggle(L("Aktif"), isOn: $edit.job.enabled)
            }
        }
        .frame(width: 540)
    }
}

// MARK: Log

private struct LogsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var admin = model.admin
        let q = admin.logQuery.trimmingCharacters(in: .whitespaces).lowercased()
        let lines = q.isEmpty ? admin.logText : admin.logText.filter { $0.lowercased().contains(q) }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Picker(L("Sumber"), selection: $admin.logSource) {
                    ForEach(admin.sources, id: \.id) { s in
                        Text(s.isJournal ? s.title : "\(s.title)  ·  \(ByteCountFormatter.string(fromByteCount: Int64(s.sizeBytes), countStyle: .file))").tag(s.id)
                    }
                }
                .frame(maxWidth: 320)
                if admin.logSource == "journal" {
                    Picker(L("Service"), selection: $admin.logUnit) {
                        Text(L("Semua")).tag("")
                        ForEach(admin.services.filter { $0.active == "active" || $0.active == "failed" }, id: \.name) { s in Text(s.name).tag(s.name) }
                    }
                    .frame(maxWidth: 220)
                    Picker(L("Level"), selection: $admin.logPriority) {
                        Text(L("Semua")).tag("")
                        Text(L("Warning ke atas")).tag("warning")
                        Text(L("Error ke atas")).tag("err")
                    }
                    .fixedSize()
                }
                Picker(L("Baris"), selection: $admin.logLines) {
                    Text("200").tag(UInt32(200)); Text("500").tag(UInt32(500)); Text("2.000").tag(UInt32(2000)); Text("5.000").tag(UInt32(5000))
                }
                .fixedSize()
                Spacer()
            }
            HStack(spacing: 10) {
                SearchField(text: $admin.logQuery, prompt: L("Saring baris…")).frame(maxWidth: 300)
                Toggle(isOn: $admin.follow) { Label(L("Ikuti"), systemImage: "arrow.down.to.line") }
                    .toggleStyle(.button)
                    .help(L("Ambil baris baru tiap 2 detik"))
                if admin.logViaSudo { Badge(text: "SUDO", color: Color(hex: "#F2A65A")) }
                Spacer()
                Text(q.isEmpty ? L("{} baris", lines.count) : L("{} dari {} baris", lines.count, admin.logText.count)).font(.caption).foregroundStyle(.secondary)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
                    model.flash(L("{} baris log disalin", lines.count))
                } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(SecondaryButtonStyle()).help(L("Salin"))
            }
            if admin.sources.isEmpty {
                Text(L("Tidak ada journal atau file log umum yang bisa dibaca di server ini.")).foregroundStyle(.secondary).padding(.top, 30)
                    .frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView([.vertical, .horizontal]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                                Text(l.isEmpty ? " " : l)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundStyle(tint(l))
                                    .textSelection(.enabled)
                                    .fixedSize()
                                    .id(i)
                            }
                        }
                        .padding(10)
                    }
                    .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                    .onChange(of: lines.count) { if admin.follow, lines.count > 0 { proxy.scrollTo(lines.count - 1, anchor: .bottom) } }
                }
            }
        }
        .onChange(of: admin.logSource) { Task { await admin.reloadLog() } }
        .onChange(of: admin.logUnit) { Task { await admin.reloadLog() } }
        .onChange(of: admin.logPriority) { Task { await admin.reloadLog() } }
        .onChange(of: admin.logLines) { Task { await admin.reloadLog() } }
    }

    private func tint(_ l: String) -> Color {
        let s = l.lowercased()
        if s.contains("error") || s.contains("fail") || s.contains("crit") || s.contains("fatal") || s.contains("panic") || s.contains("[emerg]") {
            return Color(hex: "#F0616D")
        }
        if s.contains("warn") { return Color(hex: "#F2A65A") }
        return Color.primary.opacity(0.88)
    }
}
