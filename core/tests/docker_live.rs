//! Tes Docker sungguhan (butuh Docker berjalan). Hanya membaca container yang sudah ada;
//! aksi start/stop/hapus hanya pada container sementara `zterm-test-docker-*`.
//!   cargo test --test docker_live -- --ignored --nocapture
//! Lewat SSH juga: ZTERM_TEST_SSH=user@127.0.0.1:2222 ZTERM_TEST_SSH_KEY=/path/key

use std::process::Command;
use std::sync::Arc;

use zterm_core::{DockerClient, SshTarget};

async fn exercise(d: Arc<DockerClient>, label: &str) {
    let info = d.info().await.unwrap();
    eprintln!("[{label}] Docker {} · {} · {} container ({} jalan) · {} image", info.version, info.os, info.containers, info.running, info.images);
    let before = d.containers().await.unwrap();
    eprintln!("[{label}] containers: {}", before.len());
    let _ = d.images().await.unwrap();
    let projects = d.compose_projects().await.unwrap();
    eprintln!("[{label}] compose: {:?}", projects.iter().map(|p| &p.name).collect::<Vec<_>>());

    let name = format!("zterm-test-docker-{}-{label}", std::process::id());
    let ok = Command::new("docker")
        .args(["run", "-d", "--name", &name, "alpine:3", "sh", "-c", "echo halo-zterm; sleep 600"])
        .env("PATH", format!("/usr/local/bin:{}", std::env::var("PATH").unwrap_or_default()))
        // Tes SSH memakai HOME sementara (known_hosts); docker CLI butuh HOME asli untuk context-nya.
        .env("HOME", std::env::var("ZTERM_REAL_HOME").or_else(|_| std::env::var("HOME")).unwrap_or_default())
        .status()
        .unwrap()
        .success();
    assert!(ok, "docker run gagal");
    let find = |list: &[zterm_core::DockerContainer]| list.iter().find(|c| c.name == name).cloned();
    let c = find(&d.containers().await.unwrap()).expect("container tes terlihat");
    assert_eq!(c.state, "running");
    let stats = d.stats().await.unwrap();
    assert!(stats.iter().any(|s| c.id.starts_with(&s.id) || s.id.starts_with(&c.id)), "stats memuat container tes");
    let detail = d.inspect(c.id.clone()).await.unwrap();
    assert_eq!(detail.name, name);
    assert!(detail.command.contains("sleep 600"), "{}", detail.command);
    let vols = d.volumes().await.unwrap();
    let nets = d.networks().await.unwrap();
    eprintln!("[{label}] volumes: {} · networks: {} · ip {}", vols.len(), nets.len(), detail.ip_address);
    assert!(nets.iter().any(|n| n.name == "bridge" && n.builtin));
    let logs = d.logs(c.id.clone(), 50).await.unwrap();
    assert!(logs.contains("halo-zterm"), "{logs}");

    d.container_action(c.id.clone(), "stop".into()).await.unwrap();
    assert_eq!(find(&d.containers().await.unwrap()).unwrap().state, "exited");
    d.container_action(c.id.clone(), "start".into()).await.unwrap();
    d.container_action(c.id.clone(), "restart".into()).await.unwrap();
    assert_eq!(find(&d.containers().await.unwrap()).unwrap().state, "running");
    assert!(d.container_action("x; rm -rf /".into(), "stop".into()).await.is_err());
    assert!(d.container_action(c.id.clone(), "kill-all".into()).await.is_err());
    assert!(d.exec_command(c.id.clone()).unwrap().contains("exec -it"));
    d.container_action(c.id.clone(), "rm".into()).await.unwrap();
    assert!(find(&d.containers().await.unwrap()).is_none());

    // Container milik user tidak tersentuh
    let after = d.containers().await.unwrap();
    for b in &before {
        let a = after.iter().find(|a| a.id == b.id).expect("container lama masih ada");
        assert_eq!(a.state, b.state, "{}", b.name);
    }
    let missing = d.logs("tidak-ada-container-ini".into(), 10).await.unwrap_err();
    eprintln!("[{label}] error contoh: {missing}");
    d.close().await;
}

#[tokio::test(flavor = "multi_thread")]
#[ignore]
async fn docker_local_and_ssh() {
    exercise(DockerClient::local().unwrap(), "local").await;
    if let (Ok(t), Ok(key)) = (std::env::var("ZTERM_TEST_SSH"), std::env::var("ZTERM_TEST_SSH_KEY")) {
        let (user, rest) = t.split_once('@').unwrap();
        let (host, port) = rest.rsplit_once(':').unwrap();
        let target = SshTarget {
            hostname: host.into(),
            port: port.parse().unwrap(),
            username: user.into(),
            password: None,
            private_key: Some(std::fs::read_to_string(key).unwrap()),
            passphrase: None,
            use_agent: false,
            proxy: None,
        };
        exercise(DockerClient::connect(target).await.unwrap(), "ssh").await;
    }
}
