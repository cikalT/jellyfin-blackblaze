# shellcheck shell=bash
# Diuji: dokumen wajib ada dan memuat fakta yang paling mudah dilupakan.

ROOT="$(cd .. && pwd)"

for f in README.md docs/jellyfin-settings.md docs/media-guidelines.md \
         docs/upload-windows.md docs/client-setup.md docs/operations.md; do
  assert_ok "$f ada" "[[ -f '$ROOT/$f' ]]"
done

# Checklist setting adalah dokumen paling penting di repo. Setiap item yang
# dimatikan ada karena satu alasan mahal; kalau salah satunya hilang dari
# checklist, orang berikutnya tidak akan tahu harus mematikannya.
if [[ -f "$ROOT/docs/jellyfin-settings.md" ]]; then
  _s="$(cat "$ROOT/docs/jellyfin-settings.md")"
  for term in Trickplay "chapter" "real time monitoring" "transcoding" "DLNA" "8 Mbps"; do
    assert_contains "checklist setting menyebut '$term'" "$_s" "$term"
  done
fi

# Panduan upload harus menyebutkan batas 500 MB — inilah alasan seluruh
# rencana upload awal diganti, dan tanpa itu orang akan mencoba web UI lagi.
if [[ -f "$ROOT/docs/upload-windows.md" ]]; then
  _u="$(cat "$ROOT/docs/upload-windows.md")"
  assert_contains "panduan upload menjelaskan batas 500 MB" "$_u" "500 MB"
  assert_contains "panduan upload menyebut Cyberduck"       "$_u" "Cyberduck"
fi

# Aturan format media adalah kontrak dengan pengguna; harus eksplisit.
if [[ -f "$ROOT/docs/media-guidelines.md" ]]; then
  _m="$(cat "$ROOT/docs/media-guidelines.md")"
  for term in "H.264" "AAC" "SRT" "HEVC"; do
    assert_contains "panduan media menyebut '$term'" "$_m" "$term"
  done

  # Aturan penamaan yang BENAR-BENAR mengikat. Nama folder teratas bebas —
  # yang menentukan pencocokan metadata adalah struktur di dalam tiap judul.
  # Kalau salah satu dari ini hilang dari dokumen, orang akan mengupload
  # dengan struktur yang tidak dikenali Jellyfin.
  assert_contains "panduan media menjelaskan penanda season/episode" "$_m" "S01E01"
  assert_contains "panduan media menjelaskan subfolder season"       "$_m" "Season 01"
  assert_contains "panduan media mewajibkan tahun dalam kurung"      "$_m" "(2014)"
  # Dan harus eksplisit bahwa folder teratas TIDAK mengikat, supaya tidak
  # ada lagi yang mengira 'Movies/' itu keharusan.
  assert_contains "panduan media menyatakan folder teratas bebas"    "$_m" "Folder teratas: bebas"
fi

# Panduan client harus menjawab pertanyaan pertama setiap orang: alamat apa
# yang saya masukkan? Jawabannya IP tetap di dalam tunnel.
if [[ -f "$ROOT/docs/client-setup.md" ]]; then
  _c="$(cat "$ROOT/docs/client-setup.md")"
  assert_contains "panduan client memberi alamat Jellyfin"    "$_c" "10.8.0.1:8096"
  # Inilah alasan WireGuard dipilih menggantikan Tailscale.
  assert_contains_i "panduan client menegaskan tanpa login"   "$_c" "tanpa login"
  # Split tunnel harus dijelaskan: kalau pengguna mengubahnya jadi 0.0.0.0/0
  # sendiri, seluruh browsing mengalir lewat kuota 512 GB VPS.
  assert_contains_i "panduan client menjelaskan split tunnel" "$_c" "split tunnel"
  assert_contains "panduan client memperingatkan 0.0.0.0/0"   "$_c" "0.0.0.0/0"
  # Tanpa port terbuka, tidak ada satu pun client yang bisa menyambung.
  assert_contains "panduan client menyebut UDP 51820"         "$_c" "51820"
  assert_contains "panduan client menyebut cara tambah device" "$_c" "add-client.sh"
  # Tidak boleh ada sisa instruksi Tailscale yang menyesatkan.
  assert_fail "tidak ada sisa instruksi Tailscale" "grep -qi 'tailscale' '$ROOT/docs/client-setup.md'"
fi

# Setiap file yang ditautkan README harus benar-benar ada.
if [[ -f "$ROOT/README.md" ]]; then
  _missing=""
  while IFS= read -r link; do
    [[ -e "$ROOT/$link" ]] || _missing="$_missing $link"
  done < <(grep -oE '\]\((docs/[^)]+|scripts/[^)]+|\.env\.example)\)' "$ROOT/README.md" \
           | sed -e 's/^](//' -e 's/)$//')
  assert_eq "tautan README semuanya valid" "$_missing" ""
fi
