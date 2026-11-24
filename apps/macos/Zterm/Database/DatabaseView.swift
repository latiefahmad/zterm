import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DatabaseView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            if let ws = model.dbWorkspace {
                DbWorkspaceView(ws: ws)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            } else {
                DbConnectionList()
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .animation(.zterm, value: model.dbWorkspace?.id)
    }
}

// MARK: - Daftar koneksi

struct DbConnectionList: View {
    @Environment(AppModel.self) private var model
    @AppStorage(PrivacyKeys.hideAddresses) private var hideAddresses = true
    @State private var editing: DbConnection?
    @State private var picking = false
    @State private var backingUp: DbConnection?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: "Database", subtitle: L("PostgreSQL, MySQL, MariaDB, SQL Server, SQLite, Redis, MongoDB, ClickHouse & lainnya")) {
                    Button { picking = true } label: { Label(L("Koneksi Baru"), systemImage: "plus") }
                        .buttonStyle(PrimaryButtonStyle())
                }
                if model.databases.isEmpty {
                    EmptyState(icon: "cylinder.split.1x2", title: L("Belum ada koneksi database"),
                               text: L("Sambungkan langsung, atau lewat tunnel SSH ke database yang hanya bisa diakses dari dalam server."))
                    EngineGrid { p in editing = .blank(p) }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 14)], spacing: 14) {
                        ForEach(Array(model.databases.enumerated()), id: \.element.id) { i, db in
                            DbCard(db: db, hidden: hideAddresses, onEdit: { editing = db }, onBackup: { backingUp = db })
                                .staggerIn(i, base: 0)
                        }
                    }
                }
            }
            .padding(28)
        }
        .sheet(isPresented: $picking) {
            VStack(alignment: .leading, spacing: 14) {
                Text(L("Pilih database")).font(.title3.bold())
                EngineGrid { p in picking = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { editing = .blank(p) } }
                HStack { Spacer(); Button(L("Batal")) { picking = false }.buttonStyle(SecondaryButtonStyle()) }
            }
            .padding(24)
            .frame(width: 640)
        }
        .sheet(item: $editing) { DbEditor(original: $0) }
        .sheet(item: $backingUp) { BackupSheet(db: $0) }
        .onAppear { if let d = model.demoBackup { backingUp = d; model.demoBackup = nil } }
    }
}

/// Logo engine: kotak warna dengan singkatan.
struct EngineBadge: View {
    let preset: DbPreset
    var size: CGFloat = 40
    var body: some View {
        Text(preset.abbr)
            .font(.system(size: size * 0.36, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color(hex: preset.color).gradient, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).strokeBorder(.white.opacity(0.2)))
            .shadow(color: Color(hex: preset.color).opacity(0.35), radius: 6, y: 2)
    }
}

struct EngineGrid: View {
    var onPick: (DbPreset) -> Void
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
            ForEach(Array(DbPreset.all.enumerated()), id: \.element.id) { i, p in
                Button { onPick(p) } label: {
                    VStack(spacing: 8) {
                        EngineBadge(preset: p, size: 38)
                        Text(p.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text(p.hint).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(EngineTileStyle())
                .staggerIn(i, base: 0)
            }
        }
    }
}

private struct EngineTileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Tile(configuration: configuration) }
    private struct Tile: View {
        let configuration: Configuration
        @State private var hover = false
        var body: some View {
            configuration.label
                .background(hover ? Theme.cardHover : Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(hover ? Theme.accent.opacity(0.5) : Theme.cardStroke))
                .scaleEffect(configuration.isPressed ? 0.96 : hover ? 1.02 : 1)
                .animation(.ztermSnappy, value: hover)
                .animation(.ztermSnappy, value: configuration.isPressed)
                .onHover { hover = $0 }
        }
    }
}

struct DbCard: View {
    @Environment(AppModel.self) private var model
    let db: DbConnection
    let hidden: Bool
    var onEdit: () -> Void
    var onBackup: () -> Void = {}

    private var preset: DbPreset { DbPreset.find(db) }
    private var address: String {
        if db.engine == .sqlite { return (db.filePath as NSString).abbreviatingWithTildeInPath }
        return hidden ? "\(db.username.isEmpty ? "" : db.username + "@")••••••••" : "\(db.host):\(db.port)"
    }

    var body: some View {
        HoverCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    EngineBadge(preset: preset, size: 42)
                    Spacer()
                    if backupSupported(engine: db.engine) {
                        let job = model.backups.jobs[db.id]
                        let sched = model.backups.schedule(db.id)
                        if job != nil {
                            ProgressView().controlSize(.small).frame(width: 28, height: 28).help(L("Backup berjalan…"))
                        } else {
                            IconButton(symbol: sched.frequency != .off ? "clock.badge.checkmark" : "externaldrive.badge.timemachine",
                                       help: sched.frequency != .off ? L("Backup terjadwal · {}", sched.frequency.title.lowercased()) : L("Backup & restore"),
                                       tint: sched.lastError != nil ? Color(hex: "#F0616D") : sched.frequency != .off ? Theme.accent : .primary, action: onBackup)
                        }
                    }
                    IconButton(symbol: "pencil", help: L("Edit"), action: onEdit)
                    IconButton(symbol: "trash", help: L("Hapus"), tint: .red) { model.delete(db) }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(db.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text(address).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 6) {
                    Badge(text: preset.name.uppercased(), color: Color(hex: preset.color)).fixedSize()
                    if db.sshHostId != nil {
                        Badge(text: "SSH", color: Theme.accent).fixedSize()
                    }
                    if !db.database.isEmpty { Badge(text: db.database.uppercased(), color: .gray).lineLimit(1) }
                    Spacer(minLength: 0)
                }
                Button { Task { await model.openDatabase(db) } } label: {
                    Label(L("Buka"), systemImage: "bolt.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle(wide: true))
            }
        }
        .onTapGesture(count: 2) { Task { await model.openDatabase(db) } }
    }
}

// MARK: - Form koneksi

struct DbEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let original: DbConnection
    @State private var c: DbConnection
    @State private var testing = false
    @State private var testResult: String?
    @State private var testOK = false

    init(original: DbConnection) {
        self.original = original
        _c = State(initialValue: original)
    }

    private var preset: DbPreset { DbPreset.find(c) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                EngineBadge(preset: preset, size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(original.id.isEmpty ? L("Koneksi {}", preset.name) : L("Edit koneksi")).font(.title3.bold())
                    Text(preset.hint).font(.caption).foregroundStyle(.secondary)
                }
            }
            TextField(L("Nama (mis. DB produksi)"), text: $c.label).ztermField()

            if c.engine == .sqlite {
                HStack {
                    TextField(L("Path file .sqlite / .db"), text: $c.filePath).ztermField()
                    Button(L("Pilih…")) { pickFile() }.buttonStyle(SecondaryButtonStyle())
                }
            } else {
                HStack(spacing: 8) {
                    TextField(c.engine == .mongodb ? L("Host atau URI mongodb+srv://…") : L("Host"), text: $c.host).ztermField()
                    TextField(L("Port"), value: $c.port, format: .number.grouping(.never)).ztermField().frame(width: 90)
                }
                HStack(spacing: 8) {
                    TextField(c.engine == .redis ? L("Username (opsional)") : L("Username"), text: $c.username).ztermField()
                    SecureField(L("Password"), text: Binding(get: { c.password ?? "" }, set: { c.password = $0.isEmpty ? nil : $0 })).ztermField()
                }
                TextField(c.engine == .redis ? L("Nomor database (0–15)") : L("Database (opsional)"), text: $c.database).ztermField()
                Toggle(c.engine == .postgres ? L("Wajibkan SSL/TLS") : L("Pakai SSL/TLS"), isOn: $c.tls).toggleStyle(.switch).tint(Theme.accent)

                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Tunnel SSH")).font(.system(size: 12, weight: .semibold))
                    Picker("", selection: $c.sshHostId) {
                        Text(L("Tanpa tunnel — koneksi langsung")).tag(String?.none)
                        ForEach(model.hosts) { h in Text(L("Lewat {}", h.title)).tag(Optional(h.id)) }
                    }
                    .labelsHidden()
                    if c.sshHostId != nil {
                        Text(L("Host & port di atas dilihat dari sisi server SSH, biasanya 127.0.0.1."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: 10))
            }

            if let testResult {
                Label(testResult, systemImage: testOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(testOK ? Color(hex: "#4ADE80") : .orange)
                    .lineLimit(3)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack {
                Button {
                    Task { await test() }
                } label: {
                    HStack(spacing: 6) {
                        if testing { ProgressView().controlSize(.small) } else { Image(systemName: "bolt.horizontal") }
                        Text(L("Tes koneksi"))
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(testing)
                Spacer()
                Button(L("Batal")) { dismiss() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button(L("Simpan")) { save(open: false) }.buttonStyle(SecondaryButtonStyle())
                Button { save(open: true) } label: { Label(L("Simpan & Buka"), systemImage: "bolt.fill") }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .animation(.zterm, value: testResult)
        .animation(.zterm, value: c.sshHostId)
    }

    private func save(open: Bool) {
        var x = c
        if x.label.isEmpty { x.label = x.title }
        model.save(x)
        dismiss()
        if open, let saved = model.databases.first(where: { $0.label == x.label && $0.engine == x.engine }) {
            Task { await model.openDatabase(saved) }
        }
    }

    private func test() async {
        testing = true
        defer { testing = false }
        do {
            let s = try await DbSession.connect(conn: c, ssh: model.sshTarget(forId: c.sshHostId))
            let n = (try? await s.tables().count) ?? 0
            testOK = true
            testResult = L("Berhasil tersambung — {} tabel/koleksi/key ditemukan", n)
        } catch {
            testOK = false
            testResult = error.ztermMessage
        }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            c.filePath = url.path
            if c.label.isEmpty { c.label = url.deletingPathExtension().lastPathComponent }
        }
    }
}

// MARK: - Workspace (ala phpMyAdmin)

struct DbWorkspaceView: View {
    @Environment(AppModel.self) private var model
    @Bindable var ws: DbWorkspace
    /// Daftar database & tabel di kiri bisa disembunyikan (diingat antar sesi).
    @AppStorage("db.showTree") private var showTree = true

    private var preset: DbPreset { DbPreset.find(ws.conn) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch ws.status {
            case .connecting:
                VStack(spacing: 14) {
                    EngineBadge(preset: preset, size: 56).symbolEffect(.pulse)
                    ProgressView().controlSize(.small)
                    Text(L("Menyambung ke {}…", ws.conn.title)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let msg):
                VStack(spacing: 12) {
                    Image(systemName: "bolt.horizontal.circle").font(.system(size: 40)).foregroundStyle(.orange)
                    Text(L("Gagal tersambung")).font(.title3.bold())
                    Text(msg).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 480).textSelection(.enabled)
                    HStack {
                        Button(L("Coba lagi")) { Task { await ws.connect(ssh: model.sshTarget(forId: ws.conn.sshHostId)) } }
                            .buttonStyle(PrimaryButtonStyle())
                        Button(L("Kembali")) { model.dbWorkspace = nil }.buttonStyle(SecondaryButtonStyle())
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready:
                HSplitView {
                    if showTree {
                        DbTree(ws: ws).frame(minWidth: 220, idealWidth: 270, maxWidth: 420)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    VStack(spacing: 0) {
                        breadcrumb
                        tabBar
                        Divider()
                        content
                    }
                    .frame(minWidth: 460)
                    .background(Theme.bg)
                }
            }
        }
        .animation(.zterm, value: ws.status)
        .animation(.zterm, value: showTree)
    }

    // MARK: Header & navigasi

    private var header: some View {
        HStack(spacing: 12) {
            IconButton(symbol: "chevron.left", help: L("Kembali ke daftar koneksi")) { model.dbWorkspace = nil }
            if ws.status == .ready {
                IconButton(symbol: showTree ? "sidebar.left" : "sidebar.squares.left",
                           help: showTree ? L("Sembunyikan daftar tabel (⌥⌘S)") : L("Tampilkan daftar tabel (⌥⌘S)")) { showTree.toggle() }
                    .keyboardShortcut("s", modifiers: [.command, .option])
            }
            EngineBadge(preset: preset, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(ws.conn.title).font(.system(size: 15, weight: .semibold))
                HStack(spacing: 6) {
                    Text(preset.name).font(.caption).foregroundStyle(.secondary)
                    if ws.conn.sshHostId != nil { Badge(text: L("SSH TUNNEL"), color: Theme.accent) }
                    if ws.status == .ready { PulseDot(color: Color(hex: "#4ADE80")) }
                }
            }
            Spacer()
            if ws.status == .ready {
                IconButton(symbol: "arrow.clockwise", help: L("Muat ulang")) { Task { await ws.refresh() } }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private var breadcrumb: some View {
        HStack(spacing: 6) {
            Button { withAnimation(.zterm) { ws.selectedDb = nil; ws.selectedTable = nil; ws.tab = .overview } } label: {
                Label(L("Server"), systemImage: "server.rack")
            }
            .buttonStyle(.plain)
            if let db = ws.selectedDb {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                Button { Task { await ws.selectDatabase(db) } } label: { Label(db, systemImage: "cylinder") }
                    .buttonStyle(.plain)
            }
            if let t = ws.selectedTable {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                Label(t.name, systemImage: t.isView ? "eye" : "tablecells").foregroundStyle(.primary)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
            Spacer()
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 6)
        .animation(.zterm, value: ws.selectedTable?.name)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(ws.availableTabs) { t in
                Button {
                    withAnimation(.ztermSnappy) { ws.tab = t }
                    Task { await ws.loadTab() }
                } label: {
                    Label(t.title, systemImage: t.icon)
                        .font(.system(size: 12.5, weight: ws.tab == t ? .semibold : .regular))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .foregroundStyle(ws.tab == t ? .primary : .secondary)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Theme.accent.opacity(ws.tab == t ? 0.14 : 0)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if let r = ws.shownResult, !r.columns.isEmpty {
                Button { ws.exportCSV() } label: { Label(L("Ekspor CSV"), systemImage: "square.and.arrow.down") }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 8)
        .animation(.ztermSnappy, value: ws.tab)
    }

    @ViewBuilder private var content: some View {
        ZStack {
            switch ws.tab {
            case .overview:
                if let db = ws.selectedDb { DbOverview(ws: ws, db: db) } else { ServerOverview(ws: ws) }
            case .browse: browse
            case .structure: structureView
            case .search: DbSearchForm(ws: ws)
            case .sql: sqlView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
        .animation(.zterm, value: ws.tab)
    }

    // MARK: Telusuri

    private var browse: some View {
        VStack(spacing: 0) {
            if ws.conn.engine.isSQL { browseBar }
            errorBar
            if let r = ws.page, !r.columns.isEmpty {
                ResultGrid(result: r, rowOffset: Int(ws.offset)).id("page\(ws.offset)\(r.rows.count)\(r.elapsedMs)")
                    .transition(.opacity)
            } else if ws.running {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let r = ws.page {
                Text(r.rows.isEmpty ? (ws.isFiltered ? L("Tidak ada baris yang cocok") : L("Tabel kosong")) : "").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
            }
            if ws.conn.engine.isSQL { pager }
        }
    }

    /// Cari cepat di semua kolom + keterangan filter aktif.
    private var browseBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L("Cari di tabel ini (semua kolom)"), text: $ws.quickSearch)
                    .textFieldStyle(.plain)
                    .onSubmit { Task { await ws.submitQuickSearch() } }
                if !ws.quickSearch.isEmpty {
                    Button { Task { await ws.clearFilters() } } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help(L("Hapus pencarian"))
                }
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.ink.opacity(0.1)))
            .frame(maxWidth: 320)
            if ws.isFiltered {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill").foregroundStyle(Theme.accent)
                    Text(ws.filterSummary).lineLimit(1).truncationMode(.tail)
                    Button(L("Hapus filter")) { Task { await ws.clearFilters() } }
                        .buttonStyle(.plain).foregroundStyle(Theme.accent)
                }
                .font(.system(size: 12))
                .transition(.opacity.combined(with: .move(edge: .leading)))
            }
            Spacer()
            Button {
                withAnimation(.ztermSnappy) { ws.tab = .search }
                Task { await ws.loadTab() }
            } label: { Label(L("Cari per kolom"), systemImage: "slider.horizontal.3") }
            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .animation(.zterm, value: ws.isFiltered)
    }

    private var pager: some View {
        let shown = UInt64(ws.page?.rows.count ?? 0)
        let total = ws.totalRows
        let hasNext = total.map { ws.offset + shown < $0 } ?? (shown == UInt64(ws.pageSize))
        return HStack(spacing: 10) {
            if ws.running { ProgressView().controlSize(.small) }
            Group {
                if shown == 0 {
                    Text(L("0 baris"))
                } else {
                    Text(L("Baris {}–{}", (ws.offset + 1).formatted(), (ws.offset + shown).formatted()))
                        + Text(total.map { L(" dari {}{}", ws.totalIsEstimate ? "~" : "", $0.formatted()) } ?? "")
                }
            }
            .font(.system(size: 12, weight: .medium))
            if let ms = ws.page?.elapsedMs { Text(L("· {} ms", ms)).font(.system(size: 12)).foregroundStyle(.secondary) }
            Spacer()
            Picker("", selection: Binding(get: { ws.pageSize }, set: { n in Task { await ws.setPageSize(n) } })) {
                ForEach([25, 50, 100, 250, 500] as [UInt32], id: \.self) { Text(L("{} / halaman", $0)).tag($0) }
            }
            .labelsHidden().fixedSize()
            HStack(spacing: 2) {
                IconButton(symbol: "chevron.left.2", help: L("Halaman pertama")) { Task { await ws.goToPage(offset: 0) } }
                    .disabled(ws.offset == 0)
                IconButton(symbol: "chevron.left", help: L("Sebelumnya")) {
                    Task { await ws.goToPage(offset: ws.offset >= UInt64(ws.pageSize) ? ws.offset - UInt64(ws.pageSize) : 0) }
                }
                .disabled(ws.offset == 0)
                if let total, total > 0 {
                    Text("\(ws.offset / UInt64(ws.pageSize) + 1) / \((total + UInt64(ws.pageSize) - 1) / UInt64(ws.pageSize))")
                        .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                        .frame(minWidth: 54)
                        .contentTransition(.numericText())
                }
                IconButton(symbol: "chevron.right", help: L("Berikutnya")) { Task { await ws.goToPage(offset: ws.offset + UInt64(ws.pageSize)) } }
                    .disabled(!hasNext)
                IconButton(symbol: "chevron.right.2", help: L("Halaman terakhir")) {
                    if let total, total > 0 { Task { await ws.goToPage(offset: (total - 1) / UInt64(ws.pageSize) * UInt64(ws.pageSize)) } }
                }
                .disabled(!hasNext || total == nil)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Theme.panel)
        .overlay(alignment: .top) { Divider() }
        .animation(.ztermSnappy, value: ws.offset)
    }

    // MARK: Struktur

    private var structureView: some View {
        VStack(spacing: 0) {
            errorBar
            if let r = ws.structure, !r.columns.isEmpty {
                ResultGrid(result: r, highlightColumn: "Kunci").transition(.opacity)
            } else if ws.running {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
            }
        }
    }

    // MARK: SQL

    private var sqlView: some View {
        VSplitView {
            editor.frame(minHeight: 120, idealHeight: 180)
            results.frame(minHeight: 160)
        }
    }

    @ViewBuilder private var errorBar: some View {
        if let e = ws.error {
            Label(e, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12)).foregroundStyle(.orange).lineLimit(3).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.orange.opacity(0.08))
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $ws.query)
                    .font(.system(size: 13, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                if ws.query.isEmpty {
                    Text(ws.conn.engine.placeholderQuery)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(13)
                        .allowsHitTesting(false)
                }
            }
            HStack(spacing: 8) {
                if !ws.history.isEmpty {
                    Menu {
                        ForEach(ws.history, id: \.self) { q in
                            Button(String(q.prefix(80))) { ws.query = q }
                        }
                    } label: { Label(L("Riwayat"), systemImage: "clock.arrow.circlepath") }
                    .menuStyle(.borderlessButton).fixedSize()
                }
                if let db = ws.activeDatabase {
                    Label(db, systemImage: "cylinder").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(ws.conn.engine.isSQL ? L("⌘⏎ untuk menjalankan") : L("Satu perintah per baris"))
                    .font(.caption).foregroundStyle(.tertiary)
                Button {
                    Task { await ws.run() }
                } label: {
                    HStack(spacing: 6) {
                        if ws.running { ProgressView().controlSize(.small).tint(.black) } else { Image(systemName: "play.fill") }
                        Text(L("Jalankan"))
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(ws.running)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
        .background(Theme.bg)
    }

    private var results: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let e = ws.error {
                    Label(e, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12)).foregroundStyle(.orange).lineLimit(2).textSelection(.enabled)
                } else if let r = ws.result {
                    Text(r.columns.isEmpty
                         ? (r.affected.map { L("✓ {} baris terpengaruh", $0) } ?? L("✓ Selesai"))
                         : (L10n.shared.english ? "\(r.rows.count) rows" : "\(r.rows.count) baris") + (r.truncated ? " " + L("(dipotong)") : ""))
                        .font(.system(size: 12, weight: .semibold))
                    Text(L("· {} ms", r.elapsedMs)).font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    Text(L("Tulis query lalu tekan Jalankan")).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Theme.panel)
            Divider()
            if let r = ws.result, !r.columns.isEmpty {
                ResultGrid(result: r).id(r.columns.joined() + "\(r.rows.count)\(r.elapsedMs)")
                    .transition(.opacity)
            } else {
                Color.clear
            }
        }
        .animation(.zterm, value: ws.result?.elapsedMs)
        .animation(.zterm, value: ws.error)
    }
}

// MARK: - Cari (kueri dengan contoh)

/// Tab "Cari" ala phpMyAdmin: satu baris per kolom — operator & nilai — lalu Kirim.
private struct DbSearchForm: View {
    @Bindable var ws: DbWorkspace

    var body: some View {
        VStack(spacing: 0) {
            if ws.searchForm.isEmpty {
                if ws.running { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) } else { Color.clear }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Label(L("Kueri dengan contoh — isi kolom yang ingin dicari, kosongkan sisanya. Wildcard: %"),
                              systemImage: "magnifyingglass")
                            .font(.system(size: 12.5)).foregroundStyle(.secondary)
                        VStack(spacing: 0) {
                            row(header: true, Text(L("Kolom")), Text(L("Jenis")), Text(L("Operator")), Text(L("Nilai")))
                            ForEach($ws.searchForm) { $f in
                                Divider().opacity(0.5)
                                row(header: false,
                                    Text(f.column).font(.system(size: 12.5, weight: .semibold)).lineLimit(1),
                                    Text(f.type).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1),
                                    Picker("", selection: $f.op) { ForEach(f.ops, id: \.self) { Text($0).tag($0) } }
                                        .labelsHidden().controlSize(.small),
                                    TextField(placeholder(f), text: $f.value)
                                        .frame(maxWidth: .infinity)
                                        .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                                        .disabled(!f.needsValue).opacity(f.needsValue ? 1 : 0.4)
                                        .onSubmit { Task { await ws.submitSearch() } })
                            }
                        }
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.ink.opacity(0.08)))
                    }
                    .padding(16)
                }
                HStack(spacing: 10) {
                    let n = ws.searchForm.filter(\.isActive).count
                    Text(n == 0 ? L("Belum ada syarat — Kirim menampilkan semua baris") : L("{} syarat", n))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Reset")) { for i in ws.searchForm.indices { ws.searchForm[i].value = "" } }
                        .buttonStyle(SecondaryButtonStyle())
                    Button { Task { await ws.submitSearch() } } label: { Label(L("Kirim"), systemImage: "magnifyingglass") }
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.return, modifiers: .command)
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Theme.panel)
                .overlay(alignment: .top) { Divider() }
            }
        }
    }

    private func placeholder(_ f: DbWorkspace.SearchField) -> String {
        switch f.op {
        case "IN (...)", "NOT IN (...)": L("nilai1, nilai2, …")
        case "BETWEEN", "NOT BETWEEN": L("awal, akhir")
        case "LIKE", "NOT LIKE": L("mis. abc%")
        default: f.needsValue ? "" : "—"
        }
    }

    private func row(header: Bool, _ a: some View, _ b: some View, _ c: some View, _ d: some View) -> some View {
        HStack(spacing: 12) {
            a.frame(minWidth: 80, maxWidth: 170, alignment: .leading)
            b.frame(minWidth: 60, maxWidth: 120, alignment: .leading)
            c.frame(width: 140, alignment: .leading)
            d.frame(minWidth: 100, maxWidth: .infinity, alignment: .leading)
        }
        .font(header ? .system(size: 11, weight: .semibold) : .system(size: 12.5))
        .foregroundStyle(header ? .secondary : .primary)
        .textCase(header ? .uppercase : nil)
        .padding(.horizontal, 14).padding(.vertical, header ? 9 : 6)
    }
}

// MARK: - Pohon database

private struct DbTree: View {
    @Bindable var ws: DbWorkspace
    @State private var filter = ""

    private func matches(_ t: DbTable) -> Bool { filter.isEmpty || t.name.localizedCaseInsensitiveContains(filter) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                TextField(ws.conn.engine == .redis ? L("Cari key…") : L("Cari tabel…"), text: $filter).textFieldStyle(.plain).font(.system(size: 12))
                if !filter.isEmpty {
                    Button { filter = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9).frame(height: 28)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 7))
            .padding(10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    sectionLabel(ws.conn.engine == .redis ? L("DATABASE REDIS") : "DATABASE", count: ws.userDatabases.count)
                    ForEach(ws.userDatabases, id: \.self) { db in node(db) }

                    if !ws.systemDatabases.isEmpty {
                        Button {
                            withAnimation(.ztermSnappy) { ws.showSystem.toggle() }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                                    .rotationEffect(.degrees(ws.showSystem ? 90 : 0))
                                Text(L("SISTEM")).tracking(1.2)
                                Text("\(ws.systemDatabases.count)").padding(.horizontal, 5).background(Theme.ink.opacity(0.08), in: Capsule())
                                Spacer()
                            }
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                            .padding(.horizontal, 8).padding(.top, 14).padding(.bottom, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if ws.showSystem {
                            ForEach(ws.systemDatabases, id: \.self) { db in node(db, system: true) }
                        }
                    }
                }
                .padding(.horizontal, 6).padding(.bottom, 10)
            }
        }
        .background(Theme.panel)
    }

    private func sectionLabel(_ text: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(text).tracking(1.2)
            Text("\(count)").padding(.horizontal, 5).background(Theme.ink.opacity(0.08), in: Capsule())
            Spacer()
        }
        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
        .padding(.horizontal, 8).padding(.bottom, 4)
    }

    @ViewBuilder private func node(_ db: String, system: Bool = false) -> some View {
        let open = ws.expanded.contains(db)
        let tables = (ws.dbTables[db] ?? []).filter(matches)
        DbNodeRow(name: db, open: open, loading: ws.loadingDbs.contains(db),
                  count: ws.dbTables[db]?.count, selected: ws.selectedDb == db && ws.selectedTable == nil,
                  active: ws.activeDatabase == db, system: system,
                  onToggle: { Task { await ws.toggle(db) } },
                  onSelect: { Task { await ws.selectDatabase(db) } })
        if open {
            ForEach(tables, id: \.name) { t in
                TableRow(table: t, engine: ws.conn.engine,
                         selected: ws.selectedDb == db && ws.selectedTable?.name == t.name && ws.selectedTable?.schema == t.schema) {
                    Task { await ws.openTable(t, in: db) }
                }
                .padding(.leading, 18)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if let all = ws.dbTables[db], all.isEmpty {
                Text(L("Tidak ada tabel")).font(.caption).foregroundStyle(.tertiary).padding(.leading, 40).padding(.vertical, 4)
            }
        }
    }
}

private struct DbNodeRow: View {
    let name: String
    let open: Bool
    let loading: Bool
    let count: Int?
    let selected: Bool
    let active: Bool
    let system: Bool
    var onToggle: () -> Void
    var onSelect: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onToggle) {
                Group {
                    if loading { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(open ? 90 : 0)) }
                }
                .frame(width: 14, height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Button(action: onSelect) {
                HStack(spacing: 7) {
                    Image(systemName: open ? "cylinder.split.1x2.fill" : "cylinder.split.1x2")
                        .font(.system(size: 11.5))
                        .foregroundStyle(system ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Theme.accent))
                    Text(name).font(.system(size: 12.5, weight: active ? .semibold : .regular)).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(system ? .secondary : .primary)
                    Spacer(minLength: 0)
                    if let count {
                        Text("\(count)").font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Theme.ink.opacity(0.07), in: Capsule())
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
        .background(selected ? Theme.accent.opacity(0.16) : hover ? Theme.ink.opacity(0.05) : .clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { hover = $0 }
        .animation(.ztermSnappy, value: open)
        .animation(.ztermSnappy, value: count)
    }
}

struct TableRow: View {
    let table: DbTable
    let engine: DbEngine
    let selected: Bool
    var onOpen: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 11)).foregroundStyle(table.isView ? Theme.accent3 : Theme.accent2).frame(width: 14)
                Text(table.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if engine == .postgres || engine == .sqlserver, !["public", "dbo"].contains(table.schema) {
                    Text(table.schema).font(.system(size: 9.5)).foregroundStyle(.tertiary)
                } else if hover, let rows = table.rowsText {
                    Text(rows).font(.system(size: 9.5, design: .rounded)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8).frame(height: 25)
            .background(selected ? Theme.accent.opacity(0.16) : hover ? Theme.ink.opacity(0.05) : .clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }

    private var icon: String {
        switch engine {
        case .redis: "key.fill"
        case .mongodb: "doc.on.doc.fill"
        default: table.isView ? "eye" : "tablecells"
        }
    }
}

// MARK: - Ringkasan

/// Daftar tabel satu database: baris, ukuran, tipe (seperti halaman database phpMyAdmin).
private struct DbOverview: View {
    @Bindable var ws: DbWorkspace
    let db: String
    @State private var filter = ""

    private var tables: [DbTable] {
        let all = ws.dbTables[db] ?? []
        return filter.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        let all = ws.dbTables[db] ?? []
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                stat("\(all.filter { !$0.isView }.count)", L("tabel"), "tablecells", Theme.accent2)
                stat("\(all.filter(\.isView).count)", "view", "eye", Theme.accent3)
                stat(all.compactMap(\.rows).reduce(0, +).formatted(), L("baris (perkiraan)"), "list.number", Theme.accent)
                stat(ByteCountFormatter.string(fromByteCount: Int64(all.compactMap(\.sizeBytes).reduce(0, +)), countStyle: .file),
                     L("ukuran"), "internaldrive", Color(hex: "#F59E0B"))
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                    TextField(L("Filter tabel"), text: $filter).textFieldStyle(.plain).font(.system(size: 12))
                }
                .padding(.horizontal, 9).frame(width: 200, height: 28)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: 7))
            }
            .padding(14)

            HStack(spacing: 0) {
                Text(L("Tabel")).frame(maxWidth: .infinity, alignment: .leading)
                Text(L("Tipe")).frame(width: 80, alignment: .leading)
                Text(L("Baris")).frame(width: 110, alignment: .trailing)
                Text(L("Ukuran")).frame(width: 100, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 18).padding(.vertical, 6)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }

            if ws.loadingDbs.contains(db) && all.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if all.isEmpty {
                Text(L("Database ini belum punya tabel")).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(tables.enumerated()), id: \.element.name) { i, t in
                            OverviewRow(table: t, striped: i % 2 == 1) { Task { await ws.openTable(t, in: db) } }
                                .staggerIn(min(i, 14), base: 0)
                        }
                    }
                }
            }
        }
    }

    private func stat(_ value: String, _ label: String, _ icon: String, _ tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(.system(size: 16, weight: .bold, design: .rounded)).contentTransition(.numericText())
                Text(label).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        }
    }
}

private struct OverviewRow: View {
    let table: DbTable
    let striped: Bool
    var onOpen: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: table.isView ? "eye" : "tablecells").foregroundStyle(table.isView ? Theme.accent3 : Theme.accent2)
                    Text(table.name).lineLimit(1)
                    if hover {
                        Text(L("Telusuri →")).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.accent)
                            .transition(.opacity.combined(with: .move(edge: .leading)))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(table.isView ? "VIEW" : "TABLE").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .leading)
                Text(table.rowsText ?? "—").font(.system(size: 12, design: .monospaced)).frame(width: 110, alignment: .trailing)
                Text(table.sizeText ?? "—").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    .frame(width: 100, alignment: .trailing)
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 18).frame(height: 30)
            .background(hover ? Theme.accent.opacity(0.09) : striped ? Theme.ink.opacity(0.025) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.ztermSnappy) { hover = h } }
    }
}

/// Belum memilih database: kartu-kartu database.
private struct ServerOverview: View {
    @Bindable var ws: DbWorkspace

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(L("Pilih database")).font(.title3.bold())
                Text(L("{} database pengguna · {} database sistem", ws.userDatabases.count, ws.systemDatabases.count))
                    .font(.callout).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                    ForEach(Array(ws.userDatabases.enumerated()), id: \.element) { i, db in
                        Button { Task { await ws.selectDatabase(db) } } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "cylinder.split.1x2.fill").font(.system(size: 18))
                                    .foregroundStyle(Theme.brandGradient)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(db).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                                    Text(ws.dbTables[db].map { L("{} tabel", $0.count) } ?? L("Klik untuk membuka"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(DbTileStyle())
                        .staggerIn(min(i, 16), base: 0)
                    }
                }
            }
            .padding(22)
        }
    }
}

private struct DbTileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Tile(configuration: configuration) }
    private struct Tile: View {
        let configuration: Configuration
        @State private var hover = false
        var body: some View {
            configuration.label
                .background(hover ? Theme.cardHover : Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(hover ? Theme.accent.opacity(0.5) : Theme.cardStroke))
                .scaleEffect(configuration.isPressed ? 0.97 : hover ? 1.015 : 1)
                .animation(.ztermSnappy, value: hover)
                .animation(.ztermSnappy, value: configuration.isPressed)
                .onHover { hover = $0 }
        }
    }
}

/// Tabel hasil: header tetap, gulir dua arah, NULL ditampilkan miring, klik ganda menyalin nilai.
struct ResultGrid: View {
    let result: QueryResult
    var rowOffset = 0
    /// Kolom yang nilainya disorot sebagai badge (mis. "Kunci" di tab Struktur).
    var highlightColumn: String? = nil
    @State private var copied: String?

    private var widths: [CGFloat] {
        result.columns.enumerated().map { i, name in
            if name == highlightColumn { return 112 }
            let sample = result.rows.prefix(60).map { ($0[safe: i] ?? nil)?.count ?? 4 }.max() ?? 4
            return min(360, max(70, CGFloat(max(name.count, sample)) * 7.4 + 22))
        }
    }

    var body: some View {
        let w = widths
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                SwiftUI.Section {
                    ForEach(result.rows.indices, id: \.self) { r in
                        HStack(spacing: 0) {
                            Text("\(rowOffset + r + 1)").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary)
                                .frame(width: 44, alignment: .trailing).padding(.trailing, 8)
                            ForEach(result.columns.indices, id: \.self) { c in
                                if result.columns[c] == highlightColumn {
                                    keyCell(result.rows[r][safe: c] ?? nil).frame(width: w[c], alignment: .leading)
                                } else {
                                    cell(result.rows[r][safe: c] ?? nil).frame(width: w[c], alignment: .leading)
                                }
                            }
                        }
                        .frame(height: 26)
                        .background(r % 2 == 1 ? Theme.ink.opacity(0.025) : .clear)
                    }
                } header: {
                    HStack(spacing: 0) {
                        Text("#").frame(width: 44, alignment: .trailing).padding(.trailing, 8).foregroundStyle(.tertiary)
                        ForEach(result.columns.indices, id: \.self) { c in
                            Text(result.columns[c]).lineLimit(1).frame(width: w[c], alignment: .leading).padding(.leading, 8)
                        }
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                    .frame(height: 28)
                    .background(.bar)
                    .overlay(alignment: .bottom) { Divider() }
                }
            }
        }
        .background(Theme.bg)
        .overlay(alignment: .bottom) {
            if let copied {
                Text(L("Disalin: {}", copied.prefix(40)))
                    .font(.caption).padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.ultraThickMaterial, in: Capsule()).padding(10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.zterm, value: copied)
    }

    @ViewBuilder private func keyCell(_ v: String?) -> some View {
        let key = v ?? ""
        let color: Color = key == "PRI" ? Color(hex: "#F59E0B") : key == "UNI" ? Theme.accent3 : Theme.accent2
        HStack {
            if !key.isEmpty {
                Label(key == "PRI" ? "PRIMARY" : key == "UNI" ? "UNIQUE" : key == "MUL" ? "INDEX" : key, systemImage: "key.fill")
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(color)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(color.opacity(0.14), in: Capsule())
            }
        }
        .padding(.leading, 8)
    }

    private func cell(_ v: String?) -> some View {
        Group {
            if let v {
                Text(v.replacingOccurrences(of: "\n", with: " ⏎ ")).lineLimit(1).truncationMode(.tail)
            } else {
                Text("NULL").italic().foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.leading, 8)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(v ?? "", forType: .string)
            copied = v ?? "NULL"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { if copied == (v ?? "NULL") { copied = nil } }
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
