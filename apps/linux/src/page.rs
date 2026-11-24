//! Kerangka halaman sidebar: judul, deskripsi, tombol di kanan, lalu isi yang bisa di-scroll.

use gtk::prelude::*;

pub fn scaffold(title: &str, subtitle: &str, actions: &[gtk::Widget]) -> (gtk::Widget, gtk::Box) {
    let root = gtk::Box::new(gtk::Orientation::Vertical, 0);
    let header = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    header.set_margin_top(20);
    header.set_margin_start(24);
    header.set_margin_end(24);
    header.set_margin_bottom(12);
    let titles = gtk::Box::new(gtk::Orientation::Vertical, 2);
    titles.set_hexpand(true);
    let t = gtk::Label::builder().label(title).xalign(0.0).build();
    t.add_css_class("zterm-title");
    let s = gtk::Label::builder().label(subtitle).xalign(0.0).wrap(true).build();
    s.add_css_class("zterm-muted");
    titles.append(&t);
    titles.append(&s);
    header.append(&titles);
    for a in actions {
        a.set_valign(gtk::Align::Center);
        header.append(a);
    }
    root.append(&header);

    let body = gtk::Box::new(gtk::Orientation::Vertical, 12);
    body.set_margin_start(24);
    body.set_margin_end(24);
    body.set_margin_bottom(24);
    let clamp = adw::Clamp::builder().maximum_size(900).tightening_threshold(600).child(&body).build();
    let scroll = gtk::ScrolledWindow::builder().vexpand(true).hscrollbar_policy(gtk::PolicyType::Never).child(&clamp).build();
    root.append(&scroll);
    (root.upcast(), body)
}

pub fn clear(b: &gtk::Box) {
    while let Some(c) = b.first_child() {
        b.remove(&c);
    }
}
