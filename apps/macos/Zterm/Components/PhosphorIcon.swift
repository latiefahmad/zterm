import SwiftUI

/// Ikon Phosphor Duotone. Data path dimuat dari `phosphor.json` (256×256) dan
/// sudah dinormalkan ke perintah M/L/C/Z, jadi tidak perlu parser SVG penuh.
struct PhosphorIcon: View {
    let name: String
    var size: CGFloat = 16
    var tint: Color = .primary
    var secondaryOpacity: Double = 0.2

    var body: some View {
        let glyph = PhosphorStore.shared.glyph(name)
        ZStack {
            if let glyph {
                if let secondary = glyph.secondary {
                    PhosphorShape(path: secondary).fill(tint.opacity(secondaryOpacity))
                }
                PhosphorShape(path: glyph.primary).fill(tint)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Tombol ikon kecil dengan sorotan halus, dipakai di header kartu.
struct PhIconButton: View {
    let name: String
    var help: String
    var tint: Color = .secondary
    var size: CGFloat = 15
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            PhosphorIcon(name: name, size: size, tint: hover ? .primary : tint)
                .frame(width: 28, height: 28)
                .background(Theme.ink.opacity(hover ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { h in withAnimation(.ztermHover) { hover = h } }
    }
}

// MARK: - Data

private struct PhosphorFile: Decodable {
    struct Entry: Decodable {
        let secondary: String
        let primary: String
    }
    let icons: [String: Entry]
}

/// Hasil parse satu ikon; harus selevel dengan `PhosphorStore` agar bisa dipakai
/// sebagai tipe kembalian metode internal.
struct PhosphorGlyph {
    let secondary: Path?
    let primary: Path
}

@MainActor
final class PhosphorStore {
    static let shared = PhosphorStore()

    private var raw: [String: PhosphorFile.Entry]?
    private var cache: [String: PhosphorGlyph] = [:]

    func glyph(_ name: String) -> PhosphorGlyph? {
        if let hit = cache[name] { return hit }
        if raw == nil { load() }
        guard let entry = raw?[name] else {
            assertionFailure("Ikon Phosphor tidak ditemukan: \(name)")
            return nil
        }
        let glyph = PhosphorGlyph(
            secondary: entry.secondary.isEmpty ? nil : SVGPath.parse(entry.secondary),
            primary: SVGPath.parse(entry.primary)
        )
        cache[name] = glyph
        return glyph
    }

    private func load() {
        guard let url = Bundle.main.url(forResource: "phosphor", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(PhosphorFile.self, from: data)
        else {
            assertionFailure("phosphor.json tidak ada di bundle")
            raw = [:]
            return
        }
        raw = file.icons
    }
}

// MARK: - Render

private struct PhosphorShape: Shape {
    let path: Path

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 256
        let dx = rect.minX + (rect.width - 256 * scale) / 2
        let dy = rect.minY + (rect.height - 256 * scale) / 2
        return path.applying(CGAffineTransform(translationX: dx, y: dy).scaledBy(x: scale, y: scale))
    }
}

// MARK: - Parser M/L/C/Z

private enum SVGPath {
    static func parse(_ d: String) -> Path {
        var path = Path()
        var scanner = Scanner(d)
        var cx: CGFloat = 0, cy: CGFloat = 0
        var sx: CGFloat = 0, sy: CGFloat = 0

        while let command = scanner.command() {
            switch command {
            case "M":
                let x = scanner.number(), y = scanner.number()
                path.move(to: CGPoint(x: x, y: y))
                cx = x; cy = y; sx = x; sy = y
                while scanner.hasNumber() {
                    let nx = scanner.number(), ny = scanner.number()
                    path.addLine(to: CGPoint(x: nx, y: ny))
                    cx = nx; cy = ny
                }
            case "L":
                while scanner.hasNumber() {
                    let x = scanner.number(), y = scanner.number()
                    path.addLine(to: CGPoint(x: x, y: y))
                    cx = x; cy = y
                }
            case "C":
                while scanner.hasNumber() {
                    let x1 = scanner.number(), y1 = scanner.number()
                    let x2 = scanner.number(), y2 = scanner.number()
                    let x = scanner.number(), y = scanner.number()
                    path.addCurve(to: CGPoint(x: x, y: y),
                                  control1: CGPoint(x: x1, y: y1),
                                  control2: CGPoint(x: x2, y: y2))
                    cx = x; cy = y
                }
            case "Z":
                path.closeSubpath()
                cx = sx; cy = sy
            default:
                return path
            }
        }
        return path
    }

    private struct Scanner {
        private let bytes: [UInt8]
        private var i = 0

        init(_ text: String) { bytes = Array(text.utf8) }

        private mutating func skip() {
            while i < bytes.count {
                switch bytes[i] {
                case 32, 44, 9, 10, 13: i += 1
                default: return
                }
            }
        }

        mutating func command() -> Character? {
            skip()
            guard i < bytes.count else { return nil }
            let b = bytes[i]
            guard (b >= 65 && b <= 90) || (b >= 97 && b <= 122) else { return nil }
            i += 1
            return Character(UnicodeScalar(b))
        }

        mutating func hasNumber() -> Bool {
            skip()
            guard i < bytes.count else { return false }
            let b = bytes[i]
            return (b >= 48 && b <= 57) || b == 45 || b == 43 || b == 46
        }

        mutating func number() -> CGFloat {
            skip()
            let start = i
            if i < bytes.count, bytes[i] == 45 || bytes[i] == 43 { i += 1 }
            while i < bytes.count, bytes[i] >= 48, bytes[i] <= 57 { i += 1 }
            if i < bytes.count, bytes[i] == 46 {
                i += 1
                while i < bytes.count, bytes[i] >= 48, bytes[i] <= 57 { i += 1 }
            }
            let text = String(decoding: bytes[start..<i], as: UTF8.self)
            return CGFloat(Double(text) ?? 0)
        }
    }
}
