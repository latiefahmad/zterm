import AppKit
import SwiftUI

/// Layanan database siap pakai. Beberapa memakai protokol engine lain (mis. CockroachDB = PostgreSQL).
struct DbPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let engine: DbEngine
    let port: UInt16
    let tls: Bool
    let color: String
    let abbr: String
    let hint: String

    static let all: [DbPreset] = [
        DbPreset(id: "postgres", name: "PostgreSQL", engine: .postgres, port: 5432, tls: false, color: "#336791", abbr: "PG", hint: L("Database relasional open source")),
        DbPreset(id: "mysql", name: "MySQL", engine: .mysql, port: 3306, tls: false, color: "#00758F", abbr: "My", hint: L("Database relasional populer")),
        DbPreset(id: "mariadb", name: "MariaDB", engine: .mariadb, port: 3306, tls: false, color: "#C0765A", abbr: "Ma", hint: L("Turunan MySQL")),
        DbPreset(id: "sqlserver", name: "SQL Server", engine: .sqlserver, port: 1433, tls: false, color: "#CC2927", abbr: "MS", hint: "Microsoft SQL Server / MSSQL"),
        DbPreset(id: "sqlite", name: "SQLite", engine: .sqlite, port: 0, tls: false, color: "#0F80CC", abbr: "SL", hint: L("File database lokal")),
        DbPreset(id: "redis", name: "Redis", engine: .redis, port: 6379, tls: false, color: "#DC382D", abbr: "Rd", hint: "Key-value in-memory"),
        DbPreset(id: "mongodb", name: "MongoDB", engine: .mongodb, port: 27017, tls: false, color: "#47A248", abbr: "Mg", hint: L("Database dokumen")),
        DbPreset(id: "clickhouse", name: "ClickHouse", engine: .clickhouse, port: 8123, tls: false, color: "#E8B500", abbr: "CH", hint: L("Analitik kolumnar (HTTP)")),
        // Kompatibel protokol
        DbPreset(id: "cockroach", name: "CockroachDB", engine: .postgres, port: 26257, tls: true, color: "#6933FF", abbr: "Cr", hint: L("Protokol PostgreSQL")),
        DbPreset(id: "timescale", name: "TimescaleDB", engine: .postgres, port: 5432, tls: false, color: "#FDB515", abbr: "Ts", hint: L("Time-series di atas PostgreSQL")),
        DbPreset(id: "yugabyte", name: "YugabyteDB", engine: .postgres, port: 5433, tls: false, color: "#FF6E42", abbr: "Yb", hint: L("Protokol PostgreSQL")),
        DbPreset(id: "supabase", name: "Supabase", engine: .postgres, port: 5432, tls: true, color: "#3ECF8E", abbr: "Sb", hint: L("Postgres terkelola")),
        DbPreset(id: "neon", name: "Neon", engine: .postgres, port: 5432, tls: true, color: "#00E599", abbr: "Ne", hint: "Postgres serverless"),
        DbPreset(id: "rds-pg", name: "Amazon RDS PostgreSQL", engine: .postgres, port: 5432, tls: true, color: "#FF9900", abbr: "RP", hint: "AWS RDS / Aurora PostgreSQL"),
        DbPreset(id: "rds-my", name: "Amazon Aurora MySQL", engine: .mysql, port: 3306, tls: true, color: "#FF9900", abbr: "RM", hint: "AWS RDS / Aurora MySQL"),
        DbPreset(id: "tidb", name: "TiDB", engine: .mysql, port: 4000, tls: false, color: "#E30C34", abbr: "Ti", hint: L("Protokol MySQL")),
        DbPreset(id: "planetscale", name: "PlanetScale", engine: .mysql, port: 3306, tls: true, color: "#111111", abbr: "PS", hint: "MySQL serverless"),
        DbPreset(id: "percona", name: "Percona Server", engine: .mysql, port: 3306, tls: false, color: "#E4512B", abbr: "Pc", hint: L("Turunan MySQL")),
        DbPreset(id: "azure-sql", name: "Azure SQL", engine: .sqlserver, port: 1433, tls: true, color: "#0078D4", abbr: "Az", hint: L("SQL Server di Azure")),
        DbPreset(id: "valkey", name: "Valkey", engine: .redis, port: 6379, tls: false, color: "#6983FF", abbr: "Vk", hint: L("Protokol Redis")),
        DbPreset(id: "dragonfly", name: "Dragonfly", engine: .redis, port: 6379, tls: false, color: "#8B5CF6", abbr: "Df", hint: L("Protokol Redis")),
        DbPreset(id: "upstash", name: "Upstash Redis", engine: .redis, port: 6379, tls: true, color: "#00E9A3", abbr: "Up", hint: "Redis serverless"),
        DbPreset(id: "atlas", name: "MongoDB Atlas", engine: .mongodb, port: 27017, tls: true, color: "#00684A", abbr: "At", hint: L("Tempel URI mongodb+srv:// di kolom host")),
    ]

    static func forEngine(_ e: DbEngine) -> DbPreset { all.first { $0.engine == e }! }
    static func find(_ c: DbConnection) -> DbPreset {
        all.first { $0.color.uppercased() == c.color.uppercased() && $0.engine == c.engine } ?? forEngine(c.engine)
    }
}

extension DbEngine {
    var title: String { DbPreset.forEngine(self).name }
    var isSQL: Bool { self != .redis && self != .mongodb }
    var placeholderQuery: String {
        switch self {
        case .redis: "GET key\nHGETALL user:1"
        case .mongodb: "db.users.find({\"aktif\": true})"
        case .sqlserver: "SELECT TOP 100 * FROM dbo.users"
        default: "SELECT * FROM users LIMIT 100;"
        }
    }
}

extension DbConnection {
    static func blank(_ p: DbPreset) -> DbConnection {
        DbConnection(id: "", label: "", engine: p.engine, host: p.engine == .sqlite ? "" : "127.0.0.1", port: p.port,
                     username: defaultUser(p.engine), password: nil, database: "", filePath: "", tls: p.tls,
                     sshHostId: nil, color: p.color, updatedAt: 0, deleted: false)
    }

    static func defaultUser(_ e: DbEngine) -> String {
        switch e {
        case .postgres: "postgres"
        case .mysql, .mariadb: "root"
        case .sqlserver: "sa"
        case .clickhouse: "default"
        default: ""
        }
    }

    var title: String { label.isEmpty ? (engine == .sqlite ? (filePath as NSString).lastPathComponent : host) : label }
}

extension DbConnection: Identifiable {}

/// Database bawaan sistem: disembunyikan di grup tersendiri seperti phpMyAdmin.
extension DbEngine {
    var systemDatabases: Set<String> {
        switch self {
        case .mysql, .mariadb: ["information_schema", "mysql", "performance_schema", "sys"]
        case .sqlserver: ["master", "tempdb", "model", "msdb"]
        case .clickhouse: ["system", "INFORMATION_SCHEMA", "information_schema"]
        case .mongodb: ["admin", "local", "config"]
        default: []
        }
    }

    /// Engine yang bisa membaca tabel database lain tanpa pindah koneksi.
    var listsAcrossDatabases: Bool {
        switch self {
        case .postgres, .redis: false
        default: true
        }
    }

    var supportsStructure: Bool { isSQL }
}

/// Satu koneksi database yang sedang terbuka (tampilan ala phpMyAdmin).
@MainActor
@Observable
final class DbWorkspace: Identifiable {
    enum Status: Equatable { case connecting, ready, failed(String) }
    enum Tab: String, CaseIterable, Identifiable {
        case overview, browse, structure, search, sql
        var id: String { rawValue }
        var title: String {
            switch self {
            case .overview: L("Ringkasan")
            case .browse: L("Telusuri")
            case .structure: L("Struktur")
            case .search: L("Cari")
            case .sql: "SQL"
            }
        }
        var icon: String {
            switch self {
            case .overview: "square.grid.2x2"
            case .browse: "tablecells"
            case .structure: "list.bullet.rectangle"
            case .search: "magnifyingglass"
            case .sql: "chevron.left.forwardslash.chevron.right"
            }
        }
    }

    /// Satu baris form "Cari" (kueri dengan contoh, ala phpMyAdmin).
    struct SearchField: Identifiable, Equatable {
        let column: String
        let type: String
        var op: String
        var value = ""
        var id: String { column }

        /// Operator tanpa isian nilai.
        var needsValue: Bool { !["IS NULL", "IS NOT NULL", "= ''", "!= ''"].contains(op) }
        var isActive: Bool { !needsValue || !value.trimmingCharacters(in: .whitespaces).isEmpty }

        static let textOps = ["LIKE %...%", "NOT LIKE %...%", "LIKE", "NOT LIKE", "=", "!=", "IN (...)", "NOT IN (...)",
                              "BETWEEN", "NOT BETWEEN", "= ''", "!= ''", "IS NULL", "IS NOT NULL"]
        static let valueOps = ["=", "!=", ">", ">=", "<", "<=", "LIKE %...%", "LIKE", "NOT LIKE", "IN (...)", "NOT IN (...)",
                               "BETWEEN", "NOT BETWEEN", "IS NULL", "IS NOT NULL"]

        /// Kolom angka/tanggal: operator perbandingan dulu; teks: LIKE %...% dulu.
        static func isTextual(_ type: String) -> Bool {
            let t = type.lowercased()
            let nonText = ["int", "dec", "num", "float", "double", "real", "money", "serial", "bit", "bool", "date", "time", "year"]
            return !nonText.contains { t.contains($0) } || t.contains("char") || t.contains("text")
        }
        var ops: [String] { Self.isTextual(type) ? Self.textOps : Self.valueOps }
    }

    let id = UUID()
    var conn: DbConnection
    var status: Status = .connecting

    // Pohon database
    var databases: [String] = []
    var dbTables: [String: [DbTable]] = [:]
    var expanded: Set<String> = []
    var loadingDbs: Set<String> = []
    var activeDatabase: String?
    var showSystem = false

    // Pilihan
    var selectedDb: String?
    var selectedTable: DbTable?
    var tab: Tab = .overview

    // Telusuri (halaman data)
    var page: QueryResult?
    var pageSize: UInt32 = 100
    var offset: UInt64 = 0
    var totalRows: UInt64?
    var totalIsEstimate = false

    // Struktur
    var structure: QueryResult?

    // Cari: syarat aktif di Telusuri (dari form "Cari" atau kotak cari cepat)
    var searchForm: [SearchField] = []
    var filters: [DbFilter] = []
    var filterAny = false
    var quickSearch = ""
    var isFiltered: Bool { !filters.isEmpty }

    // SQL
    var query = ""
    var result: QueryResult?
    var history: [String] = []

    var running = false
    var error: String?

    @ObservationIgnored private var session: DbSession?
    @ObservationIgnored private var ssh: SshTarget?

    init(conn: DbConnection) {
        self.conn = conn
    }

    var userDatabases: [String] { databases.filter { !conn.engine.systemDatabases.contains($0) } }
    var systemDatabases: [String] { databases.filter { conn.engine.systemDatabases.contains($0) } }
    var availableTabs: [Tab] {
        if selectedTable != nil { return conn.engine.supportsStructure ? [.browse, .structure, .search, .sql] : [.browse, .sql] }
        return [.overview, .sql]
    }

    func connect(ssh: SshTarget?) async {
        self.ssh = ssh
        withAnimation(.zterm) { status = .connecting }
        do {
            let s = try await DbSession.connect(conn: conn, ssh: ssh)
            session = s
            var dbs = (try? await s.databases()) ?? []
            if conn.engine == .sqlite { dbs = ["main"] }
            let fallback: String? = switch conn.engine {
                case .sqlite: "main"
                case .postgres: "postgres"
                case .redis: "0"
                default: nil
            }
            let active = conn.database.isEmpty ? fallback : conn.database
            withAnimation(.zterm) {
                databases = dbs
                activeDatabase = active
                status = .ready
            }
            // Buka otomatis: database di koneksi, atau satu-satunya database pengguna
            if let a = active ?? (userDatabases.count == 1 ? userDatabases.first : nil) {
                await toggle(a, forceOpen: true)
                if selectedDb == nil { selectedDb = a }
            }
            if conn.engine == .redis || conn.engine == .sqlite, let a = active ?? databases.first {
                await toggle(a, forceOpen: true)
                selectedDb = a
            }
        } catch {
            withAnimation(.zterm) { status = .failed(error.ztermMessage) }
        }
    }

    /// Buka/tutup node database di pohon (tabel dimuat saat pertama dibuka).
    func toggle(_ db: String, forceOpen: Bool = false) async {
        if expanded.contains(db) && !forceOpen {
            _ = withAnimation(.ztermSnappy) { expanded.remove(db) }
            return
        }
        _ = withAnimation(.ztermSnappy) { expanded.insert(db) }
        if dbTables[db] == nil { await loadTables(db) }
    }

    func loadTables(_ db: String) async {
        guard session != nil else { return }
        loadingDbs.insert(db)
        defer { loadingDbs.remove(db) }
        do {
            let t: [DbTable]
            if conn.engine.listsAcrossDatabases {
                t = try await session!.tablesIn(database: db)
            } else {
                if activeDatabase != db { try await useDatabase(db) }
                t = try await session!.tables()
            }
            withAnimation(.zterm) { dbTables[db] = t }
        } catch {
            withAnimation(.zterm) { self.error = error.ztermMessage }
        }
    }

    func refresh() async {
        guard let session else { return }
        let dbs = (try? await session.databases()) ?? databases
        withAnimation(.ztermSnappy) { databases = conn.engine == .sqlite ? ["main"] : dbs }
        for db in expanded { await loadTables(db) }
        if let t = selectedTable, tab == .browse { await loadPage(t) }
    }

    /// Jadikan database aktif (USE / SELECT n / sambung ulang untuk PostgreSQL).
    private func useDatabase(_ db: String) async throws {
        guard let session else { return }
        if try await session.useDatabase(name: db) {
            activeDatabase = db
            return
        }
        // PostgreSQL: satu koneksi = satu database → sambung ulang
        var c = conn
        c.database = db
        let s = try await DbSession.connect(conn: c, ssh: ssh)
        self.session = s
        conn = c
        activeDatabase = db
    }

    /// Klik nama database: tampilkan ringkasan tabelnya.
    func selectDatabase(_ db: String) async {
        withAnimation(.zterm) {
            selectedDb = db
            selectedTable = nil
            tab = .overview
            error = nil
        }
        if activeDatabase != db, conn.engine != .sqlite {
            do { try await useDatabase(db) } catch { withAnimation(.zterm) { self.error = error.ztermMessage } }
        }
        if !expanded.contains(db) || dbTables[db] == nil { await toggle(db, forceOpen: true) }
    }

    func openTable(_ t: DbTable, in db: String) async {
        if activeDatabase != db, conn.engine != .sqlite {
            do { try await useDatabase(db) } catch { withAnimation(.zterm) { self.error = error.ztermMessage }; return }
        }
        withAnimation(.zterm) {
            selectedDb = db
            selectedTable = t
            if tab == .overview || (!conn.engine.supportsStructure && (tab == .structure || tab == .search)) { tab = .browse }
            offset = 0
            page = nil
            structure = nil
            searchForm = []
            filters = []
            quickSearch = ""
            totalRows = t.rows
            totalIsEstimate = t.rows != nil
            error = nil
        }
        if let session { query = session.pageSql(schema: t.schema, table: t.name, limit: pageSize, offset: 0) }
        await loadTab()
        // Hitung baris persis jika tabel tidak terlalu besar
        if conn.engine.isSQL, (t.rows ?? 0) < 2_000_000, let session,
           let n = try? await session.countRows(schema: t.schema, table: t.name), selectedTable?.name == t.name {
            withAnimation(.ztermSnappy) { totalRows = n; totalIsEstimate = false }
        }
    }

    func loadTab() async {
        guard let t = selectedTable else { return }
        switch tab {
        case .browse: if page == nil { await loadPage(t) }
        case .structure: if structure == nil { await loadStructure(t) }
        case .search: await prepareSearchForm(t)
        default: break
        }
    }

    // MARK: Cari

    /// Isi form "Cari" dari struktur tabel (kolom & tipe).
    func prepareSearchForm(_ t: DbTable) async {
        if structure == nil { await loadStructure(t) }
        guard searchForm.isEmpty, let s = structure else { return }
        let typeIdx = s.columns.firstIndex(of: "Tipe") ?? 1
        let fields = s.rows.compactMap { row -> SearchField? in
            guard let name = row.first ?? nil else { return nil }
            let type = (row.count > typeIdx ? row[typeIdx] : nil) ?? ""
            return SearchField(column: name, type: type, op: SearchField.isTextual(type) ? "LIKE %...%" : "=")
        }
        withAnimation(.zterm) { searchForm = fields }
    }

    /// Jalankan form "Cari": hasilnya tampil di Telusuri dengan paging.
    func submitSearch() async {
        let active = searchForm.filter(\.isActive).map {
            DbFilter(column: $0.column, op: $0.op, value: $0.value.trimmingCharacters(in: .whitespaces))
        }
        quickSearch = ""
        await applyFilters(active, any: false)
    }

    /// Kotak "Cari di tabel ini": cocokkan teks di semua kolom.
    func submitQuickSearch() async {
        let text = quickSearch.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { await clearFilters(); return }
        var cols = page?.columns ?? []
        if cols.isEmpty, let t = selectedTable { await loadStructure(t); cols = structure?.rows.compactMap { $0.first ?? nil } ?? [] }
        await applyFilters(cols.map { DbFilter(column: $0, op: "LIKE %...%", value: text) }, any: true)
    }

    func clearFilters() async {
        quickSearch = ""
        for i in searchForm.indices { searchForm[i].value = "" }
        await applyFilters([], any: false)
    }

    private func applyFilters(_ f: [DbFilter], any: Bool) async {
        guard let t = selectedTable else { return }
        withAnimation(.zterm) {
            filters = f
            filterAny = any
            offset = 0
            tab = .browse
            totalRows = f.isEmpty ? t.rows : nil
            totalIsEstimate = f.isEmpty && t.rows != nil
        }
        await loadPage(t)
        guard let session else { return }
        if let n = try? await session.countSearch(schema: t.schema, table: t.name, filters: f, any: any), selectedTable?.name == t.name {
            withAnimation(.ztermSnappy) { totalRows = n; totalIsEstimate = false }
        }
    }

    /// Ringkasan syarat aktif, mis. `kota = Medan · nama LIKE %di%`.
    var filterSummary: String {
        if filterAny { return L("“{}” di semua kolom", filters.first?.value ?? "") }
        return filters.map { f in
            switch f.op {
            case "IS NULL", "IS NOT NULL", "= ''", "!= ''": "\(f.column) \(f.op)"
            case "LIKE %...%": L("{} berisi “{}”", f.column, f.value)
            case "NOT LIKE %...%": L("{} tidak berisi “{}”", f.column, f.value)
            default: "\(f.column) \(f.op) \(f.value)"
            }
        }.joined(separator: " · ")
    }

    func loadPage(_ t: DbTable) async {
        guard let session else { return }
        withAnimation(.ztermSnappy) { running = true; error = nil }
        defer { withAnimation(.ztermSnappy) { running = false } }
        do {
            let r = filters.isEmpty
                ? try await session.page(schema: t.schema, table: t.name, limit: pageSize, offset: offset)
                : try await session.search(schema: t.schema, table: t.name, filters: filters, any: filterAny, limit: pageSize, offset: offset)
            withAnimation(.zterm) { page = r }
        } catch {
            withAnimation(.zterm) { self.error = error.ztermMessage }
        }
    }

    func loadStructure(_ t: DbTable) async {
        guard let session else { return }
        withAnimation(.ztermSnappy) { running = true; error = nil }
        defer { withAnimation(.ztermSnappy) { running = false } }
        do {
            let r = try await session.columns(schema: t.schema, table: t.name)
            withAnimation(.zterm) { structure = r }
        } catch {
            withAnimation(.zterm) { self.error = error.ztermMessage }
        }
    }

    func goToPage(offset newOffset: UInt64) async {
        guard let t = selectedTable else { return }
        offset = newOffset
        await loadPage(t)
    }

    func setPageSize(_ n: UInt32) async {
        pageSize = n
        offset = 0
        if let t = selectedTable { await loadPage(t) }
    }

    func run(_ sql: String? = nil) async {
        let text = (sql ?? query).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let session, !text.isEmpty, !running else { return }
        withAnimation(.ztermSnappy) { running = true; error = nil }
        defer { withAnimation(.ztermSnappy) { running = false } }
        do {
            let r = try await session.run(sql: text)
            withAnimation(.zterm) { result = r }
            if history.first != text { history.insert(text, at: 0); history = Array(history.prefix(30)) }
            // USE nama_db → ikuti di pohon
            if let m = text.firstMatch(of: /^\s*use\s+[`\[]?([^`\]\s;]+)/.ignoresCase()) {
                activeDatabase = String(m.1)
                selectedDb = String(m.1)
            }
            // Perubahan struktur → muat ulang pohon & data
            if text.range(of: #"^\s*(create|drop|alter|rename|truncate)"#, options: [.regularExpression, .caseInsensitive]) != nil {
                await refresh()
                structure = nil
            } else if text.range(of: #"^\s*(insert|update|delete|replace)"#, options: [.regularExpression, .caseInsensitive]) != nil {
                page = nil
            }
        } catch {
            withAnimation(.zterm) { self.error = error.ztermMessage }
        }
    }

    /// Hasil yang sedang tampil di tab aktif.
    var shownResult: QueryResult? {
        switch tab {
        case .browse: page
        case .structure: structure
        case .sql: result
        case .search: nil
        case .overview: nil
        }
    }

    /// Simpan hasil yang tampil sebagai CSV.
    func exportCSV() {
        guard let r = shownResult, !r.columns.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (selectedTable?.name ?? "hasil") + ".csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        func esc(_ v: String?) -> String {
            guard let v else { return "" }
            return v.contains(where: { ",\"\n".contains($0) }) ? "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : v
        }
        var lines = [r.columns.map { esc($0) }.joined(separator: ",")]
        lines += r.rows.map { $0.map(esc).joined(separator: ",") }
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

extension DbTable {
    var sizeText: String? {
        guard let size = sizeBytes, size > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
    var rowsText: String? { rows.map { $0.formatted(.number) } }
}
