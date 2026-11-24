# Keamanan

## Melaporkan masalah

Jangan membuka issue publik untuk masalah keamanan. Hubungi pemilik repo secara privat dan sertakan langkah reproduksi, versi aplikasi, serta dampaknya.

## Key Google Picker

Halaman `site/team.html` memakai Google API key publik untuk Google Picker. Key asli tidak disimpan di repo. Saat deploy, `.github/workflows/pages.yml` menyisipkan `secrets.GOOGLE_PICKER_API_KEY` ke placeholder `__GOOGLE_PICKER_API_KEY__`.

Key tersebut wajib dibatasi:

- **HTTP referrers**: `https://latiefahmad.github.io/*`, `https://docs.google.com/*`, `http://localhost:*/*`, dan `http://127.0.0.1:*/*`
- **API restrictions**: hanya **Google Picker API**

`https://docs.google.com/*` wajib ada karena Google Picker dirender di iframe `docs.google.com`. Tanpa referrer itu, Picker menampilkan error “API developer key is invalid”.

Key publik tidak bisa dirahasiakan karena dipakai di browser. Yang melindungi adalah restriction dan kuota, bukan kerahasiaan nilainya.

## Pengembangan lokal

Jangan mengisi key asli ke `site/team.html` yang di-commit. Untuk mencoba halaman tim secara lokal:

1. Salin `site/team.html` menjadi `site/team.local.html`.
2. Ganti `__GOOGLE_PICKER_API_KEY__` dengan key development milikmu.
3. Buka `site/team.local.html` lewat server lokal, bukan `file://`.

`site/team.local.html` sudah diabaikan oleh Git.

## Rotasi key

1. Buat key baru di Google Cloud Console dengan restriction di atas.
2. Perbarui secret `GOOGLE_PICKER_API_KEY` di GitHub.
3. Deploy ulang situs dan pastikan Picker berjalan.
4. Cabut key lama di Google Cloud Console.
5. Tandai alert secret scanning sebagai **Revoked**.
