//! Editor host: Address, General, Credentials, dan Lanjutan (jump host, proxy, env).

use std::cell::RefCell;
use std::rc::Rc;

use adw::prelude::*;
use zterm_core::{AuthMethod, EnvVar, Host, HostProxy, ProxyKind, SshKey};
use gtk::glib;

use crate::ctx::{self, Ctx};
use crate::{hosts, icons, terminal, theme};

fn combo(title: &str, items: &[&str]) -> adw::ComboRow {
    let model = gtk::StringList::new(items);
    adw::ComboRow::builder().title(title).model(&model).build()
}

fn entry(title: &str, text: &str) -> adw::EntryRow {
    let e = adw::EntryRow::builder().title(title).build();
    e.set_text(text);
    e
}

fn password(title: &str, text: &str) -> adw::PasswordEntryRow {
    let e = adw::PasswordEntryRow::builder().title(title).build();
    e.set_text(text);
    e
}

fn opt(s: &str) -> Option<String> {
    let t = s.trim();
    if t.is_empty() { None } else { Some(t.to_string()) }
}

/// Buka editor. `None` = host baru.
pub fn open(ctx: &Ctx, existing: Option<Host>) {
    if ctx.vault().is_none() {
        return;
    }
    let is_new = existing.is_none();
    let h = existing.unwrap_or_else(ctx::blank_host);

    let dialog = adw::Dialog::builder()
        .title(if is_new { tr!("Host Baru") } else { tr!("Edit Host") })
        .content_width(560)
        .content_height(720)
        .build();
    let page = adw::PreferencesPage::new();

    // ---- Address ----
    let g_addr = adw::PreferencesGroup::builder().title(tr!("Address")).build();
    let hostname = entry(&tr!("IP atau hostname"), &h.hostname);
    g_addr.add(&hostname);
    let color = Rc::new(RefCell::new(h.color.clone()));
    let color_row = adw::ActionRow::builder().title(tr!("Warna")).build();
    let swatches = gtk::FlowBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .max_children_per_line(8)
        .min_children_per_line(8)
        .column_spacing(4)
        .row_spacing(4)
        .valign(gtk::Align::Center)
        .margin_top(6)
        .margin_bottom(6)
        .build();
    let mut buttons: Vec<gtk::ToggleButton> = Vec::new();
    for hex in theme::HOST_COLORS {
        let b = gtk::ToggleButton::builder().child(&theme::dot(hex, 16)).tooltip_text(hex).build();
        b.add_css_class("flat");
        b.add_css_class("zterm-swatch");
        b.set_active(h.color.eq_ignore_ascii_case(hex));
        if let Some(first) = buttons.first() {
            b.set_group(Some(first));
        }
        let c = color.clone();
        b.connect_toggled(move |b| {
            if b.is_active() {
                *c.borrow_mut() = hex.to_string();
            }
        });
        swatches.append(&b);
        buttons.push(b);
    }
    color_row.add_suffix(&swatches);
    g_addr.add(&color_row);
    page.add(&g_addr);

    // ---- General ----
    let g_gen = adw::PreferencesGroup::builder().title(tr!("General")).build();
    let label = entry(&tr!("Label"), &h.label);
    let group = entry(&tr!("Grup"), h.group.as_deref().unwrap_or(""));
    let tags = entry(&tr!("Tag (pisahkan dengan koma)"), &h.tags.join(", "));
    let port = adw::SpinRow::with_range(1.0, 65535.0, 1.0);
    port.set_title(&tr!("SSH di port"));
    port.set_value(h.port as f64);
    g_gen.add(&label);
    g_gen.add(&group);
    g_gen.add(&tags);
    g_gen.add(&port);
    page.add(&g_gen);

    // ---- Credentials ----
    let g_cred = adw::PreferencesGroup::builder().title(tr!("Credentials")).build();
    let username = entry(&tr!("Username"), &h.username);
    let auth = combo(&tr!("Autentikasi"), &["Password", "SSH Key", "Agent"]);
    auth.set_selected(match h.auth {
        AuthMethod::Password => 0,
        AuthMethod::Key => 1,
        AuthMethod::Agent => 2,
    });
    let pass = password(&tr!("Password"), h.password.as_deref().unwrap_or(""));
    let pass_hint = adw::ActionRow::builder().subtitle(tr!("Kosongkan jika ingin mengetik password saat connect.")).build();
    pass_hint.add_css_class("dim-label");
    let keys: Rc<RefCell<Vec<SshKey>>> = Rc::new(RefCell::new(ctx.keys()));
    let key_row = adw::ComboRow::builder().title(tr!("Pilih SSH key")).build();
    let gen_key = icons::button("plus", &tr!("Generate key Ed25519 baru"));
    gen_key.set_valign(gtk::Align::Center);
    key_row.add_suffix(&gen_key);
    let fill_keys = {
        let (keys, key_row) = (keys.clone(), key_row.clone());
        move |select: Option<String>| {
            let list = keys.borrow();
            let names: Vec<String> = list.iter().map(|k| format!("{} · {}", k.label, k.key_type)).collect();
            let none = tr!("Belum ada SSH key");
            let refs: Vec<&str> = names.iter().map(String::as_str).collect();
            let items: Vec<&str> = if refs.is_empty() { vec![none.as_str()] } else { refs };
            key_row.set_model(Some(&gtk::StringList::new(&items)));
            let idx = select.and_then(|id| list.iter().position(|k| k.id == id)).unwrap_or(0);
            key_row.set_selected(idx as u32);
        }
    };
    fill_keys(h.key_id.clone());
    {
        let (ctx, keys, fill, host_label) = (ctx.clone(), keys.clone(), fill_keys.clone(), label.clone());
        gen_key.connect_clicked(move |_| {
            let Some(v) = ctx.vault() else { return };
            let name = opt(&host_label.text()).unwrap_or_else(|| "Zterm".into());
            match v.generate_key(format!("{name} key")) {
                Ok(k) => {
                    ctx::copy_text(&k.public_key);
                    ctx.toast(&tr!("Key dibuat · public key disalin ke clipboard"));
                    *keys.borrow_mut() = ctx.keys();
                    fill(Some(k.id));
                    ctx.changed();
                }
                Err(e) => ctx.error(e),
            }
        });
    }
    let agent_hint = adw::ActionRow::builder().subtitle(tr!("Memakai SSH agent sistem (mis. ssh-agent, GNOME Keyring, 1Password).")).build();
    agent_hint.add_css_class("dim-label");
    g_cred.add(&username);
    g_cred.add(&auth);
    g_cred.add(&pass);
    g_cred.add(&pass_hint);
    g_cred.add(&key_row);
    g_cred.add(&agent_hint);
    let sync_auth = {
        let (auth, pass, pass_hint, key_row, agent_hint) = (auth.clone(), pass.clone(), pass_hint.clone(), key_row.clone(), agent_hint.clone());
        move || {
            let s = auth.selected();
            pass.set_visible(s == 0);
            pass_hint.set_visible(s == 0);
            key_row.set_visible(s == 1);
            agent_hint.set_visible(s == 2);
        }
    };
    sync_auth();
    let s = sync_auth.clone();
    auth.connect_selected_notify(move |_| s());
    page.add(&g_cred);

    // ---- Lanjutan ----
    let g_adv = adw::PreferencesGroup::builder().title(tr!("Lanjutan")).build();
    let fwd = adw::SwitchRow::builder().title(tr!("Agent Forwarding")).active(h.agent_forwarding).build();
    let startup = entry(&tr!("Startup snippet (dijalankan setelah login)"), h.startup_snippet.as_deref().unwrap_or(""));
    let others: Vec<Host> = ctx.hosts().into_iter().filter(|o| o.id != h.id).collect();
    let mut jump_names = vec![tr!("Tanpa jump host")];
    jump_names.extend(others.iter().map(ctx::host_title));
    let jump_refs: Vec<&str> = jump_names.iter().map(String::as_str).collect();
    let jump = combo(&tr!("Host Chaining"), &jump_refs);
    jump.set_subtitle(&tr!("Jump host (ProxyJump)"));
    if let Some(id) = &h.jump_host_id {
        if let Some(i) = others.iter().position(|o| &o.id == id) {
            jump.set_selected(i as u32 + 1);
        }
    }
    let charset = combo("Charset", &["UTF-8", "ASCII"]);
    charset.set_selected(if h.charset.eq_ignore_ascii_case("ASCII") { 1 } else { 0 });
    let follow_app = tr!("Ikuti tampilan app");
    let mut theme_names = vec![follow_app.as_str()];
    theme_names.extend(theme::TERM_THEMES.iter().map(|t| t.name));
    let term_theme = combo(&tr!("Tema terminal"), &theme_names);
    if let Some(id) = &h.terminal_theme {
        if let Some(i) = theme::TERM_THEMES.iter().position(|t| t.id == id) {
            term_theme.set_selected(i as u32 + 1);
        }
    }
    let env_text = h.env.iter().map(|e| format!("{}={}", e.name, e.value)).collect::<Vec<_>>().join(", ");
    let env = entry(&tr!("Environment (NAMA=nilai, pisahkan koma)"), &env_text);
    g_adv.add(&fwd);
    g_adv.add(&startup);
    g_adv.add(&jump);
    g_adv.add(&charset);
    g_adv.add(&term_theme);
    g_adv.add(&env);
    page.add(&g_adv);

    // ---- Proxy ----
    let g_proxy = adw::PreferencesGroup::builder().title("Proxy").build();
    let p = h.proxy.clone();
    let proxy_kind = combo(&tr!("Proxy"), &[tr!("Tanpa proxy").as_str(), "SOCKS5", "HTTP"]);
    proxy_kind.set_selected(match p.as_ref().map(|p| p.kind) {
        None => 0,
        Some(ProxyKind::Socks5) => 1,
        Some(ProxyKind::Http) => 2,
    });
    let proxy_host = entry(&tr!("Alamat proxy"), p.as_ref().map(|p| p.host.as_str()).unwrap_or(""));
    let proxy_port = adw::SpinRow::with_range(1.0, 65535.0, 1.0);
    proxy_port.set_title("Port");
    proxy_port.set_value(p.as_ref().map(|p| p.port).unwrap_or(1080) as f64);
    let proxy_user = entry(&tr!("Username (opsional)"), p.as_ref().and_then(|p| p.username.as_deref()).unwrap_or(""));
    let proxy_pass = password(&tr!("Password"), p.as_ref().and_then(|p| p.password.as_deref()).unwrap_or(""));
    g_proxy.add(&proxy_kind);
    g_proxy.add(&proxy_host);
    g_proxy.add(&proxy_port);
    g_proxy.add(&proxy_user);
    g_proxy.add(&proxy_pass);
    let sync_proxy = {
        let (k, j, rows, g) = (proxy_kind.clone(), jump.clone(), [proxy_host.clone().upcast::<gtk::Widget>(), proxy_port.clone().upcast(), proxy_user.clone().upcast(), proxy_pass.clone().upcast()], g_proxy.clone());
        move || {
            let on = k.selected() != 0;
            for r in &rows {
                r.set_visible(on);
            }
            g.set_description(Some(&if on && j.selected() != 0 {
                tr!("Proxy tidak dipakai di terminal selama jump host aktif.")
            } else {
                tr!("Dipakai untuk terminal host ini.")
            }));
        }
    };
    sync_proxy();
    let s = sync_proxy.clone();
    proxy_kind.connect_selected_notify(move |_| s());
    let s = sync_proxy.clone();
    jump.connect_selected_notify(move |_| s());
    page.add(&g_proxy);

    // ---- Hapus ----
    if !is_new {
        let g_del = adw::PreferencesGroup::new();
        let del = gtk::Button::with_label(&tr!("Hapus host"));
        del.add_css_class("destructive-action");
        del.add_css_class("pill");
        del.set_halign(gtk::Align::Center);
        let (c, d, host) = (ctx.clone(), dialog.clone(), h.clone());
        del.connect_clicked(move |_| {
            d.close();
            hosts::confirm_delete(&c, &host);
        });
        g_del.add(&del);
        page.add(&g_del);
    }

    // ---- Simpan ----
    let collect = {
        let base = h.clone();
        let (hostname, label, group, tags, port, username, auth, pass, keys, key_row) =
            (hostname.clone(), label.clone(), group.clone(), tags.clone(), port.clone(), username.clone(), auth.clone(), pass.clone(), keys.clone(), key_row.clone());
        let (fwd, startup, jump, others, charset, term_theme, env) =
            (fwd.clone(), startup.clone(), jump.clone(), others.clone(), charset.clone(), term_theme.clone(), env.clone());
        let (proxy_kind, proxy_host, proxy_port, proxy_user, proxy_pass) =
            (proxy_kind.clone(), proxy_host.clone(), proxy_port.clone(), proxy_user.clone(), proxy_pass.clone());
        let color = color.clone();
        move || -> Result<Host, String> {
            let mut h = base.clone();
            h.hostname = hostname.text().trim().to_string();
            if h.hostname.is_empty() {
                return Err(tr!("Isi IP atau hostname dulu"));
            }
            h.label = label.text().trim().to_string();
            h.group = opt(&group.text());
            h.tags = tags.text().split(',').filter_map(opt).collect();
            h.color = color.borrow().clone();
            h.port = port.value() as u16;
            h.username = username.text().trim().to_string();
            h.auth = match auth.selected() {
                1 => AuthMethod::Key,
                2 => AuthMethod::Agent,
                _ => AuthMethod::Password,
            };
            h.password = if h.auth == AuthMethod::Password { opt(&pass.text()) } else { None };
            h.key_id = None;
            if h.auth == AuthMethod::Key {
                let list = keys.borrow();
                let k = list.get(key_row.selected() as usize).ok_or_else(|| tr!("Pilih SSH key (atau buat di Keychain)"))?;
                h.key_id = Some(k.id.clone());
            }
            h.agent_forwarding = fwd.is_active();
            h.startup_snippet = opt(&startup.text());
            h.jump_host_id = match jump.selected() {
                0 => None,
                i => others.get(i as usize - 1).map(|o| o.id.clone()),
            };
            h.charset = if charset.selected() == 1 { "ASCII".into() } else { "UTF-8".into() };
            h.terminal_theme = match term_theme.selected() {
                0 => None,
                i => theme::TERM_THEMES.get(i as usize - 1).map(|t| t.id.to_string()),
            };
            h.env = env
                .text()
                .split(',')
                .filter_map(|pair| {
                    let (n, v) = pair.split_once('=')?;
                    let n = n.trim();
                    (!n.is_empty()).then(|| EnvVar { name: n.to_string(), value: v.trim().to_string() })
                })
                .collect();
            h.proxy = match proxy_kind.selected() {
                0 => None,
                k => {
                    let host = proxy_host.text().trim().to_string();
                    if host.is_empty() {
                        return Err(tr!("Isi alamat proxy"));
                    }
                    Some(HostProxy {
                        kind: if k == 2 { ProxyKind::Http } else { ProxyKind::Socks5 },
                        host,
                        port: proxy_port.value() as u16,
                        username: opt(&proxy_user.text()),
                        password: opt(&proxy_pass.text()),
                    })
                }
            };
            Ok(h)
        }
    };

    let save = {
        let (ctx, dialog, collect) = (ctx.clone(), dialog.clone(), collect.clone());
        move |connect: bool| {
            let host = match collect() {
                Ok(h) => h,
                Err(msg) => return ctx.toast(&msg),
            };
            let Some(v) = ctx.vault() else { return };
            match v.upsert_host(host) {
                Ok(saved) => {
                    dialog.close();
                    ctx.toast(&if is_new { tr!("Host “{}” ditambahkan", ctx::host_title(&saved)) } else { tr!("Perubahan disimpan") });
                    ctx.changed();
                    if connect {
                        terminal::open_host(&ctx, &saved, None);
                    }
                }
                Err(e) => ctx.error(e),
            }
        }
    };

    let header = adw::HeaderBar::new();
    let btn_save = gtk::Button::with_label(&tr!("Simpan"));
    let s = save.clone();
    btn_save.connect_clicked(move |_| s(false));
    let btn_connect = gtk::Button::builder().tooltip_text(tr!("Simpan lalu connect (Ctrl+Enter)")).build();
    btn_connect.set_child(Some(&icons::content("play", &tr!("Connect"))));
    btn_connect.add_css_class("suggested-action");
    let s = save.clone();
    btn_connect.connect_clicked(move |_| s(true));
    header.pack_start(&btn_save);
    header.pack_end(&btn_connect);
    let subtitle = adw::WindowTitle::new(&if is_new { tr!("Host Baru") } else { tr!("Edit Host") }, &tr!("Vault pribadi"));
    header.set_title_widget(Some(&subtitle));

    // Ctrl+Enter: simpan & connect; Ctrl+S: simpan
    let keys_ctl = gtk::EventControllerKey::new();
    let s = save.clone();
    keys_ctl.connect_key_pressed(move |_, key, _, mods| {
        use gtk::gdk::{Key, ModifierType};
        if mods.contains(ModifierType::CONTROL_MASK) {
            if key == Key::Return || key == Key::KP_Enter {
                s(true);
                return glib::Propagation::Stop;
            }
            if key.to_lower() == Key::s {
                s(false);
                return glib::Propagation::Stop;
            }
        }
        glib::Propagation::Proceed
    });
    dialog.add_controller(keys_ctl);

    let view = adw::ToolbarView::new();
    view.add_top_bar(&header);
    view.set_content(Some(&page));
    dialog.set_child(Some(&view));
    dialog.present(Some(&ctx.window));
    hostname.grab_focus();
}
