# shellcheck shell=bash
# Diuji: systemd/rclone-b2.service dan drop-in Docker.

ROOT="$(cd .. && pwd)"
UNIT="$ROOT/systemd/rclone-b2.service"
DROPIN="$ROOT/systemd/docker-after-deps.conf"

assert_ok "unit rclone ada"    "[[ -f '$UNIT' ]]"
assert_ok "drop-in docker ada" "[[ -f '$DROPIN' ]]"

if [[ -f "$UNIT" ]]; then
  _u="$(cat "$UNIT")"

  # Type=notify berarti systemd menganggap unit ini "started" hanya setelah
  # mount benar-benar siap. Semua pengurutan boot bergantung pada ini.
  assert_contains "Type=notify"            "$_u" "Type=notify"

  # Read-only bukan preferensi — ini yang mencegah Jellyfin menulis artwork
  # ke B2 dan mencegah penghapusan tak sengaja.
  assert_contains "mount read-only"        "$_u" "--read-only"

  # Batas keras terhadap disk 40 GB.
  assert_contains "batas ukuran cache VFS" "$_u" "--vfs-cache-max-size"
  assert_contains "mode cache VFS full"    "$_u" "--vfs-cache-mode full"

  # Endpoint RC dipakai refresh-library.sh.
  assert_contains "RC diaktifkan"          "$_u" "--rc"

  # B2 tidak mendukung change-notify; polling harus dimatikan eksplisit.
  assert_contains "polling dimatikan"      "$_u" "--poll-interval 0"

  # Pemulihan otomatis kalau rclone mati.
  assert_contains "restart on-failure"     "$_u" "Restart=on-failure"

  # Unmount saat berhenti, kalau tidak mount jadi basi dan I/O menggantung.
  assert_contains "unmount saat stop"      "$_u" "fusermount"

  # rclone tidak boleh ikut menghabiskan RAM 2 GB.
  assert_contains "batas memori rclone"    "$_u" "MemoryMax="

  # Rahasia hanya boleh datang dari file, tidak pernah tertulis di unit.
  assert_fail     "tidak ada kunci B2 di unit"      "grep -qE 'K00[0-9A-Za-z]{20,}' '$UNIT'"
  assert_contains "kredensial dari EnvironmentFile" "$_u" "EnvironmentFile="
fi

if [[ -f "$DROPIN" ]]; then
  _d="$(cat "$DROPIN")"
  # Docker harus menunggu mount. Kalau tidak, container yang auto-start saat
  # boot melihat /srv/media kosong.
  assert_contains "docker menunggu mount"     "$_d" "rclone-b2.service"
  assert_contains "docker menunggu wireguard" "$_d" "wg-quick@wg0.service"
  assert_contains "docker butuh keduanya"     "$_d" "Requires="
fi

# Validasi sintaks penuh kalau systemd tersedia (Linux saja).
if command -v systemd-analyze >/dev/null 2>&1; then
  # systemd-analyze mengeluh soal executable yang tidak ada di mesin build;
  # yang kita pedulikan adalah kesalahan sintaks dan direktif tak dikenal.
  _sa="$(systemd-analyze verify "$UNIT" 2>&1 | grep -viE 'not executable|does not exist' || true)"
  assert_eq "unit lolos systemd-analyze verify" "$_sa" ""
else
  printf '  \033[2mlewat\033[0m systemd-analyze (bukan Linux)\n'
fi
