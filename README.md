<div align="center">

<img src="site/assets/brand/icon-512.png" width="112" alt="Logo Zterm" />

# Zterm

**Semua servermu, satu terminal.**

SSH client native untuk **macOS**, **Windows**, dan **Linux (beta)** — dashboard semua server, terminal, SFTP, Docker, database ala phpMyAdmin, server lokal, berbagi host ke tim, SSH key, port forwarding, dan proxy dalam satu app.<br />
Data terenkripsi end-to-end dan tersinkron lewat Google Drive milikmu sendiri. Tersedia dalam **bahasa Indonesia & English**.<br />
Versi **Linux** masih beta — lihat [Linux (beta)](#linux-beta).

[![Rilis](https://img.shields.io/github/v/release/latiefahmad/zterm?label=rilis&color=3FD0B4)](https://github.com/latiefahmad/zterm/releases/latest)
[![Lisensi MIT](https://img.shields.io/badge/lisensi-MIT-5B9CF5)](LICENSE)
![macOS 15+](https://img.shields.io/badge/macOS-15%2B-111?logo=apple)
![Windows 10/11](https://img.shields.io/badge/Windows-10%20%2F%2011-0078D4?logo=windows)
[![Unduhan](https://img.shields.io/github/downloads/latiefahmad/zterm/total?label=unduhan&color=9D7CF2)](https://github.com/latiefahmad/zterm/releases)

[**⬇ Download untuk Mac**](https://github.com/latiefahmad/zterm/releases/latest/download/Zterm-macOS.dmg) &nbsp;·&nbsp;
[**⬇ Download untuk Windows**](https://github.com/latiefahmad/zterm/releases/latest/download/Zterm-win-x64.exe) &nbsp;·&nbsp;
[Windows ARM64](https://github.com/latiefahmad/zterm/releases/latest/download/Zterm-win-arm64.exe) &nbsp;·&nbsp;
[**⬇ Linux (AppImage, beta)**](https://github.com/latiefahmad/zterm/releases/latest/download/Zterm-Linux-x86_64.AppImage) &nbsp;·&nbsp;
[Website](https://latief.id/zterm/)

[Zterm 1.0.1](#zterm-101) · [Fitur](#fitur) · [Install](#install) · [Changelog](#changelog) · [Development](#development)

<br />

</div>

---

## Zterm 1.0.1

Rilis pertama Zterm untuk macOS, Windows, dan Linux (beta) — satu app native untuk seluruh pekerjaan server.

- **📊 Dashboard** — semua server dalam satu layar (CPU, RAM, disk, uptime), notifikasi saat server mati atau penuh
- **▶️ Jalankan perintah di banyak server** — satu perintah, hasil per server; plus **split & broadcast** terminal
- **🛠️ Kelola Server** — proses, service systemd, crontab, dan log tanpa hafal perintah
- **💾 Backup database** — sekali klik atau terjadwal, opsional ke Google Drive
- **🐳 Docker** gaya OrbStack — lokal atau di server lewat SSH
- **🐧 Linux (beta)** — AppImage untuk x86_64 & ARM64
- **🌐 Dwibahasa** — semua app tersedia dalam bahasa Indonesia & English

📝 [Catatan rilis lengkap](CHANGELOG.md)

## Kenapa Zterm

| | |
|---|---|
| **Satu app untuk semua kerja server** | Terminal SSH, transfer file, database, server lokal, tunnel, dan snippet — tanpa pindah-pindah aplikasi |
| **Native, bukan web yang dibungkus** | SwiftUI di Mac, WinUI 3 di Windows, inti bersama di Rust |
| **Kuncinya cuma kamu yang pegang** | Vault dienkripsi Argon2id + XChaCha20-Poly1305 — tanpa akun Zterm, tanpa server kami |
| **Gratis & open source** | Lisensi MIT, tanpa iklan, tanpa langganan |

## Fitur

| Fitur | Isi | macOS | Windows | Linux (beta) |
|---|---|:-:|:-:|:-:|
| 🖥️ [Hosts & terminal](#️-hosts--terminal) | SSH multi-tab, terminal lokal, autocomplete, info server, split & broadcast | ✅ | ✅ | ✅ |
| 📊 [Dashboard](#️-hosts--terminal) | Semua server sekali lihat, notifikasi, jalankan perintah di banyak server | ✅ | ✅ | — |
| 🛠️ [Kelola Server](#️-hosts--terminal) | Proses, service systemd, crontab, log | ✅ | ✅ | — |
| 🧱 [Server Lokal](#-server-lokal) | Apache / Nginx + PHP, MySQL, PostgreSQL, MongoDB | ✅ | ✅ | — |
| 👥 [Tim](#-tim) | Berbagi host terenkripsi ke rekan kerja | ✅ | ✅ | — |
| 📁 [SFTP](#-sftp) | Dua panel, drag & drop, editor bawaan, buka dengan app lain | ✅ | ✅ | — |
| 🐳 [Docker](#-docker) | Container, image & Compose — lokal atau di server lewat SSH | ✅ | ✅ | — |
| 🗄️ [Database](#️-database-ala-phpmyadmin) | 8 engine + 15 layanan cloud, cari ala phpMyAdmin, backup & restore | ✅ | ✅ | — |
| 🔑 [Keychain, tunnel & proxy](#-keychain-tunnel--proxy) | SSH key, port forwarding, SOCKS5/HTTP proxy, snippets | ✅ | ✅ | ◐ |
| 🔒 [Keamanan & sync](#-keamanan--sync) | Vault terenkripsi, sync Google Drive, Touch ID / Windows Hello | ✅ | ✅ | ◐ |
| 🌐 Bahasa | Indonesia & English — ikut sistem atau pilih di "Bahasa / Language" | ✅ | ✅ | ✅ |

◐ = sebagian (Linux: SSH key, proxy, snippets, vault terenkripsi; port forwarding & sync menyusul)

### 🖥️ Hosts & terminal

Grid atau list, dikelompokkan per grup, warna kartu bebas. Pilih beberapa host lalu connect semuanya sekaligus — satu tab per host.

| | |
|---|---|
| **Autentikasi** | Password, SSH key, atau SSH agent (termasuk OpenSSH agent & Pageant di Windows) |
| **Lanjutan** | Jump host, proxy SOCKS5/HTTP, agent forwarding, startup snippet, env var |
| **Terminal lokal** | zsh di Mac, PowerShell / CMD / WSL di Windows — tab di samping sesi SSH |
| **Info server** | Spesifikasi (OS, kernel, CPU, uptime) + grafik live CPU, RAM, jaringan, dan storage |
| **Dashboard** | Semua server dalam satu layar: CPU, RAM, disk, uptime, jaringan; notifikasi saat server mati atau penuh; langsung split & broadcast |
| **Jalankan perintah** | Satu perintah ke banyak server paralel, hasil per server (exit code, output, durasi) |
| **Kelola Server** | Proses ala htop (kill), service systemd (start/stop/restart/boot), editor crontab dengan bahasa biasa, log journalctl & file log |
| **Split & broadcast** | 2–4 terminal berdampingan; ketik sekali, jalan di semua panel (⌘D, ⇧⌘B) |
| **Autocomplete** | Saran perintah dari riwayat & snippet saat mengetik |
| **Tampilan** | 7 tema terminal, mode gelap & terang, alamat server bisa disamarkan |

### 🧱 Server Lokal

Seperti MAMP / XAMPP, tapi di dalam Zterm: nyalakan web server dan database di komputermu dengan satu klik.

| | |
|---|---|
| **Web** | Apache atau Nginx + PHP 8.4 — untuk Laravel, WordPress, dan proyek PHP lain |
| **Database** | MySQL 8.4, PostgreSQL 17, MongoDB 8 — tombol **Buka di Database** langsung ke halaman Database |
| **Unduh sesuai butuh** | Komponen diunduh otomatis saat pertama dipakai; Apache bawaan macOS dipakai langsung |
| **Rapi** | Port & folder proyek bisa diatur, hanya di `127.0.0.1`, semua berhenti saat app ditutup |

### 👥 Tim

Admin memilih host yang dibagikan lalu mengundang email rekan kerja dari dalam Zterm. Rekan cukup klik **Tim → Gabung tim** — host (lengkap dengan password & SSH key) langsung muncul di daftar Hosts mereka, read-only.

- Disimpan sebagai satu file terenkripsi di Google Drive admin — tanpa akun Zterm, tanpa server kami
- Kunci tim dibungkus per anggota (X25519), isi tim ditandatangani admin (Ed25519)
- Admin mengubah host → anggota ikut terupdate; anggota dikeluarkan → izin Drive dicabut dan kunci tim diganti

### 📁 SFTP

Dua panel berdampingan: komputermu di kiri, server di kanan. Seret file atau folder untuk upload/download, dengan progress, kecepatan, dan tombol batal. Folder baru, ganti nama, hapus, dan chmod dengan centang.

- **Editor bawaan** — klik dua kali file teks (config, script, `.env`, log): nomor baris, cari, simpan ⌘S / Ctrl+S, dan peringatan kalau file sudah diubah orang lain
- **Buka dengan** — VS Code, Sublime, Notepad++, Preview, atau app lain; setiap kali kamu menyimpan, file otomatis di-upload ke server

### 🐳 Docker

Kelola Docker di komputermu atau di server mana pun lewat SSH — tanpa expose port Docker, tanpa install agent.

| | |
|---|---|
| **Gaya OrbStack** | Sidebar Container · Volume · Image · Network, proyek Compose yang bisa dilipat, panel detail di samping |
| **Container** | Start, stop, restart, pause, hapus; port yang bisa diklik ke browser |
| **Detail** | CPU & RAM live, env (tersamar), mount, network, IP, log yang ikut berjalan |
| **Shell** | Satu klik buka terminal di dalam container |
| **Compose, image & volume** | Up, restart, stop, down per proyek; hapus image & volume yang tidak dipakai |
| **Akses** | Bila user SSH belum di grup `docker`, otomatis mencoba `sudo -n` |

### 🗄️ Database ala phpMyAdmin

MySQL, MariaDB, PostgreSQL, SQL Server, SQLite, Redis, MongoDB, ClickHouse, plus 15 preset layanan (RDS, Supabase, Neon, PlanetScale, TiDB, Atlas, Upstash, …) — langsung, TLS, atau lewat tunnel SSH.

- **Telusuri** dengan paging, **Struktur** tabel, editor **SQL** dengan riwayat, ekspor **CSV**
- **Cari** per kolom seperti phpMyAdmin: `=`, `LIKE %…%`, `IN`, `BETWEEN`, `IS NULL`, …
- **Cari cepat** di semua kolom tabel sekaligus; daftar database & tabel bisa ditampilkan / disembunyikan
- **Backup & restore** — MySQL, MariaDB, PostgreSQL, MongoDB, SQLite ke file `.gz` (lewat SSH dump dijalankan di server); jadwal harian/mingguan, simpan N terakhir, opsional ke Google Drive

### 🔑 Keychain, tunnel & proxy

- **SSH key** — buat Ed25519 sekali klik atau impor dari `~/.ssh` (Ed25519, RSA, ECDSA, dengan passphrase)
- **Port forwarding** — local, remote, dan SOCKS dinamis; nyalakan dengan toggle
- **Proxy** — konek lewat proxy SOCKS5 atau HTTP kantor/kampus, lengkap dengan login
- **Snippets, Known Hosts & Logs** — perintah favorit ke banyak host, fingerprint server, riwayat sesi

### 🔒 Keamanan & sync

- Vault terenkripsi di perangkatmu; master password tidak pernah disimpan atau dikirim
- Sync otomatis ke folder tersembunyi Google Drive milikmu (`drive.appdata`) — login di Mac atau PC lain, semua host kembali
- Buka vault dengan **Touch ID** atau **Windows Hello**
- Fingerprint server dicek terhadap `known_hosts`; kunci yang berubah ditolak

## Install

**macOS 15+** (Apple Silicon & Intel)

1. Download [`Zterm-macOS.dmg`](https://github.com/latiefahmad/zterm/releases/latest/download/Zterm-macOS.dmg), buka, seret **Zterm** ke Applications.
2. App belum dinotarisasi Apple. Saat pertama dibuka: **System Settings → Privacy & Security → Open Anyway**.
3. Kalau muncul pesan "rusak", jalankan sekali di Terminal:

   ```bash
   xattr -cr "/Applications/Zterm.app"
   ```

**Windows 10 / 11** (x64 & ARM64)

1. Download [`Zterm-win-x64.exe`](https://github.com/latiefahmad/zterm/releases/latest/download/Zterm-win-x64.exe) — atau [`Zterm-win-arm64.exe`](https://github.com/latiefahmad/zterm/releases/latest/download/Zterm-win-arm64.exe) untuk PC ARM seperti Snapdragon.
2. Kalau muncul **Windows protected your PC**, klik **More info → Run anyway**.
3. Ikuti installer (tanpa hak admin), lalu buka **Zterm** dari Start Menu.

> **Windows 1.1.1 / 1.2.0:** pasang 1.2.1 secara manual satu kali. Tombol update di versi lama crash sebelum mengunduh; setelah 1.2.1, pembaruan berikutnya otomatis.

### Linux (beta)

Versi Linux memakai **GTK4 + libadwaita** dan terminal **VTE**, langsung di atas `zterm-core` (tanpa UniFFI).

1. Download [`Zterm-Linux-x86_64.AppImage`](https://github.com/latiefahmad/zterm/releases/latest/download/Zterm-Linux-x86_64.AppImage) — atau [`aarch64`](https://github.com/latiefahmad/zterm/releases/latest/download/Zterm-Linux-aarch64.AppImage) untuk PC ARM.
2. Jadikan bisa dijalankan lalu buka:

   ```bash
   chmod +x Zterm-Linux-*.AppImage && ./Zterm-Linux-*.AppImage
   ```

Butuh distro yang cukup baru (glibc 2.39+), mis. Ubuntu 24.04, Debian 13, Fedora 40. Bisa juga build sendiri (lihat [Build Linux](#development)).

Yang sudah ada: vault terenkripsi (buat / buka dengan master password), daftar host (grup, cari, warna), editor host (password / SSH key / agent, jump host, proxy SOCKS5/HTTP), tab terminal SSH & terminal lokal, Keychain (generate / import key), dan Snippets.<br />
Menyusul: SFTP, Database, Docker, Dashboard, Tim, dan sync Google Drive.

> **Zterm 1.0.1** — tampilan baru dengan ikon Phosphor Duotone di macOS, Windows, dan Linux (beta). Zterm memberi tahu di app saat ada versi baru.

## Changelog

| Versi | Tanggal | Sorotan |
|---|---|---|
| [**1.0.1**](CHANGELOG.md#101--2026-11-25) | 25 Nov 2026 | Tampilan baru dengan ikon Phosphor Duotone di macOS, Windows, dan Linux (beta), plus perbaikan Dashboard dan build Linux |
| [**1.0.0**](CHANGELOG.md#100--2026-11-24) | 24 Nov 2026 | Rilis pertama: dashboard semua server, terminal SSH, SFTP, Docker, database & backup, Server Lokal, Tim, keychain, tunnel, Linux (beta), dan update dari dalam app |

Detail lengkap tiap versi: **[CHANGELOG.md](CHANGELOG.md)** · Semua file installer: [Releases](https://github.com/latiefahmad/zterm/releases)

## Development

```
core/              zterm-core (Rust): vault, SSH/SFTP, proxy, database, Docker, Tim, Server Lokal — diekspor via UniFFI
apps/macos/        App macOS (SwiftUI + SwiftTerm), project dibuat dengan XcodeGen
apps/windows/      App Windows (WinUI 3 + WebView2/xterm.js + ConPTY), installer Inno Setup
apps/linux/        App Linux beta (Rust + GTK4/libadwaita + VTE), memakai zterm-core langsung
scripts/           Build core, installer Windows, tes integrasi, Google Drive tiruan
site/              Website (GitHub Pages), halaman Gabung tim, katalog unduhan Server Lokal (stack.json)
```

<details>
<summary><b>Build macOS</b> — Xcode, Rust (<code>rustup</code>), XcodeGen</summary>

```bash
./scripts/build-core-apple.sh
```

```bash
cd apps/macos && xcodegen generate && open Zterm.xcodeproj
```

</details>

<details>
<summary><b>Build Windows</b> — Rust, .NET 9 SDK, VS Build Tools (C++ & Clang), Inno Setup 6</summary>

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build-core-windows.ps1
```

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build-windows-installer.ps1
```

</details>

<details>
<summary><b>Build Linux (beta)</b> — Rust, GTK 4.14+, libadwaita 1.5+, VTE (gtk4)</summary>

Ubuntu 24.04 / Debian:

```bash
sudo apt install build-essential pkg-config libssl-dev libgtk-4-dev libadwaita-1-dev libvte-2.91-gtk4-dev openssh-client
```

Fedora:

```bash
sudo dnf install gcc pkgconf-pkg-config openssl-devel gtk4-devel libadwaita-devel vte291-gtk4-devel openssh-clients
```

```bash
cargo run --release --manifest-path apps/linux/Cargo.toml
```

AppImage (`dist/Zterm-Linux-<arch>.AppImage`) atau Flatpak (GNOME runtime):

```bash
./scripts/build-linux-appimage.sh
```

```bash
./scripts/build-linux-flatpak.sh
```

</details>

<details>
<summary><b>Tes</b></summary>

```bash
cd core && cargo test
```

```bash
./scripts/test-sftp.sh
```

```bash
./scripts/test-db.sh
```

- `cargo test` termasuk alur Tim lewat Google Drive tiruan (`scripts/mock-drive.py`, butuh python3)
- `test-sftp.sh` menjalankan `sshd` sementara di `127.0.0.1` (termasuk tes lewat proxy)
- `test-db.sh` memakai container Docker sementara `zterm-test-*`
- Server Lokal dengan unduhan sungguhan (ratusan MB), manual:

```bash
cd core && ZTERM_STACK_ROOT=/tmp/zterm-stack cargo test --test stack_live -- --ignored --nocapture
```

</details>

<details>
<summary><b>Rilis</b></summary>

Naikkan versi (`core/Cargo.toml`, `apps/linux/Cargo.toml`, `apps/macos/project.yml`, `Zterm.csproj`, `Zterm.iss`, `site/index.html`), tambahkan section `## [versi]` di `CHANGELOG.md`, lalu push tag. GitHub Actions memvalidasi versi dan changelog, membangun DMG macOS + installer Windows + AppImage Linux, lalu menerbitkan release dengan isi changelog sebagai body.

```bash
git tag v1.0.1 && git push origin v1.0.1
```

</details>

Konsep & arsitektur lengkap: [CONCEPT.md](CONCEPT.md)

## Dukung

Zterm dibuat oleh **Latief Ahmad** dan dibagikan gratis. Kalau bermanfaat, beri ⭐ di repo ini atau [laporkan bug](https://github.com/latiefahmad/zterm/issues).

<div align="center">
<sub>Lisensi <a href="LICENSE">MIT</a> · <a href="CHANGELOG.md">Changelog</a> · <a href="https://github.com/latiefahmad/zterm/issues">Laporkan bug</a> · <a href="https://latief.id/zterm/privacy.html">Privasi</a></sub>
</div>
