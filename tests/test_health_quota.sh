# shellcheck shell=bash
# Diuji: scripts/healthcheck.sh dan scripts/quota-check.sh

ROOT="$(cd .. && pwd)"
HC="$ROOT/scripts/healthcheck.sh"
QC="$ROOT/scripts/quota-check.sh"

for f in "$HC" "$QC"; do
  assert_ok "$(basename "$f") ada"        "[[ -f '$f' ]]"
  assert_ok "$(basename "$f") executable" "[[ -x '$f' ]]"
done

# --- quota-check dengan vnstat palsu ---------------------------------------
# vnstat melaporkan byte. 256 GB terpakai dari kuota 512 GB = 50%, di bawah
# ambang 80% -> exit 0. 480 GB = 93,75% -> exit 1.
_vnstat_stub() {
  local d bytes="$1"; d="$(mktemp -d)"
  cat > "$d/vnstat" <<STUB
#!/usr/bin/env bash
cat <<'JSON'
{"interfaces":[{"name":"eth0","traffic":{"month":[{"date":{"year":2026,"month":8},"rx":1,"tx":$bytes}]}}]}
JSON
STUB
  chmod +x "$d/vnstat"
  printf '%s' "$d"
}

_qenv() {
  local f; f="$(mktemp)"
  cat > "$f" <<'ENVF'
NET_INTERFACE=eth0
MONTHLY_QUOTA_GB=512
QUOTA_WARN_PERCENT=80
ENVF
  printf '%s' "$f"
}

if [[ -x "$QC" ]]; then
  _env="$(_qenv)"

  # 256 GB = 274877906944 byte -> 50%, aman
  _d="$(_vnstat_stub 274877906944)"
  assert_ok "kuota 50% keluar dengan status 0" \
    "( PATH='$_d:$PATH'; '$QC' --env-file '$_env' )"
  _out="$( PATH="$_d:$PATH" "$QC" --env-file "$_env" 2>&1 || true )"
  assert_contains "melaporkan persentase" "$_out" "50"
  rm -rf "$_d"

  # 480 GB = 515396075520 byte -> 93%, melewati ambang
  _d2="$(_vnstat_stub 515396075520)"
  assert_fail "kuota 93% keluar dengan status bukan 0" \
    "( PATH='$_d2:$PATH'; '$QC' --env-file '$_env' )"
  rm -rf "$_d2"

  rm -f "$_env"
fi

# --- healthcheck harus gagal bersih kalau mount tidak ada -------------------
if [[ -x "$HC" ]]; then
  _henv="$(mktemp)"
  cat > "$_henv" <<'ENVF'
MEDIA_MOUNT=/nonexistent/mount/point
VFS_CACHE_DIR=/tmp
JELLYFIN_BIND=10.8.0.1
JELLYFIN_PORT=59999
VFS_CACHE_MAX_SIZE=10G
ENVF
  assert_fail "healthcheck gagal saat mount hilang" "'$HC' --env-file '$_henv'"
  _hout="$( "$HC" --env-file "$_henv" 2>&1 || true )"
  assert_contains "healthcheck menyebut mount" "$_hout" "/nonexistent/mount/point"
  rm -f "$_henv"
fi

# ── Perkakas yang dipasang bootstrap harus pakai require_bootstrap ──────────
# require_cmd polos menghasilkan "perintah tidak ditemukan: wg", yang benar
# secara teknis tapi tidak memberitahu pengguna bahwa yang kurang adalah
# menjalankan bootstrap. Ini pernah membingungkan sungguhan.
ROOT2="$(cd .. && pwd)"
for pair in "add-client.sh:wg" "quota-check.sh:vnstat"; do
  _f="${pair%%:*}"; _c="${pair##*:}"
  assert_fail "$_f tidak pakai require_cmd polos untuk $_c" \
    "grep -qE '^require_cmd[^\n]*\\b${_c}\\b' '$ROOT2/scripts/$_f'"
  assert_ok   "$_f memakai require_bootstrap $_c" \
    "grep -qE '^require_bootstrap[[:space:]]+${_c}\\b' '$ROOT2/scripts/$_f'"
done

# healthcheck harus melaporkan sampai mana bootstrap berjalan — ini yang
# menjadikannya satu perintah diagnosis saat pengguna melapor "gagal".
if [[ -f "$HC" ]]; then
  _hc="$(cat "$HC")"
  assert_contains "healthcheck memeriksa prasyarat bootstrap" "$_hc" "Prasyarat bootstrap"
  assert_contains "healthcheck menyebut langkah bootstrap"    "$_hc" "5/10"
fi
