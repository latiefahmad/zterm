import SwiftUI

/// Foto profil Google, atau inisial di lingkaran aksen.
struct Avatar: View {
    let name: String?
    let email: String?
    let picture: URL?
    var size: CGFloat = 28

    private var initial: String {
        let src = name ?? email ?? "?"
        return String(src.prefix(1)).uppercased()
    }

    var body: some View {
        ZStack {
            Circle().fill(Theme.accent)
            if let picture {
                AsyncImage(url: picture) { phase in
                    if let img = phase.image { img.resizable().scaledToFill() }
                    else { Text(initial).font(.system(size: size * 0.42, weight: .bold, design: .rounded)).foregroundStyle(.black.opacity(0.72)) }
                }
            } else if email != nil {
                Text(initial).font(.system(size: size * 0.42, weight: .bold, design: .rounded)).foregroundStyle(.black.opacity(0.72))
            } else {
                PhosphorIcon(name: "user", size: size * 0.44, tint: .black.opacity(0.7))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

struct AccountView: View {
    @Environment(AppModel.self) private var model
    @State private var confirm: SignOutKind?
    @State private var connecting = false
    @State private var biometric = BiometricUnlock.hasStoredKey

    enum SignOutKind: Identifiable { case keep, wipe; var id: Int { hashValue } }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                PageHeader(title: L("Akun"), subtitle: L("Sinkronisasi, keamanan, dan data vault di perangkat ini"))
                profileCard.staggerIn(0, base: 0.02)
                HStack(alignment: .top, spacing: 18) {
                    VStack(spacing: 18) {
                        syncCard.staggerIn(1, base: 0.02)
                        securityCard.staggerIn(3, base: 0.02)
                    }
                    VStack(spacing: 18) {
                        dataCard.staggerIn(2, base: 0.02)
                        signOutCard.staggerIn(4, base: 0.02)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 920)
            .frame(maxWidth: .infinity)
        }
        .confirmationDialog(confirm == .wipe ? L("Keluar & hapus data dari Mac ini?") : L("Keluar dari akun?"),
                            isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            presenting: confirm) { kind in
            Button(kind == .wipe ? L("Keluar & hapus") : L("Keluar"), role: .destructive) {
                model.signOut(deleteLocal: kind == .wipe)
            }
        } message: { kind in
            Text(kind == .wipe
                 ? L("Vault, kunci Touch ID, dan login Google dihapus dari Mac ini. Salinan terenkripsi di Google Drive tetap ada — login lagi dan masukkan master password untuk memulihkannya. Pastikan status sync sudah \"Tersinkron\".")
                 : L("Login Google diputus dan vault dikunci. Data tetap terenkripsi di Mac ini; buka lagi dengan master password."))
        }
    }

    // MARK: Kartu profil

    private var profileCard: some View {
        HStack(spacing: 18) {
            Avatar(name: model.profileName, email: model.accountEmail, picture: model.profilePicture, size: 76)
                .overlay(Circle().strokeBorder(Theme.cardStroke, lineWidth: 1))

            VStack(alignment: .leading, spacing: 5) {
                Text(model.profileName ?? (model.accountEmail == nil ? L("Tanpa akun") : model.accountEmail!.components(separatedBy: "@")[0]))
                    .font(.system(size: 22, weight: .semibold))
                    .lineLimit(1)
                if let email = model.accountEmail {
                    PhosphorLabel(text: email, icon: "envelope-simple", size: 12, tint: .secondary)
                        .font(.system(size: 12.5)).textSelection(.enabled)
                    HStack(spacing: 6) {
                        Badge(text: "GOOGLE", color: Theme.accent2)
                        Badge(text: L("SYNC DRIVE"), color: Theme.accent)
                    }
                } else {
                    Text(L("Data hanya tersimpan di Mac ini. Hubungkan Google untuk sync antar perangkat."))
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.accountEmail == nil || model.sync == .needsLogin {
                Button {
                    Task { await connect() }
                } label: {
                    HStack(spacing: 8) {
                        if connecting { ProgressView().controlSize(.small).tint(.black) } else { GoogleMark().frame(width: 16, height: 16) }
                        Text(model.accountEmail == nil ? L("Masuk dengan Google") : L("Masuk ulang Google"))
                    }
                }
                .buttonStyle(PrimaryButtonStyle(size: .large))
                .disabled(connecting)
            }
        }
        .padding(20)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.cardStroke))
    }

    // MARK: Sync

    private var syncCard: some View {
        AccountCard(title: L("Sinkronisasi"), icon: "cloud-arrow-up", tint: Theme.accent) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Theme.accent.opacity(0.13))
                    SyncIcon(state: model.sync, size: 15, tint: Theme.accent)
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(syncTitle).font(.system(size: 14, weight: .semibold))
                    Text(syncSubtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
            }
            if model.accountEmail != nil {
                Button { model.syncNow() } label: {
                    PhosphorLabel(text: L("Sinkronkan sekarang"), icon: "arrows-clockwise", size: 12)
                }
                    .buttonStyle(SecondaryButtonStyle(wide: true))
                    .disabled(model.sync == .syncing)
            }
            InfoLine(label: L("Lokasi"), value: L("Google Drive · folder app tersembunyi"))
            InfoLine(label: L("Enkripsi"), value: "XChaCha20-Poly1305 (end-to-end)")
        }
    }

    private var syncTitle: String {
        switch model.sync {
        case .off: L("Sync mati")
        case .idle: L("Siap sync")
        case .syncing: L("Menyinkronkan…")
        case .synced: L("Tersinkron")
        case .failed: L("Sync gagal")
        case .needsLogin: L("Perlu login ulang")
        }
    }

    private var syncSubtitle: String {
        switch model.sync {
        case .off: L("Hubungkan akun Google untuk menyimpan vault di Drive.")
        case .synced(let d): L("Terakhir {}", d.formatted(.relative(presentation: .named)))
        case .failed(let m): m
        case .needsLogin: L("Token Google sudah tidak berlaku.")
        default: L("Perubahan disinkronkan otomatis.")
        }
    }

    // MARK: Data

    private var dataCard: some View {
        AccountCard(title: L("Data di vault"), icon: "package", tint: Theme.accent2) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                Stat(value: model.hosts.count, label: L("Host"), icon: "hard-drives", tint: Section.hosts.tint)
                Stat(value: model.keys.count, label: L("SSH key"), icon: "key", tint: Section.keychain.tint)
                Stat(value: model.snippets.count, label: L("Snippet"), icon: "brackets-curly", tint: Section.snippets.tint)
                Stat(value: model.forwards.count, label: L("Forwarding"), icon: "arrows-left-right", tint: Section.forwarding.tint)
            }
            InfoLine(label: L("Riwayat sesi"), value: L("{} catatan", model.logs.count))
        }
    }

    // MARK: Keamanan

    private var securityCard: some View {
        AccountCard(title: L("Keamanan"), icon: "shield-check", tint: Theme.orange) {
            Toggle(isOn: Binding(get: { biometric }, set: { on in
                if on { model.enableBiometric() } else { BiometricUnlock.forget() }
                biometric = BiometricUnlock.hasStoredKey
            })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Buka dengan Touch ID")).font(.system(size: 13, weight: .medium))
                    Text(L("Kunci vault disimpan di Keychain Mac ini")).font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .tint(Theme.accent)
            Button { model.lock() } label: {
                PhosphorLabel(text: L("Kunci vault sekarang  ⇧⌘L"), icon: "lock-simple", size: 12)
            }
                .buttonStyle(SecondaryButtonStyle(wide: true))
        }
    }

    // MARK: Keluar

    private var signOutCard: some View {
        AccountCard(title: L("Keluar"), icon: "sign-out", tint: Theme.red) {
            Text(L("Keluar memutus login Google dan mengunci vault. Pilih hapus jika Mac ini bukan milikmu."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button { confirm = .keep } label: {
                PhosphorLabel(text: L("Keluar"), icon: "sign-out", size: 12)
            }
                .buttonStyle(SecondaryButtonStyle(wide: true))
            Button { confirm = .wipe } label: {
                PhosphorLabel(text: L("Keluar & hapus data dari Mac ini"), icon: "trash", size: 12,
                              tint: Theme.red)
            }
                .buttonStyle(SecondaryButtonStyle(wide: true))
        }
    }

    private func connect() async {
        connecting = true
        defer { connecting = false }
        do { _ = try await model.signInGoogle() }
        catch GoogleAuth.AuthError.cancelled {}
        catch { model.flash(Lmsg(error.localizedDescription)) }
    }
}

private struct AccountCard<Content: View>: View {
    let title: String
    let icon: String
    let tint: Color
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tint.opacity(0.13))
                    PhosphorIcon(name: icon, size: 12, tint: tint)
                }
                .frame(width: 23, height: 23)
                Text(title).font(.system(size: 14, weight: .semibold))
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: 16)
    }
}

private struct Stat: View {
    let value: Int
    let label: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            PhosphorIcon(name: icon, size: 16, tint: tint).frame(width: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(value)").font(.system(size: 20, weight: .bold, design: .rounded)).contentTransition(.numericText())
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Theme.field, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct InfoLine: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.system(size: 12))
    }
}
