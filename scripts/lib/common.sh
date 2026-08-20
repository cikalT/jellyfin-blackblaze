#!/usr/bin/env bash
# Primitif bersama. DI-SOURCE, bukan dieksekusi.
# Sengaja tidak tahu apa-apa soal B2, Jellyfin, atau Tailscale — hanya
# primitif generik, supaya bisa diuji tanpa server dan tidak berubah jadi
# tempat sampah.

set -euo pipefail

if [[ -t 1 ]]; then
  C_RED=$'\033[0;31m'; C_YLW=$'\033[0;33m'; C_GRN=$'\033[0;32m'
  C_DIM=$'\033[2m';    C_RST=$'\033[0m'
else
  C_RED=''; C_YLW=''; C_GRN=''; C_DIM=''; C_RST=''
fi

log()  { printf '%s==>%s %s\n'  "$C_GRN" "$C_RST" "$*"; }
info() { printf '%s    %s%s\n'  "$C_DIM" "$*" "$C_RST"; }
warn() { printf '%sPERINGATAN:%s %s\n' "$C_YLW" "$C_RST" "$*" >&2; }
die()  { printf '%sGAGAL:%s %s\n'      "$C_RED" "$C_RST" "$*" >&2; exit 1; }

# require_cmd <cmd>... — gagal kalau ada yang tidak ada di PATH.
require_cmd() {
  local missing=() c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  (( ${#missing[@]} == 0 )) || die "perintah tidak ditemukan: ${missing[*]}"
}

# require_env <VARNAME>... — gagal kalau ada yang tidak diset atau kosong.
require_env() {
  local missing=() v
  for v in "$@"; do
    [[ -n "${!v:-}" ]] || missing+=("$v")
  done
  (( ${#missing[@]} == 0 )) || die "variabel .env kosong atau belum diisi: ${missing[*]}"
}

# load_env <path> — meng-export semua isi file env.
load_env() {
  local f="${1:-}"
  [[ -f "$f" ]] || die "file env tidak ditemukan: $f (salin .env.example jadi .env dulu)"
  set -a
  # shellcheck disable=SC1090
  . "$f"
  set +a
}

# repo_root — path absolut root repo, diturunkan dari lokasi file ini.
repo_root() {
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd
}
