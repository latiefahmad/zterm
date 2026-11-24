import SwiftUI

/// Panel kanan untuk membuat / mengedit host.
/// Susunan: Address → General → SSH & Credentials → Lanjutan → Tema terminal.
struct HostEditor: View {
    @Environment(AppModel.self) private var model
    let original: Host
    @State private var h: Host
    @State private var tagsText: String
    @State private var showPassword = false
    @State private var showAdvanced = false
    @State private var newKeyLabel = ""
    @FocusState private var addressFocused: Bool

    init(original: Host) {
        self.original = original
        _h = State(initialValue: original)
        _tagsText = State(initialValue: original.tags.joined(separator: ", "))
        _showAdvanced = State(initialValue: original.agentForwarding || original.jumpHostId != nil || original.proxy != nil
                              || !(original.startupSnippet ?? "").isEmpty || !original.env.isEmpty)
    }

    private var isNew: Bool { original.id.isEmpty }
    private var canSave: Bool {
        !h.hostname.trimmingCharacters(in: .whitespaces).isEmpty
            && (h.proxy.map { !$0.host.trimmingCharacters(in: .whitespaces).isEmpty } ?? true)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 14) {
                    addressCard
                    generalCard
                    colorCard
                    sshCard
                    advancedCard
                    themeCard
                    if !isNew {
                        Button(role: .destructive) {
                            model.delete(original)
                            model.editingHost = nil
                        } label: {
                            Label(L("Hapus host"), systemImage: "trash").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(SecondaryButtonStyle(wide: true))
                        .foregroundStyle(.red)
                        .padding(.top, 4)
                    }
                }
                .padding(16)
            }
            footer
        }
        .background(Theme.panel)
        .onAppear { if isNew { addressFocused = true } }
    }

    // MARK: Header / footer

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(isNew ? L("Host Baru") : L("Edit Host")).font(.system(size: 17, weight: .bold))
                Text(model.accountEmail == nil ? L("Vault pribadi") : L("Vault · {}", model.accountEmail!))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            IconButton(symbol: "xmark", help: L("Tutup (Esc)")) { model.editingHost = nil }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            Button(L("Simpan")) { save(connect: false) }
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut("s")
            Button {
                save(connect: true)
            } label: {
                Label(L("Connect"), systemImage: "bolt.fill").lineLimit(1)
            }
            .help(L("Simpan lalu connect (⌘⏎)"))
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.return, modifiers: .command)
        }
        .disabled(!canSave)
        .padding(14)
        .overlay(alignment: .top) { Divider() }
    }

    private func save(connect: Bool) {
        h.hostname = h.hostname.trimmingCharacters(in: .whitespaces)
        h.tags = tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if h.group?.trimmingCharacters(in: .whitespaces).isEmpty == true { h.group = nil }
        guard let saved = model.save(h) else { return }
        model.editingHost = nil
        model.flash(isNew ? L("Host “{}” ditambahkan", saved.title) : L("Perubahan disimpan"))
        if connect { model.connect([saved.id]) }
    }

    // MARK: Cards

    private var addressCard: some View {
        EditorCard(L("Address")) {
            HStack(spacing: 10) {
                Menu {
                    ForEach(Theme.hostColors, id: \.self) { c in
                        Button {
                            withAnimation(.ztermSnappy) { h.color = c }
                        } label: {
                            Label(c, systemImage: h.color == c ? "checkmark.circle.fill" : "circle.fill")
                        }
                    }
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(hex: h.color).gradient)
                        Image(systemName: "server.rack").font(.system(size: 17, weight: .bold)).foregroundStyle(.black.opacity(0.7))
                    }
                    .frame(width: 44, height: 44)
                }
                .menuStyle(.button).buttonStyle(.plain)
                .help(L("Ganti warna"))

                TextField(L("IP atau hostname"), text: $h.hostname)
                    .focused($addressFocused)
                    .ztermField()
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(addressFocused ? Theme.accent : .clear, lineWidth: 1.5))
                    .animation(.ztermSnappy, value: addressFocused)
            }
        }
    }

    private var generalCard: some View {
        EditorCard(L("General")) {
            FieldRow(icon: "textformat") { TextField(L("Label"), text: $h.label).textFieldStyle(.plain) }
            FieldRow(icon: "square.stack.3d.up") {
                TextField(L("Grup"), text: Binding(get: { h.group ?? "" }, set: { h.group = $0 }))
                    .textFieldStyle(.plain)
                let groups = Set(model.ownHosts.compactMap(\.group)).sorted()
                if !groups.isEmpty {
                    Menu {
                        ForEach(groups, id: \.self) { g in Button(g) { h.group = g } }
                    } label: { Image(systemName: "chevron.down") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
            }
            FieldRow(icon: "tag") { TextField(L("Tag (pisahkan dengan koma)"), text: $tagsText).textFieldStyle(.plain) }
        }
    }

    private var sshCard: some View {
        EditorCard(nil) {
            HStack(spacing: 8) {
                Text(L("SSH di port")).font(.system(size: 14, weight: .semibold))
                TextField("22", value: $h.port, format: .number.grouping(.never))
                    .multilineTextAlignment(.center)
                    .frame(width: 70)
                    .ztermField()
            }
            Divider().padding(.vertical, 4)
            Text(L("Credentials")).font(.system(size: 14, weight: .semibold))

            FieldRow(icon: "person.fill") { TextField(L("Username"), text: $h.username).textFieldStyle(.plain) }

            Picker("", selection: $h.auth.animation(.zterm)) {
                Text(L("Password")).tag(AuthMethod.password)
                Text(L("SSH Key")).tag(AuthMethod.key)
                Text(L("Agent")).tag(AuthMethod.agent)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch h.auth {
                case .password:
                    FieldRow(icon: "ellipsis.rectangle") {
                        Group {
                            if showPassword {
                                TextField(L("Password"), text: passwordBinding)
                            } else {
                                SecureField(L("Password"), text: passwordBinding)
                            }
                        }
                        .textFieldStyle(.plain)
                        Button { showPassword.toggle() } label: {
                            Image(systemName: showPassword ? "eye" : "eye.slash")
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    Text(L("Kosongkan jika ingin mengetik password saat connect."))
                        .font(.caption).foregroundStyle(.tertiary)
                case .key:
                    keyPicker
                case .agent:
                    Label(L("Memakai SSH agent sistem (mis. 1Password, ssh-agent)."), systemImage: "person.badge.key")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private var passwordBinding: Binding<String> {
        Binding(get: { h.password ?? "" }, set: { h.password = $0.isEmpty ? nil : $0 })
    }

    @ViewBuilder
    private var keyPicker: some View {
        let selected = model.key(id: h.keyId)
        Menu {
            ForEach(model.keys) { k in
                Button {
                    h.keyId = k.id
                } label: {
                    Label("\(k.label) · \(k.keyType)", systemImage: h.keyId == k.id ? "checkmark" : "key")
                }
            }
            if !model.keys.isEmpty { Divider() }
            Button(L("Generate key Ed25519 baru")) {
                if let k = try? model.generateKey(label: h.title.isEmpty ? "host-key" : h.title) {
                    h.keyId = k.id
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(k.publicKey, forType: .string)
                    model.flash(L("Key dibuat · public key disalin ke clipboard"))
                }
            }
            Button(L("Buka Keychain…")) {
                model.editingHost = nil
                model.section = .keychain
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "key.fill").foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(selected?.label ?? L("Pilih SSH key")).font(.system(size: 13, weight: .medium))
                    if let s = selected {
                        Text(s.fingerprint).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.ink.opacity(0.1)))
        }
        .menuStyle(.button).buttonStyle(.plain)
    }

    private var advancedCard: some View {
        EditorCard(nil) {
            Button {
                withAnimation(.zterm) { showAdvanced.toggle() }
            } label: {
                HStack {
                    Text(L("Lanjutan")).font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showAdvanced {
                VStack(spacing: 10) {
                    FieldRow(icon: "shield.lefthalf.filled") {
                        Text(L("Agent Forwarding"))
                        Spacer()
                        Toggle("", isOn: $h.agentForwarding).toggleStyle(.switch).labelsHidden().controlSize(.small)
                    }
                    FieldRow(icon: "curlybraces") {
                        TextField(L("Startup snippet (dijalankan setelah login)"),
                                  text: Binding(get: { h.startupSnippet ?? "" }, set: { h.startupSnippet = $0.isEmpty ? nil : $0 }))
                            .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced))
                    }
                    FieldRow(icon: "point.3.connected.trianglepath.dotted") {
                        Picker(L("Host Chaining"), selection: $h.jumpHostId) {
                            Text(L("Tanpa jump host")).tag(String?.none)
                            ForEach(model.ownHosts.filter { $0.id != h.id }) { j in
                                Text(j.title).tag(Optional(j.id))
                            }
                        }
                        .labelsHidden()
                        Spacer()
                        Text(L("Jump host")).font(.caption).foregroundStyle(.secondary)
                    }
                    proxyEditor
                    envEditor
                    FieldRow(icon: "character.cursor.ibeam") {
                        Picker(L("Charset"), selection: $h.charset) {
                            Text("UTF-8").tag("UTF-8")
                            Text("ASCII").tag("ASCII")
                        }
                        .labelsHidden()
                        Spacer()
                        Text(L("Charset")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: Proxy

    private var proxyKind: Binding<ProxyKind?> {
        Binding(get: { h.proxy?.kind }, set: { kind in
            withAnimation(.ztermSnappy) {
                guard let kind else { h.proxy = nil; return }
                let port: UInt16 = kind == .http ? 8080 : 1080
                if var p = h.proxy {
                    // Port bawaan ikut berganti jika belum diubah pengguna
                    if p.port == 1080 || p.port == 8080 { p.port = port }
                    p.kind = kind
                    h.proxy = p
                } else {
                    h.proxy = HostProxy(kind: kind, host: "", port: port, username: nil, password: nil)
                }
            }
        })
    }

    private func proxyText(_ get: @escaping (HostProxy) -> String?, _ set: @escaping (inout HostProxy, String?) -> Void) -> Binding<String> {
        Binding(get: { h.proxy.flatMap(get) ?? "" },
                set: { v in if var p = h.proxy { set(&p, v.isEmpty ? nil : v); h.proxy = p } })
    }

    private var proxyEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldRow(icon: "network.badge.shield.half.filled") {
                Picker(L("Proxy"), selection: proxyKind) {
                    Text(L("Tanpa proxy")).tag(ProxyKind?.none)
                    Text("SOCKS5").tag(Optional(ProxyKind.socks5))
                    Text("HTTP").tag(Optional(ProxyKind.http))
                }
                .labelsHidden()
                Spacer()
                Text(L("Proxy")).font(.caption).foregroundStyle(.secondary)
            }
            if h.proxy != nil {
                HStack(spacing: 6) {
                    TextField(L("Alamat proxy"), text: proxyText({ $0.host }, { $0.host = ($1 ?? "").trimmingCharacters(in: .whitespaces) }))
                        .ztermField(error: h.proxy?.host.isEmpty ?? false).font(.system(size: 12, design: .monospaced))
                    TextField(L("Port"), text: proxyText({ String($0.port) }, { p, v in if let n = UInt16(v ?? "") { p.port = n } }))
                        .ztermField().font(.system(size: 12, design: .monospaced)).frame(width: 72)
                }
                HStack(spacing: 6) {
                    TextField(L("Username (opsional)"), text: proxyText({ $0.username }, { $0.username = $1 }))
                        .ztermField().font(.system(size: 12))
                    SecureField(L("Password"), text: proxyText({ $0.password }, { $0.password = $1 }))
                        .ztermField().font(.system(size: 12))
                }
                Text(h.jumpHostId != nil
                     ? L("Proxy tidak dipakai di terminal selama jump host aktif.")
                     : L("Dipakai untuk terminal, SFTP, port forwarding, dan tunnel database host ini."))
                    .font(.caption).foregroundStyle(.secondary).padding(.leading, 4)
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var envEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(h.env.indices, id: \.self) { i in
                HStack(spacing: 6) {
                    TextField(L("NAMA"), text: $h.env[i].name).ztermField().font(.system(size: 12, design: .monospaced))
                    TextField(L("nilai"), text: $h.env[i].value).ztermField().font(.system(size: 12, design: .monospaced))
                    IconButton(symbol: "minus", help: L("Hapus")) { withAnimation(.ztermSnappy) { _ = h.env.remove(at: i) } }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            Button {
                withAnimation(.ztermSnappy) { h.env.append(EnvVar(name: "", value: "")) }
            } label: {
                Label(L("Environment variable"), systemImage: "plus").font(.callout)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .padding(.leading, 4)
        }
    }

    private var themeCard: some View {
        EditorCard(L("Tema terminal")) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 12) {
                themeOption(id: nil, name: L("Otomatis"), preview: TerminalThemes.def(nil))
                ForEach(TerminalThemes.all) { t in themeOption(id: t.id, name: t.name, preview: t) }
            }
        }
    }

    private func themeOption(id: String?, name: String, preview: TerminalThemes.Def) -> some View {
        let active = h.terminalTheme == id
        return VStack(alignment: .leading, spacing: 6) {
            ThemePreview(theme: preview, auto: id == nil)
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(active ? Theme.accent : Theme.ink.opacity(0.1), lineWidth: active ? 2 : 1))
                .overlay(alignment: .topTrailing) {
                    if active {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.accent, .white)
                            .offset(x: 5, y: -5)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .scaleEffect(active ? 1 : 0.96)
            Text(name).font(.caption).foregroundStyle(active ? .primary : .secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.ztermSnappy) { h.terminalTheme = id } }
    }

    private var colorCard: some View {
        EditorCard(L("Warna kartu")) {
            CardPreview(host: h)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 26), spacing: 8)], spacing: 8) {
                ForEach(Theme.cardPalette, id: \.self) { c in
                    let active = h.color.uppercased() == c.uppercased()
                    Circle()
                        .fill(LinearGradient(colors: [Color(hex: c), Color(hex: c).opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 26, height: 26)
                        .overlay(Circle().strokeBorder(.white.opacity(active ? 0.9 : 0), lineWidth: 2).padding(2))
                        .overlay { if active { Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(.black.opacity(0.7)) } }
                        .scaleEffect(active ? 1.12 : 1)
                        .shadow(color: Color(hex: c).opacity(active ? 0.6 : 0), radius: 6)
                        .onTapGesture { withAnimation(.ztermSnappy) { h.color = c } }
                }
            }
            HStack {
                Text(L("Warna lain")).font(.callout).foregroundStyle(.secondary)
                Spacer()
                ColorPicker("", selection: Binding(
                    get: { Color(hex: h.color) },
                    set: { h.color = $0.hexString }
                ), supportsOpacity: false)
                .labelsHidden()
                Text(h.color.uppercased()).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Komponen

struct EditorCard<Content: View>: View {
    let title: String?
    @ViewBuilder var content: () -> Content
    init(_ title: String?, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title { Text(title).font(.system(size: 14, weight: .semibold)) }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: 14)
    }
}

struct FieldRow<Content: View>: View {
    let icon: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18)
            content()
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12).frame(minHeight: 38)
        .background(Theme.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.ink.opacity(0.1)))
    }
}

struct ThemePreview: View {
    let theme: TerminalThemes.Def
    var auto = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 3) {
                Text("$").foregroundStyle(Color(hex: theme.accent))
                Capsule().fill(Color(hex: theme.fg).opacity(0.75)).frame(width: 34, height: 4)
            }
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            HStack(spacing: 3) {
                ForEach([1, 2, 3, 4, 5, 6], id: \.self) { i in
                    Circle().fill(Color(hex: theme.ansi[i])).frame(width: 7, height: 7)
                }
            }
            HStack(spacing: 3) {
                Capsule().fill(Color(hex: theme.fg).opacity(0.45)).frame(width: 22, height: 4)
                Rectangle().fill(Color(hex: theme.accent)).frame(width: 5, height: 8)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
        .background {
            if auto {
                // Separuh gelap, separuh terang: mengikuti mode app
                LinearGradient(stops: [.init(color: Color(hex: "#0B0E13"), location: 0.5), .init(color: Color(hex: "#F7F6F2"), location: 0.5)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .opacity(0.9)
            } else {
                Color(hex: theme.bg)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }
}

/// Pratinjau kecil kartu host dengan warna terpilih.
struct CardPreview: View {
    let host: Host
    var body: some View {
        let c = Color(hex: host.color)
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(LinearGradient(colors: [c, c.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(Image(systemName: "server.rack").font(.system(size: 16, weight: .bold)).foregroundStyle(.black.opacity(0.7)))
                .frame(width: 40, height: 40)
                .shadow(color: c.opacity(0.5), radius: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.title.isEmpty ? L("Nama host") : host.title).font(.system(size: 13, weight: .semibold))
                Text("\(host.username)@••••••••").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "bolt.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(c)
                .frame(width: 26, height: 26).background(c.opacity(0.15), in: Circle())
        }
        .padding(12)
        .background(LinearGradient(colors: [c.opacity(0.16), Theme.card], startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(c.opacity(0.45)))
        .animation(.ztermSnappy, value: host.color)
    }
}
