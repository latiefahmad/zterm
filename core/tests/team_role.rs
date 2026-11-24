//! Regresi: admin tidak boleh turun jadi anggota saat vault yang sama dipakai ganti akun Google lalu disinkron.
//! Memakai Drive tiruan (`scripts/mock-drive.py`) dan vault sementara. Butuh python3.

use std::process::{Child, Command};
use std::sync::Arc;
use std::time::Duration;

use zterm_core::{AuthMethod, Host, MemberStatus, TeamStatus, Vault};

struct Mock(Child, String);
impl Drop for Mock {
    fn drop(&mut self) {
        self.0.kill().ok();
    }
}

fn start_mock() -> Mock {
    let port = 19390 + (std::process::id() % 500) as u16;
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
    let p = std::env::temp_dir().join(format!("zterm-test-team-role-{name}-{}.zterm", std::process::id()));
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
async fn admin_role_is_kept_and_restored() {
    let mock = start_mock();
    // SAFETY: tes tunggal di proses ini yang memakai variabel ini.
    unsafe { std::env::set_var("ZTERM_DRIVE_BASE", &mock.1) };
    let (admin_tok, dev_tok) = ("tok-admin@x.com".to_string(), "tok-dev@x.com".to_string());

    let (admin, pa) = vault("admin");
    admin.set_account_email(Some("admin@x.com".into())).unwrap();
    let web = admin.upsert_host(host("web")).unwrap();

    // Salinan vault (salt & password sama) dari sebelum tim dibuat
    let pb = format!("{pa}.copy");
    std::fs::write(&pb, admin.encrypted_blob().unwrap()).unwrap();
    let copy = Vault::unlock(pb.clone(), "rahasia123".into()).unwrap();

    let t = admin.team_create(admin_tok.clone(), "Ops".into(), "admin@x.com".into()).await.unwrap();
    admin.team_share_hosts(admin_tok.clone(), t.id.clone(), vec![web.id.clone()]).await.unwrap();
    admin.team_invite(admin_tok.clone(), t.id.clone(), "dev@x.com".into()).await.unwrap();

    // Salinan itu login akun undangan dan bergabung: record anggota lebih baru daripada record admin
    tokio::time::sleep(Duration::from_millis(5)).await;
    copy.set_account_email(Some("dev@x.com".into())).unwrap();
    pick(&mock.1, "dev@x.com", &t.file_id);
    assert!(!copy.team_join(dev_tok, t.file_id.clone(), "dev@x.com".into()).await.unwrap().is_owner);

    admin.merge_remote(copy.encrypted_blob().unwrap()).unwrap();
    let after = &admin.teams()[0];
    assert!(after.is_owner, "admin turun jadi anggota setelah sync: {:?}", after.status);
    assert_eq!(after.status, TeamStatus::Active);
    assert_eq!(after.shared_host_ids, vec![web.id.clone()]);

    assert!(admin.merge_remote(copy.encrypted_blob().unwrap()).unwrap().remote_outdated, "perbaikan harus diunggah");
    // Arah sebaliknya: salinan anggota menerima peran admin
    copy.merge_remote(admin.encrypted_blob().unwrap()).unwrap();
    assert!(copy.teams()[0].is_owner);

    for p in [pa, pb] {
        std::fs::remove_file(p).ok();
    }

    repairs_demoted_vault(&mock.1).await;
    admin_email_is_not_proof(&mock.1).await;
}

/// Vault yang sudah telanjur turun: memegang kunci admin, tapi record timnya anggota.
async fn repairs_demoted_vault(base: &str) {
    let (admin_tok, dev_tok) = ("tok-boss@x.com".to_string(), "tok-staff@x.com".to_string());
    let (admin, pa) = vault("boss");
    let web = admin.upsert_host(host("web")).unwrap();
    admin.team_create(admin_tok.clone(), "Awal".into(), "boss@x.com".into()).await.unwrap(); // membuat kunci admin
    let pb = format!("{pa}.copy");
    std::fs::write(&pb, admin.encrypted_blob().unwrap()).unwrap();
    let broken = Vault::unlock(pb.clone(), "rahasia123".into()).unwrap();

    // Host ini tidak ada di vault yang rusak
    let db = admin.upsert_host(host("db")).unwrap();
    let t = admin.team_create(admin_tok.clone(), "Ops".into(), "boss@x.com".into()).await.unwrap();
    let mut shared = vec![web.id.clone(), db.id.clone()];
    shared.sort();
    admin.team_share_hosts(admin_tok.clone(), t.id.clone(), shared.clone()).await.unwrap();
    admin.team_invite(admin_tok.clone(), t.id.clone(), "staff@x.com".into()).await.unwrap();
    pick(base, "staff@x.com", &t.file_id);
    assert!(!broken.team_join(dev_tok.clone(), t.file_id.clone(), "staff@x.com".into()).await.unwrap().is_owner);
    // Edit lokal tidak boleh tertimpa isi file tim
    broken.upsert_host(Host { hostname: "baru.internal".into(), ..web.clone() }).unwrap();

    broken.set_account_email(Some("boss@x.com".into())).unwrap();
    assert!(broken.team_sync(admin_tok.clone()).await.unwrap());
    let fixed = broken.teams().into_iter().find(|x| x.id == t.id).unwrap();
    assert!(fixed.is_owner);
    assert_eq!((fixed.status, fixed.error), (TeamStatus::Active, None));
    let mut ids = fixed.shared_host_ids;
    ids.sort();
    assert_eq!(ids, shared);
    let hosts = broken.hosts();
    assert!(hosts.iter().any(|h| h.id == db.id && h.password.as_deref() == Some("pw-db")));
    assert!(hosts.iter().any(|h| h.id == web.id && h.hostname == "baru.internal"));
    assert!(broken.team_hosts().is_empty());

    // Admin yang pulih tetap bisa memberi kunci ke anggota sungguhan
    let (staff, ps) = vault("staff");
    staff.team_join(dev_tok.clone(), t.file_id.clone(), "staff@x.com".into()).await.unwrap();
    broken.team_sync(admin_tok).await.unwrap();
    staff.team_sync(dev_tok).await.unwrap();
    assert_eq!(staff.teams()[0].status, TeamStatus::Active);
    assert!(!staff.teams()[0].is_owner);
    let mut names: Vec<_> = staff.team_hosts().into_iter().map(|h| h.hostname).collect();
    names.sort();
    assert_eq!(names, ["baru.internal", "db.internal"]);
    let fixed = broken.teams().into_iter().find(|x| x.id == t.id).unwrap();
    assert!(fixed.members.iter().any(|m| m.email == "staff@x.com" && m.status == MemberStatus::Joined));

    for p in [pa, pb, ps] {
        std::fs::remove_file(p).ok();
    }
}

/// Email admin saja tidak menjadikan vault lain admin, dan tidak mengirim permintaan kunci ke diri sendiri.
async fn admin_email_is_not_proof(base: &str) {
    let (owner_tok, guest_tok) = ("tok-owner@x.com".to_string(), "tok-guest@x.com".to_string());
    let (owner, po) = vault("owner");
    let t = owner.team_create(owner_tok.clone(), "Lain".into(), "owner@x.com".into()).await.unwrap();
    owner.team_invite(owner_tok.clone(), t.id.clone(), "guest@x.com".into()).await.unwrap();
    let (guest, pg) = vault("guest");
    pick(base, "guest@x.com", &t.file_id);
    guest.team_join(guest_tok, t.file_id.clone(), "guest@x.com".into()).await.unwrap();

    let file = || Command::new("curl").args(["-sf", &format!("{base}/debug")]).output().unwrap().stdout;
    let before = file();
    guest.set_account_email(Some("owner@x.com".into())).unwrap();
    guest.team_sync(owner_tok).await.unwrap();
    let g = &guest.teams()[0];
    assert!(!g.is_owner);
    assert!(g.error.as_deref().is_some_and(|e| e.contains("kunci admin tidak ada")), "{:?}", g.error);
    assert_eq!(file(), before, "file tim tidak boleh ditulis");

    for p in [po, pg] {
        std::fs::remove_file(p).ok();
    }
}
