import Foundation

/// Bahasa app: Indonesia (teks asli di kode) atau Inggris (kamus `en.json` dari folder i18n repo).
/// Pilihan disimpan di Mac ini; berlaku setelah app dibuka ulang.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, id, en
    var id: String { rawValue }

    static let storageKey = "app.language"

    /// Judul pilihan — sengaja dwibahasa agar bisa dikenali di bahasa mana pun.
    var title: String {
        switch self {
        case .system: L("Ikuti sistem")
        case .id: "Bahasa Indonesia"
        case .en: "English"
        }
    }

    static var choice: AppLanguage {
        get { AppLanguage(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: storageKey) }
    }

    /// Bahasa yang dipakai sekarang ("id" atau "en"), ditetapkan sekali saat app dibuka.
    static let resolved: String = {
        if let forced = ProcessInfo.processInfo.environment["ZTERM_LANG"], ["id", "en"].contains(forced) { return forced }
        return choice.language
    }()

    /// Kode bahasa ("id"/"en") untuk pilihan ini.
    var language: String {
        switch self {
        case .id: return "id"
        case .en: return "en"
        case .system: return Locale.preferredLanguages.first.map { $0.hasPrefix("id") || $0.hasPrefix("in") } == true ? "id" : "en"
        }
    }
}

import AppKit
import SwiftUI

/// Ganti bahasa: simpan pilihan, lalu tawarkan buka ulang app (teks dimuat sekali saat app dibuka).
@MainActor
enum LanguageSwitch {
    static let title = "Bahasa / Language"

    static var binding: Binding<AppLanguage> {
        Binding(get: { AppLanguage.choice }, set: { choose($0) })
    }

    static func choose(_ lang: AppLanguage) {
        guard lang != AppLanguage.choice else { return }
        AppLanguage.choice = lang
        guard lang.language != AppLanguage.resolved else { return }
        // Tampilkan setelah menu tertutup
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = L("Bahasa diterapkan setelah Zterm dibuka ulang")
            alert.informativeText = lang.language == "en" ? "The new language is applied after Zterm restarts." : "Bahasa baru diterapkan setelah Zterm dibuka ulang."
            alert.addButton(withTitle: L("Buka ulang sekarang"))
            alert.addButton(withTitle: L("Nanti"))
            if alert.runModal() == .alertFirstButtonReturn { relaunch() }
        }
    }

    static func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }
}

/// Pilihan bahasa (dipakai di halaman Tentang).
struct LanguagePicker: View {
    @State private var choice = AppLanguage.choice

    var body: some View {
        Picker(LanguageSwitch.title, selection: Binding(get: { choice }, set: { choice = $0; LanguageSwitch.choose($0) })) {
            ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
        }
        .fixedSize()
    }
}

final class L10n: @unchecked Sendable {
    static let shared = L10n()

    let english: Bool
    private let table: [String: String]
    /// Entri berpola ({} = teks apa saja) untuk pesan dari core.
    private let patterns: [(NSRegularExpression, String)]

    private init() {
        english = AppLanguage.resolved == "en"
        guard english, let url = Bundle.main.url(forResource: "en", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let t = try? JSONDecoder().decode([String: String].self, from: data) else {
            table = [:]; patterns = []; return
        }
        table = t
        patterns = t.compactMap { k, v in
            guard k.contains("{}") else { return nil }
            let parts = k.components(separatedBy: "{}").map(NSRegularExpression.escapedPattern(for:))
            guard let re = try? NSRegularExpression(pattern: "^" + parts.joined(separator: "(.+?)") + "$", options: [.dotMatchesLineSeparators]) else { return nil }
            return (re, v)
        }
        // Pola dengan teks tetap terbanyak (paling spesifik) dicoba dulu
        .sorted { $0.0.pattern.replacingOccurrences(of: "(.+?)", with: "").count > $1.0.pattern.replacingOccurrences(of: "(.+?)", with: "").count }
    }

    func text(_ s: String) -> String {
        guard english else { return s }
        if let t = table[s] { return t }
        #if DEBUG
        reportMissing(s)
        #endif
        return s
    }

    #if DEBUG
    /// Hanya build debug + env `ZTERM_I18N_CHECK=1`: catat ke stderr teks `L()` yang belum ada di kamus Inggris.
    private let checkMissing = ProcessInfo.processInfo.environment["ZTERM_I18N_CHECK"] == "1"
    private var reported = Set<String>()
    private let lock = NSLock()
    private func reportMissing(_ s: String) {
        guard checkMissing, s.rangeOfCharacter(from: .letters) != nil else { return }
        lock.lock(); defer { lock.unlock() }
        guard reported.insert(s).inserted else { return }
        FileHandle.standardError.write(Data("i18n: belum diterjemahkan: \(s.debugDescription)\n".utf8))
    }
    #endif

    /// Terjemahkan pesan utuh (mis. error dari core) memakai entri persis atau berpola.
    func message(_ s: String) -> String {
        guard english else { return s }
        if let t = match(s) { return t }
        // App sering menaikkan huruf pertama pesan core ("server tidak…" → "Server tidak…")
        if let f = s.first, f.isUppercase, let t = match(f.lowercased() + s.dropFirst()) {
            return t.prefix(1).uppercased() + t.dropFirst()
        }
        return s
    }

    private func match(_ s: String) -> String? {
        if let t = table[s] { return t }
        let range = NSRange(s.startIndex..., in: s)
        for (re, out) in patterns {
            guard let m = re.firstMatch(in: s, range: range) else { continue }
            var result = out
            for i in 1..<m.numberOfRanges {
                guard let r = Range(m.range(at: i), in: s), let slot = result.range(of: "{}") else { break }
                // Bagian yang disisipkan bisa berupa pesan lain (mis. alasan error) → terjemahkan juga
                result.replaceSubrange(slot, with: message(String(s[r])))
            }
            return result
        }
        return nil
    }
}

/// Teks UI dalam bahasa aktif. `{}` diisi `args` berurutan: `L("Backup {} selesai", name)`.
func L(_ s: String, _ args: Any...) -> String {
    var out = L10n.shared.text(s)
    for a in args {
        guard let r = out.range(of: "{}") else { break }
        out.replaceSubrange(r, with: String(describing: a))
    }
    return out
}

/// Pesan yang berasal dari core / server (dicocokkan juga dengan pola di kamus).
func Lmsg(_ s: String) -> String { L10n.shared.message(s) }
