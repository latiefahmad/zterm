//! Lokasi file app di Linux (mengikuti XDG).

use std::path::{Path, PathBuf};

pub const APP_ID: &str = "com.latiefahmad.zterm";

/// `~/.local/share/zterm` (di Flatpak: `~/.var/app/<id>/data/zterm`).
pub fn data_dir() -> PathBuf {
    let base = std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .unwrap_or_else(|| home().join(".local/share"));
    let dir = base.join("zterm");
    let _ = std::fs::create_dir_all(&dir);
    set_mode(&dir, 0o700);
    dir
}

pub fn vault_path() -> String {
    data_dir().join("vault.zterm").to_string_lossy().into_owned()
}

pub fn home() -> PathBuf {
    std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/"))
}

/// Berjalan di dalam sandbox Flatpak: ssh & shell dijalankan di host lewat `flatpak-spawn --host`.
pub fn in_flatpak() -> bool {
    Path::new("/.flatpak-info").exists()
}

pub fn set_mode(path: &Path, mode: u32) {
    use std::os::unix::fs::PermissionsExt;
    let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode));
}

/// Nama pengguna lokal (untuk tab terminal lokal).
pub fn user_name() -> String {
    std::env::var("USER").unwrap_or_else(|_| "user".into())
}
