//! Kelola server lewat SSH: proses (ala htop), service systemd, crontab, dan log.
//!
//! Satu koneksi SSH per server dipakai untuk semua perintah. Aksi yang butuh root dijalankan
//! langsung bila login sebagai root, atau lewat `sudo -n` (sudo tanpa password) bila tersedia.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use russh::ChannelMsg;

use crate::ssh::{self, SshTarget};
use crate::CoreError;

fn err(msg: impl Into<String>) -> CoreError {
    CoreError::Server { msg: msg.into() }
}

/// Kutip satu argumen untuk shell POSIX.
pub(crate) fn quote(a: &str) -> String {
    if !a.is_empty() && a.chars().all(|c| c.is_ascii_alphanumeric() || "_.:/@-+=,%".contains(c)) {
        a.to_string()
    } else {
        format!("'{}'", a.replace('\'', r"'\''"))
    }
}

/// Batas output yang dibaca per perintah.
const MAX_OUTPUT: usize = 1024 * 1024;

// MARK: - Record

/// Kemampuan server (dicek sekali saat tersambung).
#[derive(Debug, Clone, PartialEq, Default, uniffi::Record)]
pub struct AdminSystem {
    pub user: String,
    pub is_root: bool,
    /// `sudo -n` jalan tanpa password.
    pub sudo: bool,
    pub systemd: bool,
    pub journal: bool,
    pub crontab: bool,
    pub os: String,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ServerProcess {
    pub pid: u32,
    pub ppid: u32,
    pub user: String,
    pub cpu_percent: f32,
    pub mem_percent: f32,
    /// Byte.
    pub rss_bytes: u64,
    /// Lama berjalan, mis. "2-03:14:09" atau "05:12".
    pub elapsed: String,
    pub command: String,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ServiceUnit {
    /// Tanpa akhiran `.service`.
    pub name: String,
    pub description: String,
    /// active | inactive | failed | activating | deactivating
    pub active: String,
    /// running | exited | dead | failed | ...
    pub sub: String,
    /// enabled | disabled | static | masked | indirect | generated | "" (tidak diketahui)
    pub enabled: String,
}

/// Satu baris crontab. `job` terisi bila baris berupa jadwal (aktif, atau dinonaktifkan dengan `#`).
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CronLine {
    pub raw: String,
    pub job: Option<CronJob>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CronJob {
    /// Lima kolom (mis. "0 2 * * 1-5") atau kata khusus ("@reboot", "@daily", ...).
    pub schedule: String,
    pub command: String,
    pub enabled: bool,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct LogSource {
    /// "journal" atau path file.
    pub id: String,
    pub title: String,
    pub is_journal: bool,
    pub size_bytes: u64,
}

/// Potongan log. `cursor` dipakai untuk mengambil baris baru berikutnya (mode ikuti).
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct LogChunk {
    pub text: String,
    pub cursor: String,
    /// Log dibaca dengan sudo (user biasa tidak punya akses).
    pub via_sudo: bool,
}

// MARK: - Objek

#[derive(uniffi::Object)]
pub struct ServerAdmin {
    handle: tokio::sync::Mutex<Option<russh::client::Handle<ssh::Client>>>,
    root: AtomicBool,
    sudo: AtomicBool,
}

struct Out {
    code: i32,
    stdout: String,
    stderr: String,
}

impl Out {
    fn all(&self) -> String {
        format!("{}{}", self.stdout, self.stderr)
    }
    fn last_error(&self) -> String {
        let all = self.all();
        all.lines().map(str::trim).filter(|l| !l.is_empty()).last().unwrap_or("perintah gagal").to_string()
    }
}

fn denied(s: &str) -> bool {
    let s = s.to_lowercase();
    s.contains("permission denied")
        || s.contains("operation not permitted")
        || s.contains("access denied")
        || s.contains("interactive authentication required")
        || s.contains("must be privileged")
        || s.contains("insufficient permissions")
}

impl ServerAdmin {
    async fn exec(&self, cmd: &str, stdin: Option<&[u8]>, timeout: u64) -> Result<Out, CoreError> {
        let guard = self.handle.lock().await;
        let h = guard.as_ref().ok_or_else(|| err("koneksi ke server sudah ditutup"))?;
        let line = format!("PATH=\"$PATH:/usr/local/sbin:/usr/sbin:/sbin:/usr/local/bin\"; export LC_ALL=C; {cmd}");
        let run = async {
            let mut ch = h.channel_open_session().await.map_err(|e| CoreError::Ssh { msg: e.to_string() })?;
            ch.exec(true, line.as_str()).await.map_err(|e| CoreError::Ssh { msg: e.to_string() })?;
            if let Some(data) = stdin {
                ch.data(data).await.map_err(|e| CoreError::Ssh { msg: e.to_string() })?;
                ch.eof().await.map_err(|e| CoreError::Ssh { msg: e.to_string() })?;
            }
            let (mut out, mut errb) = (Vec::new(), Vec::new());
            let mut code = 0i32;
            while let Some(msg) = ch.wait().await {
                match msg {
                    ChannelMsg::Data { data } if out.len() < MAX_OUTPUT => out.extend_from_slice(&data),
                    ChannelMsg::ExtendedData { data, .. } if errb.len() < MAX_OUTPUT => errb.extend_from_slice(&data),
                    ChannelMsg::ExitStatus { exit_status } => code = exit_status as i32,
                    ChannelMsg::Close => break,
                    _ => {}
                }
            }
            Ok::<_, CoreError>(Out {
                code,
                stdout: String::from_utf8_lossy(&out).into_owned(),
                stderr: String::from_utf8_lossy(&errb).into_owned(),
            })
        };
        tokio::time::timeout(Duration::from_secs(timeout), run)
            .await
            .map_err(|_| err(format!("server tidak menjawab ({timeout} detik)")))?
    }

    /// Prefix untuk perintah yang butuh root: "" bila root, "sudo -n " bila sudo tanpa password tersedia.
    fn privileged(&self) -> &'static str {
        if self.root.load(Ordering::Relaxed) || !self.sudo.load(Ordering::Relaxed) { "" } else { "sudo -n " }
    }

    /// Jalankan sebagai user biasa; bila ditolak karena izin, ulangi dengan sudo (jika ada).
    async fn exec_escalate(&self, cmd: &str, timeout: u64) -> Result<(Out, bool), CoreError> {
        let o = self.exec(cmd, None, timeout).await?;
        if o.code != 0 && denied(&o.all()) && !self.root.load(Ordering::Relaxed) {
            if self.sudo.load(Ordering::Relaxed) {
                let o2 = self.exec(&format!("sudo -n sh -c {}", quote(cmd)), None, timeout).await?;
                return Ok((o2, true));
            }
            return Err(err(NEED_ROOT));
        }
        Ok((o, false))
    }

    async fn root_action(&self, cmd: &str) -> Result<Out, CoreError> {
        let o = self.exec(&format!("{}{cmd}", self.privileged()), None, 60).await?;
        if o.code != 0 {
            let all = o.all();
            if denied(&all) || all.contains("a password is required") || all.contains("a terminal is required") {
                return Err(err(NEED_ROOT));
            }
            return Err(err(o.last_error()));
        }
        Ok(o)
    }
}

const NEED_ROOT: &str = "Butuh akses root. Login sebagai root, atau izinkan user ini memakai sudo tanpa password (NOPASSWD).";

#[uniffi::export(async_runtime = "tokio")]
impl ServerAdmin {
    #[uniffi::constructor]
    pub async fn connect(target: SshTarget) -> Result<Arc<Self>, CoreError> {
        let handle = tokio::time::timeout(Duration::from_secs(20), ssh::connect(&target))
            .await
            .map_err(|_| CoreError::Ssh { msg: "server tidak menjawab (20 detik)".into() })??;
        Ok(Arc::new(Self { handle: tokio::sync::Mutex::new(Some(handle)), root: AtomicBool::new(false), sudo: AtomicBool::new(false) }))
    }

    /// Cek user, sudo, systemd, journal, crontab.
    pub async fn system(&self) -> Result<AdminSystem, CoreError> {
        let o = self
            .exec(
                r#"echo "user=$(id -un)"; echo "uid=$(id -u)"
sudo -n true >/dev/null 2>&1 && echo sudo=1
[ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1 && echo systemd=1
command -v journalctl >/dev/null 2>&1 && [ -d /run/systemd/system ] && echo journal=1
command -v crontab >/dev/null 2>&1 && echo crontab=1
if [ -r /etc/os-release ]; then . /etc/os-release; echo "os=${PRETTY_NAME:-$NAME}"; else echo "os=$(uname -sr)"; fi"#,
                None,
                20,
            )
            .await?;
        let mut s = AdminSystem::default();
        for line in o.stdout.lines() {
            let Some((k, v)) = line.split_once('=') else { continue };
            match k {
                "user" => s.user = v.into(),
                "uid" => s.is_root = v.trim() == "0",
                "sudo" => s.sudo = true,
                "systemd" => s.systemd = true,
                "journal" => s.journal = true,
                "crontab" => s.crontab = true,
                "os" => s.os = v.trim_matches('"').into(),
                _ => {}
            }
        }
        if s.user.is_empty() {
            return Err(err("server tidak mengembalikan info (shell bukan POSIX?)"));
        }
        self.root.store(s.is_root, Ordering::Relaxed);
        self.sudo.store(s.sudo, Ordering::Relaxed);
        Ok(s)
    }

    // MARK: Proses

    /// Proses yang berjalan, urut CPU lalu memori (maks. 500).
    pub async fn processes(&self) -> Result<Vec<ServerProcess>, CoreError> {
        let o = self
            .exec(
                // procps / macOS: kolom lengkap; BusyBox: tanpa %CPU
                r#"if ps -eo pid=,ppid=,user=,pcpu=,pmem=,rss=,etime=,args= >/dev/null 2>&1; then ps -eo pid=,ppid=,user=,pcpu=,pmem=,rss=,etime=,args=; else echo '#busybox'; ps -o pid,ppid,user,rss,etime,args | tail -n +2; fi"#,
                None,
                30,
            )
            .await?;
        let mut list = parse_ps(&o.stdout);
        list.sort_by(|a, b| b.cpu_percent.total_cmp(&a.cpu_percent).then(b.rss_bytes.cmp(&a.rss_bytes)));
        list.truncate(500);
        Ok(list)
    }

    /// Hentikan proses: SIGTERM, atau SIGKILL bila `force`.
    pub async fn kill(&self, pid: u32, force: bool) -> Result<(), CoreError> {
        let cmd = format!("kill {}{pid}", if force { "-9 " } else { "" });
        let (o, _) = self.exec_escalate(&cmd, 20).await?;
        if o.code != 0 {
            let e = o.last_error();
            return Err(err(if e.contains("No such process") { "Proses sudah berhenti".to_string() } else { e }));
        }
        Ok(())
    }

    // MARK: Service (systemd)

    pub async fn services(&self) -> Result<Vec<ServiceUnit>, CoreError> {
        let o = self
            .exec(
                "systemctl list-units --type=service --all --no-legend --no-pager --plain 2>/dev/null; echo '#files'; systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null",
                None,
                30,
            )
            .await?;
        if !o.stdout.contains(".service") && o.code != 0 {
            return Err(err("Server ini tidak memakai systemd"));
        }
        Ok(parse_services(&o.stdout))
    }

    /// start | stop | restart | reload | enable | disable
    pub async fn service_action(&self, name: String, action: String) -> Result<(), CoreError> {
        if !["start", "stop", "restart", "reload", "enable", "disable"].contains(&action.as_str()) {
            return Err(err("aksi tidak dikenal"));
        }
        if !valid_unit(&name) {
            return Err(err("nama service tidak valid"));
        }
        self.root_action(&format!("systemctl {action} {}.service", quote(&name))).await?;
        Ok(())
    }

    /// Keluaran `systemctl status` (beserta beberapa baris log terakhir).
    pub async fn service_status(&self, name: String) -> Result<String, CoreError> {
        if !valid_unit(&name) {
            return Err(err("nama service tidak valid"));
        }
        let o = self.exec(&format!("{}systemctl status {}.service --no-pager -n 20 -l", self.privileged(), quote(&name)), None, 30).await?;
        Ok(o.all())
    }

    // MARK: Cron

    /// Crontab milik user SSH ini.
    pub async fn cron_list(&self) -> Result<Vec<CronLine>, CoreError> {
        let o = self.exec("crontab -l", None, 20).await?;
        if o.code != 0 {
            let all = o.all();
            if all.to_lowercase().contains("no crontab") {
                return Ok(vec![]);
            }
            if o.code == 127 {
                return Err(err("crontab tidak tersedia di server ini (pasang paket cron)"));
            }
            return Err(err(o.last_error()));
        }
        Ok(parse_crontab(&o.stdout))
    }

    /// Simpan ulang seluruh crontab.
    pub async fn cron_save(&self, lines: Vec<CronLine>) -> Result<(), CoreError> {
        for l in &lines {
            if let Some(j) = &l.job {
                if !cron_valid(j.schedule.clone()) {
                    return Err(err(format!("Jadwal tidak valid: {}", j.schedule)));
                }
                if j.command.trim().is_empty() || j.command.contains('\n') {
                    return Err(err("Perintah cron harus satu baris dan tidak kosong"));
                }
            }
        }
        let text = render_crontab(&lines);
        let o = self.exec("crontab -", Some(text.as_bytes()), 20).await?;
        if o.code != 0 {
            return Err(err(o.last_error()));
        }
        Ok(())
    }

    // MARK: Log

    /// Journal (bila ada) dan file log umum yang ada di server.
    pub async fn log_sources(&self) -> Result<Vec<LogSource>, CoreError> {
        let o = self
            .exec(
                r#"command -v journalctl >/dev/null 2>&1 && [ -d /run/systemd/system ] && echo journal
for f in /var/log/syslog /var/log/messages /var/log/auth.log /var/log/secure /var/log/kern.log \
  /var/log/nginx/access.log /var/log/nginx/error.log /var/log/apache2/access.log /var/log/apache2/error.log \
  /var/log/httpd/access_log /var/log/httpd/error_log /var/log/mysql/error.log /var/log/mysqld.log \
  /var/log/postgresql/*.log /var/log/redis/*.log /var/log/php*fpm*.log /var/log/fail2ban.log /var/log/ufw.log \
  /var/log/docker.log /var/log/cron.log /var/log/dpkg.log /var/log/apt/history.log /var/log/system.log; do
  [ -f "$f" ] && echo "file|$(wc -c < "$f" 2>/dev/null || echo 0)|$f"
done"#,
                None,
                20,
            )
            .await?;
        let mut out = Vec::new();
        for line in o.stdout.lines() {
            if line == "journal" {
                out.push(LogSource { id: "journal".into(), title: "Journal sistem (journalctl)".into(), is_journal: true, size_bytes: 0 });
            } else if let Some(rest) = line.strip_prefix("file|") {
                let Some((size, path)) = rest.split_once('|') else { continue };
                out.push(LogSource {
                    id: path.into(),
                    title: path.trim_start_matches("/var/log/").into(),
                    is_journal: false,
                    size_bytes: size.trim().parse().unwrap_or(0),
                });
            }
        }
        Ok(out)
    }

    /// Baca log. `cursor` kosong → `lines` baris terakhir; berisi → hanya baris baru sejak cursor.
    /// Untuk journal, `unit` (nama service) dan `priority` ("err", "warning", ...) opsional.
    pub async fn read_log(&self, source: String, lines: u32, cursor: String, unit: String, priority: String) -> Result<LogChunk, CoreError> {
        let lines = lines.clamp(10, 20_000);
        if source == "journal" {
            let mut cmd = String::from("journalctl --no-pager -o short-iso --show-cursor");
            if cursor.is_empty() {
                cmd.push_str(&format!(" -n {lines}"));
            } else {
                cmd.push_str(&format!(" --after-cursor={}", quote(&cursor)));
            }
            if !unit.is_empty() {
                if !valid_unit(&unit) {
                    return Err(err("nama service tidak valid"));
                }
                cmd.push_str(&format!(" -u {}.service", quote(&unit)));
            }
            if !priority.is_empty() {
                if !["emerg", "alert", "crit", "err", "warning", "notice", "info", "debug"].contains(&priority.as_str()) {
                    return Err(err("prioritas tidak valid"));
                }
                cmd.push_str(&format!(" -p {priority}"));
            }
            // User biasa hanya melihat log miliknya → pakai sudo bila tersedia
            let via_sudo = !self.root.load(Ordering::Relaxed) && self.sudo.load(Ordering::Relaxed);
            let o = self.exec(&format!("{}{cmd}", if via_sudo { "sudo -n " } else { "" }), None, 60).await?;
            let (text, cur) = split_journal_cursor(&o.stdout);
            if o.code != 0 && text.trim().is_empty() {
                return Err(err(o.last_error()));
            }
            return Ok(LogChunk { text, cursor: if cur.is_empty() { cursor } else { cur }, via_sudo });
        }
        // File: cursor = jumlah byte yang sudah dibaca
        if !source.starts_with('/') || source.contains('\n') {
            return Err(err("path log harus absolut"));
        }
        let f = quote(&source);
        let off: u64 = cursor.parse().unwrap_or(0);
        let cmd = if cursor.is_empty() {
            format!("s=$(wc -c < {f}) || exit 1; tail -n {lines} {f}; printf '\\n#zterm-size=%s\\n' \"$s\"")
        } else {
            // File diputar (lebih kecil dari posisi terakhir) → baca ulang ekornya
            format!(
                "s=$(wc -c < {f}) || exit 1; if [ \"$s\" -lt {off} ]; then tail -n {lines} {f}; else tail -c +{} {f} | head -c $((s - {off})); fi; printf '\\n#zterm-size=%s\\n' \"$s\"",
                off + 1
            )
        };
        let (o, via_sudo) = self.exec_escalate(&cmd, 60).await?;
        if o.code != 0 {
            return Err(err(o.last_error()));
        }
        let (text, size) = split_size_marker(&o.stdout);
        Ok(LogChunk { text, cursor: size.unwrap_or(off).to_string(), via_sudo })
    }

    pub async fn close(&self) {
        if let Some(h) = self.handle.lock().await.take() {
            let _ = h.disconnect(russh::Disconnect::ByApplication, "", "en").await;
        }
    }
}

// MARK: - Parser

fn parse_size(s: &str) -> u64 {
    // BusyBox: "1234", "12.3m", "1.2g"; procps: KiB
    let s = s.trim().to_lowercase();
    let (num, mul) = match s.chars().last() {
        Some('k') => (&s[..s.len() - 1], 1024.0),
        Some('m') => (&s[..s.len() - 1], 1024.0 * 1024.0),
        Some('g') => (&s[..s.len() - 1], 1024.0 * 1024.0 * 1024.0),
        _ => (s.as_str(), 1024.0),
    };
    (num.parse::<f64>().unwrap_or(0.0) * mul) as u64
}

pub(crate) fn parse_ps(out: &str) -> Vec<ServerProcess> {
    let busybox = out.starts_with("#busybox");
    out.lines()
        .filter(|l| !l.starts_with('#'))
        .filter_map(|line| {
            let mut it = line.split_whitespace();
            let pid = it.next()?.parse().ok()?;
            let ppid = it.next()?.parse().unwrap_or(0);
            let user = it.next()?.to_string();
            let (cpu, mem) = if busybox { (0.0, 0.0) } else { (it.next()?.parse().unwrap_or(0.0), it.next()?.parse().unwrap_or(0.0)) };
            let rss = parse_size(it.next()?);
            let elapsed = it.next()?.to_string();
            let command = it.collect::<Vec<_>>().join(" ");
            if command.is_empty() {
                return None;
            }
            Some(ServerProcess { pid, ppid, user, cpu_percent: cpu, mem_percent: mem, rss_bytes: rss, elapsed, command })
        })
        .collect()
}

fn valid_unit(name: &str) -> bool {
    !name.is_empty() && name.len() < 200 && name.chars().all(|c| c.is_ascii_alphanumeric() || "-_.@:\\".contains(c))
}

pub(crate) fn parse_services(out: &str) -> Vec<ServiceUnit> {
    let (units, files) = out.split_once("#files").unwrap_or((out, ""));
    let mut list: Vec<ServiceUnit> = Vec::new();
    for line in units.lines() {
        // "● name.service loaded failed failed Desc" (titik di depan bila failed)
        let line = line.trim_start_matches(['●', '*', ' ']);
        let mut it = line.split_whitespace();
        let Some(unit) = it.next() else { continue };
        let Some(name) = unit.strip_suffix(".service") else { continue };
        let load = it.next().unwrap_or("");
        if load == "not-found" {
            continue;
        }
        let active = it.next().unwrap_or("").to_string();
        let sub = it.next().unwrap_or("").to_string();
        let description = it.collect::<Vec<_>>().join(" ");
        list.push(ServiceUnit { name: name.into(), description, active, sub, enabled: String::new() });
    }
    for line in files.lines() {
        let mut it = line.split_whitespace();
        let Some(unit) = it.next() else { continue };
        let Some(name) = unit.strip_suffix(".service") else { continue };
        let state = it.next().unwrap_or("").to_string();
        if let Some(u) = list.iter_mut().find(|u| u.name == name) {
            u.enabled = state;
        } else if !name.ends_with('@') && (state == "enabled" || state == "disabled") {
            list.push(ServiceUnit { name: name.into(), description: String::new(), active: "inactive".into(), sub: "dead".into(), enabled: state });
        }
    }
    list.sort_by(|a, b| a.name.cmp(&b.name));
    list
}

// MARK: Cron

const CRON_SPECIAL: [&str; 9] = ["@reboot", "@yearly", "@annually", "@monthly", "@weekly", "@daily", "@midnight", "@hourly", "@every_minute"];

fn cron_field_ok(f: &str, names: bool) -> bool {
    !f.is_empty()
        && f.split(',').all(|part| {
            let (range, step) = match part.split_once('/') {
                Some((r, s)) => (r, Some(s)),
                None => (part, None),
            };
            if let Some(s) = step {
                if s.is_empty() || !s.chars().all(|c| c.is_ascii_digit()) {
                    return false;
                }
            }
            range == "*"
                || range.split('-').all(|v| {
                    !v.is_empty() && (v.chars().all(|c| c.is_ascii_digit()) || (names && v.len() == 3 && v.chars().all(|c| c.is_ascii_alphabetic())))
                }) && range.split('-').count() <= 2
        })
}

/// Jadwal cron valid (5 kolom atau kata khusus seperti `@daily`).
#[uniffi::export]
pub fn cron_valid(schedule: String) -> bool {
    let s = schedule.trim();
    if s.starts_with('@') {
        return CRON_SPECIAL.contains(&s);
    }
    let f: Vec<&str> = s.split_whitespace().collect();
    f.len() == 5 && f.iter().enumerate().all(|(i, x)| cron_field_ok(x, i >= 3))
}

fn split_job(text: &str) -> Option<CronJob> {
    let t = text.trim();
    if t.starts_with('@') {
        let (sched, cmd) = t.split_once(char::is_whitespace)?;
        let cmd = cmd.trim();
        return (CRON_SPECIAL.contains(&sched) && !cmd.is_empty()).then(|| CronJob { schedule: sched.into(), command: cmd.into(), enabled: true });
    }
    let mut rest = t;
    let mut fields = Vec::new();
    for _ in 0..5 {
        rest = rest.trim_start();
        let end = rest.find(char::is_whitespace)?;
        fields.push(&rest[..end]);
        rest = &rest[end..];
    }
    let cmd = rest.trim();
    let sched = fields.join(" ");
    (!cmd.is_empty() && cron_valid(sched.clone())).then(|| CronJob { schedule: sched, command: cmd.into(), enabled: true })
}

pub(crate) fn parse_crontab(text: &str) -> Vec<CronLine> {
    text.lines()
        .map(|raw| {
            let t = raw.trim();
            let job = if t.is_empty() || (!t.starts_with('#') && t.contains('=') && !t.starts_with('@') && t.split('=').next().is_some_and(|k| !k.contains(' '))) {
                None
            } else if let Some(c) = t.strip_prefix('#') {
                split_job(c).map(|mut j| {
                    j.enabled = false;
                    j
                })
            } else {
                split_job(t)
            };
            CronLine { raw: raw.to_string(), job }
        })
        .collect()
}

pub(crate) fn render_crontab(lines: &[CronLine]) -> String {
    let mut s = String::new();
    for l in lines {
        match &l.job {
            Some(j) => {
                if !j.enabled {
                    s.push_str("# ");
                }
                s.push_str(j.schedule.trim());
                s.push(' ');
                s.push_str(j.command.trim());
            }
            None => s.push_str(&l.raw),
        }
        s.push('\n');
    }
    s
}

const DAYS: [&str; 7] = ["Minggu", "Senin", "Selasa", "Rabu", "Kamis", "Jumat", "Sabtu"];

fn day_name(v: &str) -> Option<String> {
    let n: usize = match v.to_lowercase().as_str() {
        "sun" => 0,
        "mon" => 1,
        "tue" => 2,
        "wed" => 3,
        "thu" => 4,
        "fri" => 5,
        "sat" => 6,
        x => x.parse::<usize>().ok()? % 7,
    };
    Some(DAYS[n].into())
}

fn days(f: &str) -> Option<String> {
    let parts: Option<Vec<String>> = f
        .split(',')
        .map(|p| match p.split_once('-') {
            Some((a, b)) => Some(format!("{}–{}", day_name(a)?, day_name(b)?)),
            None => day_name(p),
        })
        .collect();
    Some(parts?.join(", "))
}

/// Penjelasan jadwal cron dalam bahasa Indonesia, mis. "Tiap 5 menit", "Tiap hari pukul 02.30".
#[uniffi::export]
pub fn cron_describe(schedule: String) -> String {
    let s = schedule.trim();
    match s {
        "@reboot" => return "Saat server menyala".into(),
        "@hourly" => return "Tiap jam".into(),
        "@daily" | "@midnight" => return "Tiap hari pukul 00.00".into(),
        "@weekly" => return "Tiap Minggu pukul 00.00".into(),
        "@monthly" => return "Tiap tanggal 1 pukul 00.00".into(),
        "@yearly" | "@annually" => return "Tiap 1 Januari pukul 00.00".into(),
        _ => {}
    }
    if !cron_valid(s.into()) {
        return "Jadwal tidak valid".into();
    }
    let f: Vec<&str> = s.split_whitespace().collect();
    let (m, h, dom, mon, dow) = (f[0], f[1], f[2], f[3], f[4]);
    let num = |x: &str| x.parse::<u32>().ok();
    let rest_any = dom == "*" && mon == "*" && dow == "*";
    if rest_any && h == "*" {
        if m == "*" {
            return "Tiap menit".into();
        }
        if let Some(n) = m.strip_prefix("*/").and_then(num) {
            return format!("Tiap {n} menit");
        }
        if let Some(n) = num(m) {
            return format!("Tiap jam, menit ke-{n}");
        }
    }
    if rest_any {
        if let (Some(mm), Some(n)) = (num(m), h.strip_prefix("*/").and_then(num)) {
            return format!("Tiap {n} jam, menit ke-{mm}");
        }
    }
    let (Some(mm), Some(hh)) = (num(m), num(h)) else { return "Jadwal khusus".into() };
    let time = format!("pukul {hh:02}.{mm:02}");
    if mon == "*" && dom == "*" {
        if dow == "*" {
            return format!("Tiap hari {time}");
        }
        if let Some(d) = days(dow) {
            return format!("Tiap {d} {time}");
        }
    }
    if mon == "*" && dow == "*" {
        if let Some(d) = num(dom) {
            return format!("Tiap tanggal {d} {time}");
        }
    }
    "Jadwal khusus".into()
}

fn split_journal_cursor(out: &str) -> (String, String) {
    let mut cursor = String::new();
    let mut text = String::with_capacity(out.len());
    for line in out.lines() {
        if let Some(c) = line.strip_prefix("-- cursor: ") {
            cursor = c.trim().to_string();
        } else if line != "-- No entries --" {
            text.push_str(line);
            text.push('\n');
        }
    }
    (text, cursor)
}

fn split_size_marker(out: &str) -> (String, Option<u64>) {
    match out.rfind("\n#zterm-size=") {
        Some(i) => {
            let size = out[i + 12..].trim().parse().ok();
            (out[..i].to_string(), size)
        }
        None => (out.to_string(), None),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cron_roundtrip_and_describe() {
        let text = "# m h  dom mon dow   command\nMAILTO=\"\"\n*/5 * * * * /usr/bin/backup.sh > /dev/null 2>&1\n# 30 2 * * 1-5 certbot renew\n@reboot /opt/app/start.sh\n";
        let lines = parse_crontab(text);
        assert!(lines[0].job.is_none() && lines[1].job.is_none());
        let j = lines[2].job.as_ref().unwrap();
        assert_eq!((j.schedule.as_str(), j.command.as_str(), j.enabled), ("*/5 * * * *", "/usr/bin/backup.sh > /dev/null 2>&1", true));
        let off = lines[3].job.as_ref().unwrap();
        assert!(!off.enabled && off.schedule == "30 2 * * 1-5");
        assert_eq!(lines[4].job.as_ref().unwrap().schedule, "@reboot");
        let out = render_crontab(&lines);
        assert!(out.contains("# 30 2 * * 1-5 certbot renew\n") && out.starts_with("# m h  dom mon dow   command\nMAILTO=\"\"\n"));
        assert_eq!(cron_describe("*/5 * * * *".into()), "Tiap 5 menit");
        assert_eq!(cron_describe("30 2 * * *".into()), "Tiap hari pukul 02.30");
        assert_eq!(cron_describe("30 2 * * 1-5".into()), "Tiap Senin–Jumat pukul 02.30");
        assert_eq!(cron_describe("0 3 1 * *".into()), "Tiap tanggal 1 pukul 03.00");
        assert_eq!(cron_describe("15 */6 * * *".into()), "Tiap 6 jam, menit ke-15");
        assert!(!cron_valid("* * *".into()) && !cron_valid("61x * * * *".into()) && cron_valid("0 0 * jan sun".into()));
    }

    #[test]
    fn ps_and_services() {
        let ps = parse_ps("    1     0 root      0.0  0.1  11520 3-04:05:06 /sbin/init\n  812     1 www-data 12.5  2.3 190000   05:12 nginx: worker process\n");
        assert_eq!(ps.len(), 2);
        assert_eq!(ps[1].command, "nginx: worker process");
        assert_eq!(ps[1].rss_bytes, 190000 * 1024);
        let bb = parse_ps("#busybox\n    1     0 root       1.2m 10:00 /sbin/init\n");
        assert_eq!(bb[0].rss_bytes, (1.2 * 1024.0 * 1024.0) as u64);
        let svc = parse_services(
            "nginx.service loaded active running A high performance web server\n● mysql.service loaded failed failed MySQL\nfoo.service not-found inactive dead foo\n#files\nnginx.service enabled enabled\nmysql.service enabled enabled\nredis.service disabled enabled\ngetty@.service enabled enabled\n",
        );
        assert_eq!(svc.iter().map(|s| s.name.as_str()).collect::<Vec<_>>(), ["mysql", "nginx", "redis"]);
        assert_eq!(svc[0].active, "failed");
        assert_eq!(svc[2].enabled, "disabled");
    }

    #[test]
    fn markers() {
        assert_eq!(split_size_marker("a\nb\n\n#zterm-size=42\n"), ("a\nb\n".into(), Some(42)));
        let (t, c) = split_journal_cursor("2026 x\n-- cursor: s=abc;i=1\n");
        assert_eq!((t.as_str(), c.as_str()), ("2026 x\n", "s=abc;i=1"));
    }
}
