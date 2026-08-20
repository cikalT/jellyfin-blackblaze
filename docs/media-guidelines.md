# Aturan Format Media

Transcoding dimatikan karena 2 vCPU tidak sanggup melakukannya. Konsekuensinya:
file yang tidak memenuhi aturan di bawah **tidak akan diputar**. Ini disengaja
— gagal terang-terangan lebih baik daripada buffering yang misterius.

## Yang wajib

| Aspek | Aman | Akan gagal |
|---|---|---|
| Container | MKV, MP4 | AVI, WMV, ISO, VIDEO_TS |
| Video | H.264 (AVC), 8-bit, High@L4.1 | HEVC/H.265, 10-bit, AV1, VC-1 |
| Audio (track pertama) | AAC stereo | DTS, DTS-HD, TrueHD, FLAC multichannel |
| Subtitle | SRT (eksternal atau embedded) | ASS/SSA, PGS, VOBSUB |
| Bitrate video | <= 8 Mbps | Remux Blu-ray 20-40 Mbps |

**Kenapa AAC stereo di track pertama:** browser dan Chromecast tidak bisa
direct-play AC3/EAC3. Track surround boleh disimpan sebagai track kedua.

**Kenapa SRT, bukan ASS:** subtitle ASS harus di-render ke gambar dan
dibakar ke video — itu transcode penuh. SRT dikirim apa adanya ke client.

**Kenapa bukan HEVC:** meski banyak client bisa memutarnya, yang tidak bisa
akan memaksa transcode dan server akan tersedak.

## Mengubah file yang tidak memenuhi syarat

Di PC Windows, dengan HandBrake atau ffmpeg:

    ffmpeg -i masukan.mkv \
      -c:v libx264 -preset slow -crf 20 -maxrate 8M -bufsize 16M \
      -pix_fmt yuv420p \
      -c:a aac -b:a 192k -ac 2 \
      -c:s srt \
      keluaran.mkv

`-pix_fmt yuv420p` memaksa 8-bit. `-ac 2` memaksa stereo.

## Struktur folder di B2

Bedakan dua lapis ini — cuma satu yang mengikat.

**Folder teratas: bebas.** `Movies/`, `film/`, `koleksi/2024/` — Jellyfin tidak
peduli. Yang penting path yang kamu isi saat membuat library cocok dengan
folder yang ada di bucket. Contoh di bawah pakai `Movies/` dan `Shows/` hanya
supaya konsisten dengan dokumen lain.

**Di dalam tiap judul: mengikat.** Dari sinilah Jellyfin mencocokkan metadata.
Salah struktur, judulnya tidak dikenali dan muncul tanpa poster, sinopsis,
atau pengelompokan season.

### Film

    <folder pilihanmu>/
      Interstellar (2014)/
        Interstellar (2014).mkv
        Interstellar (2014).id.srt

Aturannya: satu folder per film, nama folder = `Judul (Tahun)`, nama file sama
dengan nama foldernya. **Tahun dalam kurung wajib** — tanpa itu pencocokan
sering meleset ke film lain berjudul mirip.

### Serial

    <folder pilihanmu>/
      Severance (2022)/
        Season 01/
          Severance (2022) S01E01.mkv
          Severance (2022) S01E02.mkv

Aturannya: satu folder per serial, lalu subfolder `Season 01`, `Season 02`
(angka dua digit), lalu file dengan penanda `S01E01`. Penanda inilah yang
dibaca Jellyfin — teks di sekitarnya boleh apa saja, tapi konsisten lebih baik.

### Subtitle

Nama file subtitle harus **sama persis** dengan file videonya, ditambah kode
bahasa sebelum ekstensi: `.id.srt` untuk Indonesia, `.en.srt` untuk Inggris.
Beda satu karakter saja, subtitle tidak akan terdeteksi.
