//! Welcome, buat master password, dan layar vault terkunci.

use std::sync::Arc;

use adw::prelude::*;
use zterm_core::{CoreError, Vault};
use gtk::{gio, glib};

use crate::config;
use crate::ctx::Ctx;
use crate::theme;
use crate::window::language_button;

/// Tampilkan layar awal sesuai keadaan vault di disk.
pub fn show_start(ctx: &Ctx) {
    #[cfg(debug_assertions)]
    if std::env::var_os("ZTERM_DEMO").is_some() {
        demo(ctx);
        return;
    }
    if zterm_core::vault_exists(config::vault_path()) { show_lock(ctx) } else { show_welcome(ctx) }
}

/// Build debug saja (`ZTERM_DEMO=1`): vault sementara berisi contoh host untuk screenshot / video.
/// `ZTERM_DEMO_LOCAL=1` membuka tab terminal lokal, `ZTERM_DEMO_PAGE=keychain|snippets` memilih halaman.
#[cfg(debug_assertions)]
fn demo(ctx: &Ctx) {
    let path = std::env::temp_dir().join(format!("zterm-demo-{}.zterm", std::process::id()));
    let Ok(v) = Vault::create(path.to_string_lossy().into_owned(), "demo-password".into()) else { return show_welcome(ctx) };
    let samples: [(&str, &str, Option<&str>, &str, &str); 5] = [
        ("prod-api", "10.0.1.10", Some("Production"), "#3FD0B4", "deploy"),
        ("prod-db", "10.0.1.20", Some("Production"), "#F0616D", "postgres"),
        ("web-1", "10.0.1.31", Some("Production"), "#5B9CF5", "deploy"),
        ("staging", "staging.local", Some("Staging"), "#9D7CF2", "deploy"),
        ("homelab", "192.168.1.5", None, "#F2A65A", "pi"),
    ];
    for (label, host, group, color, user) in samples {
        let mut h = crate::ctx::blank_host();
        h.label = label.into();
        h.hostname = host.into();
        h.group = group.map(str::to_string);
        h.color = color.into();
        h.username = user.into();
        let _ = v.upsert_host(h);
    }
    let _ = v.generate_key("Laptop Linux".into());
    for (label, cmd) in [("Cek disk", "df -h"), ("Update sistem", "sudo apt update && sudo apt upgrade -y")] {
        let _ = v.upsert_snippet(zterm_core::Snippet { id: String::new(), label: label.into(), command: cmd.into(), updated_at: 0, deleted: false });
    }
    finish(ctx, v);
    if let Ok(page) = std::env::var("ZTERM_DEMO_PAGE") {
        ctx.show_page(&page);
    }
    if std::env::var_os("ZTERM_DEMO_LOCAL").is_some() {
        crate::terminal::open_local(ctx);
    }
}

fn set_page(ctx: &Ctx, name: &str, page: &impl IsA<gtk::Widget>) {
    if let Some(old) = ctx.root.child_by_name(name) {
        ctx.root.remove(&old);
    }
    ctx.root.add_named(page, Some(name));
    ctx.root.set_visible_child_name(name);
}

/// Kolom sempit di tengah jendela.
fn column() -> (gtk::ScrolledWindow, gtk::Box) {
    let col = gtk::Box::new(gtk::Orientation::Vertical, 0);
    col.set_width_request(380);
    let clamp = adw::Clamp::builder().maximum_size(420).child(&col).valign(gtk::Align::Center).build();
    clamp.set_margin_top(32);
    clamp.set_margin_bottom(32);
    clamp.set_margin_start(24);
    clamp.set_margin_end(24);
    let scroll = gtk::ScrolledWindow::builder().hscrollbar_policy(gtk::PolicyType::Never).child(&clamp).build();
    (scroll, col)
}

fn label(text: &str, class: &str) -> gtk::Label {
    let l = gtk::Label::builder().label(text).wrap(true).xalign(0.0).build();
    if !class.is_empty() {
        l.add_css_class(class);
    }
    l
}

fn password_entry(placeholder: &str) -> gtk::PasswordEntry {
    let e = gtk::PasswordEntry::builder().placeholder_text(placeholder).show_peek_icon(true).build();
    e.set_hexpand(true);
    e
}

fn finish(ctx: &Ctx, vault: Arc<Vault>) {
    *ctx.vault.borrow_mut() = Some(vault);
    ctx.root.set_visible_child_name("main");
    ctx.show_page("hosts");
    ctx.changed();
}

// ---- Welcome ----

pub fn show_welcome(ctx: &Ctx) {
    let (scroll, col) = column();
    col.set_halign(gtk::Align::Center);

    let logo = theme::logo(84);
    logo.set_margin_bottom(24);
    col.append(&logo);

    let title = gtk::Label::new(Some(&tr!("Selamat datang di Zterm")));
    title.add_css_class("zterm-hero");
    title.set_wrap(true);
    title.set_justify(gtk::Justification::Center);
    col.append(&title);

    let tag = gtk::Label::new(Some(&tr!("Semua servermu, satu terminal.")));
    tag.add_css_class("zterm-tagline");
    tag.set_margin_top(10);
    col.append(&tag);

    let start = gtk::Button::with_label(if crate::i18n::english() { "Get Started" } else { "Mulai" });
    start.add_css_class("suggested-action");
    start.add_css_class("pill");
    start.set_margin_top(40);
    let c = ctx.clone();
    start.connect_clicked(move |_| show_create(&c));
    col.append(&start);

    let note = gtk::Label::new(Some(&tr!(
        "Data host dienkripsi di perangkatmu. Sync lewat Google Drive menyusul di versi Linux."
    )));
    note.add_css_class("zterm-hint");
    note.set_wrap(true);
    note.set_justify(gtk::Justification::Center);
    note.set_margin_top(28);
    col.append(&note);
    let lang = language_button(ctx, true);
    lang.set_halign(gtk::Align::Center);
    lang.set_margin_top(16);
    col.append(&lang);

    set_page(ctx, "welcome", &scroll);
}

// ---- Buat master password ----

const STRENGTH: [&str; 5] = ["Terlalu pendek", "Lemah", "Cukup", "Kuat", "Sangat kuat"];

fn strength(pw: &str) -> usize {
    let n = pw.chars().count();
    let mut s = 0;
    if n >= 8 {
        s += 1;
    }
    if n >= 12 {
        s += 1;
    }
    if pw.chars().any(|c| c.is_ascii_digit()) {
        s += 1;
    }
    if pw.chars().any(|c| c.is_uppercase() || (!c.is_alphanumeric() && !c.is_whitespace())) {
        s += 1;
    }
    if n < 8 { 0 } else { s.min(4) }
}

pub fn show_create(ctx: &Ctx) {
    let (scroll, col) = column();

    let back = gtk::Button::builder().halign(gtk::Align::Start).build();
    back.set_child(Some(&adw::ButtonContent::builder().icon_name("go-previous-symbolic").label(tr!("Kembali")).build()));
    back.add_css_class("flat");
    back.set_margin_bottom(20);
    let c = ctx.clone();
    back.connect_clicked(move |_| show_welcome(&c));
    col.append(&back);

    let icon = gtk::Image::from_icon_name("system-lock-screen-symbolic");
    icon.set_pixel_size(36);
    icon.set_halign(gtk::Align::Start);
    icon.add_css_class("accent");
    col.append(&icon);

    let title = label(&tr!("Buat master password"), "zterm-title");
    title.set_margin_top(14);
    col.append(&title);
    let sub = label(&tr!("Password ini mengunci semua host dan SSH key di perangkat ini."), "zterm-muted");
    sub.set_margin_top(6);
    col.append(&sub);

    let pw = password_entry(&tr!("Master password (min. 8 karakter)"));
    pw.set_margin_top(24);
    col.append(&pw);

    let bar_row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    bar_row.set_margin_top(8);
    let bar = gtk::LevelBar::builder().min_value(0.0).max_value(4.0).mode(gtk::LevelBarMode::Discrete).hexpand(true).build();
    bar.set_valign(gtk::Align::Center);
    let bar_label = gtk::Label::new(Some(&tr!(STRENGTH[0])));
    bar_label.add_css_class("zterm-hint");
    bar_label.set_width_chars(12);
    bar_label.set_xalign(1.0);
    bar_row.append(&bar);
    bar_row.append(&bar_label);
    col.append(&bar_row);

    let confirm = password_entry(&tr!("Ulangi password"));
    confirm.set_margin_top(8);
    col.append(&confirm);

    let error = label("", "zterm-error");
    error.set_visible(false);
    error.set_margin_top(8);
    col.append(&error);

    let submit = gtk::Button::with_label(&tr!("Buat vault & mulai"));
    submit.add_css_class("suggested-action");
    submit.add_css_class("pill");
    submit.set_sensitive(false);
    submit.set_margin_top(24);
    col.append(&submit);

    let warn = label(&tr!("Tidak bisa dipulihkan jika lupa. Simpan di tempat aman."), "zterm-hint");
    warn.set_margin_top(14);
    col.append(&warn);

    let validate = {
        let (pw, confirm, submit, bar, bar_label) = (pw.clone(), confirm.clone(), submit.clone(), bar.clone(), bar_label.clone());
        move || {
            let (a, b) = (pw.text(), confirm.text());
            let s = strength(&a);
            bar.set_value(s as f64);
            bar_label.set_label(&tr!(STRENGTH[s]));
            let mismatch = !b.is_empty() && a != b;
            if mismatch { confirm.add_css_class("error") } else { confirm.remove_css_class("error") }
            submit.set_sensitive(a.chars().count() >= 8 && a == b);
        }
    };
    let v = validate.clone();
    pw.connect_changed(move |_| v());
    let v = validate.clone();
    confirm.connect_changed(move |_| v());
    let c2 = confirm.clone();
    pw.connect_activate(move |_| {
        c2.grab_focus();
    });

    let run = {
        let (ctx, pw, submit, error) = (ctx.clone(), pw.clone(), submit.clone(), error.clone());
        move || {
            if !submit.is_sensitive() {
                return;
            }
            submit.set_sensitive(false);
            submit.set_label(&tr!("Membuat vault…"));
            let password = pw.text().to_string();
            let (ctx, submit, error) = (ctx.clone(), submit.clone(), error.clone());
            glib::spawn_future_local(async move {
                let res = gio::spawn_blocking(move || Vault::create(config::vault_path(), password)).await;
                match res {
                    Ok(Ok(vault)) => finish(&ctx, vault),
                    Ok(Err(e)) => {
                        error.set_label(&crate::i18n::msg(&e.to_string()));
                        error.set_visible(true);
                        submit.set_label(&tr!("Buat vault & mulai"));
                        submit.set_sensitive(true);
                    }
                    Err(_) => {}
                }
            });
        }
    };
    let r = run.clone();
    submit.connect_clicked(move |_| r());
    confirm.connect_activate(move |_| run());

    set_page(ctx, "create", &scroll);
    pw.grab_focus();
}

// ---- Vault terkunci ----

pub fn show_lock(ctx: &Ctx) {
    let (scroll, col) = column();
    col.set_halign(gtk::Align::Center);

    let logo = theme::logo(72);
    logo.set_margin_bottom(20);
    col.append(&logo);
    let title = gtk::Label::new(Some(&tr!("Vault terkunci")));
    title.add_css_class("zterm-title");
    col.append(&title);
    let sub = gtk::Label::new(Some(&tr!("Masukkan master password untuk melanjutkan.")));
    sub.add_css_class("zterm-muted");
    sub.set_margin_top(6);
    col.append(&sub);

    let row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    row.set_margin_top(24);
    let pw = password_entry(&tr!("Master password"));
    let go = gtk::Button::from_icon_name("go-next-symbolic");
    go.add_css_class("suggested-action");
    go.add_css_class("circular");
    go.set_tooltip_text(Some(&tr!("Buka vault")));
    row.append(&pw);
    row.append(&go);
    col.append(&row);

    let error = gtk::Label::new(None);
    error.add_css_class("zterm-error");
    error.set_visible(false);
    error.set_margin_top(10);
    col.append(&error);
    let lang = language_button(ctx, true);
    lang.set_halign(gtk::Align::Center);
    lang.set_margin_top(16);
    col.append(&lang);

    let run = {
        let (ctx, pw, go, error) = (ctx.clone(), pw.clone(), go.clone(), error.clone());
        move || {
            let password = pw.text().to_string();
            if password.is_empty() || !go.is_sensitive() {
                return;
            }
            go.set_sensitive(false);
            pw.set_sensitive(false);
            let (ctx, pw, go, error) = (ctx.clone(), pw.clone(), go.clone(), error.clone());
            glib::spawn_future_local(async move {
                let res = gio::spawn_blocking(move || Vault::unlock(config::vault_path(), password)).await;
                go.set_sensitive(true);
                pw.set_sensitive(true);
                match res {
                    Ok(Ok(vault)) => finish(&ctx, vault),
                    Ok(Err(e)) => {
                        let msg = match e {
                            CoreError::WrongPassword => tr!("Master password salah"),
                            other => crate::i18n::msg(&other.to_string()),
                        };
                        error.set_label(&msg);
                        error.set_visible(true);
                        pw.set_text("");
                        pw.grab_focus();
                    }
                    Err(_) => {}
                }
            });
        }
    };
    let r = run.clone();
    go.connect_clicked(move |_| r());
    pw.connect_activate(move |_| run());

    set_page(ctx, "lock", &scroll);
    pw.grab_focus();
}

/// Kunci vault: tutup semua sesi terminal dan kembali ke layar kunci.
pub fn lock(ctx: &Ctx) {
    let pages: Vec<adw::TabPage> = ctx.sessions.borrow().iter().filter_map(|s| s.page()).collect();
    for p in pages {
        ctx.tabs.close_page(&p);
    }
    *ctx.vault.borrow_mut() = None;
    ctx.changed();
    show_lock(ctx);
}
