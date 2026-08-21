# Runbook Operasional

## Kalau ada yang gagal, mulai dari sini

    ./scripts/healthcheck.sh

Bagian pertama outputnya melaporkan sampai langkah berapa bootstrap
berhasil. Kalau ada yang merah di situ, itu penyebabnya — jalankan
`sudo ./scripts/bootstrap.sh` lagi (idempoten, aman diulang) dan perhatikan
di langkah mana ia berhenti.

Skrip yang dijalankan setelah bootstrap (`add-client.sh`, `quota-check.sh`)
akan menolak jalan dengan pesan yang menunjuk ke sini, bukan sekadar
"perintah tidak ditemukan".

## Perintah harian

    ./scripts/healthcheck.sh        # mount, container, disk
    ./scripts/quota-check.sh        # pemakaian bandwidth bulan ini
    ./scripts/refresh-library.sh    # setelah upload file baru

## rclone-b2 gagal start: "address already in use"

Penyebab paling umum, dan pesannya terkubur. systemd hanya menampilkan
"control process exited with error code"; alasan sesungguhnya ada di log:

    CRITICAL: Failed to start remote control: failed to init server:
    listen tcp 127.0.0.1:5572: bind: address already in use

Artinya ada proses rclone yatim yang masih memegang port RC. Ini terjadi
karena `fusermount3 -uz` adalah *lazy unmount*: mount-nya lepas seketika,
tapi prosesnya tidak ikut mati. Jadi mount hilang — healthcheck melaporkan
"tidak ter-mount" — sementara portnya tetap dipegang.

    systemctl stop rclone-b2
    pkill -f 'rclone[ ]mount'
    sleep 2
    ss -tlnp | grep 5572          # harus kosong
    systemctl start rclone-b2

Kurung siku di pola `pkill` bukan hiasan: tanpa itu, perintah pkill cocok
dengan dirinya sendiri.

Unit sekarang membersihkan ini sendiri lewat `ExecStartPre`, jadi kasus ini
seharusnya tidak terulang. Kalau masih terjadi, berarti ada rclone yang
dijalankan di luar systemd.

## Mount hilang atau rclone-b2 gagal start

    ./scripts/debug-mount.sh

Ini memunculkan alasan sesungguhnya, bukan sekadar "control process exited
with error code". Yang dilakukannya, berurutan:

1. Memeriksa prasyarat FUSE — `/dev/fuse`, `fusermount3`, `user_allow_other`
2. Menguji akses B2 **tanpa mount**, sehingga kegagalan kredensial terpisah
   jelas dari kegagalan FUSE — dari luar keduanya terlihat sama
3. Menjalankan perintah mount **yang diambil dari unit terpasang** di
   foreground dengan `-vv`, selama 20 detik

Langkah 3 penting: perintahnya dibaca dari `/etc/systemd/system/rclone-b2.service`,
bukan ditulis ulang di dalam skrip. Menyalinnya berarti skrip bisa menguji
perintah yang berbeda dari yang sungguhan dijalankan systemd.

Kalau rclone bertahan 20 detik tanpa keluar, mount-nya sehat dan masalahnya
ada di systemd — barulah lihat log:

    systemctl status rclone-b2 --no-pager -l
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

## Tidak ada paket yang sampai ke server

Diagnosis tercepat, dua sisi sekaligus:

    timeout 30 tcpdump -ni any udp port 51820

Sambil itu berjalan, lihat baris **Transfer** di app WireGuard HP:

| tcpdump | app HP | Artinya |
|---|---|---|
| 0 paket | `sent` bertambah | HP mengirim, paket dibuang **sebelum** sampai VM. Firewall cloud. |
| 0 paket | `sent` tetap 0 | HP tidak mengirim. Tunnel tidak benar-benar aktif. |
| ada paket | `received` tetap 0 | Paket masuk tapi balasan tidak kembali. Routing di sisi server. |

Kombinasi pertama adalah yang paling sering, dan hampir selalu berarti
aturan UDP dibuat di *firewall template* Lighthouse, bukan di firewall
instance-nya. Lihat `setup-walkthrough.md` bagian 2.

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
