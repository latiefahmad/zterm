#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum CoreError {
    #[error("Master password salah")]
    WrongPassword,
    #[error("Vault sudah ada")]
    AlreadyExists,
    #[error("Data tidak ditemukan")]
    NotFound,
    #[error("Password minimal 8 karakter")]
    WeakPassword,
    #[error("Vault di Google Drive memakai master password lain")]
    KeyMismatch,
    #[error("SSH key tidak valid: {msg}")]
    InvalidKey { msg: String },
    #[error("File vault rusak: {msg}")]
    Corrupt { msg: String },
    #[error("Koneksi SSH gagal: {msg}")]
    Ssh { msg: String },
    #[error("Proxy: {msg}")]
    Proxy { msg: String },
    #[error("Login ditolak server — periksa username, password, atau key")]
    AuthFailed,
    #[error("Kunci server berubah! Bisa jadi server diganti atau ada serangan man-in-the-middle. Hapus host ini di Known Hosts jika memang server berganti.")]
    HostKeyChanged,
    #[error("Database: {msg}")]
    Db { msg: String },
    #[error("Transfer dibatalkan")]
    Cancelled,
    #[error("Gagal membaca/menulis file: {msg}")]
    Io { msg: String },
    #[error("Sesi Google berakhir. Masuk lagi dengan Google untuk melanjutkan.")]
    GoogleAuth,
    #[error("Zterm belum diberi izin mengelola file Tim di Google Drive. Masuk ulang dengan Google lalu centang izin Google Drive.")]
    GoogleScope,
    #[error("Tim: {msg}")]
    Team { msg: String },
    #[error("{msg}")]
    Stack { msg: String },
    #[error("Docker: {msg}")]
    Docker { msg: String },
    #[error("{msg}")]
    Server { msg: String },
}

impl From<std::io::Error> for CoreError {
    fn from(e: std::io::Error) -> Self {
        CoreError::Io { msg: e.to_string() }
    }
}

impl From<serde_json::Error> for CoreError {
    fn from(e: serde_json::Error) -> Self {
        CoreError::Corrupt { msg: e.to_string() }
    }
}
