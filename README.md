# Jellyfin + Backblaze B2

Server media Jellyfin di VPS kecil, dengan seluruh file tersimpan di
Backblaze B2. VPS tidak menyimpan media dan tidak terlibat dalam upload —
perannya murni menstream.

Akses hanya lewat WireGuard. Tidak ada layanan yang terbuka ke internet —
satu-satunya port yang mendengar adalah UDP WireGuard, yang tak terlihat oleh
pemindai karena tidak membalas paket tanpa kunci sah.

## Kendala yang membentuk desain ini

| | |
|---|---|
| 2 vCPU | Transcoding dimatikan total. Direct play saja. |
| 2 GB RAM | Buffer dibatasi, swap 2 GB, DLNA dimatikan. |
| 40 GB disk | Cache VFS dibatasi keras 10 GB. |
| 20 Mbps | Sekitar 1 stream 1080p pada satu waktu. |
| 512 GB/bulan | Sekitar 100 film atau 250 jam 1080p. |

## Instalasi

Di VPS Debian 12 yang masih bersih:

    git clone <repo> /opt/jellyfin-b2
    cd /opt/jellyfin-b2
    cp .env.example .env
    nano .env                       # isi kredensial B2
    sudo ./scripts/bootstrap.sh --dry-run    # tinjau dulu
    sudo ./scripts/bootstrap.sh

Lalu ikuti tiga langkah manual yang dicetak bootstrap: buka UDP 51820 di
security group Tencent, daftarkan device pertama dengan
`sudo ./scripts/add-client.sh hp`, dan kerjakan checklist di
[docs/jellyfin-settings.md](docs/jellyfin-settings.md).

## Dokumentasi

- **[Panduan setup lengkap](docs/setup-walkthrough.md) — mulai dari sini**, nol sampai menonton
- [Checklist setting Jellyfin](docs/jellyfin-settings.md) — **kerjakan ini**, bukan opsional
- [Aturan format media](docs/media-guidelines.md) — apa yang bisa dan tidak bisa diputar
- [Upload media](docs/upload-media.md) — Cyberduck atau rclone, macOS dan Windows
- [Menghubungkan device](docs/client-setup.md) — alamat apa yang dimasukkan di app Jellyfin
- [Runbook operasional](docs/operations.md) — saat ada yang rusak

## Skrip

| Skrip | Fungsi |
|---|---|
| [scripts/bootstrap.sh](scripts/bootstrap.sh) | Provisioning satu perintah. Idempoten. `--dry-run` untuk mengintip. |
| [scripts/preflight.sh](scripts/preflight.sh) | Validasi tanpa mengubah apa pun. |
| [scripts/add-client.sh](scripts/add-client.sh) | Daftarkan device baru ke WireGuard, cetak QR code. |
| [scripts/refresh-library.sh](scripts/refresh-library.sh) | Membuat file yang baru diupload langsung muncul. |
| [scripts/healthcheck.sh](scripts/healthcheck.sh) | Mount, container, disk, sampai mana bootstrap berhasil. |
| [scripts/debug-mount.sh](scripts/debug-mount.sh) | Saat rclone-b2 gagal start: memunculkan alasan sesungguhnya. |
| [scripts/quota-check.sh](scripts/quota-check.sh) | Pemakaian bandwidth bulan ini. |

## Konfigurasi

Semua parameter ada di [.env.example](.env.example) — satu sumber kebenaran,
divalidasi otomatis oleh test suite.

## Pengembangan

    bash tests/run.sh
    shellcheck -x scripts/*.sh scripts/lib/*.sh tests/run.sh

Seluruh suite berjalan di laptop tanpa server.

## Desain

- [Design spec](docs/superpowers/specs/2026-08-20-jellyfin-b2-design.md) — keputusan dan alasannya
- [Implementation plan](docs/superpowers/plans/2026-08-20-jellyfin-b2-setup.md) — langkah demi langkah
