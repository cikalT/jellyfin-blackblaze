# Menghubungkan Device ke Jellyfin

Tidak ada IP yang perlu diingat, tidak ada port forwarding, tidak ada DDNS.
Tailscale memberi server ini nama tetap yang berfungsi dari mana saja —
rumah, kantor, data seluler, Wi-Fi hotel.

## Sekali per device

1. Install Tailscale:
   - Android: Play Store
   - iOS / iPadOS: App Store
   - Windows / macOS / Linux: https://tailscale.com/download
2. **Login dengan akun yang sama** dengan yang dipakai di VPS. Ya, tiap
   device harus login — itulah cara Tailscale tahu device mana milikmu.
   Bisa pakai Google, GitHub, Microsoft, Apple, atau email.
3. Aktifkan. Device dapat alamat `100.x.x.x` dan langsung bisa melihat server.

Paket gratis Tailscale mencakup 100 device dan 3 user — jauh lebih dari cukup.

## Sekali per app Jellyfin

Buka app Jellyfin, pilih **Add Server**, isi alamatnya:

    https://jellyfin.<nama-tailnet>.ts.net

Nama persisnya bisa dilihat di VPS dengan `tailscale serve status`, atau di
admin console Tailscale. Alamat ini tidak pernah berubah — tidak perlu
diperbarui saat kamu pindah jaringan atau saat IP VPS berganti.

Login dengan user Jellyfin, lalu selesai. App akan mengingat servernya.

## WAJIB: matikan key expiry di server

Secara default, kunci device Tailscale kedaluwarsa setiap **180 hari**. Kalau
itu terjadi pada VPS, server lepas dari tailnet tanpa peringatan dan Jellyfin
mendadak tidak bisa diakses dari mana pun — satu-satunya jalan adalah SSH ke
server dan login ulang.

Matikan sekali, permanen:

**Admin console Tailscale → Machines → pilih `jellyfin` → menu ⋯ →
Disable key expiry**

Untuk HP dan laptop, expiry 180 hari tidak masalah — login ulang di device
yang ada layarnya itu mudah. Yang berbahaya hanya di server.

## Login di VPS yang headless

Server tidak punya browser, jadi ada dua cara:

    # Interaktif — mencetak URL, buka di browser mana pun untuk otorisasi
    sudo tailscale up --hostname=jellyfin

    # Auth key — dibuat dulu di admin console (Settings -> Keys)
    sudo tailscale up --hostname=jellyfin --authkey=tskey-auth-xxxxx

## Kenapa tidak pakai IP

MagicDNS memetakan `jellyfin.<tailnet>.ts.net` ke alamat tailnet server
secara otomatis. Memakai IP `100.x.x.x` mentah juga bisa, tapi sertifikat
TLS diterbitkan untuk nama DNS-nya — pakai IP dan kamu akan dapat peringatan
sertifikat. Selalu pakai nama.

## Jika tidak bisa terhubung

| Gejala | Penyebab biasanya |
|---|---|
| Tailscale menyala tapi server tidak terlihat | Device login ke akun/tailnet berbeda |
| Server hilang setelah beberapa bulan | Key expiry — lihat bagian di atas |
| Nama tidak me-resolve | MagicDNS mati di admin console Tailscale |
| Peringatan sertifikat | Memakai IP, bukan nama `.ts.net` |
| Terhubung tapi pemutaran lambat | Tailscale jatuh ke relay DERP, bukan koneksi langsung |

Baris terakhir itu penting: koneksi lewat relay DERP jauh lebih lambat dan
akan merusak pemutaran. Cek dengan `tailscale status` — kalau tertulis
"relay", pastikan **UDP 41641** diizinkan masuk di security group Tencent
supaya Tailscale bisa membangun koneksi langsung.

## Batasan device

| Device | Status |
|---|---|
| Windows, macOS, Linux, iOS, Android | App resmi |
| Apple TV (tvOS 17+) | App resmi |
| Android TV, Fire TV, Nvidia Shield | Pakai app Android |
| Smart TV Samsung (Tizen) dan LG (webOS) | **Tidak didukung** — tidak ada client Tailscale untuk platform ini |

Kalau nanti butuh menonton di TV Samsung/LG, jalan termudah adalah menambah
streaming box (Apple TV atau Fire TV) daripada mengekspos Jellyfin ke
internet.
