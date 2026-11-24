import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SftpView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let sftp = model.sftp
        VStack(spacing: 0) {
            SftpHeader()
            Divider()
            switch sftp.status {
            case .idle:
                SftpPicker().transition(.opacity)
            case .connecting:
                SftpConnecting(host: sftp.host).transition(.opacity)
            case .failed(let msg):
                SftpFailed(message: msg).transition(.opacity)
            case .connected:
                HSplitView {
                    LocalPane().frame(minWidth: 300)
                    RemotePane().frame(minWidth: 300)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                if !sftp.watched.isEmpty {
                    WatchedFilesBar().transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if !sftp.transfers.isEmpty {
                    TransferList().transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .onAppear { SftpDragContext.model = model.sftp }
        .animation(.zterm, value: sftp.status)
        .animation(.zterm, value: sftp.transfers.isEmpty)
        .animation(.zterm, value: sftp.watched.isEmpty)
        .sheet(item: Binding(get: { sftp.editor }, set: { sftp.editor = $0 })) { doc in
            RemoteEditorView(doc: doc)
        }
        .overlay(alignment: .bottom) {
            if let n = sftp.notice, sftp.error == nil {
                Label(n, systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(.ultraThickMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color(hex: "#4ADE80").opacity(0.5)))
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let e = sftp.error {
                Label(e, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(.ultraThickMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.orange.opacity(0.5)))
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
}

// MARK: - Header & pemilih host

struct SftpHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let sftp = model.sftp
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("SFTP").font(.system(size: 22, weight: .bold, design: .rounded))
                Text(sftp.host.map { L("Tersambung ke {}", $0.title) } ?? L("Transfer file Mac ↔ server"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if sftp.status == .connected {
                Toggle(L("File tersembunyi"), isOn: Binding(get: { sftp.showHidden }, set: { v in
                    sftp.showHidden = v
                    sftp.reloadLocal()
                    Task { await sftp.refreshRemote() }
                }))
                .toggleStyle(.checkbox)
                .font(.callout)
            }
            Menu {
                ForEach(model.hosts) { h in
                    Button(h.title) { Task { await model.openSftp(h) } }
                }
            } label: {
                Label(sftp.host == nil ? L("Pilih host") : L("Ganti host"), systemImage: "server.rack")
            }
            .menuStyle(.button)
            .fixedSize()
            .disabled(model.hosts.isEmpty)
            if sftp.status == .connected {
                Button { Task { await sftp.disconnect() } } label: { Label(L("Putuskan"), systemImage: "xmark.circle") }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
    }
}

struct SftpPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                EmptyState(icon: "folder.badge.gearshape", title: L("Pilih server"),
                           text: L("Buka file di server lewat SFTP — memakai login host yang sudah tersimpan."))
                    .padding(.top, -30)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    ForEach(Array(model.hosts.enumerated()), id: \.element.id) { i, h in
                        Button { Task { await model.openSftp(h) } } label: {
                            HStack(spacing: 10) {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Color(hex: h.color).gradient)
                                    .overlay(Image(systemName: "folder.fill").font(.system(size: 14, weight: .bold)).foregroundStyle(.black.opacity(0.7)))
                                    .frame(width: 34, height: 34)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(h.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                    Text(h.displayAddress(hidden: true)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "arrow.right.circle.fill").foregroundStyle(Color(hex: h.color))
                            }
                            .padding(12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.cardStroke))
                        .staggerIn(i, base: 0.05)
                    }
                }
            }
            .padding(28)
        }
    }
}

struct SftpConnecting: View {
    let host: Host?
    var body: some View {
        if let host { ConnectingOverlay(host: host).frame(maxWidth: .infinity, maxHeight: .infinity) }
    }
}

struct SftpFailed: View {
    @Environment(AppModel.self) private var model
    let message: String
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "bolt.horizontal.circle").font(.system(size: 40)).foregroundStyle(.orange)
            Text(L("Tidak bisa membuka SFTP")).font(.title3.bold())
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
            HStack {
                Button(L("Coba lagi")) { if let h = model.sftp.host { Task { await model.openSftp(h) } } }
                    .buttonStyle(PrimaryButtonStyle())
                Button(L("Pilih host lain")) { Task { await model.sftp.disconnect() } }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Panel file

/// Path yang bisa diklik per bagian: / › var › www.
struct Breadcrumb: View {
    let path: String
    var onTap: (String) -> Void

    var body: some View {
        let parts = path.split(separator: "/").map(String.init)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                Button("/") { onTap("/") }.buttonStyle(.plain)
                ForEach(parts.indices, id: \.self) { i in
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                    Button(parts[i]) { onTap("/" + parts[...i].joined(separator: "/")) }
                        .buttonStyle(.plain)
                        .foregroundStyle(i == parts.count - 1 ? .primary : .secondary)
                }
            }
            .font(.system(size: 11, design: .monospaced))
        }
    }
}

// MARK: - Antrean transfer

struct TransferList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let sftp = model.sftp
        VStack(spacing: 0) {
            Divider()
            HStack {
                Text(L("Transfer")).font(.system(size: 12, weight: .semibold))
                let running = sftp.transfers.filter { $0.state == .running }.count
                if running > 0 { Badge(text: L("{} BERJALAN", running)) }
                Spacer()
                Button(L("Bersihkan selesai")) { sftp.clearFinished() }.buttonStyle(.borderless).font(.caption)
            }
            .padding(.horizontal, 14).padding(.top, 8)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(sftp.transfers) { t in
                        TransferRow(transfer: t) { sftp.cancel(t) }
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(10)
            }
            .frame(height: min(CGFloat(sftp.transfers.count) * 52 + 16, 170))
        }
        .background(Theme.panel)
    }
}

struct TransferRow: View {
    let transfer: Transfer
    var onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: transfer.kind == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(color)
                .symbolEffect(.pulse, isActive: transfer.state == .running)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(transfer.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Spacer()
                    Text(statusText).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }
                ProgressView(value: transfer.fraction)
                    .progressViewStyle(.linear)
                    .tint(color)
                    .animation(.easeOut(duration: 0.2), value: transfer.fraction)
            }
            if transfer.state == .running {
                IconButton(symbol: "xmark", help: L("Batalkan"), action: onCancel)
            } else {
                Image(systemName: icon).foregroundStyle(color).frame(width: 28)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 9))
    }

    private var color: Color {
        switch transfer.state {
        case .running: Theme.accent
        case .done: Color(hex: "#4ADE80")
        case .failed: .orange
        case .cancelled: .gray
        }
    }

    private var icon: String {
        switch transfer.state {
        case .done: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        default: "minus.circle"
        }
    }

    private var statusText: String {
        switch transfer.state {
        case .running:
            let speed = Double(transfer.done) / max(Date().timeIntervalSince(transfer.started), 0.1)
            return L("{} / {} · {}/s", transfer.done.byteString, transfer.total.byteString, UInt64(speed).byteString)
        case .done: return L("Selesai · {}", transfer.total.byteString)
        case .failed(let m): return m
        case .cancelled: return L("Dibatalkan")
        }
    }
}

// MARK: - Sheet kecil

struct TextPromptSheet: View {
    let title: String
    let initial: String
    let action: String
    var onSubmit: (String) -> Void
    @State private var text = ""

    var body: some View {
        FormSheet(title: title, saveTitle: action, canSave: !text.trimmingCharacters(in: .whitespaces).isEmpty,
                  onSave: { onSubmit(text.trimmingCharacters(in: .whitespaces)) }) {
            TextField(L("Nama"), text: $text).ztermField()
        }
        .onAppear { text = initial }
    }
}

struct ChmodSheet: View {
    let item: FileItem
    var onSave: (UInt32) -> Void
    @State private var mode: UInt32 = 0

    private let rows: [(String, UInt32)] = [(L("Pemilik"), 6), (L("Grup"), 3), (L("Lainnya"), 0)]
    private let cols: [(String, UInt32)] = [("Baca", 4), (L("Tulis"), 2), (L("Jalankan"), 1)]

    var body: some View {
        FormSheet(title: L("Izin “{}”", item.name), onSave: { onSave(mode) }) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                GridRow {
                    Text("")
                    ForEach(cols, id: \.0) { Text($0.0).font(.caption).foregroundStyle(.secondary) }
                }
                ForEach(rows, id: \.0) { row in
                    GridRow {
                        Text(row.0)
                        ForEach(cols, id: \.0) { col in
                            let bit = col.1 << row.1
                            Toggle("", isOn: Binding(get: { mode & bit != 0 }, set: { on in
                                withAnimation(.ztermSnappy) { mode = on ? mode | bit : mode & ~bit }
                            }))
                            .toggleStyle(.checkbox).labelsHidden()
                        }
                    }
                }
            }
            HStack {
                Text(String(mode, radix: 8).leftPad(3)).font(.system(size: 22, weight: .bold, design: .monospaced))
                    .contentTransition(.numericText())
                Text(permissionString(mode, isDir: item.isDir)).font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
        .onAppear { mode = item.permissions & 0o777 }
    }
}

private extension String {
    func leftPad(_ n: Int) -> String { count >= n ? self : String(repeating: "0", count: n - count) + self }
}
