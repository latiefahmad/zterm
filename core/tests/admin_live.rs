//! Tes ServerAdmin ke server Linux dengan systemd (lihat scripts/test-admin.sh).
//! Butuh ZTERM_TEST_ADMIN_PORT + ZTERM_TEST_ADMIN_KEY; user `root`, `deploy` (sudo NOPASSWD), `biasa` (tanpa sudo).
use zterm_core::{run_remote, CronJob, CronLine, ServerAdmin, SshTarget};

fn target(user: &str) -> Option<SshTarget> {
    let port = std::env::var("ZTERM_TEST_ADMIN_PORT").ok()?.parse().ok()?;
    let key = std::fs::read_to_string(std::env::var("ZTERM_TEST_ADMIN_KEY").ok()?).ok()?;
    Some(SshTarget { hostname: "127.0.0.1".into(), port, username: user.into(), password: None, private_key: Some(key), passphrase: None, use_agent: false, proxy: None })
}

#[tokio::test]
#[ignore]
async fn admin_live() {
    let Some(t) = target("deploy") else { panic!("ZTERM_TEST_ADMIN_PORT/KEY belum diset") };
    let a = ServerAdmin::connect(t).await.unwrap();
    let sys = a.system().await.unwrap();
    assert!(sys.sudo && !sys.is_root && sys.systemd && sys.journal && sys.crontab, "{sys:?}");

    // Proses: nginx master milik root, worker www-data
    let ps = a.processes().await.unwrap();
    assert!(ps.iter().any(|p| p.command.starts_with("nginx: master") && p.user == "root"));
    // Kill proses milik root → lewat sudo
    run_remote(target("root").unwrap(), "nohup sleep 9999 >/dev/null 2>&1 &".into(), 10).await.unwrap();
    let ps = a.processes().await.unwrap();
    let sleeper = ps.iter().find(|p| p.command == "sleep 9999").expect("sleep 9999");
    a.kill(sleeper.pid, false).await.unwrap();
    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
    assert!(!a.processes().await.unwrap().iter().any(|p| p.pid == sleeper.pid));

    // Service: stop / start nginx lewat sudo
    let svc = a.services().await.unwrap();
    let nginx = svc.iter().find(|s| s.name == "nginx").unwrap();
    assert_eq!((nginx.active.as_str(), nginx.enabled.as_str()), ("active", "enabled"));
    a.service_action("nginx".into(), "stop".into()).await.unwrap();
    assert_eq!(a.services().await.unwrap().iter().find(|s| s.name == "nginx").unwrap().active, "inactive");
    a.service_action("nginx".into(), "start".into()).await.unwrap();
    assert!(a.service_status("nginx".into()).await.unwrap().contains("active (running)"));

    // Cron: simpan, baca lagi, nonaktifkan
    let lines = vec![
        CronLine { raw: "# dibuat tes".into(), job: None },
        CronLine { raw: String::new(), job: Some(CronJob { schedule: "*/5 * * * *".into(), command: "date >> /tmp/zterm-cron.log".into(), enabled: true }) },
        CronLine { raw: String::new(), job: Some(CronJob { schedule: "30 2 * * 1-5".into(), command: "echo off".into(), enabled: false }) },
    ];
    a.cron_save(lines).await.unwrap();
    let back = a.cron_list().await.unwrap();
    assert_eq!(back.len(), 3);
    assert!(back[1].job.as_ref().unwrap().enabled && !back[2].job.as_ref().unwrap().enabled);
    assert!(a.cron_save(vec![CronLine { raw: String::new(), job: Some(CronJob { schedule: "99 * *".into(), command: "x".into(), enabled: true }) }]).await.is_err());
    a.cron_save(vec![]).await.unwrap();
    assert!(a.cron_list().await.unwrap().is_empty());

    // Log: journal (sudo) + file nginx, mode ikuti
    let src = a.log_sources().await.unwrap();
    assert!(src.iter().any(|s| s.is_journal));
    let j = a.read_log("journal".into(), 50, String::new(), "nginx".into(), String::new()).await.unwrap();
    assert!(j.via_sudo && j.text.contains("nginx") && !j.cursor.is_empty(), "{j:?}");
    let f = "/var/log/nginx/error.log".to_string();
    let first = a.read_log(f.clone(), 20, String::new(), String::new(), String::new()).await.unwrap();
    run_remote(target("root").unwrap(), format!("echo zterm-baris-baru >> {f}"), 10).await.unwrap();
    let next = a.read_log(f.clone(), 20, first.cursor.clone(), String::new(), String::new()).await.unwrap();
    assert_eq!(next.text.trim(), "zterm-baris-baru", "{next:?}");
    a.close().await;

    // User tanpa sudo: aksi root ditolak dengan pesan jelas
    let b = ServerAdmin::connect(target("biasa").unwrap()).await.unwrap();
    let sys = b.system().await.unwrap();
    assert!(!sys.sudo && !sys.is_root);
    let e = b.service_action("nginx".into(), "restart".into()).await.unwrap_err().to_string();
    assert!(e.contains("Butuh akses root"), "{e}");
    b.close().await;

    // Root langsung
    let r = ServerAdmin::connect(target("root").unwrap()).await.unwrap();
    assert!(r.system().await.unwrap().is_root);
    r.service_action("cron".into(), "restart".into()).await.unwrap();
    r.close().await;
}
