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
for v in B2_ACCOUNT_ID B2_APPLICATION_KEY B2_BUCKET; do
  assert_ok "$v ada di .env.example" "grep -qE '^${v}=' '$ENVX'"
done

# Batasan keras dari spec, dikunci di sini supaya tidak diam-diam berubah.
assert_ok "bind Jellyfin adalah 127.0.0.1" "grep -qE '^JELLYFIN_BIND=127\.0\.0\.1$' '$ENVX'"
assert_ok "dir-cache-time adalah 1h"       "grep -qE '^DIR_CACHE_TIME=1h$'        '$ENVX'"
assert_ok "cache VFS dibatasi 10G"         "grep -qE '^VFS_CACHE_MAX_SIZE=10G$'   '$ENVX'"
assert_ok "image Jellyfin di-pin (bukan latest)" "grep -qE '^JELLYFIN_IMAGE=jellyfin/jellyfin:[0-9]+\.[0-9]+\.[0-9]+$' '$ENVX'"
