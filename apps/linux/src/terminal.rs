//! Satu tab terminal = satu proses `ssh` (atau shell lokal) di dalam VTE.
//!
//! Sama seperti versi Mac: memakai OpenSSH sistem (key, agent, known_hosts, ProxyJump).
//! Password/passphrase dijawab lewat skrip askpass dari variabel lingkungan, bukan argumen.

use std::cell::{Cell, RefCell};
use std::path::PathBuf;
use std::rc::Rc;

use adw::prelude::*;
use zterm_core::{AuthMethod, Host, ProxyKind, SshKey};
use gtk::{gio, glib};
use vte::prelude::*;

use crate::config;
use crate::ctx::{self, Ctx};
use crate::theme;

pub struct Session {
    pub host: Host,
    pub local: bool,
    key: Option<SshKey>,
    jump: Option<Host>,
    run: Option<String>,
    pub term: vte::Terminal,
    banner: adw::Banner,
    page: RefCell<Option<adw::TabPage>>,
    temp_files: RefCell<Vec<PathBuf>>,
    log_id: RefCell<Option<String>>,
    got_data: Cell<bool>,
    running: Cell<bool>,
    ctx: std::rc::Weak<crate::ctx::App>,
}

impl Session {
    pub fn is_connected(&self) -> bool {
        self.running.get() && self.got_data.get()
    }

    pub fn page(&self) -> Option<adw::TabPage> {
        self.page.borrow().clone()
    }

    /// Kirim teks ke terminal (dipakai snippet).
    pub fn send(&self, text: &str) {
        self.term.feed_child(text.as_bytes());
    }

    fn start(self: &Rc<Self>) {
        self.cleanup();
        self.got_data.set(false);
        self.banner.set_revealed(false);
        if let Some(p) = self.page() {
            p.set_loading(true);
        }

        let (argv, env) = if self.local {
            local_command()
        } else {
            let cmd = SshCommand::build(&self.host, self.key.as_ref(), self.jump.as_ref());
            *self.temp_files.borrow_mut() = cmd.temp_files.clone();
            if let Some(v) = self.ctx.upgrade().and_then(|c| c.vault()) {
                *self.log_id.borrow_mut() =
                    v.start_log(self.host.id.clone(), ctx::host_title(&self.host), ctx::host_address(&self.host, false)).ok();
            }
            (cmd.args, cmd.env)
        };
        let (argv, env) = wrap_for_sandbox(argv, env);
        let argv_refs: Vec<&str> = argv.iter().map(String::as_str).collect();
        let env_refs: Vec<&str> = env.iter().map(String::as_str).collect();
        let home = config::home().to_string_lossy().into_owned();

        self.running.set(true);
        let weak = Rc::downgrade(self);
        let program = argv[0].clone();
        self.term.spawn_async(
            vte::PtyFlags::DEFAULT,
            Some(&home),
            &argv_refs,
            &env_refs,
            glib::SpawnFlags::SEARCH_PATH,
            || {},
            -1,
            gio::Cancellable::NONE,
            move |res| {
                if let (Err(e), Some(s)) = (res, weak.upgrade()) {
                    s.term.feed(format!("\r\n{}\r\n", tr!("Gagal menjalankan {}: {}", program, e.message())).as_bytes());
                    s.ended(None);
                }
            },
        );
    }

    fn ended(&self, code: Option<i32>) {
        if !self.running.replace(false) {
            return;
        }
        self.cleanup();
        self.finish_log(code);
        self.term.feed(format!("\r\n\x1b[2m— {} —\x1b[0m\r\n", tr!("sesi berakhir")).as_bytes());
        let title = match code {
            Some(0) | None => tr!("Sesi berakhir"),
            Some(c) => tr!("Sesi berakhir (kode {})", c),
        };
        self.banner.set_title(&title);
        self.banner.set_revealed(true);
        if let Some(p) = self.page() {
            p.set_title(&ctx::host_title(&self.host));
            p.set_loading(false);
            p.set_indicator_icon(Some(&gio::ThemedIcon::new("network-offline-symbolic")));
        }
        if let Some(ctx) = self.ctx.upgrade() {
            ctx.changed();
        }
    }

    fn finish_log(&self, code: Option<i32>) {
        if let Some(id) = self.log_id.borrow_mut().take() {
            if let Some(v) = self.ctx.upgrade().and_then(|c| c.vault()) {
                let _ = v.finish_log(id, code);
            }
        }
    }

    /// Dipanggil saat tab ditutup.
    pub fn terminate(&self) {
        if self.running.replace(false) {
            self.finish_log(None);
        }
        self.cleanup();
    }

    fn cleanup(&self) {
        for f in self.temp_files.borrow_mut().drain(..) {
            let _ = std::fs::remove_file(f);
        }
    }

    fn first_data(self: &Rc<Self>) {
        if self.got_data.replace(true) {
            return;
        }
        if let Some(p) = self.page() {
            p.set_loading(false);
            p.set_indicator_icon(gio::Icon::NONE);
        }
        if let Some(ctx) = self.ctx.upgrade() {
            ctx.changed();
        }
        let cmds: Vec<String> = [self.host.startup_snippet.clone(), self.run.clone()]
            .into_iter()
            .flatten()
            .filter(|c| !c.trim().is_empty())
            .collect();
        for (i, cmd) in cmds.into_iter().enumerate() {
            let weak = Rc::downgrade(self);
            let delay = std::time::Duration::from_millis(600 + 300 * i as u64);
            glib::timeout_add_local_once(delay, move || {
                if let Some(s) = weak.upgrade() {
                    s.send(&format!("{cmd}\n"));
                }
            });
        }
    }
}

/// "Host" semu untuk tab terminal lokal (tidak disimpan di vault).
pub fn local_host() -> Host {
    let mut h = ctx::blank_host();
    h.id = "local".into();
    h.label = tr!("Lokal");
    h.hostname = "localhost".into();
    h.username = config::user_name();
    h.color = "#94A3B8".into();
    h
}

/// Buka tab SSH ke host (dengan perintah opsional setelah login).
pub fn open_host(ctx: &Ctx, host: &Host, run: Option<String>) {
    let key = host.key_id.as_ref().and_then(|id| ctx.keys().into_iter().find(|k| &k.id == id));
    let jump = host.jump_host_id.as_ref().and_then(|id| ctx.host(id));
    open(ctx, host.clone(), key, jump, run, false);
}

pub fn open_local(ctx: &Ctx) {
    open(ctx, local_host(), None, None, None, true);
}

fn open(ctx: &Ctx, host: Host, key: Option<SshKey>, jump: Option<Host>, run: Option<String>, local: bool) {
    let term = vte::Terminal::new();
    term.set_hexpand(true);
    term.set_vexpand(true);
    term.set_scrollback_lines(10_000);
    term.set_font(Some(&gtk::pango::FontDescription::from_string("Monospace 11")));
    term.set_mouse_autohide(true);
    term.set_allow_hyperlink(true);
    theme::apply_term_theme(&term, host.terminal_theme.as_deref());

    let banner = adw::Banner::new(&tr!("Sesi berakhir"));
    banner.set_button_label(Some(&tr!("Sambung ulang")));

    let root = gtk::Box::new(gtk::Orientation::Vertical, 0);
    root.append(&banner);
    root.append(&term);

    let session = Rc::new(Session {
        host,
        local,
        key,
        jump,
        run,
        term: term.clone(),
        banner: banner.clone(),
        page: RefCell::new(None),
        temp_files: RefCell::new(Vec::new()),
        log_id: RefCell::new(None),
        got_data: Cell::new(false),
        running: Cell::new(false),
        ctx: Rc::downgrade(ctx),
    });

    let page = ctx.tabs.append(&root);
    page.set_title(&ctx::host_title(&session.host));
    page.set_tooltip(&if local { tr!("Terminal lokal") } else { ctx::host_address(&session.host, ctx.hide_addresses.get()) });
    page.set_icon(Some(&gio::ThemedIcon::new(if local { "utilities-terminal-symbolic" } else { "network-server-symbolic" })));
    *session.page.borrow_mut() = Some(page.clone());

    {
        let weak = Rc::downgrade(&session);
        banner.connect_button_clicked(move |_| {
            if let Some(s) = weak.upgrade() {
                s.term.reset(true, true);
                s.start();
            }
        });
    }
    {
        let weak = Rc::downgrade(&session);
        term.connect_contents_changed(move |_| {
            if let Some(s) = weak.upgrade() {
                if s.running.get() {
                    s.first_data();
                }
            }
        });
    }
    {
        let weak = Rc::downgrade(&session);
        term.connect_child_exited(move |_, status| {
            if let Some(s) = weak.upgrade() {
                // Status mentah dari waitpid
                let code = if libc::WIFEXITED(status) { Some(libc::WEXITSTATUS(status)) } else { None };
                s.ended(code);
            }
        });
    }
    {
        let page = page.clone();
        #[allow(deprecated)]
        term.connect_window_title_changed(move |t| {
            if let Some(title) = t.window_title() {
                if !title.is_empty() {
                    page.set_title(&title);
                }
            }
        });
    }
    install_menu(&term);
    // Ikuti mode terang/gelap jika host tidak memilih tema sendiri
    {
        let weak = Rc::downgrade(&session);
        adw::StyleManager::default().connect_dark_notify(move |_| {
            if let Some(s) = weak.upgrade() {
                theme::apply_term_theme(&s.term, s.host.terminal_theme.as_deref());
            }
        });
    }

    ctx.sessions.borrow_mut().push(session.clone());
    session.start();
    ctx.tabs.set_selected_page(&page);
    term.grab_focus();
    ctx.changed();
}

/// Sesi milik tab yang sedang dipilih (bukan Beranda).
pub fn active_session(ctx: &Ctx) -> Option<Rc<Session>> {
    let page = ctx.tabs.selected_page()?;
    ctx.sessions.borrow().iter().find(|s| s.page().as_ref() == Some(&page)).cloned()
}

/// Sesi terminal terakhir yang dipakai (untuk snippet dari halaman Snippets).
pub fn last_session(ctx: &Ctx) -> Option<Rc<Session>> {
    active_session(ctx).or_else(|| ctx.sessions.borrow().iter().rev().find(|s| s.running.get()).cloned())
}

/// Dipanggil saat tab ditutup: hentikan proses & lepas sesi.
pub fn close_page(ctx: &Ctx, page: &adw::TabPage) {
    let mut list = ctx.sessions.borrow_mut();
    if let Some(i) = list.iter().position(|s| s.page().as_ref() == Some(page)) {
        let s = list.remove(i);
        s.terminate();
    }
    drop(list);
    ctx.changed();
}

// ---- Menu klik kanan & shortcut salin/tempel ----

fn install_menu(term: &vte::Terminal) {
    let group = gio::SimpleActionGroup::new();
    let add = |name: &str, f: Box<dyn Fn(&vte::Terminal)>| {
        let a = gio::SimpleAction::new(name, None);
        let t = term.clone();
        a.connect_activate(move |_, _| f(&t));
        group.add_action(&a);
    };
    add("copy", Box::new(|t| t.copy_clipboard_format(vte::Format::Text)));
    add("paste", Box::new(|t| t.paste_clipboard()));
    add("select-all", Box::new(|t| t.select_all()));
    add("clear", Box::new(|t| t.feed_child(b"\x0c")));
    term.insert_action_group("term", Some(&group));

    let menu = gio::Menu::new();
    let s1 = gio::Menu::new();
    s1.append(Some(&tr!("Salin")), Some("term.copy"));
    s1.append(Some(&tr!("Tempel")), Some("term.paste"));
    s1.append(Some(&tr!("Pilih Semua")), Some("term.select-all"));
    menu.append_section(None, &s1);
    let s2 = gio::Menu::new();
    s2.append(Some(&tr!("Bersihkan layar")), Some("term.clear"));
    menu.append_section(None, &s2);
    let popover = gtk::PopoverMenu::from_model(Some(&menu));
    popover.set_parent(term);
    popover.set_has_arrow(false);

    let click = gtk::GestureClick::new();
    click.set_button(3);
    let p = popover.clone();
    click.connect_pressed(move |_, _, x, y| {
        p.set_pointing_to(Some(&gtk::gdk::Rectangle::new(x as i32, y as i32, 1, 1)));
        p.popup();
    });
    term.add_controller(click);

    // Ctrl+Shift+C / Ctrl+Shift+V seperti terminal Linux pada umumnya
    let keys = gtk::EventControllerKey::new();
    keys.set_propagation_phase(gtk::PropagationPhase::Capture);
    let t = term.clone();
    keys.connect_key_pressed(move |_, key, _, mods| {
        use gtk::gdk::{Key, ModifierType};
        let cs = ModifierType::CONTROL_MASK | ModifierType::SHIFT_MASK;
        if mods & cs == cs {
            match key.to_lower() {
                Key::c => {
                    t.copy_clipboard_format(vte::Format::Text);
                    return glib::Propagation::Stop;
                }
                Key::v => {
                    t.paste_clipboard();
                    return glib::Propagation::Stop;
                }
                _ => {}
            }
        }
        glib::Propagation::Proceed
    });
    term.add_controller(keys);
}

// ---- Perintah yang dijalankan ----

fn local_command() -> (Vec<String>, Vec<String>) {
    let shell = std::env::var("SHELL")
        .ok()
        .filter(|s| config::in_flatpak() || std::path::Path::new(s).exists())
        .unwrap_or_else(|| "/bin/bash".into());
    let mut env = vec!["COLORTERM=truecolor".to_string(), "TERM_PROGRAM=Zterm".to_string()];
    if std::env::var("LANG").is_err() {
        env.push("LANG=C.UTF-8".into());
    }
    (vec![shell], env)
}

/// Di Flatpak, ssh & shell harus jalan di host (sandbox tidak punya ~/.ssh atau shell pengguna).
fn wrap_for_sandbox(argv: Vec<String>, env: Vec<String>) -> (Vec<String>, Vec<String>) {
    if !config::in_flatpak() {
        return (argv, env);
    }
    let mut out = vec!["flatpak-spawn".to_string(), "--host".to_string(), "--watch-bus".to_string()];
    out.extend(env.iter().map(|e| format!("--env={e}")));
    out.push("--env=TERM=xterm-256color".into());
    out.extend(argv);
    (out, Vec::new())
}

/// Argumen `ssh` dari data host (sama dengan `SSHCommand` di versi Mac).
pub struct SshCommand {
    pub args: Vec<String>,
    pub env: Vec<String>,
    pub temp_files: Vec<PathBuf>,
}

impl SshCommand {
    pub fn build(host: &Host, key: Option<&SshKey>, jump: Option<&Host>) -> Self {
        let mut args: Vec<String> = vec![
            "ssh".into(),
            "-p".into(),
            host.port.to_string(),
            "-o".into(),
            "ServerAliveInterval=30".into(),
            // Terima host baru otomatis (TOFU), tolak jika fingerprint berubah.
            "-o".into(),
            "StrictHostKeyChecking=accept-new".into(),
        ];
        if let Ok(kh) = std::env::var("ZTERM_TEST_KNOWN_HOSTS") {
            args.push("-o".into());
            args.push(format!("UserKnownHostsFile={kh}"));
        }
        let mut temp_files = Vec::new();
        let mut env: Vec<String> = vec!["COLORTERM=truecolor".into()];
        env.push(if host.charset.eq_ignore_ascii_case("UTF-8") { "LANG=C.UTF-8".into() } else { "LANG=C".into() });

        if !host.username.is_empty() {
            args.push("-l".into());
            args.push(host.username.clone());
        }
        if host.agent_forwarding {
            args.push("-A".into());
        }
        if let Some(j) = jump {
            args.push("-J".into());
            args.push(format!("{}@{}:{}", j.username, j.hostname, j.port));
        }
        // Proxy SOCKS5/HTTP: app ini sendiri jadi ProxyCommand (lihat main.rs).
        // Login proxy lewat environment, bukan argumen (tidak terlihat di `ps`).
        if jump.is_none() {
            if let Some(p) = host.proxy.as_ref().filter(|p| !p.host.is_empty()) {
                let kind = if p.kind == ProxyKind::Http { "http" } else { "socks5" };
                args.push("-o".into());
                args.push(format!("ProxyCommand={} --zterm-proxy {kind} {} {} %h %p", self_command(), p.host, p.port));
                if let Some(u) = p.username.as_ref().filter(|u| !u.is_empty()) {
                    env.push(format!("ZTERM_PROXY_USER={u}"));
                }
                if let Some(pw) = p.password.as_ref().filter(|p| !p.is_empty()) {
                    env.push(format!("ZTERM_PROXY_PASS={pw}"));
                }
            }
        }

        let mut secret: Option<String> = None;
        match host.auth {
            AuthMethod::Password => {
                secret = host.password.clone();
                args.push("-o".into());
                args.push("PreferredAuthentications=password,keyboard-interactive,publickey".into());
            }
            AuthMethod::Key => {
                if let Some(k) = key {
                    if let Some(file) = write_key(k) {
                        args.push("-i".into());
                        args.push(file.to_string_lossy().into_owned());
                        args.push("-o".into());
                        args.push("IdentitiesOnly=yes".into());
                        temp_files.push(file);
                        secret = k.passphrase.clone();
                    }
                }
            }
            AuthMethod::Agent => {}
        }
        for e in host.env.iter().filter(|e| !e.name.is_empty()) {
            args.push("-o".into());
            args.push(format!("SetEnv={}={}", e.name, e.value));
        }
        args.push(host.hostname.clone());

        // Password / passphrase dikirim lewat helper askpass, bukan argumen.
        if let Some(s) = secret.filter(|s| !s.is_empty()) {
            if let Some(askpass) = askpass_script() {
                env.push(format!("SSH_ASKPASS={}", askpass.display()));
                env.push("SSH_ASKPASS_REQUIRE=force".into());
                if std::env::var("DISPLAY").is_err() {
                    env.push("DISPLAY=:0".into());
                }
                env.push(format!("ZTERM_SECRET={s}"));
            }
        }
        SshCommand { args, env, temp_files }
    }
}

/// Perintah untuk menjalankan app ini lagi sebagai ProxyCommand.
fn self_command() -> String {
    if config::in_flatpak() {
        return format!("flatpak run --command=zterm {}", config::APP_ID);
    }
    // AppImage: pakai file .AppImage-nya (path mount berubah tiap dijalankan)
    let exe = std::env::var("APPIMAGE")
        .ok()
        .or_else(|| std::env::current_exe().ok().map(|p| p.to_string_lossy().into_owned()))
        .unwrap_or_else(|| "zterm".into());
    format!("\"{exe}\"")
}

/// Tulis private key ke file sementara (izin 0600), dihapus saat sesi berakhir.
fn write_key(key: &SshKey) -> Option<PathBuf> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let dir = config::data_dir().join("session-keys");
    std::fs::create_dir_all(&dir).ok()?;
    config::set_mode(&dir, 0o700);
    let path = dir.join(uuid::Uuid::new_v4().to_string());
    let mut pem = key.private_key.clone();
    if !pem.ends_with('\n') {
        pem.push('\n');
    }
    let mut f = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&path).ok()?;
    f.write_all(pem.as_bytes()).ok()?;
    Some(path)
}

/// Skrip kecil yang menjawab prompt password/passphrase dari variabel ZTERM_SECRET.
fn askpass_script() -> Option<PathBuf> {
    let path = config::data_dir().join("askpass.sh");
    let script = "#!/bin/sh\ncase \"$1\" in\n  *assword*|*assphrase*|*PIN*) printf '%s\\n' \"$ZTERM_SECRET\" ;;\n  *) exit 1 ;;\nesac\n";
    std::fs::write(&path, script).ok()?;
    config::set_mode(&path, 0o700);
    Some(path)
}
