//! Keychain: generate, import, salin public key, ganti nama, dan hapus SSH key.

use adw::prelude::*;
use zterm_core::SshKey;
use gtk::{gio, glib};

use crate::ctx::{self, Ctx};
use crate::{icons, page};

pub fn build(ctx: &Ctx) -> gtk::Widget {
    let import = gtk::Button::builder().build();
    import.set_child(Some(&icons::content("folder-open", &tr!("Import"))));
    let c = ctx.clone();
    import.connect_clicked(move |_| import_dialog(&c));
    let generate = gtk::Button::builder().build();
    generate.set_child(Some(&icons::content("plus", &tr!("Generate Key"))));
    generate.add_css_class("suggested-action");
    let c = ctx.clone();
    generate.connect_clicked(move |_| generate_dialog(&c));

    let (root, body) = page::scaffold(
        &tr!("Keychain"),
        &tr!("SSH key tersimpan terenkripsi di vault. Pakai di host lewat Credentials → SSH Key."),
        &[import.upcast(), generate.upcast()],
    );

    let c = ctx.clone();
    let b = body.clone();
    ctx.on_change(move || render(&c, &b));
    root
}

fn render(ctx: &Ctx, body: &gtk::Box) {
    page::clear(body);
    let keys = ctx.keys();
    if keys.is_empty() {
        body.append(
            &adw::StatusPage::builder()
                .icon_name(&icons::themed("key"))
                .title(tr!("Belum ada SSH key"))
                .description(tr!("Generate key Ed25519 baru atau import dari ~/.ssh."))
                .vexpand(true)
                .build(),
        );
        return;
    }
    let hosts = ctx.hosts();
    let list = gtk::ListBox::new();
    list.add_css_class("boxed-list");
    list.set_selection_mode(gtk::SelectionMode::None);
    for k in keys {
        let used = hosts.iter().filter(|h| h.key_id.as_deref() == Some(k.id.as_str())).count();
        let usage = if used == 0 { tr!("Belum dipakai") } else { tr!("Dipakai {} host", used) };
        let row = adw::ActionRow::builder()
            .title(glib::markup_escape_text(&k.label))
            .subtitle(glib::markup_escape_text(&format!("{} · {} · {usage}", k.key_type, k.fingerprint)))
            .build();
        row.set_subtitle_lines(2);
        let icon = icons::image(if k.passphrase.is_some() { "lock-key" } else { "key" }, 18);
        row.add_prefix(&icon);

        let copy = icons::button("copy", &tr!("Salin public key"));
        copy.set_valign(gtk::Align::Center);
        let (c, pubkey) = (ctx.clone(), k.public_key.clone());
        copy.connect_clicked(move |_| {
            ctx::copy_text(&pubkey);
            c.toast(&tr!("Public key disalin"));
        });
        row.add_suffix(&copy);

        let rename = icons::button("pencil-simple", &tr!("Ganti nama"));
        rename.set_valign(gtk::Align::Center);
        let (c, key) = (ctx.clone(), k.clone());
        rename.connect_clicked(move |_| rename_dialog(&c, &key));
        row.add_suffix(&rename);

        let del = icons::button("trash", &tr!("Hapus"));
        del.set_valign(gtk::Align::Center);
        let (c, key) = (ctx.clone(), k.clone());
        del.connect_clicked(move |_| delete_dialog(&c, &key, used));
        row.add_suffix(&del);
        list.append(&row);
    }
    body.append(&list);
}

fn delete_dialog(ctx: &Ctx, k: &SshKey, used: usize) {
    let body = if used > 0 {
        tr!("{} host yang memakai key ini akan kehilangan key-nya.", used)
    } else {
        tr!("Tindakan ini tidak bisa dibatalkan.")
    };
    let d = adw::AlertDialog::new(Some(&tr!("Hapus key “{}”?", k.label)), Some(&body));
    d.add_responses(&[("cancel", &tr!("Batal")), ("delete", &tr!("Hapus"))]);
    d.set_response_appearance("delete", adw::ResponseAppearance::Destructive);
    let (c, id) = (ctx.clone(), k.id.clone());
    d.connect_response(None, move |_, r| {
        if r == "delete" {
            if let Some(v) = c.vault() {
                match v.delete_key(id.clone()) {
                    Ok(()) => c.changed(),
                    Err(e) => c.error(e),
                }
            }
        }
    });
    d.present(Some(&ctx.window));
}

fn rename_dialog(ctx: &Ctx, k: &SshKey) {
    let d = adw::AlertDialog::new(Some(&tr!("Ganti nama")), None);
    let e = gtk::Entry::builder().text(&k.label).activates_default(true).build();
    let e2 = e.clone();
    d.set_extra_child(Some(&e));
    d.add_responses(&[("cancel", &tr!("Batal")), ("ok", &tr!("Simpan"))]);
    d.set_response_appearance("ok", adw::ResponseAppearance::Suggested);
    d.set_default_response(Some("ok"));
    let (c, id) = (ctx.clone(), k.id.clone());
    d.connect_response(None, move |_, r| {
        let name = e.text().trim().to_string();
        if r == "ok" && !name.is_empty() {
            if let Some(v) = c.vault() {
                match v.rename_key(id.clone(), name) {
                    Ok(()) => c.changed(),
                    Err(e) => c.error(e),
                }
            }
        }
    });
    d.present(Some(&ctx.window));
    e2.grab_focus();
}

fn generate_dialog(ctx: &Ctx) {
    let d = adw::AlertDialog::new(
        Some(&tr!("Generate SSH key")),
        Some(&tr!("Membuat pasangan key Ed25519 baru — cepat, aman, dan didukung semua server modern.")),
    );
    let e = gtk::Entry::builder().placeholder_text(tr!("Label (mis. Laptop kantor)")).activates_default(true).build();
    let e2 = e.clone();
    d.set_extra_child(Some(&e));
    d.add_responses(&[("cancel", &tr!("Batal")), ("ok", &tr!("Generate"))]);
    d.set_response_appearance("ok", adw::ResponseAppearance::Suggested);
    d.set_default_response(Some("ok"));
    let c = ctx.clone();
    d.connect_response(None, move |_, r| {
        if r != "ok" {
            return;
        }
        let label = e.text().trim().to_string();
        let label = if label.is_empty() { "Zterm".to_string() } else { label };
        let Some(v) = c.vault() else { return };
        match v.generate_key(label) {
            Ok(k) => {
                c.changed();
                show_public_key(&c, &k);
            }
            Err(err) => c.toast(&tr!("Gagal membuat key: {}", crate::i18n::msg(&err.to_string()))),
        }
    });
    d.present(Some(&ctx.window));
    e2.grab_focus();
}

fn show_public_key(ctx: &Ctx, k: &SshKey) {
    let d = adw::AlertDialog::new(
        Some(&tr!("Key berhasil dibuat")),
        Some(&tr!("Tambahkan public key ini ke ~/.ssh/authorized_keys di server.")),
    );
    let l = gtk::Label::builder().label(&k.public_key).wrap(true).wrap_mode(gtk::pango::WrapMode::Char).selectable(true).xalign(0.0).build();
    l.add_css_class("zterm-pubkey");
    d.set_extra_child(Some(&l));
    d.add_responses(&[("close", &tr!("Tutup")), ("copy", &tr!("Salin & tutup"))]);
    d.set_response_appearance("copy", adw::ResponseAppearance::Suggested);
    d.set_default_response(Some("copy"));
    let (c, pubkey) = (ctx.clone(), k.public_key.clone());
    d.connect_response(None, move |_, r| {
        if r == "copy" {
            ctx::copy_text(&pubkey);
            c.toast(&tr!("Public key disalin"));
        }
    });
    d.present(Some(&ctx.window));
}

fn import_dialog(ctx: &Ctx) {
    let dialog = adw::Dialog::builder().title(tr!("Import SSH key")).content_width(520).content_height(560).build();
    let page = adw::PreferencesPage::new();
    let group = adw::PreferencesGroup::builder()
        .description(tr!("Pilih file private key (mis. ~/.ssh/id_ed25519) atau tempel isinya. Format OpenSSH."))
        .build();
    let label = adw::EntryRow::builder().title(tr!("Label")).build();
    let pass = adw::PasswordEntryRow::builder().title(tr!("Passphrase (jika ada)")).build();
    group.add(&label);
    group.add(&pass);
    page.add(&group);

    let g2 = adw::PreferencesGroup::builder().title(tr!("Private key")).build();
    let text = gtk::TextView::builder().monospace(true).wrap_mode(gtk::WrapMode::Char).top_margin(10).bottom_margin(10).left_margin(10).right_margin(10).build();
    text.buffer().set_text("");
    let frame = gtk::Frame::new(None);
    let scroll = gtk::ScrolledWindow::builder().child(&text).min_content_height(180).build();
    frame.set_child(Some(&scroll));
    g2.add(&frame);
    let pick = gtk::Button::builder().halign(gtk::Align::Start).margin_top(8).build();
    pick.set_child(Some(&icons::content("folder-open", &tr!("Pilih file…"))));
    g2.add(&pick);
    page.add(&g2);

    {
        let (ctx, text, label) = (ctx.clone(), text.clone(), label.clone());
        pick.connect_clicked(move |_| {
            let fd = gtk::FileDialog::builder().title(tr!("Pilih private key (bukan file .pub)")).modal(true).build();
            let ssh_dir = gio::File::for_path(crate::config::home().join(".ssh"));
            fd.set_initial_folder(Some(&ssh_dir));
            let (text, label) = (text.clone(), label.clone());
            fd.open(Some(&ctx.window), gio::Cancellable::NONE, move |res| {
                let Ok(file) = res else { return };
                if let Some(path) = file.path() {
                    match std::fs::read_to_string(&path) {
                        Ok(s) => {
                            text.buffer().set_text(&s);
                            if label.text().is_empty() {
                                if let Some(n) = path.file_name() {
                                    label.set_text(&n.to_string_lossy());
                                }
                            }
                        }
                        Err(e) => text.buffer().set_text(&format!("# {e}")),
                    }
                }
            });
        });
    }

    let header = adw::HeaderBar::new();
    let ok = gtk::Button::with_label(&tr!("Import"));
    ok.add_css_class("suggested-action");
    header.pack_end(&ok);
    {
        let (ctx, dialog) = (ctx.clone(), dialog.clone());
        ok.connect_clicked(move |_| {
            let buf = text.buffer();
            let pem = buf.text(&buf.start_iter(), &buf.end_iter(), false).to_string();
            if pem.trim().is_empty() {
                return ctx.toast(&tr!("Tempel private key atau pilih file dulu"));
            }
            let l = label.text().trim().to_string();
            let l = if l.is_empty() { "Key".to_string() } else { l };
            let pp = pass.text().to_string();
            let Some(v) = ctx.vault() else { return };
            match v.import_key(l.clone(), pem, if pp.is_empty() { None } else { Some(pp) }) {
                Ok(_) => {
                    dialog.close();
                    ctx.toast(&tr!("Key “{}” diimport", l));
                    ctx.changed();
                }
                Err(e) => ctx.error(e),
            }
        });
    }

    let view = adw::ToolbarView::new();
    view.add_top_bar(&header);
    view.set_content(Some(&page));
    dialog.set_child(Some(&view));
    dialog.present(Some(&ctx.window));
}
