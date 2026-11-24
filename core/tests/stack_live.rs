//! Tes Server Lokal sungguhan: mengunduh komponen (ratusan MB), menyalakan, lalu mematikan.
//! Tidak jalan otomatis — jalankan manual:
//!   ZTERM_STACK_ROOT=/tmp/zterm-stack ZTERM_STACK_ONLY=web,postgres cargo test --test stack_live -- --ignored --nocapture

use std::sync::Arc;

use zterm_core::{LocalStack, TransferProgress};

struct Print;
impl TransferProgress for Print {
    fn on_progress(&self, done: u64, total: u64, current_file: String) {
        if total > 0 && (done == total || done % (8 << 20) < 65536) {
            eprintln!("  {current_file}: {} / {} MB", done >> 20, total >> 20);
        }
    }
    fn is_cancelled(&self) -> bool {
        false
    }
}

fn http_get(port: u16, path: &str) -> String {
    use std::io::{Read, Write};
    let mut s = std::net::TcpStream::connect(("127.0.0.1", port)).unwrap();
    write!(s, "GET {path} HTTP/1.0\r\nHost: localhost\r\n\r\n").unwrap();
    let mut out = String::new();
    s.read_to_string(&mut out).unwrap();
    out
}

#[tokio::test(flavor = "multi_thread")]
#[ignore]
async fn stack_download_start_stop() {
    let root = std::env::var("ZTERM_STACK_ROOT").expect("ZTERM_STACK_ROOT");
    let only = std::env::var("ZTERM_STACK_ONLY").unwrap_or("web,postgres,mongodb,mysql".into());
    let st = LocalStack::new(root.clone()).unwrap();
    let mut s = st.settings();
    s.doc_root = format!("{root}/htdocs");
    s.web_port = 18080;
    s.mysql_port = 13306;
    s.postgres_port = 15432;
    s.mongodb_port = 27117;
    for server in ["nginx", "apache"] {
        if !only.split(',').any(|x| x == "web") || (server == "apache" && !cfg!(target_os = "macos") && !only.contains("apache")) {
            continue;
        }
        s.web_server = server.into();
        st.set_settings(s.clone()).unwrap();
        for id in st.services().into_iter().find(|x| x.id == "web").unwrap().missing {
            eprintln!("install {id}");
            st.install(id, Arc::new(Print)).await.unwrap();
        }
        st.start("web".into()).await.unwrap_or_else(|e| panic!("{server}: {e}\n{}", st.log_tail("web".into(), 20)));
        let page = http_get(18080, "/");
        assert!(page.contains("Server lokal siap"), "{server}: {page}");
        assert!(page.contains("PHP <b>8."), "{server}: {page}");
        eprintln!("{server} OK: {}", page.lines().next().unwrap_or(""));
        st.stop("web".into()).await.unwrap();
        assert!(std::net::TcpStream::connect(("127.0.0.1", 18080)).is_err(), "{server} masih jalan");
    }
    for (db, port) in [("postgres", 15432), ("mongodb", 27117), ("mysql", 13306)] {
        if !only.split(',').any(|x| x == db) {
            continue;
        }
        if st.services().into_iter().find(|x| x.id == db).unwrap().missing.contains(&db.to_string()) {
            eprintln!("install {db}");
            st.install(db.into(), Arc::new(Print)).await.unwrap();
        }
        let t = std::time::Instant::now();
        st.start(db.into()).await.unwrap_or_else(|e| panic!("{db}: {e}\n{}", st.log_tail(db.into(), 30)));
        assert!(std::net::TcpStream::connect(("127.0.0.1", port)).is_ok());
        assert!(st.services().into_iter().find(|x| x.id == db).unwrap().running);
        eprintln!("{db} OK in {:?}", t.elapsed());
        st.stop(db.into()).await.unwrap();
        std::thread::sleep(std::time::Duration::from_millis(500));
        assert!(std::net::TcpStream::connect(("127.0.0.1", port)).is_err(), "{db} masih jalan");
    }
}
