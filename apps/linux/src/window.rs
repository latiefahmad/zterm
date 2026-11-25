//! Jendela utama: sidebar + tab (Beranda disematkan, lalu satu tab per sesi terminal).

use adw::prelude::*;
use gtk::{gio, glib};

use crate::ctx::{App, Ctx};
use crate::{hosts, icons, keychain, onboarding, snippets, terminal, theme};

/// Halaman sidebar MVP: (id, judul, ikon Phosphor).
const SECTIONS: [(&str, &str, &str); 3] = [
    ("hosts", "Hosts", "hard-drives"),
    ("keychain", "Keychain", "key"),
    ("snippets", "Snippets", "brackets-curly"),
];

pub fn build(app: &adw::Application) {
    icons::install();
    let window = adw::ApplicationWindow::builder()
        .application(app)
        .title("Zterm")
        .default_width(1200)
        .default_height(780)
        .width_request(360)
        .height_request(320)
        .build();
    let ctx = App::new(window.clone());

    install_language_action(app, &ctx);
    let main = build_main(&ctx);
    ctx.root.add_named(&main, Some("main"));
    onboarding::show_start(&ctx);
    install_shortcuts(app, &ctx);
    window.present();
}

fn build_main(ctx: &Ctx) -> gtk::Widget {
    // ---- Sidebar ----
    let sidebar_box = gtk::Box::new(gtk::Orientation::Vertical, 0);

    let brand = gtk::Box::new(gtk::Orientation::Horizontal, 10);
    brand.set_margin_start(14);
    brand.set_margin_end(14);
    brand.set_margin_top(6);
    brand.set_margin_bottom(10);
    brand.append(&theme::logo(30));
    let names = gtk::Box::new(gtk::Orientation::Vertical, 0);
    let n1 = gtk::Label::builder().label("Zterm").xalign(0.0).build();
    n1.add_css_class("zterm-brand");
    let n2 = gtk::Label::builder().label(tr!("SSH Client")).xalign(0.0).build();
    n2.add_css_class("zterm-hint");
    names.append(&n1);
    names.append(&n2);
    brand.append(&names);

    let list = gtk::ListBox::new();
    list.add_css_class("navigation-sidebar");
    list.add_css_class("zterm-sidebar");
    for (_, title, icon) in SECTIONS {
        let row = gtk::Box::new(gtk::Orientation::Horizontal, 12);
        row.append(&icons::image(icon, 18));
        row.append(&gtk::Label::new(Some(&tr!(title))));
        list.append(&row);
    }
    let c = ctx.clone();
    list.connect_row_activated(move |_, row| {
        if let Some((id, _, _)) = SECTIONS.get(row.index() as usize) {
            c.show_page(id);
        }
    });
    list.connect_row_selected(|_, _| {});
    let list_scroll = gtk::ScrolledWindow::builder().vexpand(true).hscrollbar_policy(gtk::PolicyType::Never).child(&list).build();

    let soon = gtk::Label::new(Some(&tr!("SFTP, Database, Docker, Dashboard, Tim, dan sync Google menyusul di versi Linux.")));
    soon.add_css_class("zterm-hint");
    soon.set_wrap(true);
    soon.set_xalign(0.0);
    soon.set_margin_start(14);
    soon.set_margin_end(14);
    soon.set_margin_bottom(8);

    let lock = icons::button("lock-simple", &tr!("Kunci vault (Ctrl+Shift+L)"));
    let c = ctx.clone();
    lock.connect_clicked(move |_| onboarding::lock(&c));
    let footer = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    footer.set_margin_start(10);
    footer.set_margin_end(10);
    footer.set_margin_bottom(10);
    let local_label = gtk::Label::builder().label(tr!("Vault lokal")).xalign(0.0).hexpand(true).build();
    local_label.add_css_class("zterm-hint");
    footer.append(&local_label);
    footer.append(&language_button(ctx, false));
    footer.append(&lock);

    sidebar_box.append(&brand);
    sidebar_box.append(&list_scroll);
    sidebar_box.append(&soon);
    sidebar_box.append(&footer);

    let sidebar_view = adw::ToolbarView::new();
    let sh = adw::HeaderBar::new();
    sh.set_show_title(false);
    sidebar_view.add_top_bar(&sh);
    sidebar_view.set_content(Some(&sidebar_box));

    // ---- Halaman di tab Beranda ----
    ctx.pages.add_named(&hosts::build(ctx), Some("hosts"));
    ctx.pages.add_named(&keychain::build(ctx), Some("keychain"));
    ctx.pages.add_named(&snippets::build(ctx), Some("snippets"));
    // Sorot baris sidebar sesuai halaman
    let l = list.clone();
    ctx.pages.connect_visible_child_name_notify(move |s| {
        let name = s.visible_child_name().map(|n| n.to_string()).unwrap_or_default();
        if let Some(i) = SECTIONS.iter().position(|(id, _, _)| *id == name) {
            l.select_row(l.row_at_index(i as i32).as_ref());
        }
    });
    list.select_row(list.row_at_index(0).as_ref());

    let home = ctx.tabs.append_pinned(&ctx.pages);
    home.set_title(&tr!("Beranda"));
    home.set_icon(Some(&gio::ThemedIcon::new(&icons::themed("squares-four"))));
    home.set_tooltip(&tr!("Daftar host (Ctrl+0)"));
    *ctx.home.borrow_mut() = Some(home);

    let c = ctx.clone();
    ctx.tabs.connect_close_page(move |view, page| {
        if c.home.borrow().as_ref() == Some(page) {
            view.close_page_finish(page, false);
        } else {
            terminal::close_page(&c, page);
            view.close_page_finish(page, true);
        }
        glib::Propagation::Stop
    });

    // ---- Area konten ----
    let header = adw::HeaderBar::new();
    let tab_bar = adw::TabBar::builder().view(&ctx.tabs).autohide(false).expand_tabs(false).build();
    header.set_title_widget(Some(&tab_bar));

    let local_btn = icons::button("terminal-window", &tr!("Terminal lokal (Ctrl+Shift+T)"));
    let c = ctx.clone();
    local_btn.connect_clicked(move |_| terminal::open_local(&c));
    header.pack_start(&local_btn);

    let snippet_btn = icons::menu_button("brackets-curly", &tr!("Jalankan snippet di tab ini"));
    let popover = gtk::Popover::new();
    snippet_btn.set_popover(Some(&popover));
    {
        let c = ctx.clone();
        let pop = popover.clone();
        popover.connect_show(move |_| fill_snippet_popover(&c, &pop));
    }
    header.pack_end(&snippet_btn);
    // Tombol snippet hanya untuk tab terminal
    let b = snippet_btn.clone();
    let c = ctx.clone();
    ctx.tabs.connect_selected_page_notify(move |_| {
        b.set_sensitive(terminal::active_session(&c).is_some());
        if let Some(s) = terminal::active_session(&c) {
            s.term.grab_focus();
        }
    });
    snippet_btn.set_sensitive(false);

    let content = adw::ToolbarView::new();
    content.add_top_bar(&header);
    content.set_content(Some(&ctx.tabs));

    let split = adw::OverlaySplitView::builder()
        .sidebar(&sidebar_view)
        .content(&content)
        .min_sidebar_width(200.0)
        .max_sidebar_width(240.0)
        .build();

    // Sidebar jadi overlay di jendela sempit
    let toggle = gtk::ToggleButton::builder().tooltip_text(tr!("Sidebar")).visible(false).build();
    toggle.set_child(Some(&icons::image("sidebar-simple", 18)));
    toggle.add_css_class("flat");
    split.bind_property("show-sidebar", &toggle, "active").bidirectional().sync_create().build();
    split.bind_property("collapsed", &toggle, "visible").sync_create().build();
    header.pack_start(&toggle);
    let bp = adw::Breakpoint::new(adw::BreakpointCondition::new_length(adw::BreakpointConditionLengthType::MaxWidth, 760.0, adw::LengthUnit::Sp));
    bp.add_setter(&split, "collapsed", Some(&true.to_value()));
    ctx.window.add_breakpoint(bp);

    split.upcast()
}

fn fill_snippet_popover(ctx: &Ctx, popover: &gtk::Popover) {
    let list = gtk::ListBox::new();
    list.add_css_class("boxed-list");
    list.set_selection_mode(gtk::SelectionMode::None);
    let snippets = ctx.snippets();
    if snippets.is_empty() {
        let l = gtk::Label::new(Some(&tr!("Belum ada snippet")));
        l.add_css_class("zterm-muted");
        l.set_margin_top(12);
        l.set_margin_bottom(12);
        l.set_margin_start(12);
        l.set_margin_end(12);
        popover.set_child(Some(&l));
        return;
    }
    for s in snippets {
        let row = adw::ActionRow::builder().title(glib::markup_escape_text(&s.label)).subtitle(glib::markup_escape_text(&s.command)).activatable(true).build();
        row.set_subtitle_lines(1);
        let (c, pop, cmd) = (ctx.clone(), popover.clone(), s.command.clone());
        row.connect_activated(move |_| {
            pop.popdown();
            if let Some(sess) = terminal::active_session(&c) {
                sess.send(&format!("{cmd}\n"));
            }
        });
        list.append(&row);
    }
    let scroll = gtk::ScrolledWindow::builder().child(&list).propagate_natural_height(true).max_content_height(400).min_content_width(320).build();
    popover.set_child(Some(&scroll));
}

fn install_shortcuts(app: &adw::Application, ctx: &Ctx) {
    let add = |name: &str, accels: &[&str], f: Box<dyn Fn()>| {
        let a = gio::SimpleAction::new(name, None);
        a.connect_activate(move |_, _| f());
        app.add_action(&a);
        app.set_accels_for_action(&format!("app.{name}"), accels);
    };
    let unlocked = {
        let c = ctx.clone();
        move || c.vault().is_some()
    };
    let (c, u) = (ctx.clone(), unlocked.clone());
    add("local-terminal", &["<Control><Shift>t"], Box::new(move || if u() { terminal::open_local(&c) }));
    let (c, u) = (ctx.clone(), unlocked.clone());
    add("home", &["<Control>0"], Box::new(move || if u() { c.show_page("hosts") }));
    let (c, u) = (ctx.clone(), unlocked.clone());
    add("lock", &["<Control><Shift>l"], Box::new(move || if u() { onboarding::lock(&c) }));
    let (c, u) = (ctx.clone(), unlocked.clone());
    add("new-host", &["<Control><Shift>n"], Box::new(move || if u() { crate::editor::open(&c, None) }));
    let (c, u) = (ctx.clone(), unlocked.clone());
    add("close-tab", &["<Control><Shift>w"], Box::new(move || {
        if u() {
            if let Some(s) = terminal::active_session(&c) {
                if let Some(p) = s.page() {
                    c.tabs.close_page(&p);
                }
            }
        }
    }));
    // Ctrl+1..9 → tab terminal ke-n
    for i in 1..=9u32 {
        let c = ctx.clone();
        add(&format!("tab-{i}"), &[&format!("<Control>{i}")], Box::new(move || {
            let n = c.tabs.n_pages();
            if (i as i32) < n {
                c.tabs.set_selected_page(&c.tabs.nth_page(i as i32));
            }
        }));
    }
}

// ---- Bahasa ----

/// Tombol menu "Bahasa / Language" (Ikuti sistem / Bahasa Indonesia / English).
/// `labeled`: tampilkan nama bahasa aktif di samping ikon (layar welcome & kunci).
pub fn language_button(_ctx: &Ctx, labeled: bool) -> gtk::MenuButton {
    let section = gio::Menu::new();
    for c in crate::i18n::CHOICES {
        let item = gio::MenuItem::new(Some(&crate::i18n::choice_title(c)), None);
        item.set_action_and_target_value(Some("app.language"), Some(&c.to_variant()));
        section.append_item(&item);
    }
    let menu = gio::Menu::new();
    menu.append_section(Some("Bahasa / Language"), &section);
    let b = gtk::MenuButton::builder().menu_model(&menu).tooltip_text("Bahasa / Language").build();
    if labeled {
        let current = if crate::i18n::english() { "English" } else { "Bahasa Indonesia" };
        b.set_child(Some(&icons::content("globe", current)));
    } else {
        b.set_child(Some(&icons::image("globe", 18)));
    }
    b.add_css_class("flat");
    b
}

fn install_language_action(app: &adw::Application, ctx: &Ctx) {
    let a = gio::SimpleAction::new_stateful("language", Some(glib::VariantTy::STRING), &crate::i18n::choice().to_variant());
    let c = ctx.clone();
    a.connect_activate(move |a, param| {
        let Some(choice) = param.and_then(|p| p.get::<String>()) else { return };
        if a.state().and_then(|s| s.get::<String>()).as_deref() == Some(choice.as_str()) {
            return;
        }
        a.set_state(&choice.to_variant());
        crate::i18n::set_choice(&choice);
        let d = adw::AlertDialog::new(
            Some(&tr!("Bahasa diterapkan setelah Zterm dibuka ulang")),
            Some(&tr!("Membuka ulang sekarang akan menutup semua tab terminal dan mengunci vault.")),
        );
        d.add_responses(&[("later", &tr!("Nanti")), ("restart", &tr!("Buka ulang sekarang"))]);
        d.set_response_appearance("restart", adw::ResponseAppearance::Suggested);
        d.set_default_response(Some("restart"));
        let c2 = c.clone();
        d.connect_response(None, move |_, r| {
            if r == "restart" {
                relaunch(&c2);
            }
        });
        d.present(Some(&c.window));
    });
    app.add_action(&a);
}

/// Jalankan app lagi setelah proses ini keluar (GApplication hanya mengizinkan satu instance).
fn relaunch(ctx: &Ctx) {
    let exe = std::env::var_os("APPIMAGE").map(std::path::PathBuf::from).or_else(|| std::env::current_exe().ok());
    let Some(exe) = exe else { return };
    let spawned = std::process::Command::new("sh")
        .arg("-c")
        .arg("while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; exec \"$0\"")
        .arg(&exe)
        .arg(std::process::id().to_string())
        .spawn();
    match spawned {
        Ok(_) => {
            if let Some(app) = ctx.window.application() {
                app.quit();
            }
        }
        Err(e) => ctx.error(e),
    }
}
