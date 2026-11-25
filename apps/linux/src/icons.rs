//! Ikon Phosphor Duotone: SVG simbolik di tema ikon `zterm-<nama>-symbolic`.
//!
//! GTK mewarnai ulang ikon `-symbolic` mengikuti `color` CSS, termasuk
//! lapisan duotone yang dibuat dengan opacity 0.2.

use std::path::PathBuf;

use adw::prelude::*;

/// Nama ikon tema untuk Phosphor `name`.
pub fn themed(name: &str) -> String {
    format!("zterm-{name}-symbolic")
}

/// Gambar ikon pada ukuran tertentu (px).
pub fn image(name: &str, size: i32) -> gtk::Image {
    let img = gtk::Image::from_icon_name(&themed(name));
    img.set_pixel_size(size);
    img
}

/// Tombol ikon datar dengan ukuran seragam.
pub fn button(name: &str, tooltip: &str) -> gtk::Button {
    let b = gtk::Button::builder().tooltip_text(tooltip).build();
    b.set_child(Some(&image(name, 18)));
    b.add_css_class("flat");
    b
}

/// MenuButton ikon datar.
pub fn menu_button(name: &str, tooltip: &str) -> gtk::MenuButton {
    let b = gtk::MenuButton::builder().tooltip_text(tooltip).build();
    b.set_child(Some(&image(name, 18)));
    b.add_css_class("flat");
    b.add_css_class("circular");
    b
}

/// Isi tombol libadwaita: ikon + label.
pub fn content(name: &str, label: &str) -> adw::ButtonContent {
    adw::ButtonContent::builder().icon_name(&themed(name)).label(label).build()
}

/// Daftarkan folder ikon saat berjalan langsung dari repo atau AppImage.
/// Di Flatpak ikon sudah ada di `/app/share/icons` (jalur bawaan GTK).
pub fn install() {
    let Some(display) = gtk::gdk::Display::default() else { return };
    let theme = gtk::IconTheme::for_display(&display);
    for dir in search_dirs() {
        if dir.is_dir() {
            theme.add_search_path(&dir);
        }
    }
}

fn search_dirs() -> Vec<PathBuf> {
    let mut dirs = Vec::new();
    // `cargo run` dan `cargo build --release` langsung dari repo.
    dirs.push(PathBuf::from(concat!(env!("CARGO_MANIFEST_DIR"), "/data/icons")));
    if let Some(appdir) = std::env::var_os("APPDIR") {
        dirs.push(PathBuf::from(appdir).join("usr/share/icons"));
    }
    if let Ok(exe) = std::env::current_exe() {
        if let Some(usr) = exe.parent().and_then(|p| p.parent()) {
            dirs.push(usr.join("share/icons"));
        }
    }
    dirs
}
