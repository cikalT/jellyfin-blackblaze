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
fi

# Panduan client harus menjawab pertanyaan pertama setiap orang: alamat apa
# yang saya masukkan? Jawabannya nama MagicDNS, bukan IP.
if [[ -f "$ROOT/docs/client-setup.md" ]]; then
  _c="$(cat "$ROOT/docs/client-setup.md")"
  assert_contains "panduan client menyebut MagicDNS"          "$_c" "MagicDNS"
  assert_contains "panduan client memberi contoh URL ts.net"  "$_c" ".ts.net"
  assert_contains "panduan client menyebut batasan smart TV"  "$_c" "webOS"
  # Kunci device Tailscale kedaluwarsa 180 hari secara default. Kalau itu
  # terjadi di VPS, Jellyfin hilang dari tailnet tanpa peringatan.
  assert_contains "panduan client memperingatkan key expiry"  "$_c" "key expiry"
  assert_contains "panduan client menyebut jangka 180 hari"   "$_c" "180 hari"
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
