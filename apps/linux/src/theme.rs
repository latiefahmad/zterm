//! Warna brand, CSS app, tema terminal, dan swatch warna host.

use gtk::prelude::*;
use gtk::{gdk, glib};

use crate::icons;

pub const GREEN: &str = "#4ADE80";

pub const HOST_COLORS: [&str; 16] = [
    "#3FD0B4", "#22C55E", "#84CC16", "#EAB308", "#F2A65A", "#F97316", "#F0616D", "#E11D48", "#E879C6", "#C084FC",
    "#9D7CF2", "#6366F1", "#5B9CF5", "#06B6D4", "#14B8A6", "#94A3B8",
];

const CSS: &str = r#"
@define-color accent_color #22A890;
@define-color accent_bg_color #3FD0B4;
@define-color accent_fg_color #0B0E13;

.zterm-hero { font-size: 26px; font-weight: 800; letter-spacing: -0.4px; }
.zterm-tagline { font-family: monospace; font-size: 14px; opacity: .62; }
.zterm-title { font-size: 22px; font-weight: 700; letter-spacing: -0.2px; }
.zterm-muted { opacity: .62; }
.zterm-hint { font-size: 12px; opacity: .45; }
.zterm-error { color: @error_color; font-size: 12px; }
.zterm-brand { font-weight: 800; font-size: 15px; letter-spacing: -0.2px; }

.zterm-sidebar row { border-radius: 8px; margin: 1px 6px; padding: 6px 8px; }
.zterm-sidebar row:selected { background: alpha(@accent_bg_color, .16); }

.zterm-card {
  border-radius: 12px;
  padding: 14px;
  background: alpha(@view_fg_color, .03);
  border: 1px solid alpha(@view_fg_color, .10);
  transition: background 120ms ease, border-color 120ms ease;
}
.zterm-card:hover { background: alpha(@view_fg_color, .055); border-color: alpha(@view_fg_color, .18); }
.zterm-card-title { font-weight: 600; font-size: 14px; }
.zterm-card-addr { font-family: monospace; font-size: 11.5px; opacity: .62; }
.zterm-tile-icon { color: alpha(@view_fg_color, .9); }
.zterm-chip {
  font-size: 10.5px; padding: 2px 7px; border-radius: 6px;
  background: alpha(@view_fg_color, .06);
}
.zterm-chip.online { background: alpha(#4ADE80, .12); color: #22A85A; }
.zterm-group { font-weight: 700; font-size: 11px; letter-spacing: 1.2px; opacity: .48; margin-top: 8px; }
.zterm-mono { font-family: monospace; }
.zterm-pubkey { font-family: monospace; font-size: 11px; padding: 10px; border-radius: 10px; background: alpha(@view_fg_color, .06); }
.zterm-swatch { padding: 2px; min-width: 22px; min-height: 22px; border-radius: 99px; border: 2px solid transparent; }
.zterm-swatch:checked { border-color: @view_fg_color; background: transparent; }
vte-terminal { padding: 6px 10px; }
"#;

pub fn load_css() {
    let provider = gtk::CssProvider::new();
    provider.load_from_string(CSS);
    if let Some(display) = gdk::Display::default() {
        gtk::style_context_add_provider_for_display(&display, &provider, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION);
    }
}

pub fn rgba(hex: &str) -> gdk::RGBA {
    gdk::RGBA::parse(hex).unwrap_or(gdk::RGBA::new(0.58, 0.64, 0.72, 1.0))
}

/// Kotak bulat berwarna dengan ikon di tengah (ikon kartu host).
pub fn color_tile(hex: &str, icon: &str, size: i32) -> gtk::Overlay {
    let color = rgba(hex);
    let area = gtk::DrawingArea::builder().content_width(size).content_height(size).build();
    area.set_draw_func(move |_, cr, w, h| {
        let (w, h) = (w as f64, h as f64);
        let r = (w.min(h) * 0.24).max(4.0);
        cr.new_sub_path();
        cr.arc(w - r, r, r, -std::f64::consts::FRAC_PI_2, 0.0);
        cr.arc(w - r, h - r, r, 0.0, std::f64::consts::FRAC_PI_2);
        cr.arc(r, h - r, r, std::f64::consts::FRAC_PI_2, std::f64::consts::PI);
        cr.arc(r, r, r, std::f64::consts::PI, 1.5 * std::f64::consts::PI);
        cr.close_path();
        cr.set_source_rgba(color.red() as f64, color.green() as f64, color.blue() as f64, 0.14);
        let _ = cr.fill_preserve();
        cr.set_source_rgba(color.red() as f64, color.green() as f64, color.blue() as f64, 0.38);
        cr.set_line_width(1.0);
        let _ = cr.stroke();
    });
    let overlay = gtk::Overlay::new();
    overlay.set_child(Some(&area));
    let img = icons::image(icon, size / 2);
    img.add_css_class("zterm-tile-icon");
    overlay.add_overlay(&img);
    overlay.set_valign(gtk::Align::Center);
    overlay
}

/// Lingkaran warna penuh (pemilih warna host).
pub fn dot(hex: &str, size: i32) -> gtk::DrawingArea {
    let color = rgba(hex);
    let area = gtk::DrawingArea::builder().content_width(size).content_height(size).build();
    area.set_draw_func(move |_, cr, w, h| {
        let r = (w.min(h) as f64) / 2.0;
        cr.arc(w as f64 / 2.0, h as f64 / 2.0, r, 0.0, 2.0 * std::f64::consts::PI);
        cr.set_source_rgba(color.red() as f64, color.green() as f64, color.blue() as f64, 1.0);
        let _ = cr.fill();
    });
    area
}

/// Logo app (PNG ikut dalam binary).
pub fn logo(size: i32) -> gtk::Image {
    let bytes = glib::Bytes::from_static(include_bytes!("../data/icons/com.latiefahmad.zterm.png"));
    let img = match gdk::Texture::from_bytes(&bytes) {
        Ok(t) => gtk::Image::from_paintable(Some(&t)),
        Err(_) => icons::image("terminal-window", 24),
    };
    img.set_pixel_size(size);
    img
}

// ---- Tema terminal (sama dengan versi Mac) ----

pub struct TermTheme {
    pub id: &'static str,
    pub name: &'static str,
    pub bg: &'static str,
    pub fg: &'static str,
    pub accent: &'static str,
    pub ansi: [&'static str; 16],
}

pub const TERM_THEMES: [TermTheme; 7] = [
    TermTheme { id: "zterm", name: "Zterm Night", bg: "#0B0E13", fg: "#E6EDF3", accent: "#3FD0B4",
        ansi: ["#1B212A", "#F0616D", "#8BD450", "#F2C55A", "#5B9CF5", "#B48CF2", "#3FD0B4", "#C9D1D9",
               "#4B5563", "#FF7B86", "#A6E36E", "#FFD77A", "#7DB3FF", "#CBA6FF", "#6EE7CF", "#FFFFFF"] },
    TermTheme { id: "ocean", name: "Deep Ocean", bg: "#0A1628", fg: "#D6E4F5", accent: "#5B9CF5",
        ansi: ["#14243B", "#F07178", "#9ADE7B", "#FFCB6B", "#5B9CF5", "#C792EA", "#4FD6E8", "#C3D3E8",
               "#3B4E6B", "#FF8B92", "#B5F09A", "#FFDB8E", "#82B6FF", "#DDB3FF", "#7DE8F5", "#FFFFFF"] },
    TermTheme { id: "violet", name: "Violet Dusk", bg: "#14101F", fg: "#E9E2F7", accent: "#9D7CF2",
        ansi: ["#221B33", "#FF6B8B", "#7EE0A2", "#F5D07A", "#7A9CFF", "#C49BFF", "#6FD9E0", "#D9D0EC",
               "#4A4063", "#FF8FA8", "#9FF0BC", "#FFE19C", "#9DB6FF", "#DCBDFF", "#93EBF0", "#FFFFFF"] },
    TermTheme { id: "forest", name: "Forest Mist", bg: "#0E1612", fg: "#DCEADF", accent: "#7FD18B",
        ansi: ["#1A2620", "#E5786D", "#7FD18B", "#E3C76A", "#6FA8DC", "#C59AD9", "#6CCFBF", "#C8D8CC",
               "#3E5247", "#F2958B", "#A0E3A9", "#F0DA8E", "#93C1E8", "#D8B6E6", "#8FE0D3", "#FFFFFF"] },
    TermTheme { id: "ember", name: "Ember", bg: "#17110E", fg: "#F2E6DC", accent: "#F2A65A",
        ansi: ["#271D18", "#F0616D", "#B6D46B", "#F2A65A", "#7BA7E0", "#D88AC0", "#68C6B8", "#E0D2C5",
               "#544036", "#FF8590", "#CBE68C", "#FFC07E", "#9CC0F0", "#EBA6D4", "#8ADBCE", "#FFFFFF"] },
    TermTheme { id: "paper", name: "Paper Light", bg: "#F7F6F2", fg: "#24262B", accent: "#0F9D84",
        ansi: ["#24262B", "#C8323F", "#3C8A2E", "#A86E00", "#2462C4", "#8A3FC0", "#0F8C80", "#C7C4BC",
               "#6B6E75", "#E04452", "#4FA63F", "#C48612", "#3A7BE0", "#A257D9", "#18A898", "#F7F6F2"] },
    TermTheme { id: "sand", name: "Sand", bg: "#F3EDE2", fg: "#3A3226", accent: "#C46F2E",
        ansi: ["#3A3226", "#B83A3A", "#5E8A2E", "#B07A12", "#3567A8", "#8E4C9E", "#2F8A86", "#CFC6B6",
               "#7A6F5E", "#D14F4F", "#73A33C", "#CC921F", "#4A80C4", "#A865B8", "#3BA39E", "#F3EDE2"] },
];

/// Tanpa pilihan tema: ikut mode app (gelap → Zterm Night, terang → Paper Light).
pub fn term_theme(id: Option<&str>) -> &'static TermTheme {
    if let Some(t) = TERM_THEMES.iter().find(|t| Some(t.id) == id) {
        return t;
    }
    if adw::StyleManager::default().is_dark() { &TERM_THEMES[0] } else { &TERM_THEMES[5] }
}

pub fn apply_term_theme(term: &vte::Terminal, id: Option<&str>) {
    use vte::prelude::*;
    let t = term_theme(id);
    let palette: Vec<gdk::RGBA> = t.ansi.iter().map(|c| rgba(c)).collect();
    let refs: Vec<&gdk::RGBA> = palette.iter().collect();
    term.set_colors(Some(&rgba(t.fg)), Some(&rgba(t.bg)), &refs);
    term.set_color_cursor(Some(&rgba(t.accent)));
    let mut sel = rgba(t.accent);
    sel.set_alpha(0.35);
    term.set_color_highlight(Some(&sel));
}
