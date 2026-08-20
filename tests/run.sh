#!/usr/bin/env bash
# Menjalankan setiap tests/test_*.sh dan melaporkan total.
set -uo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
# shellcheck source=tests/assert.sh
. ./assert.sh

for t in test_*.sh; do
  [[ -e "$t" ]] || continue
  printf '\n\033[1m%s\033[0m\n' "$t"
  # shellcheck disable=SC1090
  . "./$t"
done

printf '\n%d tes dijalankan, %d gagal\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
