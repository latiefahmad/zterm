/* Zterm field manual: language, theme, install tabs, and release data. */

(function () {
  "use strict";

  var EN = {
    "skip": "Skip to content",
    "brand.edition": "Field manual",
    "nav.aria": "Main navigation",
    "nav.mobile.aria": "Mobile navigation",
    "lang.aria": "Language",
    "nav.toc": "Contents",
    "nav.features": "Features",
    "nav.security": "Security",
    "nav.install": "Install",
    "nav.faq": "FAQ",
    "nav.menu": "Menu",
    "header.github": "GitHub",

    "hero.kicker.edition": "Edition 1.0.1",
    "hero.kicker.date": "November 2026",
    "hero.title": "All your servers,<br /><em>one terminal.</em>",
    "hero.lead": "A native SSH client for macOS, Windows, and Linux. Hosts, terminal, SFTP, Docker, databases, and backups in one app. Zterm uses no account and no relay server.",
    "hero.download": "Download Zterm",
    "hero.secondary": "See the feature index",
    "hero.meta": "macOS 15+ / Windows 10 and 11 / Linux beta / MIT",
    "hero.plate.label": "Plate 01",
    "hero.plate.title": "Hosts + terminal",
    "hero.sketch.aria": "Zterm interface illustration: host list and SSH terminal",
    "hero.caption": "Interface illustration. The data shown is sample data, not a screenshot.",

    "facts.aria": "Product summary",
    "facts.platform.k": "Platform",
    "facts.platform.v": "macOS, Windows, Linux",
    "facts.account.k": "Zterm account",
    "facts.account.v": "Not required",
    "facts.enc.k": "Encryption",
    "facts.license.k": "License",
    "facts.lang.k": "Language",
    "facts.lang.v": "Indonesian, English",

    "toc.label": "Contents",
    "toc.title": "Eight chapters, one app.",
    "toc.deck": "These chapters follow work that usually lives in several apps, from the host list to installation.",
    "toc.01.title": "Hosts and terminal",
    "toc.01.note": "Server list, authentication, local terminal, tunnels, keys, and snippets.",
    "toc.02.title": "Dashboard and operations",
    "toc.02.note": "CPU, RAM, disk, processes, services, cron, and logs on one screen.",
    "toc.03.title": "Databases and backups",
    "toc.03.note": "23 engines, per-column search, SQL, scheduled dumps, and restore.",
    "toc.04.title": "SFTP and editor",
    "toc.04.note": "Two file panes, parallel transfers, built-in editor, and open with local apps.",
    "toc.05.title": "Docker and local server",
    "toc.05.note": "Containers per Compose project, plus Apache, PHP, MySQL, PostgreSQL, and MongoDB on your computer.",
    "toc.06.title": "Teams and sync",
    "toc.06.note": "Share encrypted hosts, invite by email, and sync through Google Drive.",
    "toc.07.title": "Security",
    "toc.07.note": "Argon2id, XChaCha20-Poly1305, Touch ID, Windows Hello, and open source.",
    "toc.08.title": "Install",
    "toc.08.note": "DMG, Setup.exe, or AppImage. First steps and release notes.",

    "ch01.label": "Chapter 01",
    "ch01.name": "Hosts",
    "ch01.title": "Every server, one list.",
    "ch01.deck": "Hosts are grouped, with status and last connection time. Select several hosts, then open one tab for each.",
    "ch01.p1": "Double-click to connect, or select several hosts and run Connect all. Authentication can use a password, SSH key, or SSH agent. Jump hosts, SOCKS5/HTTP proxies, agent forwarding, startup snippets, and env vars are set per host.",
    "ch01.p2": "The local terminal runs in the same tab: zsh on Mac, PowerShell, CMD, or WSL on Windows. Terminal themes can be changed, and server addresses can be masked during screen sharing.",
    "ch01.auth.k": "Authentication",
    "ch01.auth.v": "Password, SSH key, or SSH agent",
    "ch01.adv.k": "Advanced",
    "ch01.adv.v": "Jump host, SOCKS5/HTTP proxy, agent forwarding, startup snippet, env vars",
    "ch01.local.k": "Local terminal",
    "ch01.local.v": "zsh on Mac; PowerShell, CMD, or WSL on Windows",
    "ch01.key.k": "Keychain",
    "ch01.key.v": "Ed25519, OpenSSH RSA/ECDSA import, SHA256 fingerprint",
    "ch01.tunnel.k": "Tunnels",
    "ch01.tunnel.v": "Local, remote, and SOCKS; status per tunnel",
    "ch01.snippet.k": "Snippets",
    "ch01.snippet.v": "Save commands, run them on many hosts or in the active tab",
    "ch01.look.k": "Appearance",
    "ch01.look.v": "7 terminal themes, card colors, light and dark mode",
    "ch01.privacy.k": "Privacy",
    "ch01.privacy.v": "Server addresses masked during screen sharing",
    "ch01.plate.label": "Plate 02",
    "ch01.plate.title": "Host editor",
    "ch01.aria": "Zterm host editor illustration",
    "ch01.caption": "Interface illustration. The data shown is sample data.",

    "ch02.label": "Chapter 02",
    "ch02.name": "Dashboard",
    "ch02.title": "Watch and manage without switching apps.",
    "ch02.deck": "CPU, RAM, disk, uptime, and network for each server refresh every 5 seconds. Processes, services, cron, and logs live on the same screen.",
    "ch02.p1": "Servers that are nearly full or down are marked, with desktop notifications. You can run one command on many servers in parallel and see the exit code, output, and duration per server.",
    "ch02.p2": "The Server info panel shows specs and CPU, RAM, and network charts every 3 seconds. No agent needs to be installed on the server.",
    "ch02.monitor.k": "Monitor",
    "ch02.monitor.v": "CPU, RAM, disk, load, uptime, network",
    "ch02.alert.k": "Alerts",
    "ch02.alert.v": "75% and 90%; offline servers are retried",
    "ch02.proc.k": "Processes",
    "ch02.proc.v": "Sort by CPU/memory, search, stop, kill -9",
    "ch02.service.k": "Services",
    "ch02.service.v": "Start, stop, restart, reload, enable at boot",
    "ch02.cron.k": "Cron",
    "ch02.cron.v": "Schedule presets, not only cron expressions",
    "ch02.log.k": "Logs",
    "ch02.log.v": "journalctl per service and log files, filter, follow",
    "ch02.run.k": "Execution",
    "ch02.run.v": "One command on many servers in parallel",
    "ch02.info.k": "Server info",
    "ch02.info.v": "OS, kernel, CPU, cores, uptime, load",
    "ch02.plate.label": "Plate 03",
    "ch02.plate.title": "Dashboard + services",
    "ch02.aria": "Zterm server dashboard illustration with CPU, RAM, and disk charts",
    "ch02.caption": "Interface illustration. The data shown is sample data.",

    "ch03.label": "Chapter 03",
    "ch03.name": "Databases",
    "ch03.title": "Databases and backups on one screen.",
    "ch03.deck": "Browse tables, search per column, run SQL, then schedule a dump without opening a browser.",
    "ch03.p1": "MySQL, MariaDB, PostgreSQL, SQL Server, SQLite, Redis, MongoDB, ClickHouse, and 15 other services. Connect directly, with TLS, through an SSH tunnel, or through a proxy.",
    "ch03.p2": "Backups run over SSH: the dump runs on the server and the result is stored compressed on your computer. Schedule daily or weekly runs, keep the last N backups, and restore from the list.",
    "ch03.engine.k": "Engines",
    "ch03.engine.v": "23 presets, including RDS, Supabase, Neon, PlanetScale, TiDB, Atlas, Upstash",
    "ch03.search.k": "Search",
    "ch03.search.v": "=, LIKE %...%, IN, BETWEEN, IS NULL",
    "ch03.tabs.k": "Tabs",
    "ch03.tabs.v": "Overview, Browse, Structure, Search, SQL",
    "ch03.export.k": "Export",
    "ch03.export.v": "Save results as CSV",
    "ch03.sql.k": "SQL",
    "ch03.sql.v": "Query history, Cmd/Ctrl+Enter to run",
    "ch03.backup.k": "Backup",
    "ch03.backup.v": "MySQL, MariaDB, PostgreSQL, MongoDB, SQLite",
    "ch03.schedule.k": "Schedule",
    "ch03.schedule.v": "Daily or weekly, keep the last N backups",
    "ch03.restore.k": "Restore",
    "ch03.restore.v": "Confirmation, progress, and a cancel button",
    "ch03.drive.k": "Drive",
    "ch03.drive.v": "Optional, to the Zterm Backups folder",
    "ch03.plate.label": "Plate 04",
    "ch03.plate.title": "Database + backup",
    "ch03.aria": "Zterm database illustration with a table, search, and backups",
    "ch03.caption": "Interface illustration. The data shown is sample data.",

    "ch04.label": "Chapter 04",
    "ch04.name": "SFTP",
    "ch04.title": "Server files, two panes.",
    "ch04.deck": "Your computer on the left, the server on the right. Drag files or folders, then watch progress and speed per transfer.",
    "ch04.p1": "Uploads and downloads run in parallel. New folders, rename, delete, and chmod are available from the same panel. Server fingerprints are checked against known_hosts.",
    "ch04.p2": "Double-click a text file to open the built-in editor: line numbers, search, and save with Cmd/Ctrl+S. If the file changes on the server before you save, Zterm warns you. Files can also open in VS Code, Sublime, Notepad++, or another app, then upload automatically every time you save.",
    "ch04.transfer.k": "Transfers",
    "ch04.transfer.v": "Files and folders, in parallel",
    "ch04.manage.k": "Manage",
    "ch04.manage.v": "New folder, rename, delete, chmod",
    "ch04.editor.k": "Editor",
    "ch04.editor.v": "Configs, scripts, .env, logs; CRLF/LF preserved",
    "ch04.open.k": "Open with",
    "ch04.open.v": "VS Code, Sublime, Notepad++, Preview",
    "ch04.autosave.k": "Auto-save",
    "ch04.autosave.v": "Upload every time the local app saves",
    "ch04.security.k": "Security",
    "ch04.security.v": "known_hosts fingerprint",
    "ch04.path.k": "Path",
    "ch04.path.v": "Breadcrumb or type directly",
    "ch04.plate.label": "Plate 05",
    "ch04.plate.title": "SFTP + editor",
    "ch04.aria": "Zterm two-pane SFTP and file editor illustration",
    "ch04.caption": "Interface illustration. The data shown is sample data.",

    "ch05.label": "Chapter 05",
    "ch05.name": "Docker",
    "ch05.title": "Docker and local server, one control.",
    "ch05.deck": "Containers on any server over SSH, plus Apache, PHP, and databases on your computer.",
    "ch05.p1": "Containers are grouped by Compose project. The detail panel shows live CPU and RAM, clickable ports, env, mounts, networks, and logs. One click opens a terminal inside a container. Compose can be up, restarted, stopped, or down per project.",
    "ch05.p2": "The local server runs Apache or Nginx with PHP 8.4, plus MySQL 8.4, PostgreSQL 17, and MongoDB 8. Components download on first use. Ports are configurable, listen only on 127.0.0.1, and everything stops when the app closes.",
    "ch05.container.k": "Containers",
    "ch05.container.v": "Start, stop, restart, remove",
    "ch05.detail.k": "Details",
    "ch05.detail.v": "CPU/RAM, ports, env, mounts, networks, logs",
    "ch05.shell.k": "Shell",
    "ch05.shell.v": "Terminal inside a container",
    "ch05.compose.k": "Compose",
    "ch05.compose.v": "Up, restart, stop, down; clean up images and volumes",
    "ch05.web.k": "Local web",
    "ch05.web.v": "Apache or Nginx + PHP 8.4",
    "ch05.db.k": "Local database",
    "ch05.db.v": "MySQL 8.4, PostgreSQL 17, MongoDB 8",
    "ch05.net.k": "Network",
    "ch05.net.v": "Configurable ports, 127.0.0.1 only",
    "ch05.download.k": "Download",
    "ch05.download.v": "Only the components you use; macOS's built-in Apache can be used",
    "ch05.plate.label": "Plate 06",
    "ch05.plate.title": "Docker + local server",
    "ch05.aria": "Zterm Docker and local server illustration",
    "ch05.caption": "Interface illustration. The data shown is sample data.",

    "ch06.label": "Chapter 06",
    "ch06.name": "Teams",
    "ch06.title": "One team, one host list.",
    "ch06.deck": "An admin shares encrypted hosts by email. Members click Join team, and the hosts appear in their Zterm.",
    "ch06.p1": "Hosts, passwords, and SSH keys are end-to-end encrypted with a team key held only by members. Google stores ciphertext and invited email addresses. When the admin edits a host, every member updates. When a member is removed, access is revoked and the team key is rotated.",
    "ch06.p2": "The vault syncs to your Google Drive appdata folder. Sign in on another Mac or PC, enter the master password, and the host list returns.",
    "ch06.invite.k": "Invite",
    "ch06.invite.v": "By Google email; no Zterm account",
    "ch06.encrypt.k": "Encryption",
    "ch06.encrypt.v": "Hosts, passwords, SSH keys; team key held only by members",
    "ch06.sync.k": "Sync",
    "ch06.sync.v": "Google Drive appdata, automatic after changes",
    "ch06.devices.k": "Devices",
    "ch06.devices.v": "Mac and Windows share one vault; Linux beta covers hosts, terminal, keychain, snippets",
    "ch06.remove.k": "Remove",
    "ch06.remove.v": "Access revoked, team key rotated",
    "ch06.drive.k": "Drive access",
    "ch06.drive.v": "Appdata and team files created or selected through Zterm",
    "ch06.plate.label": "Plate 07",
    "ch06.plate.title": "Team + sync",
    "ch06.aria": "Zterm team and sync illustration",
    "ch06.caption": "Interface illustration. The data shown is sample data.",

    "ch07.label": "Chapter 07",
    "ch07.name": "Security",
    "ch07.title": "The key stays on your device.",
    "ch07.deck": "Zterm has no account and no server. The vault is encrypted before it leaves the device.",
    "ch07.quote": "The master password is never stored or sent anywhere.",
    "ch07.p1": "Encryption happens on the device. The key is derived from the master password, then used to open the vault. There is no recovery path from Zterm because no copy of the master password is stored.",
    "ch07.01.k": "Vault encryption",
    "ch07.01.v": "Argon2id derives the key from the master password. XChaCha20-Poly1305 encrypts the vault contents.",
    "ch07.02.k": "No Zterm server",
    "ch07.02.v": "No account, analytics, ads, or tracking. Data is not sent to the developer's server.",
    "ch07.03.k": "Device key",
    "ch07.03.v": "Touch ID on Mac and Windows Hello on Windows. Quick lock with Shift+Cmd+L or Ctrl+Shift+L.",
    "ch07.04.k": "Google Drive",
    "ch07.04.v": "Only the appdata folder and team files created through Zterm. Google cannot read the encrypted contents.",
    "ch07.05.k": "Open source",
    "ch07.05.v": "MIT license. The source is on GitHub for anyone to inspect.",
    "ch07.note": "The app is not notarized by Apple and not signed with a Windows certificate. How to open it is covered in the Install chapter.",

    "ch08.label": "Chapter 08",
    "ch08.name": "Install",
    "ch08.title": "Pick a platform, then start.",
    "ch08.deck": "Version 1.0.1 is available for macOS, Windows, and Linux beta. Every build uses the same Rust core.",
    "install.tabs.aria": "Operating system",
    "install.mac.h": "How to install on Mac",
    "install.mac.1": "Download the <b>.dmg</b>, open it, and drag <b>Zterm</b> into Applications.",
    "install.mac.2": "The app is not notarized by Apple. On first launch, open <b>System Settings &gt; Privacy &amp; Security</b> and click <b>Open Anyway</b>.",
    "install.mac.3": "If macOS says the app is damaged, run this once in Terminal:",
    "install.mac.dl": "Download the macOS DMG",
    "install.mac.note": "The DMG contains a universal build for Apple Silicon and Intel. macOS 15 or later.",
    "install.win.h": "How to install on Windows",
    "install.win.1": "Download <b>Setup.exe</b>: the <b>x64</b> build for most PCs, or <b>ARM64</b> for ARM PCs such as Snapdragon.",
    "install.win.2": "The app is not signed with a paid certificate. If <b>Windows protected your PC</b> appears, click <b>More info &gt; Run anyway</b>.",
    "install.win.3": "Follow the installer. Admin rights are not required. When it finishes, open <b>Zterm</b> from the Start menu.",
    "install.win.dl": "Download Setup x64",
    "install.win.arm": "Download Setup ARM64",
    "install.win.note": "Windows 10 and 11. Remove it any time from Settings > Apps. Your vault and settings stay safe.",
    "install.linux.h": "How to install on Linux (beta)",
    "install.linux.1": "Download the <b>AppImage</b>: <b>x86_64</b> for most PCs, or <b>aarch64</b> for ARM PCs or laptops.",
    "install.linux.2": "Make it executable, then run it (or double-click it in your file manager):",
    "install.linux.3": "Needs a fairly recent distro (glibc 2.39+), such as Ubuntu 24.04, Debian 13, or Fedora 40.",
    "install.linux.dl": "Download AppImage x86_64",
    "install.linux.arm": "Download AppImage aarch64",
    "install.linux.note": "Linux is still beta. Available: hosts, SSH and local terminal, keychain, and snippets. Other features are coming.",
    "install.release.label": "Latest release",
    "install.release.chip": "Chips",
    "install.release.lang": "Language",
    "install.release.license": "License",
    "install.release.notes": "Release notes",
    "install.release.bug": "Report a bug",

    "faq.label": "FAQ",
    "faq.title": "Questions that come up often.",
    "faq.deck": "Short answers to what people usually ask before installing.",
    "faq.1.q": "Is it really free?",
    "faq.1.a": "Yes. MIT license, no ads, and no subscription.",
    "faq.2.q": "Can Zterm see my server passwords?",
    "faq.2.a": "No. All data is encrypted on your device with your master password. Zterm has no server, and Google only stores an encrypted file that cannot be read without the master password.",
    "faq.3.q": "What if I forget the master password?",
    "faq.3.a": "The vault cannot be opened. That is the consequence of end-to-end encryption. Keep the master password somewhere safe.",
    "faq.4.q": "Why is there a warning when I open it?",
    "faq.4.a": "The app is not notarized by Apple and not signed with a Windows certificate, because both cost money. The source is open on GitHub for anyone to inspect. On Mac, open it through Privacy &amp; Security &gt; Open Anyway. On Windows, click More info &gt; Run anyway. Only once.",
    "faq.5.q": "What Google Drive access does it ask for?",
    "faq.5.a": "Only the hidden app-specific data folder (drive.appdata). For the Teams feature, Zterm requests drive.file so it can create team files and open them again. Zterm cannot see other files in your Drive.",
    "faq.6.q": "Can I connect through an office proxy?",
    "faq.6.a": "Yes. In the host editor, open Advanced &gt; Proxy, choose SOCKS5 or HTTP, then enter the address, port, and login if needed. You can also turn an SSH server into a SOCKS proxy with Port Forwarding.",
    "faq.7.q": "Is there a Windows version?",
    "faq.7.a": "Yes. Windows 10 and 11, for x64 and ARM64 PCs. The build uses the same Rust core, so one vault works on Mac and Windows through Google Drive sync.",
    "faq.8.q": "Is there a Linux version?",
    "faq.8.a": "Yes, still beta: an AppImage for x86_64 and ARM64 with GTK4, libadwaita, and the VTE terminal. Working today: hosts, SSH and local terminal, keychain, and snippets. SFTP, Database, Docker, Dashboard, and Google sync are coming.",
    "faq.9.q": "Is there an English version?",
    "faq.9.a": "Yes. The app is available in Indonesian and English. The language follows the system, or you can pick one from the Bahasa / Language menu. Error messages from servers are translated too.",

    "footer.tagline": "Field manual, edition 1.0.1",
    "footer.aria": "Footer links",
    "footer.releases": "Releases",
    "footer.issues": "Report a bug",
    "footer.privacy": "Privacy",
    "footer.terms": "Terms"
  };

  var EN_ARIA = {
    "brand.aria": "Zterm, field manual",
    "nav.aria": "Main navigation",
    "nav.mobile.aria": "Mobile navigation",
    "lang.aria": "Language",
    "facts.aria": "Product summary",
    "hero.sketch.aria": "Zterm interface illustration: host list and SSH terminal",
    "ch01.aria": "Zterm host editor illustration",
    "ch02.aria": "Zterm server dashboard illustration with CPU, RAM, and disk charts",
    "ch03.aria": "Zterm database illustration with a table, search, and backups",
    "ch04.aria": "Zterm two-pane SFTP and file editor illustration",
    "ch05.aria": "Zterm Docker and local server illustration",
    "ch06.aria": "Zterm team and sync illustration",
    "install.tabs.aria": "Operating system",
    "footer.aria": "Footer links"
  };

  var UI = {
    id: {
      themeDark: "Aktifkan tema gelap",
      themeLight: "Aktifkan tema terang",
      downloadMac: "Unduh untuk Mac",
      downloadWin: "Unduh untuk Windows",
      downloadWinArm: "Unduh untuk Windows (ARM64)",
      downloadLinux: "Unduh untuk Linux",
      downloadLinuxArm: "Unduh untuk Linux (ARM64)"
    },
    en: {
      themeDark: "Switch to dark theme",
      themeLight: "Switch to light theme",
      downloadMac: "Download for Mac",
      downloadWin: "Download for Windows",
      downloadWinArm: "Download for Windows (ARM64)",
      downloadLinux: "Download for Linux",
      downloadLinuxArm: "Download for Linux (ARM64)"
    }
  };

  var ID = {};
  var ID_ARIA = {};
  var lang = "id";
  var latestVersion = "1.0.1";

  document.querySelectorAll("[data-i18n]").forEach(function (el) {
    ID[el.dataset.i18n] = el.innerHTML;
  });
  document.querySelectorAll("[data-i18n-aria]").forEach(function (el) {
    ID_ARIA[el.dataset.i18nAria] = el.getAttribute("aria-label") || "";
  });

  var root = document.documentElement;
  var themeBtn = document.getElementById("themeBtn");
  var themeMeta = document.querySelector('meta[name="theme-color"]');
  var heroDownload = document.getElementById("heroDownload");
  var heroDownloadLabel = document.getElementById("heroDownloadLabel");
  var editionEl = document.querySelector('[data-i18n="hero.kicker.edition"]');
  var taglineEl = document.querySelector('[data-i18n="footer.tagline"]');

  function ui() {
    return UI[lang] || UI.id;
  }

  function applyVersionCopy() {
    if (editionEl) {
      editionEl.textContent = (lang === "en" ? "Edition " : "Edisi ") + latestVersion;
    }
    if (taglineEl) {
      taglineEl.textContent = lang === "en"
        ? "Field manual, edition " + latestVersion
        : "Panduan lapangan, edisi " + latestVersion;
    }
  }

  function applyAria() {
    var dict = lang === "en" ? EN_ARIA : ID_ARIA;
    document.querySelectorAll("[data-i18n-aria]").forEach(function (el) {
      var value = dict[el.dataset.i18nAria];
      if (value) el.setAttribute("aria-label", value);
    });
    applyThemeLabel();
  }

  function applyThemeLabel() {
    if (!themeBtn) return;
    var dark = root.dataset.theme === "dark";
    themeBtn.setAttribute("aria-label", dark ? ui().themeLight : ui().themeDark);
    themeBtn.setAttribute("aria-pressed", dark ? "true" : "false");
  }

  function setLang(next) {
    lang = next === "en" ? "en" : "id";
    var dict = lang === "en" ? EN : ID;
    document.querySelectorAll("[data-i18n]").forEach(function (el) {
      var value = dict[el.dataset.i18n];
      if (typeof value === "string") el.innerHTML = value;
    });
    root.lang = lang;
    document.querySelectorAll("[data-lang]").forEach(function (button) {
      var on = button.dataset.lang === lang;
      button.classList.toggle("is-on", on);
      button.setAttribute("aria-pressed", on ? "true" : "false");
    });
    applyAria();
    applyVersionCopy();
    applyDownload();
    try { localStorage.setItem("lang", lang); } catch (e) {}
  }

  document.querySelectorAll("[data-lang]").forEach(function (button) {
    button.addEventListener("click", function () {
      setLang(button.dataset.lang);
    });
  });

  function applyTheme(theme) {
    var next = theme === "dark" ? "dark" : "light";
    root.dataset.theme = next;
    if (themeMeta) themeMeta.setAttribute("content", next === "dark" ? "#171410" : "#f2ede3");
    applyThemeLabel();
    try { localStorage.setItem("theme", next); } catch (e) {}
  }

  if (themeBtn) {
    themeBtn.addEventListener("click", function () {
      applyTheme(root.dataset.theme === "dark" ? "light" : "dark");
    });
  }

  var ua = navigator.userAgent;
  var visitorOS = /Windows/i.test(ua) ? "win" : (/Linux|X11/i.test(ua) && !/Android/i.test(ua) ? "linux" : "mac");
  var visitorArm = visitorOS === "linux" && /aarch64|arm64/i.test(ua);

  var DIRECT = "https://github.com/latiefahmad/zterm/releases/latest/download/";
  var DL = {
    mac: DIRECT + "Zterm-macOS.dmg",
    win: DIRECT + "Zterm-Windows-x64-Setup.exe",
    winArm: DIRECT + "Zterm-Windows-arm64-Setup.exe",
    linux: DIRECT + "Zterm-Linux-x86_64.AppImage",
    linuxArm: DIRECT + "Zterm-Linux-aarch64.AppImage"
  };

  function heroLink() {
    if (visitorOS === "win") return visitorArm ? DL.winArm : DL.win;
    if (visitorOS === "linux") return visitorArm ? DL.linuxArm : DL.linux;
    return DL.mac;
  }

  function heroLabel() {
    if (visitorOS === "win") return visitorArm ? ui().downloadWinArm : ui().downloadWin;
    if (visitorOS === "linux") return visitorArm ? ui().downloadLinuxArm : ui().downloadLinux;
    return ui().downloadMac;
  }

  function applyDownload() {
    if (heroDownload) heroDownload.href = heroLink();
    if (heroDownloadLabel) heroDownloadLabel.textContent = heroLabel();

    var mac = document.getElementById("dlMac");
    var win = document.getElementById("dlWin");
    var winArm = document.getElementById("dlWinArm");
    var linux = document.getElementById("dlLinux");
    var linuxArm = document.getElementById("dlLinuxArm");

    if (mac) mac.href = DL.mac;
    if (win) win.href = visitorArm ? DL.winArm : DL.win;
    if (winArm) winArm.href = DL.winArm;
    if (linux) linux.href = visitorOS === "linux" && visitorArm ? DL.linuxArm : DL.linux;
    if (linuxArm) linuxArm.href = DL.linuxArm;
  }

  var tabs = Array.prototype.slice.call(document.querySelectorAll('#osTabs [role="tab"]'));
  var panes = Array.prototype.slice.call(document.querySelectorAll(".os-pane"));

  function selectTab(tab, moveFocus) {
    if (!tab) return;
    tabs.forEach(function (item) {
      var on = item === tab;
      item.setAttribute("aria-selected", on ? "true" : "false");
      item.tabIndex = on ? 0 : -1;
      if (on && moveFocus) item.focus();
    });
    panes.forEach(function (pane) {
      pane.hidden = pane.dataset.os !== tab.dataset.os;
    });
  }

  tabs.forEach(function (tab, index) {
    tab.addEventListener("click", function () {
      selectTab(tab, false);
    });
    tab.addEventListener("keydown", function (event) {
      var next = null;
      if (event.key === "ArrowRight") next = tabs[(index + 1) % tabs.length];
      else if (event.key === "ArrowLeft") next = tabs[(index - 1 + tabs.length) % tabs.length];
      else if (event.key === "Home") next = tabs[0];
      else if (event.key === "End") next = tabs[tabs.length - 1];
      if (next) {
        event.preventDefault();
        selectTab(next, true);
      }
    });
  });

  var initialTab = tabs.filter(function (tab) { return tab.dataset.os === visitorOS; })[0] || tabs[0];
  selectTab(initialTab, false);

  var menu = document.querySelector(".mobile-menu");
  if (menu) {
    menu.querySelectorAll("a").forEach(function (link) {
      link.addEventListener("click", function () {
        menu.removeAttribute("open");
      });
    });
    document.addEventListener("click", function (event) {
      if (menu.open && !menu.contains(event.target)) menu.removeAttribute("open");
    });
    document.addEventListener("keydown", function (event) {
      if (event.key === "Escape" && menu.open) {
        menu.removeAttribute("open");
        var summary = menu.querySelector("summary");
        if (summary) summary.focus();
      }
    });
  }

  if (visitorOS === "win" && navigator.userAgentData && navigator.userAgentData.getHighEntropyValues) {
    navigator.userAgentData.getHighEntropyValues(["architecture"]).then(function (values) {
      if (values && values.architecture === "arm") {
        visitorArm = true;
        applyDownload();
      }
    }).catch(function () {});
  }

  var versionBadge = document.getElementById("ver");
  var releaseVersion = document.getElementById("relVer");

  fetch("https://api.github.com/repos/latiefahmad/zterm/releases/latest")
    .then(function (response) { return response.ok ? response.json() : Promise.reject(); })
    .then(function (release) {
      var version = String(release.tag_name || "").replace(/^v/, "");
      if (version) {
        latestVersion = version;
        if (versionBadge) versionBadge.textContent = version;
        if (releaseVersion) releaseVersion.textContent = version;
        applyVersionCopy();
      }
      var size = function (asset) {
        return Math.max(1, Math.round(asset.size / 1048576)) + " MB";
      };
      var assets = release.assets || [];
      var dmg = assets.filter(function (a) { return /\.dmg$/i.test(a.name); })[0];
      var exe = assets.filter(function (a) { return /Windows-x64-Setup\.exe$/i.test(a.name); })[0];
      var appImage = assets.filter(function (a) { return /Linux-x86_64\.AppImage$/i.test(a.name); })[0];
      document.querySelectorAll(".sizeMac").forEach(function (el) {
        if (dmg) el.textContent = "DMG " + size(dmg);
      });
      document.querySelectorAll(".sizeWin").forEach(function (el) {
        if (exe) el.textContent = "EXE " + size(exe);
      });
      document.querySelectorAll(".sizeLinux").forEach(function (el) {
        if (appImage) el.textContent = "AppImage " + size(appImage);
      });
    })
    .catch(function () {});

  var savedLang = "id";
  try {
    savedLang = localStorage.getItem("lang") || "id";
    var savedTheme = localStorage.getItem("theme") || localStorage.getItem("zterm-theme");
    if (savedTheme === "dark" || savedTheme === "light") root.dataset.theme = savedTheme;
  } catch (e) {}
  applyTheme(root.dataset.theme === "dark" ? "dark" : "light");
  setLang(savedLang);
  applyDownload();
})();
