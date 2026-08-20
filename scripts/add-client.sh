#!/usr/bin/env bash
# Mendaftarkan satu device baru ke WireGuard dan mencetak QR code-nya.
#
# Tidak ada akun, tidak ada login. Satu perintah menghasilkan satu config;
# device menyimpannya sekali dan terhubung selamanya.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "$HERE/lib/common.sh"

ENV_FILE="$(repo_root)/.env"
WG_CONF=""
SERVER_PUB="/etc/wireguard/server.pub"
DRY_RUN=0
NAME=""

usage() {
  cat <<'USAGE'
Pemakaian: sudo add-client.sh <nama> [opsi]

  <nama>              Nama device: huruf kecil, angka, tanda hubung.
                      Contoh: hp, laptop, tablet-anak

  --dry-run           Cetak config yang akan dibuat, tanpa mengubah apa pun.
  --env-file PATH     Default: <root repo>/.env
  --wg-conf PATH      Default: /etc/wireguard/<WG_INTERFACE>.conf
  --server-pub PATH   Default: /etc/wireguard/server.pub
  -h, --help          Tampilkan bantuan ini
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)    DRY_RUN=1 ;;
    --env-file)   ENV_FILE="${2:-}"; shift ;;
    --wg-conf)    WG_CONF="${2:-}"; shift ;;
    --server-pub) SERVER_PUB="${2:-}"; shift ;;
    -h|--help)    usage; exit 0 ;;
    -*)           die "opsi tidak dikenal: $1" ;;
    *)            [[ -z "$NAME" ]] || die "nama device sudah diberikan: '$NAME'"; NAME="$1" ;;
  esac
  shift
done

[[ -n "$NAME" ]] || { usage >&2; die "nama device wajib diisi"; }

# Nama masuk ke nama file dan ke komentar di dalam config server. Membatasinya
# di sini mencegah path traversal sekaligus config yang rusak.
[[ "$NAME" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || die \
  "nama '$NAME' tidak valid. Pakai huruf kecil, angka, dan tanda hubung saja
  (maksimal 31 karakter, diawali huruf atau angka)."

load_env "$ENV_FILE"
require_env WG_INTERFACE WG_PORT WG_SUBNET WG_SERVER_IP WG_ENDPOINT WG_CLIENT_DIR JELLYFIN_PORT
require_bootstrap wg "langkah 5/10 (Runtime)"

WG_CONF="${WG_CONF:-/etc/wireguard/${WG_INTERFACE}.conf}"
[[ -f "$WG_CONF" ]]    || die "config server tidak ditemukan: $WG_CONF (jalankan bootstrap.sh dulu)"
[[ -f "$SERVER_PUB" ]] || die "kunci publik server tidak ditemukan: $SERVER_PUB"

# Nama duplikat menghasilkan dua peer dan dua file config dengan nama sama —
# menghapus salah satunya nanti jadi tebak-tebakan.
if grep -qE "^#[[:space:]]*${NAME}\$" "$WG_CONF"; then
  die "device bernama '$NAME' sudah terdaftar di $WG_CONF.
  Pakai nama lain, atau hapus blok [Peer] miliknya dulu."
fi

# ── Alokasi IP ───────────────────────────────────────────────────────────────
# Ambil oktet terakhir dari setiap AllowedIPs milik peer, lalu pilih angka
# bebas terkecil mulai dari .2 (.1 milik server).
prefix="${WG_SERVER_IP%.*}"
used="$(grep -oE 'AllowedIPs[[:space:]]*=[[:space:]]*[0-9.]+/32' "$WG_CONF" \
        | grep -oE '[0-9]+/32' | cut -d/ -f1 || true)"

next=2
while printf '%s\n' "$used" | grep -qx "$next"; do
  next=$((next + 1))
  (( next <= 254 )) || die "subnet $WG_SUBNET penuh (254 device)"
done
CLIENT_IP="${prefix}.${next}"

# ── Kunci ────────────────────────────────────────────────────────────────────
umask 077
client_priv="$(wg genkey)"
client_pub="$(printf '%s' "$client_priv" | wg pubkey)"
psk="$(wg genpsk)"
server_pub="$(cat "$SERVER_PUB")"

# ── Config client ────────────────────────────────────────────────────────────
# AllowedIPs sengaja hanya berisi subnet WireGuard, bukan 0.0.0.0/0.
# Ini yang membuatnya split tunnel: browsing biasa tetap lewat koneksi
# normal dan tidak menyentuh kuota 512 GB VPS.
client_conf="$(cat <<CONF
[Interface]
PrivateKey = ${client_priv}
Address = ${CLIENT_IP}/32

[Peer]
PublicKey = ${server_pub}
PresharedKey = ${psk}
Endpoint = ${WG_ENDPOINT}:${WG_PORT}
AllowedIPs = ${WG_SUBNET}
PersistentKeepalive = 25
CONF
)"

if (( DRY_RUN )); then
  log "[dry-run] config untuk '$NAME' (tidak ada yang ditulis)"
  printf '%s\n' "$client_conf"
  info "Jellyfin nanti ada di: http://${WG_SERVER_IP}:${JELLYFIN_PORT}"
  exit 0
fi

# ── Daftarkan di server ──────────────────────────────────────────────────────
cat >> "$WG_CONF" <<PEER

[Peer]
# ${NAME}
PublicKey = ${client_pub}
PresharedKey = ${psk}
AllowedIPs = ${CLIENT_IP}/32
PEER

# syncconf, bukan restart: menerapkan peer baru tanpa memutus tunnel
# device lain yang sedang menonton.
if wg show "$WG_INTERFACE" >/dev/null 2>&1; then
  wg syncconf "$WG_INTERFACE" <(wg-quick strip "$WG_CONF")
  info "peer diterapkan tanpa memutus koneksi yang sedang berjalan"
else
  warn "interface $WG_INTERFACE belum aktif — jalankan: systemctl start wg-quick@${WG_INTERFACE}"
fi

install -d -m 700 "$WG_CLIENT_DIR"
out="${WG_CLIENT_DIR}/${NAME}.conf"
printf '%s\n' "$client_conf" > "$out"
chmod 600 "$out"

# ── Serahkan ke pengguna ─────────────────────────────────────────────────────
log "Device '$NAME' terdaftar sebagai ${CLIENT_IP}"
echo
if command -v qrencode >/dev/null 2>&1; then
  printf '%s\n' "$client_conf" | qrencode -t ansiutf8
  echo
  info "HP/tablet : buka app WireGuard -> tambah tunnel -> scan QR di atas"
else
  warn "qrencode tidak terpasang — QR dilewati (apt-get install qrencode)"
fi
info "Laptop    : salin file ini, lalu import di app WireGuard:"
info "            $out"
echo
info "Setelah tunnel aktif, Jellyfin ada di: http://${WG_SERVER_IP}:${JELLYFIN_PORT}"
