# Upload Media dari Windows

## Kenapa bukan web UI Backblaze

Web UI B2 dibatasi **500 MB per file** dan tidak mendukung upload folder.
Film 1080p biasanya 2-8 GB, jadi lewat browser secara harfiah tidak mungkin.
Ini batasan resmi Backblaze, bukan bug.

## Kenapa ini tidak memakan kuota VPS

    Upload:  PC Windows ──────────────▶ B2         VPS tidak terlibat
    Stream:  B2 ──▶ VPS ──▶ penonton               ini yang pakai kuota

Cyberduck bicara langsung ke Backblaze. VPS tidak berada di jalur upload,
jadi kuota 512 GB/bulan sama sekali tidak tersentuh. Backblaze juga tidak
menagih biaya upload.

## Setup Cyberduck (sekali saja)

1. Unduh dari https://cyberduck.io — gratis, ada versi Windows.
2. **Open Connection** → pilih **Backblaze B2** dari dropdown.
3. Isi:
   - Account ID / Application Key ID: **applicationKeyId** milikmu
     (string yang muncul bersama key saat dibuat — bukan master Account ID)
   - Application Key: string key-nya sendiri

   Gunakan key yang **bisa menulis** di sini — key read-only di server
   sengaja dibuat terpisah dan tidak bisa dipakai upload.
4. **Connect**, lalu simpan sebagai bookmark supaya tidak perlu diisi lagi.

## Alur upload

1. Rapikan file di PC sesuai `media-guidelines.md` — struktur folder harus
   sudah benar **sebelum** diupload, karena merapikan di B2 jauh lebih repot.
2. Drag folder `Interstellar (2014)` ke dalam folder film di bucket —
   `Movies/` kalau kamu pakai nama itu, atau nama apa pun yang kamu pilih
   saat membuat library. Yang mengikat struktur di dalam folder judulnya,
   bukan nama folder teratasnya.
3. Tunggu selesai. Cyberduck bisa melanjutkan upload yang terputus.
4. Di VPS, buat file langsung terlihat:

       ssh <vps> 'cd /opt/jellyfin-b2 && ./scripts/refresh-library.sh'

   Kalau tidak buru-buru, lewati langkah ini — file akan muncul sendiri
   dalam beberapa jam lewat scan terjadwal.

## Kalau upload lambat

Yang membatasi adalah kecepatan **upload** internet rumahmu, bukan Backblaze.
Cek di speedtest: angka upload-lah yang menentukan. 10 Mbps upload berarti
sekitar 1 jam per film 4 GB.
