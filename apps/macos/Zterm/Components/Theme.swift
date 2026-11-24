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

    /// Hitam di mode terang, putih di mode gelap — dipakai dengan opacity untuk garis & lapisan.
    static let ink = Color.adaptive(light: .black, dark: .white)

    static let bg = Color.adaptive(light: ns("#F4F6F9"), dark: ns("#0B0E13"))
    static let panel = Color.adaptive(light: ns("#FBFCFD"), dark: ns("#0F131A"))
    static let card = Color.adaptive(light: .white, dark: NSColor.white.withAlphaComponent(0.045))
    static let cardHover = Color.adaptive(light: .white, dark: NSColor.white.withAlphaComponent(0.075))
    static let cardStroke = Color.adaptive(light: NSColor.black.withAlphaComponent(0.08), dark: NSColor.white.withAlphaComponent(0.08))
    static let field = Color.adaptive(light: NSColor.black.withAlphaComponent(0.04), dark: NSColor.black.withAlphaComponent(0.25))
    static let shadow = Color.adaptive(light: NSColor.black.withAlphaComponent(0.10), dark: NSColor.black.withAlphaComponent(0.40))

    static let hostColors = ["#3FD0B4", "#5B9CF5", "#9D7CF2", "#F2A65A", "#F0616D", "#8BD450", "#E879C6", "#94A3B8"]
    /// Pilihan warna kartu host (bisa juga warna bebas lewat color picker).
    static let cardPalette = ["#3FD0B4", "#22C55E", "#84CC16", "#EAB308", "#F2A65A", "#F97316", "#F0616D", "#E11D48",
                              "#E879C6", "#C084FC", "#9D7CF2", "#6366F1", "#5B9CF5", "#06B6D4", "#14B8A6", "#94A3B8"]

    static let brandGradient = LinearGradient(
        colors: [accent, accent2, accent3], startPoint: .topLeading, endPoint: .bottomTrailing)
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
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.cardStroke))
            .shadow(color: Theme.shadow.opacity(0.35), radius: 2, y: 1)
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

/// Tombol utama: gradien brand, glow halus, terang saat hover, mengecil saat ditekan.
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
                .foregroundStyle(Color.black.opacity(0.82))
                .padding(.horizontal, size.hPad)
                .frame(height: size.height)
                .frame(maxWidth: wide ? .infinity : nil)
                .background(Theme.brandGradient, in: RoundedRectangle(cornerRadius: size.radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: size.radius, style: .continuous)
                    .fill(.white.opacity(hover && enabled ? 0.14 : 0)))
                .shadow(color: Theme.accent.opacity(enabled ? (hover ? 0.4 : 0.22) : 0), radius: hover ? 12 : 8, y: 3)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
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
