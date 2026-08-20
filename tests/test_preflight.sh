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
JELLYFIN_BIND=127.0.0.1
JELLYFIN_PORT=8096
JELLYFIN_MEM_LIMIT=1200m
JELLYFIN_UID=1000
JELLYFIN_GID=1000
JELLYFIN_DATA=/opt/jellyfin
TZ=Asia/Jakarta
JELLYFIN_API_KEY=
JELLYFIN_PUBLISHED_URL=
TS_HOSTNAME=jellyfin
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
  assert_contains "pesan menjelaskan risiko bind" "$_msg2" "127.0.0.1"

  # Image tidak ter-pin harus ditolak.
  _latest="$(_mkenv)"; sed -i.bak 's|^JELLYFIN_IMAGE=.*|JELLYFIN_IMAGE=jellyfin/jellyfin:latest|' "$_latest"
  assert_fail "image :latest ditolak" "'$PF' --config-only --env-file '$_latest'"

  # File env yang tidak ada harus gagal dengan jelas, bukan crash.
  assert_fail "env file hilang ditolak" "'$PF' --config-only --env-file /nope/.env"

  rm -f "$_good" "$_nokey" "$_public" "$_latest" \
        "$_nokey.bak" "$_public.bak" "$_latest.bak" 2>/dev/null || true
fi
