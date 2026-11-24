# Zterm — Konsep Aplikasi

> SSH client native untuk macOS dan Windows. Terinspirasi alur kerja aplikasi seperti Termius, dengan identitas, desain, dan nama sendiri.

## 1. Visi

Satu aplikasi untuk mengelola dan mengakses semua server: simpan host sekali, konek dari Mac maupun Windows, dengan kredensial terenkripsi end-to-end dan tersinkron lewat Google Drive milik user sendiri.

**Prinsip:** benar-benar native di tiap OS (bukan web yang dibungkus), animasi halus, cepat dibuka.

**Target pengguna:** developer, DevOps/SysAdmin, dan pemilik VPS yang mengelola banyak server.

## 2. Fitur

### MVP (v0.1)
| Fitur | Deskripsi |
|---|---|
| **Welcome & onboarding** | Layar sambutan beranimasi → login Google atau tanpa akun → buat master password |
| **Host Manager** | CRUD host, tag, warna, pencarian cepat |
| **Multi-host** | Pilih banyak host lalu "Connect semua" — satu tab per host, berjalan paralel |
| **Terminal SSH** | Terminal native multi-tab, true color, copy/paste |
| **Autentikasi** | Password, private key (Ed25519/RSA/ECDSA), SSH agent |
| **Vault** | Semua data dienkripsi master password (Argon2id + XChaCha20-Poly1305); buka dengan Touch ID / Windows Hello |
| **Known Hosts** | Verifikasi fingerprint, peringatan saat berubah |

### v0.2 — Produktivitas
- SFTP dua panel, drag & drop
- Port forwarding L / R / D
- Snippets (jalankan ke satu atau banyak host sekaligus)
- Jump host, split pane, import `~/.ssh/config`

### v0.3 — Sinkronisasi
- Sync Google Drive (bagian 5a)
- Session log, Mosh (opsional)

## 3. Arsitektur

```
┌──────────────────────────┐   ┌───────────────────────────┐
│ macOS — apps/macos       │   │ Windows — apps/windows     │
│ Swift 6 + SwiftUI        │   │ C# (.NET 9) + WinUI 3      │
│ Terminal: SwiftTerm      │   │ Terminal: Win2D renderer   │
│ Keychain + Touch ID      │   │ Credential Mgr + Hello     │
└────────────┬─────────────┘   └─────────────┬─────────────┘
             │ UniFFI (Swift)                │ uniffi-bindgen-cs (C#)
             └───────────────┬───────────────┘
              ┌──────────────▼───────────────┐
              │ zterm-core (Rust) — core/     │
              │  model   : Host, Group, Key  │
              │  vault   : Argon2id + XChaCha│
              │  ssh     : russh             │
              │  term    : alacritty_terminal│  (dipakai Windows)
              │  sftp, forward, sync (Drive) │
              └──────────────────────────────┘
```

- **Logika ditulis sekali** di Rust: enkripsi, SSH, sync. UI ditulis native per OS.
- **macOS dulu**, Windows menyusul memakai core yang sama.
- Format file vault (`vault.zterm`) sama di kedua OS → file yang sama bisa disinkron lewat Google Drive.

### Tahap transisi SSH di macOS
v0.1 awal memakai `/usr/bin/ssh` bawaan macOS di dalam SwiftTerm (sudah mendukung key, agent, known_hosts). Setelah `zterm-core/ssh` (russh) siap, macOS dan Windows sama-sama memakai SSH dari core.

## 4. Model Data

```
Host        { id, label, hostname, port, username, auth, keyId?, groupId?, tags[], color, updatedAt, deleted }
Group       { id, name, parentId?, defaults }
SshKey      { id, label, type, publicKey, privateKey (enc), passphrase? (enc) }
Snippet     { id, label, command, tags[] }
PortForward { id, hostId, type: L|R|D, bindHost, bindPort, destHost?, destPort? }
KnownHost   { hostname, port, keyType, fingerprint }
```
Setiap record punya `updatedAt` dan `deleted` (tombstone) untuk merge saat sync.

## 5. Keamanan
- Kunci vault diturunkan dari master password dengan **Argon2id**, data dienkripsi **XChaCha20-Poly1305**
- Master password tidak pernah disimpan; opsi buka dengan Touch ID / Windows Hello (kunci disimpan di Keychain / Credential Manager)
- Auto-lock setelah idle
- Sync **zero-knowledge**: Google hanya menyimpan ciphertext

## 5a. Sync via Google Drive

- File `vault.zterm` (terenkripsi) di **`appDataFolder`** — folder tersembunyi khusus aplikasi
- Scope OAuth: `drive.appdata` (tidak bisa membaca file lain user)
- Login: OAuth 2.0 + PKCE — macOS `ASWebAuthenticationSession`, Windows browser sistem + redirect loopback
- Alur: simpan lokal dulu → upload (debounce) → sebelum upload cek `modifiedTime`, kalau berubah: pull → merge per record (`updatedAt` terbaru menang) → push
- Provider dibuat pluggable (`SyncProvider`) untuk Dropbox / WebDAV nanti

## 5b. Platform

| Hal | macOS | Windows |
|---|---|---|
| UI | SwiftUI | WinUI 3 |
| Terminal | SwiftTerm | `alacritty_terminal` (Rust) + Win2D |
| Secret | Keychain + Touch ID | Credential Manager + Windows Hello |
| Login Google | ASWebAuthenticationSession | Browser + loopback |
| Installer | `.dmg` | `Setup.exe` (Velopack) |
| Auto-update | Sparkle | Velopack |
| Dev environment | Xcode | Visual Studio 2022 (Windows / Parallels ARM) |

## 5c. Kebutuhan

- [x] Xcode, Swift 6, Rust, XcodeGen
- [ ] Windows (PC atau Parallels) + Visual Studio 2022 — saat mulai versi Windows
- [ ] Google Cloud project → Drive API + OAuth Client ID (macOS & Desktop)
- [ ] GitHub repo (source, CI, Releases, Pages)
- Tanpa Apple Developer / sertifikat Windows berbayar (lihat 5d)

## 5d. Distribusi

- **GitHub Releases**: `.dmg` (macOS, universal) dan `Setup.exe` (Windows), dibuat GitHub Actions saat push tag `v*`
- **GitHub Pages** (`site/`): landing page, tombol download otomatis sesuai OS, panduan install, changelog
- Tanpa signing berbayar:
  - macOS → System Settings → Privacy & Security → **Open Anyway**, atau `xattr -cr "/Applications/Zterm.app"`
  - Windows → SmartScreen → **More info → Run anyway**

## 6. Desain & Animasi

**Alur pertama kali dibuka**
```
Welcome  ──►  Pilih: [Masuk dengan Google] / [Pakai tanpa akun]  ──►  Buat master password  ──►  Hosts
```
Berikutnya: **Lock screen** (master password / Touch ID) → Hosts.

**Bahasa animasi**
- Background gradien bergerak pelan (mesh gradient) + partikel grid halus
- Logo `>_` dengan kursor berkedip & efek ketik pada tagline
- Elemen masuk berurutan (staggered fade + slide + spring)
- Transisi antar langkah onboarding: slide + blur, tombol dengan spring saat ditekan
- Kartu host: hover angkat (scale + shadow), pilih dengan animasi centang
- "Connect semua": kartu terbang ke tab bar, tab muncul satu per satu
- Indikator status koneksi berdenyut (connecting → connected)
- Semua animasi menghormati setting **Reduce Motion** OS

**Layout utama**
```
┌─────────┬──────────────────────────────────────────┐
│ ● ● ●   │ [⊞] [prod-api ×] [db-01 ×] [+]            │
│ >_ Zterm ├──────────────────────────────────────────┤
│ Hosts   │                                          │
│ Keychain│   root@prod-api:~$ _                     │
│ Snippets│                                          │
│ Forward │                                          │
│ SFTP    │                                          │
│ ⚙︎       │                                          │
└─────────┴──────────────────────────────────────────┘
```

## 7. Roadmap

| Fase | Fokus |
|---|---|
| 1 | `zterm-core`: model + vault terenkripsi + binding Swift; app Mac: onboarding, lock, host manager, multi-host, terminal (ssh sistem) |
| 2 | SSH di core (russh), keychain SSH key, known hosts, Touch ID → **v0.1 macOS** |
| 3 | SFTP, port forwarding, snippets → v0.2 |
| 4 | Sync Google Drive → v0.3 |
| 5 | App Windows (WinUI 3) dengan core yang sama |

## 8. Struktur Repo

```
zterm/
├─ core/                    # zterm-core (Rust, UniFFI)
├─ apps/
│  ├─ macos/                # SwiftUI (project.yml → XcodeGen)
│  └─ windows/              # WinUI 3 (fase 5)
├─ scripts/                 # build-core-apple.sh, dll.
├─ site/                    # Website GitHub Pages
└─ .github/workflows/       # release.yml, pages.yml
```
