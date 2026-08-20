#!/usr/bin/env bash
# Melaporkan pemakaian bandwidth keluar bulan ini terhadap kuota VPS.
# Traffic keluar-lah yang dihitung Tencent, dan itulah yang habis saat menonton.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "$HERE/lib/common.sh"

ENV_FILE="$(repo_root)/.env"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file) ENV_FILE="${2:-}"; shift ;;
    -h|--help)  echo "Pemakaian: quota-check.sh [--env-file PATH]"; exit 0 ;;
    *)          die "argumen tidak dikenal: $1" ;;
  esac
  shift
done

load_env "$ENV_FILE"
require_env NET_INTERFACE MONTHLY_QUOTA_GB QUOTA_WARN_PERCENT
require_bootstrap vnstat "langkah 2/10 (Paket dasar)"
require_cmd python3

# vnstat 2.x melaporkan byte. Entri bulan terakhir adalah bulan berjalan.
tx_bytes="$(vnstat --json m -i "$NET_INTERFACE" 2>/dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["interfaces"][0]["traffic"]["month"][-1]["tx"])')"

[[ "$tx_bytes" =~ ^[0-9]+$ ]] || die "tidak bisa membaca data vnstat untuk $NET_INTERFACE"

used_gb=$(( tx_bytes / 1024 / 1024 / 1024 ))
pct=$(( used_gb * 100 / MONTHLY_QUOTA_GB ))
remaining_gb=$(( MONTHLY_QUOTA_GB - used_gb ))

log "Kuota bandwidth bulan ini"
info "terpakai    : ${used_gb} GB dari ${MONTHLY_QUOTA_GB} GB (${pct}%)"
info "sisa        : ${remaining_gb} GB"
info "kira-kira   : ~$(( remaining_gb / 5 )) film lagi @ 5 GB"

if (( pct >= QUOTA_WARN_PERCENT )); then
  warn "pemakaian ${pct}% sudah melewati ambang ${QUOTA_WARN_PERCENT}%.
  Kalau kuota habis, Tencent biasanya menurunkan kecepatan drastis sampai
  bulan berikutnya."
  exit 1
fi
exit 0
