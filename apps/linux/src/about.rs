//! Tentang Zterm: hero berbingkai terminal, tautan komunitas, dan info singkat.
//!
//! Linux belum punya auto-updater, jadi kartu versi hanya menampilkan rilis
//! resmi + tautan catatan rilis (bukan tombol "Periksa" palsu). Sync juga belum
//! tersedia di Linux, jadi baris Sync menyebut penyimpanan lokal.

use adw::prelude::*;
use gtk::gio;

use crate::ctx::Ctx;
use crate::{icons, theme};

const WEBSITE: &str = "https://latief.id/zterm/";
const GITHUB: &str = "https://github.com/latiefahmad/zterm";
const RELEASES: &str = "https://github.com/latiefahmad/zterm/releases";
const ISSUES: &str = "https://github.com/latiefahmad/zterm/issues";
const PRIVACY: &str = "https://latief.id/zterm/privacy.html";
const TERMS: &str = "https://latief.id/zterm/terms.html";
const DONATE: &str = "https://saweria.co/latiefahmad";

pub fn build(ctx: &Ctx) -> gtk::Widget {
    let body = gtk::Box::new(gtk::Orientation::Vertical, 14);
    body.set_margin_top(18);
    body.set_margin_bottom(24);
    body.set_margin_start(24);
    body.set_margin_end(24);
    body.append(&hero());
    body.append(&panels());
    body.append(&footer(ctx));

    let clamp = adw::Clamp::builder().maximum_size(900).tightening_threshold(600).child(&body).build();
    let scroll = gtk::ScrolledWindow::builder()
        .vexpand(true)
        .hscrollbar_policy(gtk::PolicyType::Never)
        .child(&clamp)
        .build();

    // Latar: grid titik + sorotan mint, digambar sendiri agar tidak membebani
    // pohon widget dengan ratusan titik.
    let backdrop = gtk::DrawingArea::new();
    backdrop.set_hexpand(true);
    backdrop.set_vexpand(true);
    let dark = adw::StyleManager::default().is_dark();
    backdrop.set_draw_func(move |_, cr, width, height| {
        let (w, h) = (width as f64, height as f64);
        let glow = gtk::cairo::RadialGradient::new(w * 0.18, 0.0, 0.0, w * 0.18, 0.0, w.max(h) * 0.9);
        glow.add_color_stop_rgba(0.0, 0.247, 0.816, 0.706, if dark { 0.12 } else { 0.15 });
        glow.add_color_stop_rgba(1.0, 0.247, 0.816, 0.706, 0.0);
        let _ = cr.set_source(&glow);
        let _ = cr.paint();

        cr.set_source_rgba(0.247, 0.816, 0.706, if dark { 0.10 } else { 0.13 });
        let gap = 24.0;
        let mut y = gap / 2.0;
        while y < h {
            let mut x = gap / 2.0;
            while x < w {
                cr.arc(x, y, 1.0, 0.0, std::f64::consts::TAU);
                let _ = cr.fill();
                x += gap;
            }
            y += gap;
        }
    });

    let root = gtk::Overlay::new();
    root.set_child(Some(&backdrop));
    root.add_overlay(&scroll);
    root.set_vexpand(true);
    root.upcast()
}

fn hero() -> gtk::Widget {
    let card = gtk::Box::new(gtk::Orientation::Vertical, 0);
    card.add_css_class("zterm-term-card");
    card.set_overflow(gtk::Overflow::Hidden);

    let content = gtk::Box::new(gtk::Orientation::Vertical, 0);

    // Chrome ala terminal.
    let chrome = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    chrome.add_css_class("zterm-term-chrome");
    chrome.append(&theme::dot("#FF5F57", 8));
    chrome.append(&theme::dot("#FEBC2E", 8));
    chrome.append(&theme::dot("#28C840", 8));
    let chrome_title = gtk::Label::new(Some("ZTERM — ABOUT"));
    chrome_title.add_css_class("zterm-term-title");
    chrome_title.set_hexpand(true);
    chrome_title.set_xalign(1.0);
    chrome.append(&chrome_title);
    content.append(&chrome);

    let body = gtk::Box::new(gtk::Orientation::Vertical, 10);
    body.set_margin_top(14);
    body.set_margin_bottom(16);
    body.set_margin_start(18);
    body.set_margin_end(18);

    // Logo + judul + tagline + badge.
    let main = gtk::Box::new(gtk::Orientation::Horizontal, 14);
    main.append(&theme::logo(56));

    let copy = gtk::Box::new(gtk::Orientation::Vertical, 3);
    copy.set_hexpand(true);
    copy.set_valign(gtk::Align::Center);
    copy.append(&label(&tr!("Tentang Zterm"), "zterm-eyebrow"));
    copy.append(&label("Zterm", "zterm-about-title"));

    let tagline = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    let prompt = label(">", "zterm-prompt");
    tagline.append(&prompt);
    tagline.append(&label(&tr!("Semua servermu, satu terminal."), "zterm-about-tagline"));
    let cursor = label("▍", "zterm-prompt");
    tagline.append(&cursor);
    copy.append(&tagline);

    let badges = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    badges.append(&badge(&format!("v{}", env!("CARGO_PKG_VERSION")), "mint"));
    badges.append(&badge(&format!("core {}", zterm_core::core_version()), "blue"));
    badges.append(&badge("MIT", "violet"));
    copy.append(&badges);
    copy.append(&label("GTK4 · LIBADWAITA · VTE", "zterm-eyebrow"));
    main.append(&copy);
    body.append(&main);

    // Status versi: Linux tidak punya auto-updater, jadi tampilkan rilis resmi.
    let status = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    status.add_css_class("zterm-status-card");
    status.append(&theme::dot("#3FD0B4", 8));
    let status_copy = gtk::Box::new(gtk::Orientation::Vertical, 0);
    status_copy.set_hexpand(true);
    status_copy.append(&label("VERSI", "zterm-eyebrow"));
    status_copy.append(&label(&format!("v{} · {}", env!("CARGO_PKG_VERSION"), tr!("Rilis resmi")), "zterm-about-status"));
    status.append(&status_copy);
    let releases = gtk::Button::new();
    releases.add_css_class("pill");
    releases.add_css_class("small");
    releases.set_child(Some(&icons::content("sparkle", &tr!("Catatan rilis"))));
    releases.connect_clicked(|_| open_url(RELEASES));
    status.append(&releases);
    body.append(&status);

    let note = label(&tr!("Gratis · tanpa iklan · local-first"), "zterm-hint");
    note.set_halign(gtk::Align::End);
    body.append(&note);
    content.append(&body);

    let overlay = gtk::Overlay::new();
    overlay.set_child(Some(&content));
    let watermark = gtk::Label::new(Some(">_"));
    watermark.add_css_class("zterm-term-watermark");
    watermark.set_halign(gtk::Align::End);
    watermark.set_valign(gtk::Align::End);
    watermark.set_margin_end(14);
    // Jangan menelan klik tombol di bawahnya (mis. Catatan rilis).
    watermark.set_can_target(false);
    overlay.add_overlay(&watermark);

    card.append(&overlay);
    card.upcast()
}

fn panels() -> gtk::Widget {
    let flow = gtk::FlowBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .max_children_per_line(2)
        .min_children_per_line(1)
        .homogeneous(true)
        .column_spacing(14)
        .row_spacing(14)
        .build();
    flow.set_halign(gtk::Align::Fill);
    flow.set_hexpand(true);
    flow.insert(&explore_panel(), -1);
    flow.insert(&info_panel(), -1);
    flow.upcast()
}

fn explore_panel() -> gtk::Widget {
    let panel = gtk::Box::new(gtk::Orientation::Vertical, 10);
    panel.add_css_class("zterm-card");
    panel.set_hexpand(true);
    panel.append(&panel_head(&tr!("Jelajahi"), &tr!("Buka di browser")));

    let grid = gtk::Grid::builder()
        .column_spacing(8)
        .row_spacing(8)
        .column_homogeneous(true)
        .row_homogeneous(true)
        .build();
    let tiles = [
        ("globe", "#3FD0B4", tr!("Website"), "latief.id/zterm".to_string(), WEBSITE),
        ("file-code", "#5B9CF5", "GitHub".to_string(), "latiefahmad/zterm".to_string(), GITHUB),
        ("sparkle", "#9D7CF2", tr!("Catatan rilis"), tr!("Yang baru"), RELEASES),
        ("bug", "#F2A65A", tr!("Laporkan bug"), "github issues".to_string(), ISSUES),
    ];
    for (i, (icon, color, title, subtitle, url)) in tiles.into_iter().enumerate() {
        grid.attach(&tile(icon, color, &title, &subtitle, url), i as i32 % 2, i as i32 / 2, 1, 1);
    }
    panel.append(&grid);
    panel.upcast()
}

fn tile(icon: &str, color: &str, title: &str, subtitle: &str, url: &'static str) -> gtk::Widget {
    let b = gtk::Button::new();
    b.add_css_class("zterm-about-tile");
    b.set_hexpand(true);
    b.set_halign(gtk::Align::Fill);

    let row = gtk::Box::new(gtk::Orientation::Horizontal, 9);
    row.append(&theme::color_tile(color, icon, 30));
    let text = gtk::Box::new(gtk::Orientation::Vertical, 1);
    text.set_hexpand(true);
    let t = label(title, "zterm-about-tile-title");
    t.set_ellipsize(gtk::pango::EllipsizeMode::End);
    t.set_xalign(0.0);
    let s = label(subtitle, "zterm-about-tile-sub");
    s.set_ellipsize(gtk::pango::EllipsizeMode::End);
    s.set_xalign(0.0);
    text.append(&t);
    text.append(&s);
    row.append(&text);
    b.set_child(Some(&row));
    b.connect_clicked(move |_| open_url(url));
    b.upcast()
}

fn info_panel() -> gtk::Widget {
    let panel = gtk::Box::new(gtk::Orientation::Vertical, 10);
    panel.add_css_class("zterm-card");
    panel.set_hexpand(true);
    panel.append(&panel_head(&tr!("Di balik layar"), "native · rust"));

    let list = gtk::Box::new(gtk::Orientation::Vertical, 0);
    let rows = [
        ("user", tr!("Dibuat oleh"), "Latief Ahmad".to_string()),
        ("cube", tr!("Inti"), "zterm-core · Rust".to_string()),
        ("shield-check", tr!("Keamanan"), "Argon2id + XChaCha20".to_string()),
        ("cloud", "Sync".to_string(), tr!("Hanya di perangkat ini")),
    ];
    let last = rows.len() - 1;
    for (i, (icon, title, value)) in rows.into_iter().enumerate() {
        list.append(&info_row(icon, &title, &value, i == last));
    }
    panel.append(&list);
    panel.upcast()
}

fn info_row(icon: &str, title: &str, value: &str, last: bool) -> gtk::Widget {
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 9);
    row.add_css_class("zterm-info-row");
    if last {
        row.add_css_class("last");
    }
    row.append(&theme::color_tile("#94A3B8", icon, 26));
    let l = label(title, "zterm-info-label");
    l.set_size_request(74, -1);
    l.set_xalign(0.0);
    row.append(&l);
    let v = label(value, "zterm-info-value");
    v.set_hexpand(true);
    v.set_xalign(1.0);
    v.set_ellipsize(gtk::pango::EllipsizeMode::End);
    row.append(&v);
    row.upcast()
}

fn footer(ctx: &Ctx) -> gtk::Widget {
    let footer = gtk::Box::new(gtk::Orientation::Vertical, 4);

    let legal = gtk::Box::new(gtk::Orientation::Horizontal, 14);
    legal.append(&link(&tr!("Kebijakan Privasi"), PRIVACY));
    legal.append(&label("·", "zterm-hint"));
    legal.append(&link(&tr!("Syarat Layanan"), TERMS));
    footer.append(&legal);
    footer.append(&label(&tr!("© 2026 Latief Ahmad · Lisensi MIT"), "zterm-hint"));

    let bottom = gtk::Box::new(gtk::Orientation::Horizontal, 10);
    bottom.append(&crate::window::language_button(ctx, false));
    let spacer = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    spacer.set_hexpand(true);
    bottom.append(&spacer);
    let support = gtk::Button::new();
    support.add_css_class("suggested-action");
    support.add_css_class("zterm-support");
    support.add_css_class("pill");
    support.set_child(Some(&icons::content("heart", "Support me")));
    support.set_tooltip_text(Some("saweria.co/latiefahmad"));
    support.connect_clicked(|_| open_url(DONATE));
    bottom.append(&support);
    footer.append(&bottom);

    footer.upcast()
}

fn panel_head(title: &str, hint: &str) -> gtk::Widget {
    let head = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    head.append(&label(title, "zterm-card-title"));
    let spacer = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    spacer.set_hexpand(true);
    head.append(&spacer);
    head.append(&label(&hint.to_uppercase(), "zterm-eyebrow"));
    head.upcast()
}

fn badge(text: &str, class: &str) -> gtk::Label {
    let l = label(text, "zterm-badge");
    l.add_css_class(class);
    l
}

fn link(text: &str, url: &str) -> gtk::LinkButton {
    let b = gtk::LinkButton::with_label(url, text);
    b.add_css_class("zterm-link");
    b
}

fn label(text: &str, class: &str) -> gtk::Label {
    let l = gtk::Label::new(Some(text));
    l.add_css_class(class);
    l.set_xalign(0.0);
    l
}

fn open_url(url: &str) {
    let _ = gio::AppInfo::launch_default_for_uri(url, None::<&gio::AppLaunchContext>);
}
