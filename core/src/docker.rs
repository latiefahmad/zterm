//! Docker: kelola container, image, dan proyek Compose — di komputer ini atau di server lewat SSH.
//!
//! Semua operasi memakai Docker CLI (`docker ... --format '{{json .}}'`), jadi tidak perlu membuka
//! socket Docker ke luar. Di server, bila user belum masuk grup `docker`, dicoba `sudo -n docker`.

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use russh::ChannelMsg;
use serde_json::Value;

use crate::ssh::{self, SshTarget};
use crate::CoreError;

fn err(msg: impl Into<String>) -> CoreError {
    CoreError::Docker { msg: msg.into() }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct DockerInfo {
    pub version: String,
    pub os: String,
    pub containers: u32,
    pub running: u32,
    pub images: u32,
    pub cpus: u32,
    /// Byte.
    pub memory: u64,
    /// Perintah dijalankan dengan `sudo` (user belum di grup docker).
    pub uses_sudo: bool,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct DockerContainer {
    pub id: String,
    pub name: String,
    pub image: String,
    /// running | exited | paused | created | restarting | dead
    pub state: String,
    /// mis. "Up 2 hours", "Exited (0) 3 days ago"
    pub status: String,
    pub ports: String,
    pub created: String,
    /// Nama proyek Docker Compose (kosong = bukan dari Compose).
    pub project: String,
    pub service: String,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct DockerStat {
    pub id: String,
    pub cpu_percent: f64,
    pub mem_percent: f64,
    /// mis. "23.2MiB / 7.8GiB"
    pub mem_usage: String,
    pub net_io: String,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct DockerImage {
    pub id: String,
    pub repository: String,
    pub tag: String,
    pub size: String,
    pub created: String,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ComposeProject {
    pub name: String,
    /// mis. "running(3)", "exited(2)"
    pub status: String,
    pub config_files: String,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct DockerVolume {
    pub name: String,
    pub driver: String,
    pub mountpoint: String,
    /// Proyek Compose pemilik volume (kosong = tidak ada).
    pub project: String,
    /// Volume anonim (nama acak) — biasanya sisa container lama.
    pub anonymous: bool,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct DockerNetwork {
    pub id: String,
    pub name: String,
    pub driver: String,
    pub project: String,
    /// bridge/host/none bawaan Docker.
    pub builtin: bool,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct DockerPort {
    pub host_ip: String,
    pub host_port: u16,
    /// mis. "80/tcp"
    pub container_port: String,
}

/// Detail satu container (`docker inspect`).
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct DockerDetail {
    pub id: String,
    pub name: String,
    pub image: String,
    pub command: String,
    pub created: String,
    pub started_at: String,
    pub restart_policy: String,
    pub health: String,
    pub ip_address: String,
    pub networks: Vec<String>,
    pub ports: Vec<DockerPort>,
    /// `KEY=VALUE` — bisa berisi rahasia, tampilkan tersamar di UI.
    pub env: Vec<String>,
    /// "sumber → tujuan (rw)"
    pub mounts: Vec<String>,
}

enum Target {
    Local(PathBuf),
    Ssh(tokio::sync::Mutex<Option<russh::client::Handle<ssh::Client>>>),
}

#[derive(uniffi::Object)]
pub struct DockerClient {
    target: Target,
    sudo: AtomicBool,
}

/// Nilai yang aman dimasukkan ke perintah shell (id, nama, image, path compose).
fn safe(v: &str) -> Result<&str, CoreError> {
    let ok = !v.is_empty() && v.chars().all(|c| c.is_ascii_alphanumeric() || "_.:/@-+=, ".contains(c)) && !v.starts_with('-');
    if ok { Ok(v) } else { Err(err(format!("nama tidak valid: {v}"))) }
}

fn quote(a: &str) -> String {
    if a.chars().all(|c| c.is_ascii_alphanumeric() || "_.:/@-+=,{}%".contains(c)) {
        a.to_string()
    } else {
        format!("'{}'", a.replace('\'', r"'\''"))
    }
}

/// Docker CLI di komputer ini. App GUI tidak mewarisi PATH terminal, jadi lokasi umum dicek satu per satu.
fn find_local_docker() -> Option<PathBuf> {
    let home = std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" }).map(PathBuf::from).unwrap_or_default();
    let mut cands: Vec<PathBuf> = if cfg!(windows) {
        vec![
            PathBuf::from(r"C:\Program Files\Docker\Docker\resources\bin\docker.exe"),
            home.join(r"AppData\Local\Programs\Rancher Desktop\resources\resources\win32\bin\docker.exe"),
        ]
    } else {
        vec![
            PathBuf::from("/usr/local/bin/docker"),
            PathBuf::from("/opt/homebrew/bin/docker"),
            home.join(".orbstack/bin/docker"),
            PathBuf::from("/Applications/Docker.app/Contents/Resources/bin/docker"),
            PathBuf::from("/Applications/OrbStack.app/Contents/MacOS/xbin/docker"),
            home.join(".rd/bin/docker"),
            PathBuf::from("/usr/bin/docker"),
        ]
    };
    if let Some(path) = std::env::var_os("PATH") {
        for d in std::env::split_paths(&path) {
            cands.push(d.join(if cfg!(windows) { "docker.exe" } else { "docker" }));
        }
    }
    cands.into_iter().find(|p| p.is_file())
}

fn denied(out: &str) -> bool {
    let o = out.to_lowercase();
    o.contains("permission denied") && o.contains("docker")
}

#[uniffi::export(async_runtime = "tokio")]
impl DockerClient {
    /// Docker di komputer ini (Docker Desktop, OrbStack, Rancher, Colima, …).
    #[uniffi::constructor]
    pub fn local() -> Result<Arc<Self>, CoreError> {
        let bin = find_local_docker().ok_or_else(|| {
            err("Docker belum terpasang di komputer ini. Pasang Docker Desktop atau OrbStack, lalu coba lagi.")
        })?;
        Ok(Arc::new(Self { target: Target::Local(bin), sudo: AtomicBool::new(false) }))
    }

    /// Docker di server lewat SSH (password/key/agent/proxy sesuai host).
    #[uniffi::constructor]
    pub async fn connect(target: SshTarget) -> Result<Arc<Self>, CoreError> {
        let h = ssh::connect(&target).await?;
        Ok(Arc::new(Self { target: Target::Ssh(tokio::sync::Mutex::new(Some(h))), sudo: AtomicBool::new(false) }))
    }

    pub async fn info(&self) -> Result<DockerInfo, CoreError> {
        let out = self
            .docker(&["info", "--format", "{{.ServerVersion}}|{{.OperatingSystem}}|{{.Containers}}|{{.ContainersRunning}}|{{.Images}}|{{.NCPU}}|{{.MemTotal}}"])
            .await?;
        let line = out.lines().rev().find(|l| l.contains('|')).unwrap_or("");
        let p: Vec<&str> = line.split('|').collect();
        if p.len() < 7 || p[0].trim().is_empty() {
            return Err(err(format!("Docker daemon tidak menjawab: {}", out.trim().chars().take(200).collect::<String>())));
        }
        Ok(DockerInfo {
            version: p[0].trim().into(),
            os: p[1].trim().into(),
            containers: p[2].trim().parse().unwrap_or(0),
            running: p[3].trim().parse().unwrap_or(0),
            images: p[4].trim().parse().unwrap_or(0),
            cpus: p[5].trim().parse().unwrap_or(0),
            memory: p[6].trim().parse().unwrap_or(0),
            uses_sudo: self.sudo.load(Ordering::Relaxed),
        })
    }

    pub async fn containers(&self) -> Result<Vec<DockerContainer>, CoreError> {
        let out = self.docker(&["ps", "-a", "--format", "{{json .}}"]).await?;
        let mut v: Vec<DockerContainer> = json_lines(&out).iter().map(parse_container).collect();
        v.sort_by(|a, b| (a.project.is_empty(), &a.project, &a.name).cmp(&(b.project.is_empty(), &b.project, &b.name)));
        Ok(v)
    }

    /// Pemakaian CPU & RAM container yang berjalan (satu sampel).
    pub async fn stats(&self) -> Result<Vec<DockerStat>, CoreError> {
        let out = self.docker(&["stats", "--no-stream", "--format", "{{json .}}"]).await?;
        Ok(json_lines(&out).iter().map(parse_stat).collect())
    }

    pub async fn images(&self) -> Result<Vec<DockerImage>, CoreError> {
        let out = self.docker(&["images", "--format", "{{json .}}"]).await?;
        Ok(json_lines(&out)
            .iter()
            .map(|v| DockerImage {
                id: s(v, "ID"),
                repository: s(v, "Repository"),
                tag: s(v, "Tag"),
                size: s(v, "Size"),
                created: s(v, "CreatedSince"),
            })
            .collect())
    }

    /// Proyek Docker Compose (kosong bila plugin compose tidak ada).
    pub async fn compose_projects(&self) -> Result<Vec<ComposeProject>, CoreError> {
        let Ok(out) = self.docker(&["compose", "ls", "-a", "--format", "json"]).await else { return Ok(vec![]) };
        let start = out.find('[').unwrap_or(out.len());
        let list: Vec<Value> = serde_json::from_str(out[start..].trim()).unwrap_or_default();
        Ok(list
            .iter()
            .map(|v| ComposeProject { name: s(v, "Name"), status: s(v, "Status"), config_files: s(v, "ConfigFiles") })
            .collect())
    }

    pub async fn volumes(&self) -> Result<Vec<DockerVolume>, CoreError> {
        let out = self.docker(&["volume", "ls", "--format", "{{json .}}"]).await?;
        let mut v: Vec<DockerVolume> = json_lines(&out)
            .iter()
            .map(|v| {
                let labels = s(v, "Labels");
                let name = s(v, "Name");
                DockerVolume {
                    anonymous: labels.contains("com.docker.volume.anonymous") || (name.len() == 64 && name.chars().all(|c| c.is_ascii_hexdigit())),
                    project: label(&labels, "com.docker.compose.project"),
                    driver: s(v, "Driver"),
                    mountpoint: s(v, "Mountpoint"),
                    name,
                }
            })
            .collect();
        v.sort_by(|a, b| (a.anonymous, a.project.is_empty(), &a.project, &a.name).cmp(&(b.anonymous, b.project.is_empty(), &b.project, &b.name)));
        Ok(v)
    }

    pub async fn networks(&self) -> Result<Vec<DockerNetwork>, CoreError> {
        let out = self.docker(&["network", "ls", "--format", "{{json .}}"]).await?;
        Ok(json_lines(&out)
            .iter()
            .map(|v| {
                let name = s(v, "Name");
                DockerNetwork {
                    id: s(v, "ID"),
                    builtin: matches!(name.as_str(), "bridge" | "host" | "none"),
                    project: label(&s(v, "Labels"), "com.docker.compose.project"),
                    driver: s(v, "Driver"),
                    name,
                }
            })
            .collect())
    }

    pub async fn remove_volume(&self, name: String) -> Result<(), CoreError> {
        let name = safe(&name)?;
        self.docker(&["volume", "rm", name]).await.map(|_| ())
    }

    pub async fn inspect(&self, id: String) -> Result<DockerDetail, CoreError> {
        let id = safe(&id)?;
        let out = self.docker(&["inspect", "--type", "container", id]).await?;
        let start = out.find('[').ok_or_else(|| err("detail container tidak terbaca"))?;
        let list: Vec<Value> = serde_json::from_str(out[start..].trim()).map_err(|_| err("detail container tidak terbaca"))?;
        let d = list.first().ok_or_else(|| err("container tidak ditemukan"))?;
        Ok(parse_detail(d))
    }

    /// start | stop | restart | pause | unpause | rm
    pub async fn container_action(&self, id: String, action: String) -> Result<(), CoreError> {
        let id = safe(&id)?;
        let args: Vec<&str> = match action.as_str() {
            "start" | "stop" | "restart" | "pause" | "unpause" => vec![action.as_str(), id],
            "rm" => vec!["rm", "-f", id],
            a => return Err(err(format!("aksi {a} tidak dikenal"))),
        };
        self.docker(&args).await.map(|_| ())
    }

    pub async fn logs(&self, id: String, tail: u32) -> Result<String, CoreError> {
        let id = safe(&id)?;
        let tail = tail.clamp(10, 5000).to_string();
        self.docker(&["logs", "--tail", &tail, "--timestamps", id]).await
    }

    pub async fn remove_image(&self, id: String) -> Result<(), CoreError> {
        let id = safe(&id)?;
        self.docker(&["rmi", id]).await.map(|_| ())
    }

    /// up | stop | restart | down | pull — untuk proyek dari `compose_projects`.
    pub async fn compose_action(&self, project: String, config_files: String, action: String) -> Result<String, CoreError> {
        let mut args: Vec<String> = vec!["compose".into(), "-p".into(), safe(&project)?.to_string()];
        for f in config_files.split(',').map(str::trim).filter(|f| !f.is_empty()) {
            args.push("-f".into());
            args.push(safe(f)?.to_string());
        }
        match action.as_str() {
            "up" => args.extend(["up".into(), "-d".into()]),
            "stop" | "restart" | "down" | "pull" => args.push(action.clone()),
            a => return Err(err(format!("aksi {a} tidak dikenal"))),
        }
        let refs: Vec<&str> = args.iter().map(String::as_str).collect();
        self.docker(&refs).await
    }

    /// Perintah untuk membuka shell di dalam container (dijalankan di terminal app).
    pub fn exec_command(&self, id: String) -> Result<String, CoreError> {
        let id = safe(&id)?;
        let docker = match &self.target {
            Target::Local(bin) => quote(&bin.to_string_lossy()),
            Target::Ssh(_) => if self.sudo.load(Ordering::Relaxed) { "sudo docker".into() } else { "docker".into() },
        };
        Ok(if cfg!(windows) && matches!(self.target, Target::Local(_)) {
            // Terminal lokal Windows = PowerShell: path ber-kutip perlu operator &.
            format!("& {docker} exec -it {id} sh")
        } else {
            format!("{docker} exec -it {id} sh -c 'command -v bash >/dev/null && exec bash || exec sh'")
        })
    }

    pub async fn close(&self) {
        if let Target::Ssh(m) = &self.target {
            if let Some(h) = m.lock().await.take() {
                let _ = h.disconnect(russh::Disconnect::ByApplication, "", "en").await;
            }
        }
    }
}

impl DockerClient {
    /// Jalankan `docker <args>`; error berisi pesan dari Docker.
    async fn docker(&self, args: &[&str]) -> Result<String, CoreError> {
        let (code, out) = self.run(args, self.sudo.load(Ordering::Relaxed)).await?;
        if code != 0 && denied(&out) && matches!(self.target, Target::Ssh(_)) && !self.sudo.load(Ordering::Relaxed) {
            // User belum di grup docker: coba sudo tanpa password.
            let (c2, o2) = self.run(args, true).await?;
            if c2 == 0 {
                self.sudo.store(true, Ordering::Relaxed);
                return Ok(o2);
            }
            return Err(err(
                "User SSH ini belum punya akses Docker. Di server jalankan: sudo usermod -aG docker $USER (lalu login ulang), atau pakai user root.",
            ));
        }
        if code == 127 || out.contains("docker: command not found") || out.contains("docker: not found") {
            return Err(err("Docker belum terpasang di server ini"));
        }
        if code != 0 {
            let msg = out.lines().map(str::trim).filter(|l| !l.is_empty()).last().unwrap_or("perintah gagal").to_string();
            return Err(err(msg.trim_start_matches("Error response from daemon: ").to_string()));
        }
        Ok(out)
    }

    async fn run(&self, args: &[&str], sudo: bool) -> Result<(i32, String), CoreError> {
        match &self.target {
            Target::Local(bin) => {
                let bin = bin.clone();
                let args: Vec<String> = args.iter().map(|a| a.to_string()).collect();
                tokio::task::spawn_blocking(move || {
                    let mut cmd = std::process::Command::new(&bin);
                    cmd.args(&args);
                    // Plugin compose & credential helper ada di folder yang sama dengan docker.
                    if let Some(dir) = bin.parent() {
                        let path = std::env::var_os("PATH").unwrap_or_default();
                        let mut dirs = vec![dir.to_path_buf(), PathBuf::from("/usr/local/bin"), PathBuf::from("/opt/homebrew/bin")];
                        dirs.extend(std::env::split_paths(&path));
                        if let Ok(p) = std::env::join_paths(dirs) {
                            cmd.env("PATH", p);
                        }
                    }
                    #[cfg(windows)]
                    {
                        use std::os::windows::process::CommandExt;
                        cmd.creation_flags(0x0800_0000);
                    }
                    let o = cmd.output().map_err(|e| err(format!("gagal menjalankan docker: {e}")))?;
                    let mut s = String::from_utf8_lossy(&o.stdout).into_owned();
                    s.push_str(&String::from_utf8_lossy(&o.stderr));
                    Ok((o.status.code().unwrap_or(-1), s))
                })
                .await
                .map_err(|e| err(e.to_string()))?
            }
            Target::Ssh(m) => {
                let mut line = String::from("PATH=\"$PATH:/usr/local/bin:/usr/bin:/snap/bin:/opt/homebrew/bin\"; ");
                if sudo {
                    line.push_str("sudo -n ");
                }
                line.push_str("docker");
                for a in args {
                    line.push(' ');
                    line.push_str(&quote(a));
                }
                line.push_str(" 2>&1");
                let guard = m.lock().await;
                let h = guard.as_ref().ok_or_else(|| err("koneksi Docker sudah ditutup"))?;
                let run = async {
                    let mut ch = h.channel_open_session().await.map_err(|e| CoreError::Ssh { msg: e.to_string() })?;
                    ch.exec(true, line.as_str()).await.map_err(|e| CoreError::Ssh { msg: e.to_string() })?;
                    let mut out = Vec::new();
                    let mut code = 0i32;
                    while let Some(msg) = ch.wait().await {
                        match msg {
                            ChannelMsg::Data { data } | ChannelMsg::ExtendedData { data, .. } => out.extend_from_slice(&data),
                            ChannelMsg::ExitStatus { exit_status } => code = exit_status as i32,
                            ChannelMsg::Close => break,
                            _ => {}
                        }
                    }
                    Ok::<_, CoreError>((code, String::from_utf8_lossy(&out).into_owned()))
                };
                tokio::time::timeout(Duration::from_secs(120), run).await.map_err(|_| err("server tidak menjawab (120 detik)"))?
            }
        }
    }
}

fn json_lines(out: &str) -> Vec<Value> {
    out.lines().filter(|l| l.trim_start().starts_with('{')).filter_map(|l| serde_json::from_str(l).ok()).collect()
}

fn s(v: &Value, k: &str) -> String {
    match &v[k] {
        Value::String(s) => s.clone(),
        Value::Null => String::new(),
        other => other.to_string(),
    }
}

fn label(labels: &str, key: &str) -> String {
    labels
        .split(',')
        .find_map(|kv| kv.split_once('=').filter(|(k, _)| *k == key).map(|(_, v)| v.to_string()))
        .unwrap_or_default()
}

fn parse_container(v: &Value) -> DockerContainer {
    let labels = s(v, "Labels");
    DockerContainer {
        id: s(v, "ID"),
        name: s(v, "Names"),
        image: s(v, "Image"),
        state: s(v, "State").to_lowercase(),
        status: s(v, "Status"),
        ports: s(v, "Ports"),
        created: s(v, "RunningFor"),
        project: label(&labels, "com.docker.compose.project"),
        service: label(&labels, "com.docker.compose.service"),
    }
}

fn parse_detail(d: &Value) -> DockerDetail {
    let strs = |v: &Value| -> Vec<String> { v.as_array().map(|a| a.iter().filter_map(|x| x.as_str().map(str::to_string)).collect()).unwrap_or_default() };
    let mut command = vec![d["Path"].as_str().unwrap_or("").to_string()];
    command.extend(strs(&d["Args"]));
    let nets = d["NetworkSettings"]["Networks"].as_object();
    let mut ports: Vec<DockerPort> = vec![];
    if let Some(map) = d["NetworkSettings"]["Ports"].as_object() {
        for (inner, binds) in map {
            for b in binds.as_array().into_iter().flatten() {
                if let Some(p) = b["HostPort"].as_str().and_then(|p| p.parse().ok()) {
                    let host_ip = b["HostIp"].as_str().unwrap_or("").to_string();
                    // Lewati duplikat IPv6 (::) bila IPv4 sudah ada untuk port yang sama.
                    if !ports.iter().any(|x: &DockerPort| x.host_port == p && x.container_port == *inner) {
                        ports.push(DockerPort { host_ip, host_port: p, container_port: inner.clone() });
                    }
                }
            }
        }
    }
    ports.sort_by_key(|p| p.host_port);
    DockerDetail {
        id: d["Id"].as_str().unwrap_or("").to_string(),
        name: d["Name"].as_str().unwrap_or("").trim_start_matches('/').to_string(),
        image: d["Config"]["Image"].as_str().unwrap_or("").to_string(),
        command: command.into_iter().filter(|c| !c.is_empty()).collect::<Vec<_>>().join(" "),
        created: d["Created"].as_str().unwrap_or("").chars().take(19).collect::<String>().replace('T', " "),
        started_at: d["State"]["StartedAt"].as_str().unwrap_or("").chars().take(19).collect::<String>().replace('T', " "),
        restart_policy: d["HostConfig"]["RestartPolicy"]["Name"].as_str().unwrap_or("no").to_string(),
        health: d["State"]["Health"]["Status"].as_str().unwrap_or("").to_string(),
        ip_address: nets
            .and_then(|m| m.values().find_map(|n| n["IPAddress"].as_str().filter(|s| !s.is_empty()).map(str::to_string)))
            .unwrap_or_default(),
        networks: nets.map(|m| m.keys().cloned().collect()).unwrap_or_default(),
        ports,
        env: strs(&d["Config"]["Env"]),
        mounts: d["Mounts"]
            .as_array()
            .into_iter()
            .flatten()
            .map(|m| {
                let src = m["Name"].as_str().filter(|s| !s.is_empty()).or(m["Source"].as_str()).unwrap_or("");
                format!("{src} → {} ({})", m["Destination"].as_str().unwrap_or(""), if m["RW"].as_bool().unwrap_or(true) { "rw" } else { "ro" })
            })
            .collect(),
    }
}

fn pct(x: &str) -> f64 {
    x.trim().trim_end_matches('%').parse().unwrap_or(0.0)
}

fn parse_stat(v: &Value) -> DockerStat {
    DockerStat {
        id: s(v, "ID"),
        cpu_percent: pct(&s(v, "CPUPerc")),
        mem_percent: pct(&s(v, "MemPerc")),
        mem_usage: s(v, "MemUsage"),
        net_io: s(v, "NetIO"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_docker_json() {
        let ps = r#"{"ID":"5e0011e88bbe","Image":"traefik:v3.5","Labels":"com.docker.compose.project=ppra,com.docker.compose.service=traefik,x=y","Names":"ppra-traefik-1","Ports":"0.0.0.0:8000->8000/tcp","RunningFor":"About an hour ago","State":"running","Status":"Up About an hour"}
{"ID":"aa","Image":"alpine","Labels":"","Names":"solo","Ports":"","RunningFor":"2 days ago","State":"exited","Status":"Exited (0) 2 days ago"}"#;
        let v: Vec<DockerContainer> = json_lines(ps).iter().map(parse_container).collect();
        assert_eq!(v[0].project, "ppra");
        assert_eq!(v[0].service, "traefik");
        assert_eq!(v[0].state, "running");
        assert_eq!(v[1].project, "");
        let st = parse_stat(&serde_json::from_str(r#"{"ID":"5e","CPUPerc":"12.50%","MemPerc":"0.29%","MemUsage":"23.25MiB / 7.816GiB","NetIO":"1MB / 2MB"}"#).unwrap());
        assert_eq!(st.cpu_percent, 12.5);
        assert_eq!(st.mem_percent, 0.29);
    }

    #[test]
    fn parses_inspect() {
        let d: Value = serde_json::from_str(r#"{"Id":"abc","Name":"/web","Path":"/docker-entrypoint.sh","Args":["nginx","-g","daemon off;"],
          "Created":"2026-11-20T01:02:03.456Z","State":{"StartedAt":"2026-11-20T01:02:04.1Z","Health":{"Status":"healthy"}},
          "HostConfig":{"RestartPolicy":{"Name":"unless-stopped"}},"Config":{"Image":"nginx:alpine","Env":["A=1","SECRET=x"]},
          "Mounts":[{"Name":"data","Source":"/var/lib/x","Destination":"/data","RW":true}],
          "NetworkSettings":{"Networks":{"shop_default":{"IPAddress":"172.18.0.2"}},"Ports":{"80/tcp":[{"HostIp":"0.0.0.0","HostPort":"8080"},{"HostIp":"::","HostPort":"8080"}],"443/tcp":null}}}"#).unwrap();
        let x = parse_detail(&d);
        assert_eq!(x.name, "web");
        assert_eq!(x.command, "/docker-entrypoint.sh nginx -g daemon off;");
        assert_eq!(x.ports.len(), 1);
        assert_eq!(x.ports[0].host_port, 8080);
        assert_eq!(x.mounts, vec!["data → /data (rw)"]);
        assert_eq!(x.ip_address, "172.18.0.2");
        assert_eq!(x.health, "healthy");
        assert_eq!(x.created, "2026-11-20 01:02:03");
    }

    #[test]
    fn rejects_unsafe_names_and_quotes() {
        assert!(safe("ppra-traefik-1").is_ok());
        assert!(safe("/home/me/app/docker-compose.yml").is_ok());
        assert!(safe("x; rm -rf /").is_err());
        assert!(safe("$(id)").is_err());
        assert!(safe("--privileged").is_err());
        assert_eq!(quote("{{json .}}"), "'{{json .}}'");
        assert_eq!(quote("ps"), "ps");
        assert_eq!(quote("a b"), "'a b'");
        assert_eq!(quote("it's"), r"'it'\''s'");
    }
}
