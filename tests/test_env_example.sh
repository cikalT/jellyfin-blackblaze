# shellcheck shell=bash
# Diuji: .env.example lengkap terhadap setiap ${VAR} yang dirujuk template.

ROOT="$(cd .. && pwd)"
ENVX="$ROOT/.env.example"

assert_ok ".env.example ada" "[[ -f '$ENVX' ]]"

# Setiap ${VAR} di template harus terdokumentasi di .env.example.
# Hanya file template murni yang dipindai — skrip shell punya variabel lokal
# sendiri yang bukan urusan konfigurasi.
_templates=()
for f in "$ROOT/docker-compose.yml" "$ROOT/systemd/rclone-b2.service"; do
  [[ -f "$f" ]] && _templates+=("$f")
done

if (( ${#_templates[@]} > 0 )); then
  _refs="$(grep -ohE '\$\{[A-Z][A-Z0-9_]*\}' "${_templates[@]}" | tr -d '${}' | sort -u)"
  _undocumented=""
  while IFS= read -r v; do
    [[ -n "$v" ]] || continue
    grep -qE "^${v}=" "$ENVX" || _undocumented="$_undocumented $v"
  done <<< "$_refs"
  assert_eq "setiap \${VAR} template ada di .env.example" "$_undocumented" ""
fi

# Variabel yang tidak boleh punya nilai default terisi — kalau terisi, operator
# akan menjalankan setup dengan kredensial contoh dan bingung kenapa gagal.
for v in B2_KEY_ID B2_APPLICATION_KEY B2_BUCKET; do
  assert_ok "$v ada di .env.example" "grep -qE '^${v}=' '$ENVX'"
done

# Dua nilai B2 yang paling sering salah diisi. Keduanya gagal dengan cara
# yang membingungkan: applicationKeyId yang keliru menghasilkan 401, dan
# bucket ID yang keliru menghasilkan "bucket tidak ditemukan". Dokumentasinya
# harus menyebut perbedaan itu eksplisit, bukan cuma menamai variabelnya.
_envx_body="$(cat "$ENVX")"
assert_fail     "tidak memakai nama B2_ACCOUNT_ID yang menyesatkan" \
  "grep -q 'B2_ACCOUNT_ID' '$ENVX'"
assert_contains "menjelaskan applicationKeyId" "$_envx_body" "applicationKeyId"
assert_contains "memperingatkan bukan master Account ID" "$_envx_body" "BUKAN master Account ID"
assert_contains "menjelaskan nama bucket bukan bucket ID" "$_envx_body" "bukan bucket ID"

# Batasan keras dari spec, dikunci di sini supaya tidak diam-diam berubah.
# Jellyfin harus mendengar HANYA di alamat WireGuard. Kalau kedua nilai ini
# berbeda, Jellyfin bind ke alamat yang tidak ada (container gagal start) atau
# ke alamat yang bisa dijangkau dari luar tunnel.
_bind="$(grep -E '^JELLYFIN_BIND=' "$ENVX" | cut -d= -f2)"
_wgip="$(grep -E '^WG_SERVER_IP=' "$ENVX" | cut -d= -f2)"
assert_eq "JELLYFIN_BIND sama dengan WG_SERVER_IP" "$_bind" "$_wgip"
assert_fail "bind bukan 0.0.0.0" "[[ '$_bind' == '0.0.0.0' ]]"
assert_ok   "bind adalah alamat privat RFC1918" \
  "printf '%s' '$_bind' | grep -qE '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)'"

# WireGuard: split tunnel dan endpoint wajib terdokumentasi.
for v in WG_INTERFACE WG_PORT WG_SUBNET WG_SERVER_IP WG_ENDPOINT WG_CLIENT_DIR; do
  assert_ok "$v ada di .env.example" "grep -qE '^${v}=' '$ENVX'"
done
assert_fail "WG_ENDPOINT dibiarkan kosong untuk diisi operator" "grep -qE '^WG_ENDPOINT=.+' '$ENVX'"
assert_fail "tidak ada sisa TS_HOSTNAME" "grep -q 'TS_HOSTNAME' '$ENVX'"
assert_ok "dir-cache-time adalah 1h"       "grep -qE '^DIR_CACHE_TIME=1h$'        '$ENVX'"
assert_ok "cache VFS dibatasi 10G"         "grep -qE '^VFS_CACHE_MAX_SIZE=10G$'   '$ENVX'"
assert_ok "image Jellyfin di-pin (bukan latest)" "grep -qE '^JELLYFIN_IMAGE=jellyfin/jellyfin:[0-9]+\.[0-9]+\.[0-9]+$' '$ENVX'"
