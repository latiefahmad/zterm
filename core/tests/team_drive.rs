//! Tes alur Tim lewat Google Drive tiruan (`scripts/mock-drive.py`): buat tim, undang, gabung
//! lewat "Picker", bagikan host, keluarkan anggota. Butuh python3.

use std::process::{Child, Command};
use std::sync::Arc;
use std::time::Duration;

use zterm_core::{AuthMethod, CoreError, Host, MemberStatus, TeamStatus, Vault};

struct Mock(Child, String);
impl Drop for Mock {
    fn drop(&mut self) {
        self.0.kill().ok();
    }
}

fn start_mock() -> Mock {
    let port = 18790 + (std::process::id() % 500) as u16;
    let script = concat!(env!("CARGO_MANIFEST_DIR"), "/../scripts/mock-drive.py");
    let child = Command::new("python3").args([script, "127.0.0.1", &port.to_string()]).spawn().expect("python3");
    let base = format!("http://127.0.0.1:{port}");
    for _ in 0..50 {
        if std::net::TcpStream::connect(("127.0.0.1", port)).is_ok() {
            break;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    Mock(child, base)
}

fn vault(name: &str) -> (Arc<Vault>, String) {
    let p = std::env::temp_dir().join(format!("zterm-test-team-{name}-{}.zterm", std::process::id()));
    std::fs::remove_file(&p).ok();
    let p = p.to_string_lossy().into_owned();
    (Vault::create(p.clone(), "rahasia123".into()).unwrap(), p)
}

fn host(label: &str) -> Host {
    Host {
        id: String::new(), label: label.into(), hostname: format!("{label}.internal"), group: None, port: 22,
        username: "deploy".into(), auth: AuthMethod::Password, password: Some("pw-".to_string() + label), key_id: None,
        agent_forwarding: false, startup_snippet: None, jump_host_id: None, proxy: None, env: vec![],
        charset: "UTF-8".into(), terminal_theme: None, tags: vec![], color: "#3fd0b4".into(), updated_at: 0, deleted: false,
    }
}

fn pick(base: &str, email: &str, file: &str) {
    let out = Command::new("curl").args(["-s", "-X", "POST", &format!("{base}/pick?email={email}&file={file}")]).output().unwrap();
    assert!(String::from_utf8_lossy(&out.stdout).contains("ok"));
}

#[tokio::test(flavor = "multi_thread")]
async fn team_flow_over_drive() {
    let mock = start_mock();
    // SAFETY: tes tunggal di proses ini yang memakai variabel ini.
    unsafe { std::env::set_var("ZTERM_DRIVE_BASE", &mock.1) };
    let admin_tok = "tok-admin@x.com".to_string();
    let budi_tok = "tok-budi@x.com".to_string();

    let (admin, pa) = vault("admin");
    let (budi, pb) = vault("budi");
    let web = admin.upsert_host(host("web")).unwrap();
    let _db = admin.upsert_host(host("db")).unwrap();

    // Admin membuat tim, membagikan host "web", mengundang Budi
    let t = admin.team_create(admin_tok.clone(), "Ops".into(), "admin@x.com".into()).await.unwrap();
    admin.team_share_hosts(admin_tok.clone(), t.id.clone(), vec![web.id.clone()]).await.unwrap();
    let t = admin.team_invite(admin_tok.clone(), t.id.clone(), "Budi@X.com".into()).await.unwrap();
    assert_eq!(t.members.len(), 2);
    assert_eq!(t.members[1].status, MemberStatus::Invited);
    assert!(matches!(admin.team_invite(admin_tok.clone(), t.id.clone(), "budi@x.com".into()).await, Err(CoreError::Team { .. })));

    // Budi belum memilih file lewat Picker → belum terlihat
    assert!(budi.team_find_invites(budi_tok.clone()).await.unwrap().is_empty());
    assert!(budi.team_join(budi_tok.clone(), t.file_id.clone(), "budi@x.com".into()).await.is_err());

    // Setelah Picker: undangan terlihat, gabung → menunggu kunci dari admin
    pick(&mock.1, "budi@x.com", &t.file_id);
    let inv = budi.team_find_invites(budi_tok.clone()).await.unwrap();
    assert_eq!(inv.len(), 1);
    assert_eq!(inv[0].name, "Ops");
    assert_eq!(inv[0].owner_email, "admin@x.com");
    let bt = budi.team_join(budi_tok.clone(), inv[0].file_id.clone(), "budi@x.com".into()).await.unwrap();
    assert_eq!(bt.status, TeamStatus::Waiting);
    assert!(budi.team_hosts().is_empty());

    // Admin sync → membungkus kunci untuk Budi; Budi sync → host tim muncul
    assert!(admin.team_sync(admin_tok.clone()).await.unwrap());
    assert_eq!(admin.teams()[0].members[1].status, MemberStatus::Joined);
    assert!(budi.team_sync(budi_tok.clone()).await.unwrap());
    let hosts = budi.team_hosts();
    assert_eq!(hosts.len(), 1);
    assert_eq!(hosts[0].label, "web");
    assert_eq!(hosts[0].password.as_deref(), Some("pw-web"));
    assert!(hosts[0].id.starts_with("team:"));
    assert_eq!(hosts[0].group.as_deref(), Some("Tim · Ops"));
    assert_eq!(budi.teams()[0].status, TeamStatus::Active);

    // Admin mengubah host → setelah sync, Budi melihat perubahan
    let mut w = web.clone();
    w.hostname = "web2.internal".into();
    admin.upsert_host(w).unwrap();
    admin.team_sync(admin_tok.clone()).await.unwrap();
    budi.team_sync(budi_tok.clone()).await.unwrap();
    assert_eq!(budi.team_hosts()[0].hostname, "web2.internal");
    // Tanpa perubahan → sync tidak mengubah apa pun
    assert!(!budi.team_sync(budi_tok.clone()).await.unwrap());

    // Budi dikeluarkan → izin dicabut, host tim hilang
    admin.team_remove_member(admin_tok.clone(), t.id.clone(), "budi@x.com".into()).await.unwrap();
    assert_eq!(admin.teams()[0].members.len(), 1);
    budi.team_sync(budi_tok.clone()).await.unwrap();
    assert_eq!(budi.teams()[0].status, TeamStatus::Revoked);
    assert!(budi.team_hosts().is_empty());

    // Token kedaluwarsa → GoogleAuth
    assert!(matches!(admin.team_sync("bukan-token".into()).await, Err(CoreError::GoogleAuth)));

    // Admin menghapus tim
    admin.team_leave(admin_tok.clone(), t.id.clone()).await.unwrap();
    assert!(admin.teams().is_empty());
    budi.team_leave(budi_tok.clone(), bt.id.clone()).await.unwrap();
    assert!(budi.teams().is_empty());

    for p in [pa, pb] {
        std::fs::remove_file(p).ok();
    }
}
