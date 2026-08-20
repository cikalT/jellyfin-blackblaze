#!/usr/bin/env bash
# Memprovision VPS Debian 12 kosong menjadi server Jellyfin yang menstream
# dari Backblaze B2. Idempoten: aman dijalankan berkali-kali.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "$HERE/lib/common.sh"
ROOT="$(repo_root)"

DRY_RUN=0
ENV_FILE="$ROOT/.env"

usage() {
  cat <<'USAGE'
Pemakaian: sudo bootstrap.sh [opsi]

  --dry-run          Cetak setiap aksi tanpa mengubah apa pun.
  --env-file PATH    File env yang dipakai (default: <root repo>/.env)
  -h, --help         Tampilkan bantuan ini
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)  DRY_RUN=1 ;;
    --env-file) ENV_FILE="${2:-}"; shift ;;
    -h|--help)  usage; exit 0 ;;
    *)          die "argumen tidak dikenal: $1" ;;
  esac
  shift
done

# run — mengeksekusi, atau mencetak saja saat --dry-run.
run() {
  if (( DRY_RUN )); then
    printf '  [dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

# write_file <path> <mode> — menulis stdin ke path dengan mode tertentu.
write_file() {
  local path="$1" mode="$2" content; content="$(cat)"
  if (( DRY_RUN )); then
    printf '  [dry-run] tulis %s (mode %s, %d byte)\n' "$path" "$mode" "${#content}"
    return
  fi
  install -d -m 755 "$(dirname "$path")"
  printf '%s' "$content" > "$path"
  chmod "$mode" "$path"
}

# write_once <path> <mode> — seperti write_file, tapi TIDAK PERNAH menimpa
# file yang sudah ada. Dipakai untuk file yang menumpuk state (wg0.conf
# menyimpan daftar peer; menimpanya akan memutus semua client).
write_once() {
  local path="$1" mode="$2" content; content="$(cat)"
  if [[ -e "$path" ]]; then
    info "$path sudah ada — dibiarkan"
    return
  fi
  if (( DRY_RUN )); then
    printf '  [dry-run] tulis %s (mode %s, %d byte)\n' "$path" "$mode" "${#content}"
    return
  fi
  install -d -m 700 "$(dirname "$path")"
  printf '%s' "$content" > "$path"
  chmod "$mode" "$path"
}

load_env "$ENV_FILE"

# ── 1. Preflight ─────────────────────────────────────────────────────────────
# Preflight bersifat read-only, jadi dijalankan sungguhan bahkan saat dry-run —
# gunanya justru untuk menangkap konfigurasi salah sedini mungkin.
#
# curl dipasang lebih dulu karena preflight memakainya untuk memvalidasi
# kredensial B2. Ini satu-satunya perubahan sistem yang mendahului preflight,
# dan sengaja dipilih yang paling tidak berbahaya: memasang curl bisa
# dibatalkan, sementara langkah-langkah setelah preflight tidak.
log "1/10 Preflight"
if ! command -v curl >/dev/null 2>&1; then
  info "memasang curl (dibutuhkan preflight untuk memeriksa kredensial B2)"
  run apt-get update -qq
  run apt-get install -y -qq curl ca-certificates
fi

if (( DRY_RUN )); then
  "$HERE/preflight.sh" --config-only --env-file "$ENV_FILE"
else
  "$HERE/preflight.sh" --env-file "$ENV_FILE"
fi

# ── 2. Paket dasar ───────────────────────────────────────────────────────────
log "2/10 Paket dasar"
run apt-get update -qq
run apt-get install -y -qq curl ca-certificates fuse3 vnstat jq gnupg

# ── 3. Swap ──────────────────────────────────────────────────────────────────
# RAM 2 GB terlalu mepet untuk scan library Jellyfin. Tanpa swap, OOM killer
# memilih korban dan sering kali korbannya sshd.
log "3/10 Swap"
if swapon --show 2>/dev/null | grep -q '/swapfile'; then
  info "swapfile sudah aktif"
else
  run fallocate -l 2G /swapfile
  run chmod 600 /swapfile
  run mkswap /swapfile
  run swapon /swapfile
  if ! grep -q '^/swapfile' /etc/fstab 2>/dev/null; then
    run bash -c 'echo "/swapfile none swap sw 0 0" >> /etc/fstab'
  fi
fi
run sysctl -qw vm.swappiness=10
write_file /etc/sysctl.d/99-jellyfin.conf 644 <<'SYSCTL'
vm.swappiness=10
SYSCTL

# ── 4. Batas log ─────────────────────────────────────────────────────────────
# Disk 40 GB. journald tanpa batas akan memakannya pelan-pelan.
log "4/10 Batas log"
write_file /etc/systemd/journald.conf.d/99-limits.conf 644 <<'JOURNAL'
[Journal]
SystemMaxUse=200M
SystemMaxFileSize=50M
JOURNAL
run systemctl restart systemd-journald

# ── 5. Docker, rclone, WireGuard ─────────────────────────────────────────────
log "5/10 Runtime"
if command -v docker >/dev/null 2>&1; then
  info "docker sudah ada"
else
  run bash -c 'curl -fsSL https://get.docker.com | sh'
fi

if command -v rclone >/dev/null 2>&1; then
  info "rclone sudah ada"
else
  run bash -c 'curl -fsSL https://rclone.org/install.sh | bash'
fi

if command -v wg >/dev/null 2>&1; then
  info "wireguard sudah ada"
else
  run apt-get install -y -qq wireguard wireguard-tools qrencode
fi

# --allow-other butuh flag ini untuk mount yang dipakai lintas namespace.
if ! grep -q '^user_allow_other' /etc/fuse.conf 2>/dev/null; then
  run bash -c 'echo user_allow_other >> /etc/fuse.conf'
fi

# ── 6. Direktori ─────────────────────────────────────────────────────────────
log "6/10 Direktori"
run install -d -m 755 "$MEDIA_MOUNT"
run install -d -m 755 -o "$JELLYFIN_UID" -g "$JELLYFIN_GID" "$VFS_CACHE_DIR"
run install -d -m 755 -o "$JELLYFIN_UID" -g "$JELLYFIN_GID" "$JELLYFIN_DATA/config" "$JELLYFIN_DATA/cache"

# ── 7. Rahasia ───────────────────────────────────────────────────────────────
# Kredensial tinggal di /etc, bukan di dalam checkout repo. Mode 600 karena
# file ini memberikan akses baca ke seluruh library.
log "7/10 Kredensial"
write_file /etc/rclone/rclone.conf 600 <<CFG
[b2]
type = b2
account = ${B2_KEY_ID}
key = ${B2_APPLICATION_KEY}
hard_delete = false
CFG

write_file /etc/jellyfin-b2/env 600 <<ENVF
B2_BUCKET=${B2_BUCKET}
MEDIA_MOUNT=${MEDIA_MOUNT}
VFS_CACHE_DIR=${VFS_CACHE_DIR}
VFS_CACHE_MAX_SIZE=${VFS_CACHE_MAX_SIZE}
DIR_CACHE_TIME=${DIR_CACHE_TIME}
RC_ADDR=${RC_ADDR}
JELLYFIN_UID=${JELLYFIN_UID}
JELLYFIN_GID=${JELLYFIN_GID}
ENVF

# ── 8. WireGuard ─────────────────────────────────────────────────────────────
# Split tunnel yang disengaja: tidak ada MASQUERADE, tidak ada ip_forward.
# Client hanya bisa menjangkau VPS ini, bukan berselancar lewat VPS ini —
# full tunnel akan mengalirkan seluruh browsing lewat kuota 512 GB.
log "8/10 WireGuard"
run install -d -m 700 /etc/wireguard "$WG_CLIENT_DIR"

if [[ -f /etc/wireguard/server.key ]]; then
  info "kunci server sudah ada — dibiarkan (regenerasi akan memutus semua client)"
elif (( DRY_RUN )); then
  printf '  [dry-run] generate kunci server ke /etc/wireguard/server.key\n'
else
  umask 077
  wg genkey | tee /etc/wireguard/server.key | wg pubkey > /etc/wireguard/server.pub
  chmod 600 /etc/wireguard/server.key
  chmod 644 /etc/wireguard/server.pub
fi

# write_once, bukan write_file: file ini menumpuk blok [Peer] dari
# add-client.sh. Menimpanya akan menghapus setiap device yang terdaftar.
_wg_privkey="$( [[ -f /etc/wireguard/server.key ]] && cat /etc/wireguard/server.key || echo 'AKAN_DIISI_SAAT_BOOTSTRAP_SUNGGUHAN' )"
write_once "/etc/wireguard/${WG_INTERFACE}.conf" 600 <<WGCONF
[Interface]
Address = ${WG_SERVER_IP}/24
ListenPort = ${WG_PORT}
PrivateKey = ${_wg_privkey}

# Peer ditambahkan oleh scripts/add-client.sh — jangan diedit manual
# kecuali kamu tahu persis yang kamu lakukan.
WGCONF

run systemctl enable --now "wg-quick@${WG_INTERFACE}"

# ── 9. Unit systemd ──────────────────────────────────────────────────────────
log "9/10 systemd"
run install -m 644 "$ROOT/systemd/rclone-b2.service" /etc/systemd/system/rclone-b2.service
run install -d -m 755 /etc/systemd/system/docker.service.d
run install -m 644 "$ROOT/systemd/docker-after-deps.conf" \
    /etc/systemd/system/docker.service.d/10-after-deps.conf
run systemctl daemon-reload
run systemctl enable --now rclone-b2.service

if (( DRY_RUN == 0 )); then
  # Type=notify berarti systemd sudah menunggu mount siap, tapi kita tetap
  # verifikasi sebelum menyerahkan kendali ke Docker.
  for _ in $(seq 1 30); do
    mountpoint -q "$MEDIA_MOUNT" && break
    sleep 1
  done
  mountpoint -q "$MEDIA_MOUNT" \
    || die "mount tidak muncul di $MEDIA_MOUNT — cek: journalctl -u rclone-b2 -n 50"
  # find, bukan ls: nama folder film penuh spasi dan tanda kurung.
  info "mount aktif: $(find "$MEDIA_MOUNT" -maxdepth 1 -mindepth 1 -printf '%f  ' 2>/dev/null | head -c 200)"
fi

# ── 10. Jellyfin ─────────────────────────────────────────────────────────────
log "10/10 Jellyfin"
run systemctl restart docker
run docker compose --project-directory "$ROOT" --env-file "$ENV_FILE" up -d

cat <<NEXT

Bootstrap selesai. Tiga langkah yang harus dilakukan manual:

  1. Buka UDP ${WG_PORT} di security group Tencent.
     Tanpa ini, tidak ada client yang bisa menyambung. WireGuard tidak
     membalas paket tanpa kunci sah, jadi port ini tak terlihat oleh scanner.

  2. Daftarkan device pertamamu:
       sudo ./scripts/add-client.sh hp
     Skrip mencetak QR code — scan dari app WireGuard di HP. Tanpa login,
     tanpa akun. Ulangi dengan nama berbeda untuk laptop dan tablet.

  3. Aktifkan tunnel di HP, lalu buka  http://${WG_SERVER_IP}:${JELLYFIN_PORT}
     Selesaikan wizard Jellyfin, lalu KERJAKAN CHECKLIST di
     docs/jellyfin-settings.md. Checklist itu bukan opsional — melewatinya
     bisa menghabiskan kuota sebulan hanya untuk sekali scan library.

  Setelah itu, isi JELLYFIN_API_KEY di .env lalu:  docker compose up -d

NEXT
