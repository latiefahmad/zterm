//! Snippets: perintah favorit — jalankan ke tab aktif atau ke banyak host sekaligus.

use std::cell::RefCell;
use std::rc::Rc;

use adw::prelude::*;
use zterm_core::Snippet;
use gtk::glib;

use crate::ctx::{self, Ctx};
use crate::{icons, page, terminal};

pub fn build(ctx: &Ctx) -> gtk::Widget {
    let search = gtk::SearchEntry::builder().placeholder_text(tr!("Cari snippet…")).width_chars(18).build();
    let add = gtk::Button::builder().build();
    add.set_child(Some(&icons::content("plus", &tr!("Snippet Baru"))));
    add.add_css_class("suggested-action");
    let c = ctx.clone();
    add.connect_clicked(move |_| editor(&c, None));

    let (root, body) = page::scaffold(
        &tr!("Snippets"),
        &tr!("Perintah favorit — jalankan ke satu atau banyak host sekaligus"),
        &[search.clone().upcast(), add.upcast()],
    );
    let refresh = {
        let (c, b, s) = (ctx.clone(), body.clone(), search.clone());
        move || render(&c, &b, &s.text())
    };
    let r = refresh.clone();
    search.connect_search_changed(move |_| r());
    ctx.on_change(refresh);
    root
}

fn render(ctx: &Ctx, body: &gtk::Box, query: &str) {
    page::clear(body);
    let all = ctx.snippets();
    if all.is_empty() {
        body.append(
            &adw::StatusPage::builder()
                .icon_name(&icons::themed("brackets-curly"))
                .title(tr!("Belum ada snippet"))
                .description(tr!("Simpan perintah yang sering dipakai, misalnya cek disk atau restart service."))
                .vexpand(true)
                .build(),
        );
        return;
    }
    let q = query.to_lowercase();
    let list = gtk::ListBox::new();
    list.add_css_class("boxed-list");
    list.set_selection_mode(gtk::SelectionMode::None);
    for s in all.into_iter().filter(|s| q.is_empty() || s.label.to_lowercase().contains(&q) || s.command.to_lowercase().contains(&q)) {
        let row = adw::ActionRow::builder()
            .title(glib::markup_escape_text(&s.label))
            .subtitle(glib::markup_escape_text(&s.command))
            .build();
        row.set_subtitle_lines(3);
        row.add_css_class("property");
        row.add_prefix(&icons::image("brackets-curly", 18));

        let run_tab = icons::button("terminal-window", &tr!("Jalankan di tab aktif"));
        run_tab.set_valign(gtk::Align::Center);
        let (c, cmd) = (ctx.clone(), s.command.clone());
        run_tab.connect_clicked(move |_| match terminal::last_session(&c) {
            Some(sess) => {
                sess.send(&format!("{cmd}\n"));
                if let Some(p) = sess.page() {
                    c.tabs.set_selected_page(&p);
                }
                c.toast(&tr!("Dikirim ke tab aktif"));
            }
            None => c.toast(&tr!("Belum ada tab terminal yang terbuka")),
        });
        row.add_suffix(&run_tab);

        let run = gtk::Button::builder().tooltip_text(tr!("Jalankan di beberapa host")).valign(gtk::Align::Center).build();
        run.set_child(Some(&icons::content("play", &tr!("Jalankan"))));
        run.add_css_class("pill");
        run.add_css_class("small");
        let (c, sn) = (ctx.clone(), s.clone());
        run.connect_clicked(move |_| run_dialog(&c, &sn));
        row.add_suffix(&run);

        let edit = icons::button("pencil-simple", &tr!("Edit"));
        edit.set_valign(gtk::Align::Center);
        let (c, sn) = (ctx.clone(), s.clone());
        edit.connect_clicked(move |_| editor(&c, Some(sn.clone())));
        row.add_suffix(&edit);

        let del = icons::button("trash", &tr!("Hapus"));
        del.set_valign(gtk::Align::Center);
        let (c, id) = (ctx.clone(), s.id.clone());
        del.connect_clicked(move |_| {
            if let Some(v) = c.vault() {
                match v.delete_snippet(id.clone()) {
                    Ok(()) => c.changed(),
                    Err(e) => c.error(e),
                }
            }
        });
        row.add_suffix(&del);
        list.append(&row);
    }
    body.append(&list);
}

fn editor(ctx: &Ctx, existing: Option<Snippet>) {
    let is_new = existing.is_none();
    let s = existing.unwrap_or(Snippet { id: String::new(), label: String::new(), command: String::new(), updated_at: 0, deleted: false });
    let d = adw::AlertDialog::new(Some(&if is_new { tr!("Snippet Baru") } else { tr!("Edit Snippet") }), None);
    let b = gtk::Box::new(gtk::Orientation::Vertical, 8);
    let name = gtk::Entry::builder().placeholder_text(tr!("Nama (mis. Cek disk)")).text(&s.label).build();
    let text = gtk::TextView::builder().monospace(true).wrap_mode(gtk::WrapMode::Char).top_margin(8).bottom_margin(8).left_margin(8).right_margin(8).build();
    text.buffer().set_text(&s.command);
    let frame = gtk::Frame::new(None);
    frame.set_child(Some(&gtk::ScrolledWindow::builder().child(&text).min_content_height(110).min_content_width(360).build()));
    let hint = gtk::Label::builder().label(tr!("Contoh: df -h && free -m")).xalign(0.0).build();
    hint.add_css_class("zterm-hint");
    b.append(&name);
    b.append(&frame);
    b.append(&hint);
    d.set_extra_child(Some(&b));
    d.add_responses(&[("cancel", &tr!("Batal")), ("ok", &tr!("Simpan"))]);
    d.set_response_appearance("ok", adw::ResponseAppearance::Suggested);
    let name2 = name.clone();
    let c = ctx.clone();
    d.connect_response(None, move |_, r| {
        if r != "ok" {
            return;
        }
        let buf = text.buffer();
        let command = buf.text(&buf.start_iter(), &buf.end_iter(), false).trim().to_string();
        if command.is_empty() {
            return;
        }
        let mut sn = s.clone();
        sn.label = {
            let n = name.text().trim().to_string();
            if n.is_empty() { command.lines().next().unwrap_or("").chars().take(40).collect() } else { n }
        };
        sn.command = command;
        if let Some(v) = c.vault() {
            match v.upsert_snippet(sn) {
                Ok(_) => c.changed(),
                Err(e) => c.error(e),
            }
        }
    });
    d.present(Some(&ctx.window));
    name2.grab_focus();
}

/// Pilih host, lalu buka satu tab per host yang menjalankan snippet setelah login.
fn run_dialog(ctx: &Ctx, s: &Snippet) {
    let hosts = ctx.hosts();
    if hosts.is_empty() {
        return ctx.toast(&tr!("Belum ada host"));
    }
    let d = adw::AlertDialog::new(Some(&tr!("Jalankan “{}”", s.label)), Some(&tr!("Satu tab terminal dibuka per host.")));
    let list = gtk::ListBox::new();
    list.add_css_class("boxed-list");
    list.set_selection_mode(gtk::SelectionMode::None);
    let picked: Rc<RefCell<Vec<String>>> = Rc::new(RefCell::new(Vec::new()));
    for h in &hosts {
        let check = gtk::CheckButton::new();
        let row = adw::ActionRow::builder()
            .title(glib::markup_escape_text(&ctx::host_title(h)))
            .subtitle(glib::markup_escape_text(&ctx::host_address(h, ctx.hide_addresses.get())))
            .activatable_widget(&check)
            .build();
        row.add_prefix(&check);
        let (p, id) = (picked.clone(), h.id.clone());
        check.connect_toggled(move |c| {
            let mut v = p.borrow_mut();
            v.retain(|x| x != &id);
            if c.is_active() {
                v.push(id.clone());
            }
        });
        list.append(&row);
    }
    let scroll = gtk::ScrolledWindow::builder().child(&list).propagate_natural_height(true).max_content_height(360).min_content_width(340).build();
    d.set_extra_child(Some(&scroll));
    d.add_responses(&[("cancel", &tr!("Batal")), ("run", &tr!("Jalankan"))]);
    d.set_response_appearance("run", adw::ResponseAppearance::Suggested);
    let (c, cmd) = (ctx.clone(), s.command.clone());
    d.connect_response(None, move |_, r| {
        if r != "run" {
            return;
        }
        for id in picked.borrow().iter() {
            if let Some(h) = hosts.iter().find(|h| &h.id == id) {
                terminal::open_host(&c, h, Some(cmd.clone()));
            }
        }
    });
    d.present(Some(&ctx.window));
}
