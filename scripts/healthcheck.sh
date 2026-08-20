#!/usr/bin/env bash
# Melaporkan kesehatan mount, container, dan disk. Read-only.
set -uo pipefail   # bukan -e: kita ingin SEMUA cek jalan, lalu melaporkan.

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "$HERE/lib/common.sh"
set +e

ENV_FILE="$(repo_root)/.env"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file) ENV_FILE="${2:-}"; shift ;;
    -h|--help)  echo "Pemakaian: healthcheck.sh [--env-file PATH]"; exit 0 ;;
    *)          printf 'argumen tidak dikenal: %s\n' "$1" >&2; exit 1 ;;
  esac
  shift
done

[[ -f "$ENV_FILE" ]] || { printf 'GAGAL: env tidak ditemukan: %s\n' "$ENV_FILE" >&2; exit 1; }
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

FAILED=0
ok()   { printf '  \033[0;32mok\033[0m    %s\n' "$*"; }
bad()  { printf '  \033[0;31mGAGAL\033[0m %s\n' "$*"; FAILED=1; }
note() { printf '  \033[0;33mcatatan\033[0m %s\n' "$*"; }

log "Prasyarat bootstrap"
_incomplete=0
_need() {
  local label="$1" probe="$2" step="$3"
  if eval "$probe" >/dev/null 2>&1; then
    ok "$label"
  else
    bad "$label — belum ada (bootstrap langkah $step)"
    _incomplete=1
  fi
}
_need "docker terpasang"          "command -v docker"        "5/10"
_need "rclone terpasang"          "command -v rclone"        "5/10"
_need "wireguard terpasang"       "command -v wg"            "5/10"
_need "kredensial /etc/jellyfin-b2/env" "[[ -f /etc/jellyfin-b2/env ]]" "7/10"
_need "config /etc/rclone/rclone.conf"  "[[ -f /etc/rclone/rclone.conf ]]" "7/10"
_need "kunci server WireGuard"    "[[ -f /etc/wireguard/server.key ]]" "8/10"
_need "unit rclone-b2 terpasang"  "[[ -f /etc/systemd/system/rclone-b2.service ]]" "9/10"

if (( _incomplete )); then
  printf '\n'
  note "Bootstrap belum selesai. Jalankan: sudo ./scripts/bootstrap.sh"
  printf '\n'
fi

log "Mount"
if mountpoint -q "${MEDIA_MOUNT:-}" 2>/dev/null; then
  ok "$MEDIA_MOUNT ter-mount"
  if [[ -n "$(ls -A "$MEDIA_MOUNT" 2>/dev/null)" ]]; then
    ok "mount berisi $(find "$MEDIA_MOUNT" -maxdepth 1 -mindepth 1 2>/dev/null | wc -l | tr -d ' ') entri teratas"
  else
    bad "$MEDIA_MOUNT ter-mount tapi kosong — cek nama bucket dan izin kunci"
  fi
else
  bad "${MEDIA_MOUNT:-<MEDIA_MOUNT tidak diset>} tidak ter-mount"
fi

if command -v systemctl >/dev/null 2>&1; then
  if systemctl is-active --quiet rclone-b2.service; then
    ok "rclone-b2.service aktif"
  else
    bad "rclone-b2.service tidak aktif — journalctl -u rclone-b2 -n 50"
  fi
fi

log "Jellyfin"
if curl -fsS --max-time 10 "http://${JELLYFIN_BIND:-127.0.0.1}:${JELLYFIN_PORT:-8096}/health" >/dev/null 2>&1; then
  ok "Jellyfin merespons di ${JELLYFIN_BIND}:${JELLYFIN_PORT}"
else
  bad "Jellyfin tidak merespons di ${JELLYFIN_BIND:-?}:${JELLYFIN_PORT:-?} — docker ps"
fi

log "Disk"
_pct="$(df --output=pcent / 2>/dev/null | tail -1 | tr -dc '0-9')"
if [[ -n "$_pct" ]]; then
  if   (( _pct >= 90 )); then bad  "/ terpakai ${_pct}%"
  elif (( _pct >= 80 )); then note "/ terpakai ${_pct}%"
  else                        ok   "/ terpakai ${_pct}%"
  fi
fi
if [[ -d "${VFS_CACHE_DIR:-}" ]]; then
  ok "cache VFS: $(du -sh "$VFS_CACHE_DIR" 2>/dev/null | cut -f1) (batas ${VFS_CACHE_MAX_SIZE:-?})"
fi

exit "$FAILED"
