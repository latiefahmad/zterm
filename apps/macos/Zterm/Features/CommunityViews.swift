import AppKit
import SwiftUI

enum Links {
    static let website = URL(string: "https://latief.id/zterm/")!
    static let github = URL(string: "https://github.com/latiefahmad/zterm")!
    static let issues = URL(string: "https://github.com/latiefahmad/zterm/issues")!
    static let releases = URL(string: "https://github.com/latiefahmad/zterm/releases")!
    static let privacy = URL(string: "https://latief.id/zterm/privacy.html")!
    static let terms = URL(string: "https://latief.id/zterm/terms.html")!
    static let donate = URL(string: "https://saweria.co/latiefahmad")!
}

// MARK: - Tentang

struct AboutView: View {
    @State private var appear = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                hero
                HStack(alignment: .top, spacing: 14) {
                    explorePanel
                    infoPanel
                }
                footer
            }
            .frame(maxWidth: 860)
            .padding(.horizontal, 28)
            .padding(.top, 16)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity)
        }
        .background(AnimatedBackground())
        .onAppear { withAnimation(.spring(response: 0.6, dampingFraction: 0.65)) { appear = true } }
    }

    // MARK: Hero berbingkai terminal

    private var hero: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    ForEach(["#FF5F57", "#FEBC2E", "#28C840"], id: \.self) { hex in
                        Circle().fill(Color(hex: hex)).frame(width: 8, height: 8)
                    }
                    Spacer()
                    Text("ZTERM — ABOUT")
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .tracking(1.1)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .frame(height: 31)
                .background(Theme.ink.opacity(0.02))
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.cardStroke).frame(height: 1) }

                HStack(alignment: .center, spacing: 16) {
                    ZtermLogo(size: 68)
                        .scaleEffect(appear ? 1 : 0.78)
                        .rotationEffect(.degrees(appear ? 0 : -10))
                        .opacity(appear ? 1 : 0)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Tentang Zterm"))
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(1.4)
                            .textCase(.uppercase)
                            .foregroundStyle(.tertiary)
                        Text("Zterm")
                            .font(.system(size: 34, weight: .heavy, design: .rounded))
                        HStack(spacing: 6) {
                            Text(">").foregroundStyle(Theme.accent)
                            TypewriterText(L("Semua servermu, satu terminal."), delay: 0.35)
                                .foregroundStyle(.secondary)
                        }
                        .font(.system(size: 13.5, design: .monospaced))
                        .frame(height: 18)
                        HStack(spacing: 7) {
                            Badge(text: "v\(AppVersion.current)")
                            Badge(text: L("CORE {}", coreVersion()), color: Theme.accent2)
                            Badge(text: "MIT", color: Theme.accent3)
                            Text("SWIFTUI · SWIFTTERM · OPENSSH")
                                .font(.system(size: 8.5, weight: .semibold))
                                .tracking(0.9)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    .layoutPriority(1)

                    Spacer(minLength: 8)

                    VStack(alignment: .trailing, spacing: 7) {
                        UpdateStatus()
                        Text(L("Gratis · tanpa iklan · local-first"))
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    .frame(width: 230, alignment: .trailing)
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 16)
            }

            Text(">_")
                .font(.system(size: 112, weight: .heavy, design: .monospaced))
                .foregroundStyle(Theme.accent.opacity(0.07))
                .offset(x: -14, y: 30)
                .allowsHitTesting(false)
        }
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.cardStroke))
    }

    // MARK: Panel

    private var explorePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            panelHead(L("Jelajahi"), L("Buka di browser"))
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                AboutTile(icon: "globe", color: Theme.accent, title: L("Website"), subtitle: "latief.id/zterm", url: Links.website)
                AboutTile(icon: "file-code", color: Theme.accent2, title: "GitHub", subtitle: "latiefahmad/zterm", url: Links.github)
                AboutTile(icon: "sparkle", color: Theme.accent3, title: L("Catatan rilis"), subtitle: L("Yang baru"), url: Links.releases)
                AboutTile(icon: "bug", color: Theme.orange, title: L("Laporkan bug"), subtitle: "github issues", url: Links.issues)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.cardStroke))
    }

    private var infoPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            panelHead(L("Di balik layar"), "native · rust")
            VStack(spacing: 0) {
                AboutInfoRow(icon: "user", label: L("Dibuat oleh"), value: "Latief Ahmad")
                AboutInfoRow(icon: "cube", label: L("Inti"), value: "zterm-core · Rust")
                AboutInfoRow(icon: "shield-check", label: L("Keamanan"), value: "Argon2id + XChaCha20")
                AboutInfoRow(icon: "cloud", label: "Sync", value: "Google Drive · zero-knowledge", last: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.cardStroke))
    }

    private func panelHead(_ title: String, _ hint: String) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer()
            Text(hint.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    private var footer: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 14) {
                    Link(L("Kebijakan Privasi"), destination: Links.privacy)
                    Link(L("Syarat Layanan"), destination: Links.terms)
                }
                .font(.system(size: 11.5))
                .tint(Theme.accent)
                Text(L("© 2026 Latief Ahmad · Lisensi MIT"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                LanguagePicker()
                Button { NSWorkspace.shared.open(Links.donate) } label: {
                    PhosphorLabel(text: "Support me", icon: "heart", size: 12)
                }
                .buttonStyle(PrimaryButtonStyle(size: .large))
                .help("saweria.co/latiefahmad")
            }
        }
    }
}

/// Kartu tautan ringkas di panel Explore.
struct AboutTile: View {
    let icon: String
    let color: Color
    let title: String
    let subtitle: String
    let url: URL
    @State private var hover = false

    var body: some View {
        Button { NSWorkspace.shared.open(url) } label: {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(color.opacity(0.12))
                        .frame(width: 30, height: 30)
                    PhosphorIcon(name: icon, size: 14, tint: color)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hover ? Theme.cardHover : Theme.field, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.cardStroke))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.ztermHover) { hover = h } }
        .help(url.absoluteString)
    }
}

/// Baris info empat kolom di panel "Di balik layar".
struct AboutInfoRow: View {
    let icon: String
    let label: String
    let value: String
    var last = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Theme.ink.opacity(0.04))
                        .frame(width: 26, height: 26)
                    PhosphorIcon(name: icon, size: 13, tint: .secondary)
                }
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 74, alignment: .leading)
                Spacer(minLength: 4)
                Text(value)
                    .font(.system(size: 12, weight: .medium))
                    .multilineTextAlignment(.trailing)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.vertical, 8)
            if !last { Divider().opacity(0.6) }
        }
    }
}

/// Status versi ringkas di sisi hero + tombol cek / pasang pembaruan.
struct UpdateStatus: View {
    @Environment(AppModel.self) private var model
    @State private var checking = false

    private var title: String {
        if model.updateBusy { return model.updateStatus ?? L("Mengunduh pembaruan…") }
        if let u = model.update { return L("Versi {} tersedia", u.version) }
        return L("Kamu memakai versi terbaru")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(model.update == nil ? Theme.accent : Theme.orange)
                    .frame(width: 8, height: 8)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 1) {
                    Text("UPDATE")
                        .font(.system(size: 8, weight: .semibold))
                        .tracking(1.0)
                        .foregroundStyle(.tertiary)
                    Text(title)
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 2)
                if !model.updateBusy {
                    Button {
                        Task {
                            checking = true
                            await model.checkForUpdates(manual: true)
                            checking = false
                        }
                    } label: {
                        if checking { ProgressView().controlSize(.mini) } else { Text(L("Periksa")).font(.system(size: 11, weight: .semibold)) }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(model.updateBusy)
                }
            }
            if model.updateBusy {
                ProgressView(value: min(max(model.updateProgress, 0), 1))
                    .progressViewStyle(.linear)
                    .tint(Theme.accent)
                    .animation(.easeOut(duration: 0.2), value: model.updateProgress)
                Text(model.updateStatus ?? L("Mengunduh pembaruan…"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let u = model.update {
                HStack(spacing: 6) {
                    Button(L("Update sekarang")) { confirmAndInstallUpdate(model, version: u.version) }
                        .buttonStyle(PrimaryButtonStyle())
                    Button { NSWorkspace.shared.open(u.page) } label: {
                        PhosphorIcon(name: "sparkle", size: 12)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .help(L("Catatan rilis"))
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.field, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(model.update == nil ? Theme.cardStroke : Theme.orange.opacity(0.35)))
    }
}
