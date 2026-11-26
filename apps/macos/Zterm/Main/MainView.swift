import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 290)
        } detail: {
            VStack(spacing: 0) {
                TabStrip(columns: $columns)
                HStack(spacing: 0) {
                ZStack {
                    if model.activeSessionID == nil {
                        SectionContent(section: model.section)
                            .id(model.section)
                            .transition(.opacity)
                    }
                    // Semua sesi tetap hidup walau tidak sedang ditampilkan; di split beberapa tampil berdampingan.
                    TerminalPanes()
                }
                .animation(.zterm, value: model.activeSessionID)
                    if let stats = model.serverStats, model.activeSessionID != nil {
                        Divider()
                        ServerInfoPanel(stats: stats)
                            .frame(width: 330)
                            .id(stats.host.id)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .animation(.zterm, value: model.serverStats?.host.id)
            }
            .background(Theme.bg)
            .toolbarBackground(.hidden, for: .windowToolbar)
            .inspector(isPresented: Binding(
                get: { model.editingHost != nil },
                set: { if !$0 { model.editingHost = nil } }
            )) {
                if let host = model.editingHost {
                    HostEditor(original: host)
                        .id(host.id.isEmpty ? "new-\(host.hostname)" : host.id)
                        .inspectorColumnWidth(min: 340, ideal: 380, max: 460)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ztermNewHost)) { _ in
            model.activeSessionID = nil
            model.section = .hosts
            model.editingHost = .blank()
        }
    }
}

struct SectionContent: View {
    let section: Section
    var body: some View {
        switch section {
        case .hosts: HostsView()
        case .dashboard: DashboardView()
        case .serverAdmin: AdminView()
        case .team: TeamView()
        case .keychain: KeychainView()
        case .forwarding: ForwardingView()
        case .sftp: SftpView()
        case .database: DatabaseView()
        case .localServer: LocalServerView()
        case .docker: DockerView()
        case .snippets: SnippetsView()
        case .knownHosts: KnownHostsView()
        case .logs: LogsView()
        case .about: AboutView()
        case .account: AccountView()
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Namespace private var ns

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                ZtermLogo(size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Zterm").font(.system(size: 15, weight: .bold, design: .rounded)).lineLimit(1)
                    HStack(spacing: 5) {
                        Text(L("SSH Client")).font(.system(size: 10.5)).foregroundStyle(.secondary)
                        Text(AppVersion.current)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Theme.accent.opacity(0.14), in: Capsule())
                            .foregroundStyle(Theme.accent)
                    }
                }
                .fixedSize()
                Spacer(minLength: 0)
                AppearanceMenu().foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 18)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 3) {
                    SidebarHeader(text: L("Workspace"))
                    ForEach(Section.main) { s in row(s) }
                    SidebarHeader(text: L("Komunitas")).padding(.top, 14)
                    ForEach(Section.community) { s in row(s) }
                }
                .padding(.horizontal, 10)
            }

            if let u = model.update, !model.updateDismissed {
                UpdateCard(update: u)
                    .padding(.horizontal, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            AccountFooter()
        }
        .animation(.ztermSnappy, value: model.section)
        .animation(.ztermSnappy, value: model.activeSessionID == nil)
    }

    private func row(_ s: Section) -> some View {
        SidebarRow(section: s, selected: model.activeSessionID == nil && model.section == s,
                   badge: badge(for: s), ns: ns) {
            model.section = s
            model.showHome()
        }
    }

    private func badge(for s: Section) -> Int {
        switch s {
        case .hosts: model.hosts.count
        case .dashboard: model.dashboard.attention
        case .team: model.teams.count
        case .keychain: model.keys.count
        case .snippets: model.snippets.count
        case .forwarding: model.forwards.count
        case .database: model.databases.count
        case .localServer: model.stack.services.filter(\.running).count
        default: 0
        }
    }
}

struct SidebarHeader: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
    }
}

/// Baris menu sidebar: ikon dalam kotak berwarna, sorotan aktif yang meluncur, hover lembut.
struct SidebarRow: View {
    let section: Section
    let selected: Bool
    let badge: Int
    let ns: Namespace.ID
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selected ? Theme.accent.opacity(0.12) : Theme.ink.opacity(0.05))
                    PhosphorIcon(name: section.ph, size: 15, tint: selected ? Theme.accent : .secondary)
                }
                .frame(width: 26, height: 26)

                Text(section.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? .primary : .secondary)
                Spacer(minLength: 0)
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Theme.ink.opacity(selected ? 0.14 : 0.07), in: Capsule())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 36)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.ink.opacity(0.09))
                        .overlay(alignment: .leading) {
                            Capsule().fill(section.tint).frame(width: 3, height: 16).offset(x: -2)
                        }
                        .matchedGeometryEffect(id: "sidebarSel", in: ns)
                } else if hover {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.ink.opacity(0.045))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.ztermHover) { hover = h } }
    }
}

extension Section {
    /// Nama ikon Phosphor Duotone untuk sidebar.
    var ph: String {
        switch self {
        case .hosts: "hard-drives"
        case .dashboard: "gauge"
        case .serverAdmin: "wrench"
        case .team: "users-three"
        case .keychain: "key"
        case .forwarding: "arrows-left-right"
        case .sftp: "folder-open"
        case .database: "database"
        case .localServer: "stack"
        case .docker: "cube"
        case .snippets: "brackets-curly"
        case .knownHosts: "fingerprint"
        case .logs: "clock"
        case .about: "info"
        case .account: "user-circle"
        }
    }

    /// Warna ikon tiap menu.
    var tint: Color {
        switch self {
        case .hosts: Color(hex: "#3B82F6")
        case .dashboard: Color(hex: "#F43F5E")
        case .serverAdmin: Color(hex: "#0EA5E9")
        case .team: Color(hex: "#22C55E")
        case .keychain: Color(hex: "#F59E0B")
        case .forwarding: Color(hex: "#10B981")
        case .sftp: Color(hex: "#06B6D4")
        case .database: Color(hex: "#F97316")
        case .localServer: Color(hex: "#EAB308")
        case .docker: Color(hex: "#2496ED")
        case .snippets: Color(hex: "#8B5CF6")
        case .knownHosts: Color(hex: "#EC4899")
        case .logs: Color(hex: "#64748B")
        case .about: Color(hex: "#6366F1")
        case .account: Color(hex: "#14B8A6")
        }
    }
}

struct AccountFooter: View {
    @Environment(AppModel.self) private var model
    @State private var hover = false
    @State private var connecting = false

    private var statusText: String {
        switch model.sync {
        case .off: L("Lokal saja")
        case .idle: L("Siap sync")
        case .syncing: L("Menyinkronkan…")
        case .synced(let d): Date().timeIntervalSince(d) < 60 ? L("Tersinkron") : L("Sinkron {}", d.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
        case .failed: L("Sync gagal — klik untuk ulang")
        case .needsLogin: L("Masuk ulang Google")
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Avatar(name: model.profileName, email: model.accountEmail, picture: model.profilePicture, size: 30)
                .overlay(alignment: .bottomTrailing) {
                    if model.accountEmail != nil {
                        SyncIcon(state: model.sync)
                            .font(.system(size: 7))
                            .frame(width: 14, height: 14)
                            .background(Theme.accent, in: Circle())
                            .overlay(Circle().strokeBorder(Theme.panel, lineWidth: 1.5))
                            .offset(x: 3, y: 3)
                    }
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(model.profileName ?? model.accountEmail ?? L("Tanpa akun"))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(statusText)
                        .font(.system(size: 11))
                        .minimumScaleFactor(0.85)
                        .foregroundStyle(isFailed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
            }
            Spacer(minLength: 0)
            Menu {
                if model.accountEmail == nil {
                    Button(L("Hubungkan Google Drive…")) { Task { await connect() } }
                } else if model.sync == .needsLogin {
                    Button(L("Masuk ulang Google…")) { Task { await connect() } }
                } else {
                    Button(L("Sinkronkan sekarang")) { model.syncNow() }
                    Divider()
                    Button(L("Putuskan akun Google"), role: .destructive) { model.disconnectGoogle() }
                }
                Divider()
                Button(L("Lihat profil")) { model.section = .account; model.showHome() }
                Button(L("Kunci vault")) { model.lock() }
            } label: {
                PhosphorIcon(name: "dots-three-circle", size: 16)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(12)
        .background(Theme.ink.opacity(hover ? 0.06 : 0.03), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.ztermSnappy) {
                model.section = .account
                model.showHome()
            }
        }
        .help(failureMessage ?? L("Lihat profil akun"))
        .padding(10)
        .onHover { h in withAnimation(.ztermHover) { hover = h } }
    }

    private var isFailed: Bool {
        switch model.sync { case .failed, .needsLogin: true; default: false }
    }
    private var failureMessage: String? { if case .failed(let m) = model.sync { m } else { nil } }

    private func connect() async {
        guard !connecting else { return }
        connecting = true
        defer { connecting = false }
        do { _ = try await model.signInGoogle() }
        catch GoogleAuth.AuthError.cancelled {}
        catch { model.flash(Lmsg(error.localizedDescription)) }
    }
}

/// Ikon status sync: berputar saat menyinkronkan, centang saat selesai.
struct SyncIcon: View {
    let state: SyncState
    var size: CGFloat = 12
    var tint: Color = .black.opacity(0.75)
    @State private var spin = false

    var body: some View {
        Group {
            switch state {
            case .off: PhosphorIcon(name: "user", size: size, tint: tint)
            case .idle, .synced: PhosphorIcon(name: "cloud-check", size: size, tint: tint)
            case .syncing:
                PhosphorIcon(name: "arrows-clockwise", size: size, tint: tint)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .onAppear { withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { spin = true } }
                    .onDisappear { spin = false }
            case .failed, .needsLogin: PhosphorIcon(name: "cloud-warning", size: size, tint: tint)
            }
        }
    }
}

/// Tombol kecil untuk ganti Sistem / Terang / Gelap.
struct AppearanceMenu: View {
    @AppStorage(AppearanceMode.storageKey) private var appearance: AppearanceMode = .dark

    var body: some View {
        Menu {
            Picker(L("Tampilan"), selection: $appearance) {
                ForEach(AppearanceMode.allCases) { m in PhosphorLabel(sf: m.icon, text: m.title, size: 12).tag(m) }
            }
            .pickerStyle(.inline)
            Picker(LanguageSwitch.title, selection: LanguageSwitch.binding) {
                ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            PhosphorIcon(sf: appearance.icon, size: 15)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("Tampilan: {}", appearance.title))
    }
}

// MARK: - Tab bar

struct TabStrip: View {
    @Environment(AppModel.self) private var model
    @Binding var columns: NavigationSplitViewVisibility
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 6) {

            TabChip(isActive: model.activeSessionID == nil, ns: ns, onSelect: { model.showHome() }) {
                PhosphorIcon(name: "squares-four", size: 13)
                    .frame(width: 18)
            }
            .help(L("Daftar host (⌘0)"))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(model.sessions.enumerated()), id: \.element.id) { i, s in
                        SessionTab(session: s, index: i, ns: ns)
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.6, anchor: .leading).combined(with: .opacity),
                                removal: .scale(scale: 0.8).combined(with: .opacity)))
                    }
                }
                .padding(.vertical, 1)
            }
            Button { model.openLocalTerminal() } label: {
                PhosphorIcon(name: "plus", size: 12, tint: .secondary)
                    .frame(width: 26, height: 26)
                    .background(Theme.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("Terminal lokal (⇧⌘T)"))
            Spacer(minLength: 0)
            if let s = model.activeSession, !s.isLocal {
                Button {
                    withAnimation(.zterm) { model.showServerInfo.toggle() }
                } label: {
                    PhosphorLabel(text: L("Info server"), icon: "cpu", size: 13,
                                  tint: model.showServerInfo ? Theme.accent : .secondary)
                        .font(.system(size: 12, weight: model.showServerInfo ? .semibold : .regular))
                        .padding(.horizontal, 9).frame(height: 26)
                        .background(model.showServerInfo ? Theme.accent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .foregroundStyle(model.showServerInfo ? Theme.accent : .secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("Spesifikasi & grafik server (⇧⌘I)"))
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
            if model.activeSessionID != nil {
                SplitMenu()
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
            if model.splitVisible {
                Button { model.toggleBroadcast() } label: {
                    PhosphorLabel(text: L("Broadcast"), icon: "broadcast", size: 13,
                                  tint: model.broadcast ? Color.orange : .secondary)
                        .font(.system(size: 12, weight: model.broadcast ? .semibold : .regular))
                        .padding(.horizontal, 9).frame(height: 26)
                        .background(model.broadcast ? Color.orange.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .foregroundStyle(model.broadcast ? Color.orange : .secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("Ketik sekali, kirim ke semua panel split (⇧⌘B)"))
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
            if model.activeSessionID != nil {
                AutocompleteMenu()
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
            if model.activeSessionID != nil && !model.snippets.isEmpty {
                Menu {
                    ForEach(model.snippets) { sn in
                        Button(sn.label) { model.runInActiveSession(sn) }
                    }
                } label: {
                    PhosphorLabel(text: L("Snippet"), icon: "brackets-curly", size: 13)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(L("Jalankan snippet di tab ini"))
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
        .background {
            Rectangle().fill(.bar)
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
        }
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct TabChip<Label: View>: View {
    let isActive: Bool
    let ns: Namespace.ID
    var onSelect: () -> Void
    @ViewBuilder var label: () -> Label
    @State private var hover = false

    var body: some View {
        // Button sungguhan (bukan onTapGesture) supaya klik tidak tertelan gesture geser jendela
        Button { withAnimation(.ztermSnappy) { onSelect() } } label: { chip }
            .buttonStyle(.plain)
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }

    private var chip: some View {
        label()
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background {
                if isActive {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.ink.opacity(0.1))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.ink.opacity(0.08)))
                        .matchedGeometryEffect(id: "activeTab", in: ns)
                } else if hover {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.ink.opacity(0.05))
                }
            }
            .foregroundStyle(isActive ? .primary : .secondary)
            .contentShape(Rectangle())
    }
}

struct SessionTab: View {
    @Environment(AppModel.self) private var model
    @AppStorage(PrivacyKeys.hideAddresses) private var hideAddresses = true
    let session: TerminalSession
    let index: Int
    let ns: Namespace.ID
    @State private var hover = false

    var body: some View {
        TabChip(isActive: model.activeSessionID == session.id, ns: ns,
                onSelect: { model.activeSessionID = session.id }) {
            HStack(spacing: 7) {
                if session.isLocal {
                    PhosphorIcon(name: "terminal-window", size: 12, tint: .secondary)
                } else {
                    StatusDot(status: session.status, color: Color(hex: session.host.color))
                }
                Text(session.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .frame(maxWidth: 150, alignment: .leading)
                Button {
                    model.close(session)
                } label: {
                    PhosphorIcon(name: "x", size: 9, tint: .secondary)
                        .frame(width: 16, height: 16)
                        .background(Theme.ink.opacity(hover ? 0.1 : 0), in: Circle())
                }
                .buttonStyle(.plain)
                .opacity(hover || model.activeSessionID == session.id ? 1 : 0)
            }
        }
        .onHover { hover = $0 }
        .help(index < 9 ? "\(session.host.displayAddress(hidden: hideAddresses))  ·  ⌘\(index + 1)"
                        : session.host.displayAddress(hidden: hideAddresses))
    }
}

/// Titik status: berdenyut saat menghubungkan, solid saat tersambung, abu-abu saat terputus.
struct StatusDot: View {
    let status: TerminalSession.Status
    let color: Color
    @State private var pulse = false

    var body: some View {
        ZStack {
            if status == .connecting {
                Circle().stroke(color, lineWidth: 1.5)
                    .scaleEffect(pulse ? 2.2 : 1)
                    .opacity(pulse ? 0 : 0.8)
            }
            Circle().fill(fill)
        }
        .frame(width: 7, height: 7)
        .onAppear {
            withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) { pulse = true }
        }
    }

    private var fill: Color {
        switch status {
        case .connecting: color.opacity(0.6)
        case .connected: Color(hex: "#4ADE80")
        case .disconnected: .gray
        }
    }
}

/// Kartu "versi baru tersedia" di bawah sidebar.
struct UpdateCard: View {
    @Environment(AppModel.self) private var model
    let update: AvailableUpdate

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                PhosphorIcon(name: "sparkle", size: 14, tint: Theme.accent)
                Text(L("Versi {} tersedia", update.version)).font(.system(size: 12, weight: .semibold))
                Spacer()
                if !model.updateBusy {
                    Button { model.dismissUpdate() } label: {
                        PhosphorIcon(name: "x", size: 9, tint: .secondary)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(L("Nanti"))
                }
            }
            Text(L("Kamu memakai {}.", AppVersion.current)).font(.system(size: 11)).foregroundStyle(.secondary)
            if model.updateBusy {
                ProgressView(value: min(max(model.updateProgress, 0), 1))
                    .progressViewStyle(.linear)
                    .tint(Theme.accent)
                    .animation(.easeOut(duration: 0.2), value: model.updateProgress)
                Text(model.updateStatus ?? L("Mengunduh pembaruan…"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 6) {
                    Button(L("Update sekarang")) { confirmAndInstallUpdate(model, version: update.version) }
                        .buttonStyle(PrimaryButtonStyle())
                    Button(L("Nanti")) { model.dismissUpdate() }
                        .buttonStyle(SecondaryButtonStyle())
                    Button(L("Catatan rilis")) { NSWorkspace.shared.open(update.page) }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.accent.opacity(0.35)))
    }
}

/// Pengaturan autocomplete terminal di strip tab.
struct AutocompleteMenu: View {
    @AppStorage(AutocompleteKeys.enabled) private var enabled = true
    @State private var confirmClear = false

    var body: some View {
        Menu {
            Toggle(L("Saran perintah saat mengetik"), isOn: $enabled)
            Divider()
            Button(L("Hapus riwayat perintah ({})", CommandHistory.count), role: .destructive) { confirmClear = true }
        } label: {
            PhosphorLabel(sf: enabled ? "text.cursor" : "text.badge.xmark",
                          text: L("Autocomplete"), size: 13,
                          tint: enabled ? Theme.accent : .secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(L("Saran perintah dari riwayat, snippet, dan perintah umum"))
        .confirmationDialog(L("Hapus semua riwayat perintah?"), isPresented: $confirmClear) {
            Button(L("Hapus"), role: .destructive) { CommandHistory.clear() }
        } message: {
            Text(L("Riwayat hanya tersimpan di Mac ini dan dipakai untuk saran autocomplete."))
        }
    }
}
