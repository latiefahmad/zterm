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
                VStack(alignment: .leading, spacing: 26) {
                    header
                    if model.hosts.isEmpty {
                        EmptyHosts { model.editingHost = .blank() }
                    } else if filtered.isEmpty {
                        Text(L("Tidak ada host yang cocok dengan “{}”", query))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.top, 60)
                    } else {
                        ForEach(grouped, id: \.0) { group, hosts in
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 8) {
                                    Text(group.isEmpty ? "HOSTS" : group.uppercased())
                                        .font(.system(size: 11, weight: .semibold))
                                        .tracking(1.2)
                                    Text("\(hosts.count)")
                                        .font(.system(size: 10, weight: .bold))
                                        .padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(Theme.ink.opacity(0.08), in: Capsule())
                                    Rectangle().fill(Theme.ink.opacity(0.07)).frame(height: 1)
                                }
                                .foregroundStyle(.secondary)

                                if layout == .grid {
                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 360), spacing: 14)], spacing: 14) {
                                        ForEach(Array(hosts.enumerated()), id: \.element.id) { i, h in
                                            HostTile(host: h, layout: .grid, ns: ns)
                                                .staggerIn(i, base: 0)
                                        }
                                    }
                                } else {
                                    VStack(spacing: 6) {
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
            VStack(alignment: .leading, spacing: 2) {
                Text("Hosts").font(.system(size: 26, weight: .bold, design: .rounded))
                HStack(spacing: 6) {
                    Text(L("{} server", model.hosts.count))
                    let online = Set(model.sessions.filter { $0.status == .connected }.map(\.host.id)).count
                    if online > 0 {
                        Text("·")
                        Circle().fill(Color(hex: "#4ADE80")).frame(width: 6, height: 6)
                        Text(L("{} terhubung", online)).contentTransition(.numericText())
                    }
                }
                .font(.callout).foregroundStyle(.secondary)
                .help(L("⌘-klik untuk memilih beberapa host · klik dua kali untuk connect"))
            }
            Spacer()
            LayoutSwitch(layout: $layout)
            Button {
                withAnimation(.ztermSnappy) { hideAddresses.toggle() }
            } label: {
                Image(systemName: hideAddresses ? "eye.slash" : "eye")
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 16)
            }
            .buttonStyle(SecondaryButtonStyle())
            .help(hideAddresses ? L("Tampilkan alamat host") : L("Sembunyikan alamat host"))
            SearchField(text: $query, prompt: L("Cari host, IP, tag…"))
            ViewThatFits(in: .horizontal) {
                Button { model.editingHost = .blank() } label: { Label(L("Host Baru"), systemImage: "plus") }
                    .buttonStyle(PrimaryButtonStyle()).fixedSize()
                Button { model.editingHost = .blank() } label: { Image(systemName: "plus") }
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
                Image(systemName: l == .grid ? "square.grid.2x2" : "list.bullet")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 24)
                    .foregroundStyle(layout == l ? .primary : .secondary)
                    .background {
                        if layout == l {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Theme.ink.opacity(0.12))
                                .matchedGeometryEffect(id: "layout", in: ns)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.ztermSnappy) { layout = l } }
                    .help(l == .grid ? L("Tampilan grid") : L("Tampilan list"))
            }
        }
        .padding(3)
        .background(Theme.ink.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
    @State private var mouse: CGPoint = .zero

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
        .background(background)
        .overlay(border)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .shadow(color: color.opacity(hover ? 0.22 : 0), radius: 18, y: 8)
        .shadow(color: Theme.shadow.opacity(hover ? 1 : 0.4), radius: hover ? 14 : 3, y: hover ? 8 : 1)
        .offset(y: hover ? -2 : 0)
        .animation(.ztermHover, value: hover)
        .animation(.ztermSnappy, value: selected)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let p): mouse = p; if !hover { hover = true }
            case .ended: hover = false
            }
        }
        .onTapGesture(count: 2) { if model.selection.isEmpty { model.connect([host.id]) } }
        .simultaneousGesture(TapGesture().onEnded {
            if NSEvent.modifierFlags.contains(.command) || !model.selection.isEmpty { toggle() }
        })
        .contextMenu { menu }
    }

    private var radius: CGFloat { layout == .grid ? 16 : 12 }

    // MARK: Grid

    private var gridBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                icon(size: 46)
                Spacer()
                if hover && model.selection.isEmpty && !host.isTeam {
                    HStack(spacing: 4) {
                        IconButton(symbol: "pencil", help: L("Edit")) { model.editingHost = host }
                        IconButton(symbol: "doc.on.doc", help: L("Duplikat")) { duplicate() }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .topTrailing)))
                } else {
                    statusChip
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(host.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .matchedGeometryEffect(id: "title-\(host.id)", in: ns)
                Text(host.displayAddress(hidden: hideAddresses))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
            HStack(spacing: 5) {
                ForEach(host.tags.prefix(3), id: \.self) { tag in
                    Text(tag).font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(color.opacity(0.13), in: Capsule())
                        .foregroundStyle(color)
                }
                if host.tags.isEmpty {
                    Label(authLabel, systemImage: authIcon).font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                connectButton
            }
            .frame(height: 26)
        }
        .padding(16)
    }

    // MARK: List

    private var listBody: some View {
        HStack(spacing: 14) {
            icon(size: 34)
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
                        .background(color.opacity(0.13), in: Capsule())
                        .foregroundStyle(color)
                }
            }
            Spacer()
            Label(authLabel, systemImage: authIcon)
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .frame(width: 90, alignment: .leading)
            statusChip.frame(width: 130, alignment: .trailing)
            HStack(spacing: 4) {
                if !host.isTeam { IconButton(symbol: "pencil", help: L("Edit")) { model.editingHost = host } }
                connectButton
            }
            .opacity(hover || selected ? 1 : 0.35)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    // MARK: Bagian bersama

    private func icon(size: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(selected ? AnyShapeStyle(Theme.brandGradient)
                               : AnyShapeStyle(LinearGradient(colors: [color, color.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing)))
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .strokeBorder(.white.opacity(0.25), lineWidth: 1)
            Image(systemName: selected ? "checkmark" : host.isTeam ? "person.2.fill" : "server.rack")
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundStyle(.black.opacity(0.72))
                .contentTransition(.symbolEffect(.replace))
            if live {
                Circle().fill(Color(hex: "#4ADE80"))
                    .frame(width: size * 0.26, height: size * 0.26)
                    .overlay(Circle().strokeBorder(Theme.bg, lineWidth: 2))
                    .offset(x: size * 0.42, y: -size * 0.42)
                    .transition(.scale)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: color.opacity(hover ? 0.55 : 0.2), radius: hover ? 10 : 4)
        .rotationEffect(.degrees(hover && layout == .grid ? -4 : 0))
        .scaleEffect(hover && layout == .grid ? 1.06 : 1)
        .animation(.ztermSnappy, value: hover)
        .matchedGeometryEffect(id: "icon-\(host.id)", in: ns)
        .onTapGesture { toggle() }
    }

    @ViewBuilder
    private var statusChip: some View {
        if live {
            HStack(spacing: 5) {
                PulseDot(color: Color(hex: "#4ADE80"))
                Text(L("Terhubung"))
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color(hex: "#4ADE80"))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color(hex: "#4ADE80").opacity(0.12), in: Capsule())
        } else if let lastSeen {
            Text(lastSeen.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8).padding(.vertical, 4)
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
                Image(systemName: "bolt.fill")
                if layout == .grid && hover { Text(L("Connect")).transition(.opacity.combined(with: .move(edge: .trailing))) }
            }
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(hover ? Color.black.opacity(0.8) : color)
            .padding(.horizontal, 9).frame(height: 26)
            .background {
                Capsule().fill(hover ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(color.opacity(0.14)))
            }
        }
        .buttonStyle(.plain)
        .help(L("Connect (klik dua kali kartu)"))
        .animation(.ztermSnappy, value: hover)
    }

    private var background: some View {
        ZStack {
            Rectangle().fill(hover || selected ? Theme.cardHover : Theme.card)
            // Sorotan halus yang mengikuti kursor
            if hover {
                GeometryReader { geo in
                    // Pusat gradien mengikuti kursor (tanpa menggeser view-nya)
                    RadialGradient(colors: [color.opacity(0.20), color.opacity(0.06), .clear],
                                   center: UnitPoint(x: geo.size.width > 0 ? mouse.x / geo.size.width : 0.5,
                                                     y: geo.size.height > 0 ? mouse.y / geo.size.height : 0.5),
                                   startRadius: 0, endRadius: layout == .grid ? 200 : 300)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
            // Garis warna host di sisi kiri (list) / atas (grid)
            if layout == .grid {
                LinearGradient(colors: [color.opacity(0.14), .clear], startPoint: .top, endPoint: .center)
            } else {
                HStack { Rectangle().fill(color).frame(width: 3); Spacer() }
            }
        }
    }

    @ViewBuilder
    private var border: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if selected || editing {
            shape.strokeBorder(Theme.accent, lineWidth: 1.5)
        } else if hover {
            // Border gradien yang berputar saat di-hover
            TimelineView(.animation) { ctx in
                let angle = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4) / 4 * 360
                shape.strokeBorder(
                    AngularGradient(colors: [color, Theme.accent2, Theme.accent3, color], center: .center,
                                    angle: .degrees(angle)),
                    lineWidth: 1.2)
                    .opacity(0.9)
            }
            .transition(.opacity)
        } else {
            shape.strokeBorder(Theme.cardStroke)
        }
    }

    private var authLabel: String {
        switch host.auth { case .password: L("Password"); case .key: L("SSH Key"); case .agent: L("Agent") }
    }
    private var authIcon: String {
        switch host.auth { case .password: "ellipsis.rectangle"; case .key: "key.fill"; case .agent: "person.badge.key" }
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
        HStack(spacing: 14) {
            Text("\(model.selection.count)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .frame(minWidth: 24, minHeight: 24)
                .background(Theme.accent, in: Circle())
                .foregroundStyle(.black)
                .contentTransition(.numericText())
            Text(L("host dipilih")).font(.callout)
            Divider().frame(height: 18)
            Button(L("Pilih semua")) { withAnimation(.ztermSnappy) { model.selection = Set(visibleIDs) } }
                .buttonStyle(.borderless)
            Button(L("Batal")) { withAnimation(.ztermSnappy) { model.selection.removeAll() } }
                .buttonStyle(.borderless)
            Button {
                model.connect(model.hosts.map(\.id).filter { model.selection.contains($0) })
            } label: {
                Label(L("Connect semua"), systemImage: "bolt.fill")
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.return)
        }
        .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 8)
        .background(.ultraThickMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.ink.opacity(0.1)))
        .shadow(color: Theme.shadow, radius: 24, y: 10)
        .animation(.ztermSnappy, value: model.selection.count)
    }
}

struct EmptyHosts: View {
    var onAdd: () -> Void
    @State private var animate = false

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                ForEach(0..<3) { i in
                    Circle()
                        .stroke(Theme.accent.opacity(0.35), lineWidth: 1)
                        .frame(width: 70, height: 70)
                        .scaleEffect(animate ? 2.2 : 1)
                        .opacity(animate ? 0 : 0.8)
                        .animation(.easeOut(duration: 2.4).repeatForever(autoreverses: false).delay(Double(i) * 0.8), value: animate)
                }
                Image(systemName: "server.rack")
                    .font(.system(size: 30))
                    .foregroundStyle(Theme.brandGradient)
            }
            .frame(height: 140)
            Text(L("Belum ada host")).font(.title3.bold())
            Text(L("Tambahkan server pertamamu, lalu connect dengan satu klik."))
                .foregroundStyle(.secondary)
            Button(action: onAdd) { Label(L("Tambah host"), systemImage: "plus") }
                .buttonStyle(PrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 50)
        .onAppear { animate = true }
    }
}

struct IconButton: View {
    let symbol: String
    var help: String = ""
    var tint: Color = .primary
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(Theme.ink.opacity(hover ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}
