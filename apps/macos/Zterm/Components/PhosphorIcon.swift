import SwiftUI

/// Ikon Phosphor Duotone. Data path dimuat dari `phosphor.json` (256×256) dan
/// sudah dinormalkan ke perintah M/L/C/Z, jadi tidak perlu parser SVG penuh.
struct PhosphorIcon: View {
    let name: String
    var size: CGFloat = 16
    /// `nil` berarti mengikuti `foregroundStyle` dari parent.
    var tint: Color? = nil
    var secondaryOpacity: Double = 0.2

    var body: some View {
        let glyph = PhosphorStore.shared.glyph(name)
        ZStack {
            if let glyph {
                let style = tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.foreground)
                if let secondary = glyph.secondary {
                    PhosphorShape(path: secondary).fill(style).opacity(secondaryOpacity)
                }
                PhosphorShape(path: glyph.primary).fill(style)
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

// MARK: - Kompatibilitas nama SF Symbol

/// Peta nama SF Symbol lama ke Phosphor. Dipakai selama migrasi halaman;
/// nama yang tidak dikenal jatuh ke `circle` agar UI tidak kosong.
enum PhosphorMap {
    static let table: [String: String] = [
        // Navigasi & caret
        "chevron.left": "caret-left", "chevron.right": "caret-right",
        "chevron.up": "caret-up", "chevron.down": "caret-down",
        "chevron.up.chevron.down": "caret-up-down",
        "chevron.left.2": "caret-double-left", "chevron.right.2": "caret-double-right",
        "chevron.left.forwardslash.chevron.right": "file-code",
        "chevron.right.circle.fill": "arrow-circle-right",
        "arrow.left": "arrow-left", "arrow.right": "arrow-right",
        "arrow.up": "arrow-up", "arrow.down": "arrow-down",
        "arrow.up.right": "arrow-up-right", "arrow.up.forward.app": "arrow-up-right",
        "arrow.up.right.square": "arrow-square-out",
        "arrow.right.circle": "arrow-circle-right", "arrow.left.circle": "arrow-circle-left",
        "arrow.right.circle.fill": "arrow-circle-right",
        "arrow.down.circle": "arrow-circle-down", "arrow.down.circle.fill": "arrow-circle-down",
        "arrow.up.circle": "arrow-circle-up", "arrow.up.circle.fill": "arrow-circle-up",
        "arrow.down.to.line": "arrow-line-down",
        "arrow.clockwise": "arrows-clockwise",
        "arrow.clockwise.circle": "arrows-clockwise",
        "arrow.counterclockwise": "arrow-counter-clockwise",
        "arrow.triangle.2.circlepath": "arrows-clockwise",
        "arrow.left.arrow.right": "arrows-left-right",
        "arrow.up.and.down": "arrows-down-up",
        "arrow.up.and.down.and.arrow.left.and.right": "arrows-out",
        "arrow.down.right.and.arrow.up.left": "arrows-out",
        "arrow.up.left.and.arrow.down.right": "arrows-out",
        "rectangle.split.2x1": "columns",
        "plus.square.on.square": "copy", "square.on.square": "copy",
        "rectangle.on.rectangle": "copy",
        "rectangle.badge.minus": "minus-square",
        "sidebar.left": "sidebar-simple", "sidebar.squares.left": "sidebar-simple",
        // Status & aksi
        "checkmark": "check", "checkmark.circle.fill": "check-circle",
        "checkmark.square": "check-square", "checkmark.square.fill": "check-square",
        "checkmark.seal.fill": "seal-check", "checkmark.icloud.fill": "cloud-check",
        "xmark": "x", "xmark.circle": "x-circle", "xmark.circle.fill": "x-circle",
        "xmark.octagon": "prohibit",
        "plus": "plus", "minus": "minus", "minus.circle": "minus-circle",
        "minus.circle.fill": "minus-circle", "plus.circle": "plus-circle",
        "exclamationmark.triangle": "warning", "exclamationmark.triangle.fill": "warning",
        "exclamationmark.circle": "warning-circle",
        "exclamationmark.icloud.fill": "cloud-warning",
        "info": "info", "info.circle": "info",
        "questionmark.circle": "question",
        "lock.fill": "lock-simple", "lock.slash": "lock-open",
        "lock.rotation": "fingerprint", "lock.shield": "shield-check",
        "lock.trianglebadge.exclamationmark": "warning-circle",
        "key": "key", "key.fill": "key",
        "key.horizontal": "key", "key.horizontal.fill": "key",
        "eye": "eye", "eye.slash": "eye-slash",
        "bell": "bell", "bell.fill": "bell", "bell.slash": "bell-slash",
        "trash": "trash", "pencil": "pencil-simple",
        "square.and.arrow.down": "download-simple", "square.and.arrow.up": "upload-simple",
        "tray": "tray", "doc.on.doc": "copy", "doc.on.doc.fill": "copy",
        "rectangle.portrait.and.arrow.right": "sign-out",
        "power": "power", "scope": "selection-plus",
        "square.dashed": "selection-plus", "rectangle.dashed": "selection-plus",
        "dot.radiowaves.left.and.right": "broadcast",
        "sparkles": "sparkle", "hourglass": "hourglass",
        "person.fill": "user", "person.crop.circle": "user-circle",
        "person.2.fill": "users", "person.2.badge.key.fill": "users-three",
        "person.badge.plus": "user-plus", "person.badge.key": "user-circle",
        "person.fill.xmark": "user-minus",
        "envelope": "envelope-simple", "envelope.fill": "envelope-simple",
        "envelope.open.fill": "envelope-open",
        "paperplane": "paper-plane-tilt",
        "g.circle.fill": "google-logo",
        "checklist": "list-checks",
        "play.fill": "play", "stop.fill": "stop", "stop.circle": "stop-circle",
        "bolt.fill": "lightning", "bolt.horizontal": "lightning",
        "bolt.horizontal.circle": "lightning",
        "icloud.and.arrow.down.fill": "cloud-arrow-down",
        "externaldrive.badge.plus": "hard-drive",
        "externaldrive.badge.timemachine": "clock",
        "clock.badge.checkmark": "clock",
        "calendar.badge.clock": "calendar",
        "text.cursor": "cursor-text", "text.badge.xmark": "text-strikethrough",
        "slider.horizontal.3": "sliders-horizontal",
        "line.3.horizontal.decrease.circle.fill": "funnel",
        "line.3.horizontal.decrease": "funnel",
        "line.3.horizontal": "list-dashes",
        "list.bullet": "list-dashes", "list.bullet.rectangle": "rows",
        "square.grid.2x2": "squares-four", "square.grid.2x2.fill": "squares-four",
        "square.stack.3d.up.fill": "stack",
        "square": "square", "circle": "circle", "circle.fill": "circle",
        "circle.lefthalf.filled": "circle-half",
        "record.circle": "record", "dot.circle": "dot-outline",
        "smallcircle.filled.circle": "dot-outline",
        "circle.dashed": "circle-notch",
        "cpu": "cpu", "memorychip": "memory",
        "clock": "clock", "clock.arrow.circlepath": "clock",
        "server.rack": "hard-drives",
        "laptopcomputer": "laptop", "desktopcomputer": "desktop-tower",
        "macwindow": "monitor", "display": "monitor",
        "externaldrive": "hard-drive", "internaldrive": "hard-drive",
        "globe": "globe", "network": "globe", "safari": "globe",
        "wifi": "wifi-high", "wifi.slash": "wifi-slash",
        "shippingbox.fill": "package", "shippingbox": "package", "archivebox": "archive",
        "square.stack.3d.down.right": "stack",
        "curlybraces": "brackets-curly",
        "apple.terminal": "terminal-window", "terminal": "terminal-window",
        "ellipsis": "dots-three", "ellipsis.circle": "dots-three-circle",
        "ellipsis.circle.fill": "dots-three-circle",
        "ellipsis.rectangle": "password",
        "magnifyingglass": "magnifying-glass",
        "person.3.fill": "users-three",
        "point.3.connected.trianglepath.dotted": "tree-structure",
        "gearshape": "gear-six", "gearshape.2": "gear-six",
        "gauge.with.dots.needle.67percent": "gauge",
        "wrench.and.screwdriver.fill": "wrench",
        "arrow.right.arrow.left": "arrows-left-right",
        "cylinder": "database", "cylinder.split.1x2": "database",
        "cylinder.split.1x2.fill": "database",
        "tablecells": "table",
        "touchid": "fingerprint",
        // Berkas
        "doc": "file", "doc.fill": "file",
        "doc.text": "file-text", "doc.text.fill": "file-text",
        "doc.text.magnifyingglass": "file-magnifying-glass",
        "doc.zipper": "file-zip", "doc.richtext": "file-pdf",
        "arrow.up.doc": "file-arrow-up", "arrow.up.doc.fill": "file-arrow-up",
        "arrow.down.doc.fill": "file-arrow-down",
        "photo": "image", "photo.on.rectangle": "image", "photos": "image",
        "film": "film-strip", "music.note": "music-notes",
        "folder": "folder", "folder.fill": "folder",
        "folder.badge.plus": "folder-plus", "folder.fill.badge.plus": "folder-plus",
        "house": "house",
        "sun.max.fill": "sun", "moon.fill": "moon",
    ]

    static func name(for symbol: String) -> String { table[symbol] ?? "circle" }
}

extension PhosphorIcon {
    /// Memakai nama SF Symbol lama (dipetakan otomatis ke Phosphor).
    init(sf symbol: String, size: CGFloat = 16, tint: Color? = nil, secondaryOpacity: Double = 0.2) {
        self.init(name: PhosphorMap.name(for: symbol), size: size, tint: tint, secondaryOpacity: secondaryOpacity)
    }
}

/// Label Phosphor + teks, pengganti `Label(_, systemImage:)`.
struct PhosphorLabel: View {
    let text: String
    let icon: String
    var size: CGFloat = 13
    var tint: Color? = nil

    /// Memakai nama SF Symbol lama (dipetakan otomatis ke Phosphor).
    init(sf symbol: String, text: String, size: CGFloat = 13, tint: Color? = nil) {
        self.text = text
        self.icon = PhosphorMap.name(for: symbol)
        self.size = size
        self.tint = tint
    }

    init(text: String, icon: String, size: CGFloat = 13, tint: Color? = nil) {
        self.text = text
        self.icon = icon
        self.size = size
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 6) {
            PhosphorIcon(name: icon, size: size, tint: tint)
            Text(text)
        }
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
