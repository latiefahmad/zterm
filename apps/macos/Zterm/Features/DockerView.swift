import SwiftUI

// MARK: - Model

/// Docker: container, volume, image, network — di Mac ini atau server lewat SSH (core: DockerClient).
/// Tampilan meniru OrbStack: sidebar kecil, daftar ringkas per proyek Compose, panel detail di kanan.
@MainActor
@Observable
final class DockerModel {
    enum Tab: String, CaseIterable { case containers, volumes, images, networks }

    /// nil = Docker di Mac ini; selain itu id host.
    private(set) var targetId: String?
    private(set) var connected = false
    var info: DockerInfo?
    var containers: [DockerContainer] = []
    var stats: [String: DockerStat] = [:]
    var images: [DockerImage] = []
    var volumes: [DockerVolume] = []
    var networks: [DockerNetwork] = []
    var projects: [ComposeProject] = []
    var tab: Tab = .containers
    var query = ""
    var loading = false
    var error: String?
    var busy: Set<String> = []
    /// Proyek Compose yang dilipat.
    var collapsed: Set<String> = []
    var selectedId: String?
    var detail: DockerDetail?

    @ObservationIgnored private var client: DockerClient?
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    /// Hostname server (untuk link port); nil = localhost.
    @ObservationIgnored private var hostname: String?

    var selected: DockerContainer? { containers.first { $0.id == selectedId } }

    func select(_ id: String?, model: AppModel) async {
        generation += 1
        let gen = generation
        let old = client
        client = nil
        hostname = id.flatMap { model.host(id: $0)?.hostname }
        withAnimation(.zterm) {
            targetId = id; connected = false; info = nil; error = nil; selectedId = nil; detail = nil
            containers = []; images = []; volumes = []; networks = []; projects = []; stats = [:]
            loading = true
        }
        Task { await old?.close() }
        do {
            let c: DockerClient
            if let id {
                guard let t = model.sshTarget(forId: id) else { throw CoreError.NotFound }
                c = try await DockerClient.connect(target: t)
            } else {
                c = try DockerClient.local()
            }
            guard gen == generation else { await c.close(); return }
            client = c
            connected = true
            await refresh()
        } catch {
            guard gen == generation else { return }
            withAnimation(.zterm) { self.error = error.ztermMessage; loading = false }
        }
    }

    func refresh() async {
        guard let client else { return }
        loading = true
        do {
            async let i = client.info()
            async let c = client.containers()
            async let p = client.composeProjects()
            let (ii, cc, pp) = try await (i, c, p)
            withAnimation(.zterm) { info = ii; containers = cc; projects = pp; error = nil }
            async let im = client.images()
            async let v = client.volumes()
            async let n = client.networks()
            let (imm, vv, nn) = try await (im, v, n)
            withAnimation(.zterm) { images = imm; volumes = vv; networks = nn }
        } catch {
            withAnimation(.zterm) { self.error = error.ztermMessage }
        }
        loading = false
        await refreshStats()
        if let id = selectedId { await loadDetail(id) }
    }

    func refreshStats() async {
        guard let client, containers.contains(where: { $0.state == "running" }) else { return }
        if let s = try? await client.stats() {
            stats = Dictionary(s.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    func startPolling() {
        poller?.cancel()
        poller = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard let self, self.connected, !Task.isCancelled else { continue }
                tick += 1
                if tick % 3 == 0, let c = try? await self.client?.containers() { withAnimation(.zterm) { self.containers = c } }
                await self.refreshStats()
            }
        }
    }

    func stopPolling() { poller?.cancel() }

    func choose(_ c: DockerContainer?) {
        withAnimation(.ztermSnappy) { selectedId = c?.id; if c == nil { detail = nil } }
        if let c { Task { await loadDetail(c.id) } }
    }

    func loadDetail(_ id: String) async {
        guard let client, let d = try? await client.inspect(id: id), selectedId == id else { return }
        detail = d
    }

    private func run(_ key: String, _ op: @escaping (DockerClient) async throws -> Void) async {
        guard let client, !busy.contains(key) else { return }
        busy.insert(key)
        do { try await op(client); error = nil } catch { withAnimation(.zterm) { self.error = error.ztermMessage } }
        busy.remove(key)
        await refresh()
    }

    func action(_ c: DockerContainer, _ action: String) async {
        if action == "rm" && selectedId == c.id { choose(nil) }
        await run(c.id) { try await $0.containerAction(id: c.id, action: action) }
    }

    func compose(_ name: String, _ action: String) async {
        let files = projects.first { $0.name == name }?.configFiles ?? ""
        await run("compose:\(name)") { _ = try await $0.composeAction(project: name, configFiles: files, action: action) }
    }

    func removeImage(_ i: DockerImage) async { await run("img:\(i.id)") { try await $0.removeImage(id: i.id) } }
    func removeVolume(_ v: DockerVolume) async { await run("vol:\(v.name)") { try await $0.removeVolume(name: v.name) } }

    func logs(_ id: String, tail: UInt32) async -> String {
        guard let client else { return "" }
        do { return try await client.logs(id: id, tail: tail) } catch { return error.ztermMessage }
    }

    func execCommand(_ id: String) -> String? { try? client?.execCommand(id: id) }

    /// Link port di browser: localhost untuk Mac ini, hostname server untuk host SSH.
    func url(_ port: UInt16) -> URL? { URL(string: "http://\(hostname ?? "localhost"):\(port)") }

    var filtered: [DockerContainer] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return containers }
        return containers.filter { [$0.name, $0.image, $0.project, $0.ports].contains { $0.lowercased().contains(q) } }
    }

    var groups: [(String, [DockerContainer])] {
        let d = Dictionary(grouping: filtered, by: \.project)
        return d.keys.sorted { a, b in a.isEmpty ? false : (b.isEmpty ? true : a < b) }.map { ($0, d[$0]!) }
    }

    func count(_ t: Tab) -> Int {
        switch t {
        case .containers: containers.count
        case .volumes: volumes.count
        case .images: images.count
        case .networks: networks.count
        }
    }
}

extension DockerContainer: @retroactive Identifiable {}

// MARK: - Halaman

private let dockerBlue = Color(hex: "#2496ED")
private let runningGreen = Color(hex: "#4ADE80")

struct DockerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let docker = model.docker
        HStack(spacing: 0) {
            DockerSidebar()
                .frame(width: 210)
            Divider().opacity(0.6)
            VStack(spacing: 0) {
                ListHeader()
                Divider().opacity(0.5)
                if let e = docker.error {
                    ErrorBanner(text: e).padding(14)
                }
                ScrollView {
                    Group {
                        if docker.info == nil {
                            if docker.loading {
                                HStack(spacing: 10) { ProgressView().controlSize(.small); Text(L("Menghubungkan ke Docker…")).foregroundStyle(.secondary) }
                                    .frame(maxWidth: .infinity).padding(.top, 80)
                            }
                        } else {
                            switch docker.tab {
                            case .containers: ContainerList()
                            case .volumes: VolumeList()
                            case .images: ImageList()
                            case .networks: NetworkList()
                            }
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                }
            }
            .frame(maxWidth: .infinity)
            if docker.tab == .containers, let c = docker.selected {
                Divider().opacity(0.6)
                ContainerDetail(container: c)
                    .frame(width: 380)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.ztermSnappy, value: docker.selectedId)
        .animation(.zterm, value: docker.tab)
        .task {
            if !docker.connected && !docker.loading { await docker.select(docker.targetId, model: model) }
            docker.startPolling()
        }
        .onDisappear { docker.stopPolling() }
    }
}

private struct ErrorBanner: View {
    @Environment(AppModel.self) private var model
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(L("Coba lagi")) { Task { await model.docker.select(model.docker.targetId, model: model) } }.buttonStyle(SecondaryButtonStyle())
        }
        .padding(12)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: Sidebar

private struct DockerSidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let docker = model.docker
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("DOCKER DI")).font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                TargetMenu()
            }
            .padding(.top, 14)
            VStack(spacing: 2) {
                item(.containers, L("Container"), "shippingbox")
                item(.volumes, L("Volume"), "externaldrive")
                item(.images, L("Image"), "square.stack.3d.down.right")
                item(.networks, L("Network"), "point.3.connected.trianglepath.dotted")
            }
            Spacer()
            if let i = docker.info {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Circle().fill(runningGreen).frame(width: 7, height: 7)
                        Text(verbatim: L("Docker {}", i.version)).font(.system(size: 11.5, weight: .semibold))
                    }
                    Text(verbatim: i.os + (i.usesSudo ? L(" · sudo") : "")).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    Text(verbatim: L("{} CPU · {}", i.cpus, ByteCountFormatter.string(fromByteCount: Int64(i.memory), countStyle: .memory)))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(verbatim: L("{} dari {} container berjalan", i.running, i.containers)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 14)
        .background(Theme.ink.opacity(0.018))
    }

    private func item(_ t: DockerModel.Tab, _ title: String, _ icon: String) -> some View {
        let docker = model.docker
        let on = docker.tab == t
        return Button {
            withAnimation(.ztermSnappy) { docker.tab = t }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 13)).frame(width: 18).foregroundStyle(on ? dockerBlue : .secondary)
                Text(title).font(.system(size: 13, weight: on ? .semibold : .regular))
                Spacer()
                if docker.info != nil {
                    Text("\(docker.count(t))").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(on ? dockerBlue.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Pilih Docker: Mac ini atau host tersimpan.
private struct TargetMenu: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let docker = model.docker
        let current = docker.targetId.flatMap { id in model.hosts.first { $0.id == id } }
        Menu {
            Button { Task { await docker.select(nil, model: model) } } label: { Label(L("Mac ini"), systemImage: "laptopcomputer") }
            if !model.hosts.isEmpty {
                Divider()
                ForEach(model.hosts) { h in
                    Button { Task { await docker.select(h.id, model: model) } } label: { Label(h.title, systemImage: "server.rack") }
                }
            }
        } label: {
            Label(current?.title ?? L("Mac ini"), systemImage: current == nil ? "laptopcomputer" : "server.rack")
                .font(.system(size: 12.5, weight: .semibold))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.cardStroke))
        .help(L("Pilih Docker di Mac ini atau di server"))
    }
}

private struct ListHeader: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var docker = model.docker
        HStack(spacing: 10) {
            Text(title).font(.system(size: 20, weight: .bold, design: .rounded))
            if docker.loading && docker.info != nil { ProgressView().controlSize(.small) }
            Spacer()
            if docker.tab == .containers {
                SearchField(text: $docker.query, prompt: L("Cari"))
            }
            Button { Task { await docker.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(SecondaryButtonStyle()).help(L("Muat ulang")).disabled(!docker.connected)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private var title: String {
        switch model.docker.tab {
        case .containers: L("Container")
        case .volumes: L("Volume")
        case .images: L("Image")
        case .networks: L("Network")
        }
    }
}

// MARK: Container

private struct ContainerList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let docker = model.docker
        if docker.containers.isEmpty {
            EmptyState(icon: "shippingbox", title: L("Belum ada container"), text: L("Container dari docker run atau docker compose akan muncul di sini."))
        } else {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(docker.groups, id: \.0) { project, list in
                    if project.isEmpty {
                        ForEach(list) { c in ContainerRow(container: c, indent: false) }
                    } else {
                        ProjectRow(name: project, list: list)
                        if !docker.collapsed.contains(project) || !docker.query.isEmpty {
                            ForEach(list) { c in ContainerRow(container: c, indent: true) }
                        }
                    }
                }
            }
        }
    }
}

/// Baris dengan sorotan hover & tombol yang muncul saat disorot (gaya OrbStack).
private struct HoverRow<Content: View, Actions: View>: View {
    var selected = false
    var action: () -> Void = {}
    @ViewBuilder var content: () -> Content
    @ViewBuilder var actions: () -> Actions
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            content()
            Spacer(minLength: 8)
            HStack(spacing: 2) { actions() }.opacity(hover || selected ? 1 : 0)
        }
        .padding(.horizontal, 10).frame(height: 46)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? dockerBlue.opacity(0.16) : hover ? Theme.ink.opacity(0.05) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: action)
    }
}

private struct StatusIcon: View {
    let state: String
    var size: CGFloat = 30
    var body: some View {
        let running = state == "running"
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(running ? dockerBlue.opacity(0.18) : Theme.ink.opacity(0.06))
            Image(systemName: "shippingbox.fill").font(.system(size: size * 0.45)).foregroundStyle(running ? dockerBlue : .secondary)
            Circle().fill(color).frame(width: size * 0.3, height: size * 0.3)
                .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                .offset(x: size * 0.36, y: size * 0.36)
        }
        .frame(width: size, height: size)
    }
    private var color: Color {
        switch state {
        case "running": runningGreen
        case "paused": .orange
        case "restarting": .yellow
        default: Color.gray
        }
    }
}

private struct ProjectRow: View {
    @Environment(AppModel.self) private var model
    let name: String
    let list: [DockerContainer]

    var body: some View {
        let docker = model.docker
        let running = list.filter { $0.state == "running" }.count
        let open = !docker.collapsed.contains(name)
        let busy = docker.busy.contains("compose:\(name)")
        HoverRow(action: {
            withAnimation(.ztermSnappy) { if open { docker.collapsed.insert(name) } else { docker.collapsed.remove(name) } }
        }) {
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                .rotationEffect(.degrees(open ? 90 : 0)).frame(width: 12)
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(running > 0 ? dockerBlue.opacity(0.18) : Theme.ink.opacity(0.06))
                Image(systemName: "square.stack.3d.up.fill").font(.system(size: 13)).foregroundStyle(running > 0 ? dockerBlue : .secondary)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 13, weight: .semibold))
                Text(running > 0 ? L("{} dari {} berjalan", running, list.count) : L("{} container · berhenti", list.count))
                    .font(.system(size: 11)).foregroundStyle(running > 0 ? runningGreen : .secondary)
            }
        } actions: {
            if busy { ProgressView().controlSize(.small).frame(width: 28) }
            if running > 0 {
                IconButton(symbol: "stop.fill", help: L("Stop proyek")) { Task { await docker.compose(name, "stop") } }
            } else {
                IconButton(symbol: "play.fill", help: L("Jalankan proyek (up)"), tint: runningGreen) { Task { await docker.compose(name, "up") } }
            }
            IconButton(symbol: "arrow.clockwise", help: L("Restart proyek")) { Task { await docker.compose(name, "restart") } }
            ConfirmIcon(symbol: "trash", help: L("Down (hapus container proyek)"), title: L("Down proyek {}?", name),
                        message: L("Semua container proyek ini dihentikan dan dihapus (docker compose down). Volume tetap aman."), confirm: L("Down")) {
                Task { await docker.compose(name, "down") }
            }
        }
    }
}

private struct ContainerRow: View {
    @Environment(AppModel.self) private var model
    let container: DockerContainer
    let indent: Bool

    var body: some View {
        let docker = model.docker
        let running = container.state == "running"
        let busy = docker.busy.contains(container.id)
        HoverRow(selected: docker.selectedId == container.id, action: { docker.choose(container) }) {
            if indent { Spacer().frame(width: 22) }
            StatusIcon(state: container.state)
            VStack(alignment: .leading, spacing: 1) {
                Text(container.service.isEmpty ? container.name : container.service).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(container.image).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if let p = firstPort(container.ports), running {
                Button { if let u = docker.url(p) { NSWorkspace.shared.open(u) } } label: {
                    HStack(spacing: 3) { Text(verbatim: ":\(p)"); Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .bold)) }
                        .font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(dockerBlue)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(dockerBlue.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain).help(L("Buka di browser"))
            }
            if running, let s = docker.stats[container.id] {
                Text(verbatim: String(format: "%.1f%%", s.cpuPercent)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).frame(width: 50, alignment: .trailing)
            }
        } actions: {
            if busy {
                ProgressView().controlSize(.small).frame(width: 28)
            } else if running {
                IconButton(symbol: "stop.fill", help: L("Stop")) { Task { await docker.action(container, "stop") } }
            } else {
                IconButton(symbol: "play.fill", help: L("Start"), tint: runningGreen) { Task { await docker.action(container, "start") } }
            }
            IconButton(symbol: "arrow.clockwise", help: L("Restart")) { Task { await docker.action(container, "restart") } }
            ConfirmIcon(symbol: "trash", help: L("Hapus container"), title: L("Hapus container {}?", container.name),
                        message: L("Container dihentikan dan dihapus. Volume dan image tidak ikut terhapus."), confirm: L("Hapus")) {
                Task { await docker.action(container, "rm") }
            }
        }
    }
}

/// Port host pertama dari string `docker ps` ("0.0.0.0:8000->8000/tcp, ...").
private func firstPort(_ ports: String) -> UInt16? {
    for p in ports.components(separatedBy: ", ") {
        guard let r = p.range(of: "->") else { continue }
        if let n = p[..<r.lowerBound].split(separator: ":").last.flatMap({ UInt16($0) }) { return n }
    }
    return nil
}

private struct ConfirmIcon: View {
    let symbol: String
    let help: String
    let title: String
    let message: String
    let confirm: String
    let action: () -> Void
    @State private var asking = false
    var body: some View {
        IconButton(symbol: symbol, help: help, tint: .red) { asking = true }
            .confirmationDialog(title, isPresented: $asking) {
                Button(confirm, role: .destructive, action: action)
            } message: { Text(message) }
    }
}

// MARK: Detail

private struct ContainerDetail: View {
    @Environment(AppModel.self) private var model
    let container: DockerContainer
    @State private var tab = 0
    @State private var showEnv = false

    var body: some View {
        let docker = model.docker
        let running = container.state == "running"
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    StatusIcon(state: container.state, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(container.name).font(.system(size: 16, weight: .bold)).lineLimit(1).textSelection(.enabled)
                        Text(container.status).font(.system(size: 11.5)).foregroundStyle(running ? runningGreen : .secondary)
                    }
                    Spacer()
                    IconButton(symbol: "xmark", help: L("Tutup")) { docker.choose(nil) }
                }
                HStack(spacing: 8) {
                    if running {
                        Button { Task { await docker.action(container, "stop") } } label: { Label(L("Stop"), systemImage: "stop.fill") }
                    } else {
                        Button { Task { await docker.action(container, "start") } } label: { Label(L("Start"), systemImage: "play.fill") }
                    }
                    Button { Task { await docker.action(container, "restart") } } label: { Label(L("Restart"), systemImage: "arrow.clockwise") }
                    Button { openShell() } label: { Label(L("Terminal"), systemImage: "terminal") }.disabled(!running)
                }
                .buttonStyle(SecondaryButtonStyle())
                Picker("", selection: $tab) {
                    Text(L("Info")).tag(0)
                    Text(L("Log")).tag(1)
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            .padding(16)
            Divider().opacity(0.5)
            if tab == 0 {
                ScrollView { info.padding(16) }
            } else {
                LiveLogs(id: container.id).padding(12)
            }
        }
        .background(Theme.ink.opacity(0.018))
        .onChange(of: container.id) { tab = 0; showEnv = false }
    }

    @ViewBuilder private var info: some View {
        let docker = model.docker
        let d = docker.detail?.id.hasPrefix(container.id) == true ? docker.detail : nil
        VStack(alignment: .leading, spacing: 18) {
            if container.state == "running", let s = docker.stats[container.id] {
                group(L("Pemakaian")) {
                    UsageBar(label: "CPU", value: s.cpuPercent, text: String(format: "%.1f%%", s.cpuPercent))
                    UsageBar(label: "RAM", value: s.memPercent, text: s.memUsage)
                }
            }
            if let d, !d.ports.isEmpty {
                group(L("Port")) {
                    ForEach(d.ports, id: \.hostPort) { p in
                        Button { if let u = docker.url(p.hostPort) { NSWorkspace.shared.open(u) } } label: {
                            HStack {
                                Text(verbatim: "\(docker.url(p.hostPort)?.host() ?? "localhost"):\(p.hostPort)").foregroundStyle(dockerBlue)
                                Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .bold)).foregroundStyle(dockerBlue)
                                Spacer()
                                Text(p.containerPort).foregroundStyle(.secondary)
                            }
                            .font(.system(size: 12, design: .monospaced))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            group(L("Umum")) {
                kv(L("Image"), container.image)
                if let d {
                    kv(L("Perintah"), d.command)
                    kv(L("Dibuat"), d.created)
                    if !d.startedAt.hasPrefix("0001") { kv(L("Mulai"), d.startedAt) }
                    kv(L("Restart"), d.restartPolicy)
                    if !d.health.isEmpty { kv(L("Health"), d.health) }
                }
                kv("ID", String(container.id.prefix(12)))
                if !container.project.isEmpty { kv(L("Compose"), "\(container.project) · \(container.service)") }
            }
            if let d {
                if !d.networks.isEmpty {
                    group(L("Network")) {
                        kv("IP", d.ipAddress.isEmpty ? "—" : d.ipAddress)
                        ForEach(d.networks, id: \.self) { n in Text(n).font(.system(size: 12, design: .monospaced)) }
                    }
                }
                if !d.mounts.isEmpty {
                    group(L("Mount")) {
                        ForEach(d.mounts, id: \.self) { m in
                            Text(m.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.system(size: 11, design: .monospaced))
                                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                        }
                    }
                }
                if !d.env.isEmpty {
                    group(L("Environment"), trailing: {
                        Button(showEnv ? L("Sembunyikan") : L("Tampilkan")) { withAnimation(.ztermSnappy) { showEnv.toggle() } }
                            .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(dockerBlue)
                    }) {
                        ForEach(d.env, id: \.self) { e in
                            let parts = e.split(separator: "=", maxSplits: 1).map(String.init)
                            HStack(alignment: .top, spacing: 6) {
                                Text(parts.first ?? e).font(.system(size: 11, weight: .semibold, design: .monospaced))
                                Text(showEnv ? (parts.count > 1 ? parts[1] : "") : "••••••").font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                            }
                        }
                    }
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            }
        }
    }

    private func group<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        group(title, trailing: { EmptyView() }, content: content)
    }

    private func group<T: View, C: View>(_ title: String, @ViewBuilder trailing: () -> T, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                Spacer()
                trailing()
            }
            VStack(alignment: .leading, spacing: 7) { content() }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func kv(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
            Text(v).font(.system(size: 12)).textSelection(.enabled).lineLimit(3)
        }
    }

    private func openShell() {
        guard let cmd = model.docker.execCommand(container.id) else { return }
        if let id = model.docker.targetId { model.connect([id], run: cmd) } else { model.openLocalTerminal(run: cmd) }
    }
}

private struct UsageBar: View {
    let label: String
    let value: Double
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label).font(.system(size: 11.5, weight: .semibold))
                Spacer()
                Text(verbatim: text).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.ink.opacity(0.08))
                    Capsule().fill(value > 80 ? Color.red : value > 50 ? Color.orange : dockerBlue)
                        .frame(width: max(3, g.size.width * min(1, value / 100)))
                }
            }
            .frame(height: 5)
        }
    }
}

private struct LiveLogs: View {
    @Environment(AppModel.self) private var model
    let id: String
    @State private var text = ""
    @State private var follow = true

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Toggle(L("Ikuti log baru"), isOn: $follow).toggleStyle(.switch).controlSize(.mini).font(.system(size: 11.5))
                Spacer()
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); model.flash(L("Log disalin")) } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain).help(L("Salin log"))
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(text.isEmpty ? L("Memuat log…") : text)
                        .font(.system(size: 10.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    Color.clear.frame(height: 1).id("end")
                }
                .onChange(of: text) { if follow { proxy.scrollTo("end", anchor: .bottom) } }
            }
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 8))
        }
        .task(id: "\(id)-\(follow)") {
            while !Task.isCancelled {
                text = await model.docker.logs(id, tail: 500)
                if !follow { break }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

// MARK: Volume, Image, Network

private struct VolumeList: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let docker = model.docker
        LazyVStack(spacing: 2) {
            ForEach(docker.volumes, id: \.name) { v in
                HoverRow {
                    icon("externaldrive.fill", active: !v.anonymous)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(v.anonymous ? String(v.name.prefix(12)) + "…" : v.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text(v.project.isEmpty ? (v.anonymous ? L("anonim · {}", v.driver) : v.driver) : "\(v.project) · \(v.driver)")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                } actions: {
                    if docker.busy.contains("vol:\(v.name)") {
                        ProgressView().controlSize(.small)
                    } else {
                        ConfirmIcon(symbol: "trash", help: L("Hapus volume"), title: L("Hapus volume {}?", v.name.prefix(24)),
                                    message: L("Data di volume ini hilang permanen. Volume yang masih dipakai container tidak bisa dihapus."), confirm: L("Hapus")) {
                            Task { await docker.removeVolume(v) }
                        }
                    }
                }
            }
        }
    }
}

private struct ImageList: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let docker = model.docker
        LazyVStack(spacing: 2) {
            ForEach(docker.images, id: \.id) { i in
                HoverRow {
                    icon("square.stack.3d.down.right.fill", active: true)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(i.repository).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Text(i.tag).font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 6).padding(.vertical, 1).background(Theme.ink.opacity(0.07), in: Capsule())
                        }
                        Text("\(i.size) · \(i.created)").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                } actions: {
                    if docker.busy.contains("img:\(i.id)") {
                        ProgressView().controlSize(.small)
                    } else {
                        ConfirmIcon(symbol: "trash", help: L("Hapus image"), title: L("Hapus image {}:{}?", i.repository, i.tag),
                                    message: L("Image yang masih dipakai container tidak bisa dihapus."), confirm: L("Hapus")) {
                            Task { await docker.removeImage(i) }
                        }
                    }
                }
            }
        }
    }
}

private struct NetworkList: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        LazyVStack(spacing: 2) {
            ForEach(model.docker.networks, id: \.id) { n in
                HoverRow {
                    icon("point.3.connected.trianglepath.dotted", active: !n.builtin)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(n.name).font(.system(size: 13, weight: .medium))
                        Text([n.driver, n.project.isEmpty ? (n.builtin ? L("bawaan") : "") : n.project].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                } actions: { EmptyView() }
            }
        }
    }
}

private func icon(_ name: String, active: Bool) -> some View {
    ZStack {
        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(active ? dockerBlue.opacity(0.16) : Theme.ink.opacity(0.06))
        Image(systemName: name).font(.system(size: 13)).foregroundStyle(active ? dockerBlue : .secondary)
    }
    .frame(width: 30, height: 30)
}
