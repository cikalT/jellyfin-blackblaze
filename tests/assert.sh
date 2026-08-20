#!/usr/bin/env bash
# Primitif assertion minimal. Di-source oleh tests/run.sh, bukan dieksekusi.
# Sengaja tidak memakai `set -e`: sebuah assertion yang gagal harus mencatat
# kegagalan lalu melanjutkan, bukan menghentikan seluruh suite.

TESTS_RUN=0
TESTS_FAILED=0

_pass() { TESTS_RUN=$((TESTS_RUN + 1)); printf '  \033[0;32mok\033[0m   %s\n' "$1"; }
_fail() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_FAILED=$((TESTS_FAILED + 1))
  printf '  \033[0;31mGAGAL\033[0m %s\n       %s\n' "$1" "$2"
}

# assert_ok <nama> <perintah>   — perintah harus keluar dengan status 0
assert_ok() {
  if ( eval "$2" ) >/dev/null 2>&1; then _pass "$1"; else _fail "$1" "harusnya sukses: $2"; fi
}

# assert_fail <nama> <perintah> — perintah harus keluar dengan status bukan 0
assert_fail() {
  if ( eval "$2" ) >/dev/null 2>&1; then _fail "$1" "harusnya gagal: $2"; else _pass "$1"; fi
}

# assert_contains <nama> <teks> <substring>
assert_contains() {
  if printf '%s' "$2" | grep -qF -- "$3"; then _pass "$1"; else _fail "$1" "tidak mengandung '$3' di: $2"; fi
}

# assert_eq <nama> <aktual> <harapan>
assert_eq() {
  if [[ "$2" == "$3" ]]; then _pass "$1"; else _fail "$1" "'$2' != '$3'"; fi
}
