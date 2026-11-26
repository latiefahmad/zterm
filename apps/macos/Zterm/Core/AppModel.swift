import AppKit
import SwiftUI

enum Phase: Equatable {
    case welcome
    case createPassword
    /// Vault ditemukan di Google Drive — buka dengan master password lama.
    case restore
    case locked
    case main
}

enum Section: String, CaseIterable, Identifiable {
    case hosts, dashboard, serverAdmin, team, keychain, forwarding, sftp, database, localServer, docker, snippets, knownHosts, logs, about, account
    var id: String { rawValue }
    static let main: [Section] = [.dashboard, .hosts, .serverAdmin, .team, .keychain, .forwarding, .sftp, .database, .localServer, .docker, .snippets, .knownHosts, .logs]
    static let community: [Section] = [.about]
    var title: String {
        switch self {
        case .hosts: "Hosts"
        case .dashboard: "Dashboard"
        case .serverAdmin: L("Kelola Server")
        case .team: L("Tim")
        case .keychain: "Keychain"
        case .forwarding: "Port Forwarding"
        case .sftp: "SFTP"
        case .database: "Database"
        case .localServer: L("Server Lokal")
        case .docker: "Docker"
        case .snippets: "Snippets"
        case .knownHosts: "Known Hosts"
        case .logs: L("Logs")
        case .about: L("Tentang")
        case .account: L("Akun")
        }
    }
    var icon: String {
        switch self {
        case .hosts: "server.rack"
        case .dashboard: "gauge.with.dots.needle.67percent"
        case .serverAdmin: "wrench.and.screwdriver.fill"
        case .team: "person.2.fill"
        case .keychain: "key.horizontal.fill"
        case .forwarding: "arrow.right.arrow.left"
        case .sftp: "folder.fill"
        case .database: "cylinder.split.1x2.fill"
        case .localServer: "square.stack.3d.up.fill"
        case .docker: "shippingbox.fill"
        case .snippets: "curlybraces"
        case .knownHosts: "touchid"
        case .logs: "clock.fill"
        case .about: "info.circle.fill"
        case .account: "person.crop.circle.fill"
        }
    }
}

enum SyncState: Equatable {
    case off, idle, syncing, synced(Date), failed(String)
    /// Token Google tidak ada / kedaluwarsa — perlu login ulang.
    case needsLogin
}

/// State utama app. Semua data persisten lewat `Vault` (zterm-core, Rust).
@MainActor
@Observable
final class AppModel {
    var phase: Phase
    var section: Section = .hosts
    var hosts: [Host] = []
    var keys: [SshKey] = []
    var snippets: [Snippet] = []
    var forwards: [PortForward] = []
    var logs: [SessionLog] = []
    var databases: [DbConnection] = []
    /// Tim yang dimiliki / diikuti, key milik host tim, dan undangan yang belum diterima.
    var teams: [TeamInfo] = []
    var teamKeys: [SshKey] = []
    var teamInvites: [TeamInvite] = []
    var teamBusy = false
    var teamError: String?
    /// Koneksi database yang sedang dibuka di workspace.
    var dbWorkspace: DbWorkspace?
    var accountEmail: String?
    var pendingAccountEmail: String?
    /// Vault terenkripsi yang diunduh dari Drive saat login di perangkat baru.
    var pendingRemoteBlob: Data?

    // Sesi terminal
    var sessions: [TerminalSession] = []
    var activeSessionID: UUID? { didSet { syncServerStats() } }
    /// Panel Info server (spesifikasi & grafik) untuk host di tab aktif.
    var showServerInfo = false { didSet { syncServerStats() } }
    var serverStats: ServerStats?
    let dashboard = DashboardModel()
    let admin = AdminModel()
    let backups = BackupModel()
    /// Hanya tes: buka sheet Backup untuk koneksi ini.
    var demoBackup: DbConnection?
    /// Sheet "Jalankan perintah di banyak server".
    var runMany: RunManyModel?

    // Multi-select host
    var selection: Set<String> = []

    var toast: String?
    /// Host yang sedang diedit di panel kanan (inspector). `id` kosong = host baru.
    var editingHost: Host?

    var sync: SyncState = .off
    /// Rilis baru yang tersedia di GitHub (nil = sudah versi terbaru / belum dicek).
    var update: AvailableUpdate?
    var updateDismissed = false
    var updateBusy = false
    var updateProgress = 0.0
    var updateStatus: String?
    @ObservationIgnored private var updatePercent = -1
    @ObservationIgnored private var updateAcceptingProgress = false
    let tunnels = TunnelManager()
    let sftp = SftpModel()
    let stack = StackModel()
    let docker = DockerModel()

    private var vault: Vault?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var remoteFile: DriveClient.RemoteFile?
    @ObservationIgnored private var teamTimer: Task<Void, Never>?

    init() {
        phase = vaultExists(path: Config.vaultPath) ? .locked : .welcome
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-ZtermDemo") { loadDemo() }
        #endif
    }

    #if DEBUG
    /// Vault sementara berisi contoh data — hanya untuk build debug (`-ZtermDemo`).
    private func loadDemo() {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("zterm-demo-\(UUID()).zterm").path
        guard let v = try? Vault.create(path: path, password: "demo-password") else { return }
        let samples: [(String, String, String?, [String], String)] = [
            ("prod-api", "10.0.1.10", "Production", ["api", "prod"], "#3FD0B4"),
            ("prod-db", "10.0.1.20", "Production", ["postgres"], "#F0616D"),
            ("staging", "staging.local", "Staging", ["web"], "#5B9CF5"),
            ("homelab", "192.168.1.5", nil, ["pi"], "#9D7CF2"),
        ]
        for (label, hostname, group, tags, color) in samples {
            var h = Host.blank()
            h.label = label; h.hostname = hostname; h.group = group; h.tags = tags; h.color = color
            _ = try? v.upsertHost(host: h)
        }
        _ = try? v.generateKey(label: "MacBook")
        let hs = v.hosts()
        _ = try? v.upsertSnippet(snippet: Snippet(id: "", label: "Cek disk", command: "df -h", updatedAt: 0, deleted: false))
        _ = try? v.upsertSnippet(snippet: Snippet(id: "", label: "Update sistem", command: "sudo apt update && sudo apt upgrade -y", updatedAt: 0, deleted: false))
        _ = try? v.upsertForward(forward: PortForward(id: "", label: "Postgres prod", hostId: hs[1].id, kind: .local,
                                                      bindAddress: "127.0.0.1", bindPort: 5433, destHost: "localhost", destPort: 5432, updatedAt: 0, deleted: false))
        if let l = try? v.startLog(hostId: hs[0].id, hostLabel: hs[0].title, address: hs[0].address) { try? v.finishLog(id: l, exitCode: 0) }
        vault = v
        reload()
        phase = .main
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-ZtermDemoEdit") { editingHost = hosts.first }
        if args.contains("-ZtermDemoLocal") { openLocalTerminal(run: ProcessInfo.processInfo.environment["ZTERM_DEMO_RUN"]) }
        if let i = args.firstIndex(of: "-ZtermDemoSection"), i + 1 < args.count, let s = Section(rawValue: args[i + 1]) { section = s }
        if args.contains("-ZtermDemoSelect") { selection = [hosts[2].id] }
        if args.contains("-ZtermDemoConnect") {
            var local = Host.blank()
            local.label = "localhost"; local.hostname = "127.0.0.1"; local.auth = .agent
            local.username = NSUserName(); local.color = "#F2A65A"; local.terminalTheme = "ember"
            if let l = try? v.upsertHost(host: local) { reload(); connect([l.id]) }
        }
        if args.contains("-ZtermDemoDb") || args.contains("-ZtermDemoDbList") {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("zterm-demo-\(UUID()).sqlite").path
            let pg = DbConnection(id: "", label: "Produksi API", engine: .postgres, host: "10.0.1.20", port: 5432, username: "postgres",
                                  password: nil, database: "app", filePath: "", tls: true, sshHostId: hs.first?.id, color: "#336791", updatedAt: 0, deleted: false)
            let rd = DbConnection(id: "", label: "Cache", engine: .redis, host: "127.0.0.1", port: 6379, username: "",
                                  password: nil, database: "0", filePath: "", tls: false, sshHostId: nil, color: "#DC382D", updatedAt: 0, deleted: false)
            let my = DbConnection(id: "", label: "Absensi", engine: .mariadb, host: "127.0.0.1", port: 3306, username: "root",
                                  password: nil, database: "absensi", filePath: "", tls: false, sshHostId: hs.last?.id, color: "#C0765A", updatedAt: 0, deleted: false)
            let lite = DbConnection(id: "", label: "Toko Lokal", engine: .sqlite, host: "", port: 0, username: "", password: nil,
                                    database: "", filePath: file, tls: false, sshHostId: nil, color: "#0F80CC", updatedAt: 0, deleted: false)
            for c in [pg, rd, my] { _ = try? v.upsertDatabase(conn: c) }
            if let saved = try? v.upsertDatabase(conn: lite) {
                reload()
                if args.contains("-ZtermDemoDb") {
                    Task {
                        let s = try? await DbSession.connect(conn: saved, ssh: nil)
                        _ = try? await s?.run(sql: "CREATE TABLE produk (id INTEGER PRIMARY KEY, nama TEXT, harga INTEGER, stok INTEGER, kategori TEXT)")
                        _ = try? await s?.run(sql: "CREATE TABLE pelanggan (id INTEGER PRIMARY KEY, nama TEXT, kota TEXT)")
                        _ = try? await s?.run(sql: "CREATE VIEW stok_rendah AS SELECT * FROM produk WHERE stok < 10")
                        _ = try? await s?.run(sql: "INSERT INTO produk (nama, harga, stok, kategori) VALUES ('Kopi Gayo 250g', 85000, 42, 'Minuman'), ('Teh Tarik', 18000, 7, 'Minuman'), ('Keripik Pisang', 22000, 120, 'Camilan'), ('Kue Adee', 35000, NULL, 'Kue'), ('Madu Hutan', 120000, 5, 'Herbal'), ('Kopi Ulee Kareng', 65000, 31, 'Minuman')")
                        await openDatabase(saved)
                        let env = ProcessInfo.processInfo.environment
                        // ZTERM_DEMO_DB_TAB=search|browse : buka tabel produk; ZTERM_DEMO_DB_QUICK / ZTERM_DEMO_DB_FIND (kolom=nilai)
                        if let tab = env["ZTERM_DEMO_DB_TAB"].flatMap(DbWorkspace.Tab.init(rawValue:)), let ws = dbWorkspace,
                           let t = ws.dbTables["main"]?.first(where: { $0.name == "produk" }) {
                            await ws.openTable(t, in: "main")
                            withAnimation(.ztermSnappy) { ws.tab = tab }
                            await ws.loadTab()
                            if let q = env["ZTERM_DEMO_DB_QUICK"] { ws.quickSearch = q; await ws.submitQuickSearch() }
                            if let find = env["ZTERM_DEMO_DB_FIND"] {
                                for pair in find.split(separator: ";") {
                                    let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                                    if let i = ws.searchForm.firstIndex(where: { $0.column == kv[0] }), kv.count == 2 { ws.searchForm[i].value = kv[1] }
                                }
                                if env["ZTERM_DEMO_DB_SUBMIT"] != nil { await ws.submitSearch() }
                            }
                            return
                        }
                        dbWorkspace?.query = "SELECT nama, harga, stok, kategori FROM produk ORDER BY harga DESC;"
                        await dbWorkspace?.run()
                    }
                } else {
                    section = .database
                }
            }
        }
        let env = ProcessInfo.processInfo.environment
        // Tes autocomplete: ZTERM_TERM_PORT + ZTERM_TERM_KEY, lalu ZTERM_TERM_TYPE = ketikan dipisah "|" (\r = Enter)
        if let port = env["ZTERM_TERM_PORT"].flatMap(UInt16.init),
           let pem = env["ZTERM_TERM_KEY"].flatMap({ try? String(contentsOfFile: $0, encoding: .utf8) }),
           let k = try? v.importKey(label: "tes-terminal", privateKey: pem, passphrase: nil) {
            var h = Host.blank()
            h.label = "server-tes"; h.hostname = "127.0.0.1"; h.port = port; h.username = NSUserName()
            h.auth = .key; h.keyId = k.id; h.color = "#3FD0B4"
            if let saved = try? v.upsertHost(host: h) {
                _ = try? v.upsertSnippet(snippet: Snippet(id: "", label: "Lihat log nginx", command: "tail -f /var/log/nginx/error.log", updatedAt: 0, deleted: false))
                reload()
                connect([saved.id])
                if env["ZTERM_DEMO_INFO"] != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in showServerInfo = true } }
                let steps = (env["ZTERM_TERM_TYPE"] ?? "").components(separatedBy: "|").map { $0.replacingOccurrences(of: "\\r", with: "\r") }
                for (i, step) in steps.enumerated() where !step.isEmpty {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3 + Double(i) * 1.2) { [weak self] in
                        if step == "<accept>" { self?.activeSession?.autocomplete.accept(0) }
                        else { self?.activeTerminalView?.send(txt: step) }
                    }
                }
            }
        }
        if let port = env["ZTERM_MYSQL_PORT"].flatMap(UInt16.init) {
            // Tes tampilan phpMyAdmin: MariaDB lokal tanpa database terpilih
            let my = DbConnection(id: "", label: "MariaDB lokal", engine: .mariadb, host: "127.0.0.1", port: port, username: "root",
                                  password: env["ZTERM_MYSQL_PW"], database: "", filePath: "", tls: false, sshHostId: nil,
                                  color: "#C0765A", updatedAt: 0, deleted: false)
            if let saved = try? v.upsertDatabase(conn: my) {
                reload()
                Task {
                    await openDatabase(saved)
                    // ZTERM_MYSQL_OPEN=db atau db/tabel, ZTERM_MYSQL_TAB=structure|sql
                    guard let ws = dbWorkspace, let target = env["ZTERM_MYSQL_OPEN"] else { return }
                    let parts = target.split(separator: "/").map(String.init)
                    await ws.selectDatabase(parts[0])
                    if parts.count > 1, let t = ws.dbTables[parts[0]]?.first(where: { $0.name == parts[1] }) {
                        if let tab = env["ZTERM_MYSQL_TAB"].flatMap(DbWorkspace.Tab.init(rawValue:)) { ws.tab = tab }
                        await ws.openTable(t, in: parts[0])
                        if env["ZTERM_MYSQL_PAGE"] != nil { await ws.goToPage(offset: 100) }
                    }
                }
            }
        }
        if args.contains("-ZtermDemoSftp"), let port = env["ZTERM_SFTP_PORT"].flatMap(UInt16.init),
           let pem = env["ZTERM_SFTP_KEY"].flatMap({ try? String(contentsOfFile: $0, encoding: .utf8) }),
           let k = try? v.importKey(label: "tes-sftp", privateKey: pem, passphrase: nil) {
            var h = Host.blank()
            h.label = "sftp-lokal"; h.hostname = "127.0.0.1"; h.port = port; h.username = NSUserName()
            h.auth = .key; h.keyId = k.id; h.color = "#5B9CF5"
            if let saved = try? v.upsertHost(host: h) {
                reload()
                sftp.localPath = env["ZTERM_SFTP_LOCAL"] ?? sftp.localPath
                sftp.reloadLocal()
                Task {
                    await openSftp(saved)
                    if let r = env["ZTERM_SFTP_REMOTE"] { await sftp.openRemote(r) }
                    // ZTERM_SFTP_EDIT / ZTERM_SFTP_OPENWITH = nama file di folder remote
                    for (k, edit) in [("ZTERM_SFTP_EDIT", true), ("ZTERM_SFTP_OPENWITH", false)] {
                        if let n = env[k], let item = sftp.remoteItems.first(where: { $0.name == n }) {
                            if edit {
                                await sftp.openEditor(item)
                                // ZTERM_SFTP_EDIT_APPEND: tambahkan teks lalu simpan (tes alur simpan)
                                if let add = env["ZTERM_SFTP_EDIT_APPEND"], let doc = sftp.editor {
                                    doc.text += add + "\n"
                                    await sftp.saveEditor(doc)
                                }
                            } else {
                                let app = env["ZTERM_SFTP_APP"].map { URL(fileURLWithPath: $0) }
                                await sftp.openWith(item, app: app)
                            }
                        }
                    }
                }
            }
        }
        // Tes Tim dengan Drive tiruan: ZTERM_DRIVE_BASE + ZTERM_TEST_DRIVE_TOKEN/EMAIL,
        // ZTERM_DEMO_TEAM=admin (buat tim, bagikan 2 host, undang ZTERM_DEMO_TEAM_INVITE) atau member (gabung undangan pertama)
        // ZTERM_DEMO_SPLIT=3 : split terminal lokal; ZTERM_DEMO_BROADCAST=1; ZTERM_DEMO_SPLIT_TYPE = teks diketik di panel aktif
        if let n = env["ZTERM_DEMO_SPLIT"].flatMap(Int.init), n > 1 {
            openLocalTerminal()
            for _ in 1..<n { splitDuplicate() }
            if env["ZTERM_DEMO_BROADCAST"] != nil { broadcast = true }
            if let typed = env["ZTERM_DEMO_SPLIT_TYPE"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [self] in
                    activeTerminalView?.send(txt: typed.replacingOccurrences(of: "\\r", with: "\r"))
                }
            }
        }
        // ZTERM_DEMO_DASHBOARD=1 : buka Dashboard; ZTERM_DEMO_DASHBOARD_SELECT=judul1,judul2 : pilih server
        // ZTERM_DASH_HOSTS="label|port|user|grup|#warna;..." (semua 127.0.0.1, key ZTERM_TERM_KEY) menggantikan host contoh
        if let list = env["ZTERM_DASH_HOSTS"],
           let pem = env["ZTERM_TERM_KEY"].flatMap({ try? String(contentsOfFile: $0, encoding: .utf8) }),
           let k = try? v.importKey(label: "tes-dashboard", privateKey: pem, passphrase: nil) {
            for h in v.hosts() { try? v.deleteHost(id: h.id) }
            for item in list.split(separator: ";") {
                let f = item.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                guard f.count == 5, let port = UInt16(f[1]) else { continue }
                var h = Host.blank()
                h.label = f[0]; h.hostname = "127.0.0.1"; h.port = port; h.username = f[2]
                h.group = f[3].isEmpty ? nil : f[3]; h.color = f[4]; h.auth = .key; h.keyId = k.id
                _ = try? v.upsertHost(host: h)
            }
            reload()
        }
        // ZTERM_DEMO_BACKUP_DB="label|engine|port|user|pw|db|host ssh?" : koneksi tes + buka sheet Backup; ZTERM_DEMO_BACKUP_RUN=1 jalankan
        if let spec = env["ZTERM_DEMO_BACKUP_DB"] {
            let f = spec.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            if f.count == 7 {
                let engine: DbEngine = f[1] == "postgres" ? .postgres : f[1] == "mariadb" ? .mariadb : .mysql
                let ssh = hosts.first { $0.title == f[6] }?.id
                let c = DbConnection(id: "", label: f[0], engine: engine, host: "127.0.0.1", port: UInt16(f[2]) ?? 3306, username: f[3],
                                     password: f[4], database: f[5], filePath: "", tls: false, sshHostId: ssh, color: "#C0765A", updatedAt: 0, deleted: false)
                if let saved = try? v.upsertDatabase(conn: c) {
                    reload()
                    section = .database
                    demoBackup = saved
                    if env["ZTERM_DEMO_BACKUP_RUN"] != nil { Task { await backups.backup(saved, app: self) } }
                }
            }
        }
        // ZTERM_DEMO_CONNECT=judul host : buka terminal; ZTERM_DEMO_INFO=1 panel Info server; ZTERM_DEMO_CONNECT_TYPE = ketikan (\r = Enter)
        if let name = env["ZTERM_DEMO_CONNECT"], let h = hosts.first(where: { $0.title == name }) {
            connect([h.id])
            if env["ZTERM_DEMO_INFO"] != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in showServerInfo = true; syncServerStats() } }
            if let typed = env["ZTERM_DEMO_CONNECT_TYPE"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [self] in activeTerminalView?.send(txt: typed.replacingOccurrences(of: "\\r", with: "\r")) }
            }
        }
        // ZTERM_DEMO_ADMIN=judul host, ZTERM_DEMO_ADMIN_TAB=processes|services|cron|logs, ZTERM_DEMO_ADMIN_SERVICE=nama
        if let name = env["ZTERM_DEMO_ADMIN"], let h = hosts.first(where: { $0.title == name }) {
            section = .serverAdmin
            if let t = env["ZTERM_DEMO_ADMIN_TAB"].flatMap(AdminModel.Tab.init(rawValue:)) { admin.tab = t }
            Task {
                await admin.select(h.id, model: self)
                if let svc = env["ZTERM_DEMO_ADMIN_SERVICE"] {
                    if admin.tab == .logs { admin.showLogs(unit: svc) } else { admin.chooseService(svc) }
                }
            }
        }
        if env["ZTERM_DEMO_DASHBOARD"] != nil {
            section = .dashboard
            // ZTERM_DEMO_ALERTS=1 : nyalakan pemantauan + catat peringatan ke stderr (tanpa minta izin notifikasi)
            if env["ZTERM_DEMO_ALERTS"] != nil {
                dashboard.alerts = true
                dashboard.start(self)
                for t in dashboard.tiles.values {
                    t.onAlert = { title, body, key in FileHandle.standardError.write(Data("ALERT [\(key)] \(title) — \(body)\n".utf8)) }
                }
            }
            // ZTERM_DEMO_RUNMANY=perintah : buka "Jalankan perintah" untuk semua host lalu jalankan
            if let cmd = env["ZTERM_DEMO_RUNMANY"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
                    openRunMany(hosts.map(\.id))
                    runMany?.command = cmd
                    runMany?.run(self)
                    // Catat hasil ke stderr setelah selesai (tes otomatis)
                    Task { [self] in
                        while runMany?.running == true || runMany?.rows.isEmpty == true { try? await Task.sleep(for: .milliseconds(300)) }
                        if let r = runMany {
                            FileHandle.standardError.write(Data("RUNMANY ok=\(r.okCount) fail=\(r.failCount)\n\(r.report(self))\nRUNMANY-END\n".utf8))
                        }
                    }
                }
            }
            if let list = env["ZTERM_DEMO_DASHBOARD_SELECT"] {
                let names = Set(list.split(separator: ",").map(String.init))
                dashboard.selection = Set(hosts.filter { names.contains($0.title) }.map(\.id))
                // ZTERM_DEMO_DASHBOARD_SPLIT = teks yang diketik setelah "Split & broadcast" (\r = Enter)
                if let typed = env["ZTERM_DEMO_DASHBOARD_SPLIT"] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
                        openSplit(hosts.map(\.id).filter { dashboard.selection.contains($0) }, broadcast: true)
                        dashboard.selection.removeAll()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [self] in
                            activeTerminalView?.send(txt: typed.replacingOccurrences(of: "\\r", with: "\r"))
                        }
                    }
                }
            }
        }
        // ZTERM_DEMO_DOCKER=1 : buka halaman Docker (Mac ini); ZTERM_DEMO_DOCKER_TAB=images|compose
        if env["ZTERM_DEMO_DOCKER"] != nil {
            section = .docker
            if let t = env["ZTERM_DEMO_DOCKER_TAB"].flatMap(DockerModel.Tab.init(rawValue:)) { docker.tab = t }
            if let q = env["ZTERM_DEMO_DOCKER_QUERY"] { docker.query = q }
            // ZTERM_DEMO_DOCKER_SELECT=nama container : buka panel detail
            if let name = env["ZTERM_DEMO_DOCKER_SELECT"] {
                Task {
                    for _ in 0..<40 where docker.containers.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
                    if let c = docker.containers.first(where: { $0.name == name }) { docker.choose(c) }
                }
            }
        }
        // ZTERM_DEMO_STACK=web,postgres : nyalakan layanan Server Lokal (folder ZTERM_STACK_ROOT)
        if let list = env["ZTERM_DEMO_STACK"] {
            section = .localServer
            Task {
                // ZTERM_DEMO_STACK_DOCROOT=folder proyek; ZTERM_DEMO_STACK_INSTALL=php,... unduh komponen dulu
                if let root = env["ZTERM_DEMO_STACK_DOCROOT"] { stack.settings.docRoot = root; stack.saveSettings() }
                for id in (env["ZTERM_DEMO_STACK_INSTALL"] ?? "").split(separator: ",") { stack.install(String(id)) }
                for _ in 0..<600 where !stack.downloads.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
                for s in list.split(separator: ",") { await stack.toggle(String(s)) }
                // ZTERM_DEMO_STACK_OPENDB=postgres : buka koneksi lokal di halaman Database
                if let db = env["ZTERM_DEMO_STACK_OPENDB"], let svc = stack.service(db) {
                    let engine: DbEngine = db == "mysql" ? .mysql : db == "postgres" ? .postgres : .mongodb
                    let conn = DbConnection(id: "", label: "Lokal · \(db)", engine: engine, host: "127.0.0.1", port: svc.port,
                                            username: db == "mysql" ? "root" : db == "postgres" ? "postgres" : "", password: nil,
                                            database: "", filePath: "", tls: false, sshHostId: nil, color: "#336791", updatedAt: 0, deleted: false)
                    save(conn)
                    if let saved = databases.first(where: { $0.label == conn.label }) { await openDatabase(saved) }
                }
            }
        }
        if let role = env["ZTERM_DEMO_TEAM"] {
            section = .team
            startTeamTimer()
            Task {
                if role == "admin" {
                    guard await createTeam(name: env["ZTERM_DEMO_TEAM_NAME"] ?? "Tim Ops"), let t = teams.first else { return }
                    await shareHosts(t, ids: Array(hs.prefix(2).map(\.id)))
                    for e in (env["ZTERM_DEMO_TEAM_INVITE"] ?? "").split(separator: ",") {
                        _ = await inviteToTeam(teams.first!, email: String(e))
                    }
                } else {
                    await refreshInvites()
                    if let inv = teamInvites.first { _ = await joinTeam(fileId: inv.fileId) }
                }
            }
        }
        if args.contains("-ZtermDemoLockCycle") {
            phase = .welcome
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in open(v) }
        }
    }
    #endif

    // MARK: Vault

    func createVault(password: String) async throws {
        let path = Config.vaultPath
        let v = try await Task.detached { try Vault.create(path: path, password: password) }.value
        if let email = pendingAccountEmail { try v.setAccountEmail(email: email) }
        open(v)
        BiometricUnlock.store(key: v.exportKey())
    }

    func unlock(password: String) async throws {
        let path = Config.vaultPath
        let v = try await Task.detached { try Vault.unlock(path: path, password: password) }.value
        open(v)
        BiometricUnlock.store(key: v.exportKey())
    }

    /// Pulihkan vault dari Google Drive di perangkat ini.
    func restore(password: String) async throws {
        guard let blob = pendingRemoteBlob else { return }
        let path = Config.vaultPath
        try blob.write(to: URL(fileURLWithPath: path), options: .atomic)
        do {
            let v = try await Task.detached { try Vault.unlock(path: path, password: password) }.value
            if let email = pendingAccountEmail { try v.setAccountEmail(email: email) }
            pendingRemoteBlob = nil
            open(v)
            BiometricUnlock.store(key: v.exportKey())
        } catch {
            try? FileManager.default.removeItem(atPath: path)
            throw error
        }
    }

    func unlockWithBiometrics() async throws {
        let key = try await BiometricUnlock.retrieve()
        let path = Config.vaultPath
        let v = try await Task.detached { try Vault.unlockWithKey(path: path, key: key) }.value
        open(v)
    }

    func lock() {
        Task { await sftp.disconnect() }
        sessions.forEach { $0.terminate() }
        tunnels.stopAll()
        syncTask?.cancel()
        teamTimer?.cancel()
        teams = []; teamKeys = []; teamInvites = []; teamError = nil
        sessions = []
        activeSessionID = nil
        vault = nil
        hosts = []; keys = []; snippets = []; forwards = []; logs = []; databases = []
        dbWorkspace = nil
        dashboard.reset()
        admin.close()
        Task { await admin.select(nil, model: self) }
        backups.stopTimer()
        runMany = nil
        withAnimation(.zterm) { phase = .locked }
    }

    private func open(_ v: Vault) {
        vault = v
        reload()
        accountEmail = v.accountEmail()
        sync = accountEmail == nil ? .off : .idle
        withAnimation(.zterm) { phase = .main }
        if accountEmail != nil { syncNow() }
        Task { await checkForUpdates(manual: false) }
        startTeamTimer()
        backups.startTimer(app: self)
        Task { await backups.runDue(self) }
    }

    /// Cek rilis baru. `manual` = dipanggil dari menu, tampilkan hasil walau sudah terbaru.
    func checkForUpdates(manual: Bool) async {
        if updateBusy { return }
        do {
            let u = try await UpdateChecker.check()
            withAnimation(.zterm) { update = u; if u != nil { updateDismissed = false } }
            if manual && u == nil { flash(L("Zterm {} sudah versi terbaru", AppVersion.current)) }
        } catch {
            if manual { flash(L("Gagal memeriksa pembaruan")) }
        }
    }

    /// Sembunyikan notifikasi untuk sesi ini. Pemeriksaan berikutnya (mis. saat app dibuka lagi) menampilkannya lagi.
    func dismissUpdate() {
        withAnimation(.zterm) { updateDismissed = true }
    }

    /// Unduh DMG, verifikasi checksum, siapkan bundle pengganti, lalu tutup app.
    /// Helper shell menunggu proses ini keluar, mengganti Zterm.app, dan membukanya kembali.
    func installUpdate() async {
        guard let u = update, !updateBusy else { return }
        updateBusy = true
        updateDismissed = false
        updateProgress = 0
        updatePercent = -1
        updateAcceptingProgress = true
        updateStatus = L("Mengunduh pembaruan…")

        let progress: (Double) -> Void = { [weak self] p in
            Task { @MainActor in
                guard let self, self.updateAcceptingProgress else { return }
                self.updateProgress = min(max(p, 0), 1)
                let pct = min(99, Int((p * 100).rounded()))
                if pct == self.updatePercent { return }
                self.updatePercent = pct
                self.updateStatus = pct > 0
                    ? L("Mengunduh pembaruan… {}%", pct)
                    : L("Mengunduh pembaruan…")
            }
        }

        do {
            let dmg = try await UpdateInstaller.download(u, progress: progress)
            updateAcceptingProgress = false
            updateProgress = 1
            updateStatus = L("Memverifikasi pembaruan…")
            try await Task.detached(priority: .userInitiated) {
                try UpdateInstaller.verify(u, dmg: dmg)
            }.value

            updateStatus = L("Menyiapkan pembaruan…")
            let plan = try await Task.detached(priority: .userInitiated) {
                try UpdateInstaller.prepare(dmg: dmg, version: u.version)
            }.value
            try? await Task.sleep(nanoseconds: 350_000_000)

            updateStatus = L("Zterm akan ditutup dan dibuka ulang.")
            try? await Task.sleep(nanoseconds: 700_000_000)

            try UpdateInstaller.launch(plan)
            await sftp.disconnect()
            sessions.forEach { $0.terminate() }
            tunnels.stopAll()
            NSApplication.shared.terminate(nil)
            // Jaring pengaman: kalau terminate tertahan, paksa keluar supaya
            // helper bisa mengganti bundle tanpa menunggu PID selamanya.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
        } catch {
            updateAcceptingProgress = false
            updateBusy = false
            updateProgress = 0
            updatePercent = -1
            updateStatus = nil
            flash(L("Gagal memasang pembaruan: {}", error.localizedDescription))
        }
    }

    private func reload() {
        guard let vault else { return }
        teams = vault.teams()
        // Host tim ikut tampil di daftar host (read-only); key-nya disimpan terpisah dari Keychain.
        hosts = vault.hosts() + vault.teamHosts()
        teamKeys = vault.teamKeys()
        keys = vault.keys()
        snippets = vault.snippets()
        forwards = vault.forwards()
        logs = vault.logs()
        databases = vault.databases()
        // Notifikasi Dashboard aktif → pantau terus, ikut perubahan host
        if dashboard.alerts { dashboard.start(self) }
    }

    // MARK: Dashboard

    func setDashboardAlerts(_ on: Bool) async {
        if on, !(await Notifier.shared.requestPermission()) {
            flash(L("Notifikasi diblokir — izinkan Zterm di System Settings → Notifications"))
            return
        }
        withAnimation(.ztermSnappy) { dashboard.alerts = on }
        if on {
            dashboard.start(self)
            flash(L("Notifikasi aktif — Dashboard memantau semua server di latar belakang"))
        } else if section != .dashboard || activeSessionID != nil {
            dashboard.stop()
        }
    }

    /// Buka sheet "Jalankan perintah"; `ids` kosong → semua server yang online (atau semua host).
    func openRunMany(_ ids: [String]) {
        var chosen = Set(ids)
        if chosen.isEmpty {
            chosen = Set(dashboard.tiles.values.filter { $0.state == .online }.map(\.id))
            if chosen.isEmpty { chosen = Set(hosts.map(\.id)) }
        }
        runMany = RunManyModel(targets: chosen)
    }

    /// Dipanggil setelah setiap perubahan data: muat ulang tampilan & jadwalkan sync.
    private func changed(animated: Bool = true) {
        if animated { withAnimation(.zterm) { reload() } } else { reload() }
        scheduleSync()
    }

    // MARK: Akun Google & sync

    /// Login Google. Jika vault sudah ada di Drive, kembalikan `true` (perlu dipulihkan).
    /// Nama & foto profil Google (hanya disimpan di Mac ini, bukan di vault).
    var profileName: String? = UserDefaults.standard.string(forKey: "profile.name")
    var profilePicture: URL? = UserDefaults.standard.string(forKey: "profile.picture").flatMap(URL.init(string:))

    private func saveProfile(name: String?, picture: String?) {
        UserDefaults.standard.set(name, forKey: "profile.name")
        UserDefaults.standard.set(picture, forKey: "profile.picture")
        profileName = name
        profilePicture = picture.flatMap(URL.init(string:))
    }

    func signInGoogle() async throws -> Bool {
        let r = try await GoogleAuth().signIn()
        saveProfile(name: r.name, picture: r.picture)
        pendingAccountEmail = r.email
        if vault != nil {
            try vault?.setAccountEmail(email: r.email)
            accountEmail = r.email
            sync = .idle
            syncNow()
            return false
        }
        if let file = try await DriveClient.find() {
            pendingRemoteBlob = try await DriveClient.download(file)
            return true
        }
        return false
    }

    func disconnectGoogle() {
        GoogleTokens.forget()
        saveProfile(name: nil, picture: nil)
        try? vault?.setAccountEmail(email: nil)
        accountEmail = nil
        remoteFile = nil
        withAnimation(.zterm) { sync = .off }
    }

    /// Keluar dari akun.
    /// - `deleteLocal == false`: putuskan Google & kunci vault; data tetap terenkripsi di Mac ini.
    /// - `deleteLocal == true`: hapus vault, kunci Touch ID, dan token dari Mac ini → kembali ke layar sambutan.
    ///   Salinan di Google Drive tidak dihapus, jadi bisa dipulihkan dengan login lagi.
    func signOut(deleteLocal: Bool) {
        disconnectGoogle()
        lock()
        guard deleteLocal else { return }
        try? FileManager.default.removeItem(atPath: Config.vaultPath)
        BiometricUnlock.forget()
        pendingRemoteBlob = nil
        pendingAccountEmail = nil
        withAnimation(.zterm) { phase = .welcome }
    }

    /// Aktifkan Touch ID untuk vault yang sedang terbuka.
    func enableBiometric() {
        if let v = vault { BiometricUnlock.store(key: v.exportKey()) }
    }

    var lastSynced: Date? { if case .synced(let d) = sync { d } else { nil } }

    private func scheduleSync() {
        guard accountEmail != nil else { return }
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            await self?.performSync()
        }
    }

    func syncNow() {
        guard accountEmail != nil else { return }
        syncTask?.cancel()
        syncTask = Task { [weak self] in await self?.performSync() }
    }

    private func performSync() async {
        guard let vault else { return }
        guard GoogleTokens.hasRefreshToken else {
            withAnimation(.zterm) { sync = .needsLogin }
            return
        }
        withAnimation(.zterm) { sync = .syncing }
        do {
            let remote = try await DriveClient.find()
            remoteFile = remote
            if let remote {
                let blob = try await DriveClient.download(remote)
                let outcome = try vault.mergeRemote(blob: blob)
                if outcome.localChanged { withAnimation(.zterm) { reload() } }
                if outcome.remoteOutdated { try await DriveClient.upload(try vault.encryptedBlob(), replacing: remote) }
            } else {
                try await DriveClient.upload(try vault.encryptedBlob(), replacing: nil)
            }
            withAnimation(.zterm) { sync = .synced(Date()) }
            if !teams.isEmpty { await syncTeams() }
        } catch is CancellationError {
        } catch DriveError.notSignedIn {
            withAnimation(.zterm) { sync = .needsLogin }
        } catch {
            withAnimation(.zterm) { sync = .failed(error.ztermMessage) }
        }
    }

    // MARK: Hosts

    @discardableResult
    func save(_ host: Host) -> Host? {
        guard let vault else { return nil }
        guard !host.isTeam else { flash(L("Host tim hanya bisa diubah admin tim")); return nil }
        do {
            let saved = try vault.upsertHost(host: host)
            // Tab yang sedang terbuka untuk host ini langsung memakai tema baru
            for s in sessions where s.host.id == saved.id && s.themeID != saved.terminalTheme {
                s.applyTheme(saved.terminalTheme)
            }
            changed()
            return saved
        } catch {
            flash(error.ztermMessage)
            return nil
        }
    }

    func delete(_ host: Host) {
        guard !host.isTeam else { flash(L("Host tim hanya bisa diubah admin tim")); return }
        try? vault?.deleteHost(id: host.id)
        selection.remove(host.id)
        changed()
    }

    func host(id: String?) -> Host? { hosts.first { $0.id == id } }
    func key(id: String?) -> SshKey? { keys.first { $0.id == id } ?? teamKeys.first { $0.id == id } }
    /// Host pribadi saja (tanpa host tim).
    var ownHosts: [Host] { hosts.filter { !$0.isTeam } }

    // MARK: Keychain

    func generateKey(label: String) throws -> SshKey {
        guard let vault else { throw CoreError.NotFound }
        let k = try vault.generateKey(label: label)
        changed()
        return k
    }

    func importKey(label: String, privateKey: String, passphrase: String?) throws {
        guard let vault else { return }
        _ = try vault.importKey(label: label, privateKey: privateKey, passphrase: passphrase)
        changed()
    }

    func renameKey(_ key: SshKey, to label: String) {
        try? vault?.renameKey(id: key.id, label: label)
        changed(animated: false)
    }

    func deleteKey(_ key: SshKey) {
        try? vault?.deleteKey(id: key.id)
        changed()
    }

    // MARK: Snippets

    func save(_ snippet: Snippet) {
        do { _ = try vault?.upsertSnippet(snippet: snippet); changed() }
        catch { flash(error.ztermMessage) }
    }

    func delete(_ snippet: Snippet) {
        try? vault?.deleteSnippet(id: snippet.id)
        changed()
    }

    /// Kirim perintah ke tab terminal yang sedang aktif.
    func runInActiveSession(_ snippet: Snippet) {
        guard let s = sessions.first(where: { $0.id == activeSessionID }) else { return }
        s.send(snippet.command + "\n")
    }

    // MARK: Port forwarding

    func save(_ forward: PortForward) {
        do { _ = try vault?.upsertForward(forward: forward); changed() }
        catch { flash(error.ztermMessage) }
    }

    func delete(_ forward: PortForward) {
        tunnels.stop(forward.id)
        try? vault?.deleteForward(id: forward.id)
        changed()
    }

    func toggleTunnel(_ forward: PortForward) {
        if tunnels.isRunning(forward.id) {
            tunnels.stop(forward.id)
        } else if let h = host(id: forward.hostId) {
            tunnels.start(forward, host: h, key: key(id: h.keyId), jump: host(id: h.jumpHostId))
        } else {
            flash(L("Host untuk aturan ini sudah tidak ada"))
        }
    }

    // MARK: Database

    func save(_ db: DbConnection) {
        do { _ = try vault?.upsertDatabase(conn: db); changed() }
        catch { flash(error.ztermMessage) }
    }

    func delete(_ db: DbConnection) {
        if dbWorkspace?.conn.id == db.id { dbWorkspace = nil }
        try? vault?.deleteDatabase(id: db.id)
        changed()
    }

    func openDatabase(_ db: DbConnection) async {
        let ws = DbWorkspace(conn: db)
        withAnimation(.zterm) {
            section = .database
            activeSessionID = nil
            dbWorkspace = ws
        }
        await ws.connect(ssh: sshTarget(forId: db.sshHostId))
    }

    /// Target SSH dari host tersimpan (untuk tunnel database & SFTP).
    func sshTarget(forId id: String?) -> SshTarget? {
        guard let h = host(id: id) else { return nil }
        let k = key(id: h.keyId)
        return SshTarget(hostname: h.hostname, port: h.port, username: h.username,
                         password: h.auth == .password ? h.password : nil,
                         privateKey: h.auth == .key ? k?.privateKey : nil,
                         passphrase: h.auth == .key ? k?.passphrase : nil,
                         useAgent: true, proxy: h.proxy)
    }

    // MARK: SFTP

    func openSftp(_ host: Host) async {
        withAnimation(.ztermSnappy) {
            section = .sftp
            activeSessionID = nil
        }
        await sftp.connect(host, key: key(id: host.keyId))
    }

    // MARK: Logs

    func logStart(_ host: Host) -> String? {
        let id = try? vault?.startLog(hostId: host.id, hostLabel: host.title, address: host.address)
        changed(animated: false)
        return id
    }

    func logEnd(_ id: String?, code: Int32?) {
        guard let id else { return }
        try? vault?.finishLog(id: id, exitCode: code)
        changed(animated: false)
    }

    func clearLogs() {
        try? vault?.clearLogs()
        changed()
    }

    // MARK: Sesi

    /// Buka satu tab per host. `run` = perintah yang dikirim setelah tersambung (dari snippet).
    func connect(_ ids: [String], run: String? = nil) {
        let targets = ids.compactMap { id in hosts.first { $0.id == id } }
        guard !targets.isEmpty else { return }
        for (i, h) in targets.enumerated() {
            // Muncul satu per satu agar animasi tab terasa
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.08) { [self] in
                let s = TerminalSession(host: h, key: key(id: h.keyId), jump: host(id: h.jumpHostId), run: run, model: self)
                withAnimation(.ztermSnappy) {
                    sessions.append(s)
                    if i == 0 { activeSessionID = s.id }
                }
            }
        }
        selection.removeAll()
    }

    /// Hubungkan / putus panel Info server mengikuti tab aktif.
    func syncServerStats() {
        guard showServerInfo, let s = activeSession, !s.isLocal, let target = sshTarget(forId: s.host.id) else {
            serverStats?.stop()
            serverStats = nil
            return
        }
        if serverStats?.host.id == s.host.id { return }
        serverStats?.stop()
        let st = ServerStats(host: s.host)
        serverStats = st
        st.start(target: target)
    }

    func retryServerStats() {
        guard let st = serverStats, let target = sshTarget(forId: st.host.id) else { return }
        st.retry(target: target)
    }

    /// Buka tab terminal lokal (shell di Mac ini).
    func openLocalTerminal(run: String? = nil) {
        let s = TerminalSession(host: TerminalSession.localHost(), key: nil, jump: nil, run: run, model: self, local: true)
        withAnimation(.ztermSnappy) {
            sessions.append(s)
            activeSessionID = s.id
        }
    }

    func close(_ session: TerminalSession) {
        session.terminate()
        guard let idx = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        withAnimation(.ztermSnappy) {
            removeFromSplit(session.id)
            sessions.remove(at: idx)
            if activeSessionID == session.id {
                activeSessionID = sessions.isEmpty ? nil : sessions[max(0, idx - 1)].id
            }
        }
    }

    /// Tab terminal yang sedang tampil.
    var activeSession: TerminalSession? {
        sessions.first { $0.id == activeSessionID }
    }

    /// View terminal dari tab yang sedang tampil (nil jika di daftar host).
    var activeTerminalView: ZtermTerminalView? {
        sessions.first { $0.id == activeSessionID }?.view
    }

    func closeActive() {
        if let s = sessions.first(where: { $0.id == activeSessionID }) { close(s) }
    }

    func focusTab(number n: Int) {
        guard n >= 1, n <= sessions.count else { return }
        withAnimation(.ztermSnappy) { activeSessionID = sessions[n - 1].id }
    }

    func showHome() {
        withAnimation(.ztermSnappy) { activeSessionID = nil }
    }

    // MARK: Split & broadcast

    /// Tab yang ditampilkan berdampingan (2–4). Tampil saat tab aktif termasuk di dalamnya.
    var splitIDs: [UUID] = []
    /// Ketikan di satu panel dikirim ke semua panel split.
    var broadcast = false
    @ObservationIgnored private var broadcasting = false
    static let maxSplit = 4

    var splitVisible: Bool { splitIDs.count > 1 && activeSessionID.map(splitIDs.contains) == true }
    var canSplit: Bool { activeSession != nil && (splitVisible ? splitIDs.count < Self.maxSplit : true) }

    private func addToSplit(_ id: UUID) {
        guard let active = activeSessionID else { return }
        withAnimation(.ztermSnappy) {
            if !splitVisible { splitIDs = [active] }
            if !splitIDs.contains(id), splitIDs.count < Self.maxSplit { splitIDs.append(id) }
            activeSessionID = id
        }
    }

    /// Gabungkan tab yang sudah terbuka ke split.
    func split(with session: TerminalSession) { addToSplit(session.id) }

    /// Buka host baru langsung di panel split.
    func splitNew(_ host: Host) {
        guard canSplit else { return }
        let s = TerminalSession(host: host, key: key(id: host.keyId), jump: self.host(id: host.jumpHostId), model: self)
        sessions.append(s)
        addToSplit(s.id)
    }

    /// Buka beberapa host sekaligus dalam satu split (dari Dashboard), opsional langsung broadcast.
    func openSplit(_ ids: [String], broadcast on: Bool) {
        let hs = ids.compactMap { host(id: $0) }.prefix(Self.maxSplit)
        guard !hs.isEmpty else { return }
        let new = hs.map { h in TerminalSession(host: h, key: key(id: h.keyId), jump: host(id: h.jumpHostId), model: self) }
        sessions.append(contentsOf: new)
        withAnimation(.ztermSnappy) {
            splitIDs = new.count > 1 ? new.map(\.id) : []
            activeSessionID = new.first?.id
            broadcast = on && new.count > 1
        }
    }

    /// Panel baru ke host yang sama dengan tab aktif (⌘D).
    func splitDuplicate() {
        guard let s = activeSession, canSplit else { return }
        if s.isLocal {
            let n = TerminalSession(host: TerminalSession.localHost(), key: nil, jump: nil, model: self, local: true)
            sessions.append(n)
            addToSplit(n.id)
        } else {
            splitNew(s.host)
        }
    }

    func removeFromSplit(_ id: UUID) {
        withAnimation(.ztermSnappy) {
            splitIDs.removeAll { $0 == id }
            if splitIDs.count < 2 { splitIDs = []; broadcast = false }
        }
    }

    func unsplit() {
        withAnimation(.ztermSnappy) { splitIDs = []; broadcast = false }
    }

    func toggleBroadcast() {
        guard splitVisible else { return }
        withAnimation(.ztermSnappy) { broadcast.toggle() }
    }

    /// Panel yang diklik jadi tab aktif.
    func focusPane(_ id: UUID) {
        guard splitVisible, splitIDs.contains(id), activeSessionID != id else { return }
        activeSessionID = id
    }

    /// Teruskan ketikan dari satu panel ke panel split lain (saat broadcast menyala).
    /// Balasan otomatis terminal (laporan posisi kursor, atribut perangkat, warna OSC, fokus) — bukan ketikan,
    /// jadi tidak boleh ikut di-broadcast ke panel lain.
    static func isTerminalReply(_ data: ArraySlice<UInt8>) -> Bool {
        guard data.count >= 3, data.first == 0x1B else { return false }
        let s = String(decoding: data, as: UTF8.self)
        return s.range(of: #"^(\e\[\??[0-9;]*[Rcn]|\e\[[>=?][0-9;]*c|\e\][0-9]+;[^\a\e]*(\a|\e\\)|\e\[[IO]|\e\[\??[0-9;]*\$y|\eP[^\e]*\e\\)+$"#, options: .regularExpression) != nil
    }

    func broadcastInput(from source: TerminalSession, data: ArraySlice<UInt8>) {
        guard broadcast, !broadcasting, splitVisible, splitIDs.contains(source.id), !Self.isTerminalReply(data) else { return }
        broadcasting = true
        defer { broadcasting = false }
        for s in sessions where s.id != source.id && splitIDs.contains(s.id) {
            if case .disconnected = s.status { continue }
            s.view.send(source: s.view, data: data)
        }
    }

    // MARK: Tim

    /// Akun Google sudah memberi izin drive.file (dibutuhkan untuk file Tim).
    var teamReady: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["ZTERM_TEST_DRIVE_TOKEN"] != nil { return true }
        #endif
        return accountEmail != nil && GoogleTokens.hasDriveFileScope
    }

    func driveToken() async throws -> String {
        #if DEBUG
        if let t = ProcessInfo.processInfo.environment["ZTERM_TEST_DRIVE_TOKEN"] { return t }
        #endif
        return try await GoogleTokens.validAccessToken()
    }

    /// Jalankan operasi Tim dengan token Google; error ditampilkan di halaman Tim.
    @discardableResult
    private func teamCall<T>(quiet: Bool = false, _ op: (Vault, String) async throws -> T) async -> T? {
        guard let vault else { return nil }
        if !quiet { teamBusy = true }
        defer { if !quiet { teamBusy = false } }
        do {
            let r = try await op(vault, try await driveToken())
            if !quiet { teamError = nil }
            withAnimation(.zterm) { reload() }
            return r
        } catch CoreError.GoogleScope {
            GoogleTokens.markDriveFileScope(false)
            teamError = CoreError.GoogleScope.ztermMessage
        } catch DriveError.notSignedIn, CoreError.GoogleAuth {
            withAnimation(.zterm) { sync = .needsLogin }
            teamError = CoreError.GoogleAuth.ztermMessage
        } catch {
            if !quiet { teamError = error.ztermMessage }
        }
        return nil
    }

    func createTeam(name: String) async -> Bool {
        guard let email = teamEmail else { return false }
        let ok = await teamCall { v, t in try await v.teamCreate(token: t, name: name, myEmail: email) } != nil
        if ok { flash(L("Tim {} dibuat", name)) }
        return ok
    }

    func inviteToTeam(_ team: TeamInfo, email: String) async -> Bool {
        let ok = await teamCall { v, t in try await v.teamInvite(token: t, teamId: team.id, email: email) } != nil
        if ok { flash(L("Undangan dikirim ke {}", email)) }
        return ok
    }

    func removeFromTeam(_ team: TeamInfo, email: String) async {
        if await teamCall({ v, t in try await v.teamRemoveMember(token: t, teamId: team.id, email: email) }) != nil {
            flash(L("{} dikeluarkan · kunci tim diganti", email))
        }
    }

    func shareHosts(_ team: TeamInfo, ids: [String]) async {
        await teamCall { v, t in try await v.teamShareHosts(token: t, teamId: team.id, hostIds: ids) }
    }

    func refreshInvites() async {
        if let list = await teamCall(quiet: true, { v, t in try await v.teamFindInvites(token: t) }) {
            withAnimation(.zterm) { teamInvites = list }
        }
    }

    func joinTeam(fileId: String) async -> Bool {
        guard let email = teamEmail else { return false }
        let id = Self.fileId(from: fileId)
        guard let info = await teamCall({ v, t in try await v.teamJoin(token: t, fileId: id, myEmail: email) }) else { return false }
        teamInvites.removeAll { $0.fileId == id }
        flash(info.status == .active ? L("Bergabung ke {}", info.name) : L("Bergabung ke {} · menunggu admin", info.name))
        return true
    }

    func leaveTeam(_ team: TeamInfo) async {
        if await teamCall({ v, t in try await v.teamLeave(token: t, teamId: team.id) }) != nil {
            flash(team.isOwner ? L("Tim {} dihapus", team.name) : L("Keluar dari {}", team.name))
        }
    }

    /// Sinkron semua tim (diam-diam; error per tim tampil di kartunya).
    func syncTeams() async {
        guard teamReady, !teams.isEmpty else { return }
        await teamCall(quiet: true) { v, t in try await v.teamSync(token: t) }
    }

    /// Minta izin drive.file: login ulang Google dengan scope baru.
    func grantTeamAccess() async {
        do {
            _ = try await signInGoogle()
            teamError = GoogleTokens.hasDriveFileScope ? nil : L("Izin Google Drive belum dicentang. Coba lagi dan centang izin Drive.")
        } catch GoogleAuth.AuthError.cancelled {
        } catch {
            teamError = error.ztermMessage
        }
    }

    private var teamEmail: String? {
        #if DEBUG
        if let e = ProcessInfo.processInfo.environment["ZTERM_TEST_DRIVE_EMAIL"] { return e }
        #endif
        guard let e = accountEmail else { teamError = L("Masuk dengan Google dulu untuk memakai Tim"); return nil }
        return e
    }

    /// Terima id file atau link Google Drive (…/d/<id>/… atau ?id=<id>).
    static func fileId(from text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = t.range(of: #"/d/([A-Za-z0-9_-]+)"#, options: .regularExpression) {
            return String(t[r].dropFirst(3))
        }
        if let c = URLComponents(string: t), let id = c.queryItems?.first(where: { $0.name == "id" })?.value { return id }
        return t
    }

    private func startTeamTimer() {
        teamTimer?.cancel()
        teamTimer = Task { [weak self] in
            while !Task.isCancelled {
                var every = 60.0
                #if DEBUG
                every = ProcessInfo.processInfo.environment["ZTERM_TEAM_SYNC_SECS"].flatMap(Double.init) ?? every
                #endif
                try? await Task.sleep(for: .seconds(every))
                guard let self, self.phase == .main else { continue }
                await self.syncTeams()
            }
        }
    }

    func flash(_ message: String) {
        withAnimation(.zterm) { toast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [self] in
            if toast == message { withAnimation(.zterm) { toast = nil } }
        }
    }
}

extension Host {
    /// Host dari tim yang diikuti (hanya admin tim yang bisa mengubah).
    var isTeam: Bool { id.hasPrefix("team:") }

    static func blank() -> Host {
        Host(id: "", hostname: "", label: "", group: nil, tags: [], color: Theme.hostColors[0],
             port: 22, username: "root", auth: .password, password: nil, keyId: nil,
             agentForwarding: false, startupSnippet: nil, jumpHostId: nil, proxy: nil, env: [],
             charset: "UTF-8", terminalTheme: nil, updatedAt: 0, deleted: false)
    }

    var title: String { label.isEmpty ? hostname : label }
    var address: String { "\(username)@\(hostname)" + (port == 22 ? "" : ":\(port)") }

    /// Alamat yang disamarkan untuk tampilan (privasi saat berbagi layar).
    func displayAddress(hidden: Bool) -> String {
        hidden ? "\(username)@••••••••" : address
    }
}

extension Host: Identifiable {}
extension SshKey: Identifiable {}
extension Snippet: Identifiable {}
extension PortForward: Identifiable {}
extension SessionLog: Identifiable {}

/// Kunci pengaturan "sembunyikan alamat host".
enum PrivacyKeys {
    static let hideAddresses = "hideAddresses"
}
