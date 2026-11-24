//! Backup & restore database ke file `.gz` di komputer ini (opsional diunggah ke Google Drive).
//!
//! - Koneksi lewat host SSH: alat dump (`mysqldump`, `pg_dump`, `mongodump`) dijalankan di server itu,
//!   hasilnya dialirkan lewat SSH lalu dikompres di sini. Tidak perlu memasang apa pun di komputer ini.
//! - Koneksi langsung: alat dump di komputer ini (PATH, Homebrew, MAMP, atau komponen Server Lokal).
//! - SQLite: file database disalin (dikompres) apa adanya.

use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use flate2::read::GzDecoder;
use flate2::write::GzEncoder;
use flate2::Compression;
use russh::ChannelMsg;

use crate::admin::quote;
use crate::model::{DbConnection, DbEngine};
use crate::sftp::TransferProgress;
use crate::ssh::{self, SshTarget};
use crate::CoreError;

fn err(msg: impl Into<String>) -> CoreError {
    CoreError::Db { msg: msg.into() }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct BackupResult {
    pub path: String,
    /// Ukuran file .gz.
    pub bytes: u64,
    /// Ukuran data sebelum dikompres.
    pub raw_bytes: u64,
    pub duration_ms: u64,
    /// "server" (dump di server lewat SSH) atau "lokal".
    pub location: String,
}

/// Engine yang bisa di-backup.
#[uniffi::export]
pub fn backup_supported(engine: DbEngine) -> bool {
    matches!(engine, DbEngine::Mysql | DbEngine::Mariadb | DbEngine::Postgres | DbEngine::Mongodb | DbEngine::Sqlite)
}

/// Akhiran nama file backup, mis. ".sql.gz".
#[uniffi::export]
pub fn backup_extension(engine: DbEngine) -> String {
    match engine {
        DbEngine::Mongodb => ".archive.gz",
        DbEngine::Sqlite => ".sqlite.gz",
        _ => ".sql.gz",
    }
    .into()
}

// MARK: - Perintah

struct Tool {
    /// Nama program yang dicari (urut pilihan).
    names: &'static [&'static str],
    args: Vec<String>,
    env: Vec<(&'static str, String)>,
    install_hint: &'static str,
}

fn host(c: &DbConnection) -> String {
    if c.host.trim().is_empty() { "127.0.0.1".into() } else { c.host.trim().into() }
}

fn mongo_uri(c: &DbConnection) -> String {
    let enc = |s: &str| s.bytes().map(|b| if b.is_ascii_alphanumeric() || b"-._~".contains(&b) { (b as char).to_string() } else { format!("%{b:02X}") }).collect::<String>();
    let auth = if c.username.is_empty() { String::new() } else { format!("{}:{}@", enc(&c.username), enc(c.password.as_deref().unwrap_or(""))) };
    let q = if c.username.is_empty() { "" } else { "?authSource=admin" };
    format!("mongodb://{auth}{}:{}/{q}", host(c), c.port)
}

fn dump_tool(c: &DbConnection) -> Result<Tool, CoreError> {
    let pw = c.password.clone().unwrap_or_default();
    Ok(match c.engine {
        DbEngine::Mysql | DbEngine::Mariadb => {
            let mut args = vec![
                format!("--host={}", host(c)),
                format!("--port={}", c.port),
                format!("--user={}", c.username),
                "--single-transaction".into(),
                "--routines".into(),
                "--triggers".into(),
                "--hex-blob".into(),
                "--no-tablespaces".into(),
                "--default-character-set=utf8mb4".into(),
            ];
            if c.database.is_empty() {
                args.push("--all-databases".into());
            } else {
                args.push("--databases".into());
                args.push(c.database.clone());
            }
            Tool { names: &["mysqldump", "mariadb-dump"], args, env: vec![("MYSQL_PWD", pw)], install_hint: "pasang mysql-client / mariadb-client" }
        }
        DbEngine::Postgres => Tool {
            names: &["pg_dump"],
            args: vec![
                format!("--host={}", host(c)),
                format!("--port={}", c.port),
                format!("--username={}", c.username),
                "--no-owner".into(),
                "--no-privileges".into(),
                "--clean".into(),
                "--if-exists".into(),
                "--format=plain".into(),
                if c.database.is_empty() { "postgres".into() } else { c.database.clone() },
            ],
            env: vec![("PGPASSWORD", pw)],
            install_hint: "pasang postgresql-client",
        },
        DbEngine::Mongodb => {
            let mut args = vec![format!("--uri={}", mongo_uri(c)), "--archive".into(), "--quiet".into()];
            if !c.database.is_empty() {
                args.push(format!("--db={}", c.database));
            }
            Tool { names: &["mongodump"], args, env: vec![], install_hint: "pasang MongoDB Database Tools" }
        }
        _ => return Err(err("Backup belum didukung untuk jenis database ini")),
    })
}

fn restore_tool(c: &DbConnection) -> Result<Tool, CoreError> {
    let pw = c.password.clone().unwrap_or_default();
    Ok(match c.engine {
        DbEngine::Mysql | DbEngine::Mariadb => {
            let mut args = vec![format!("--host={}", host(c)), format!("--port={}", c.port), format!("--user={}", c.username), "--default-character-set=utf8mb4".into()];
            if !c.database.is_empty() {
                args.push(c.database.clone());
            }
            Tool { names: &["mysql", "mariadb"], args, env: vec![("MYSQL_PWD", pw)], install_hint: "pasang mysql-client / mariadb-client" }
        }
        DbEngine::Postgres => Tool {
            names: &["psql"],
            args: vec![
                format!("--host={}", host(c)),
                format!("--port={}", c.port),
                format!("--username={}", c.username),
                format!("--dbname={}", if c.database.is_empty() { "postgres" } else { c.database.as_str() }),
                "--quiet".into(),
                "--no-psqlrc".into(),
                "--set=ON_ERROR_STOP=1".into(),
            ],
            env: vec![("PGPASSWORD", pw)],
            install_hint: "pasang postgresql-client",
        },
        DbEngine::Mongodb => Tool {
            names: &["mongorestore"],
            args: vec![format!("--uri={}", mongo_uri(c)), "--archive".into(), "--drop".into(), "--quiet".into()],
            env: vec![],
            install_hint: "pasang MongoDB Database Tools",
        },
        _ => return Err(err("Restore belum didukung untuk jenis database ini")),
    })
}

/// Satu baris shell: cari program, set env, jalankan.
fn shell_line(t: &Tool) -> String {
    let find = t.names.iter().map(|n| format!("command -v {n}")).collect::<Vec<_>>().join(" || ");
    let env = t.env.iter().map(|(k, v)| format!("{k}={}", quote(v))).collect::<Vec<_>>().join(" ");
    let args = t.args.iter().map(|a| quote(a)).collect::<Vec<_>>().join(" ");
    format!(
        "PATH=\"$PATH:/usr/local/bin:/usr/bin:/opt/homebrew/bin:/usr/local/mysql/bin\"; D=$({find}) || {{ echo 'zterm:notool' >&2; exit 127; }}; {env} \"$D\" {args}"
    )
}

/// Pesan error yang jelas dari stderr alat dump.
fn tool_error(stderr: &str, code: i32, t: &Tool, remote: bool) -> CoreError {
    if code == 127 || stderr.contains("zterm:notool") {
        return err(format!(
            "{} tidak ditemukan {} — {}",
            t.names[0],
            if remote { "di server" } else { "di komputer ini" },
            t.install_hint
        ));
    }
    let line = stderr
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with("mysqldump: [Warning]") && !l.contains("Using a password"))
        .last()
        .unwrap_or("perintah gagal");
    err(line.to_string())
}

// MARK: - Lokal

fn exe(name: &str) -> String {
    if cfg!(windows) { format!("{name}.exe") } else { name.to_string() }
}

/// Cari program di folder tambahan (rekursif, mis. komponen Server Lokal), PATH, dan lokasi umum.
fn find_local(names: &[&str], extra: &[String]) -> Option<PathBuf> {
    fn walk(dir: &Path, file: &str, depth: u8) -> Option<PathBuf> {
        let p = dir.join(file);
        if p.is_file() {
            return Some(p);
        }
        if depth == 0 {
            return None;
        }
        for e in std::fs::read_dir(dir).ok()?.flatten() {
            if e.file_type().map(|t| t.is_dir()).unwrap_or(false) {
                if let Some(f) = walk(&e.path(), file, depth - 1) {
                    return Some(f);
                }
            }
        }
        None
    }
    let mut dirs: Vec<PathBuf> = std::env::var_os("PATH").map(|p| std::env::split_paths(&p).collect()).unwrap_or_default();
    for d in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/local/mysql/bin", "/Applications/MAMP/Library/bin", "/Applications/Postgres.app/Contents/Versions/latest/bin"] {
        dirs.push(d.into());
    }
    for n in names {
        let f = exe(n);
        for d in &dirs {
            if d.join(&f).is_file() {
                return Some(d.join(&f));
            }
        }
        for root in extra.iter().chain(
            [
                r"C:\Program Files\MySQL", r"C:\Program Files\PostgreSQL", r"C:\Program Files\MariaDB", r"C:\Program Files\MongoDB",
                "/opt/homebrew/opt/mysql-client/bin", "/opt/homebrew/opt/libpq/bin", "/usr/local/opt/mysql-client/bin", "/usr/local/opt/libpq/bin",
                "/Applications/MAMP/Library/bin", "/Applications/Postgres.app/Contents/Versions",
            ]
                .iter()
                .map(|s| s.to_string())
                .collect::<Vec<_>>()
                .iter(),
        ) {
            let root = Path::new(root);
            if root.is_dir() {
                if let Some(p) = walk(root, &f, 5) {
                    return Some(p);
                }
            }
        }
    }
    None
}

fn local_command(t: &Tool, extra: &[String]) -> Result<std::process::Command, CoreError> {
    let bin = find_local(t.names, extra).ok_or_else(|| tool_error("", 127, t, false))?;
    let mut cmd = std::process::Command::new(&bin);
    cmd.args(&t.args);
    for (k, v) in &t.env {
        cmd.env(k, v);
    }
    // Pustaka bawaan (mis. libpq / libmysqlclient di komponen Server Lokal) ada di sebelah bin
    if let Some(lib) = bin.parent().and_then(|b| b.parent()).map(|p| p.join("lib")) {
        if lib.is_dir() {
            let var = if cfg!(target_os = "macos") { "DYLD_LIBRARY_PATH" } else { "LD_LIBRARY_PATH" };
            cmd.env(var, lib);
        }
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0800_0000);
    }
    Ok(cmd)
}

// MARK: - Backup

/// Backup `conn` ke file `dest_path` (.gz). `ssh` = host SSH koneksi (dump dijalankan di sana).
/// `tool_dirs` = folder tambahan untuk mencari alat dump di komputer ini (mis. folder Server Lokal).
#[uniffi::export(async_runtime = "tokio")]
pub async fn backup_database(
    conn: DbConnection,
    ssh: Option<SshTarget>,
    dest_path: String,
    tool_dirs: Vec<String>,
    progress: Arc<dyn TransferProgress>,
) -> Result<BackupResult, CoreError> {
    let start = Instant::now();
    let dest = PathBuf::from(&dest_path);
    if let Some(dir) = dest.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let tmp = dest.with_extension("part");
    let result = run_backup(&conn, ssh, &tmp, &tool_dirs, progress).await;
    match result {
        Ok((raw, location)) => {
            std::fs::rename(&tmp, &dest)?;
            let bytes = std::fs::metadata(&dest).map(|m| m.len()).unwrap_or(0);
            Ok(BackupResult { path: dest_path, bytes, raw_bytes: raw, duration_ms: start.elapsed().as_millis() as u64, location })
        }
        Err(e) => {
            let _ = std::fs::remove_file(&tmp);
            Err(e)
        }
    }
}

async fn run_backup(conn: &DbConnection, ssh: Option<SshTarget>, tmp: &Path, tool_dirs: &[String], progress: Arc<dyn TransferProgress>) -> Result<(u64, String), CoreError> {
    if conn.engine == DbEngine::Sqlite {
        let src = PathBuf::from(&conn.file_path);
        let tmp = tmp.to_path_buf();
        return tokio::task::spawn_blocking(move || {
            let mut input = std::fs::File::open(&src).map_err(|e| err(format!("file SQLite tidak bisa dibuka: {e}")))?;
            let total = input.metadata().map(|m| m.len()).unwrap_or(0);
            let mut gz = GzEncoder::new(std::fs::File::create(&tmp)?, Compression::default());
            let n = copy_progress(&mut input, &mut gz, total, &*progress)?;
            gz.finish()?;
            Ok((n, "lokal".to_string()))
        })
        .await
        .map_err(|e| err(e.to_string()))?;
    }
    let tool = dump_tool(conn)?;
    let file = std::fs::File::create(tmp)?;
    let mut gz = GzEncoder::new(file, Compression::default());
    if let Some(target) = ssh {
        let h = tokio::time::timeout(Duration::from_secs(20), ssh::connect(&target))
            .await
            .map_err(|_| CoreError::Ssh { msg: "server tidak menjawab (20 detik)".into() })??;
        let mut ch = h.channel_open_session().await.map_err(|e| CoreError::Ssh { msg: e.to_string() })?;
        ch.exec(true, shell_line(&tool).as_str()).await.map_err(|e| CoreError::Ssh { msg: e.to_string() })?;
        let (mut raw, mut stderr, mut code) = (0u64, Vec::new(), 0i32);
        let mut cancelled = false;
        while let Some(msg) = ch.wait().await {
            match msg {
                ChannelMsg::Data { data } => {
                    gz.write_all(&data)?;
                    raw += data.len() as u64;
                    progress.on_progress(raw, 0, String::new());
                    if progress.is_cancelled() {
                        cancelled = true;
                        break;
                    }
                }
                ChannelMsg::ExtendedData { data, .. } if stderr.len() < 65536 => stderr.extend_from_slice(&data),
                ChannelMsg::ExitStatus { exit_status } => code = exit_status as i32,
                ChannelMsg::Close => break,
                _ => {}
            }
        }
        let _ = h.disconnect(russh::Disconnect::ByApplication, "", "en").await;
        if cancelled {
            return Err(CoreError::Cancelled);
        }
        if code != 0 {
            return Err(tool_error(&String::from_utf8_lossy(&stderr), code, &tool, true));
        }
        if raw == 0 {
            return Err(err("backup kosong — periksa nama database & hak akses user"));
        }
        gz.finish()?;
        return Ok((raw, "server".into()));
    }
    let mut cmd = local_command(&tool, tool_dirs)?;
    tokio::task::spawn_blocking(move || {
        cmd.stdout(std::process::Stdio::piped()).stderr(std::process::Stdio::piped()).stdin(std::process::Stdio::null());
        let mut child = cmd.spawn().map_err(|e| err(format!("gagal menjalankan {}: {e}", tool.names[0])))?;
        let mut stderr = child.stderr.take();
        let errs = std::thread::spawn(move || {
            let mut s = String::new();
            if let Some(e) = stderr.as_mut() {
                let _ = e.read_to_string(&mut s);
            }
            s
        });
        let mut out = child.stdout.take().ok_or_else(|| err("stdout tidak tersedia"))?;
        let copied = copy_progress(&mut out, &mut gz, 0, &*progress);
        if copied.is_err() {
            let _ = child.kill();
        }
        let status = child.wait()?;
        let stderr = errs.join().unwrap_or_default();
        let raw = copied?;
        if !status.success() {
            return Err(tool_error(&stderr, status.code().unwrap_or(1), &tool, false));
        }
        if raw == 0 {
            return Err(err("backup kosong — periksa nama database & hak akses user"));
        }
        gz.finish()?;
        Ok((raw, "lokal".to_string()))
    })
    .await
    .map_err(|e| err(e.to_string()))?
}

fn copy_progress(r: &mut dyn Read, w: &mut dyn Write, total: u64, progress: &dyn TransferProgress) -> Result<u64, CoreError> {
    let mut buf = vec![0u8; 256 * 1024];
    let mut n = 0u64;
    loop {
        let k = r.read(&mut buf)?;
        if k == 0 {
            return Ok(n);
        }
        w.write_all(&buf[..k])?;
        n += k as u64;
        progress.on_progress(n, total, String::new());
        if progress.is_cancelled() {
            return Err(CoreError::Cancelled);
        }
    }
}

// MARK: - Restore

/// Pulihkan file backup (.gz) ke `conn`. Data yang ada ditimpa (tabel di-drop & dibuat ulang).
#[uniffi::export(async_runtime = "tokio")]
pub async fn restore_database(
    conn: DbConnection,
    ssh: Option<SshTarget>,
    src_path: String,
    tool_dirs: Vec<String>,
    progress: Arc<dyn TransferProgress>,
) -> Result<(), CoreError> {
    let src = PathBuf::from(&src_path);
    let total = std::fs::metadata(&src).map_err(|e| err(format!("file backup tidak bisa dibuka: {e}")))?.len();
    if conn.engine == DbEngine::Sqlite {
        let dest = PathBuf::from(&conn.file_path);
        return tokio::task::spawn_blocking(move || {
            let mut gz = GzDecoder::new(std::fs::File::open(&src)?);
            let tmp = dest.with_extension("zterm-restore");
            let mut out = std::fs::File::create(&tmp)?;
            copy_progress(&mut gz, &mut out, 0, &*progress)?;
            out.sync_all()?;
            std::fs::rename(&tmp, &dest)?;
            Ok(())
        })
        .await
        .map_err(|e| err(e.to_string()))?;
    }
    let tool = restore_tool(&conn)?;
    if let Some(target) = ssh {
        let h = tokio::time::timeout(Duration::from_secs(20), ssh::connect(&target))
            .await
            .map_err(|_| CoreError::Ssh { msg: "server tidak menjawab (20 detik)".into() })??;
        let mut ch = h.channel_open_session().await.map_err(|e| CoreError::Ssh { msg: e.to_string() })?;
        ch.exec(true, shell_line(&tool).as_str()).await.map_err(|e| CoreError::Ssh { msg: e.to_string() })?;
        // Baca & dekompres di thread terpisah, kirim per potongan
        let (tx, mut rx) = tokio::sync::mpsc::channel::<Result<Vec<u8>, CoreError>>(4);
        let src2 = src.clone();
        let reader = tokio::task::spawn_blocking(move || {
            let file = match std::fs::File::open(&src2) {
                Ok(f) => f,
                Err(e) => {
                    let _ = tx.blocking_send(Err(e.into()));
                    return;
                }
            };
            let mut gz = GzDecoder::new(file);
            let mut buf = vec![0u8; 256 * 1024];
            loop {
                match gz.read(&mut buf) {
                    Ok(0) => return,
                    Ok(k) => {
                        if tx.blocking_send(Ok(buf[..k].to_vec())).is_err() {
                            return;
                        }
                    }
                    Err(e) => {
                        let _ = tx.blocking_send(Err(err(format!("file backup rusak: {e}"))));
                        return;
                    }
                }
            }
        });
        let mut sent = 0u64;
        while let Some(chunk) = rx.recv().await {
            let chunk = chunk?;
            sent += chunk.len() as u64;
            ch.data(&chunk[..]).await.map_err(|e| CoreError::Ssh { msg: e.to_string() })?;
            progress.on_progress(sent, 0, String::new());
            if progress.is_cancelled() {
                let _ = h.disconnect(russh::Disconnect::ByApplication, "", "en").await;
                return Err(CoreError::Cancelled);
            }
        }
        let _ = reader.await;
        ch.eof().await.map_err(|e| CoreError::Ssh { msg: e.to_string() })?;
        let (mut stderr, mut code) = (Vec::new(), 0i32);
        while let Some(msg) = ch.wait().await {
            match msg {
                ChannelMsg::Data { data } | ChannelMsg::ExtendedData { data, .. } if stderr.len() < 65536 => stderr.extend_from_slice(&data),
                ChannelMsg::ExitStatus { exit_status } => code = exit_status as i32,
                ChannelMsg::Close => break,
                _ => {}
            }
        }
        let _ = h.disconnect(russh::Disconnect::ByApplication, "", "en").await;
        let _ = total;
        if code != 0 {
            return Err(tool_error(&String::from_utf8_lossy(&stderr), code, &tool, true));
        }
        return Ok(());
    }
    let mut cmd = local_command(&tool, &tool_dirs)?;
    tokio::task::spawn_blocking(move || {
        cmd.stdin(std::process::Stdio::piped()).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::piped());
        let mut child = cmd.spawn().map_err(|e| err(format!("gagal menjalankan {}: {e}", tool.names[0])))?;
        let mut stderr = child.stderr.take();
        let errs = std::thread::spawn(move || {
            let mut s = String::new();
            if let Some(e) = stderr.as_mut() {
                let _ = e.read_to_string(&mut s);
            }
            s
        });
        let mut gz = GzDecoder::new(std::fs::File::open(&src)?);
        let res = {
            let mut stdin = child.stdin.take().ok_or_else(|| err("stdin tidak tersedia"))?;
            copy_progress(&mut gz, &mut stdin, 0, &*progress)
            // stdin ditutup di sini → alat restore selesai membaca
        };
        if res.is_err() {
            let _ = child.kill();
        }
        let status = child.wait()?;
        let stderr = errs.join().unwrap_or_default();
        if let Err(e) = res {
            if !status.success() {
                return Err(tool_error(&stderr, status.code().unwrap_or(1), &tool, false));
            }
            return Err(e);
        }
        if !status.success() {
            return Err(tool_error(&stderr, status.code().unwrap_or(1), &tool, false));
        }
        Ok(())
    })
    .await
    .map_err(|e| err(e.to_string()))?
}

// MARK: - Google Drive

/// Unggah file backup ke folder "Zterm Backups" di Google Drive (izin drive.file). Mengembalikan id file.
#[uniffi::export(async_runtime = "tokio")]
pub async fn drive_upload_backup(token: String, path: String, progress: Arc<dyn TransferProgress>) -> Result<String, CoreError> {
    let base = crate::team::drive_base();
    let http = reqwest::Client::new();
    let send = |req: reqwest::RequestBuilder| async {
        let resp = req.bearer_auth(&token).send().await.map_err(|e| err(format!("tidak bisa terhubung ke Google Drive: {e}")))?;
        let code = resp.status().as_u16();
        let headers = resp.headers().clone();
        let body = resp.bytes().await.map(|b| b.to_vec()).unwrap_or_default();
        match code {
            200..=299 | 308 => Ok((code, headers, body)),
            401 => Err(CoreError::GoogleAuth),
            403 if String::from_utf8_lossy(&body).contains("insufficient") => Err(CoreError::GoogleScope),
            _ => Err(err(format!("Google Drive {code}: {}", String::from_utf8_lossy(&body).chars().take(160).collect::<String>()))),
        }
    };
    // Folder tujuan (dibuat sekali, ditandai appProperties)
    let q = "mimeType = 'application/vnd.google-apps.folder' and appProperties has { key='ztermBackups' and value='1' } and trashed = false";
    let (_, _, body) = send(http.get(format!("{base}/drive/v3/files")).query(&[("q", q), ("fields", "files(id)")])).await?;
    let v: serde_json::Value = serde_json::from_slice(&body)?;
    let folder = match v["files"][0]["id"].as_str() {
        Some(id) => id.to_string(),
        None => {
            let meta = serde_json::json!({ "name": "Zterm Backups", "mimeType": "application/vnd.google-apps.folder", "appProperties": { "ztermBackups": "1" } });
            let (_, _, body) = send(http.post(format!("{base}/drive/v3/files?fields=id")).header("Content-Type", "application/json").body(meta.to_string())).await?;
            let v: serde_json::Value = serde_json::from_slice(&body)?;
            v["id"].as_str().ok_or_else(|| err("Google Drive tidak mengembalikan id folder"))?.to_string()
        }
    };
    // Unggah resumable per 8 MB
    let p = PathBuf::from(&path);
    let total = std::fs::metadata(&p)?.len();
    let name = p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| "backup.gz".into());
    let meta = serde_json::json!({ "name": name, "parents": [folder], "appProperties": { "ztermBackup": "1" } });
    let (_, headers, _) = send(
        http.post(format!("{base}/upload/drive/v3/files?uploadType=resumable&fields=id"))
            .header("Content-Type", "application/json; charset=UTF-8")
            .header("X-Upload-Content-Type", "application/gzip")
            .header("X-Upload-Content-Length", total.to_string())
            .body(meta.to_string()),
    )
    .await?;
    let session = headers.get("location").and_then(|l| l.to_str().ok()).ok_or_else(|| err("Google Drive tidak memberi alamat unggah"))?.to_string();
    let mut file = std::fs::File::open(&p)?;
    let chunk = 8 * 1024 * 1024usize;
    let mut sent = 0u64;
    loop {
        let mut buf = vec![0u8; chunk];
        let mut k = 0;
        while k < chunk {
            let n = file.read(&mut buf[k..])?;
            if n == 0 {
                break;
            }
            k += n;
        }
        buf.truncate(k);
        let range = if total == 0 { "bytes */0".to_string() } else { format!("bytes {}-{}/{}", sent, sent + k as u64 - 1, total) };
        let (code, _, body) = send(http.put(&session).header("Content-Range", range).body(buf)).await?;
        sent += k as u64;
        progress.on_progress(sent, total, name.clone());
        if progress.is_cancelled() {
            return Err(CoreError::Cancelled);
        }
        if code != 308 {
            let v: serde_json::Value = serde_json::from_slice(&body)?;
            return v["id"].as_str().map(str::to_string).ok_or_else(|| err("Google Drive tidak mengembalikan id file"));
        }
        if sent >= total {
            return Err(err("unggahan Google Drive tidak selesai"));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn conn(engine: DbEngine) -> DbConnection {
        DbConnection {
            id: String::new(), label: "x".into(), engine, host: "db.local".into(), port: 3306, username: "root".into(),
            password: Some("p'w d".into()), database: "toko".into(), file_path: String::new(), tls: false, ssh_host_id: None,
            color: String::new(), updated_at: 0, deleted: false,
        }
    }

    #[test]
    fn shell_lines() {
        let l = shell_line(&dump_tool(&conn(DbEngine::Mysql)).unwrap());
        assert!(l.contains("command -v mysqldump || command -v mariadb-dump"));
        assert!(l.contains("MYSQL_PWD='p'\\''w d' \"$D\" --host=db.local --port=3306 --user=root --single-transaction"));
        assert!(l.ends_with("--databases toko"));
        let pg = shell_line(&restore_tool(&conn(DbEngine::Postgres)).unwrap());
        assert!(pg.contains("PGPASSWORD=") && pg.contains("--dbname=toko"));
        assert_eq!(mongo_uri(&conn(DbEngine::Mongodb)), "mongodb://root:p%27w%20d@db.local:3306/?authSource=admin");
        assert!(dump_tool(&conn(DbEngine::Redis)).is_err());
        assert_eq!(backup_extension(DbEngine::Mongodb), ".archive.gz");
    }
}
