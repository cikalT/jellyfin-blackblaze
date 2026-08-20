# Checklist Setting Jellyfin

Kerjakan sekali, setelah wizard awal selesai. **Jangan dilewati.** Beberapa
setting bawaan Jellyfin dirancang untuk media di disk lokal; di atas mount B2,
setting yang sama membaca seluruh file dan bisa menghabiskan kuota sebulan
dalam satu malam.

## 1. Sebelum menambahkan library apa pun

Matikan dulu, baru tambahkan library. Kalau library ditambahkan lebih dulu,
scan pertama sudah terlanjur berjalan dengan setting bawaan.

**Dashboard → Playback → Transcoding**
- [ ] Hardware acceleration: **None**
- [ ] Transcode thread count: **1**

**Dashboard → Scheduled Tasks**
- [ ] *Extract Chapter Images* → nonaktifkan (Triggers: hapus semua)
- [ ] *Trickplay Image Extraction* → nonaktifkan (Triggers: hapus semua)
- [ ] *Scan Media Library* → set trigger: setiap **6 jam**

**Dashboard → Networking**
- [ ] Enable automatic port mapping (UPnP): **mati**
- [ ] Published Server URL: `https://<host>.<tailnet>.ts.net`

**Dashboard → General / Plugins**
- [ ] DLNA: **mati** (berbasis broadcast, tidak berguna di tailnet, buang RAM)

## 2. Saat menambahkan tiap library

Tambahkan dua library, keduanya menunjuk ke dalam mount:

| Library | Tipe konten | Folder |
|---|---|---|
| Film | Movies | `/media/Movies` |
| Serial | TV Shows | `/media/Shows` |

Untuk **masing-masing**, di layar penambahan library:

- [ ] Enable real time monitoring: **mati**
      *FUSE tidak punya inotify yang benar; ini memicu rescan berulang.*
- [ ] Enable trickplay image extraction: **mati**
      *Membaca seluruh file setiap judul. Ini item termahal di halaman ini.*
- [ ] Extract chapter images: **mati**
- [ ] Save artwork into media folders: **mati**
      *Mount read-only — akan gagal terus dan mengotori log.*
- [ ] Enable subtitle extraction on the fly: **mati**

## 3. Setting per-user

**Dashboard → Users → [user] → Playback**

- [ ] Allow video playback that requires transcoding: **mati**
- [ ] Allow video playback that requires conversion (remux): **mati**
- [ ] Allow audio playback that requires transcoding: **aktif**
      *Remux audio murah secara CPU dan menyelamatkan banyak file. Hanya
      video yang dilarang.*
- [ ] Internet streaming bitrate limit: **8 Mbps**
      *Link hanya 20 Mbps. Tanpa batas ini, client meminta lebih dari yang
      bisa dilayani dan hasilnya buffering, bukan penurunan kualitas.*
- [ ] Maximum simultaneous streams: **2**

## 4. Setelah semuanya jalan

**Dashboard → Advanced → API Keys → New API Key** (nama: `scripts`)

Salin key-nya ke `.env` sebagai `JELLYFIN_API_KEY`, lalu:

    docker compose up -d

## 5. Verifikasi

Putar satu film, lalu buka **Dashboard → Activity**. Sesi harus tertulis
**Direct Play**. Kalau tertulis *Transcode* atau *Remux*, file itu melanggar
aturan di `media-guidelines.md` — perbaiki filenya, jangan setting-nya.
