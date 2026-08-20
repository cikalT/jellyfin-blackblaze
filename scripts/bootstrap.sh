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

load_env "$ENV_FILE"

# ── 1. Preflight ─────────────────────────────────────────────────────────────
# Preflight bersifat read-only, jadi dijalankan sungguhan bahkan saat dry-run —
# gunanya justru untuk menangkap konfigurasi salah sedini mungkin.
log "1/9  Preflight"
if (( DRY_RUN )); then
  "$HERE/preflight.sh" --config-only --env-file "$ENV_FILE"
else
  "$HERE/preflight.sh" --env-file "$ENV_FILE"
fi

# ── 2. Paket dasar ───────────────────────────────────────────────────────────
log "2/9  Paket dasar"
run apt-get update -qq
run apt-get install -y -qq curl ca-certificates fuse3 vnstat jq gnupg

# ── 3. Swap ──────────────────────────────────────────────────────────────────
# RAM 2 GB terlalu mepet untuk scan library Jellyfin. Tanpa swap, OOM killer
# memilih korban dan sering kali korbannya sshd.
log "3/9  Swap"
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
log "4/9  Batas log"
write_file /etc/systemd/journald.conf.d/99-limits.conf 644 <<'JOURNAL'
[Journal]
SystemMaxUse=200M
SystemMaxFileSize=50M
JOURNAL
run systemctl restart systemd-journald

# ── 5. Docker, rclone, Tailscale ─────────────────────────────────────────────
log "5/9  Runtime"
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

if command -v tailscale >/dev/null 2>&1; then
  info "tailscale sudah ada"
else
  run bash -c 'curl -fsSL https://tailscale.com/install.sh | sh'
fi

# --allow-other butuh flag ini untuk mount yang dipakai lintas namespace.
if ! grep -q '^user_allow_other' /etc/fuse.conf 2>/dev/null; then
  run bash -c 'echo user_allow_other >> /etc/fuse.conf'
fi

# ── 6. Direktori ─────────────────────────────────────────────────────────────
log "6/9  Direktori"
run install -d -m 755 "$MEDIA_MOUNT"
run install -d -m 755 -o "$JELLYFIN_UID" -g "$JELLYFIN_GID" "$VFS_CACHE_DIR"
run install -d -m 755 -o "$JELLYFIN_UID" -g "$JELLYFIN_GID" "$JELLYFIN_DATA/config" "$JELLYFIN_DATA/cache"

# ── 7. Rahasia ───────────────────────────────────────────────────────────────
# Kredensial tinggal di /etc, bukan di dalam checkout repo. Mode 600 karena
# file ini memberikan akses baca ke seluruh library.
log "7/9  Kredensial"
write_file /etc/rclone/rclone.conf 600 <<CFG
[b2]
type = b2
account = ${B2_ACCOUNT_ID}
key = ${B2_APPLICATION_KEY}
hard_delete = false
CFG

write_file /etc/jellyfin-b2/env 600 <<ENVF
B2_BUCKET=${B2_BUCKET}
MEDIA_MOUNT=${MEDIA_MOUNT}
VFS_CACHE_DIR=${VFS_CACHE_DIR}
VFS_CACHE_MAX_SIZE=${VFS_CACHE_MAX_SIZE}
DIR_CACHE_TIME=${DIR_CACHE_TIME}
RCLONE_RC_ADDR=${RCLONE_RC_ADDR}
JELLYFIN_UID=${JELLYFIN_UID}
JELLYFIN_GID=${JELLYFIN_GID}
ENVF

# ── 8. Unit systemd ──────────────────────────────────────────────────────────
log "8/9  systemd"
run install -m 644 "$ROOT/systemd/rclone-b2.service" /etc/systemd/system/rclone-b2.service
run install -d -m 755 /etc/systemd/system/docker.service.d
run install -m 644 "$ROOT/systemd/docker-after-mount.conf" \
    /etc/systemd/system/docker.service.d/10-after-mount.conf
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

# ── 9. Jellyfin ──────────────────────────────────────────────────────────────
log "9/9  Jellyfin"
run systemctl restart docker
run docker compose --project-directory "$ROOT" --env-file "$ENV_FILE" up -d

cat <<NEXT

Bootstrap selesai. Tiga langkah yang harus dilakukan manual:

  1. Sambungkan ke Tailscale (butuh login di browser):
       sudo tailscale up --hostname=${TS_HOSTNAME}

  2. Paparkan Jellyfin ke tailnet dengan TLS asli:
       sudo tailscale serve --bg ${JELLYFIN_PORT}
       tailscale serve status        # catat URL https://...ts.net

  3. Buka URL itu, selesaikan wizard Jellyfin, lalu KERJAKAN CHECKLIST di
     docs/jellyfin-settings.md. Checklist itu bukan opsional — melewatinya
     bisa menghabiskan kuota sebulan hanya untuk sekali scan library.

  Setelah itu, isi JELLYFIN_API_KEY dan JELLYFIN_PUBLISHED_URL di .env,
  lalu jalankan ulang:  docker compose up -d

NEXT
