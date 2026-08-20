# shellcheck shell=bash
# Diuji: scripts/add-client.sh, dengan `wg` dan `qrencode` palsu di PATH.
#
# Nilai palsu di bawah sengaja TIDAK menyerupai kunci WireGuard sungguhan.
# Base64 44-karakter setelah "PrivateKey =" akan dilaporkan pemindai rahasia
# sebagai kebocoran, meski isinya jelas dummy — dan repo yang rutin memicu
# alarm palsu melatih orang mengabaikan alarm sungguhan.
# Skripnya hanya meneruskan string ini apa adanya, jadi bentuknya bebas.

ROOT="$(cd .. && pwd)"
AC="$ROOT/scripts/add-client.sh"

assert_ok "add-client.sh ada"        "[[ -f '$AC' ]]"
assert_ok "add-client.sh executable" "[[ -x '$AC' ]]"

_stubdir() {
  local d; d="$(mktemp -d)"
  cat > "$d/wg" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  genkey) echo "FAKE-CLIENT-PRIVATE-FOR-TESTS-ONLY" ;;
  pubkey) cat >/dev/null; echo "FAKE-CLIENT-PUBLIC-FOR-TESTS-ONLY" ;;
  genpsk) echo "FAKE-PRESHARED-FOR-TESTS-ONLY" ;;
  *) exit 0 ;;
esac
STUB
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/qrencode"
  chmod +x "$d/wg" "$d/qrencode"
  printf '%s' "$d"
}

_mkenv() {
  local f; f="$(mktemp)"
  cat > "$f" <<'ENVF'
WG_INTERFACE=wg0
WG_PORT=51820
WG_SUBNET=10.8.0.0/24
WG_SERVER_IP=10.8.0.1
WG_ENDPOINT=203.0.113.10
WG_CLIENT_DIR=/tmp/wg-clients-test
JELLYFIN_PORT=8096
ENVF
  printf '%s' "$f"
}

# Server conf dengan dua peer terpakai: .2 dan .3
_mkwgconf() {
  local f; f="$(mktemp)"
  cat > "$f" <<'WGC'
[Interface]
Address = 10.8.0.1/24
ListenPort = 51820
PrivateKey = FAKE-SERVER-PRIVATE-FOR-TESTS-ONLY

[Peer]
# hp
PublicKey = FAKE-PEER-1-FOR-TESTS-ONLY
AllowedIPs = 10.8.0.2/32

[Peer]
# laptop
PublicKey = FAKE-PEER-2-FOR-TESTS-ONLY
AllowedIPs = 10.8.0.3/32
WGC
  printf '%s' "$f"
}

_mkpub() { local f; f="$(mktemp)"; printf 'FAKE-SERVER-PUBLIC-FOR-TESTS-ONLY\n' > "$f"; printf '%s' "$f"; }

if [[ -x "$AC" ]]; then
  _d="$(_stubdir)"; _env="$(_mkenv)"; _wgc="$(_mkwgconf)"; _pub="$(_mkpub)"
  _run() { PATH="$_d:$PATH" "$AC" "$@" --env-file "$_env" --wg-conf "$_wgc" --server-pub "$_pub" --dry-run 2>&1; }

  _out="$(_run tablet || true)"

  # Alokasi IP: .2 dan .3 terpakai, jadi berikutnya harus .4
  assert_contains "mengalokasikan IP bebas berikutnya" "$_out" "Address = 10.8.0.4/32"

  # SPLIT TUNNEL. Ini baris paling penting di seluruh config client:
  # kalau jadi 0.0.0.0/0, seluruh browsing pengguna mengalir lewat VPS dan
  # kuota 512 GB habis untuk hal yang bukan menonton.
  assert_contains "client memakai split tunnel"        "$_out" "AllowedIPs = 10.8.0.0/24"
  assert_fail     "client BUKAN full tunnel"           "printf '%s' '$_out' | grep -q '0\.0\.0\.0/0'"

  assert_contains "endpoint memakai IP publik + port"  "$_out" "Endpoint = 203.0.113.10:51820"
  assert_contains "memakai kunci publik server"        "$_out" "FAKE-SERVER-PUBLIC-FOR-TESTS-ONLY"
  assert_contains "memakai preshared key"              "$_out" "PresharedKey"
  # Client mobile di belakang NAT butuh ini, kalau tidak tunnel mati saat idle.
  assert_contains "keepalive diset"                    "$_out" "PersistentKeepalive"
  # Alamat Jellyfin harus ikut tercetak — itu satu-satunya hal yang
  # sebenarnya ingin diketahui pengguna setelah scan QR.
  assert_contains "mencetak alamat Jellyfin"           "$_out" "10.8.0.1:8096"

  # dry-run tidak boleh menyentuh file server
  _before="$(md5 -q "$_wgc" 2>/dev/null || md5sum "$_wgc" | cut -d' ' -f1)"
  _run laptop2 >/dev/null 2>&1 || true
  _after="$(md5 -q "$_wgc" 2>/dev/null || md5sum "$_wgc" | cut -d' ' -f1)"
  assert_eq "dry-run tidak mengubah wg0.conf" "$_before" "$_after"

  # Nama harus divalidasi — masuk ke nama file dan komentar config.
  assert_fail "menolak nama dengan spasi"      "PATH='$_d:$PATH' '$AC' 'hp saya' --env-file '$_env' --wg-conf '$_wgc' --server-pub '$_pub' --dry-run"
  assert_fail "menolak nama dengan slash"      "PATH='$_d:$PATH' '$AC' '../etc' --env-file '$_env' --wg-conf '$_wgc' --server-pub '$_pub' --dry-run"
  assert_fail "menolak tanpa nama"             "PATH='$_d:$PATH' '$AC' --env-file '$_env' --wg-conf '$_wgc' --server-pub '$_pub' --dry-run"

  # Nama duplikat akan membingungkan: dua file config, dua peer, satu nama.
  assert_fail "menolak nama yang sudah dipakai" "PATH='$_d:$PATH' '$AC' hp --env-file '$_env' --wg-conf '$_wgc' --server-pub '$_pub' --dry-run"

  rm -rf "$_d" "$_env" "$_wgc" "$_pub"
fi
