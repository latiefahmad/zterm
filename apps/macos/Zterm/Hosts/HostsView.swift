import SwiftUI

enum HostLayout: String { case grid, list }

struct HostsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(PrivacyKeys.hideAddresses) private var hideAddresses = true
    @AppStorage("hostLayout") private var layout: HostLayout = .grid
    @State private var query = ""
    @Namespace private var ns

    private var filtered: [Host] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return model.hosts }
        return model.hosts.filter { h in
            ([h.label, h.hostname, h.username, h.group ?? ""] + h.tags).contains { $0.lowercased().contains(q) }
        }
    }

    /// Dikelompokkan per grup; host tanpa grup di bagian "Hosts".
    private var grouped: [(String, [Host])] {
        let dict = Dictionary(grouping: filtered) { $0.group?.isEmpty == false ? $0.group! : "" }
        return dict.keys.sorted { a, b in a.isEmpty ? false : (b.isEmpty ? true : a < b) }
            .map { ($0, dict[$0]!) }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    if model.hosts.isEmpty {
                        EmptyHosts { model.editingHost = .blank() }
                    } else if filtered.isEmpty {
                        EmptyState(ph: "magnifying-glass", title: L("Tidak ada hasil"),
                                   text: L("Tidak ada host yang cocok dengan “{}”.", query))
                    } else {
                        ForEach(grouped, id: \.0) { group, hosts in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 8) {
                                    Text(group.isEmpty ? "HOSTS" : group.uppercased())
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .tracking(1.1)
                                    Text("\(hosts.count)")
                                        .font(.system(size: 10, weight: .semibold))
                                        .padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(Theme.ink.opacity(0.07), in: Capsule())
                                    Rectangle().fill(Theme.ink.opacity(0.06)).frame(height: 1)
                                }
                                .foregroundStyle(.secondary)

                                if layout == .grid {
                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 380), spacing: 12)], spacing: 12) {
                                        ForEach(Array(hosts.enumerated()), id: \.element.id) { i, h in
                                            HostTile(host: h, layout: .grid, ns: ns)
                                                .staggerIn(i, base: 0)
                                        }
                                    }
                                } else {
                                    VStack(spacing: 4) {
                                        ForEach(Array(hosts.enumerated()), id: \.element.id) { i, h in
                                            HostTile(host: h, layout: .list, ns: ns)
                                                .staggerIn(i, base: 0)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(28)
                .padding(.bottom, 80)
                .animation(.zterm, value: layout)
            }

            if !model.selection.isEmpty {
                SelectionBar(visibleIDs: filtered.map(\.id))
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.zterm, value: model.selection.isEmpty)
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Hosts").font(.system(size: 22, weight: .semibold)).tracking(-0.2)
                HStack(spacing: 6) {
                    Text(L("{} server", model.hosts.count))
                    let online = Set(model.sessions.filter { $0.status == .connected }.map(\.host.id)).count
                    if online > 0 {
                        Text("·")
                        Circle().fill(Theme.green).frame(width: 6, height: 6)
                        Text(L("{} terhubung", online)).contentTransition(.numericText())
                    }
                }
                .font(.system(size: 12.5)).foregroundStyle(.secondary)
                .help(L("⌘-klik untuk memilih beberapa host · klik dua kali untuk connect"))
            }
            Spacer()
            LayoutSwitch(layout: $layout)
            Button {
                withAnimation(.ztermSnappy) { hideAddresses.toggle() }
            } label: {
                PhosphorIcon(name: hideAddresses ? "eye-slash" : "eye", size: 14)
                    .frame(width: 16)
            }
            .buttonStyle(SecondaryButtonStyle())
            .help(hideAddresses ? L("Tampilkan alamat host") : L("Sembunyikan alamat host"))
            SearchField(text: $query, prompt: L("Cari host, IP, tag…"))
            ViewThatFits(in: .horizontal) {
                Button { model.editingHost = .blank() } label: {
                    PhosphorLabel(text: L("Host Baru"), icon: "plus", size: 12,
                                  tint: Color(hex: "#06231E"))
                }
                .buttonStyle(PrimaryButtonStyle()).fixedSize()
                Button { model.editingHost = .blank() } label: {
                    PhosphorIcon(name: "plus", size: 13, tint: Color(hex: "#06231E"))
                }
                .buttonStyle(PrimaryButtonStyle()).help(L("Host Baru"))
            }
        }
    }
}

/// Saklar Grid / List dengan indikator yang meluncur.
struct LayoutSwitch: View {
    @Binding var layout: HostLayout
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach([HostLayout.grid, .list], id: \.self) { l in
                PhosphorIcon(name: l == .grid ? "squares-four" : "list-dashes", size: 13,
                             tint: layout == l ? .primary : .secondary)
                    .frame(width: 30, height: 24)
                    .background {
                        if layout == l {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Theme.ink.opacity(0.1))
                                .matchedGeometryEffect(id: "layout", in: ns)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.ztermSnappy) { layout = l } }
                    .help(l == .grid ? L("Tampilan grid") : L("Tampilan list"))
            }
        }
        .padding(3)
        .background(Theme.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.cardStroke))
    }
}

// MARK: - Kartu host

struct HostTile: View {
    @Environment(AppModel.self) private var model
    @AppStorage(PrivacyKeys.hideAddresses) private var hideAddresses = true
    let host: Host
    let layout: HostLayout
    let ns: Namespace.ID

    @State private var hover = false

    private var color: Color { Color(hex: host.color) }
    private var selected: Bool { model.selection.contains(host.id) }
    private var editing: Bool { model.editingHost?.id == host.id }
    private var live: Bool { model.sessions.contains { $0.host.id == host.id && $0.status == .connected } }
    private var lastSeen: Date? {
        model.logs.first { $0.hostId == host.id }.map { Date(ms: $0.startedAt) }
    }

    var body: some View {
        Group {
            if layout == .grid { gridBody } else { listBody }
        }
        .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(hover ? Theme.cardHover : Theme.card))
        .overlay(border)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .shadow(color: Theme.shadow.opacity(hover ? 0.9 : 0.35), radius: hover ? 10 : 2, y: hover ? 4 : 1)
        .offset(y: hover ? -1 : 0)
        .animation(.ztermHover, value: hover)
        .animation(.ztermSnappy, value: selected)
        .contentShape(Rectangle())
        .onHover { h in hover = h }
        .onTapGesture(count: 2) { if model.selection.isEmpty { model.connect([host.id]) } }
        .simultaneousGesture(TapGesture().onEnded {
            if NSEvent.modifierFlags.contains(.command) || !model.selection.isEmpty { toggle() }
        })
        .contextMenu { menu }
    }

    private var radius: CGFloat { layout == .grid ? 12 : 10 }

    // MARK: Grid

    private var gridBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                icon(size: 42)
                Spacer()
                if hover && model.selection.isEmpty && !host.isTeam {
                    HStack(spacing: 2) {
                        IconButton(symbol: "pencil", help: L("Edit")) { model.editingHost = host }
                        IconButton(symbol: "doc.on.doc", help: L("Duplikat")) { duplicate() }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .topTrailing)))
                } else {
                    statusChip
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(host.title)
                    .font(.system(size: 14.5, weight: .semibold))
                    .lineLimit(1)
                    .matchedGeometryEffect(id: "title-\(host.id)", in: ns)
                Text(host.displayAddress(hidden: hideAddresses))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
            HStack(spacing: 5) {
                ForEach(host.tags.prefix(3), id: \.self) { tag in
                    Text(tag).font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(color.opacity(0.11), in: Capsule())
                        .foregroundStyle(color)
                }
                if host.tags.isEmpty {
                    PhosphorLabel(text: authLabel, icon: authIcon, size: 11, tint: .secondary)
                        .font(.system(size: 10, weight: .medium))
                }
                Spacer(minLength: 0)
                connectButton
            }
            .frame(height: 26)
        }
        .padding(14)
    }

    // MARK: List

    private var listBody: some View {
        HStack(spacing: 12) {
            icon(size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(host.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .matchedGeometryEffect(id: "title-\(host.id)", in: ns)
                Text(host.displayAddress(hidden: hideAddresses))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(minWidth: 160, alignment: .leading)
            HStack(spacing: 5) {
                ForEach(host.tags.prefix(4), id: \.self) { tag in
                    Text(tag).font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(color.opacity(0.11), in: Capsule())
                        .foregroundStyle(color)
                }
            }
            Spacer()
            PhosphorLabel(text: authLabel, icon: authIcon, size: 11, tint: .secondary)
                .font(.system(size: 11))
                .frame(width: 100, alignment: .leading)
            statusChip.frame(width: 130, alignment: .trailing)
            HStack(spacing: 2) {
                if !host.isTeam { IconButton(symbol: "pencil", help: L("Edit")) { model.editingHost = host } }
                connectButton
            }
            .opacity(hover || selected ? 1 : 0.4)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    // MARK: Bagian bersama

    private func icon(size: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Theme.accent.opacity(0.16) : color.opacity(0.11))
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder((selected ? Theme.accent : color).opacity(0.2), lineWidth: 1)
            PhosphorIcon(name: selected ? "check" : host.isTeam ? "users-three" : "hard-drives",
                         size: size * 0.44, tint: selected ? Theme.accent : color)
            if live {
                Circle().fill(Theme.green)
                    .frame(width: size * 0.26, height: size * 0.26)
                    .overlay(Circle().strokeBorder(Theme.card, lineWidth: 2))
                    .offset(x: size * 0.42, y: -size * 0.42)
            }
        }
        .frame(width: size, height: size)
        .matchedGeometryEffect(id: "icon-\(host.id)", in: ns)
        .onTapGesture { toggle() }
    }

    @ViewBuilder
    private var statusChip: some View {
        if live {
            HStack(spacing: 5) {
                PulseDot(color: Theme.green)
                Text(L("Terhubung"))
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.green)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Theme.green.opacity(0.11), in: Capsule())
        } else if let lastSeen {
            Text(lastSeen.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Theme.ink.opacity(0.05), in: Capsule())
                .help(L("Terakhir connect"))
        } else {
            Text(L("Belum pernah"))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
        }
    }

    private var connectButton: some View {
        Button {
            model.connect([host.id])
        } label: {
            HStack(spacing: 4) {
                PhosphorIcon(name: "lightning", size: 10,
                             tint: hover ? Color.black.opacity(0.8) : color)
                if layout == .grid && hover {
                    Text(L("Connect")).transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(hover ? Color.black.opacity(0.8) : color)
            .padding(.horizontal, 9).frame(height: 24)
            .background(hover ? Theme.accent : color.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(L("Connect (klik dua kali kartu)"))
        .animation(.ztermSnappy, value: hover)
    }

    @ViewBuilder
    private var border: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if selected || editing {
            shape.strokeBorder(Theme.accent, lineWidth: 1)
        } else {
            shape.strokeBorder(hover ? Theme.ink.opacity(0.16) : Theme.cardStroke)
        }
    }

    private var authLabel: String {
        switch host.auth { case .password: L("Password"); case .key: L("SSH Key"); case .agent: L("Agent") }
    }
    private var authIcon: String {
        switch host.auth { case .password: "password"; case .key: "key"; case .agent: "user-circle" }
    }

    @ViewBuilder
    private var menu: some View {
        Button(L("Connect")) { model.connect([host.id]) }
        Button(L("Buka SFTP")) { Task { await model.openSftp(host) } }
        if host.isTeam {
            Text(L("Host tim · hanya admin yang bisa mengubah"))
        } else {
            Button(L("Edit")) { model.editingHost = host }
            Button(L("Duplikat")) { duplicate() }
        }
        Button(selected ? L("Batal pilih") : L("Pilih")) { toggle() }
        Divider()
        Button(L("Salin alamat")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(host.address, forType: .string)
            model.flash(L("Alamat disalin"))
        }
        if !host.isTeam {
            Divider()
            Button(L("Hapus"), role: .destructive) { model.delete(host) }
        }
    }

    private func duplicate() {
        var copy = host
        copy.id = ""
        copy.label = host.title + " (salinan)"
        model.save(copy)
    }

    private func toggle() {
        withAnimation(.ztermSnappy) {
            if selected { model.selection.remove(host.id) } else { model.selection.insert(host.id) }
        }
    }
}

struct PulseDot: View {
    let color: Color
    @State private var on = false
    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.5)).scaleEffect(on ? 2 : 1).opacity(on ? 0 : 1)
            Circle().fill(color)
        }
        .frame(width: 6, height: 6)
        .onAppear { withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) { on = true } }
    }
}

struct SelectionBar: View {
    @Environment(AppModel.self) private var model
    let visibleIDs: [String]

    var body: some View {
        HStack(spacing: 12) {
            Text("\(model.selection.count)")
                .font(.system(size: 12, weight: .semibold))
                .frame(minWidth: 22, minHeight: 22)
                .background(Theme.accent, in: Circle())
                .foregroundStyle(Color(hex: "#06231E"))
                .contentTransition(.numericText())
            Text(L("host dipilih")).font(.system(size: 12.5))
            Divider().frame(height: 18)
            Button(L("Pilih semua")) { withAnimation(.ztermSnappy) { model.selection = Set(visibleIDs) } }
                .buttonStyle(.borderless)
            Button(L("Batal")) { withAnimation(.ztermSnappy) { model.selection.removeAll() } }
                .buttonStyle(.borderless)
            Button {
                model.connect(model.hosts.map(\.id).filter { model.selection.contains($0) })
            } label: {
                PhosphorLabel(text: L("Connect semua"), icon: "lightning", size: 12,
                              tint: Color(hex: "#06231E"))
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.return)
        }
        .padding(.leading, 12).padding(.trailing, 8).padding(.vertical, 7)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.cardStroke))
        .shadow(color: Theme.shadow, radius: 20, y: 8)
        .animation(.ztermSnappy, value: model.selection.count)
    }
}

struct EmptyHosts: View {
    var onAdd: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.ink.opacity(0.05))
                    .frame(width: 72, height: 72)
                PhosphorIcon(name: "hard-drives", size: 34, tint: Theme.accent)
            }
            Text(L("Belum ada host")).font(.system(size: 16, weight: .semibold))
            Text(L("Tambahkan server pertamamu, lalu connect dengan satu klik."))
                .font(.system(size: 12.5)).foregroundStyle(.secondary)
            Button(action: onAdd) {
                PhosphorLabel(text: L("Tambah host"), icon: "plus", size: 12,
                              tint: Color(hex: "#06231E"))
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 56)
    }
}

struct IconButton: View {
    let symbol: String
    var help: String = ""
    var tint: Color = .secondary
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            PhosphorIcon(sf: symbol, size: 13, tint: hover ? .primary : tint)
                .frame(width: 26, height: 26)
                .background(Theme.ink.opacity(hover ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}
