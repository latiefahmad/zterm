# Terjemahan (i18n)

Zterm ditulis dalam bahasa Indonesia; bahasa Inggris memakai kamus **`en.json`**:
kunci = teks Indonesia persis seperti di kode, nilai = terjemahan Inggris.

- Placeholder `{}` = nilai yang disisipkan, berurutan: `L("Backup {} selesai", name)` → "Backup {} finished".
- Teks yang dibuat core (pesan error, `cron_describe`, dll.) diterjemahkan dengan **pola**: entri berisi `{}`
  dicocokkan terhadap pesan utuh (`{}` = teks apa saja), lalu bagian yang cocok disalin ke terjemahan.
  Di app dipakai lewat `Lmsg(pesan)`.
- Jangan sunting `en.json` langsung: tambahkan ke `parts/<bagian>.json` (core, mac, windows, linux), lalu
  jalankan `python3 scripts/i18n-merge.py` untuk menggabungkan & memeriksa placeholder.

Pilihan bahasa disimpan per perangkat: `system` (bawaan: Indonesia bila bahasa sistem Indonesia, selain itu Inggris), `id`, atau `en`.
