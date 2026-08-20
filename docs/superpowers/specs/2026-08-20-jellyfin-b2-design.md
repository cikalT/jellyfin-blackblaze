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

### Model pengguna

**Satu akun Jellyfin, banyak perangkat, tidak pernah memutar bersamaan.** Ini
bukan detail sepele — inilah yang membuat plafon 20 Mbps cukup, dan yang
membenarkan dihapusnya seluruh urusan manajemen multi-user, kuota per-user, dan
pembatasan sesi yang rumit.

### Non-goals

Hal-hal berikut secara sengaja **tidak** dibangun:

- Transcoding (hardware maupun software) — perangkat kerasnya tidak sanggup.
- Akses publik dari internet — akses hanya lewat Tailscale.
- Pipeline upload otomatis, *arr stack, atau downloader di server.
- Sinkronisasi dua arah ke B2 — mount bersifat **read-only**.
- Redundansi / high availability. Ini instance tunggal.
- Reverse proxy publik, sertifikat Let's Encrypt, fail2ban, atau hardening
  internet-facing lainnya — tidak ada yang terekspos, jadi tidak ada yang perlu
  dikeraskan.
- Manajemen multi-user, profil anak, atau pembatasan konten.

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

WireGuard menambah overhead enkapsulasi ~4–6%. Anggaran realistis:
**~485 GB tontonan/bulan**.

Split tunnel penting di sini: client hanya me-rute subnet VPN lewat tunnel,
sehingga browsing biasa tidak menyentuh kuota sama sekali. Full tunnel akan
mengalirkan seluruh trafik internet pengguna lewat VPS dan menghabiskan
kuota untuk hal yang bukan menonton.

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
   │        └── bind ke 10.8.0.1:8096 saja                         │
   │                          │                                    │
   │   wg0  10.8.0.1  ────────┘   dengar di UDP 51820              │
   └───────────────────────────┬───────────────────────────────────┘
                               │  WireGuard, split tunnel
                               ▼
              HP 10.8.0.2 · laptop 10.8.0.3 · tablet 10.8.0.4
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
| `--dir-cache-time` | `1h` | Kompromi: file baru terlihat otomatis dalam <=1 jam, sementara biaya listing tetap jauh di bawah jatah gratis B2 (2.500 Class C/hari). |
| `--poll-interval` | `0` | Eksplisit: B2 tidak mendukung change-notify, jadi polling memang mustahil. |
| `--rc` | `127.0.0.1:5572` | Memungkinkan `vfs/refresh` setelah upload baru. |
| `--uid/--gid` | `1000` | Cocok dengan user Jellyfin di container. |

**Perilaku file baru.** Rantainya dua lapis, dan penting untuk tidak
mencampuradukkannya:

1. **rclone** menahan daftar isi folder selama `--dir-cache-time` (1 jam).
   Selama cache masih hangat, file baru belum terlihat oleh proses mana pun di
   server — termasuk Jellyfin.
2. **Jellyfin** punya scheduled task *Scan Media Library* yang mendeteksi file
   baru dan yang berubah. Task ini hanya seakurat listing yang dilihatnya.

Jadi file baru muncul otomatis dalam waktu paling lama `dir-cache-time` +
interval scan. Untuk hasil instan, `scripts/refresh-library.sh` memaksa
`vfs/refresh` lewat rclone RC lalu langsung memicu scan Jellyfin lewat API.
Tidak diperlukan cron tambahan — penjadwal bawaan Jellyfin sudah menangani
kasus normal.

### 4.2 Jellyfin

Docker Compose, image di-pin, `mem_limit` diset agar OOM killer tidak menyerang
sistem lain.

Port di-bind ke `127.0.0.1:8096`. Paparan ke tailnet dilakukan oleh
`tailscale serve`, bukan dengan membuka port. Tidak ada satu pun port yang
mendengar di interface publik.

### 4.3 WireGuard

Server WireGuard di host, `wg-quick@wg0`, subnet `10.8.0.0/24`, VPS di
`10.8.0.1`, mendengar di UDP 51820.

**Tanpa akun, tanpa login.** Ini alasan utama WireGuard dipilih menggantikan
Tailscale: satu config per device, dibuat sekali, berlaku selamanya. Tidak
ada SSO, tidak ada admin console, tidak ada kunci yang kedaluwarsa.

**Split tunnel, disengaja.** Config client memakai `AllowedIPs = 10.8.0.0/24`,
bukan `0.0.0.0/0`. Tidak ada `MASQUERADE` dan `ip_forward` tetap mati — VPS
ini bukan gateway internet, hanya tujuan. Full tunnel akan menghabiskan kuota
512 GB untuk browsing biasa.

**Tanpa TLS, disengaja.** Jellyfin diakses lewat `http://10.8.0.1:8096`.
WireGuard sudah mengenkripsi seluruh isi tunnel; menambahkan TLS di atasnya
hanya menambah sertifikat yang harus diperpanjang tanpa menambah keamanan.

**Permukaan serangan.** Satu-satunya port yang mendengar di IP publik adalah
UDP 51820 dan SSH. WireGuard tidak membalas paket tanpa kunci sah, sehingga
tidak terlihat oleh pemindai port dan tidak bisa di-brute force.

Device didaftarkan lewat `scripts/add-client.sh <nama>`, yang mengalokasikan
IP bebas berikutnya, membuat kunci, menerapkan peer tanpa memutus koneksi
yang sedang berjalan (`wg syncconf`, bukan restart), lalu mencetak QR code.

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
| Scan media library (scheduled task) | Setiap 6 jam | Dengan `dir-cache-time` 1 jam, ini membuat file baru muncul otomatis dalam <=7 jam tanpa intervensi. Biayanya ~800 panggilan listing/hari, masih di bawah jatah gratis. |
| Maximum simultaneous streams (per user) | 2 | Pagar pengaman terhadap pemutaran ganda yang tidak disengaja. Tidak diset 1 karena sesi TV yang tidak tertutup rapi bisa mengunci pemutaran berikutnya. |
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

### Kenapa Cloudflare tidak dipakai sama sekali

Pengguna memiliki domain di Cloudflare. Domain itu **sengaja tidak dilibatkan**
dalam setup ini, karena dua pemakaian yang mungkin sama-sama tidak layak:

**Sebagai proxy akses Jellyfin (Cloudflare Tunnel / awan oranye).** Cloudflare
melarang pengiriman video lewat jaringan mereka di plan Free, Pro, dan Business;
mereka dapat me-redirect konten atau mengambil tindakan lain terhadap akun yang
melanggar. Pola ini populer di kalangan self-hoster tapi tetap melanggar ToS.
Ditolak.

**Sebagai front untuk download B2 (`--b2-download-url`).** Ini menghindari biaya
egress B2, tapi manfaatnya nyaris nol di sini: egress sudah dibatasi 512 GB oleh
kuota VPS, sementara tunjangan gratis B2 adalah 3x storage — artinya selama
storage di atas ~171 GB, egress selalu gratis dengan sendirinya. Untuk library
yang lebih kecil, biaya terburuknya beberapa ribu rupiah per bulan. Menambahkan
Cloudflare berarti kompleksitas dan area abu-abu ToS demi penghematan yang tidak
berarti. YAGNI.

Akses tetap lewat Tailscale saja.

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
2. Jellyfin bisa dibuka di `http://10.8.0.1:8096` dari device lain di tunnel.
3. `ss -tlnp` menunjukkan **tidak ada** listener TCP di IP publik selain SSH;
   satu-satunya port publik lain adalah UDP 51820.
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
- **File baru muncul dengan jeda, bukan seketika.** Paling lama ~7 jam secara
  otomatis (cache direktori 1 jam + interval scan 6 jam). Konsekuensi dari B2
  yang tidak mendukung change-notify. `refresh-library.sh` menjadikannya instan
  kalau sedang tidak sabar.
- **Instance tunggal, tanpa backup config.** Metadata Jellyfin (status tonton,
  user) ada di disk VPS. Snapshot Tencent adalah mitigasi yang disarankan,
  di luar cakupan otomasi ini.

---

## 14. Riwayat keputusan

Dicatat agar keputusan yang sudah dibayar dengan diskusi tidak dibongkar ulang
tanpa alasan baru.

| # | Keputusan | Alternatif yang ditolak | Alasan |
|---|---|---|---|
| 1 | Repo + skrip, dijalankan sendiri oleh pengguna | Provisioning langsung via SSH | Tidak ada kredensial yang perlu melewati sesi asisten. |
| 2 | Akses lewat VPN saja, bukan internet publik | Domain publik + Caddy; Cloudflare Tunnel | Nol attack surface. Pengguna tunggal, tidak ada kebutuhan berbagi. |
| 3 | Domain Cloudflare tidak dilibatkan | Awan oranye untuk Jellyfin | Cloudflare melarang pengiriman video lewat plan Free/Pro/Business. |
| 4 | Cloudflare fronting untuk B2 tidak dipakai | `--b2-download-url` via Cloudflare | Egress B2 sudah gratis dengan sendirinya pada skala ini. YAGNI. |
| 5 | rclone systemd di host, bukan container | rclone dalam Docker | FUSE-in-Docker rapuh; container rclone yang restart bisa membuat Jellyfin mengira seluruh library hilang. |
| 6 | Upload lewat Cyberduck di Windows | Web UI Backblaze B2 | Web UI B2 dibatasi 500 MB/file dan tidak mendukung upload folder. Rencana awal pengguna secara harfiah tidak bisa dijalankan untuk file film. |
| 7 | `dir-cache-time` 1 jam + scan Jellyfin tiap 6 jam | `dir-cache-time` 24 jam + cron nightly | Direvisi setelah pengguna menunjukkan Jellyfin sudah punya deteksi file baru. Menurunkan cache membuat fitur bawaan itu berfungsi; cron jadi tidak perlu. |
| 8 | Transcoding dimatikan, disiplin format dipindah ke pengguna | Transcoding terbatas | 2 vCPU tidak punya pilihan lain. Gagal terang-terangan lebih baik daripada buffering misterius. |

| 9 | WireGuard murni menggantikan Tailscale | Tetap Tailscale; Cloudflare WARP/Zero Trust | Direvisi 2026-08-20 setelah pengguna melaporkan login Tailscale merepotkan. WireGuard tidak punya konsep akun sama sekali: satu config per device, dibuat sekali, berlaku selamanya. Cloudflare WARP ditolak karena tetap menuntut enrolment per device — tidak menyelesaikan masalahnya — sekaligus mengembalikan persoalan ToS video yang sudah kami hindari di keputusan #3. |
| 10 | Split tunnel, bukan full tunnel | `AllowedIPs = 0.0.0.0/0` | Full tunnel mengalirkan seluruh browsing pengguna lewat kuota 512 GB dan membatasinya di 20 Mbps. VPS ini tujuan, bukan gateway. |
| 11 | Tanpa TLS di dalam tunnel | Sertifikat self-signed; Let's Encrypt via DNS-01 | WireGuard sudah mengenkripsi seluruh isi tunnel. TLS di atasnya menambah sertifikat yang harus diurus tanpa menambah keamanan. |

### Yang hilang dengan meninggalkan Tailscale

Dicatat jujur, karena keputusan #9 bukan tanpa biaya:

- **NAT traversal.** Tailscale bisa menembus dua sisi yang sama-sama di
  belakang NAT. WireGuard tidak. Di sini tidak masalah — VPS punya IP publik,
  jadi client selalu bisa mendial masuk.
- **Nama DNS.** Hilangnya MagicDNS berarti memakai `10.8.0.1`. Untuk satu
  server, IP tetap justru lebih mudah diingat daripada nama `.ts.net`.
- **Manajemen device terpusat.** Menambah atau mencabut device kini lewat
  SSH, bukan admin console. Untuk pengguna tunggal dengan tiga device, ini
  pertukaran yang jelas menguntungkan.
- **Port yang harus dibuka.** UDP 51820 di security group. Dimitigasi oleh
  sifat WireGuard yang tidak membalas paket tanpa kunci sah.
