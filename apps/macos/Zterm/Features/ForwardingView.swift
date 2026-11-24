import SwiftUI

struct ForwardingView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: PortForward?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: "Port Forwarding", subtitle: L("Teruskan port lewat SSH: local, remote, atau proxy SOCKS")) {
                    Button { editing = .blank(hostId: model.hosts.first?.id ?? "") } label: {
                        Label(L("Aturan Baru"), systemImage: "plus")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.hosts.isEmpty)
                }
                if model.forwards.isEmpty {
                    EmptyState(icon: "arrow.right.arrow.left", title: L("Belum ada aturan"),
                               text: model.hosts.isEmpty ? L("Tambahkan host dulu, lalu buat aturan port forwarding.")
                                   : L("Contoh: buka database server di localhost:5433 lewat tunnel SSH."))
                } else {
                    VStack(spacing: 10) {
                        ForEach(Array(model.forwards.enumerated()), id: \.element.id) { i, f in
                            ForwardRow(forward: f, onEdit: { editing = f }).staggerIn(i, base: 0)
                        }
                    }
                }
            }
            .padding(28)
        }
        .sheet(item: $editing) { ForwardEditor(original: $0) }
    }
}

struct ForwardRow: View {
    @Environment(AppModel.self) private var model
    @AppStorage(PrivacyKeys.hideAddresses) private var hideAddresses = true
    let forward: PortForward
    var onEdit: () -> Void

    private var state: TunnelManager.State? { model.tunnels.states[forward.id] }
    private var running: Bool { model.tunnels.isRunning(forward.id) }

    var body: some View {
        HoverCard {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(running ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Theme.ink.opacity(0.08)))
                    Image(systemName: forward.kind.icon)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(running ? Color.black.opacity(0.7) : .secondary)
                        .symbolEffect(.pulse, isActive: state == .starting)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(forward.label.isEmpty ? L("Tanpa nama") : forward.label).font(.system(size: 14, weight: .semibold))
                        Badge(text: forward.kind.short)
                    }
                    Text(forward.summary(via: model.host(id: forward.hostId)?.title ?? L("host terhapus"), hideRemote: hideAddresses))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if case .failed(let msg) = state {
                        Text(msg).font(.caption).foregroundStyle(.orange).lineLimit(2).transition(.opacity)
                    }
                }
                Spacer()
                StatusPill(state: state)
                IconButton(symbol: "pencil", help: L("Edit"), action: onEdit)
                IconButton(symbol: "trash", help: L("Hapus"), tint: .red) { model.delete(forward) }
                Toggle("", isOn: Binding(get: { running }, set: { _ in model.toggleTunnel(forward) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(Theme.accent)
            }
        }
        .animation(.zterm, value: state)
    }
}

struct StatusPill: View {
    let state: TunnelManager.State?
    @State private var pulse = false

    var body: some View {
        let (text, color): (String, Color) = switch state {
        case .none: (L("Mati"), .gray)
        case .starting: (L("Menghubungkan"), .yellow)
        case .running: (L("Aktif"), Color(hex: "#4ADE80"))
        case .failed: (L("Gagal"), .orange)
        }
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
                .scaleEffect(state == .running && pulse ? 1.35 : 1)
                .animation(.easeInOut(duration: 0.9).repeatForever(), value: pulse)
            Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(color.opacity(0.12), in: Capsule())
        .onAppear { pulse = true }
    }
}

struct ForwardEditor: View {
    @Environment(AppModel.self) private var model
    let original: PortForward
    @State private var f: PortForward

    init(original: PortForward) {
        self.original = original
        _f = State(initialValue: original)
    }

    private var valid: Bool {
        !f.hostId.isEmpty && f.bindPort > 0 && (f.kind == .dynamic || (!f.destHost.isEmpty && f.destPort > 0))
    }

    var body: some View {
        FormSheet(title: original.id.isEmpty ? L("Aturan Baru") : L("Edit Aturan"), canSave: valid, onSave: { model.save(f) }) {
            TextField(L("Nama (mis. Postgres produksi)"), text: $f.label).ztermField()
            Picker(L("Lewat host"), selection: $f.hostId) {
                ForEach(model.hosts) { h in Text(h.title).tag(h.id) }
            }
            Picker("", selection: $f.kind.animation(.zterm)) {
                Text(L("Local (-L)")).tag(ForwardKind.local)
                Text(L("Remote (-R)")).tag(ForwardKind.remote)
                Text(L("SOCKS (-D)")).tag(ForwardKind.dynamic)
            }
            .pickerStyle(.segmented).labelsHidden()
            Text(f.kind.explanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                TextField(f.kind == .remote ? L("Alamat di server") : L("Alamat lokal"), text: $f.bindAddress).ztermField()
                TextField(L("Port"), value: $f.bindPort, format: .number.grouping(.never)).ztermField().frame(width: 90)
            }
            if f.kind != .dynamic {
                Image(systemName: "arrow.down").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                HStack(spacing: 8) {
                    TextField(L("Host tujuan"), text: $f.destHost).ztermField()
                    TextField(L("Port"), value: $f.destPort, format: .number.grouping(.never)).ztermField().frame(width: 90)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

extension PortForward {
    static func blank(hostId: String) -> PortForward {
        PortForward(id: "", label: "", hostId: hostId, kind: .local, bindAddress: "127.0.0.1", bindPort: 8080,
                    destHost: "localhost", destPort: 80, updatedAt: 0, deleted: false)
    }

    func summary(via host: String, hideRemote: Bool) -> String {
        let dest = hideRemote && kind == .local && destHost != "localhost" && destHost != "127.0.0.1" ? "••••" : destHost
        switch kind {
        case .local: return L("{}:{} → {}:{}  via {}", bindAddress, bindPort, dest, destPort, host)
        case .remote: return "\(host) \(bindAddress):\(bindPort) → \(dest):\(destPort)"
        case .dynamic: return L("SOCKS {}:{}  via {}", bindAddress, bindPort, host)
        }
    }
}

extension ForwardKind {
    var short: String { switch self { case .local: "LOCAL"; case .remote: "REMOTE"; case .dynamic: "SOCKS" } }
    var icon: String { switch self { case .local: "arrow.right.circle"; case .remote: "arrow.left.circle"; case .dynamic: "globe" } }
    var explanation: String {
        switch self {
        case .local: L("Port di Mac ini diteruskan ke tujuan yang bisa dijangkau server. Contoh: 127.0.0.1:5433 → localhost:5432 (database di server).")
        case .remote: L("Port di server diteruskan ke tujuan di sisi Mac ini. Contoh: membuka web lokal ke server.")
        case .dynamic: L("Proxy SOCKS di Mac ini; semua lalu lintas keluar lewat server. Atur browser ke proxy SOCKS tersebut.")
        }
    }
}
