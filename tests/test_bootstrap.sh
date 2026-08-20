# shellcheck shell=bash
# Diuji: scripts/bootstrap.sh

ROOT="$(cd .. && pwd)"
BS="$ROOT/scripts/bootstrap.sh"

assert_ok "bootstrap.sh ada"        "[[ -f '$BS' ]]"
assert_ok "bootstrap.sh executable" "[[ -x '$BS' ]]"

if [[ -f "$BS" ]]; then
  _b="$(cat "$BS")"

  # Idempotensi: setiap langkah destruktif atau instalasi harus dijaga
  # pemeriksaan. Menjalankan bootstrap dua kali harus aman.
  assert_contains "swapfile dijaga pemeriksaan"  "$_b" "swapon --show"
  assert_contains "instalasi docker dijaga"      "$_b" "command -v docker"
  assert_contains "instalasi rclone dijaga"      "$_b" "command -v rclone"
  assert_contains "instalasi tailscale dijaga"   "$_b" "command -v tailscale"

  # Rahasia yang ditulis ke disk harus dikunci.
  assert_contains "chmod 600 untuk file rahasia" "$_b" "chmod 600"

  # Bootstrap harus menolak berjalan kalau preflight gagal.
  assert_contains "memanggil preflight"          "$_b" "preflight.sh"

  # tailscale up butuh autentikasi interaktif — bootstrap harus memandu,
  # bukan mencoba dan gagal secara membingungkan.
  assert_contains "memandu tailscale up"         "$_b" "tailscale up"
fi

# --dry-run tidak boleh mengubah apa pun dan harus keluar dengan status 0,
# bahkan sebagai user biasa di laptop.
if [[ -x "$BS" ]]; then
  _env="$(mktemp)"
  cp "$ROOT/.env.example" "$_env"
  sed -i.bak -e 's/^B2_ACCOUNT_ID=.*/B2_ACCOUNT_ID=005test/' \
             -e 's/^B2_APPLICATION_KEY=.*/B2_APPLICATION_KEY=Ktest/' \
             -e 's/^B2_BUCKET=.*/B2_BUCKET=test-bucket/' "$_env"

  _out="$( "$BS" --dry-run --env-file "$_env" 2>&1 || true )"
  assert_contains "dry-run menandai aksinya"   "$_out" "[dry-run]"
  assert_ok       "dry-run keluar bersih"      "'$BS' --dry-run --env-file '$_env'"
  assert_fail     "dry-run tidak membuat /etc/jellyfin-b2" "[[ -e /etc/jellyfin-b2 ]]"

  # Langkah berikutnya harus menampilkan hostname sungguhan, bukan nama
  # variabel mentah — kalau tidak, operator akan menyalin '$TS_HOSTNAME'
  # apa adanya ke terminal.
  assert_contains "instruksi tailscale memakai hostname sungguhan" "$_out" "--hostname=jellyfin"

  rm -f "$_env" "$_env.bak"
fi
