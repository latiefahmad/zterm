import AppKit
import SwiftUI

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt64(s, radix: 16) ?? 0x3FD0B4
        self.init(
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
        )
    }

    /// `#RRGGBB` dari warna SwiftUI (untuk disimpan di vault).
    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        return String(format: "#%02X%02X%02X", Int(round(ns.redComponent * 255)),
                      Int(round(ns.greenComponent * 255)), Int(round(ns.blueComponent * 255)))
    }

    /// Warna yang otomatis berganti mengikuti mode terang / gelap.
    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in
            ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

private func ns(_ hex: String, _ a: CGFloat = 1) -> NSColor { NSColor(Color(hex: hex)).withAlphaComponent(a) }

enum Theme {
    static let accent = Color(hex: "#3FD0B4")
    static let accent2 = Color(hex: "#5B9CF5")
    static let accent3 = Color(hex: "#9D7CF2")
    static let green = Color(hex: "#4ADE80")
    static let orange = Color(hex: "#F2A65A")
    static let red = Color(hex: "#F0616D")

    /// Hitam di mode terang, putih di mode gelap - dipakai dengan opacity untuk garis & lapisan.
    static let ink = Color.adaptive(light: .black, dark: .white)

    /// Permukaan netral ala shadcn: kertas zinc, garis tipis, tanpa lapisan kaca.
    static let bg = Color.adaptive(light: ns("#F7F7F8"), dark: ns("#09090B"))
    static let panel = Color.adaptive(light: ns("#FFFFFF"), dark: ns("#0C0C0F"))
    static let card = Color.adaptive(light: ns("#FFFFFF"), dark: ns("#131316"))
    static let cardHover = Color.adaptive(light: ns("#FAFAFA"), dark: ns("#18181B"))
    static let cardStroke = Color.adaptive(light: ns("#E4E4E7"), dark: ns("#27272A"))
    static let field = Color.adaptive(light: ns("#F4F4F5"), dark: ns("#18181B"))
    static let shadow = Color.adaptive(light: NSColor.black.withAlphaComponent(0.06), dark: NSColor.black.withAlphaComponent(0.50))

    static let hostColors = ["#3FD0B4", "#5B9CF5", "#9D7CF2", "#F2A65A", "#F0616D", "#8BD450", "#E879C6", "#94A3B8"]
    /// Pilihan warna kartu host (bisa juga warna bebas lewat color picker).
    static let cardPalette = ["#3FD0B4", "#22C55E", "#84CC16", "#EAB308", "#F2A65A", "#F97316", "#F0616D", "#E11D48",
                              "#E879C6", "#C084FC", "#9D7CF2", "#6366F1", "#5B9CF5", "#06B6D4", "#14B8A6", "#94A3B8"]

    /// Dipertahankan sebagai nama lama, tetapi kini satu warna: aksen rata tanpa gradien.
    static let brandGradient = LinearGradient(
        colors: [accent, accent], startPoint: .top, endPoint: .bottom)
}

// MARK: - Tampilan (Sistem / Terang / Gelap)

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: L("Ikuti sistem")
        case .light: L("Terang")
        case .dark: L("Gelap")
        }
    }
    var icon: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }

    /// Diterapkan ke seluruh app (termasuk terminal & menu) lewat NSApp.appearance.
    @MainActor func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    static let storageKey = "appearance"
}

// MARK: - Animasi

/// Spring standar agar semua animasi terasa satu keluarga.
extension Animation {
    /// Transisi besar: pindah layar, panel, daftar.
    static let zterm = Animation.spring(response: 0.42, dampingFraction: 0.86)
    /// Interaksi kecil: tombol, hover, pilih.
    static let ztermSnappy = Animation.spring(response: 0.26, dampingFraction: 0.8)
    static let ztermHover = Animation.easeOut(duration: 0.14)
}

// MARK: - Kartu

struct GlassCard: ViewModifier {
    var padding: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.cardStroke))
    }
}

extension View {
    func glassCard(padding: CGFloat = 16) -> some View { modifier(GlassCard(padding: padding)) }
}

// MARK: - Tombol

enum ZtermButtonSize {
    case regular, large
    var height: CGFloat { self == .large ? 40 : 30 }
    var font: Font { .system(size: self == .large ? 14 : 13, weight: .semibold) }
    var hPad: CGFloat { self == .large ? 18 : 12 }
    var radius: CGFloat { self == .large ? 10 : 8 }
}

/// Tombol utama: aksen rata, teks gelap, tanpa glow.
struct PrimaryButtonStyle: ButtonStyle {
    var wide = false
    var size: ZtermButtonSize = .regular

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, wide: wide, size: size)
    }

    private struct Styled: View {
        let configuration: Configuration
        let wide: Bool
        let size: ZtermButtonSize
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false

        var body: some View {
            configuration.label
                .font(size.font)
                .lineLimit(1)
                .foregroundStyle(Color(hex: "#06231E"))
                .padding(.horizontal, size.hPad)
                .frame(height: size.height)
                .frame(maxWidth: wide ? .infinity : nil)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: size.radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: size.radius, style: .continuous)
                    .fill(.white.opacity(hover && enabled ? 0.12 : 0)))
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .opacity(enabled ? 1 : 0.45)
                .contentShape(Rectangle())
                .onHover { h in withAnimation(.ztermHover) { hover = h } }
                .animation(.ztermSnappy, value: configuration.isPressed)
        }
    }
}

/// Tombol sekunder: lapisan netral yang menyesuaikan mode terang/gelap.
struct SecondaryButtonStyle: ButtonStyle {
    var wide = false
    var size: ZtermButtonSize = .regular

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, wide: wide, size: size)
    }

    private struct Styled: View {
        let configuration: Configuration
        let wide: Bool
        let size: ZtermButtonSize
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false

        var body: some View {
            configuration.label
                .font(size.font.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, size.hPad)
                .frame(height: size.height)
                .frame(maxWidth: wide ? .infinity : nil)
                .background(Theme.ink.opacity(configuration.isPressed ? 0.12 : hover ? 0.09 : 0.055),
                            in: RoundedRectangle(cornerRadius: size.radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: size.radius, style: .continuous).strokeBorder(Theme.cardStroke))
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .opacity(enabled ? 1 : 0.45)
                .contentShape(Rectangle())
                .onHover { h in withAnimation(.ztermHover) { hover = h } }
                .animation(.ztermSnappy, value: configuration.isPressed)
        }
    }
}

// MARK: - Transisi

/// Transisi masuk/keluar dengan blur — dipakai antar langkah onboarding.
struct BlurModifier: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View { content.blur(radius: radius) }
}

extension AnyTransition {
    static var blurSlide: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: BlurModifier(radius: 8), identity: BlurModifier(radius: 0))
                .combined(with: .opacity).combined(with: .offset(x: 24)),
            removal: .modifier(active: BlurModifier(radius: 8), identity: BlurModifier(radius: 0))
                .combined(with: .opacity).combined(with: .offset(x: -24))
        )
    }
}
