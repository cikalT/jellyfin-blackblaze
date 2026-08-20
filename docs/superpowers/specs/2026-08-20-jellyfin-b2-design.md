# Design: Jellyfin di VPS Tencent dengan Media di Backblaze B2

**Tanggal:** 2026-08-20
**Status:** Disetujui
**Jalur brainstorming:** Architectural (proyek baru)

---

## 1. Tujuan

Menjalankan server media Jellyfin di VPS Tencent kecil, dengan seluruh file media
tersimpan di Backblaze B2. VPS tidak pernah menyimpan media secara permanen dan
tidak pernah terlibat dalam proses upload — perannya murni sebagai **jembatan
streaming** antara B2 dan penonton.

### Non-goals

Hal-hal berikut secara sengaja **tidak** dibangun:

- Transcoding (hardware maupun software) — perangkat kerasnya tidak sanggup.
- Akses publik dari internet — akses hanya lewat Tailscale.
- Pipeline upload otomatis, *arr stack, atau downloader di server.
- Sinkronisasi dua arah ke B2 — mount bersifat **read-only**.
- Redundansi / high availability. Ini instance tunggal.

---

## 2. Kendala perangkat keras & jaringan

| Sumber daya | Nilai | Implikasi desain |
|---|---|---|
| CPU | 2 vCPU | Transcoding mustahil. Direct play adalah satu-satunya mode. |
| RAM | 2 GB | Butuh swapfile. Buffer rclone dibatasi. DLNA dimatikan. |
| Disk | 40 GB SSD | Cache VFS harus dibatasi keras. Metadata Jellyfin harus dijaga. |
| Bandwidth | 20 Mbps | Plafon **per-stream**: ~1 stream 1080p, atau 2–3 stream 720p. |
| Kuota | 512 GB/bulan | ~100 film @5 GB, atau ~250 jam 1080p. Harus dipantau. |

### Anggaran bandwidth

Setiap byte yang ditonton melintasi NIC VPS **dua kali** secara logis (masuk dari
B2, keluar ke penonton), tapi Tencent hanya menghitung **traffic keluar**. Jadi
kuota efektifnya adalah 512 GB tontonan per bulan.

Tailscale menambah overhead WireGuard ~4–6%. Anggaran realistis: **~485 GB
tontonan/bulan**.

---

## 3. Arsitektur

```
                    ┌──────────────────────────────┐
   PC Windows       │      Backblaze B2 bucket     │
   (Cyberduck) ────▶│  Movies/ Shows/  (private)   │
                    └──────────────┬───────────────┘
                                   │  HTTPS, read-only app key
                                   │  rclone VFS (cache 10 GB)
   ┌───────────────────────────────▼───────────────────────────────┐
   │  VPS Tencent — Debian 12                                      │
   │                                                               │
   │   rclone mount (systemd, di host)  ──▶  /srv/media  (ro)      │
   │                                             │ bind, rslave    │
   │   Jellyfin (Docker, versi di-pin)  ◀────────┘                 │
   │        └── bind ke 127.0.0.1:8096 saja                        │
   │                          │                                    │
   │   tailscaled ────────────┘                                    │
   └───────────────────────────┬───────────────────────────────────┘
                               │  WireGuard (terenkripsi)
                               ▼
                    TV / HP / laptop di tailnet
```

### Kenapa rclone di host, bukan di container

FUSE di dalam Docker butuh `--cap-add SYS_ADMIN`, `--device /dev/fuse`, dan
mount propagation yang rapuh. Kalau container rclone restart, container Jellyfin
melihat direktori kosong dan Jellyfin akan **menghapus seluruh library** karena
mengira semua file hilang. Menjalankan rclone sebagai unit systemd di host
menghilangkan seluruh kelas masalah ini dan memberi kita `Restart=on-failure`
yang benar.

### Kenapa Jellyfin di Docker

Versi di-pin dan reproducible, konfigurasi masuk repo, rollback satu baris.
Overhead daemon Docker (~80 MB) sepadan.

---

## 4. Komponen

### 4.1 rclone mount

Unit systemd `rclone-b2.service`, `Type=notify`, mount ke `/srv/media`.

Flag yang menentukan perilaku:

| Flag | Nilai | Alasan |
|---|---|---|
| `--read-only` | — | Jellyfin tidak boleh menulis ke B2. Mencegah artwork tersimpan ke media folder. |
| `--vfs-cache-mode` | `full` | Seek/scrub mulus. rclone modern hanya mengunduh potongan yang dibaca (sparse), bukan seluruh file. |
| `--vfs-cache-max-size` | `10G` | Batas keras terhadap disk 40 GB. |
| `--vfs-cache-max-age` | `72h` | File yang lama tidak ditonton dibuang. |
| `--vfs-read-chunk-size` | `16M` | Awal pemutaran cepat; naik bertahap sampai limit. |
| `--vfs-read-chunk-size-limit` | `128M` | Batas atas agar tidak agresif menarik data. |
| `--vfs-read-ahead` | `128M` | Bantalan cukup untuk bitrate 8 Mbps tanpa boros. |
| `--buffer-size` | `16M` | Per file terbuka. 3 stream = 48 MB RAM. Aman di 2 GB. |
| `--dir-cache-time` | `24h` | B2 tidak mendukung change-notify, jadi polling mustahil. |
| `--poll-interval` | `0` | Eksplisit: tidak ada polling. Refresh dilakukan manual/nightly. |
| `--rc` | `127.0.0.1:5572` | Memungkinkan `vfs/refresh` setelah upload baru. |
| `--uid/--gid` | `1000` | Cocok dengan user Jellyfin di container. |

**Konsekuensi yang disengaja:** file yang baru diupload **tidak muncul otomatis**.
Ini ditangani oleh `scripts/refresh-library.sh` (manual) dan cron nightly.

### 4.2 Jellyfin

Docker Compose, image di-pin, `mem_limit` diset agar OOM killer tidak menyerang
sistem lain.

Port di-bind ke `127.0.0.1:8096`. Paparan ke tailnet dilakukan oleh
`tailscale serve`, bukan dengan membuka port. Tidak ada satu pun port yang
mendengar di interface publik.

### 4.3 Tailscale

`tailscale serve --bg --https=443 http://127.0.0.1:8096` memberi URL
`https://<host>.<tailnet>.ts.net` dengan sertifikat Let's Encrypt asli.
Tidak ada peringatan sertifikat di client mana pun.

---

## 5. Konfigurasi Jellyfin yang wajib

Ini bukan preferensi — ini yang membedakan setup yang jalan dengan yang
menghabiskan kuota sebulan dalam satu malam.

### 5.1 Yang wajib DIMATIKAN

| Setting | Lokasi | Kenapa krusial |
|---|---|---|
| **Trickplay image extraction** | Library → Trickplay | Membaca **seluruh file** setiap film untuk bikin thumbnail scrubbing. Library 50 film = ~250 GB terbaca dari B2. Ini jebakan terbesar. |
| **Chapter image extraction** | Library → lanjutan + Scheduled Tasks | Sama: seek ke banyak titik di seluruh file. |
| **Real-time monitoring** | Tiap library | FUSE tidak punya inotify yang benar. Memicu rescan berulang. |
| **Save artwork into media folders** | Library | Mount read-only — akan gagal dan mengotori log. |
| **Video transcoding** (per user) | User → Playback | Memaksa direct play. Kalau file tidak kompatibel, lebih baik gagal terang-terangan daripada mencekik CPU. |
| **DLNA** | Dashboard → Plugins/Networking | Berbasis broadcast, tidak berguna di tailnet. Menghemat RAM. |
| **UPnP / automatic port mapping** | Dashboard → Networking | Tidak boleh ada usaha membuka port ke internet. |

### 5.2 Yang wajib DISETEL

| Setting | Nilai | Alasan |
|---|---|---|
| Hardware acceleration | None | Tidak ada GPU. |
| Transcode thread count | 1 | Membatasi kerusakan kalau transcode tetap terpicu. |
| Internet streaming bitrate limit (per user) | 8 Mbps | Mencegah client meminta lebih dari yang bisa dilayani link 20 Mbps. |
| Scan media library (scheduled task) | Harian, 03:00 WIB | Di luar jam tonton. |
| Published server URL | `https://<host>.<tailnet>.ts.net` | Agar client menghasilkan URL yang benar. |
| Audio transcoding (per user) | **Aktif** | Remux audio murah secara CPU dan menyelamatkan banyak file. Hanya *video* yang dilarang. |

---

## 6. Aturan media (kontrak dengan pengguna)

Karena transcoding dimatikan, file yang tidak memenuhi syarat **tidak akan
diputar**. Ini konsekuensi yang diterima secara sadar.

### Wajib

| Aspek | Nilai yang aman | Yang akan gagal |
|---|---|---|
| Container | MKV atau MP4 | AVI, WMV, ISO, VIDEO_TS |
| Video | H.264 (AVC), 8-bit, High@L4.1 | HEVC/H.265, 10-bit, AV1, VC-1 |
| Audio | AAC stereo (track pertama) | DTS, DTS-HD, TrueHD, FLAC multichannel |
| Subtitle | SRT — eksternal atau embedded | ASS/SSA (butuh burn-in = transcode), PGS/VOBSUB (bitmap) |
| Bitrate | ≤ 8 Mbps | Remux Blu-ray 20–40 Mbps |

AAC stereo dipilih sebagai track pertama karena browser dan Chromecast tidak
bisa direct-play AC3/EAC3. Track surround boleh ada sebagai track kedua.

### Struktur folder di B2

Harus mengikuti konvensi penamaan Jellyfin, karena inilah satu-satunya cara
Jellyfin mengenali judul:

```
Movies/
  Interstellar (2014)/
    Interstellar (2014).mkv
    Interstellar (2014).id.srt

Shows/
  Severance (2022)/
    Season 01/
      Severance (2022) S01E01.mkv
      Severance (2022) S01E02.mkv
```

Tahun dalam kurung wajib — tanpa itu pencocokan metadata sering meleset.

---

## 7. Alur upload

```
1. Siapkan file di PC Windows sesuai aturan bagian 6
2. Cyberduck → drag folder ke bucket B2
3. SSH ke VPS → jalankan scripts/refresh-library.sh
   (atau tunggu cron 03:00)
4. File muncul di Jellyfin
```

Cyberduck dipilih karena web UI B2 dibatasi **500 MB per file** dan tidak
mendukung upload folder — batasan resmi Backblaze yang membuat upload film
lewat browser mustahil. Cyberduck upload langsung PC → B2; **VPS sama sekali
tidak berada di jalur upload**, sehingga kuota 512 GB tetap utuh.

---

## 8. Konfigurasi Backblaze B2

| Item | Nilai | Alasan |
|---|---|---|
| Bucket type | Private | Tidak ada alasan file terekspos publik. |
| Lifecycle rule | *Keep only the last version* | Tanpa ini, setiap file yang ditimpa disimpan selamanya dan ditagih. |
| Application key | Dibatasi ke 1 bucket, kapabilitas `listBuckets`, `listFiles`, `readFiles` | Server hanya streaming. Kalau VPS dibobol, penyerang tidak bisa menghapus media. |
| Egress | Gratis hingga 3× storage/bulan | Karena VPS dibatasi 512 GB, egress hampir pasti selalu di dalam kuota gratis. |

**Cloudflare fronting sengaja tidak dipakai.** Trik `--b2-download-url` lewat
Cloudflare berguna untuk menghindari biaya egress B2, tapi di sini egress sudah
dibatasi 512 GB oleh VPS — jauh di bawah tunjangan gratis B2 untuk storage
berapa pun di atas ~171 GB. Menambahkannya berarti kompleksitas tanpa manfaat.
YAGNI.

---

## 9. Anggaran disk (40 GB)

| Komponen | Alokasi |
|---|---|
| OS Debian + paket | ~6 GB |
| Image & overlay Docker | ~3 GB |
| Config + metadata + artwork Jellyfin | ~5 GB |
| Cache VFS rclone | 10 GB (batas keras) |
| Swapfile | 2 GB |
| Log (journald dibatasi 200 MB, docker json-file 30 MB) | ~1 GB |
| **Cadangan bebas** | **~13 GB** |

---

## 10. Isi repository

```
.env.example              # semua parameter; diisi di server, tidak pernah di-commit
docker-compose.yml        # Jellyfin, di-pin, bind ke localhost
.gitignore                # .env, rclone.conf, config/, cache/

rclone/
  rclone.conf.example     # template remote B2

systemd/
  rclone-b2.service       # unit mount

scripts/
  bootstrap.sh            # provisioning satu perintah (idempoten)
  preflight.sh            # verifikasi kredensial & sumber daya sebelum install
  refresh-library.sh      # vfs/refresh + trigger scan Jellyfin
  quota-check.sh          # laporan pemakaian kuota bulanan via vnstat
  healthcheck.sh          # cek mount hidup + Jellyfin merespons

docs/
  superpowers/specs/      # dokumen desain (file ini)
  superpowers/plans/      # rencana implementasi
  media-guidelines.md     # aturan bagian 6, versi lengkap untuk dirujuk saat upload
  upload-windows.md       # setup Cyberduck di Windows
  jellyfin-settings.md    # checklist bagian 5, langkah demi langkah dengan lokasi menu
  operations.md           # runbook: mount mati, cache penuh, kuota habis, upgrade
```

### Prinsip skrip

- **Idempoten.** `bootstrap.sh` aman dijalankan berkali-kali.
- **Gagal keras & awal.** `set -euo pipefail`, plus `preflight.sh` yang
  memvalidasi sebelum ada perubahan sistem.
- **Tidak ada rahasia di repo.** Semua kredensial lewat `.env` yang di-gitignore.
- **Bisa dibaca manusia.** Setiap langkah mencetak apa yang dilakukannya.

---

## 11. Penanganan kegagalan

| Kegagalan | Deteksi | Penanganan |
|---|---|---|
| Mount rclone mati | `healthcheck.sh`, systemd | `Restart=on-failure`, `RestartSec=10`. Propagasi `rslave` membuat container ikut melihat mount baru. |
| B2 tidak bisa dihubungi | Log rclone | Mount tetap ada tapi I/O error. Jellyfin menampilkan error putar, **tidak** menghapus library (karena real-time monitoring off). |
| Cache disk penuh | `healthcheck.sh` | `--vfs-cache-max-size` adalah batas keras; rclone membuang entri terlama sendiri. |
| Kuota bulanan habis | `quota-check.sh` | Peringatan di 80%. Keputusan ada di pengguna — tidak ada throttling otomatis. |
| RAM habis saat scan | — | Swapfile 2 GB + `mem_limit` container mencegah OOM killer membunuh sshd. |
| File tidak bisa direct-play | Jellyfin gagal putar | Disengaja. Pengguna merujuk `media-guidelines.md` dan meng-encode ulang di PC. |

---

## 12. Kriteria keberhasilan

Setup dianggap selesai jika semua ini benar:

1. `systemctl status rclone-b2` aktif, dan `ls /srv/media` menampilkan isi bucket.
2. Jellyfin bisa dibuka di `https://<host>.<tailnet>.ts.net` dari device lain di tailnet.
3. `ss -tlnp` menunjukkan **tidak ada** listener di IP publik selain SSH.
4. Satu film 1080p diputar dari awal sampai akhir tanpa buffering, dan dashboard
   Jellyfin melaporkan **Direct Play** (bukan Transcode/Remux).
5. Seek ke tengah film merespons dalam <5 detik.
6. `quota-check.sh` melaporkan pemakaian yang masuk akal.
7. File baru yang diupload dari Windows muncul setelah `refresh-library.sh`.
8. Setelah reboot VPS, semuanya kembali hidup tanpa intervensi manual.

---

## 13. Risiko yang diterima

- **Satu stream saja.** Ini batas fisik 20 Mbps, tidak bisa direkayasa. Kalau
  butuh lebih, satu-satunya jalan adalah menaikkan paket VPS.
- **Disiplin format media.** Beban pindah ke pengguna saat encode. Ini pertukaran
  sadar: 2 vCPU tidak punya pilihan lain.
- **File baru tidak muncul otomatis.** Konsekuensi dari B2 yang tidak mendukung
  change-notify. Dimitigasi dengan skrip refresh + cron.
- **Instance tunggal, tanpa backup config.** Metadata Jellyfin (status tonton,
  user) ada di disk VPS. Snapshot Tencent adalah mitigasi yang disarankan,
  di luar cakupan otomasi ini.
