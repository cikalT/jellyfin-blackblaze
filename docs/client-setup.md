# Menghubungkan Device ke Jellyfin

**Tanpa login, tanpa akun, tanpa langganan.** WireGuard tidak punya konsep
akun sama sekali. Kamu buat satu config per device, scan sekali, selesai —
tidak ada sesi yang kedaluwarsa dan tidak ada yang perlu di-login ulang.

## Sebelum device pertama

Buka **UDP 51820** di security group VPS Tencent. Tanpa ini tidak ada satu
pun client yang bisa menyambung.

Ini lebih aman daripada terdengar: WireGuard tidak membalas paket yang tidak
membawa kunci sah — bagi pemindai port, port itu tampak tertutup. Sangat
berbeda dengan mengekspos halaman login HTTP yang akan langsung jadi sasaran
bot.

## Menambahkan device

Di VPS, satu perintah per device:

    sudo ./scripts/add-client.sh hp
    sudo ./scripts/add-client.sh laptop
    sudo ./scripts/add-client.sh tablet

Nama bebas, asal huruf kecil, angka, dan tanda hubung. Skrip akan:

1. Memilih alamat bebas berikutnya di tunnel (`10.8.0.2`, `.3`, `.4`, ...)
2. Membuat pasangan kunci khusus device itu
3. Mendaftarkannya ke server **tanpa memutus** device lain yang sedang menonton
4. Mencetak QR code dan menyimpan file `.conf`

## Memasang di device

Install app WireGuard resmi — [wireguard.com/install](https://www.wireguard.com/install/).
Tersedia untuk Windows, macOS, Linux, iOS, dan Android.

**HP / tablet:** buka app → **+** → *Scan from QR code* → arahkan ke QR yang
tercetak di terminal. Beri nama, aktifkan togglenya. Selesai.

**Laptop:** salin file `.conf` dari `/etc/wireguard/clients/<nama>.conf` ke
laptop, lalu di app WireGuard pilih *Import tunnel from file*.

    scp root@<ip-vps>:/etc/wireguard/clients/laptop.conf .

File itu berisi kunci privat device — perlakukan seperti password.

## Membuka Jellyfin

Aktifkan tunnel, lalu buka:

    http://10.8.0.1:8096

**Awalan `http://` harus diketik lengkap.** Chrome otomatis menaikkan alamat
yang kamu ketik ke `https://`, dan Jellyfin di sini melayani HTTP polos.
Gejalanya: *"This site can't provide a secure connection — 10.8.0.1 sent an
invalid response"*. Itu bukan kerusakan — justru bukti tunnel-mu sudah jalan
dan server menjawab.

Kalau Chrome tetap memaksa: **Settings → Privacy and security → Always use
secure connections → matikan**.

Lebih baik lagi, **pakai app Jellyfin, bukan browser.** Di layar *Add Server*
isi `http://10.8.0.1:8096`. App-nya tidak memaksa HTTPS, dan pemutarannya
jauh lebih baik.

### Membedakan dua error yang mirip

| Pesan browser | Artinya |
|---|---|
| *took too long to respond* | Paket tidak sampai. Tunnel atau firewall. |
| *sent an invalid response* / *can't provide a secure connection* | Paket **sampai** dan dijawab. Tunnel sehat, kamu cuma salah skema — pakai `http://`. |

Alamat ini **tidak pernah berubah** — tidak peduli kamu di rumah, di kantor,
atau pakai data seluler. Masukkan alamat yang sama di app Jellyfin sebagai
server address.

Tanpa HTTPS memang disengaja. WireGuard sudah mengenkripsi seluruh trafik
di dalam tunnel, jadi menambahkan TLS di atasnya hanya menambah sertifikat
yang harus diurus tanpa menambah keamanan.

## Kenapa split tunnel — jangan diubah

Config yang dihasilkan berisi baris ini:

    AllowedIPs = 10.8.0.0/24

Artinya **hanya** trafik menuju VPS yang lewat tunnel. Browsing, YouTube,
WhatsApp — semuanya tetap lewat koneksi normalmu.

Kalau kamu menggantinya jadi `0.0.0.0/0`, seluruh internetmu akan mengalir
lewat VPS. Efeknya: kuota 512 GB/bulan habis untuk hal yang bukan menonton,
dan semua browsing dibatasi 20 Mbps. Jangan diubah kecuali kamu memang
sengaja ingin memakai VPS ini sebagai VPN penuh — dan sadar konsekuensinya.

## Jika tidak bisa terhubung

| Gejala | Penyebab biasanya |
|---|---|
| Handshake tidak pernah terjadi | UDP 51820 belum dibuka di security group Tencent |
| Terhubung, tapi `10.8.0.1` tidak merespons | Jellyfin belum jalan — cek `./scripts/healthcheck.sh` di VPS |
| Jalan di rumah, mati di seluler | Operator memblokir UDP. Coba ganti `WG_PORT` ke 443 lalu jalankan ulang bootstrap |
| Tunnel mati sendiri saat HP idle | `PersistentKeepalive` hilang dari config — buat ulang dengan `add-client.sh` |
| Browsing jadi lambat setelah connect | `AllowedIPs` berubah jadi `0.0.0.0/0` — lihat bagian di atas |

Cek dari sisi server siapa yang sedang terhubung:

    sudo wg show

Kolom *latest handshake* menunjukkan kapan terakhir device itu aktif. Kalau
kosong, device itu belum pernah berhasil menyambung sama sekali.

## Menghapus device

Hilang HP? Buka `/etc/wireguard/wg0.conf`, hapus blok `[Peer]` yang
berkomentar nama device itu, lalu:

    sudo wg syncconf wg0 <(wg-quick strip wg0)
    sudo rm /etc/wireguard/clients/hp.conf

Device itu langsung kehilangan akses. Device lain tidak terganggu.
