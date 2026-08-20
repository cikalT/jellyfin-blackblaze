# shellcheck shell=bash
# Diuji: scripts/preflight.sh (mode --config-only)

ROOT="$(cd .. && pwd)"
PF="$ROOT/scripts/preflight.sh"

assert_ok "preflight.sh ada"        "[[ -f '$PF' ]]"
assert_ok "preflight.sh executable" "[[ -x '$PF' ]]"

# Fixture: .env yang benar-benar valid.
_mkenv() {
  local f; f="$(mktemp)"
  cat > "$f" <<'FIXTURE'
B2_KEY_ID=005abcdef
B2_APPLICATION_KEY=K005abcdefghij
B2_BUCKET=media-bucket
MEDIA_MOUNT=/srv/media
VFS_CACHE_DIR=/var/cache/rclone
VFS_CACHE_MAX_SIZE=10G
DIR_CACHE_TIME=1h
RCLONE_RC_ADDR=127.0.0.1:5572
JELLYFIN_IMAGE=jellyfin/jellyfin:10.11.11
JELLYFIN_BIND=10.8.0.1
JELLYFIN_PORT=8096
JELLYFIN_MEM_LIMIT=1200m
JELLYFIN_UID=1000
JELLYFIN_GID=1000
JELLYFIN_DATA=/opt/jellyfin
TZ=Asia/Jakarta
JELLYFIN_API_KEY=
JELLYFIN_PUBLISHED_URL=
WG_INTERFACE=wg0
WG_PORT=51820
WG_SUBNET=10.8.0.0/24
WG_SERVER_IP=10.8.0.1
WG_ENDPOINT=203.0.113.10
WG_CLIENT_DIR=/etc/wireguard/clients
MONTHLY_QUOTA_GB=512
QUOTA_WARN_PERCENT=80
NET_INTERFACE=eth0
FIXTURE
  printf '%s' "$f"
}

if [[ -x "$PF" ]]; then
  _good="$(_mkenv)"
  assert_ok "env valid lolos" "'$PF' --config-only --env-file '$_good'"

  # Kredensial B2 kosong harus ditolak, dan pesannya harus menyebut variabelnya.
  _nokey="$(_mkenv)"; sed -i.bak 's/^B2_BUCKET=.*/B2_BUCKET=/' "$_nokey"
  assert_fail "B2_BUCKET kosong ditolak" "'$PF' --config-only --env-file '$_nokey'"
  _msg="$( "$PF" --config-only --env-file "$_nokey" 2>&1 || true )"
  assert_contains "pesan menyebut B2_BUCKET" "$_msg" "B2_BUCKET"

  # Cek keamanan: bind non-localhost berarti terekspos ke internet.
  # Ini harus ditolak keras, bukan sekadar peringatan.
  _public="$(_mkenv)"; sed -i.bak 's/^JELLYFIN_BIND=.*/JELLYFIN_BIND=0.0.0.0/' "$_public"
  assert_fail "bind 0.0.0.0 ditolak" "'$PF' --config-only --env-file '$_public'"
  _msg2="$( "$PF" --config-only --env-file "$_public" 2>&1 || true )"
  assert_contains "pesan menjelaskan risiko bind" "$_msg2" "WG_SERVER_IP"

  # Endpoint publik wajib: tanpa itu config client tidak punya alamat tujuan.
  _noep="$(_mkenv)"; sed -i.bak 's/^WG_ENDPOINT=.*/WG_ENDPOINT=/' "$_noep"
  assert_fail "WG_ENDPOINT kosong ditolak" "'$PF' --config-only --env-file '$_noep'"
  rm -f "$_noep" "$_noep.bak"

  # Image tidak ter-pin harus ditolak.
  _latest="$(_mkenv)"; sed -i.bak 's|^JELLYFIN_IMAGE=.*|JELLYFIN_IMAGE=jellyfin/jellyfin:latest|' "$_latest"
  assert_fail "image :latest ditolak" "'$PF' --config-only --env-file '$_latest'"

  # File env yang tidak ada harus gagal dengan jelas, bukan crash.
  assert_fail "env file hilang ditolak" "'$PF' --config-only --env-file /nope/.env"

  rm -f "$_good" "$_nokey" "$_public" "$_latest" \
        "$_nokey.bak" "$_public.bak" "$_latest.bak" 2>/dev/null || true
fi

# ── Regresi: preflight TIDAK BOLEH bergantung pada rclone ───────────────────
# rclone baru dipasang oleh bootstrap. Memakainya di preflight membuat
# preflight mustahil lolos di server bersih — dan karena bootstrap memanggil
# preflight di langkah 1, bootstrap ikut gagal total.
assert_fail "preflight tidak memanggil rclone" \
  "grep -vE '^[[:space:]]*#' '$PF' | grep -qE '(require_cmd[^\n]*rclone|^[[:space:]]*rclone )'"

# ── Cek kredensial B2 lewat API, dengan curl palsu ─────────────────────────
_curl_stub() {
  local d; d="$(mktemp -d)"
  cat > "$d/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n%s' "$STUB_BODY" "$STUB_HTTP"
STUB
  chmod +x "$d/curl"
  printf '%s' "$d"
}

if [[ -x "$PF" ]]; then
  _cd="$(_curl_stub)"; _cenv="$(_mkenv)"
  _b2() { PATH="$_cd:$PATH" STUB_BODY="$1" STUB_HTTP="$2" "$PF" --b2-only --env-file "$_cenv" 2>&1; }

  _RO='{"allowed":{"buckets":[{"id":"b1","name":"media-bucket"}],"capabilities":["listBuckets","listFiles","readFiles"]}}'
  _RW='{"allowed":{"buckets":[{"id":"b1","name":"media-bucket"}],"capabilities":["listBuckets","listFiles","readFiles","writeFiles","deleteFiles"]}}'
  _WRONG='{"allowed":{"buckets":[{"id":"b9","name":"bucket-lain"}],"capabilities":["listBuckets","listFiles","readFiles"]}}'
  _THIN='{"allowed":{"buckets":[{"id":"b1","name":"media-bucket"}],"capabilities":["listBuckets"]}}'

  assert_ok   "kunci read-only untuk bucket benar diterima" \
    "PATH='$_cd:$PATH' STUB_BODY='$_RO' STUB_HTTP=200 '$PF' --b2-only --env-file '$_cenv'"

  # 401 adalah gejala paling membingungkan di seluruh setup ini. Pesannya
  # harus menyebut penyebab sesungguhnya, bukan menyuruh 'cek kredensial'.
  _o401="$(_b2 '{"code":"unauthorized"}' 401 || true)"
  assert_contains "401 menjelaskan keyID vs Account ID" "$_o401" "applicationKeyId"
  assert_fail "401 menggagalkan preflight" \
    "PATH='$_cd:$PATH' STUB_BODY='{}' STUB_HTTP=401 '$PF' --b2-only --env-file '$_cenv'"

  # Kunci yang bisa menulis tetap boleh jalan, tapi harus diperingatkan.
  _orw="$(_b2 "$_RW" 200 || true)"
  assert_contains "kunci writable diperingatkan" "$_orw" "BISA MENULIS"
  assert_ok "kunci writable tidak menggagalkan" \
    "PATH='$_cd:$PATH' STUB_BODY='$_RW' STUB_HTTP=200 '$PF' --b2-only --env-file '$_cenv'"

  # Kunci yang diarahkan ke bucket lain adalah kesalahan konfigurasi nyata.
  assert_fail "kunci untuk bucket lain ditolak" \
    "PATH='$_cd:$PATH' STUB_BODY='$_WRONG' STUB_HTTP=200 '$PF' --b2-only --env-file '$_cenv'"

  # Kapabilitas kurang -> mount akan gagal nanti dengan pesan yang tidak jelas.
  _othin="$(_b2 "$_THIN" 200 || true)"
  assert_contains "kapabilitas kurang disebut namanya" "$_othin" "readFiles"

  rm -rf "$_cd" "$_cenv"
fi
