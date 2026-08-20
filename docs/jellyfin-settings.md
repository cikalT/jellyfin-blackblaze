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
- [ ] Published Server URL: `http://10.8.0.1:8096`

**Dashboard → General / Plugins**
- [ ] DLNA: **mati** (berbasis broadcast, tidak lewat tunnel, buang RAM)

## 2. Saat menambahkan tiap library

### Yang bebas kamu tentukan

Jellyfin **tidak punya aturan** soal nama folder teratas. Tiga hal ini
sepenuhnya pilihanmu:

- **Nama library** — yang tampil di menu. `Film`, `Movies`, `Koleksi`, apa saja.
- **Nama folder di B2** — `Movies/`, `film/`, `video/bioskop/`, terserah.
- **Berapa library** — boleh satu per genre, satu per bahasa, atau cuma satu
  untuk semuanya. Satu library juga boleh menunjuk ke beberapa folder sekaligus.

Yang penting cuma: path yang kamu isi di Jellyfin harus cocok dengan folder
yang benar-benar ada di bucket, dengan `/media` sebagai prefiks. Folder
`Koleksi Film/` di B2 berarti path `/media/Koleksi Film`.

### Yang mengikat

Dua hal, dan keduanya karena Jellyfin memakainya untuk mencocokkan metadata:

**1. Content type harus benar.** Ini bukan label — ini yang menentukan aturan
penamaan mana yang dipakai Jellyfin saat memindai. Salah pilih, judulnya tidak
akan dikenali sama sekali.

| Isi folder | Content type yang harus dipilih |
|---|---|
| Film | Movies |
| Serial / anime bersambung | TV Shows |
| Musik | Music |

**2. Jangan campur film dan serial dalam satu library.** Aturan penamaan
keduanya berbeda; dicampur berarti sebagian besar tidak akan cocok.

Struktur di *dalam* tiap judul juga mengikat — itu dijelaskan terpisah di
[media-guidelines.md](media-guidelines.md), karena berlaku saat upload,
bukan saat setup library.

### Contoh yang dipakai dokumentasi ini

Sekadar titik awal, bukan keharusan:

| Nama library | Content type | Path di Jellyfin | Folder di B2 |
|---|---|---|---|
| Film | Movies | `/media/Movies` | `Movies/` |
| Serial | TV Shows | `/media/Shows` | `Shows/` |

Kalau kamu pakai nama lain, sesuaikan juga contoh di dokumen lain — tidak ada
yang rusak, cuma contohnya jadi tidak cocok dengan punyamu.

### Setting untuk tiap library

Untuk **masing-masing** library, di layar penambahan:

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
