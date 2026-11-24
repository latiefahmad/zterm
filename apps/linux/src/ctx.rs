//! Status app bersama: vault yang terbuka, jendela, toast, dan sesi terminal.

use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::sync::Arc;

use adw::prelude::*;
use zterm_core::{Host, SshKey, Snippet, Vault};

use crate::terminal::Session;

pub type Ctx = Rc<App>;

pub struct App {
    pub window: adw::ApplicationWindow,
    pub toasts: adw::ToastOverlay,
    /// "welcome" / "create" / "lock" / "main"
    pub root: gtk::Stack,
    pub vault: RefCell<Option<Arc<Vault>>>,
    /// Tab: halaman "Beranda" (disematkan) + satu tab per sesi terminal.
    pub tabs: adw::TabView,
    pub home: RefCell<Option<adw::TabPage>>,
    /// Halaman sidebar (hosts / keychain / snippets) di dalam tab Beranda.
    pub pages: gtk::Stack,
    pub sessions: RefCell<Vec<Rc<Session>>>,
    refreshers: RefCell<Vec<Box<dyn Fn()>>>,
    /// Sembunyikan alamat host (privasi saat berbagi layar).
    pub hide_addresses: Cell<bool>,
}

impl App {
    pub fn new(window: adw::ApplicationWindow) -> Ctx {
        let toasts = adw::ToastOverlay::new();
        let root = gtk::Stack::builder().transition_type(gtk::StackTransitionType::Crossfade).build();
        toasts.set_child(Some(&root));
        window.set_content(Some(&toasts));
        Rc::new(App {
            window,
            toasts,
            root,
            vault: RefCell::new(None),
            tabs: adw::TabView::new(),
            home: RefCell::new(None),
            pages: gtk::Stack::builder().transition_type(gtk::StackTransitionType::Crossfade).build(),
            sessions: RefCell::new(Vec::new()),
            refreshers: RefCell::new(Vec::new()),
            hide_addresses: Cell::new(false),
        })
    }

    pub fn vault(&self) -> Option<Arc<Vault>> {
        self.vault.borrow().clone()
    }

    pub fn toast(&self, text: &str) {
        let t = adw::Toast::new(text);
        t.set_timeout(3);
        self.toasts.add_toast(t);
    }

    pub fn error(&self, e: impl std::fmt::Display) {
        self.toast(&crate::i18n::msg(&e.to_string()));
    }

    /// Daftarkan fungsi yang dipanggil ulang setiap data vault berubah.
    pub fn on_change(&self, f: impl Fn() + 'static) {
        self.refreshers.borrow_mut().push(Box::new(f));
    }

    pub fn changed(&self) {
        for f in self.refreshers.borrow().iter() {
            f();
        }
    }

    // ---- Data vault (kosong jika terkunci) ----

    pub fn hosts(&self) -> Vec<Host> {
        self.vault().map(|v| v.hosts()).unwrap_or_default()
    }

    pub fn keys(&self) -> Vec<SshKey> {
        self.vault().map(|v| v.keys()).unwrap_or_default()
    }

    pub fn snippets(&self) -> Vec<Snippet> {
        self.vault().map(|v| v.snippets()).unwrap_or_default()
    }

    pub fn host(&self, id: &str) -> Option<Host> {
        self.hosts().into_iter().find(|h| h.id == id)
    }

    /// Jumlah tab yang sedang tersambung ke host ini.
    pub fn connected_count(&self, host_id: &str) -> usize {
        self.sessions.borrow().iter().filter(|s| s.host.id == host_id && s.is_connected()).count()
    }

    /// Kembali ke tab Beranda dan buka halaman sidebar tertentu.
    pub fn show_page(&self, name: &str) {
        self.pages.set_visible_child_name(name);
        if let Some(home) = self.home.borrow().as_ref() {
            self.tabs.set_selected_page(home);
        }
    }
}

pub fn host_title(h: &Host) -> String {
    if h.label.trim().is_empty() { h.hostname.clone() } else { h.label.clone() }
}

pub fn host_address(h: &Host, hidden: bool) -> String {
    let host = if hidden { "••••••••".to_string() } else { h.hostname.clone() };
    let port = if h.port == 22 || hidden { String::new() } else { format!(":{}", h.port) };
    if h.username.is_empty() { format!("{host}{port}") } else { format!("{}@{host}{port}", h.username) }
}

pub fn blank_host() -> Host {
    Host {
        id: String::new(),
        hostname: String::new(),
        label: String::new(),
        group: None,
        tags: vec![],
        color: crate::theme::HOST_COLORS[0].into(),
        port: 22,
        username: "root".into(),
        auth: zterm_core::AuthMethod::Password,
        password: None,
        key_id: None,
        agent_forwarding: false,
        startup_snippet: None,
        jump_host_id: None,
        proxy: None,
        env: vec![],
        charset: "UTF-8".into(),
        terminal_theme: None,
        updated_at: 0,
        deleted: false,
    }
}

/// Salin teks ke clipboard.
pub fn copy_text(text: &str) {
    if let Some(d) = gtk::gdk::Display::default() {
        d.clipboard().set_text(text);
    }
}
