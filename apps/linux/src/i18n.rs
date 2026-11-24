//! Bahasa app: Indonesia (teks asli di kode) atau Inggris (kamus `i18n/en.json` repo, ditanam saat build).
//! Pilihan disimpan di `<data>/language` (system | id | en); berlaku setelah app dibuka ulang.

use std::collections::HashMap;
use std::sync::OnceLock;

const EN_JSON: &str = include_str!("../../../i18n/en.json");

pub const CHOICES: [&str; 3] = ["system", "id", "en"];

fn choice_path() -> std::path::PathBuf {
    crate::config::data_dir().join("language")
}

/// Pilihan tersimpan: "system", "id", atau "en".
pub fn choice() -> String {
    let c = std::fs::read_to_string(choice_path()).unwrap_or_default().trim().to_string();
    if CHOICES.contains(&c.as_str()) { c } else { "system".into() }
}

pub fn set_choice(c: &str) {
    let _ = std::fs::write(choice_path(), c);
}

pub fn choice_title(c: &str) -> String {
    match c {
        "id" => "Bahasa Indonesia".into(),
        "en" => "English".into(),
        _ => tr("Ikuti sistem"),
    }
}

struct Dict {
    english: bool,
    table: HashMap<String, String>,
    /// Entri berpola ({} = teks apa saja), yang paling panjang dulu.
    patterns: Vec<(Vec<String>, String)>,
}

fn dict() -> &'static Dict {
    static D: OnceLock<Dict> = OnceLock::new();
    D.get_or_init(|| {
        let lang = match std::env::var("ZTERM_LANG").ok().filter(|l| l == "id" || l == "en") {
            Some(l) => l,
            None => match choice().as_str() {
                "id" => "id".into(),
                "en" => "en".into(),
                _ => {
                    let sys = ["LC_ALL", "LC_MESSAGES", "LANG", "LANGUAGE"].iter().find_map(|k| std::env::var(k).ok().filter(|v| !v.is_empty())).unwrap_or_default();
                    if sys.starts_with("id") || sys.starts_with("in_") { "id".into() } else { "en".into() }
                }
            },
        };
        let english = lang == "en";
        let table: HashMap<String, String> = if english { serde_json::from_str(EN_JSON).unwrap_or_default() } else { HashMap::new() };
        let mut patterns: Vec<(Vec<String>, String)> =
            table.iter().filter(|(k, _)| k.contains("{}")).map(|(k, v)| (k.split("{}").map(str::to_string).collect(), v.clone())).collect();
        patterns.sort_by_key(|(p, _)| std::cmp::Reverse(p.iter().map(String::len).sum::<usize>()));
        Dict { english, table, patterns }
    })
}

pub fn english() -> bool {
    dict().english
}

/// Teks UI dalam bahasa aktif (tanpa placeholder). Untuk `{}` pakai makro [`tr!`](crate::tr).
pub fn tr(s: &str) -> String {
    let d = dict();
    if d.english { d.table.get(s).cloned().unwrap_or_else(|| s.to_string()) } else { s.to_string() }
}

/// Isi `{}` berurutan.
pub fn fill(template: &str, args: &[String]) -> String {
    let mut out = String::with_capacity(template.len());
    let mut rest = template;
    let mut it = args.iter();
    while let Some(i) = rest.find("{}") {
        out.push_str(&rest[..i]);
        match it.next() {
            Some(a) => out.push_str(a),
            None => out.push_str("{}"),
        }
        rest = &rest[i + 2..];
    }
    out.push_str(rest);
    out
}

/// Cocokkan `s` dengan pola `parts` (dipisah `{}`); kembalikan isi tiap `{}`.
fn capture(parts: &[String], s: &str) -> Option<Vec<String>> {
    let first = parts.first()?;
    let last = parts.last()?;
    if !s.starts_with(first.as_str()) || !s.ends_with(last.as_str()) || s.len() < first.len() + last.len() {
        return None;
    }
    let mut pos = first.len();
    let end = s.len() - last.len();
    let mut caps = Vec::new();
    for mid in &parts[1..parts.len() - 1] {
        let at = s[pos..end].find(mid.as_str())? + pos;
        if at == pos {
            return None;
        }
        caps.push(s[pos..at].to_string());
        pos = at + mid.len();
    }
    if pos >= end {
        return None;
    }
    caps.push(s[pos..end].to_string());
    Some(caps)
}

/// Terjemahkan pesan utuh (mis. error dari core) memakai entri persis atau berpola.
pub fn msg(s: &str) -> String {
    let d = dict();
    if !d.english {
        return s.to_string();
    }
    if let Some(t) = matched(d, s) {
        return t;
    }
    // Huruf pertama pesan core kadang dinaikkan ("server tidak…" → "Server tidak…")
    let mut c = s.chars();
    if let Some(f) = c.next().filter(|f| f.is_uppercase()) {
        let lower: String = f.to_lowercase().chain(c).collect();
        if let Some(t) = matched(d, &lower) {
            let mut tc = t.chars();
            return tc.next().map(|f| f.to_uppercase().chain(tc).collect()).unwrap_or(t);
        }
    }
    s.to_string()
}

fn matched(d: &Dict, s: &str) -> Option<String> {
    if let Some(t) = d.table.get(s) {
        return Some(t.clone());
    }
    for (parts, out) in &d.patterns {
        if let Some(caps) = capture(parts, s) {
            let caps: Vec<String> = caps.iter().map(|c| msg(c)).collect();
            return Some(fill(out, &caps));
        }
    }
    None
}

/// `tr!("Backup {} selesai", name)` — teks UI dalam bahasa aktif, `{}` diisi berurutan.
#[macro_export]
macro_rules! tr {
    ($s:expr) => { $crate::i18n::tr($s) };
    ($s:expr, $($a:expr),+ $(,)?) => { $crate::i18n::fill(&$crate::i18n::tr($s), &[$(($a).to_string()),+]) };
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capture_and_fill() {
        let p: Vec<String> = "Koneksi SSH gagal: {}".split("{}").map(str::to_string).collect();
        assert_eq!(capture(&p, "Koneksi SSH gagal: timeout").unwrap(), vec!["timeout"]);
        let p: Vec<String> = "server tidak menjawab ({} detik)".split("{}").map(str::to_string).collect();
        assert_eq!(capture(&p, "server tidak menjawab (20 detik)").unwrap(), vec!["20"]);
        assert_eq!(fill("Backup {} finished · {}", &["A".into(), "9 MB".into()]), "Backup A finished · 9 MB");
    }
}

#[cfg(test)]
mod english_tests {
    #[test]
    fn core_messages_in_english() {
        // SAFETY: tes tunggal ini yang pertama memakai kamus di proses ini.
        unsafe { std::env::set_var("ZTERM_LANG", "en") };
        let m = super::msg;
        assert_eq!(m("Tiap 5 menit"), "Every 5 minutes");
        assert_eq!(m("Tiap hari pukul 02.30"), "Every day at 02:30");
        assert_eq!(m("Tiap Senin–Jumat pukul 08.00"), "Every Monday–Friday at 08:00");
        assert_eq!(m("Tiap 6 jam, menit ke-15"), "Every 6 hours at minute 15");
        assert_eq!(m("Tiap tanggal 1 pukul 03.00"), "On day 1 of every month at 03:00");
        assert_eq!(m("Koneksi SSH gagal: server tidak menjawab (20 detik)"), "SSH connection failed: server not responding (20 seconds)");
        assert_eq!(m("Server tidak menjawab (20 detik)"), "Server not responding (20 seconds)");
        assert_eq!(m("mysqldump tidak ditemukan di server — pasang mysql-client / mariadb-client"), "mysqldump not found on the server — install mysql-client / mariadb-client");
        assert_eq!(m("Master password salah"), "Wrong master password");
        assert_eq!(m("sesuatu yang tidak ada di kamus"), "sesuatu yang tidak ada di kamus");
    }
}
