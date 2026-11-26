import CryptoKit
import SwiftUI

/// Daftar server yang sudah dipercaya (`~/.ssh/known_hosts`), dipakai oleh koneksi SSH.
struct KnownHostsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(PrivacyKeys.hideAddresses) private var hideAddresses = true
    @State private var entries: [KnownHost] = []
    @State private var query = ""
    @State private var deleteMode: DeleteMode?

    private enum DeleteMode: Identifiable {
        case single(KnownHost)
        case all(KnownHost)

        var id: String {
            switch self {
            case .single(let e): "single-\(e.id)"
            case .all(let e): "all-\(e.id)"
            }
        }
    }

    private var filtered: [KnownHost] {
        let q = query.lowercased()
        return q.isEmpty ? entries : entries.filter { $0.hosts.lowercased().contains(q) || $0.keyType.lowercased().contains(q) }
    }

    private var deleteTitle: String {
        guard let mode = deleteMode else { return L("Hapus known host?") }
        switch mode {
        case .single:
            return L("Hapus fingerprint ini?")
        case .all(let e):
            if let hp = e.firstHost { return L("Hapus semua key untuk {}?", hp.host) }
            return L("Hapus semua key untuk host ini")
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: "Known Hosts", subtitle: L("Fingerprint server yang sudah dipercaya — ~/.ssh/known_hosts")) {
                    SearchField(text: $query, prompt: L("Cari host…"))
                    Button { reload() } label: { PhosphorIcon(name: "arrows-clockwise", size: 14) }
                        .buttonStyle(SecondaryButtonStyle())
                        .help(L("Muat ulang"))
                }
                if entries.isEmpty {
                    EmptyState(ph: "fingerprint", title: L("Belum ada known host"),
                               text: L("Fingerprint server otomatis tercatat di sini saat pertama kali kamu connect."))
                } else {
                    VStack(spacing: 6) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { i, e in
                            HoverCard(padding: 12) {
                                HStack(spacing: 12) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.accent.opacity(0.12))
                                        RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.accent.opacity(0.22))
                                        PhosphorIcon(name: "fingerprint", size: 17, tint: Theme.accent)
                                    }
                                    .frame(width: 34, height: 34)
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 8) {
                                            Text(e.displayHosts(hidden: hideAddresses)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                            Badge(text: e.shortType, color: Theme.accent2)
                                        }
                                        Text(e.fingerprint)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1).truncationMode(.middle)
                                            .textSelection(.enabled)
                                    }
                                    Spacer()
                                    HStack(spacing: 2) {
                                        if e.firstHost != nil {
                                            Menu {
                                                Button(L("Hapus semua key untuk host ini"), role: .destructive) {
                                                    deleteMode = .all(e)
                                                }
                                            } label: {
                                                PhosphorIcon(sf: "ellipsis", size: 13, tint: .secondary)
                                                    .frame(width: 26, height: 26)
                                                    .contentShape(Rectangle())
                                            }
                                            .menuStyle(.borderlessButton)
                                            .menuIndicator(.hidden)
                                            .fixedSize()
                                            .help(L("Lainnya"))
                                        }
                                        IconButton(symbol: "trash", help: L("Hapus dari known hosts"), tint: .red) {
                                            deleteMode = .single(e)
                                        }
                                    }
                                }
                            }
                            .staggerIn(i, base: 0)
                        }
                    }
                }
            }
            .padding(28)
        }
        .onAppear(perform: reload)
        .confirmationDialog(deleteTitle,
                            isPresented: Binding(get: { deleteMode != nil }, set: { if !$0 { deleteMode = nil } }),
                            presenting: deleteMode) { mode in
            switch mode {
            case .single(let e):
                Button(L("Hapus fingerprint"), role: .destructive) { delete(e) }
            case .all(let e):
                Button(L("Hapus semua key"), role: .destructive) { deleteAll(e) }
            }
        } message: { mode in
            switch mode {
            case .single:
                Text(L("Saat connect berikutnya, fingerprint server akan dicatat ulang. Hapus hanya jika kamu yakin server memang berganti kunci."))
            case .all(let e):
                Text(L("Semua key untuk {} di known_hosts akan dihapus, lalu server dipercaya lagi saat connect berikutnya. Hapus hanya jika kamu yakin server memang berganti kunci.", e.firstHost?.host ?? e.hosts))
            }
        }
    }

    private func reload() {
        withAnimation(.zterm) { entries = KnownHostsFile.read() }
    }

    private func delete(_ e: KnownHost) {
        do {
            try KnownHostsFile.remove(lineAt: e.line)
            model.flash(L("Fingerprint dihapus"))
        } catch {
            model.flash(Lmsg(error.localizedDescription))
        }
        reload()
    }

    private func deleteAll(_ e: KnownHost) {
        guard let hp = e.firstHost else { return }
        do {
            let removed = try forgetKnownHost(host: hp.host, port: hp.port)
            model.flash(L("{} key dihapus", Int(removed)))
        } catch {
            model.flash(Lmsg(error.localizedDescription))
        }
        reload()
    }
}

struct KnownHost: Identifiable {
    let id = UUID()
    let line: Int
    let hosts: String
    let keyType: String
    let fingerprint: String

    var isHashed: Bool { hosts.hasPrefix("|1|") }
    var shortType: String {
        keyType.replacingOccurrences(of: "ssh-", with: "").replacingOccurrences(of: "ecdsa-sha2-", with: "").uppercased()
    }

    func displayHosts(hidden: Bool) -> String {
        if isHashed { return L("Host ter-hash") }
        return hidden ? hosts.split(separator: ",").map { _ in "••••••" }.joined(separator: ", ") : hosts
    }

    /// Host & port pertama pada pola known_hosts (nil untuk entri ter-hash).
    var firstHost: (host: String, port: UInt16)? {
        guard !isHashed else { return nil }
        for raw in hosts.split(separator: ",") {
            let part = raw.trimmingCharacters(in: .whitespaces)
            guard !part.isEmpty, !part.hasPrefix("!"), !part.contains("*"), !part.contains("?") else { continue }
            if part.hasPrefix("["), let close = part.firstIndex(of: "]") {
                let host = String(part[part.index(after: part.startIndex)..<close])
                let rest = part[part.index(after: close)...]
                let port = rest.hasPrefix(":") ? UInt16(rest.dropFirst()) ?? 22 : 22
                return (host, port)
            }
            return (part, 22)
        }
        return nil
    }
}

enum KnownHostsFile {
    static var url: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/known_hosts") }

    static func read() -> [KnownHost] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.components(separatedBy: "\n").enumerated().compactMap { i, raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            var parts = line.split(separator: " ").map(String.init)
            if parts.first?.hasPrefix("@") == true { parts.removeFirst() } // @cert-authority / @revoked
            guard parts.count >= 3, let keyData = Data(base64Encoded: parts[2]) else { return nil }
            let digest = Data(SHA256.hash(data: keyData)).base64EncodedString().replacingOccurrences(of: "=", with: "")
            return KnownHost(line: i, hosts: parts[0], keyType: parts[1], fingerprint: "SHA256:\(digest)")
        }
    }

    /// Hapus satu baris. Salinan lama disimpan sebagai known_hosts.old (seperti `ssh-keygen -R`).
    static func remove(lineAt index: Int) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        var lines = text.components(separatedBy: "\n")
        guard index < lines.count else { return }
        let backup = url.deletingLastPathComponent().appendingPathComponent("known_hosts.old")
        try? FileManager.default.removeItem(at: backup)
        try FileManager.default.copyItem(at: url, to: backup)
        lines.remove(at: index)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
