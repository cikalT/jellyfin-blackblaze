#!/usr/bin/env bash
# Membuat file yang baru diupload langsung muncul, tanpa menunggu cache
# direktori kedaluwarsa.
#
# Urutan itu penting: rclone menyimpan listing direktori selama
# --dir-cache-time. Menyuruh Jellyfin memindai lebih dulu hanya akan memindai
# listing basi dan tidak menemukan apa-apa.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "$HERE/lib/common.sh"

ENV_FILE="$(repo_root)/.env"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file) ENV_FILE="${2:-}"; shift ;;
    -h|--help)  echo "Pemakaian: refresh-library.sh [--env-file PATH]"; exit 0 ;;
    *)          die "argumen tidak dikenal: $1" ;;
  esac
  shift
done

load_env "$ENV_FILE"
require_env RC_ADDR JELLYFIN_BIND JELLYFIN_PORT

# 1. Buang cache direktori rclone supaya file baru terlihat oleh kernel.
log "Me-refresh listing direktori rclone"
rclone rc --url "http://${RC_ADDR}/" vfs/refresh recursive=true \
  || die "vfs/refresh gagal. Apakah mount berjalan? Cek: systemctl status rclone-b2"

# 2. Sekarang suruh Jellyfin memindai listing yang sudah segar.
if [[ -z "${JELLYFIN_API_KEY:-}" ]]; then
  warn "JELLYFIN_API_KEY kosong — scan Jellyfin dilewati.
  Buat key di Dashboard -> Advanced -> API Keys, lalu isi di .env.
  Sampai saat itu, scan terjadwal akan menemukannya sendiri dalam beberapa jam."
  exit 0
fi

log "Memicu scan library Jellyfin"
curl -fsS -X POST \
  "http://${JELLYFIN_BIND}:${JELLYFIN_PORT}/Library/Refresh" \
  -H "Authorization: MediaBrowser Token=\"${JELLYFIN_API_KEY}\"" \
  -H "Content-Length: 0" \
  || die "gagal memicu scan. Apakah container Jellyfin berjalan? Cek: docker ps"

log "Selesai. Scan berjalan di latar belakang — pantau di Dashboard."
