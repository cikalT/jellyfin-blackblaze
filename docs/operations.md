# Runbook Operasional

## Perintah harian

    ./scripts/healthcheck.sh        # mount, container, disk
    ./scripts/quota-check.sh        # pemakaian bandwidth bulan ini
    ./scripts/refresh-library.sh    # setelah upload file baru

## Mount hilang atau library terlihat kosong

    systemctl status rclone-b2
    journalctl -u rclone-b2 -n 50 --no-pager

Penyebab paling umum, berurutan:

1. **Kredensial B2 kedaluwarsa atau dicabut.** Log akan menampilkan 401.
   Buat application key baru, perbarui `/etc/rclone/rclone.conf`,
   lalu `systemctl restart rclone-b2`.
2. **Mount ada tapi container melihat kosong.** Ini kegagalan propagasi.
   Pastikan `propagation: rslave` masih ada di `docker-compose.yml`, lalu
   `docker compose up -d --force-recreate`.
3. **rclone dimatikan OOM killer.** `journalctl -k | grep -i oom`.
   Turunkan `--buffer-size` di unit systemd.

## Tidak ada device yang bisa connect

    sudo wg show

Kolom *latest handshake* per peer adalah diagnosis tercepat:

- **Kosong untuk semua peer** → UDP 51820 tertutup di security group Tencent,
  atau `wg-quick@wg0` mati. Cek `systemctl status wg-quick@wg0`.
- **Kosong untuk satu peer saja** → config device itu salah; buat ulang
  dengan `./scripts/add-client.sh <nama>` memakai nama baru.
- **Handshake ada tapi Jellyfin tidak merespons** → tunnel sehat, masalahnya
  di Jellyfin. Jalankan `./scripts/healthcheck.sh`.

Kalau interface-nya sendiri tidak mau naik:

    journalctl -u wg-quick@wg0 -n 30 --no-pager

Penyebab paling umum: `wg0.conf` rusak karena diedit manual. Blok `[Peer]`
yang tidak lengkap membuat seluruh interface gagal start, bukan cuma peer itu.

## Disk penuh

    df -h /
    du -sh /var/cache/rclone /opt/jellyfin/*

Cache VFS punya batas keras dan membersihkan dirinya sendiri. Kalau disk
tetap penuh, tersangkanya biasanya metadata Jellyfin — periksa apakah
trickplay atau chapter image ternyata aktif (`jellyfin-settings.md`),
lalu hapus isinya:

    docker compose down
    rm -rf /opt/jellyfin/cache/*
    docker compose up -d

## Kuota bandwidth hampir habis

    ./scripts/quota-check.sh

Tidak ada throttling otomatis — keputusan ada padamu. Pilihan:
turunkan *Internet streaming bitrate limit* per user, atau berhenti menonton
sampai bulan berikutnya. Kalau kuota habis, Tencent biasanya menurunkan
kecepatan drastis, bukan memutus koneksi.

## Pemutaran buffering

Buka **Dashboard → Activity** saat sedang memutar.

- Tertulis **Transcode** atau **Remux** → filenya melanggar
  `media-guidelines.md`. Perbaiki filenya.
- Tertulis **Direct Play** tapi tetap buffering → bitrate file melebihi
  20 Mbps yang tersedia, atau ada stream kedua yang berjalan.

## Upgrade Jellyfin

    # 1. Snapshot dulu lewat panel Tencent.
    # 2. Ubah JELLYFIN_IMAGE di .env ke versi baru.
    docker compose pull && docker compose up -d
    ./scripts/healthcheck.sh

Rollback: kembalikan `JELLYFIN_IMAGE` ke versi lama, `docker compose up -d`.
Jangan pernah memakai tag `:latest` — itu membuat rollback mustahil, dan
`preflight.sh` memang menolaknya.

## Setelah reboot VPS

Seharusnya tidak perlu apa-apa. Docker sengaja diurutkan setelah mount,
jadi keduanya hidup dengan urutan yang benar. Verifikasi:

    ./scripts/healthcheck.sh

Kalau Docker tidak start, biasanya karena mount gagal — itu perilaku yang
disengaja. Perbaiki mount-nya dulu, Docker akan menyusul.
