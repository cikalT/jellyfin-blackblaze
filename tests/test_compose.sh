# shellcheck shell=bash
# Diuji: docker-compose.yml

ROOT="$(cd .. && pwd)"
COMPOSE="$ROOT/docker-compose.yml"

assert_ok "docker-compose.yml ada" "[[ -f '$COMPOSE' ]]"

if [[ -f "$COMPOSE" ]]; then
  _c="$(cat "$COMPOSE")"

  # Batasan keamanan: mount media harus read-only, dan harus memakai
  # propagasi rslave supaya container ikut melihat mount rclone yang
  # dipasang ulang. Tanpa rslave, restart rclone membuat library terlihat
  # kosong oleh Jellyfin.
  assert_contains "bind media read-only"          "$_c" "read_only: true"
  assert_contains "bind memakai propagasi rslave" "$_c" "propagation: rslave"

  # Port TIDAK BOLEH terikat ke semua interface.
  assert_contains "port terikat ke JELLYFIN_BIND" "$_c" '${JELLYFIN_BIND}:${JELLYFIN_PORT}:8096'
  # Baris komentar dilewati: komentar yang memperingatkan bahaya 0.0.0.0
  # justru berguna, yang dilarang adalah konfigurasi sungguhannya.
  assert_fail     "tidak ada bind 0.0.0.0" \
    "grep -vE '^[[:space:]]*#' '$COMPOSE' | grep -q '0\.0\.0\.0'"

  # Image harus dari variabel (yang sudah dipastikan ter-pin oleh Task 2),
  # tidak pernah ':latest' langsung di sini.
  assert_fail     "tidak ada tag :latest" \
    "grep -vE '^[[:space:]]*#' '$COMPOSE' | grep -q ':latest'"

  # Batas memori wajib: 2 GB RAM tanpa batas berarti OOM killer bisa
  # membunuh sshd dan mengunci kita dari server.
  assert_contains "batas memori diset"            "$_c" "mem_limit:"

  # Rotasi log wajib: disk hanya 40 GB.
  assert_contains "rotasi log dikonfigurasi"      "$_c" "max-size:"
fi

# Validasi skema penuh, kalau docker tersedia di mesin ini.
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  _fixture="$(mktemp -d)"
  cp "$ROOT/.env.example" "$_fixture/.env"
  # Isi placeholder supaya interpolasi menghasilkan compose yang valid.
  {
    echo "B2_KEY_ID=005test"
    echo "B2_APPLICATION_KEY=Ktest"
    echo "B2_BUCKET=test-bucket"
    echo "WG_ENDPOINT=203.0.113.10"
  } >> "$_fixture/.env"
  cp "$COMPOSE" "$_fixture/docker-compose.yml"
  assert_ok "docker compose config tervalidasi" \
    "docker compose --project-directory '$_fixture' config"
  rm -rf "$_fixture"
else
  printf '  \033[2mlewat\033[0m docker compose config (docker tidak tersedia di sini)\n'
fi
