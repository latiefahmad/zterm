# Changelog

Semua perubahan penting di Zterm. Format mengikuti [Keep a Changelog](https://keepachangelog.com/id-ID/1.1.0/), versi mengikuti [Semantic Versioning](https://semver.org/lang/id/).

Download versi terbaru: [Releases](https://github.com/latiefahmad/zterm/releases/latest) · Website: [latief.id/zterm](https://latief.id/zterm/)

---

## [1.1.1] - 2026-11-26

Pembaruan otomatis kini benar-benar memasang versi baru dan membuka Zterm kembali, dengan progress unduhan yang halus.

### Diperbaiki

- **Progress unduhan** - laporan progress dibatasi dan bilah dianimasikan, sehingga tidak lagi terasa patah-patah; sidebar dan halaman Tentang tidak digambar ulang setiap potongan data
- **Pasang otomatis (Windows)** - installer dijalankan langsung dengan mode senyap, menutup sisa proses Zterm, memasang, lalu membuka Zterm lagi lewat entri `[Run]`; tidak lagi bergantung pada helper `.cmd` yang bisa menunggu proses induk selamanya
- **Pasang otomatis (macOS)** - helper menunggu proses dengan batas waktu, mencatat langkah pemasangan ke `update.log`, dan tetap membuka Zterm lagi bila penggantian bundle gagal

### Catatan

- Pengguna versi 1.1.0 atau lebih lama perlu memasang 1.1.1 secara manual satu kali; pembaruan otomatis berikutnya sudah memakai alur baru.

[1.1.1]: https://github.com/latiefahmad/zterm/releases/tag/v1.1.1

## [1.1.0] - 2026-11-26

Dialog keamanan saat kunci server berubah, plus hapus semua key satu host dari Known Hosts.

### Ditambahkan

- **Host key berubah** - SFTP di macOS dan Windows menampilkan fingerprint lama dan baru berdampingan, dengan aksi **Ganti key** dan pintasan ke Known Hosts
- **Known Hosts** - hapus semua key untuk satu host sekaligus (termasuk entri ter-hash), dengan konfirmasi eksplisit dan cadangan `known_hosts.old`

### Diubah

- **Core** - `HostKeyChanged` membawa host, port, fingerprint, dan tipe key lama/baru; path `known_hosts` konsisten memakai `HOME` lalu `USERPROFILE`
- **Keamanan** - Ganti key tidak pernah menjadi tombol default; Batal/Escape tetap menjadi aksi aman

### Platform

- **macOS 15+** - universal (Apple Silicon & Intel)
- **Windows 10/11** - x64 dan ARM64
- **Linux (beta)** - x86_64 dan ARM64

[1.1.0]: https://github.com/latiefahmad/zterm/releases/tag/v1.1.0

## [1.0.1] - 2026-11-25

Pembaruan tampilan untuk macOS, Windows, dan Linux (beta). Seluruh ikon kini memakai Phosphor Duotone, dengan permukaan netral, border tipis, dan status berbentuk badge.

### Diubah

- **Antarmuka baru** — ikon Phosphor Duotone di seluruh halaman macOS, Windows, dan Linux, ukuran ikon diseragamkan, gradient dan glow berlebihan dihapus, aksen teal Zterm dipertahankan
- **Dashboard & sidebar** — tata letak baru dengan kartu server, status titik/badge, dan navigasi yang lebih ringkas di macOS dan Windows
- **Linux (beta)** — sidebar, onboarding, Hosts, Keychain, Snippets, editor, dan tab terminal memakai Phosphor Duotone; 174 ikon SVG simbolik ikut dipaketkan di AppImage dan Flatpak

### Diperbaiki

- macOS: halaman Akun gagal dibangun karena `PageHeader` tanpa aksi
- macOS: Dashboard menyegarkan daftar host saat host ditambah, diubah, atau dihapus
- Linux: ikon tetap ditemukan saat build release dijalankan langsung dari repo

### Platform

- **macOS 15+** — universal (Apple Silicon & Intel)
- **Windows 10/11** — x64 dan ARM64
- **Linux (beta)** — x86_64 dan ARM64

[1.0.1]: https://github.com/latiefahmad/zterm/releases/tag/v1.0.1

## [1.0.0] - 2026-11-24

Rilis pertama Zterm untuk macOS, Windows, dan Linux (beta). Satu aplikasi native untuk seluruh pekerjaan server: terminal SSH, SFTP, Docker, database, server lokal, dan kolaborasi tim.

### Ditambahkan

- **Hosts & terminal** — koneksi SSH multi-tab, terminal lokal, autocomplete, info server, split 2–4 panel, dan broadcast ke semua panel
- **Dashboard** — CPU, RAM, disk, uptime, dan jaringan semua server dalam satu layar, diperbarui tiap 5 detik, dengan notifikasi saat server mati atau penuh
- **Jalankan perintah di banyak server** — satu perintah paralel ke puluhan server, lengkap dengan exit code, output, dan durasi per server
- **Kelola Server** — proses ala htop, service systemd, crontab dengan preset bahasa manusia, serta log journalctl dan file log
- **SFTP** — dua panel, drag & drop, progress dan tombol batal, kelola file dan chmod, editor bawaan dengan nomor baris dan pencarian, serta opsi buka dengan app lain
- **Database ala phpMyAdmin** — MySQL, MariaDB, PostgreSQL, SQL Server, SQLite, Redis, MongoDB, ClickHouse, dan 15 preset layanan cloud; telusuri, struktur, pencarian per kolom, SQL dengan riwayat, ekspor CSV
- **Backup & restore database** — sekali klik atau terjadwal, kompresi `.gz`, simpan N backup terakhir, dan opsi unggah ke Google Drive
- **Docker** — container per proyek Compose, detail CPU/RAM live, port yang bisa diklik, log berjalan, shell dalam container, serta kelola image, volume, dan network
- **Server Lokal** — Apache atau Nginx + PHP 8.4, MySQL 8.4, PostgreSQL 17, dan MongoDB 8 di komputer sendiri, dengan unduhan komponen sesuai kebutuhan
- **Tim** — berbagi host terenkripsi ke rekan kerja lewat Google Drive, dengan kunci tim X25519 dan tanda tangan admin Ed25519
- **Keychain & tunnel** — generate atau impor SSH key, port forwarding local/remote/SOCKS, proxy SOCKS5/HTTP per host, snippets, known hosts, dan riwayat sesi
- **Antarmuka** — mode gelap dan terang, 7 tema terminal, bahasa Indonesia dan English, serta alamat server yang bisa disamarkan
- **Linux (beta)** — AppImage untuk x86_64 dan ARM64 dengan GTK4, libadwaita, dan VTE
- **Update dari dalam app** — Windows dan macOS mengunduh, memverifikasi SHA-256, memasang, dan membuka ulang Zterm otomatis; pilih **Update sekarang** atau **Nanti**, dengan progres unduhan di sidebar dan halaman Tentang

### Keamanan

- Vault terenkripsi Argon2id + XChaCha20-Poly1305, tanpa akun Zterm dan tanpa server perantara
- Sinkronisasi ke folder tersembunyi Google Drive milik pengguna (`drive.appdata`)
- Buka vault dengan Touch ID atau Windows Hello; kunci cepat dengan ⇧⌘L / Ctrl+Shift+L
- Fingerprint server diverifikasi terhadap `known_hosts`; kunci yang berubah ditolak

### Platform

- **macOS 15+** — universal (Apple Silicon & Intel), dibangun dengan SwiftUI dan SwiftTerm
- **Windows 10/11** — x64 dan ARM64, dibangun dengan WinUI 3, WebView2, dan ConPTY
- **Linux (beta)** — x86_64 dan ARM64, dibangun dengan GTK4 + libadwaita dan VTE

### Catatan

- **Linux (beta)** — pembaruan masih manual: unduh AppImage terbaru dari halaman rilis.

[1.0.0]: https://github.com/latiefahmad/zterm/releases/tag/v1.0.0
