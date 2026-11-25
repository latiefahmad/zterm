import CryptoKit
import SwiftUI

/// Daftar server yang sudah dipercaya (`~/.ssh/known_hosts`), dipakai oleh koneksi SSH.
struct KnownHostsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(PrivacyKeys.hideAddresses) private var hideAddresses = true
    @State private var entries: [KnownHost] = []
    @State private var query = ""
    @State private var toDelete: KnownHost?

    private var filtered: [KnownHost] {
        let q = query.lowercased()
        return q.isEmpty ? entries : entries.filter { $0.hosts.lowercased().contains(q) || $0.keyType.lowercased().contains(q) }
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
                                    IconButton(symbol: "trash", help: L("Hapus dari known hosts"), tint: .red) { toDelete = e }
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
        .confirmationDialog(L("Hapus fingerprint ini?"), isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }),
                            presenting: toDelete) { e in
            Button(L("Hapus"), role: .destructive) { delete(e) }
        } message: { _ in
            Text(L("Saat connect berikutnya, fingerprint server akan dicatat ulang. Hapus hanya jika kamu yakin server memang berganti kunci."))
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
