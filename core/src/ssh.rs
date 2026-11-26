//! Koneksi SSH native (russh) — dipakai SFTP sekarang, dan nanti terminal & tunnel database.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use russh::client::{self, Handle};
use russh::keys::agent::client::AgentClient;
use russh::keys::{HashAlg, PrivateKeyWithHashAlg, PublicKeyOrCertificate};

use crate::CoreError;

/// Data yang dibutuhkan untuk membuka sesi SSH ke satu host.
#[derive(Debug, Clone, uniffi::Record)]
pub struct SshTarget {
    pub hostname: String,
    pub port: u16,
    pub username: String,
    pub password: Option<String>,
    /// Private key format OpenSSH (isi file), jika login dengan key.
    pub private_key: Option<String>,
    pub passphrase: Option<String>,
    /// Coba SSH agent sistem (SSH_AUTH_SOCK).
    pub use_agent: bool,
    /// Sambung lewat proxy SOCKS5 / HTTP.
    pub proxy: Option<crate::model::HostProxy>,
}

/// Rincian konflik host key, dibawa ke UI supaya pengguna bisa membandingkan
/// fingerprint lama dan baru sebelum memutuskan mengganti key.
#[derive(Debug, Clone)]
struct KeyConflict {
    host: String,
    port: u16,
    old_fingerprint: String,
    new_fingerprint: String,
    old_key_type: String,
    new_key_type: String,
}

/// Handler russh: memverifikasi kunci server terhadap ~/.ssh/known_hosts.
/// Host baru dicatat otomatis (seperti `StrictHostKeyChecking=accept-new`);
/// kunci yang berubah ditolak.
pub struct Client {
    host: String,
    port: u16,
    conflict: Arc<std::sync::Mutex<Option<KeyConflict>>>,
}

impl client::Handler for Client {
    type Error = russh::Error;

    async fn check_server_key(&mut self, server_key: &PublicKeyOrCertificate) -> Result<bool, Self::Error> {
        let key = match server_key {
            PublicKeyOrCertificate::PublicKey { key, .. } => key,
            // Sertifikat host: terima (diverifikasi CA-nya oleh admin server).
            PublicKeyOrCertificate::Certificate(_) => return Ok(true),
        };
        // Pakai jalur yang sama dengan learn_host() supaya cek dan pencatatan
        // tidak pernah membaca dua file known_hosts yang berbeda.
        let Some(path) = known_hosts_path() else { return Ok(true) };
        match russh::keys::check_known_hosts_path(&self.host, self.port, key, &path) {
            Ok(true) => Ok(true),
            Ok(false) => {
                learn_host(&self.host, self.port, key);
                Ok(true)
            }
            Err(russh::keys::Error::KeyChanged { line }) => {
                let old = recorded_key_at(&self.host, self.port, line, &path);
                let conflict = KeyConflict {
                    host: self.host.clone(),
                    port: self.port,
                    old_fingerprint: old
                        .as_ref()
                        .map(|k| k.fingerprint(HashAlg::Sha256).to_string())
                        .unwrap_or_default(),
                    new_fingerprint: key.fingerprint(HashAlg::Sha256).to_string(),
                    old_key_type: old
                        .as_ref()
                        .map(|k| k.algorithm().as_str().to_string())
                        .unwrap_or_default(),
                    new_key_type: key.algorithm().as_str().to_string(),
                };
                if let Ok(mut slot) = self.conflict.lock() {
                    *slot = Some(conflict);
                }
                Ok(false)
            }
            // known_hosts tidak ada / tidak terbaca → catat host baru
            Err(_) => {
                learn_host(&self.host, self.port, key);
                Ok(true)
            }
        }
    }
}

/// Kunci lama pada baris known_hosts yang bentrok (nomor baris dari russh = 1-based).
fn recorded_key_at(
    host: &str,
    port: u16,
    line: usize,
    path: &std::path::Path,
) -> Option<russh::keys::PublicKey> {
    russh::keys::known_hosts::known_host_keys_path(host, port, path)
        .ok()?
        .into_iter()
        .find(|(n, _)| *n == line)
        .map(|(_, key)| key)
}

fn known_hosts_path() -> Option<PathBuf> {
    // Sama dengan OpenSSH: HOME lebih dulu (Git Bash/WSL), lalu %USERPROFILE% di Windows.
    std::env::var_os("HOME")
        .filter(|h| !h.is_empty())
        .or_else(|| std::env::var_os("USERPROFILE").filter(|h| !h.is_empty()))
        .map(|h| PathBuf::from(h).join(".ssh").join("known_hosts"))
}

/// Tambah baris ke known_hosts dengan format yang sama seperti OpenSSH.
fn learn_host(host: &str, port: u16, key: &russh::keys::PublicKey) {
    let Some(path) = known_hosts_path() else { return };
    let Ok(line) = key.to_openssh() else { return };
    let name = if port == 22 { host.to_string() } else { format!("[{host}]:{port}") };
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&path) {
        let _ = writeln!(f, "{name} {line}");
    }
}

fn ssh_err(e: impl std::fmt::Display) -> CoreError {
    CoreError::Ssh { msg: e.to_string() }
}

/// Buka koneksi SSH dan autentikasi: key → agent → password → keyboard-interactive.
/// Coba semua identitas di SSH agent. `true` jika salah satu diterima server.
async fn agent_auth<S>(h: &mut Handle<Client>, user: &str, mut agent: AgentClient<S>) -> Result<bool, CoreError>
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send + 'static,
{
    let Ok(ids) = agent.request_identities().await else { return Ok(false) };
    let hash = h.best_supported_rsa_hash().await.map_err(ssh_err)?.flatten();
    for id in ids {
        let pk = id.public_key().into_owned();
        if let Ok(res) = h.authenticate_publickey_with(user, pk, hash, &mut agent).await {
            if res.success() {
                return Ok(true);
            }
        }
    }
    Ok(false)
}

pub async fn connect(t: &SshTarget) -> Result<Handle<Client>, CoreError> {
    let config = Arc::new(client::Config {
        inactivity_timeout: None,
        keepalive_interval: Some(Duration::from_secs(30)),
        keepalive_max: 4,
        ..Default::default()
    });
    let conflict = Arc::new(std::sync::Mutex::new(None));
    let handler = Client { host: t.hostname.clone(), port: t.port, conflict: conflict.clone() };

    let connecting = async {
        match &t.proxy {
            Some(p) => {
                let stream = crate::proxy::open(p, &t.hostname, t.port).await.map_err(Err)?;
                client::connect_stream(config, stream, handler).await.map_err(Ok)
            }
            None => client::connect(config, (t.hostname.as_str(), t.port), handler).await.map_err(Ok),
        }
    };
    let mut h = match tokio::time::timeout(Duration::from_secs(30), connecting).await {
        Err(_) => return Err(CoreError::Ssh { msg: "waktu koneksi habis (30 detik)".into() }),
        // Gagal di proxy: teruskan pesan proxy apa adanya
        Ok(Err(Err(e))) => return Err(e),
        Ok(Err(Ok(e))) => {
            if let Some(c) = conflict.lock().ok().and_then(|mut slot| slot.take()) {
                return Err(CoreError::HostKeyChanged {
                    host: c.host,
                    port: c.port,
                    old_fingerprint: c.old_fingerprint,
                    new_fingerprint: c.new_fingerprint,
                    old_key_type: c.old_key_type,
                    new_key_type: c.new_key_type,
                });
            }
            return Err(ssh_err(e));
        }
        Ok(Ok(h)) => h,
    };

    let user = t.username.clone();

    // 1. Private key dari Keychain Zterm
    if let Some(pem) = t.private_key.as_deref().filter(|p| !p.trim().is_empty()) {
        let key = russh::keys::decode_secret_key(pem, t.passphrase.as_deref().filter(|p| !p.is_empty()))
            .map_err(|e| CoreError::InvalidKey { msg: e.to_string() })?;
        let hash = h.best_supported_rsa_hash().await.map_err(ssh_err)?.flatten();
        let res = h
            .authenticate_publickey(&user, PrivateKeyWithHashAlg::new(Arc::new(key), hash))
            .await
            .map_err(ssh_err)?;
        if res.success() {
            return Ok(h);
        }
    }

    // 2. SSH agent sistem
    if t.use_agent {
        // macOS/Linux: $SSH_AUTH_SOCK
        #[cfg(unix)]
        if let Ok(agent) = AgentClient::connect_env().await {
            if agent_auth(&mut h, &user, agent).await? {
                return Ok(h);
            }
        }
        // Windows: agent OpenSSH (named pipe), lalu Pageant (PuTTY)
        #[cfg(windows)]
        {
            if let Ok(agent) = AgentClient::connect_named_pipe(r"\\.\pipe\openssh-ssh-agent").await {
                if agent_auth(&mut h, &user, agent).await? {
                    return Ok(h);
                }
            }
            if let Ok(agent) = AgentClient::connect_pageant().await {
                if agent_auth(&mut h, &user, agent).await? {
                    return Ok(h);
                }
            }
        }
    }

    // 3. Password, lalu keyboard-interactive dengan password yang sama
    if let Some(pw) = t.password.as_deref().filter(|p| !p.is_empty()) {
        if h.authenticate_password(&user, pw).await.map_err(ssh_err)?.success() {
            return Ok(h);
        }
        use russh::client::KeyboardInteractiveAuthResponse as K;
        let mut resp = h.authenticate_keyboard_interactive_start(&user, None::<String>).await.map_err(ssh_err)?;
        for _ in 0..3 {
            match resp {
                K::Success => return Ok(h),
                K::Failure { .. } => break,
                K::InfoRequest { prompts, .. } => {
                    let answers = prompts.iter().map(|_| pw.to_string()).collect();
                    resp = h.authenticate_keyboard_interactive_respond(answers).await.map_err(ssh_err)?;
                }
            }
        }
    }

    Err(CoreError::AuthFailed)
}

/// Hapus semua key untuk satu host dari `~/.ssh/known_hosts`.
///
/// Dipakai tombol "Ganti key" setelah pengguna membandingkan fingerprint lama
/// dan baru. Entri ter-hash ikut dikenali (russh memakai HMAC-SHA1 yang sama
/// seperti OpenSSH), dan salinan lama disimpan sebagai `known_hosts.old`.
#[uniffi::export]
pub fn forget_known_host(host: String, port: u16) -> Result<u32, CoreError> {
    let host = host.trim();
    if host.is_empty() {
        return Ok(0);
    }
    let Some(path) = known_hosts_path() else { return Ok(0) };
    forget_known_host_at(host, port, &path)
}

fn forget_known_host_at(host: &str, port: u16, path: &std::path::Path) -> Result<u32, CoreError> {
    // Nomor baris dari russh memakai hitungan yang melewati baris komentar,
    // jadi penghapusan mengikuti hitungan yang sama agar tidak salah baris.
    let lines: std::collections::HashSet<usize> =
        match russh::keys::known_hosts::known_host_keys_path(host, port, path) {
            Ok(keys) => keys.into_iter().map(|(line, _)| line).collect(),
            Err(e) => return Err(CoreError::Io { msg: e.to_string() }),
        };
    if lines.is_empty() {
        return Ok(0);
    }

    let data = std::fs::read_to_string(path).map_err(|e| CoreError::Io { msg: e.to_string() })?;
    let mut kept = String::with_capacity(data.len());
    let mut logical = 1usize;
    for line in data.split_inclusive('\n') {
        if line.starts_with('#') {
            kept.push_str(line);
            continue;
        }
        if !lines.contains(&logical) {
            kept.push_str(line);
        }
        logical += 1;
    }

    let backup = path.with_file_name("known_hosts.old");
    std::fs::copy(path, &backup).map_err(|e| CoreError::Io { msg: e.to_string() })?;
    std::fs::write(path, kept).map_err(|e| CoreError::Io { msg: e.to_string() })?;
    Ok(lines.len() as u32)
}

#[cfg(test)]
mod tests {
    use super::forget_known_host_at;

    const KEY_A: &str = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILagOJFgwaMNhBWQINinKOXmqS4Gh5NgxgriXwdOoINJ";
    const KEY_B: &str = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJdD7y3aLq454yWBdwLWbieU1ebz9/cu7/QEXn9OIeZJ";

    fn temp_file() -> (std::path::PathBuf, std::path::PathBuf) {
        let dir = std::env::temp_dir().join(format!("zterm-known-hosts-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("known_hosts");
        (dir, path)
    }

    #[test]
    fn forget_removes_all_keys_for_one_host() {
        let (dir, path) = temp_file();
        std::fs::write(
            &path,
            format!("example.com {KEY_A}\nexample.com {KEY_B}\nother.com {KEY_A}\n"),
        )
        .unwrap();

        let removed = forget_known_host_at("example.com", 22, &path).unwrap();

        assert_eq!(removed, 2);
        assert_eq!(std::fs::read_to_string(&path).unwrap(), format!("other.com {KEY_A}\n"));
        assert!(dir.join("known_hosts.old").exists());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn forget_handles_non_default_port() {
        let (dir, path) = temp_file();
        std::fs::write(
            &path,
            format!("[example.com]:2222 {KEY_A}\nexample.com {KEY_B}\n"),
        )
        .unwrap();

        let removed = forget_known_host_at("example.com", 2222, &path).unwrap();

        assert_eq!(removed, 1);
        assert_eq!(std::fs::read_to_string(&path).unwrap(), format!("example.com {KEY_B}\n"));
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn forget_keeps_comments_and_other_hosts() {
        let (dir, path) = temp_file();
        std::fs::write(
            &path,
            format!("# komentar\nexample.com {KEY_A}\n# komentar lain\nother.com {KEY_B}\n"),
        )
        .unwrap();

        let removed = forget_known_host_at("example.com", 22, &path).unwrap();

        assert_eq!(removed, 1);
        assert_eq!(
            std::fs::read_to_string(&path).unwrap(),
            format!("# komentar\n# komentar lain\nother.com {KEY_B}\n")
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn forget_missing_host_is_noop() {
        let (dir, path) = temp_file();
        std::fs::write(&path, format!("other.com {KEY_A}\n")).unwrap();

        assert_eq!(forget_known_host_at("example.com", 22, &path).unwrap(), 0);
        assert!(!dir.join("known_hosts.old").exists());
        std::fs::remove_dir_all(dir).unwrap();
    }
}
