# Upload Media ke Backblaze B2

Berlaku untuk **macOS dan Windows**. Alurnya identik; hanya cara memasang
aplikasinya yang berbeda.

## Kenapa bukan web UI Backblaze

Web UI B2 dibatasi **500 MB per file** dan tidak mendukung upload folder.
Film 1080p biasanya 2–8 GB, jadi lewat browser secara harfiah tidak mungkin.
Ini batasan resmi Backblaze, bukan bug.

## Kenapa ini tidak memakan kuota VPS

```
Upload:  PC kamu ──────────────▶ B2         VPS tidak terlibat
Stream:  B2 ──▶ VPS ──▶ penonton            ini yang pakai kuota
```

Aplikasi di bawah bicara **langsung** ke Backblaze. VPS tidak berada di jalur
upload, jadi kuota 512 GB/bulan sama sekali tidak tersentuh. Backblaze juga
tidak menagih biaya upload — hanya penyimpanan dan unduhan.

## Kunci yang dipakai

Gunakan application key yang **bisa menulis** — yang kamu beri nama
`cyberduck-upload` saat setup. **Bukan** kunci read-only milik server.

Pemisahan ini disengaja: kalau VPS suatu saat dibobol, kuncinya tidak bisa
dipakai menghapus library. Kunci tulis hanya ada di komputermu.

Kamu butuh dua nilai:

| Nilai | Bentuknya |
|---|---|
| `keyID` / Application Key ID | `0053f1a2b3c4d5e0000000001` |
| `applicationKey` | `K005abc123def456ghi789jkl012mno345` |

Kalau `applicationKey` sudah hilang — Backblaze hanya menampilkannya sekali —
buat kunci baru, tidak bisa dilihat ulang.

---

# Cara 1 — Cyberduck (GUI, disarankan)

Drag-and-drop seperti Finder atau File Explorer. Gratis.

## Pasang

**macOS**

```bash
brew install --cask cyberduck
```

Atau unduh dari [cyberduck.io](https://cyberduck.io) kalau tidak pakai Homebrew.

**Windows** — unduh installer dari [cyberduck.io](https://cyberduck.io).

## Sambungkan (sekali saja)

1. **Open Connection**
2. Pilih **Backblaze B2** dari dropdown paling atas
3. Isi:
   - *Account ID or Application Key ID* → `keyID` milikmu
   - *Application Key* → `applicationKey` milikmu
4. **Connect**
5. Setelah masuk, **Bookmark → New Bookmark** supaya tidak perlu diisi lagi

## Upload

1. Buka bucket-mu, masuk ke folder `Movies` atau `Shows`
2. Drag folder judulnya dari Finder/Explorer ke jendela Cyberduck
3. Tunggu selesai — upload yang terputus bisa dilanjutkan, tidak mulai dari nol

---

# Cara 2 — rclone (CLI, untuk upload banyak)

Lebih cepat untuk puluhan file sekaligus, bisa di-resume, dan bisa
diulang tanpa mengunggah ulang yang sudah ada. Konsepnya sama persis dengan
yang dipakai server — hanya arahnya terbalik.

## Pasang

**macOS**

```bash
brew install rclone
```

**Windows** (PowerShell sebagai Administrator)

```powershell
winget install Rclone.Rclone
```

## Konfigurasi

Buat file config langsung, lebih cepat daripada wizard interaktif.

**macOS**

```bash
mkdir -p ~/.config/rclone
cat > ~/.config/rclone/rclone.conf <<'CFG'
[b2]
type = b2
account = GANTI_DENGAN_KEY_ID
key = GANTI_DENGAN_APPLICATION_KEY
hard_delete = false
CFG
chmod 600 ~/.config/rclone/rclone.conf
```

**Windows** — buat file `%APPDATA%\rclone\rclone.conf` dengan isi yang sama.

Uji:

```bash
rclone lsd b2:
```

Bucket-mu harus muncul di daftar.

## Upload

```bash
rclone copy "Interstellar (2014)" "b2:NAMA_BUCKET/Movies/Interstellar (2014)" \
  --progress --transfers 4 --fast-list
```

`copy` hanya mengirim yang belum ada di tujuan, jadi aman dijalankan ulang
kalau koneksi putus di tengah.

Untuk mengunggah seluruh folder film sekaligus:

```bash
rclone copy ~/Movies "b2:NAMA_BUCKET/Movies" --progress --transfers 4 --fast-list
```

**Jangan pakai `sync`.** `sync` membuat tujuan sama persis dengan sumber —
artinya file di B2 yang tidak ada di komputermu akan **dihapus**. `copy`
tidak pernah menghapus apa pun.

---

# Struktur folder

Jellyfin mengenali judul dari nama folder dan file. Aturan lengkapnya ada di
[media-guidelines.md](media-guidelines.md); ringkasnya:

```
Movies/
  Interstellar (2014)/
    Interstellar (2014).mkv
    Interstellar (2014).id.srt

Shows/
  Severance (2022)/
    Season 01/
      Severance (2022) S01E01.mkv
```

Tiga hal yang sering salah:

- **Tahun dalam kurung wajib.** Tanpa itu pencocokan metadata sering meleset
  ke film lain berjudul mirip.
- **Satu folder = satu judul.** Dua video dalam satu folder di library
  bertipe *Movies* akan dibaca sebagai dua versi dari judul yang sama.
- **Rapikan sebelum upload.** Memindahkan file di B2 setelah terunggah jauh
  lebih repot daripada merapikannya di komputer.

Kamu mungkin melihat file `.bzEmpty` muncul di dalam folder. Itu penanda
buatan Backblaze — B2 tidak punya folder sungguhan, jadi file kosong dibuat
agar foldernya terlihat. Jellyfin mengabaikannya.

---

# Setelah upload

```bash
ssh root@IP_VPS 'cd /opt/jellyfin-b2 && ./scripts/refresh-library.sh'
```

Ini memaksa rclone di server membaca ulang daftar folder, lalu memicu scan
Jellyfin. Tanpa perintah ini file tetap muncul sendiri dalam beberapa jam
lewat scan terjadwal — skrip ini hanya mempercepat.

# Perkiraan waktu

Yang membatasi adalah kecepatan **upload** internet rumahmu, bukan Backblaze.
Cek di speedtest — angka upload, bukan download.

| Upload rumah | Film 4 GB | Film 8 GB |
|---|---|---|
| 5 Mbps | ~1 jam 50 menit | ~3 jam 40 menit |
| 10 Mbps | ~55 menit | ~1 jam 50 menit |
| 20 Mbps | ~27 menit | ~55 menit |
| 50 Mbps | ~11 menit | ~22 menit |

Untuk unggahan besar, jalankan `rclone copy` di terminal yang dibiarkan
terbuka dan tinggalkan semalam. Kalau putus, jalankan lagi perintah yang
sama — yang sudah terkirim tidak diulang.
