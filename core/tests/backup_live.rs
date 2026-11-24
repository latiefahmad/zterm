//! Tes backup & restore lewat SSH ke server dengan MariaDB + PostgreSQL (db `toko`, user app/rahasia).
//! Butuh ZTERM_TEST_ADMIN_PORT + ZTERM_TEST_ADMIN_KEY (user `deploy` & `root`).
use std::io::Read;
use std::sync::Arc;

use zterm_core::{backup_database, restore_database, run_remote, DbConnection, DbEngine, SshTarget, TransferProgress};

struct P;
impl TransferProgress for P {
    fn on_progress(&self, _: u64, _: u64, _: String) {}
    fn is_cancelled(&self) -> bool { false }
}

fn target(user: &str) -> SshTarget {
    let port = std::env::var("ZTERM_TEST_ADMIN_PORT").unwrap().parse().unwrap();
    let key = std::fs::read_to_string(std::env::var("ZTERM_TEST_ADMIN_KEY").unwrap()).unwrap();
    SshTarget { hostname: "127.0.0.1".into(), port, username: user.into(), password: None, private_key: Some(key), passphrase: None, use_agent: false, proxy: None }
}

fn conn(engine: DbEngine, port: u16) -> DbConnection {
    DbConnection {
        id: String::new(), label: "toko".into(), engine, host: "127.0.0.1".into(), port, username: "app".into(), password: Some("rahasia".into()),
        database: "toko".into(), file_path: String::new(), tls: false, ssh_host_id: Some("x".into()), color: String::new(), updated_at: 0, deleted: false,
    }
}

async fn sh(cmd: &str) -> String {
    run_remote(target("root"), cmd.into(), 30).await.unwrap().output
}

fn gunzip(path: &str) -> String {
    let mut s = String::new();
    flate2::read::GzDecoder::new(std::fs::File::open(path).unwrap()).read_to_string(&mut s).unwrap();
    s
}

#[tokio::test]
#[ignore]
async fn backup_restore_over_ssh() {
    let dir = std::env::temp_dir().join(format!("zterm-backup-{}", std::process::id()));
    let p = Arc::new(P);

    // MariaDB
    let f = dir.join("toko.sql.gz").to_string_lossy().into_owned();
    let r = backup_database(conn(DbEngine::Mariadb, 3306), Some(target("deploy")), f.clone(), vec![], p.clone()).await.unwrap();
    assert_eq!(r.location, "server");
    let sql = gunzip(&f);
    assert!(sql.contains("CREATE TABLE `produk`") && sql.contains("Kopi Gayo"), "{}", &sql[..sql.len().min(400)]);
    sh("mariadb -e 'DROP TABLE toko.produk'").await;
    restore_database(conn(DbEngine::Mariadb, 3306), Some(target("deploy")), f.clone(), vec![], p.clone()).await.unwrap();
    assert_eq!(sh("mariadb -N -e 'select count(*) from toko.produk'").await.trim(), "3");

    // PostgreSQL
    let g = dir.join("toko-pg.sql.gz").to_string_lossy().into_owned();
    backup_database(conn(DbEngine::Postgres, 5432), Some(target("deploy")), g.clone(), vec![], p.clone()).await.unwrap();
    assert!(gunzip(&g).contains("CREATE TABLE public.pelanggan"));
    sh("PGPASSWORD=rahasia psql -h 127.0.0.1 -U app toko -q -c 'DELETE FROM pelanggan'").await;
    restore_database(conn(DbEngine::Postgres, 5432), Some(target("deploy")), g.clone(), vec![], p.clone()).await.unwrap();
    assert_eq!(sh("PGPASSWORD=rahasia psql -h 127.0.0.1 -U app toko -tAc 'select count(*) from pelanggan'").await.trim(), "2");

    // Password salah → pesan jelas, file sementara tidak tertinggal
    let mut bad = conn(DbEngine::Mariadb, 3306);
    bad.password = Some("salah".into());
    let e = backup_database(bad, Some(target("deploy")), dir.join("x.sql.gz").to_string_lossy().into_owned(), vec![], p.clone()).await.unwrap_err().to_string();
    assert!(e.contains("Access denied"), "{e}");
    assert!(!dir.join("x.part").exists() && !dir.join("x.sql.gz").exists());

    // Alat tidak ada di server
    let e = backup_database(conn(DbEngine::Mongodb, 27017), Some(target("deploy")), dir.join("m.archive.gz").to_string_lossy().into_owned(), vec![], p).await.unwrap_err().to_string();
    assert!(e.contains("mongodump tidak ditemukan di server"), "{e}");
    let _ = std::fs::remove_dir_all(dir);
}

/// Mode lokal: MySQL di 127.0.0.1 (ZTERM_TEST_LOCAL_MYSQL_PORT, root/rahasia, db `toko`), alat dump di komputer ini.
#[tokio::test]
#[ignore]
async fn backup_restore_local() {
    let port: u16 = std::env::var("ZTERM_TEST_LOCAL_MYSQL_PORT").unwrap().parse().unwrap();
    let mut c = conn(DbEngine::Mysql, port);
    c.username = "root".into();
    c.ssh_host_id = None;
    let f = std::env::temp_dir().join(format!("zterm-local-{}.sql.gz", std::process::id())).to_string_lossy().into_owned();
    let r = backup_database(c.clone(), None, f.clone(), vec![], Arc::new(P)).await.unwrap();
    assert_eq!(r.location, "lokal");
    assert!(gunzip(&f).contains("INSERT INTO `produk`"));
    restore_database(c, None, f.clone(), vec![], Arc::new(P)).await.unwrap();
    let _ = std::fs::remove_file(f);
}
