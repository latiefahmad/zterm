//! Halaman Hosts: kartu per grup, cari, dan aksi per host.

use std::collections::BTreeMap;

use adw::prelude::*;
use zterm_core::{AuthMethod, Host};
use gtk::gio;

use crate::ctx::{self, Ctx};
use crate::{editor, terminal, theme};

pub fn build(ctx: &Ctx) -> gtk::Widget {
    let root = gtk::Box::new(gtk::Orientation::Vertical, 0);

    // ---- Header halaman ----
    let header = gtk::Box::new(gtk::Orientation::Horizontal, 12);
    header.set_margin_top(20);
    header.set_margin_start(24);
    header.set_margin_end(24);
    header.set_margin_bottom(12);
    let titles = gtk::Box::new(gtk::Orientation::Vertical, 2);
    titles.set_hexpand(true);
    let title = gtk::Label::builder().label(tr!("Hosts")).xalign(0.0).build();
    title.add_css_class("zterm-title");
    let subtitle = gtk::Label::builder().xalign(0.0).build();
    subtitle.add_css_class("zterm-muted");
    titles.append(&title);
    titles.append(&subtitle);
    header.append(&titles);

    let search = gtk::SearchEntry::builder().placeholder_text(tr!("Cari host, IP, tag…")).width_chars(22).valign(gtk::Align::Center).build();
    header.append(&search);

    let hide = gtk::ToggleButton::builder().icon_name("view-reveal-symbolic").tooltip_text(tr!("Sembunyikan alamat host")).valign(gtk::Align::Center).build();
    hide.add_css_class("flat");
    header.append(&hide);

    let add = gtk::Button::builder().valign(gtk::Align::Center).build();
    add.set_child(Some(&adw::ButtonContent::builder().icon_name("list-add-symbolic").label(tr!("Host Baru")).build()));
    add.add_css_class("suggested-action");
    add.set_tooltip_text(Some(&tr!("Host Baru (Ctrl+Shift+N)")));
    let c = ctx.clone();
    add.connect_clicked(move |_| editor::open(&c, None));
    header.append(&add);
    root.append(&header);

    // ---- Isi ----
    let body = gtk::Box::new(gtk::Orientation::Vertical, 8);
    body.set_margin_start(24);
    body.set_margin_end(24);
    body.set_margin_bottom(24);
    let scroll = gtk::ScrolledWindow::builder().vexpand(true).hscrollbar_policy(gtk::PolicyType::Never).child(&body).build();
    root.append(&scroll);

    let refresh = {
        let (ctx, body, subtitle, search) = (ctx.clone(), body.clone(), subtitle.clone(), search.clone());
        move || render(&ctx, &body, &subtitle, &search.text())
    };
    let r = refresh.clone();
    search.connect_search_changed(move |_| r());
    let (r, c) = (refresh.clone(), ctx.clone());
    hide.connect_toggled(move |b| {
        c.hide_addresses.set(b.is_active());
        b.set_icon_name(if b.is_active() { "view-conceal-symbolic" } else { "view-reveal-symbolic" });
        b.set_tooltip_text(Some(&if b.is_active() { tr!("Tampilkan alamat host") } else { tr!("Sembunyikan alamat host") }));
        r();
    });
    ctx.on_change(refresh);
    root.upcast()
}

fn matches(h: &Host, q: &str) -> bool {
    if q.is_empty() {
        return true;
    }
    let q = q.to_lowercase();
    [&h.label, &h.hostname, &h.username].iter().any(|s| s.to_lowercase().contains(&q))
        || h.group.as_deref().is_some_and(|g| g.to_lowercase().contains(&q))
        || h.tags.iter().any(|t| t.to_lowercase().contains(&q))
}

fn render(ctx: &Ctx, body: &gtk::Box, subtitle: &gtk::Label, query: &str) {
    while let Some(c) = body.first_child() {
        body.remove(&c);
    }
    let all = ctx.hosts();
    let online: usize = all.iter().filter(|h| ctx.connected_count(&h.id) > 0).count();
    subtitle.set_label(&if online > 0 {
        tr!("{} server · {} terhubung", all.len(), online)
    } else {
        tr!("{} server · klik dua kali kartu untuk connect", all.len())
    });

    if all.is_empty() {
        let status = adw::StatusPage::builder()
            .icon_name("network-server-symbolic")
            .title(tr!("Belum ada host"))
            .description(tr!("Tambahkan server pertamamu, lalu connect dengan satu klik."))
            .vexpand(true)
            .build();
        let b = gtk::Button::with_label(&tr!("Tambah host"));
        b.add_css_class("suggested-action");
        b.add_css_class("pill");
        b.set_halign(gtk::Align::Center);
        let c = ctx.clone();
        b.connect_clicked(move |_| editor::open(&c, None));
        status.set_child(Some(&b));
        body.append(&status);
        return;
    }

    let hosts: Vec<Host> = all.into_iter().filter(|h| matches(h, query)).collect();
    if hosts.is_empty() {
        let status = adw::StatusPage::builder()
            .icon_name("system-search-symbolic")
            .title(tr!("Tidak ada host yang cocok dengan “{}”", query))
            .vexpand(true)
            .build();
        body.append(&status);
        return;
    }

    // Host tanpa grup tampil paling atas dengan judul "HOSTS"
    let mut groups: BTreeMap<(u8, String), Vec<Host>> = BTreeMap::new();
    for h in hosts {
        let key = match h.group.as_deref().map(str::trim).filter(|g| !g.is_empty()) {
            Some(g) => (1, g.to_string()),
            None => (0, tr!("Hosts")),
        };
        groups.entry(key).or_default().push(h);
    }
    for ((_, name), list) in groups {
        let head = gtk::Label::builder().label(format!("{}  ·  {}", name.to_uppercase(), list.len())).xalign(0.0).build();
        head.add_css_class("zterm-group");
        body.append(&head);
        let flow = gtk::FlowBox::builder()
            .selection_mode(gtk::SelectionMode::None)
            .homogeneous(true)
            .min_children_per_line(1)
            .max_children_per_line(6)
            .row_spacing(12)
            .column_spacing(12)
            .build();
        for h in &list {
            flow.append(&card(ctx, h));
        }
        body.append(&flow);
    }
}

fn auth_label(a: AuthMethod) -> &'static str {
    match a {
        AuthMethod::Password => "Password",
        AuthMethod::Key => "SSH Key",
        AuthMethod::Agent => "Agent",
    }
}

fn card(ctx: &Ctx, h: &Host) -> gtk::Widget {
    let card = gtk::Box::new(gtk::Orientation::Vertical, 12);
    card.add_css_class("zterm-card");
    card.set_width_request(250);

    let top = gtk::Box::new(gtk::Orientation::Horizontal, 12);
    top.append(&theme::color_tile(&h.color, "network-server-symbolic", 40));
    let names = gtk::Box::new(gtk::Orientation::Vertical, 2);
    names.set_hexpand(true);
    names.set_valign(gtk::Align::Center);
    let t = gtk::Label::builder().label(ctx::host_title(h)).xalign(0.0).ellipsize(gtk::pango::EllipsizeMode::End).build();
    t.add_css_class("zterm-card-title");
    let a = gtk::Label::builder().label(ctx::host_address(h, ctx.hide_addresses.get())).xalign(0.0).ellipsize(gtk::pango::EllipsizeMode::End).build();
    a.add_css_class("zterm-card-addr");
    names.append(&t);
    names.append(&a);
    top.append(&names);
    top.append(&menu_button(ctx, h));
    card.append(&top);

    let bottom = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    let chip = gtk::Label::new(Some(auth_label(h.auth)));
    chip.add_css_class("zterm-chip");
    chip.set_valign(gtk::Align::Center);
    bottom.append(&chip);
    for tag in h.tags.iter().filter(|t| !t.is_empty()).take(2) {
        let c = gtk::Label::new(Some(tag));
        c.add_css_class("zterm-chip");
        c.set_valign(gtk::Align::Center);
        bottom.append(&c);
    }
    let n = ctx.connected_count(&h.id);
    if n > 0 {
        let c = gtk::Label::new(Some(if n > 1 { tr!("Terhubung ×{}", n) } else { tr!("Terhubung") }.as_str()));
        c.add_css_class("zterm-chip");
        c.add_css_class("online");
        c.set_valign(gtk::Align::Center);
        bottom.append(&c);
    }
    let spacer = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    spacer.set_hexpand(true);
    bottom.append(&spacer);
    let connect = gtk::Button::builder().tooltip_text(tr!("Connect (klik dua kali kartu)")).build();
    connect.set_child(Some(&adw::ButtonContent::builder().icon_name("media-playback-start-symbolic").label(tr!("Connect")).build()));
    connect.add_css_class("suggested-action");
    connect.add_css_class("pill");
    connect.add_css_class("small");
    let (c, host) = (ctx.clone(), h.clone());
    connect.connect_clicked(move |_| terminal::open_host(&c, &host, None));
    bottom.append(&connect);
    card.append(&bottom);

    let dbl = gtk::GestureClick::new();
    let (c, host) = (ctx.clone(), h.clone());
    dbl.connect_pressed(move |g, n, _, _| {
        if n == 2 {
            g.set_state(gtk::EventSequenceState::Claimed);
            terminal::open_host(&c, &host, None);
        }
    });
    card.add_controller(dbl);
    card.upcast()
}

fn menu_button(ctx: &Ctx, h: &Host) -> gtk::MenuButton {
    let group = gio::SimpleActionGroup::new();
    let add = |name: &str, f: Box<dyn Fn()>| {
        let a = gio::SimpleAction::new(name, None);
        a.connect_activate(move |_, _| f());
        group.add_action(&a);
    };
    let (c, host) = (ctx.clone(), h.clone());
    add("connect", Box::new(move || terminal::open_host(&c, &host, None)));
    let (c, host) = (ctx.clone(), h.clone());
    add("edit", Box::new(move || editor::open(&c, Some(host.clone()))));
    let (c, host) = (ctx.clone(), h.clone());
    add("duplicate", Box::new(move || {
        let mut copy = host.clone();
        copy.id = String::new();
        copy.label = tr!("{} (salinan)", ctx::host_title(&host));
        if let Some(v) = c.vault() {
            match v.upsert_host(copy) {
                Ok(_) => c.changed(),
                Err(e) => c.error(e),
            }
        }
    }));
    let (c, host) = (ctx.clone(), h.clone());
    add("copy", Box::new(move || {
        ctx::copy_text(&ctx::host_address(&host, false));
        c.toast(&tr!("Alamat disalin"));
    }));
    let (c, host) = (ctx.clone(), h.clone());
    add("delete", Box::new(move || confirm_delete(&c, &host)));

    let menu = gio::Menu::new();
    let s1 = gio::Menu::new();
    s1.append(Some(&tr!("Connect")), Some("host.connect"));
    s1.append(Some(&tr!("Edit")), Some("host.edit"));
    s1.append(Some(&tr!("Duplikat")), Some("host.duplicate"));
    s1.append(Some(&tr!("Salin alamat")), Some("host.copy"));
    menu.append_section(None, &s1);
    let s2 = gio::Menu::new();
    s2.append(Some(&tr!("Hapus")), Some("host.delete"));
    menu.append_section(None, &s2);

    let b = gtk::MenuButton::builder().icon_name("view-more-symbolic").menu_model(&menu).valign(gtk::Align::Start).build();
    b.add_css_class("flat");
    b.add_css_class("circular");
    b.insert_action_group("host", Some(&group));
    b
}

pub fn confirm_delete(ctx: &Ctx, h: &Host) {
    let d = adw::AlertDialog::new(
        Some(&tr!("Hapus host “{}”?", ctx::host_title(h))),
        Some(&tr!("Tindakan ini tidak bisa dibatalkan.")),
    );
    d.add_responses(&[("cancel", &tr!("Batal")), ("delete", &tr!("Hapus"))]);
    d.set_response_appearance("delete", adw::ResponseAppearance::Destructive);
    d.set_default_response(Some("cancel"));
    let (c, id) = (ctx.clone(), h.id.clone());
    d.connect_response(None, move |_, r| {
        if r == "delete" {
            if let Some(v) = c.vault() {
                match v.delete_host(id.clone()) {
                    Ok(()) => {
                        c.toast(&tr!("Host dihapus"));
                        c.changed();
                    }
                    Err(e) => c.error(e),
                }
            }
        }
    });
    d.present(Some(&ctx.window));
}

