import AppKit
import SwiftUI

enum Links {
    static let website = URL(string: "https://latief.id/zterm/")!
    static let github = URL(string: "https://github.com/latiefahmad/zterm")!
    static let issues = URL(string: "https://github.com/latiefahmad/zterm/issues")!
    static let releases = URL(string: "https://github.com/latiefahmad/zterm/releases")!
    static let privacy = URL(string: "https://latief.id/zterm/privacy.html")!
    static let terms = URL(string: "https://latief.id/zterm/terms.html")!
}

// MARK: - Tentang

struct AboutView: View {
    @State private var appear = false

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return L("Versi {} ({})", v, b)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 14) {
                    ZtermLogo(size: 96)
                        .scaleEffect(appear ? 1 : 0.7)
                        .rotationEffect(.degrees(appear ? 0 : -12))
                        .opacity(appear ? 1 : 0)
                    Text("Zterm").font(.system(size: 34, weight: .heavy, design: .rounded))
                        .staggerIn(1, base: 0.1)
                    TypewriterText(L("Semua servermu, satu terminal."), delay: 0.4)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(height: 20)
                    HStack(spacing: 8) {
                        Badge(text: version.uppercased())
                        Badge(text: L("CORE {}", coreVersion()), color: Theme.accent2)
                        Badge(text: "MIT", color: Theme.accent3)
                    }
                    .staggerIn(2, base: 0.1)
                }
                .padding(.top, 24)

                Text(L("SSH client native untuk macOS — gratis, tanpa iklan, tanpa server. Host, SSH key, dan snippet dienkripsi di perangkatmu dan tersinkron lewat Google Drive milikmu sendiri."))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 520)
                    .staggerIn(3, base: 0.1)

                HStack(spacing: 10) {
                    LinkButton(title: L("Website"), icon: "globe", url: Links.website)
                    LinkButton(title: L("GitHub"), icon: "chevron.left.forwardslash.chevron.right", url: Links.github)
                    LinkButton(title: L("Catatan rilis"), icon: "sparkles", url: Links.releases)
                    LinkButton(title: L("Laporkan bug"), icon: "ladybug", url: Links.issues)
                }
                .staggerIn(4, base: 0.1)

                UpdateStatus()
                    .staggerIn(5, base: 0.1)

                VStack(alignment: .leading, spacing: 0) {
                    InfoRow(label: L("Dibuat oleh"), value: "Latief Ahmad")
                    InfoRow(label: L("Antarmuka"), value: "SwiftUI (native macOS)")
                    InfoRow(label: L("Inti"), value: "zterm-core · Rust (vault, sync, keychain)")
                    InfoRow(label: L("Enkripsi"), value: "Argon2id + XChaCha20-Poly1305")
                    InfoRow(label: L("Terminal"), value: "SwiftTerm · OpenSSH")
                    InfoRow(label: L("Sync"), value: L("Google Drive (appDataFolder), zero-knowledge"), last: true)
                }
                .glassCard(padding: 4)
                .frame(maxWidth: 560)
                .staggerIn(5, base: 0.1)

                LanguagePicker()
                    .staggerIn(5, base: 0.1)

                HStack(spacing: 16) {
                    Link(L("Kebijakan Privasi"), destination: Links.privacy)
                    Link(L("Syarat Layanan"), destination: Links.terms)
                }
                .font(.callout)
                .foregroundStyle(.secondary)

                Text(L("© 2026 Latief Ahmad · Lisensi MIT"))
                    .font(.caption).foregroundStyle(.tertiary)
                    .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
        }
        .onAppear { withAnimation(.spring(response: 0.6, dampingFraction: 0.65)) { appear = true } }
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var last = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                Text(value).multilineTextAlignment(.trailing)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 14).padding(.vertical, 11)
            if !last { Divider().padding(.horizontal, 14) }
        }
    }
}

struct LinkButton: View {
    let title: String
    let icon: String
    let url: URL
    var body: some View {
        Button { NSWorkspace.shared.open(url) } label: { PhosphorLabel(sf: icon, text: title, size: 12) }
            .buttonStyle(SecondaryButtonStyle())
    }
}

/// Status versi di halaman Tentang + tombol cek pembaruan.
struct UpdateStatus: View {
    @Environment(AppModel.self) private var model
    @State private var checking = false

    var body: some View {
        HStack(spacing: 10) {
            PhosphorIcon(sf: model.update == nil ? "checkmark.seal.fill" : "arrow.down.circle.fill", size: 15)
                .foregroundStyle(model.update == nil ? Theme.accent : .orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.update.map { L("Versi {} tersedia", $0.version) } ?? L("Kamu memakai versi terbaru ({})", AppVersion.current))
                    .font(.callout)
                if model.updateBusy {
                    ProgressView(value: min(max(model.updateProgress, 0), 1))
                        .progressViewStyle(.linear)
                        .tint(Theme.accent)
                        .frame(maxWidth: 220)
                    Text(model.updateStatus ?? L("Mengunduh pembaruan…"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                Task {
                    checking = true
                    await model.checkForUpdates(manual: true)
                    checking = false
                }
            } label: {
                if checking { ProgressView().controlSize(.small) } else { Text(L("Periksa")) }
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(model.updateBusy)
            if let u = model.update, !model.updateBusy {
                Button(L("Update sekarang")) { confirmAndInstallUpdate(model, version: u.version) }
                    .buttonStyle(PrimaryButtonStyle())
                Button(L("Catatan rilis")) { NSWorkspace.shared.open(u.page) }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .glassCard(padding: 0)
    }
}
