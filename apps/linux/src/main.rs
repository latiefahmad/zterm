//! Zterm untuk Linux — GTK4 + libadwaita + VTE, memakai zterm-core langsung.

#[macro_use]
mod i18n;
mod about;
mod config;
mod ctx;
mod editor;
mod hosts;
mod icons;
mod keychain;
mod onboarding;
mod page;
mod snippets;
mod terminal;
mod theme;
mod window;

use adw::prelude::*;
use zterm_core::{HostProxy, ProxyKind};

fn main() -> gtk::glib::ExitCode {
    let args: Vec<String> = std::env::args().collect();

    // Mode ProxyCommand: `ssh -o ProxyCommand="<app> --zterm-proxy <socks5|http> <proxy-host> <proxy-port> %h %p"`.
    // Proses ini hanya menyalurkan stdin/stdout ke server lewat proxy, tanpa membuka UI.
    if args.len() >= 7 && args[1] == "--zterm-proxy" {
        let proxy = HostProxy {
            kind: if args[2] == "http" { ProxyKind::Http } else { ProxyKind::Socks5 },
            host: args[3].clone(),
            port: args[4].parse().unwrap_or(1080),
            username: std::env::var("ZTERM_PROXY_USER").ok(),
            password: std::env::var("ZTERM_PROXY_PASS").ok(),
        };
        return match zterm_core::proxy_stdio(proxy, args[5].clone(), args[6].parse().unwrap_or(22)) {
            Ok(()) => gtk::glib::ExitCode::SUCCESS,
            Err(e) => {
                eprintln!("Zterm: {e}");
                gtk::glib::ExitCode::FAILURE
            }
        };
    }
    if args.get(1).map(String::as_str) == Some("--version") {
        println!("Zterm {} (core {})", env!("CARGO_PKG_VERSION"), zterm_core::core_version());
        return gtk::glib::ExitCode::SUCCESS;
    }

    // AppImage: hook linuxdeploy-plugin-gtk memaksa GTK_THEME=Adwaita, yang menimpa gaya libadwaita.
    if std::env::var_os("APPIMAGE").is_some() {
        // SAFETY: masih satu thread, sebelum GTK dimulai.
        unsafe { std::env::remove_var("GTK_THEME") };
    }

    let app = adw::Application::builder().application_id(config::APP_ID).build();
    app.connect_startup(|_| {
        gtk::Window::set_default_icon_name(config::APP_ID);
        theme::load_css();
    });
    app.connect_activate(|app| {
        if let Some(w) = app.active_window() {
            w.present();
        } else {
            window::build(app);
        }
    });
    app.run_with_args(&args[..1])
}
