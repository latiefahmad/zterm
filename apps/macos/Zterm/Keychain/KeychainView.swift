import AppKit
import SwiftUI

struct KeychainView: View {
    @Environment(AppModel.self) private var model
    @State private var sheet: Sheet?

    enum Sheet: Identifiable {
        case generate, importKey
        var id: Int { hashValue }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: "Keychain", subtitle: L("SSH key tersimpan terenkripsi di vault. Pakai di host lewat Credentials → SSH Key.")) {
                    Button { sheet = .importKey } label: {
                        PhosphorLabel(text: L("Import"), icon: "download-simple", size: 12)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    Button { sheet = .generate } label: {
                        PhosphorLabel(text: L("Generate Key"), icon: "sparkle", size: 12,
                                      tint: Color(hex: "#06231E"))
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }

                if model.keys.isEmpty {
                    EmptyState(ph: "key", title: L("Belum ada SSH key"),
                               text: L("Generate key Ed25519 baru atau import dari ~/.ssh."))
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12)], spacing: 12) {
                        ForEach(Array(model.keys.enumerated()), id: \.element.id) { i, k in
                            KeyCard(key: k).staggerIn(i, base: 0)
                        }
                    }
                }
            }
            .padding(28)
        }
        .sheet(item: $sheet) { s in
            switch s {
            case .generate: GenerateKeySheet()
            case .importKey: ImportKeySheet()
            }
        }
    }
}

struct KeyCard: View {
    @Environment(AppModel.self) private var model
    let key: SshKey
    @State private var hover = false
    @State private var copied = false
    @State private var renaming = false
    @State private var newLabel = ""
    @State private var confirmDelete = false

    private var usedBy: Int { model.hosts.filter { $0.keyId == key.id }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.accent.opacity(0.14))
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Theme.accent.opacity(0.26))
                    PhosphorIcon(name: "key", size: 17, tint: Theme.accent)
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 3) {
                    if renaming {
                        TextField(L("Label"), text: $newLabel, onCommit: {
                            model.renameKey(key, to: newLabel)
                            renaming = false
                        })
                        .textFieldStyle(.roundedBorder)
                    } else {
                        Text(key.label).font(.system(size: 14, weight: .semibold))
                    }
                    HStack(spacing: 6) {
                        Text(key.keyType.replacingOccurrences(of: "ssh-", with: "").uppercased())
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.accent.opacity(0.15), in: Capsule())
                            .foregroundStyle(Theme.accent)
                        if key.passphrase != nil {
                            PhosphorIcon(name: "lock-simple", size: 11, tint: .secondary)
                        }
                        Text(usedBy == 0 ? L("Belum dipakai") : L("Dipakai {} host", usedBy))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            Text(key.fingerprint)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(key.publicKey, forType: .string)
                    withAnimation(.ztermSnappy) { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { withAnimation(.zterm) { copied = false } }
                } label: {
                    PhosphorLabel(text: copied ? L("Tersalin!") : L("Salin public key"),
                                  icon: copied ? "check" : "copy", size: 12,
                                  tint: copied ? Theme.accent : .primary)
                }
                .buttonStyle(SecondaryButtonStyle())
                Spacer()
                IconButton(symbol: "pencil", help: L("Ganti nama")) { newLabel = key.label; renaming = true }
                IconButton(symbol: "trash", help: L("Hapus"), tint: .red) { confirmDelete = true }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hover ? Theme.cardHover : Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(hover ? Theme.ink.opacity(0.16) : Theme.cardStroke))
        .offset(y: hover ? -1 : 0)
        .shadow(color: Theme.shadow.opacity(hover ? 1 : 0), radius: 12, y: 6)
        .animation(.ztermHover, value: hover)
        .onHover { hover = $0 }
        .confirmationDialog(L("Hapus key “{}”?", key.label), isPresented: $confirmDelete) {
            Button(L("Hapus"), role: .destructive) { model.deleteKey(key) }
        } message: {
            Text(usedBy > 0 ? L("{} host yang memakai key ini akan kehilangan key-nya.", usedBy) : L("Tindakan ini tidak bisa dibatalkan."))
        }
    }
}

struct GenerateKeySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var result: SshKey?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let k = result {
                PhosphorLabel(text: L("Key berhasil dibuat"), icon: "seal-check", size: 16,
                              tint: Theme.accent)
                    .font(.title3.bold())
                Text(LocalizedStringKey(L("Tambahkan public key ini ke `~/.ssh/authorized_keys` di server.")))
                    .font(.callout).foregroundStyle(.secondary)
                Text(k.publicKey)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.field, in: RoundedRectangle(cornerRadius: 8))
                HStack {
                    Spacer()
                    Button(L("Salin & tutup")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(k.publicKey, forType: .string)
                        model.flash(L("Public key disalin"))
                        dismiss()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
                .transition(.opacity)
            } else {
                Text(L("Generate SSH key")).font(.title3.bold())
                Text(L("Membuat pasangan key Ed25519 baru — cepat, aman, dan didukung semua server modern."))
                    .font(.callout).foregroundStyle(.secondary)
                TextField(L("Label (mis. MacBook kantor)"), text: $label).ztermField()
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                HStack {
                    Spacer()
                    Button(L("Batal")) { dismiss() }.buttonStyle(SecondaryButtonStyle())
                    Button(L("Generate")) {
                        do { withAnimation(.zterm) { result = try? model.generateKey(label: label) } }
                        if result == nil { error = L("Gagal membuat key") }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.return)
                }
            }
        }
        .padding(24)
        .frame(width: 460)
        .animation(.zterm, value: result?.id)
    }
}

struct ImportKeySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var pem = ""
    @State private var passphrase = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Import SSH key")).font(.title3.bold())
            Text(LocalizedStringKey(L("Pilih file private key (mis. `~/.ssh/id_ed25519`) atau tempel isinya. Format OpenSSH.")))
                .font(.callout).foregroundStyle(.secondary)
            TextField(L("Label"), text: $label).ztermField()
            ZStack(alignment: .topLeading) {
                TextEditor(text: $pem)
                    .font(.system(size: 11, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                if pem.isEmpty {
                    Text(L("-----BEGIN OPENSSH PRIVATE KEY-----")).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary).padding(11).allowsHitTesting(false)
                }
            }
            .frame(height: 140)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.ink.opacity(0.1)))
            SecureField(L("Passphrase (jika ada)"), text: $passphrase).ztermField()
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).transition(.opacity)
            }
            HStack {
                Button { pickFile() } label: {
                    PhosphorLabel(text: L("Pilih file…"), icon: "folder", size: 12)
                }
                    .buttonStyle(SecondaryButtonStyle())
                Spacer()
                Button(L("Batal")) { dismiss() }.buttonStyle(SecondaryButtonStyle())
                Button(L("Import")) {
                    do {
                        try model.importKey(label: label, privateKey: pem, passphrase: passphrase.isEmpty ? nil : passphrase)
                        model.flash(L("Key “{}” diimport", label.isEmpty ? "SSH key" : label))
                        dismiss()
                    } catch {
                        withAnimation(.zterm) { self.error = Lmsg(error.localizedDescription) }
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(pem.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.allowsMultipleSelection = false
        panel.message = L("Pilih private key (bukan file .pub)")
        if panel.runModal() == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) {
            pem = text
            if label.isEmpty { label = url.lastPathComponent }
        }
    }
}
