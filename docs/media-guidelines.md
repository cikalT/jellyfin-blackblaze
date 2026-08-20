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

Jellyfin mengenali judul dari nama folder dan file. Tahun dalam kurung wajib.

    Movies/
      Interstellar (2014)/
        Interstellar (2014).mkv
        Interstellar (2014).id.srt

    Shows/
      Severance (2022)/
        Season 01/
          Severance (2022) S01E01.mkv
          Severance (2022) S01E02.mkv

Nama file subtitle harus sama persis dengan file videonya, ditambah kode
bahasa: `.id.srt` untuk Indonesia, `.en.srt` untuk Inggris.
