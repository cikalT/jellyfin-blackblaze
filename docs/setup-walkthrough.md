# Panduan Setup Lengkap

Dari nol sampai menonton film pertama. Ikuti berurutan — tiap bagian
mengandalkan yang sebelumnya.

Perkiraan waktu: **45–60 menit**, di luar waktu upload film.

**Tanda yang dipakai:**
`$` dijalankan di **PC/laptop kamu** · `#` dijalankan di **VPS sebagai root**

---

## Bagian 0 — Yang perlu disiapkan

| Kebutuhan | Keterangan |
|---|---|
| VPS Tencent | Debian 12, akses SSH root, IP publik |
| Akun Backblaze | Gratis. Kartu kredit diminta untuk B2, tagihan mulai setelah 10 GB |
| PC Windows | Untuk upload media |
| Film uji | Satu file, H.264 + AAC, di bawah 8 Mbps — lihat `media-guidelines.md` |

Siapkan buku catatan. Ada **empat nilai** yang harus kamu salin antar layanan:
`keyID` B2, `applicationKey` B2, nama bucket, dan IP publik VPS.

---

## Bagian 1 — Backblaze B2

### 1.1 Aktifkan B2

Masuk ke [backblaze.com](https://www.backblaze.com) → **My Account** →
**B2 Cloud Storage** → **Enable B2**.

### 1.2 Buat bucket

**Buckets** → **Create a Bucket**

| Kolom | Isi |
|---|---|
| Bucket Unique Name | mis. `media-cikal-2026` (harus unik se-Backblaze) |
| Files in Bucket are | **Private** |
| Default Encryption | Disable |
| Object Lock | Disable |

Catat nama bucket-nya. Ini yang masuk ke `B2_BUCKET`.

### 1.3 Pasang lifecycle rule

Masih di bucket itu → **Lifecycle Settings** → pilih
**Keep only the last version of the file** → **Update Bucket**.

Tanpa ini, setiap file yang kamu timpa akan disimpan selamanya dan tetap
ditagih. Ini satu klik yang mudah dilupakan dan mahal.

### 1.4 Buat DUA application key

Kamu butuh dua kunci berbeda dengan hak berbeda. Ini disengaja: server
tidak pernah perlu menulis, jadi kalau VPS dibobol, penyerang tidak bisa
menghapus library-mu.

**Kunci pertama — untuk server (read-only):**

**Application Keys** → **Add a New Application Key**

| Kolom | Isi |
|---|---|
| Name of Key | `jellyfin-server-ro` |
| Allow access to Bucket(s) | pilih bucket kamu (**jangan** "All") |
| Type of Access | **Read Only** |
| Sisanya | biarkan kosong |

Setelah **Create New Key**, layar menampilkan dua string:

```
keyID:          0053f1a2b3c4d5e0000000001
applicationKey: K005abc123def456ghi789jkl012mno345
```

**Salin keduanya sekarang.** `applicationKey` hanya ditampilkan sekali —
kalau halamannya tertutup, kamu harus buat kunci baru.

- `keyID` → masuk ke **`B2_KEY_ID`**
- `applicationKey` → masuk ke **`B2_APPLICATION_KEY`**

> **Kesalahan paling umum:** mengisi `B2_KEY_ID` dengan *Account ID* dari
> halaman akun. Itu nilai yang berbeda, dan B2 akan membalas **401**.
> Yang benar adalah `keyID` yang muncul bersama kunci di atas.

**Kunci kedua — untuk upload dari Windows (read-write):**

Ulangi, dengan **Name of Key** `cyberduck-upload` dan **Type of Access**
dibiarkan penuh (jangan centang Read Only). Simpan di password manager —
kunci ini hanya dipakai di PC Windows, tidak pernah menyentuh VPS.

---

## Bagian 2 — Firewall Tencent

Panel Tencent → instance kamu → **Firewall** / **Security Group**.

Tambahkan aturan inbound:

| Protokol | Port | Sumber | Alasan |
|---|---|---|---|
| TCP | 22 | IP rumahmu, kalau bisa | SSH |
| **UDP** | **51820** | `0.0.0.0/0` | WireGuard |

Dua jebakan di langkah ini, dan keduanya membuat panel terlihat seakan
aturannya sudah benar:

**1. Harus UDP, bukan TCP.** WireGuard murni UDP; aturan TCP tidak menolong
sama sekali.

**2. Harus di firewall INSTANCE, bukan di firewall TEMPLATE.** Lighthouse
punya halaman *Firewall Templates* yang terpisah. Aturan yang dibuat di sana
**tidak berlaku** sampai template-nya diterapkan ke instance — dialognya
bahkan menyatakan itu sendiri: *"The change of template rules has no impact
on the existing firewall rules."* Jalur yang benar:

    Lighthouse → Instances → klik instance → tab Firewall → Add rule

Tab Firewall milik instance itu harus menampilkan baris UDP 51820
berdampingan dengan TCP 22 yang sudah ada. Kalau di sana hanya ada TCP 22,
aturan UDP-mu belum pernah aktif.

Membuka UDP 51820 ke publik terdengar berisiko, tapi WireGuard tidak
membalas paket yang tidak membawa kunci sah. Bagi pemindai port, port itu
tampak tertutup — tidak ada yang bisa di-brute force.

Catat **IP publik** instance dari panel. Ini masuk ke `WG_ENDPOINT`.

---

## Bagian 3 — Provisioning VPS

### 3.1 Masuk dan pasang git

```bash
$ ssh root@<ip-publik-vps>
```

```bash
# apt-get update && apt-get install -y git curl
```

### 3.2 Ambil repo

```bash
# git clone https://github.com/cikalT/jellyfin-blackblaze.git /opt/jellyfin-b2
# cd /opt/jellyfin-b2
```

### 3.3 Isi konfigurasi

```bash
# cp .env.example .env
# nano .env
```

Empat baris yang wajib diisi — sisanya biarkan apa adanya:

```bash
B2_KEY_ID=0053f1a2b3c4d5e0000000001
B2_APPLICATION_KEY=K005abc123def456ghi789jkl012mno345
B2_BUCKET=media-cikal-2026
WG_ENDPOINT=43.128.77.19
```

Konfirmasi IP publiknya kalau ragu:

```bash
# curl -s ifconfig.me
```

Simpan dengan `Ctrl+O`, `Enter`, lalu `Ctrl+X`.

### 3.4 Validasi sebelum mengubah apa pun

```bash
# ./scripts/preflight.sh
```

Skrip ini tidak mengubah apa pun. Yang diperiksa: kredensial B2 diterima
API Backblaze, kunci punya kapabilitas yang benar dan dibatasi ke bucket
yang benar, RAM dan disk cukup, modul WireGuard tersedia, dan `WG_ENDPOINT`
cocok dengan IP publik sungguhan.

Kalau kredensialnya ditolak, pesannya menyebut penyebab yang paling mungkin.
Untuk memeriksa ulang kunci saja tanpa cek lainnya:

```bash
# ./scripts/preflight.sh --b2-only
```

Harapan: berakhir dengan `Preflight lolos.`

Kalau gagal, pesannya menyebut persis apa yang salah. Perbaiki dulu —
jangan lanjut.

### 3.5 Intip apa yang akan dilakukan

```bash
# ./scripts/bootstrap.sh --dry-run
```

Mencetak setiap perintah yang akan dijalankan, diawali `[dry-run]`, tanpa
menyentuh sistem. Baca sekilas.

### 3.6 Jalankan

```bash
# ./scripts/bootstrap.sh
```

Sepuluh langkah, sekitar 3–5 menit. Yang terjadi: paket dasar, swapfile
2 GB, batas log, Docker + rclone + WireGuard, direktori, kredensial ke
`/etc/`, kunci WireGuard, unit systemd, lalu container Jellyfin.

Skrip ini **idempoten** — aman diulang kalau terputus di tengah.

Berakhir dengan tiga langkah lanjutan yang tercetak di layar.

### 3.7 Pastikan sehat

```bash
# ./scripts/healthcheck.sh
```

Semua harus hijau. Kalau `/srv/media ter-mount` tapi kosong, berarti bucket
memang masih kosong — normal pada tahap ini.

---

## Bagian 4 — Sambungkan device

### 4.1 Daftarkan HP

```bash
# ./scripts/add-client.sh hp
```

Terminal mencetak QR code besar. Jangan ditutup dulu.

### 4.2 Pasang di HP

Install **WireGuard** dari Play Store / App Store — aplikasi resmi, ikonnya
naga ungu.

Buka app → tombol **+** → **Scan from QR code** → arahkan ke terminal →
beri nama `jellyfin` → **aktifkan togglenya**.

Tidak ada login. Tidak ada akun. Selesai.

### 4.3 Uji tunnel

Dengan tunnel aktif, buka browser di HP:

```
http://10.8.0.1:8096
```

Halaman setup Jellyfin harus muncul. Kalau tidak, lihat Bagian 8.

### 4.4 Daftarkan device lain

```bash
# ./scripts/add-client.sh laptop
# ./scripts/add-client.sh tablet
```

Untuk laptop, lebih mudah pakai file daripada QR:

```bash
$ scp root@<ip-vps>:/etc/wireguard/clients/laptop.conf .
```

Lalu di app WireGuard desktop: **Import tunnel from file**.

Menambah device tidak memutus device lain yang sedang menonton.

---

## Bagian 5 — Konfigurasi Jellyfin

### 5.1 Wizard awal

Di `http://10.8.0.1:8096`:

1. Bahasa → **Next**
2. Buat user admin — catat passwordnya
3. **"Add Media Library"** → **lewati, klik Next tanpa menambahkan apa pun**
4. Metadata language → **Next**
5. Remote access: **hilangkan centang** "Allow remote connections"
6. **Finish**, lalu login

> Langkah 3 penting. Kalau library ditambahkan sekarang, scan pertama
> berjalan dengan setting bawaan — dan setting bawaan Jellyfin bisa
> menghabiskan kuota sebulan dalam satu malam di atas mount B2.

### 5.2 Kerjakan checklist SEBELUM menambah library

Buka **[jellyfin-settings.md](jellyfin-settings.md)** dan kerjakan dari
atas ke bawah. Bukan opsional.

Yang paling mahal kalau terlewat: **Trickplay image extraction**. Fitur itu
membaca *seluruh file* setiap film untuk membuat thumbnail scrubbing.
Library 50 film berarti ~250 GB tersedot dari B2 — separuh kuota bulananmu
untuk sekali scan.

### 5.3 Buat API key

**Dashboard → Advanced → API Keys → +**, beri nama `scripts`.

Di VPS:

```bash
# nano .env          # isi JELLYFIN_API_KEY=<key-tadi>
# docker compose up -d
```

Ini yang membuat `refresh-library.sh` bisa memicu scan.

---

## Bagian 6 — Upload media

### 6.1 Siapkan file di Windows

Rapikan **sebelum** upload — merapikan di B2 jauh lebih repot:

```
Interstellar (2014)\
    Interstellar (2014).mkv
    Interstellar (2014).id.srt
```

Tahun dalam kurung wajib. Nama file harus sama dengan nama foldernya.
Aturan lengkap ada di [media-guidelines.md](media-guidelines.md).

### 6.2 Pasang Cyberduck

Unduh dari [cyberduck.io](https://cyberduck.io) — gratis, ada versi Windows.

**Open Connection** → pilih **Backblaze B2** → isi dengan kunci
**read-write** (`cyberduck-upload`, bukan yang read-only) → **Connect** →
simpan sebagai bookmark.

### 6.3 Buat struktur folder

Di dalam bucket, buat dua folder: `Movies` dan `Shows`.

Nama ini cuma konvensi — boleh apa saja, asal nanti cocok dengan path yang
kamu isi di Jellyfin.

### 6.4 Upload

Drag folder `Interstellar (2014)` ke dalam `Movies/`.

Upload berjalan langsung PC → Backblaze. **VPS tidak terlibat sama sekali**,
jadi kuota 512 GB tidak tersentuh. Yang membatasi kecepatan adalah upload
internet rumahmu.

---

## Bagian 7 — Tambahkan library dan tonton

### 7.1 Buat library

**Dashboard → Libraries → Add Media Library**

| Kolom | Isi |
|---|---|
| Content type | **Movies** |
| Display name | Film |
| Folders | `/media/Movies` |

Lalu matikan yang tercantum di bagian 2 `jellyfin-settings.md` —
real time monitoring, trickplay, chapter images, save artwork.

Ulangi untuk serial dengan content type **TV Shows** dan `/media/Shows`.

### 7.2 Munculkan file yang baru diupload

```bash
# ./scripts/refresh-library.sh
```

Ini memaksa rclone melihat file baru, lalu memicu scan Jellyfin. Tanpa
perintah ini file tetap muncul sendiri dalam beberapa jam — skrip ini hanya
mempercepat.

### 7.3 Verifikasi pemutaran

Putar filmnya. Sambil berjalan, buka **Dashboard → Activity**.

Harus tertulis **Direct Play**.

Kalau tertulis *Transcode* atau *Remux*, filenya melanggar aturan format —
perbaiki filenya, jangan setting-nya. Server tidak akan sanggup transcode.

---

## Bagian 8 — Pemakaian sehari-hari

```bash
# ./scripts/healthcheck.sh        # mount, container, disk
# ./scripts/quota-check.sh        # sisa kuota bulan ini
# ./scripts/refresh-library.sh    # setelah upload file baru
# ./scripts/add-client.sh <nama>  # daftarkan device baru
```

### Kalau ada yang rusak

| Gejala | Cek pertama |
|---|---|
| Tidak bisa connect sama sekali | UDP 51820 di security group Tencent — pastikan **UDP**, bukan TCP |
| Tunnel jalan, Jellyfin tidak merespons | `./scripts/healthcheck.sh` |
| Library kosong padahal sudah upload | `./scripts/refresh-library.sh` |
| Buffering | **Dashboard → Activity** — Direct Play atau Transcode? |
| Handshake tidak pernah terjadi | `wg show` — kolom *latest handshake* kosong berarti paket tidak sampai |

Diagnosis lengkap ada di [operations.md](operations.md).

### Yang harus diingat

- **Satu stream 1080p pada satu waktu.** Batas fisik 20 Mbps, tidak bisa
  direkayasa.
- **512 GB/bulan** ≈ 100 film. Pantau dengan `quota-check.sh`.
- **Jangan ubah `AllowedIPs` jadi `0.0.0.0/0`** di config WireGuard. Itu
  mengalirkan seluruh browsing-mu lewat VPS dan menghabiskan kuota untuk
  hal yang bukan menonton.
- **Jangan pernah `git add` file `.env`.** Isinya kunci B2 sungguhan.
