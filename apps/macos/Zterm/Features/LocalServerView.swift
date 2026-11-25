import AppKit
import SwiftUI

// MARK: - Model

/// Progress unduhan komponen Server Lokal (dipanggil dari thread core).
final class StackProgressBridge: TransferProgress, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var lastPush = Date.distantPast
    private let onUpdate: @Sendable (Double, String) -> Void

    init(onUpdate: @escaping @Sendable (Double, String) -> Void) { self.onUpdate = onUpdate }

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }

    func onProgress(done: UInt64, total: UInt64, currentFile: String) {
        let now = Date()
        lock.lock()
        let push = now.timeIntervalSince(lastPush) > 0.1 || done == total
        if push { lastPush = now }
        lock.unlock()
        guard push else { return }
        let frac = total > 0 ? Double(done) / Double(total) : 0
        let label = total > 0 ? "\(currentFile) · \(ByteCountFormatter.string(fromByteCount: Int64(done), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file))" : currentFile
        onUpdate(frac, label)
    }

    func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

/// Server Lokal: web server (Apache / Nginx + PHP) dan database lokal, dikelola oleh core (LocalStack).
@MainActor
@Observable
final class StackModel {
    struct Download: Equatable { var fraction: Double; var label: String }

    private(set) var components: [StackComponent] = []
    private(set) var services: [StackService] = []
    var settings: StackSettings
    var downloads: [String: Download] = [:]
    var busy: Set<String> = []
    var error: String?

    @ObservationIgnored let stack: LocalStack?
    @ObservationIgnored private var bridges: [String: StackProgressBridge] = [:]
    @ObservationIgnored private var poller: Task<Void, Never>?

    init() {
        var root = Config.appSupport.appendingPathComponent("stack").path
        #if DEBUG
        if let r = ProcessInfo.processInfo.environment["ZTERM_STACK_ROOT"] { root = r }
        #endif
        stack = try? LocalStack(root: root)
        settings = stack?.settings() ?? StackSettings(webServer: "apache", webPort: 8080, docRoot: NSHomeDirectory() + "/Sites",
                                                      mysqlPort: 3306, postgresPort: 5432, mongodbPort: 27017)
        refresh()
        // Matikan semua layanan saat app ditutup agar tidak ada proses yang tertinggal.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [stack] _ in
            stack?.stopAll()
        }
    }

    func component(_ id: String) -> StackComponent? { components.first { $0.id == id } }
    func service(_ id: String) -> StackService? { services.first { $0.id == id } }
    var anyRunning: Bool { services.contains { $0.running } }

    func refresh() {
        guard let stack else { return }
        components = stack.components()
        services = stack.services()
    }

    /// Perbarui status berkala selama halaman terbuka (layanan bisa berhenti sendiri).
    func startPolling() {
        poller?.cancel()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.refresh()
            }
        }
    }

    func stopPolling() { poller?.cancel() }

    func saveSettings() {
        do { try stack?.setSettings(settings: settings); error = nil } catch { self.error = error.ztermMessage }
        refresh()
    }

    func install(_ id: String) {
        guard let stack, downloads[id] == nil else { return }
        let bridge = StackProgressBridge { [weak self] frac, label in
            Task { @MainActor in self?.downloads[id] = Download(fraction: frac, label: label) }
        }
        bridges[id] = bridge
        downloads[id] = Download(fraction: 0, label: L("Menyiapkan unduhan…"))
        refresh()
        Task {
            do {
                try await stack.install(id: id, progress: bridge)
                error = nil
            } catch CoreError.Cancelled {
            } catch {
                self.error = error.ztermMessage
            }
            downloads[id] = nil
            bridges[id] = nil
            withAnimation(.zterm) { refresh() }
        }
    }

    func cancelInstall(_ id: String) { bridges[id]?.cancel() }

    func uninstall(_ id: String) {
        do { try stack?.uninstall(id: id); error = nil } catch { self.error = error.ztermMessage }
        withAnimation(.zterm) { refresh() }
    }

    /// Unduh semua komponen yang belum ada untuk layanan ini.
    func installMissing(_ service: String) {
        for id in self.service(service)?.missing ?? [] { install(id) }
    }

    func toggle(_ service: String) async {
        guard let stack, !busy.contains(service) else { return }
        busy.insert(service)
        defer { busy.remove(service) }
        let running = self.service(service)?.running == true
        do {
            if running { try await stack.stop(service: service) } else { try await stack.start(service: service) }
        } catch {
            // Error menyala/berhenti tampil di kartu layanannya (StackService.error).
        }
        withAnimation(.zterm) { refresh() }
    }

    func startAll() async {
        for s in services where !s.running && s.missing.isEmpty { await toggle(s.id) }
    }

    func stopAll() async {
        for s in services where s.running { await toggle(s.id) }
    }

    func log(_ service: String) -> String { stack?.logTail(service: service, lines: 60) ?? "" }
    var rootPath: String { stack?.rootPath() ?? "" }
    var webURL: URL { URL(string: "http://localhost:\(settings.webPort)/")! }
}

// MARK: - Tampilan

private struct DbKind {
    let id: String, name: String, color: String, icon: String, engine: DbEngine, user: String, note: String
}

private let dbKinds = [
    DbKind(id: "mysql", name: "MySQL", color: "#00758F", icon: "cylinder.split.1x2.fill", engine: .mysql, user: "root", note: L("User root, tanpa password")),
    DbKind(id: "postgres", name: "PostgreSQL", color: "#336791", icon: "cylinder.fill", engine: .postgres, user: "postgres", note: L("User postgres, tanpa password")),
    DbKind(id: "mongodb", name: "MongoDB", color: "#13AA52", icon: "leaf.fill", engine: .mongodb, user: "", note: L("Tanpa autentikasi")),
]

struct LocalServerView: View {
    @Environment(AppModel.self) private var model
    @State private var showLog: String?

    private var stack: StackModel { model.stack }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: L("Server Lokal"), subtitle: L("Web server & database di komputermu — seperti MAMP, tanpa install manual")) {
                    Button { NSWorkspace.shared.open(URL(fileURLWithPath: stack.rootPath)) } label: { PhosphorIcon(sf: "folder", size: 14) }
                        .buttonStyle(SecondaryButtonStyle()).help(L("Buka folder data & log"))
                    if stack.anyRunning {
                        Button { Task { await stack.stopAll() } } label: { PhosphorLabel(sf: "stop.fill", text: L("Stop semua"), size: 12) }
                            .buttonStyle(SecondaryButtonStyle())
                    } else {
                        Button { Task { await stack.startAll() } } label: { PhosphorLabel(sf: "play.fill", text: L("Start semua"), size: 12) }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(!stack.services.contains { $0.missing.isEmpty })
                    }
                }
                if let e = stack.error {
                    PhosphorLabel(sf: "exclamationmark.triangle.fill", text: e, size: 12)
                        .font(.callout).foregroundStyle(.red)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                        .onTapGesture { withAnimation(.zterm) { stack.error = nil } }
                }
                WebCard(showLog: $showLog)
                Text("DATABASE").font(.system(size: 11, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                    ForEach(Array(dbKinds.enumerated()), id: \.element.id) { i, k in
                        LocalDbCard(kind: k, showLog: $showLog).staggerIn(i, base: 0)
                    }
                }
            }
            .padding(28)
            .animation(.zterm, value: stack.services)
            .animation(.zterm, value: stack.error)
        }
        .onAppear { stack.refresh(); stack.startPolling() }
        .onDisappear { stack.stopPolling() }
        .sheet(item: Binding(get: { showLog.map(LogID.init) }, set: { showLog = $0?.id })) { l in LogSheet(service: l.id) }
    }
}

private struct LogID: Identifiable { let id: String }

/// Tombol status layanan: Start / Stop (dengan indikator saat bekerja).
private struct PowerButton: View {
    let running: Bool
    let busy: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if busy { ProgressView().controlSize(.small) } else { PhosphorIcon(sf: running ? "stop.fill" : "power", size: 13) }
                Text(busy ? (running ? L("Menghentikan…") : L("Menyalakan…")) : running ? L("Stop") : L("Start"))
            }
            .frame(minWidth: 96)
        }
        .modifier(PowerStyle(running: running))
        .disabled(!enabled || busy)
    }
}

/// Start = tombol utama; Stop = tombol sekunder agar beda jelas.
private struct PowerStyle: ViewModifier {
    let running: Bool
    func body(content: Content) -> some View {
        if running { content.buttonStyle(SecondaryButtonStyle()) } else { content.buttonStyle(PrimaryButtonStyle()) }
    }
}

private struct ServiceDot: View {
    let running: Bool
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(running ? Color(hex: "#4ADE80") : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
            Text(running ? L("Berjalan") : L("Berhenti")).font(.system(size: 11.5, weight: .medium)).foregroundStyle(running ? Color(hex: "#4ADE80") : .secondary)
        }
    }
}

/// Komponen yang perlu diunduh: tombol unduh / progress / batal.
private struct ComponentRow: View {
    @Environment(AppModel.self) private var model
    let id: String

    var body: some View {
        let stack = model.stack
        if let c = stack.component(id) {
            HStack(spacing: 10) {
                PhosphorIcon(sf: c.state == .notInstalled ? "arrow.down.circle" : "checkmark.circle.fill", size: 14)
                    .foregroundStyle(c.state == .notInstalled ? Color.secondary : Color(hex: "#4ADE80"))
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(c.name) \(c.version)").font(.system(size: 12.5, weight: .medium))
                    if let d = stack.downloads[id] {
                        ProgressView(value: d.fraction).progressViewStyle(.linear).frame(maxWidth: 260)
                        Text(d.label).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        Text(c.system ? L("Bawaan macOS") : c.state == .notInstalled ? L("Belum diunduh · ±{} MB", c.sizeMb) : L("Terpasang"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if stack.downloads[id] != nil {
                    Button(L("Batal")) { stack.cancelInstall(id) }.buttonStyle(SecondaryButtonStyle())
                } else if c.state == .notInstalled {
                    Button { stack.install(id) } label: { PhosphorLabel(sf: "arrow.down", text: L("Unduh"), size: 12) }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(!c.available)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Theme.ink.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

private struct WebCard: View {
    @Environment(AppModel.self) private var model
    @Binding var showLog: String?

    var body: some View {
        @Bindable var stack = model.stack
        let svc = stack.service("web")
        let running = svc?.running == true
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                PhosphorIcon(sf: "globe", size: 22).foregroundStyle(.black.opacity(0.72))
                    .frame(width: 48, height: 48)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 10) {
                        Text(L("Web server")).font(.system(size: 18, weight: .bold))
                        ServiceDot(running: running)
                    }
                    Text(verbatim: running ? L("{} + PHP di localhost:{}", stack.settings.webServer == "nginx" ? "Nginx" : "Apache", String(stack.settings.webPort)) : L("Apache atau Nginx dengan PHP — untuk Laravel, WordPress, dan proyek PHP lain"))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                if running {
                    Button { NSWorkspace.shared.open(stack.webURL) } label: { PhosphorLabel(sf: "safari", text: L("Buka di browser"), size: 12) }
                        .buttonStyle(SecondaryButtonStyle())
                }
                Menu {
                    Button(L("Lihat log")) { showLog = "web" }
                    Button(L("Buka folder proyek")) { NSWorkspace.shared.open(URL(fileURLWithPath: stack.settings.docRoot)) }
                } label: { PhosphorIcon(sf: "ellipsis", size: 14).frame(width: 26, height: 26) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                PowerButton(running: running, busy: stack.busy.contains("web"), enabled: svc?.missing.isEmpty == true) {
                    Task { await stack.toggle("web") }
                }
            }

            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    field(L("Web server")) {
                        Picker("", selection: $stack.settings.webServer) {
                            Text(L("Apache")).tag("apache")
                            Text(L("Nginx")).tag("nginx")
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                        .disabled(running)
                        .onChange(of: stack.settings.webServer) { stack.saveSettings() }
                    }
                    field(L("Port")) {
                        PortField(port: $stack.settings.webPort, disabled: running) { stack.saveSettings() }
                    }
                    field(L("Folder proyek")) {
                        HStack(spacing: 8) {
                            Text(stack.settings.docRoot.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .frame(maxWidth: 280, alignment: .leading)
                                .background(Theme.field, in: RoundedRectangle(cornerRadius: 8))
                            Button(L("Pilih…")) { chooseRoot() }.buttonStyle(SecondaryButtonStyle()).disabled(running)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("KOMPONEN")).font(.system(size: 10.5, weight: .semibold)).tracking(1.1).foregroundStyle(.secondary)
                    ComponentRow(id: stack.settings.webServer)
                    ComponentRow(id: "php")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let e = svc?.error, !running {
                PhosphorLabel(sf: "exclamationmark.circle", text: e, size: 12).font(.system(size: 11.5)).foregroundStyle(.orange).lineLimit(2)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(running ? Color(hex: "#4ADE80").opacity(0.45) : Theme.cardStroke))
    }

    private func field<C: View>(_ label: String, @ViewBuilder content: () -> C) -> some View {
        HStack(spacing: 12) {
            Text(label).font(.system(size: 12.5)).foregroundStyle(.secondary).frame(width: 100, alignment: .trailing)
            content()
        }
    }

    private func chooseRoot() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = L("Pilih")
        p.directoryURL = URL(fileURLWithPath: model.stack.settings.docRoot)
        if p.runModal() == .OK, let u = p.url {
            model.stack.settings.docRoot = u.path
            model.stack.saveSettings()
        }
    }
}

private struct PortField: View {
    @Binding var port: UInt16
    let disabled: Bool
    let onCommit: () -> Void
    var body: some View {
        TextField(L("Port"), value: $port, format: .number.grouping(.never))
            .ztermField().frame(width: 90)
            .disabled(disabled)
            .onSubmit(onCommit)
            .onChange(of: port) { onCommit() }
    }
}

private struct LocalDbCard: View {
    @Environment(AppModel.self) private var model
    let kind: DbKind
    @Binding var showLog: String?
    @State private var confirmRemove = false

    var body: some View {
        @Bindable var stack = model.stack
        let svc = stack.service(kind.id)
        let comp = stack.component(kind.id)
        let running = svc?.running == true
        let installed = comp.map { $0.state != .notInstalled && $0.state != .installing } ?? false
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                PhosphorIcon(sf: kind.icon, size: 17).foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color(hex: kind.color), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.name).font(.system(size: 15, weight: .bold))
                    Text(comp.map { L("versi {}", $0.version) } ?? "").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if installed { ServiceDot(running: running) }
                Menu {
                    Button(L("Lihat log")) { showLog = kind.id }
                    if installed {
                        Divider()
                        Button(L("Hapus program…"), role: .destructive) { confirmRemove = true }.disabled(running)
                    }
                } label: { PhosphorIcon(sf: "ellipsis", size: 13).frame(width: 24, height: 24) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }

            if !installed {
                ComponentRow(id: kind.id)
            } else {
                HStack(spacing: 10) {
                    Text(L("Port")).font(.system(size: 12)).foregroundStyle(.secondary)
                    PortField(port: portBinding(stack), disabled: running) { stack.saveSettings() }
                    Spacer()
                    PowerButton(running: running, busy: stack.busy.contains(kind.id), enabled: true) {
                        Task { await stack.toggle(kind.id) }
                    }
                }
                Text(verbatim: "127.0.0.1:\(String(svc?.port ?? 0)) · \(kind.note)").font(.system(size: 11)).foregroundStyle(.tertiary)
                if running {
                    Button { Task { await openInDatabase(port: svc?.port ?? 0) } } label: {
                        PhosphorLabel(sf: "tablecells", text: L("Buka di Database"), size: 12).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
            if let e = svc?.error, !running {
                PhosphorLabel(sf: "exclamationmark.circle", text: e, size: 12).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(3)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(running ? Color(hex: "#4ADE80").opacity(0.45) : Theme.cardStroke))
        .confirmationDialog(L("Hapus program {}?", kind.name), isPresented: $confirmRemove) {
            Button(L("Hapus program"), role: .destructive) { stack.uninstall(kind.id) }
        } message: {
            Text(L("Program dihapus dari komputermu. Data database tetap disimpan dan dipakai lagi saat diunduh ulang."))
        }
    }

    private func portBinding(_ stack: StackModel) -> Binding<UInt16> {
        switch kind.id {
        case "mysql": Binding(get: { stack.settings.mysqlPort }, set: { stack.settings.mysqlPort = $0 })
        case "postgres": Binding(get: { stack.settings.postgresPort }, set: { stack.settings.postgresPort = $0 })
        default: Binding(get: { stack.settings.mongodbPort }, set: { stack.settings.mongodbPort = $0 })
        }
    }

    /// Simpan koneksi "Lokal · <DB>" (sekali) lalu buka di halaman Database.
    private func openInDatabase(port: UInt16) async {
        let label = L("Lokal · {}", kind.name)
        var conn = model.databases.first { $0.label == label && $0.host == "127.0.0.1" } ??
            DbConnection(id: "", label: label, engine: kind.engine, host: "127.0.0.1", port: port, username: kind.user,
                         password: nil, database: "", filePath: "", tls: false, sshHostId: nil, color: kind.color, updatedAt: 0, deleted: false)
        if conn.port != port || conn.id.isEmpty {
            conn.port = port
            model.save(conn)
            conn = model.databases.first { $0.label == label && $0.host == "127.0.0.1" } ?? conn
        }
        await model.openDatabase(conn)
    }
}

private struct LogSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let service: String
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("Log {}", service == "web" ? "web server" : service)).font(.title3.bold())
                Spacer()
                Button { text = model.stack.log(service) } label: { PhosphorIcon(sf: "arrow.clockwise", size: 13) }.buttonStyle(SecondaryButtonStyle())
            }
            ScrollView {
                Text(text.isEmpty ? L("Belum ada log.") : text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(height: 360)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Spacer()
                Button(L("Tutup")) { dismiss() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
            }
        }
        .padding(22).frame(width: 640)
        .onAppear { text = model.stack.log(service) }
    }
}
