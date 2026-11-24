# Arah desain situs Zterm

## Design Read

Landing page untuk developer, sysadmin, dan tim kecil yang mengelola server, dengan bahasa visual panduan lapangan cetak. Dial: **ENERGY 2 / RHYTHM 3 / MOTION 1**.

## Identitas

Zterm adalah manual lapangan untuk server yang benar-benar kamu jalankan. Halaman harus terasa seperti buku teknis dari penerbit kecil: kertas hangat, tinta hitam, satu aksen oranye bara, judul serif editorial, label data monospace, garis rambut, bab bernomor, dan plate bergambar dengan keterangan.

Halaman ini tidak boleh terasa seperti template SaaS. Tidak ada gradien biru-ungu, kartu kaca, glow, bayangan mengambang, atau animasi masuk saat scroll.

## Palet

| Peran | Light | Dark | Alasan |
|---|---|---|---|
| Kertas | `#f2ede3` | `#171410` | Kertas hangat memberi karakter cetak dan memisahkan halaman dari putih default SaaS. |
| Tinta | `#191611` | `#f2ece0` | Kontras tinggi untuk teks utama. |
| Tinta sekunder | `#4f483c` | `#c9c0b1` | Teks penjelas yang tetap terbaca. |
| Tinta redup | `#6b6355` | `#a49a88` | Label dan keterangan; rasio tetap di atas 4.5:1. |
| Garis | `#c9c0b1` | `#3b342a` | Pemisah struktural, bukan dekorasi. |
| Garis kontrol | `#8c8272` | `#6e6556` | Batas kontrol memenuhi kontras non-teks 3:1. |
| Aksen | `#b23a0a` | `#ff8a4c` | Oranye bara dipakai untuk aksi utama, penanda struktural, dan fokus keyboard. |
| Status sehat | `#3f5d3a` | `#a8c29a` | Status nyata di ilustrasi, selalu disertai teks. |
| Terminal | `#1b1813` | `#0f0d0a` | Permukaan terminal asli, bukan kostum dekoratif. |

Palet aktif: kertas, tinta, olive, dan satu aksen oranye.

## Tipografi

- **Newsreader** untuk judul dan kutipan. Serif editorial dengan optik buku, bukan sans geometris default.
- **IBM Plex Sans** untuk teks. Dirancang untuk dokumentasi teknis dan nyaman di ukuran kecil.
- **IBM Plex Mono** untuk label, data, perintah, dan keterangan plate. Bukan monospace sebagai kostum terminal, tetapi karena isinya memang data.

Judul memakai ukuran besar dan tracking rapat. Label memakai kalimat normal, bukan huruf kapital dengan tracking lebar.

## Layout

- Grid 12 kolom, lebar maksimum 1240px.
- Hero asimetris: teks di kiri, plate besar di kanan.
- Setiap bab punya nomor, judul, deck, salinan, tabel spesifikasi, dan plate bila diperlukan.
- RHYTHM 3: komposisi berganti antara teks plus plate, plate lebar, catatan margin, dan ledger keamanan. Tidak semua bab berbentuk sama.
- MOTION 1: tidak ada animasi masuk, parallax, atau loop. Hanya perubahan warna, garis, dan fokus saat hover atau keyboard.

## Motif identitas

Sistem "plate" dan "bab" seperti manual cetak:

- nomor bab kecil berwarna aksen;
- garis rambut sebagai pemisah;
- plate berbingkai tinta dengan label dan keterangan;
- angka dan perintah dalam monospace;
- judul serif dengan satu frasa italic.

## Suara copy

Langsung, spesifik, tenang. Bahasa Indonesia lebih dulu, terjemahan Inggris tetap tersedia. Tidak memakai em dash, buzzword, statistik karangan, atau nama pelanggan fiktif.

## Catatan tujuan

- Garis dan pemisah membantu hierarki bab; tidak ada grid atau pola latar.
- Oranye muncul sebagai penanda, bukan latar luas: tombol unduh utama, frasa italic judul, nomor bab, label plate, penanda baris, dan fokus keyboard.
- Plate adalah ilustrasi antarmuka yang diberi label jelas, bukan tangkapan layar palsu.
- Tidak ada bayangan, gradien, glass, atau glow.
