# shellcheck shell=bash
# Diuji: scripts/lib/common.sh

LIB="$(cd .. && pwd)/scripts/lib/common.sh"

assert_ok       "common.sh ada"                  "[[ -f '$LIB' ]]"
assert_ok       "common.sh bisa di-source"       ". '$LIB'"

# die selalu keluar dengan status 1
assert_fail     "die keluar dengan status bukan 0" ". '$LIB'; die 'boom'"

# require_env menolak variabel yang tidak diset, menerima yang diset
assert_fail     "require_env menolak var kosong"   ". '$LIB'; unset FOO_XYZ; require_env FOO_XYZ"
assert_ok       "require_env menerima var terisi"  ". '$LIB'; FOO_XYZ=1; require_env FOO_XYZ"
assert_fail     "require_env menolak string kosong" ". '$LIB'; FOO_XYZ=''; require_env FOO_XYZ"

# Pesan kegagalan harus menyebut variabel mana yang hilang — kalau tidak,
# operator tidak tahu harus memperbaiki apa.
_msg="$( . "$LIB"; unset MISSING_ONE; require_env MISSING_ONE 2>&1 || true )"
assert_contains "require_env menyebut nama var yang hilang" "$_msg" "MISSING_ONE"

# require_cmd
assert_ok       "require_cmd menerima perintah nyata" ". '$LIB'; require_cmd bash"
assert_fail     "require_cmd menolak perintah palsu"  ". '$LIB'; require_cmd definitely_not_a_real_command_xyz"

# load_env
assert_fail     "load_env menolak file hilang"     ". '$LIB'; load_env /nonexistent/path/.env"

_tmp="$(mktemp)"; printf 'LOADED_VALUE=halo\n' > "$_tmp"
_got="$( . "$LIB"; load_env "$_tmp"; printf '%s' "$LOADED_VALUE" )"
assert_eq       "load_env meng-export nilai"       "$_got" "halo"
rm -f "$_tmp"

# repo_root harus menunjuk ke direktori yang berisi .env.example
_root="$( . "$LIB"; repo_root )"
assert_ok       "repo_root menemukan root repo"    "[[ -d '$_root/scripts' ]]"

# ── Guard: tidak boleh ada string berbentuk kunci di repo ────────────────────
# Pemindai rahasia mencocokkan BENTUK, bukan makna. Nilai dummy yang
# menyerupai kunci sungguhan memicu insiden palsu, dan repo yang rutin
# memicu alarm palsu melatih orang mengabaikan alarm sungguhan.
# Pola dirangkai dari dua potongan supaya baris ini tidak cocok dengan
# dirinya sendiri.
_keypat="Private""Key[[:space:]]*=[[:space:]]*[A-Za-z0-9+/]{40,}"
_hits="$(cd .. && grep -rlE "$_keypat" $(git ls-files) 2>/dev/null | tr '\n' ' ')"
assert_eq "tidak ada string berbentuk kunci privat di repo" "$_hits" ""

_b64pat="[A-Za-z0-9+/]{43}="
_hits2="$(cd .. && grep -rlE "$_b64pat" $(git ls-files) 2>/dev/null | tr '\n' ' ')"
assert_eq "tidak ada base64 44-karakter mirip kunci" "$_hits2" ""
