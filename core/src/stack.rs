//! Server Lokal: web server (Apache / Nginx + PHP) dan database lokal (MySQL, PostgreSQL, MongoDB)
//! seperti MAMP / XAMPP. Komponen diunduh saat dibutuhkan ke folder data app, lalu dijalankan
//! sebagai proses anak yang hanya mendengarkan di 127.0.0.1.
//!
//! Struktur folder (`root`):
//! ```text
//! apps/<id>/      binari terpasang (+ .zterm-version)
//! data/<id>/      data database (tidak terhapus saat komponen dihapus)
//! conf/ logs/ run/ (pid & socket) downloads/
//! settings.json
//! ```
//! Daftar unduhan bawaan bisa ditimpa `stack.json` di website (agar link yang berubah bisa diperbaiki
//! tanpa rilis app baru).

use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::Write;
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde::{Deserialize, Serialize};

use crate::sftp::TransferProgress;
use crate::CoreError;

const REMOTE_MANIFEST: &str = "https://latiefahmad.github.io/zterm/stack.json";
const PHP_PORT: u16 = 9074;

fn err(msg: impl Into<String>) -> CoreError {
    CoreError::Stack { msg: msg.into() }
}

// ---------- Katalog unduhan ----------

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Download {
    id: String,
    platform: String,
    version: String,
    url: String,
    /// "targz" | "zip" | "bin" | "jar-txz"
    format: String,
    /// Perkiraan ukuran unduhan (MB), untuk ditampilkan sebelum mengunduh.
    size_mb: u32,
    /// Subfolder berisi program setelah diekstrak (kosong = otomatis).
    #[serde(default)]
    home: String,
}

fn platform() -> &'static str {
    if cfg!(target_os = "macos") {
        if cfg!(target_arch = "aarch64") { "macos-aarch64" } else { "macos-x86_64" }
    } else {
        // Windows ARM menjalankan binari x64 lewat emulasi.
        "windows-x86_64"
    }
}

fn builtin_manifest() -> Vec<Download> {
    let d = |id: &str, platform: &str, version: &str, url: &str, format: &str, size_mb: u32, home: &str| Download {
        id: id.into(), platform: platform.into(), version: version.into(), url: url.into(), format: format.into(), size_mb, home: home.into(),
    };
    vec![
        d("nginx", "macos-aarch64", "1.30.5", "https://jirutka.github.io/nginx-binaries/nginx-1.30.5-arm64-darwin", "bin", 7, ""),
        d("nginx", "macos-x86_64", "1.30.5", "https://jirutka.github.io/nginx-binaries/nginx-1.30.5-x86_64-darwin", "bin", 7, ""),
        d("nginx", "windows-x86_64", "1.28.0", "https://nginx.org/download/nginx-1.28.0.zip", "zip", 2, ""),
        d("apache", "windows-x86_64", "2.4.71", "https://www.apachelounge.com/download/VS18/binaries/httpd-2.4.71-261112-Win64-VS18.zip", "zip", 14, "Apache24"),
        d("php", "macos-aarch64", "8.4.8", "https://dl.static-php.dev/static-php-cli/common/php-8.4.8-fpm-macos-aarch64.tar.gz", "targz", 10, ""),
        d("php", "macos-x86_64", "8.4.8", "https://dl.static-php.dev/static-php-cli/common/php-8.4.8-fpm-macos-x86_64.tar.gz", "targz", 10, ""),
        d("php", "windows-x86_64", "8.4.8", "https://windows.php.net/downloads/releases/archives/php-8.4.8-nts-Win32-vs17-x64.zip", "zip", 33, ""),
        d("mysql", "macos-aarch64", "8.4.6", "https://cdn.mysql.com/archives/mysql-8.4/mysql-8.4.6-macos15-arm64.tar.gz", "targz", 160, ""),
        d("mysql", "macos-x86_64", "8.4.6", "https://cdn.mysql.com/archives/mysql-8.4/mysql-8.4.6-macos15-x86_64.tar.gz", "targz", 165, ""),
        d("mysql", "windows-x86_64", "8.4.6", "https://cdn.mysql.com/archives/mysql-8.4/mysql-8.4.6-winx64.zip", "zip", 260, ""),
        d("postgres", "macos-aarch64", "17.12", "https://repo1.maven.org/maven2/io/zonky/test/postgres/embedded-postgres-binaries-darwin-arm64v8/17.12.0/embedded-postgres-binaries-darwin-arm64v8-17.12.0.jar", "jar-txz", 60, ""),
        d("postgres", "macos-x86_64", "17.12", "https://repo1.maven.org/maven2/io/zonky/test/postgres/embedded-postgres-binaries-darwin-amd64/17.12.0/embedded-postgres-binaries-darwin-amd64-17.12.0.jar", "jar-txz", 60, ""),
        d("postgres", "windows-x86_64", "17.12", "https://repo1.maven.org/maven2/io/zonky/test/postgres/embedded-postgres-binaries-windows-amd64/17.12.0/embedded-postgres-binaries-windows-amd64-17.12.0.jar", "jar-txz", 55, ""),
        d("mongodb", "macos-aarch64", "8.0.4", "https://fastdl.mongodb.org/osx/mongodb-macos-arm64-8.0.4.tgz", "targz", 80, ""),
        d("mongodb", "macos-x86_64", "8.0.4", "https://fastdl.mongodb.org/osx/mongodb-macos-x86_64-8.0.4.tgz", "targz", 85, ""),
        d("mongodb", "windows-x86_64", "8.0.4", "https://fastdl.mongodb.org/windows/mongodb-windows-x86_64-8.0.4.zip", "zip", 75, ""),
    ]
}

/// Apache bawaan macOS dipakai langsung (tidak perlu diunduh).
const MAC_HTTPD: &str = "/usr/sbin/httpd";

// ---------- Tipe untuk UI ----------

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum StackState {
    /// Belum diunduh.
    NotInstalled,
    Installing,
    Stopped,
    Running,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct StackComponent {
    /// apache | nginx | php | mysql | postgres | mongodb
    pub id: String,
    pub name: String,
    pub version: String,
    pub state: StackState,
    /// Perkiraan ukuran unduhan (MB); 0 = bawaan sistem.
    pub size_mb: u32,
    /// Bawaan sistem (Apache di macOS) — tidak perlu diunduh.
    pub system: bool,
    /// Tersedia untuk OS ini.
    pub available: bool,
}

/// Layanan yang bisa dinyalakan: web | mysql | postgres | mongodb.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct StackService {
    pub id: String,
    pub running: bool,
    pub port: u16,
    /// Komponen yang perlu diunduh dulu (kosong = siap dijalankan).
    pub missing: Vec<String>,
    pub error: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct StackSettings {
    /// "apache" | "nginx"
    pub web_server: String,
    pub web_port: u16,
    pub doc_root: String,
    pub mysql_port: u16,
    pub postgres_port: u16,
    pub mongodb_port: u16,
}

fn home_dir() -> PathBuf {
    std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" }).map(PathBuf::from).unwrap_or_else(std::env::temp_dir)
}

impl Default for StackSettings {
    fn default() -> Self {
        Self {
            web_server: if cfg!(target_os = "macos") { "apache".into() } else { "nginx".into() },
            web_port: 8080,
            doc_root: home_dir().join("Sites").to_string_lossy().into_owned(),
            mysql_port: 3306,
            postgres_port: 5432,
            mongodb_port: 27017,
        }
    }
}

// ---------- LocalStack ----------

struct Inner {
    /// Proses yang berjalan per layanan (web = php + server).
    procs: HashMap<String, Vec<Child>>,
    installing: HashSet<String>,
    errors: HashMap<String, String>,
    settings: StackSettings,
    manifest: Vec<Download>,
}

#[derive(uniffi::Object)]
pub struct LocalStack {
    root: PathBuf,
    inner: Mutex<Inner>,
}

#[uniffi::export(async_runtime = "tokio")]
impl LocalStack {
    /// `root` = folder data Server Lokal (mis. `~/Library/Application Support/Zterm/stack`).
    #[uniffi::constructor]
    pub fn new(root: String) -> Result<Arc<Self>, CoreError> {
        let root = PathBuf::from(root);
        for d in ["apps", "data", "conf", "logs", "run", "downloads"] {
            fs::create_dir_all(root.join(d))?;
        }
        let settings = fs::read(root.join("settings.json"))
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default();
        let s = Arc::new(Self {
            root,
            inner: Mutex::new(Inner {
                procs: HashMap::new(),
                installing: HashSet::new(),
                errors: HashMap::new(),
                settings,
                manifest: builtin_manifest(),
            }),
        });
        s.kill_stale();
        Ok(s)
    }

    pub fn settings(&self) -> StackSettings {
        self.inner.lock().unwrap().settings.clone()
    }

    pub fn set_settings(&self, settings: StackSettings) -> Result<(), CoreError> {
        if !matches!(settings.web_server.as_str(), "apache" | "nginx") {
            return Err(err("web server harus apache atau nginx"));
        }
        fs::write(self.root.join("settings.json"), serde_json::to_vec_pretty(&settings)?)?;
        self.inner.lock().unwrap().settings = settings;
        Ok(())
    }

    /// Semua komponen untuk OS ini beserta statusnya.
    pub fn components(&self) -> Vec<StackComponent> {
        let inner = self.inner.lock().unwrap();
        let names = [
            ("apache", "Apache"), ("nginx", "Nginx"), ("php", "PHP"),
            ("mysql", "MySQL"), ("postgres", "PostgreSQL"), ("mongodb", "MongoDB"),
        ];
        names
            .iter()
            .map(|(id, name)| {
                let system = *id == "apache" && cfg!(target_os = "macos");
                let dl = inner.manifest.iter().find(|d| d.id == *id && d.platform == platform());
                let installed = self.installed_version(id);
                let running = inner.procs.contains_key(service_of(id));
                StackComponent {
                    id: id.to_string(),
                    name: name.to_string(),
                    version: if system { mac_httpd_version() } else { installed.clone().or(dl.map(|d| d.version.clone())).unwrap_or_default() },
                    state: if inner.installing.contains(*id) {
                        StackState::Installing
                    } else if !system && installed.is_none() {
                        StackState::NotInstalled
                    } else if running {
                        StackState::Running
                    } else {
                        StackState::Stopped
                    },
                    size_mb: if system { 0 } else { dl.map_or(0, |d| d.size_mb) },
                    system,
                    available: system || dl.is_some(),
                }
            })
            .collect()
    }

    /// Status layanan (web, mysql, postgres, mongodb).
    pub fn services(&self) -> Vec<StackService> {
        let mut inner = self.inner.lock().unwrap();
        // Bersihkan proses yang sudah berhenti sendiri (crash / port bentrok).
        let dead: Vec<String> = inner
            .procs
            .iter_mut()
            .filter_map(|(k, ps)| ps.iter_mut().any(|p| !matches!(p.try_wait(), Ok(None))).then(|| k.clone()))
            .collect();
        for k in dead {
            if let Some(mut ps) = inner.procs.remove(&k) {
                for p in ps.iter_mut() {
                    kill_child(p);
                }
                let _ = fs::remove_file(self.root.join("run").join(format!("{k}.pids")));
                inner.errors.entry(k.clone()).or_insert_with(|| format!("{} berhenti tiba-tiba — lihat log", service_name(&k)));
            }
        }
        let s = inner.settings.clone();
        ["web", "mysql", "postgres", "mongodb"]
            .iter()
            .map(|id| StackService {
                id: id.to_string(),
                running: inner.procs.contains_key(*id),
                port: match *id { "web" => s.web_port, "mysql" => s.mysql_port, "postgres" => s.postgres_port, _ => s.mongodb_port },
                missing: self.missing_for(id, &s),
                error: inner.errors.get(*id).cloned(),
            })
            .collect()
    }

    /// Unduh & pasang komponen. `progress.is_cancelled()` membatalkan unduhan.
    pub async fn install(&self, id: String, progress: Arc<dyn TransferProgress>) -> Result<(), CoreError> {
        let dl = {
            let mut inner = self.inner.lock().unwrap();
            if !inner.installing.insert(id.clone()) {
                return Err(err("komponen ini sedang diunduh"));
            }
            inner.manifest.iter().find(|d| d.id == id && d.platform == platform()).cloned()
        };
        let result = async {
            let dl = match remote_override(&id).await.or(dl) {
                Some(d) => d,
                None => return Err(err(format!("{id} belum tersedia untuk sistem ini"))),
            };
            let file = self.root.join("downloads").join(format!("{id}-{}.part", dl.version));
            download(&dl.url, &file, &id, progress.clone()).await?;
            progress.on_progress(1, 1, format!("Memasang {id}…"));
            let root = self.root.clone();
            let id2 = id.clone();
            tokio::task::spawn_blocking(move || install_archive(&root, &id2, &dl, &file))
                .await
                .map_err(|e| err(e.to_string()))?
        }
        .await;
        self.inner.lock().unwrap().installing.remove(&id);
        result
    }

    /// Hapus program komponen (data database tetap disimpan).
    pub fn uninstall(&self, id: String) -> Result<(), CoreError> {
        let svc = service_of(&id).to_string();
        if self.inner.lock().unwrap().procs.contains_key(&svc) {
            return Err(err(format!("hentikan {} dulu", service_name(&svc))));
        }
        let dir = self.root.join("apps").join(&id);
        if dir.exists() {
            fs::remove_dir_all(dir)?;
        }
        Ok(())
    }

    /// Nyalakan layanan: web | mysql | postgres | mongodb.
    pub async fn start(&self, service: String) -> Result<(), CoreError> {
        let settings = {
            let mut inner = self.inner.lock().unwrap();
            if inner.procs.contains_key(&service) {
                return Ok(());
            }
            inner.errors.remove(&service);
            inner.settings.clone()
        };
        let missing = self.missing_for(&service, &settings);
        if !missing.is_empty() {
            return Err(err(format!("unduh dulu: {}", missing.join(", "))));
        }
        let me = StackRef { root: self.root.clone() };
        let svc = service.clone();
        let result = tokio::task::spawn_blocking(move || me.start_blocking(&svc, &settings))
            .await
            .map_err(|e| err(e.to_string()))?;
        match result {
            Ok(children) => {
                self.inner.lock().unwrap().procs.insert(service, children);
                Ok(())
            }
            Err(e) => {
                self.inner.lock().unwrap().errors.insert(service, e.to_string());
                Err(e)
            }
        }
    }

    pub async fn stop(&self, service: String) -> Result<(), CoreError> {
        let procs = self.inner.lock().unwrap().procs.remove(&service);
        let settings = self.settings();
        if let Some(children) = procs {
            let me = StackRef { root: self.root.clone() };
            tokio::task::spawn_blocking(move || me.stop_blocking(&service, children, &settings))
                .await
                .map_err(|e| err(e.to_string()))?;
        }
        Ok(())
    }

    /// Hentikan semua layanan (dipanggil saat app ditutup).
    pub fn stop_all(&self) {
        let all: Vec<(String, Vec<Child>)> = self.inner.lock().unwrap().procs.drain().collect();
        let settings = self.settings();
        let me = StackRef { root: self.root.clone() };
        for (svc, children) in all {
            me.stop_blocking(&svc, children, &settings);
        }
    }

    /// Baris terakhir log layanan.
    pub fn log_tail(&self, service: String, lines: u32) -> String {
        let files: Vec<&str> = match service.as_str() {
            "web" => vec!["php.log", "web.log", "apache-error.log", "nginx-error.log"],
            "mysql" => vec!["mysql.log"],
            "postgres" => vec!["postgres.log"],
            _ => vec!["mongodb.log"],
        };
        let mut out = String::new();
        for f in files {
            if let Ok(text) = fs::read_to_string(self.root.join("logs").join(f)) {
                let tail: Vec<&str> = text.lines().rev().take(lines as usize).collect();
                if !tail.is_empty() {
                    out.push_str(&format!("── {f}\n"));
                    for l in tail.into_iter().rev() {
                        out.push_str(l);
                        out.push('\n');
                    }
                }
            }
        }
        out
    }

    /// Folder log & data, untuk tombol "Buka folder".
    pub fn root_path(&self) -> String {
        self.root.to_string_lossy().into_owned()
    }

    /// Windows: komponen (Apache, PHP, MySQL) butuh Microsoft Visual C++ Runtime.
    pub fn needs_vc_runtime(&self) -> bool {
        if !cfg!(windows) {
            return false;
        }
        let sys = std::env::var_os("SystemRoot").map(PathBuf::from).unwrap_or_else(|| PathBuf::from(r"C:\Windows")).join("System32");
        !(sys.join("vcruntime140.dll").exists() && sys.join("msvcp140.dll").exists() && sys.join("vcruntime140_1.dll").exists())
    }
}

fn service_of(component: &str) -> &str {
    match component {
        "apache" | "nginx" | "php" => "web",
        other => other,
    }
}

fn service_name(service: &str) -> &str {
    match service {
        "web" => "Web server",
        "mysql" => "MySQL",
        "postgres" => "PostgreSQL",
        _ => "MongoDB",
    }
}

fn mac_httpd_version() -> String {
    Command::new(MAC_HTTPD)
        .arg("-v")
        .output()
        .ok()
        .and_then(|o| {
            let s = String::from_utf8_lossy(&o.stdout).to_string();
            s.split("Apache/").nth(1).map(|v| v.split_whitespace().next().unwrap_or("").to_string())
        })
        .unwrap_or_else(|| "bawaan macOS".into())
}

// ---------- Unduh & ekstrak ----------

async fn remote_override(id: &str) -> Option<Download> {
    let client = reqwest::Client::builder().timeout(Duration::from_secs(4)).build().ok()?;
    let body = client.get(REMOTE_MANIFEST).send().await.ok()?.bytes().await.ok()?;
    let list: Vec<Download> = serde_json::from_slice(&body).ok()?;
    list.into_iter().find(|d| d.id == id && d.platform == platform())
}

async fn download(url: &str, file: &Path, id: &str, progress: Arc<dyn TransferProgress>) -> Result<(), CoreError> {
    let client = reqwest::Client::builder()
        .user_agent("curl/8 (Zterm)")
        .connect_timeout(Duration::from_secs(20))
        .build()
        .map_err(|e| err(e.to_string()))?;
    let resp = client.get(url).send().await.map_err(|e| err(format!("gagal mengunduh {id}: {e}")))?;
    if !resp.status().is_success() {
        return Err(err(format!("gagal mengunduh {id}: HTTP {}", resp.status().as_u16())));
    }
    let total = resp.content_length().unwrap_or(0);
    let mut out = fs::File::create(file)?;
    let mut done = 0u64;
    let mut resp = resp;
    let label = format!("Mengunduh {id}");
    while let Some(chunk) = resp.chunk().await.transpose() {
        if progress.is_cancelled() {
            drop(out);
            let _ = fs::remove_file(file);
            return Err(CoreError::Cancelled);
        }
        let chunk = chunk.map_err(|e| err(format!("unduhan {id} terputus: {e}")))?;
        out.write_all(&chunk)?;
        done += chunk.len() as u64;
        progress.on_progress(done, total.max(done), label.clone());
    }
    out.flush()?;
    // Server yang mengembalikan halaman HTML (link mati / diblokir) bukan arsip.
    if done < 200_000 {
        let _ = fs::remove_file(file);
        return Err(err(format!("file {id} dari server tidak valid (link mungkin sudah berubah)")));
    }
    Ok(())
}

fn install_archive(root: &Path, id: &str, dl: &Download, file: &Path) -> Result<(), CoreError> {
    let tmp = root.join("apps").join(format!("{id}.tmp"));
    let _ = fs::remove_dir_all(&tmp);
    fs::create_dir_all(&tmp)?;
    let res = (|| -> Result<(), CoreError> {
        match dl.format.as_str() {
            "bin" => {
                let name = if cfg!(windows) { format!("{id}.exe") } else { id.to_string() };
                fs::copy(file, tmp.join(&name))?;
                make_executable(&tmp.join(name));
            }
            "targz" => {
                let gz = flate2::read::GzDecoder::new(fs::File::open(file)?);
                let mut ar = tar::Archive::new(gz);
                ar.set_preserve_permissions(true);
                ar.unpack(&tmp).map_err(|e| err(format!("gagal mengekstrak {id}: {e}")))?;
            }
            "zip" => unzip(file, &tmp)?,
            "jar-txz" => {
                let mut jar = zip::ZipArchive::new(fs::File::open(file)?).map_err(|e| err(e.to_string()))?;
                let name = (0..jar.len())
                    .filter_map(|i| jar.by_index(i).ok().map(|f| f.name().to_string()))
                    .find(|n| n.ends_with(".txz"))
                    .ok_or_else(|| err("arsip PostgreSQL tidak berisi .txz"))?;
                let tar_path = tmp.with_extension("tar");
                {
                    let entry = jar.by_name(&name).map_err(|e| err(e.to_string()))?;
                    let mut input = std::io::BufReader::new(entry);
                    let mut out = std::io::BufWriter::new(fs::File::create(&tar_path)?);
                    lzma_rs::xz_decompress(&mut input, &mut out).map_err(|e| err(format!("gagal membuka arsip PostgreSQL: {e:?}")))?;
                }
                let mut ar = tar::Archive::new(fs::File::open(&tar_path)?);
                ar.set_preserve_permissions(true);
                ar.unpack(&tmp).map_err(|e| err(format!("gagal mengekstrak {id}: {e}")))?;
                let _ = fs::remove_file(tar_path);
            }
            f => return Err(err(format!("format arsip {f} tidak dikenal"))),
        }
        Ok(())
    })();
    let _ = fs::remove_file(file);
    if let Err(e) = res {
        let _ = fs::remove_dir_all(&tmp);
        return Err(e);
    }
    // Ambil folder program: `home` dari katalog, atau satu-satunya folder teratas.
    let mut home = if dl.home.is_empty() { tmp.clone() } else { tmp.join(&dl.home) };
    if dl.home.is_empty() {
        let entries: Vec<PathBuf> = fs::read_dir(&tmp)?.filter_map(|e| e.ok().map(|e| e.path())).collect();
        if entries.len() == 1 && entries[0].is_dir() {
            home = entries[0].clone();
        }
    }
    let dest = root.join("apps").join(id);
    let _ = fs::remove_dir_all(&dest);
    fs::rename(&home, &dest)?;
    let _ = fs::remove_dir_all(&tmp);
    fs::write(dest.join(".zterm-version"), &dl.version)?;
    Ok(())
}

fn unzip(file: &Path, dest: &Path) -> Result<(), CoreError> {
    let mut z = zip::ZipArchive::new(fs::File::open(file)?).map_err(|e| err(format!("arsip zip rusak: {e}")))?;
    for i in 0..z.len() {
        let mut f = z.by_index(i).map_err(|e| err(e.to_string()))?;
        let Some(rel) = f.enclosed_name() else { continue };
        let out = dest.join(rel);
        if f.is_dir() {
            fs::create_dir_all(&out)?;
            continue;
        }
        if let Some(p) = out.parent() {
            fs::create_dir_all(p)?;
        }
        let mut w = fs::File::create(&out)?;
        std::io::copy(&mut f, &mut w)?;
        #[cfg(unix)]
        if let Some(mode) = f.unix_mode() {
            use std::os::unix::fs::PermissionsExt;
            let _ = fs::set_permissions(&out, fs::Permissions::from_mode(mode));
        }
    }
    Ok(())
}

fn make_executable(_p: &Path) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(_p, fs::Permissions::from_mode(0o755));
    }
}

// ---------- Menjalankan layanan ----------

fn exe(name: &str) -> String {
    if cfg!(windows) { format!("{name}.exe") } else { name.to_string() }
}

/// Path untuk file konfigurasi (Windows: garis miring maju agar aman di nginx/Apache).
fn cfg_path(p: &Path) -> String {
    p.to_string_lossy().replace('\\', "/")
}

fn port_free(port: u16) -> bool {
    TcpListener::bind(("127.0.0.1", port)).is_ok()
}

fn port_open(port: u16) -> bool {
    TcpStream::connect_timeout(&([127, 0, 0, 1], port).into(), Duration::from_millis(300)).is_ok()
}

impl LocalStack {
    fn installed_version(&self, id: &str) -> Option<String> {
        fs::read_to_string(self.root.join("apps").join(id).join(".zterm-version")).ok().map(|s| s.trim().to_string())
    }

    fn missing_for(&self, service: &str, s: &StackSettings) -> Vec<String> {
        let need: Vec<&str> = match service {
            "web" => vec![s.web_server.as_str(), "php"],
            other => vec![other],
        };
        need.into_iter()
            .filter(|id| !(*id == "apache" && cfg!(target_os = "macos") && Path::new(MAC_HTTPD).exists()))
            .filter(|id| self.installed_version(id).is_none())
            .map(str::to_string)
            .collect()
    }

    /// Matikan proses sisa dari sesi sebelumnya (app ditutup paksa / crash).
    fn kill_stale(&self) {
        let Ok(rd) = fs::read_dir(self.root.join("run")) else { return };
        for e in rd.flatten() {
            let p = e.path();
            if p.extension().and_then(|x| x.to_str()) != Some("pids") {
                continue;
            }
            for line in fs::read_to_string(&p).unwrap_or_default().lines() {
                let mut it = line.split(':');
                if let (Some(name), Some(Ok(pid))) = (it.next(), it.next().map(|p| p.trim().parse::<u32>())) {
                    if pid_alive(pid) && process_name_matches(pid, name) {
                        kill_pid(pid, false);
                    }
                }
            }
            let _ = fs::remove_file(p);
        }
    }
}

/// Bagian yang dipakai di thread terpisah (tanpa lock).
struct StackRef {
    root: PathBuf,
}

impl StackRef {
    fn app(&self, id: &str) -> PathBuf {
        self.root.join("apps").join(id)
    }
    fn log(&self, name: &str) -> PathBuf {
        self.root.join("logs").join(name)
    }

    fn spawn(&self, cmd: &mut Command, log: &str) -> Result<Child, CoreError> {
        let out = fs::OpenOptions::new().create(true).append(true).open(self.log(log))?;
        cmd.stdin(Stdio::null()).stdout(out.try_clone()?).stderr(out);
        hide_window(cmd);
        // Grup proses sendiri: worker php-fpm / nginx / httpd ikut berhenti saat grupnya dimatikan.
        #[cfg(unix)]
        {
            use std::os::unix::process::CommandExt;
            cmd.process_group(0);
        }
        cmd.spawn().map_err(|e| err(format!("gagal menjalankan {:?}: {e}", cmd.get_program())))
    }

    /// Jalankan perintah sampai selesai (init database, dsb.).
    fn run(&self, cmd: &mut Command, log: &str, what: &str) -> Result<(), CoreError> {
        let mut child = self.spawn(cmd, log)?;
        let status = child.wait()?;
        if !status.success() {
            return Err(err(format!("{what} gagal — lihat log ({log})")));
        }
        Ok(())
    }

    fn wait_port(&self, children: &mut [Child], port: u16, secs: u64, what: &str, log: &str) -> Result<(), CoreError> {
        for _ in 0..secs * 5 {
            if port_open(port) {
                return Ok(());
            }
            for c in children.iter_mut() {
                if let Ok(Some(st)) = c.try_wait() {
                    let tail = fs::read_to_string(self.log(log)).unwrap_or_default();
                    let last = tail.lines().rev().find(|l| !l.trim().is_empty()).unwrap_or("").trim();
                    // MongoDB menulis log JSON: ambil pesannya saja.
                    let last = serde_json::from_str::<serde_json::Value>(last)
                        .ok()
                        .and_then(|v| v["attr"]["error"]["errmsg"].as_str().or(v["msg"].as_str()).map(str::to_string))
                        .unwrap_or_else(|| last.to_string());
                    let short: String = last.chars().take(180).collect();
                    let _ = st;
                    return Err(err(format!("{what} berhenti: {short}{} — lihat log", if last.chars().count() > 180 { "…" } else { "" })));
                }
            }
            std::thread::sleep(Duration::from_millis(200));
        }
        Err(err(format!("{what} tidak merespons di port {port} — lihat log")))
    }

    fn write_pids(&self, service: &str, children: &[(&str, &Child)]) {
        let body: String = children.iter().map(|(n, c)| format!("{n}:{}\n", c.id())).collect();
        let _ = fs::write(self.root.join("run").join(format!("{service}.pids")), body);
    }

    fn start_blocking(&self, service: &str, s: &StackSettings) -> Result<Vec<Child>, CoreError> {
        let port = match service {
            "web" => s.web_port,
            "mysql" => s.mysql_port,
            "postgres" => s.postgres_port,
            _ => s.mongodb_port,
        };
        if !port_free(port) {
            return Err(err(format!("port {port} sudah dipakai aplikasi lain — ganti port di pengaturan")));
        }
        let children = match service {
            "web" => self.start_web(s)?,
            "mysql" => self.start_mysql(s.mysql_port)?,
            "postgres" => self.start_postgres(s.postgres_port)?,
            "mongodb" => self.start_mongodb(s.mongodb_port)?,
            other => return Err(err(format!("layanan {other} tidak dikenal"))),
        };
        Ok(children)
    }

    // ----- Web: PHP + Apache / Nginx -----

    fn start_web(&self, s: &StackSettings) -> Result<Vec<Child>, CoreError> {
        if !port_free(PHP_PORT) {
            return Err(err(format!("port PHP {PHP_PORT} sudah dipakai aplikasi lain")));
        }
        let doc = PathBuf::from(&s.doc_root);
        fs::create_dir_all(&doc)?;
        let empty = fs::read_dir(&doc).map(|mut d| d.next().is_none()).unwrap_or(true);
        if empty {
            fs::write(doc.join("index.php"), WELCOME_PHP)?;
        }
        let conf = self.root.join("conf");
        let run = self.root.join("run");

        // PHP
        let php_ini = conf.join("php.ini");
        let ext_dir = self.app("php").join("ext");
        let mut ini = String::from("display_errors = On\nerror_reporting = E_ALL\nmemory_limit = 512M\nupload_max_filesize = 128M\npost_max_size = 128M\ndate.timezone = Asia/Jakarta\n");
        if cfg!(windows) {
            ini.push_str(&format!("extension_dir = \"{}\"\n", cfg_path(&ext_dir)));
            for e in ["mysqli", "pdo_mysql", "pgsql", "pdo_pgsql", "pdo_sqlite", "sqlite3", "mbstring", "openssl", "curl", "fileinfo", "gd", "intl", "zip"] {
                if ext_dir.join(format!("php_{e}.dll")).exists() {
                    ini.push_str(&format!("extension={e}\n"));
                }
            }
        }
        fs::write(&php_ini, ini)?;
        let mut php = if cfg!(windows) {
            let mut c = Command::new(self.app("php").join("php-cgi.exe"));
            c.args(["-b", &format!("127.0.0.1:{PHP_PORT}"), "-c"]).arg(&php_ini);
            c.env("PHP_FCGI_MAX_REQUESTS", "0");
            c
        } else {
            let fpm = conf.join("php-fpm.conf");
            fs::write(
                &fpm,
                format!(
                    "[global]\npid = {}\nerror_log = {}\ndaemonize = no\n\n[www]\nlisten = 127.0.0.1:{PHP_PORT}\npm = dynamic\npm.max_children = 8\npm.start_servers = 2\npm.min_spare_servers = 1\npm.max_spare_servers = 4\ncatch_workers_output = yes\nclear_env = no\n",
                    run.join("php-fpm.pid").display(),
                    self.log("php.log").display()
                ),
            )?;
            let mut c = Command::new(self.app("php").join("php-fpm"));
            c.arg("-F").arg("-y").arg(&fpm).arg("-c").arg(&php_ini);
            c
        };
        let mut php_child = self.spawn(&mut php, "php.log")?;
        if let Err(e) = self.wait_port(std::slice::from_mut(&mut php_child), PHP_PORT, 15, "PHP", "php.log") {
            kill_child(&mut php_child);
            return Err(e);
        }

        // Web server
        let server = if s.web_server == "nginx" { self.start_nginx(s) } else { self.start_apache(s) };
        let mut server = match server {
            Ok(c) => c,
            Err(e) => {
                kill_child(&mut php_child);
                return Err(e);
            }
        };
        let mut both = vec![php_child];
        both.push(server);
        if let Err(e) = self.wait_port(&mut both, s.web_port, 15, if s.web_server == "nginx" { "Nginx" } else { "Apache" }, "web.log") {
            for c in both.iter_mut() {
                kill_child(c);
            }
            return Err(e);
        }
        server = both.pop().unwrap();
        let php_child = both.pop().unwrap();
        let names = [(if cfg!(windows) { "php-cgi" } else { "php-fpm" }, &php_child), (if s.web_server == "nginx" { "nginx" } else { "httpd" }, &server)];
        self.write_pids("web", &names);
        Ok(vec![php_child, server])
    }

    fn start_nginx(&self, s: &StackSettings) -> Result<Child, CoreError> {
        let conf = self.root.join("conf");
        let prefix = self.root.join("run").join("nginx");
        for d in ["", "temp/body", "temp/proxy", "temp/fastcgi", "temp/uwsgi", "temp/scgi", "logs"] {
            fs::create_dir_all(prefix.join(d))?;
        }
        fs::write(conf.join("mime.types"), NGINX_MIME)?;
        fs::write(conf.join("fastcgi_params"), FASTCGI_PARAMS)?;
        let p = |x: &Path| cfg_path(x);
        let nginx_conf = format!(
            "worker_processes 1;\nerror_log \"{err}\";\npid \"{pid}\";\n{daemon}events {{ worker_connections 256; }}\n\nhttp {{\n  include \"{mime}\";\n  default_type application/octet-stream;\n  access_log \"{access}\";\n  sendfile on;\n  client_max_body_size 128m;\n  client_body_temp_path \"{t}/body\";\n  proxy_temp_path \"{t}/proxy\";\n  fastcgi_temp_path \"{t}/fastcgi\";\n  uwsgi_temp_path \"{t}/uwsgi\";\n  scgi_temp_path \"{t}/scgi\";\n\n  server {{\n    listen 127.0.0.1:{port};\n    server_name localhost;\n    root \"{root}\";\n    index index.php index.html index.htm;\n    autoindex on;\n\n    location / {{\n      try_files $uri $uri/ /index.php?$query_string;\n    }}\n\n    location ~ \\.php$ {{\n      try_files $uri =404;\n      fastcgi_pass 127.0.0.1:{php};\n      fastcgi_index index.php;\n      include \"{params}\";\n      fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;\n    }}\n  }}\n}}\n",
            err = p(&self.log("nginx-error.log")),
            pid = p(&self.root.join("run").join("nginx.pid")),
            daemon = if cfg!(windows) { "" } else { "daemon off;\n" },
            mime = p(&conf.join("mime.types")),
            access = p(&self.log("nginx-access.log")),
            t = p(&prefix.join("temp")),
            port = s.web_port,
            root = p(Path::new(&s.doc_root)),
            php = PHP_PORT,
            params = p(&conf.join("fastcgi_params")),
        );
        let file = conf.join("nginx.conf");
        fs::write(&file, nginx_conf)?;
        let mut cmd = Command::new(self.app("nginx").join(exe("nginx")));
        cmd.arg("-p").arg(&prefix).arg("-c").arg(&file).arg("-e").arg(self.log("nginx-error.log"));
        cmd.current_dir(&prefix);
        self.spawn(&mut cmd, "web.log")
    }

    fn start_apache(&self, s: &StackSettings) -> Result<Child, CoreError> {
        let conf = self.root.join("conf");
        fs::write(conf.join("apache-mime.types"), APACHE_MIME)?;
        let p = |x: &Path| cfg_path(x);
        let (server_root, modules, mods) = if cfg!(windows) {
            (self.app("apache"), "modules", vec!["authz_core", "dir", "mime", "log_config", "rewrite", "proxy", "proxy_fcgi", "autoindex", "alias", "headers", "setenvif", "env"])
        } else {
            (PathBuf::from("/usr"), "libexec/apache2", vec!["mpm_event", "unixd", "authz_core", "dir", "mime", "log_config", "rewrite", "proxy", "proxy_fcgi", "autoindex", "alias", "headers", "setenvif", "env"])
        };
        let mut c = format!("ServerRoot \"{}\"\n", p(&server_root));
        for m in mods {
            c.push_str(&format!("LoadModule {m}_module {modules}/mod_{m}.so\n"));
        }
        c.push_str(&format!(
            "Listen 127.0.0.1:{port}\nServerName localhost\nPidFile \"{pid}\"\n{runtime}DocumentRoot \"{root}\"\n<Directory \"{root}\">\n  Options Indexes FollowSymLinks\n  AllowOverride All\n  Require all granted\n</Directory>\nDirectoryIndex index.php index.html index.htm\nTypesConfig \"{mime}\"\nErrorLog \"{err}\"\nLogFormat \"%h %l %u %t \\\"%r\\\" %>s %b\" common\nCustomLog \"{access}\" common\n<FilesMatch \"\\.php$\">\n  SetHandler \"proxy:fcgi://127.0.0.1:{php}\"\n</FilesMatch>\n",
            port = s.web_port,
            pid = p(&self.root.join("run").join("httpd.pid")),
            runtime = if cfg!(windows) { String::new() } else { format!("DefaultRuntimeDir \"{}\"\n", p(&self.root.join("run"))) },
            root = p(Path::new(&s.doc_root)),
            mime = p(&conf.join("apache-mime.types")),
            err = p(&self.log("apache-error.log")),
            access = p(&self.log("apache-access.log")),
            php = PHP_PORT,
        ));
        let file = conf.join("httpd.conf");
        fs::write(&file, c)?;
        let bin = if cfg!(windows) { self.app("apache").join("bin").join("httpd.exe") } else { PathBuf::from(MAC_HTTPD) };
        let mut cmd = Command::new(bin);
        cmd.arg("-f").arg(&file);
        if !cfg!(windows) {
            cmd.arg("-DFOREGROUND");
        }
        self.spawn(&mut cmd, "web.log")
    }

    // ----- Database -----

    fn start_mysql(&self, port: u16) -> Result<Vec<Child>, CoreError> {
        let home = self.app("mysql");
        let data = self.root.join("data").join("mysql");
        let bin = home.join("bin").join(exe("mysqld"));
        if !data.join("mysql").exists() {
            let _ = fs::remove_dir_all(&data);
            self.run(
                Command::new(&bin)
                    .arg("--no-defaults")
                    .arg("--initialize-insecure")
                    .arg(format!("--basedir={}", home.display()))
                    .arg(format!("--datadir={}", data.display())),
                "mysql.log",
                "Menyiapkan database MySQL",
            )?;
        }
        let mut cmd = Command::new(&bin);
        cmd.arg("--no-defaults")
            .arg(format!("--basedir={}", home.display()))
            .arg(format!("--datadir={}", data.display()))
            .arg(format!("--port={port}"))
            .arg("--bind-address=127.0.0.1")
            .arg("--mysqlx=OFF")
            .arg(format!("--pid-file={}", self.root.join("run").join("mysql.pid").display()));
        if !cfg!(windows) {
            // Path socket pendek (batas 103 byte di macOS).
            cmd.arg(format!("--socket=/tmp/zterm-mysql-{port}.sock"));
        }
        cmd.arg(format!("--log-error={}", self.log("mysql.log").display()));
        let mut child = self.spawn(&mut cmd, "mysql.log")?;
        self.wait_port(std::slice::from_mut(&mut child), port, 60, "MySQL", "mysql.log")
            .inspect_err(|_| kill_child(&mut child))?;
        self.write_pids("mysql", &[("mysqld", &child)]);
        Ok(vec![child])
    }

    fn start_postgres(&self, port: u16) -> Result<Vec<Child>, CoreError> {
        let home = self.app("postgres");
        let data = self.root.join("data").join("postgres");
        if !data.join("PG_VERSION").exists() {
            let _ = fs::remove_dir_all(&data);
            self.run(
                Command::new(home.join("bin").join(exe("initdb")))
                    .arg("-D")
                    .arg(&data)
                    .args(["-U", "postgres", "--auth=trust", "-E", "UTF8", "--no-locale"]),
                "postgres.log",
                "Menyiapkan database PostgreSQL",
            )?;
        }
        let mut cmd = Command::new(home.join("bin").join(exe("postgres")));
        // Hanya TCP: path socket Unix di folder app bisa melebihi batas 103 byte macOS.
        cmd.arg("-D").arg(&data).arg("-p").arg(port.to_string()).args(["-c", "listen_addresses=127.0.0.1", "-c", "unix_socket_directories="]);
        let mut child = self.spawn(&mut cmd, "postgres.log")?;
        self.wait_port(std::slice::from_mut(&mut child), port, 30, "PostgreSQL", "postgres.log")
            .inspect_err(|_| kill_child(&mut child))?;
        self.write_pids("postgres", &[("postgres", &child)]);
        Ok(vec![child])
    }

    fn start_mongodb(&self, port: u16) -> Result<Vec<Child>, CoreError> {
        let data = self.root.join("data").join("mongodb");
        fs::create_dir_all(&data)?;
        let mut cmd = Command::new(self.app("mongodb").join("bin").join(exe("mongod")));
        cmd.arg("--dbpath")
            .arg(&data)
            .arg("--port")
            .arg(port.to_string())
            .args(["--bind_ip", "127.0.0.1"]);
        // Log ke stdout (diarahkan ke mongodb.log). Jangan --logpath ke file yang sama: Windows menguncinya.
        let mut child = self.spawn(&mut cmd, "mongodb.log")?;
        self.wait_port(std::slice::from_mut(&mut child), port, 30, "MongoDB", "mongodb.log")
            .inspect_err(|_| kill_child(&mut child))?;
        self.write_pids("mongodb", &[("mongod", &child)]);
        Ok(vec![child])
    }

    fn stop_blocking(&self, service: &str, mut children: Vec<Child>, s: &StackSettings) {
        // Matikan dengan sopan dulu agar database tidak perlu recovery.
        if cfg!(windows) {
            match service {
                "mysql" => {
                    let mut c = Command::new(self.app("mysql").join("bin").join("mysqladmin.exe"));
                    c.args(["-u", "root", "-h", "127.0.0.1", &format!("--port={}", s.mysql_port), "shutdown"]);
                    hide_window(&mut c);
                    let _ = c.status();
                }
                "postgres" => {
                    let mut c = Command::new(self.app("postgres").join("bin").join("pg_ctl.exe"));
                    c.arg("stop").arg("-D").arg(self.root.join("data").join("postgres")).args(["-m", "fast"]);
                    hide_window(&mut c);
                    let _ = c.status();
                }
                _ => {}
            }
        }
        for c in children.iter_mut().rev() {
            kill_child_wait(c, if service == "web" { 3 } else { 30 });
        }
        let _ = fs::remove_file(self.root.join("run").join(format!("{service}.pids")));
    }
}

// ---------- Proses ----------

fn hide_window(_cmd: &mut Command) {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        _cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    }
}

fn kill_child(c: &mut Child) {
    kill_child_wait(c, 3);
}

/// SIGTERM ke grup proses, tunggu sampai `secs` detik, lalu paksa.
fn kill_child_wait(c: &mut Child, secs: u64) {
    if matches!(c.try_wait(), Ok(Some(_))) {
        kill_pid(c.id(), false); // sisa worker di grup yang sama
        return;
    }
    kill_pid(c.id(), true);
    for _ in 0..secs * 10 {
        if matches!(c.try_wait(), Ok(Some(_))) {
            break;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    kill_pid(c.id(), false);
    let _ = c.kill();
    let _ = c.wait();
}

/// `graceful`: SIGTERM di macOS (database menutup file dengan rapi). Windows: matikan seluruh pohon proses.
fn kill_pid(pid: u32, graceful: bool) {
    // Proses dijalankan sebagai pemimpin grupnya sendiri → kirim sinyal ke seluruh grup.
    #[cfg(unix)]
    unsafe {
        libc::kill(-(pid as i32), if graceful { libc::SIGTERM } else { libc::SIGKILL });
    }
    #[cfg(windows)]
    {
        let _ = graceful;
        let mut c = Command::new("taskkill");
        c.args(["/PID", &pid.to_string(), "/T", "/F"]).stdout(Stdio::null()).stderr(Stdio::null());
        hide_window(&mut c);
        let _ = c.status();
    }
}

fn pid_alive(pid: u32) -> bool {
    #[cfg(unix)]
    {
        unsafe { libc::kill(pid as i32, 0) == 0 }
    }
    #[cfg(windows)]
    {
        process_image(pid).is_some()
    }
}

#[cfg(windows)]
fn process_image(pid: u32) -> Option<String> {
    let mut c = Command::new("tasklist");
    c.args(["/FI", &format!("PID eq {pid}"), "/FO", "CSV", "/NH"]);
    hide_window(&mut c);
    let out = c.output().ok()?;
    let s = String::from_utf8_lossy(&out.stdout);
    let first = s.lines().next()?.trim();
    first.starts_with('"').then(|| first.trim_matches('"').split("\",\"").next().unwrap_or("").to_lowercase())
}

/// Pastikan pid milik program kita (pid bisa dipakai ulang proses lain setelah reboot).
fn process_name_matches(pid: u32, name: &str) -> bool {
    #[cfg(unix)]
    {
        Command::new("ps")
            .args(["-p", &pid.to_string(), "-o", "comm="])
            .output()
            .map(|o| String::from_utf8_lossy(&o.stdout).contains(name))
            .unwrap_or(false)
    }
    #[cfg(windows)]
    {
        process_image(pid).is_some_and(|img| img.contains(&name.to_lowercase()))
    }
}

// ---------- Template ----------

const WELCOME_PHP: &str = r#"<?php $ext = get_loaded_extensions(); sort($ext); ?>
<!doctype html>
<html lang="id"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Server Lokal · Zterm</title>
<style>
  body{margin:0;min-height:100vh;display:grid;place-items:center;background:radial-gradient(800px 400px at 20% 0%,rgba(63,208,180,.18),transparent 60%),radial-gradient(700px 400px at 100% 0%,rgba(157,124,242,.18),transparent 60%),#0e1116;color:#e6edf3;font:16px/1.6 system-ui,-apple-system,"Segoe UI",sans-serif}
  .card{max-width:640px;margin:24px;padding:32px;border-radius:20px;background:#151a21;border:1px solid #262e3a}
  h1{margin:0 0 6px;font-size:30px;letter-spacing:-.02em}
  .muted{color:#8b96a5}.ok{display:inline-block;padding:3px 10px;border-radius:999px;background:rgba(74,222,128,.14);color:#4ade80;font-size:13px;font-weight:600}
  code{background:#0e1116;border:1px solid #262e3a;border-radius:6px;padding:2px 6px;font-size:13px}
  .ext{display:flex;flex-wrap:wrap;gap:6px;margin-top:10px}.ext span{font-size:12px;padding:2px 8px;border-radius:6px;background:#0e1116;border:1px solid #262e3a;color:#8b96a5}
</style></head><body><div class="card">
<span class="ok">● Berjalan</span>
<h1>Server lokal siap 🎉</h1>
<p class="muted">Dijalankan oleh Zterm. Ganti file ini dengan proyekmu — foldernya:<br><code><?= htmlspecialchars(__DIR__) ?></code></p>
<p>PHP <b><?= PHP_VERSION ?></b> · <?= htmlspecialchars($_SERVER['SERVER_SOFTWARE'] ?? 'web server') ?></p>
<div class="ext"><?php foreach ($ext as $e) echo '<span>' . htmlspecialchars($e) . '</span>'; ?></div>
</div></body></html>
"#;

const NGINX_MIME: &str = "types {\n  text/html html htm;\n  text/css css;\n  text/plain txt log md;\n  text/xml xml;\n  application/javascript js mjs;\n  application/json json map;\n  application/wasm wasm;\n  application/pdf pdf;\n  application/zip zip;\n  image/png png;\n  image/jpeg jpg jpeg;\n  image/gif gif;\n  image/webp webp;\n  image/avif avif;\n  image/svg+xml svg svgz;\n  image/x-icon ico;\n  font/woff woff;\n  font/woff2 woff2;\n  font/ttf ttf;\n  audio/mpeg mp3;\n  video/mp4 mp4;\n  video/webm webm;\n}\n";

const APACHE_MIME: &str = "text/html html htm\ntext/css css\ntext/plain txt log md\ntext/xml xml\napplication/javascript js mjs\napplication/json json map\napplication/wasm wasm\napplication/pdf pdf\napplication/zip zip\nimage/png png\nimage/jpeg jpg jpeg\nimage/gif gif\nimage/webp webp\nimage/avif avif\nimage/svg+xml svg svgz\nimage/x-icon ico\nfont/woff woff\nfont/woff2 woff2\nfont/ttf ttf\naudio/mpeg mp3\nvideo/mp4 mp4\nvideo/webm webm\n";

const FASTCGI_PARAMS: &str = "fastcgi_param QUERY_STRING $query_string;\nfastcgi_param REQUEST_METHOD $request_method;\nfastcgi_param CONTENT_TYPE $content_type;\nfastcgi_param CONTENT_LENGTH $content_length;\nfastcgi_param SCRIPT_NAME $fastcgi_script_name;\nfastcgi_param REQUEST_URI $request_uri;\nfastcgi_param DOCUMENT_URI $document_uri;\nfastcgi_param DOCUMENT_ROOT $document_root;\nfastcgi_param SERVER_PROTOCOL $server_protocol;\nfastcgi_param REQUEST_SCHEME $scheme;\nfastcgi_param HTTPS $https if_not_empty;\nfastcgi_param GATEWAY_INTERFACE CGI/1.1;\nfastcgi_param SERVER_SOFTWARE nginx/$nginx_version;\nfastcgi_param REMOTE_ADDR $remote_addr;\nfastcgi_param REMOTE_PORT $remote_port;\nfastcgi_param SERVER_ADDR $server_addr;\nfastcgi_param SERVER_PORT $server_port;\nfastcgi_param SERVER_NAME $server_name;\nfastcgi_param REDIRECT_STATUS 200;\n";

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn manifest_covers_every_platform() {
        let m = builtin_manifest();
        for p in ["macos-aarch64", "macos-x86_64", "windows-x86_64"] {
            for id in ["nginx", "php", "mysql", "postgres", "mongodb"] {
                assert!(m.iter().any(|d| d.id == id && d.platform == p), "{id} {p}");
            }
        }
        assert!(m.iter().any(|d| d.id == "apache" && d.platform == "windows-x86_64"));
    }

    #[test]
    fn settings_persist_and_missing_components() {
        let root = std::env::temp_dir().join(format!("zterm-test-stack-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let st = LocalStack::new(root.to_string_lossy().into()).unwrap();
        let mut s = st.settings();
        s.web_server = "nginx".into();
        s.web_port = 18080;
        st.set_settings(s.clone()).unwrap();
        assert_eq!(LocalStack::new(root.to_string_lossy().into()).unwrap().settings(), s);
        let web = st.services().into_iter().find(|x| x.id == "web").unwrap();
        assert_eq!(web.missing, vec!["nginx", "php"]);
        assert!(!web.running);
        let mut bad = s.clone();
        bad.web_server = "iis".into();
        assert!(st.set_settings(bad).is_err());
        let _ = fs::remove_dir_all(root);
    }
}
