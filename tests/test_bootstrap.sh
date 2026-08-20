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
  assert_contains "instalasi wireguard dijaga"   "$_b" "command -v wg"

  # Rahasia yang ditulis ke disk harus dikunci.
  assert_contains "chmod 600 untuk file rahasia" "$_b" "chmod 600"

  # Bootstrap harus menolak berjalan kalau preflight gagal.
  assert_contains "memanggil preflight"          "$_b" "preflight.sh"

  # Kunci server hanya boleh dibuat sekali. Regenerasi memutus SEMUA client
  # yang sudah terdaftar, tanpa peringatan.
  assert_contains "kunci server WireGuard dijaga" "$_b" "server.key"
  # Split tunnel: tidak boleh ada masquerade/NAT. Full tunnel akan mengalirkan
  # seluruh browsing lewat VPS dan menghabiskan kuota 512 GB.
  assert_fail "tidak ada MASQUERADE (split tunnel)" \
    "grep -vE '^[[:space:]]*#' '$BS' | grep -q 'MASQUERADE'"
  assert_fail "tidak mengaktifkan ip_forward" \
    "grep -vE '^[[:space:]]*#' '$BS' | grep -q 'ip_forward'"
fi

# --dry-run tidak boleh mengubah apa pun dan harus keluar dengan status 0,
# bahkan sebagai user biasa di laptop.
if [[ -x "$BS" ]]; then
  _env="$(mktemp)"
  cp "$ROOT/.env.example" "$_env"
  sed -i.bak -e 's/^B2_KEY_ID=.*/B2_KEY_ID=005test/' \
             -e 's/^B2_APPLICATION_KEY=.*/B2_APPLICATION_KEY=Ktest/' \
             -e 's/^B2_BUCKET=.*/B2_BUCKET=test-bucket/' \
             -e 's/^WG_ENDPOINT=.*/WG_ENDPOINT=203.0.113.10/' "$_env"

  _out="$( "$BS" --dry-run --env-file "$_env" 2>&1 || true )"
  assert_contains "dry-run menandai aksinya"   "$_out" "[dry-run]"
  assert_ok       "dry-run keluar bersih"      "'$BS' --dry-run --env-file '$_env'"
  assert_fail     "dry-run tidak membuat /etc/jellyfin-b2" "[[ -e /etc/jellyfin-b2 ]]"

  # Langkah berikutnya harus menampilkan hostname sungguhan, bukan nama
  # variabel mentah — kalau tidak, operator akan menyalin '$TS_HOSTNAME'
  # apa adanya ke terminal.
  assert_contains "langkah berikutnya menyebut add-client" "$_out" "add-client.sh"

  rm -f "$_env" "$_env.bak"
fi
