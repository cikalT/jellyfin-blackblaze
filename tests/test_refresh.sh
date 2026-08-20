# shellcheck shell=bash
# Diuji: scripts/refresh-library.sh, dengan rclone dan curl palsu di PATH.

ROOT="$(cd .. && pwd)"
RL="$ROOT/scripts/refresh-library.sh"

assert_ok "refresh-library.sh ada"        "[[ -f '$RL' ]]"
assert_ok "refresh-library.sh executable" "[[ -x '$RL' ]]"

# Membangun bin palsu yang mencatat argumennya ke $STUB_LOG, lalu sukses.
_stubdir() {
  local d; d="$(mktemp -d)"
  for c in rclone curl; do
    cat > "$d/$c" <<STUB
#!/usr/bin/env bash
printf '%s %s\n' "$c" "\$*" >> "\$STUB_LOG"
exit 0
STUB
    chmod +x "$d/$c"
  done
  printf '%s' "$d"
}

_mkenv() {
  local f key="$1"; f="$(mktemp)"
  cat > "$f" <<ENVF
RC_ADDR=127.0.0.1:5572
JELLYFIN_BIND=10.8.0.1
JELLYFIN_PORT=8096
JELLYFIN_API_KEY=$key
ENVF
  printf '%s' "$f"
}

if [[ -x "$RL" ]]; then
  # --- Dengan API key: kedua langkah harus jalan, rclone lebih dulu ---
  _d="$(_stubdir)"; _log="$(mktemp)"; _env="$(_mkenv secretkey123)"
  ( export STUB_LOG="$_log" PATH="$_d:$PATH"; "$RL" --env-file "$_env" ) >/dev/null 2>&1 || true
  _got="$(cat "$_log")"

  assert_contains "memanggil vfs/refresh rclone" "$_got" "vfs/refresh"
  assert_contains "refresh bersifat rekursif"    "$_got" "recursive=true"
  assert_contains "menargetkan alamat RC"        "$_got" "127.0.0.1:5572"
  assert_contains "memicu scan Jellyfin"         "$_got" "/Library/Refresh"
  assert_contains "mengirim token API"           "$_got" "secretkey123"

  # Urutan penting: listing rclone harus di-refresh SEBELUM Jellyfin memindai.
  assert_eq "rclone berjalan sebelum curl" "$(head -1 "$_log" | awk '{print $1}')" "rclone"
  rm -rf "$_d" "$_log" "$_env"

  # --- Tanpa API key: refresh rclone tetap jalan, langkah Jellyfin dilewati ---
  _d2="$(_stubdir)"; _log2="$(mktemp)"; _env2="$(_mkenv "")"
  ( export STUB_LOG="$_log2" PATH="$_d2:$PATH"; "$RL" --env-file "$_env2" ) >/dev/null 2>&1 || true
  _got2="$(cat "$_log2")"

  assert_contains "tanpa key: rclone tetap di-refresh" "$_got2" "vfs/refresh"
  assert_fail     "tanpa key: Jellyfin dilewati"       "printf '%s' '$_got2' | grep -q 'Library/Refresh'"
  assert_ok       "tanpa key: tetap exit 0" \
    "( export STUB_LOG='$_log2' PATH='$_d2:$PATH'; '$RL' --env-file '$_env2' )"
  rm -rf "$_d2" "$_log2" "$_env2"
fi
