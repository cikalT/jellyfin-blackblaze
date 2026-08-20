#!/usr/bin/env bash
# Memunculkan alasan sesungguhnya kenapa rclone-b2.service gagal start.
#
# Perintah rclone-nya DIAMBIL DARI UNIT YANG TERPASANG, bukan ditulis ulang
# di sini. Menyalinnya berarti skrip ini bisa menguji perintah yang berbeda
# dari yang sungguhan dijalankan systemd — persis kelas bug yang sedang
# kita cari.
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "$HERE/lib/common.sh"
set +e

UNIT="${UNIT:-/etc/systemd/system/rclone-b2.service}"
ENVF="${ENVF:-/etc/jellyfin-b2/env}"
SECONDS_TO_RUN="${SECONDS_TO_RUN:-20}"

ok()  { printf '  \033[0;32mok\033[0m    %s\n' "$*"; }
bad() { printf '  \033[0;31mGAGAL\033[0m %s\n' "$*"; }

[[ -f "$UNIT" ]] || die "unit tidak ditemukan: $UNIT (jalankan bootstrap dulu)"
[[ -f "$ENVF" ]] || die "env tidak ditemukan: $ENVF (jalankan bootstrap dulu)"
set -a
# shellcheck disable=SC1090
. "$ENVF"
set +a

# ── 1. Prasyarat FUSE ────────────────────────────────────────────────────────
log "1/4  Prasyarat FUSE"
# check <perintah> <pesan-ok> <pesan-gagal>
check() { if eval "$1" >/dev/null 2>&1; then ok "$2"; else bad "$3"; fi; }

check "[[ -e /dev/fuse ]]" \
  "/dev/fuse ada" \
  "/dev/fuse tidak ada — kernel tanpa dukungan FUSE"
check "command -v fusermount3" \
  "fusermount3 ada" \
  "fusermount3 tidak ada — apt-get install fuse3"
check "grep -q '^user_allow_other' /etc/fuse.conf" \
  "user_allow_other aktif di /etc/fuse.conf" \
  "user_allow_other belum ada di /etc/fuse.conf — --allow-other akan ditolak"
# Port RC yang masih dipegang proses yatim adalah penyebab paling umum
# kegagalan start, dan pesan rclone-nya ("address already in use") terkubur
# di balik "control process exited with error code" milik systemd.
_rcport="${RCLONE_RC_ADDR##*:}"
if ss -tlnp 2>/dev/null | grep -q ":${_rcport}[[:space:]]"; then
  bad "port RC ${_rcport} sudah dipakai proses lain — inilah penyebabnya"
  ss -tlnpa 2>/dev/null | grep ":${_rcport}[[:space:]]" | sed 's/^/    /'
  command -v fuser >/dev/null 2>&1 && fuser -v "${_rcport}/tcp" 2>&1 | sed 's/^/    /'
  printf '\n'
  die "Port RC masih dipegang. 'systemctl stop' saja sering tidak cukup:
  kalau unit sedang dalam loop auto-restart, job stop-nya dibatalkan dan
  loop menyambar portnya lagi. Hentikan loop-nya, bukan instance-nya:

      systemctl disable --now rclone-b2
      systemctl reset-failed rclone-b2
      pkill -9 -f rclone
      sleep 3
      systemctl enable --now rclone-b2"
else
  ok "port RC ${_rcport} bebas"
fi

if mountpoint -q "$MEDIA_MOUNT" 2>/dev/null; then
  bad "$MEDIA_MOUNT sudah ter-mount — hentikan service dulu"
else
  ok "$MEDIA_MOUNT belum ter-mount"
fi

# ── 2. Versi rclone ──────────────────────────────────────────────────────────
log "2/4  rclone"
command -v rclone >/dev/null || die "rclone tidak terpasang"
rclone version | head -1 | sed 's/^/    /'

# ── 3. Auth dan bucket, terpisah dari FUSE ───────────────────────────────────
# Memisahkan dua kemungkinan: kredensial/bucket salah, atau mount/FUSE yang
# bermasalah. Tanpa pemisahan ini keduanya terlihat sama dari luar.
log "3/4  Akses B2 (tanpa mount)"
if _out="$(rclone --config /etc/rclone/rclone.conf lsd "b2:${B2_BUCKET}" 2>&1)"; then
  ok "bucket '${B2_BUCKET}' bisa dibaca rclone"
  if [[ -n "$_out" ]]; then
    printf '%s\n' "$_out" | sed 's/^/    /'
  else
    info "(bucket kosong — normal kalau belum upload apa pun)"
  fi
else
  bad "rclone tidak bisa membaca bucket:"
  printf '%s\n' "$_out" | sed 's/^/    /'
  die "Masalahnya di kredensial atau nama bucket, bukan di mount.
  Periksa dengan: ./scripts/preflight.sh --b2-only"
fi

# ── 4. Jalankan perintah unit yang sesungguhnya, di foreground ───────────────
log "4/4  Menjalankan perintah mount dari unit (${SECONDS_TO_RUN} detik, verbose)"

cmd="$(awk '
  /^ExecStart=/ { inblock=1; sub(/^ExecStart=/,"") }
  inblock {
    line=$0
    cont = (line ~ /\\[[:space:]]*$/)
    sub(/\\[[:space:]]*$/,"",line)
    printf "%s ", line
    if (!cont) exit
  }' "$UNIT")"

# --syslog membuang output ke journal; di sini kita justru ingin melihatnya.
cmd="${cmd//--syslog/}"
cmd="${cmd//--log-level INFO/-vv}"

info "perintah yang diuji:"
printf '    %s\n\n' "$cmd"

eval "timeout ${SECONDS_TO_RUN} ${cmd}" 2>&1 | sed 's/^/    /'
_rc=${PIPESTATUS[0]}

printf '\n'
case "$_rc" in
  124) log "rclone bertahan ${SECONDS_TO_RUN} detik tanpa keluar — mount-nya sendiri sehat.
  Kalau service tetap gagal, masalahnya di systemd (Type=notify, urutan, atau
  MemoryMax), bukan di rclone. Kirim: journalctl -u rclone-b2 -n 40 --no-pager" ;;
  0)   warn "rclone keluar dengan status 0 lebih cepat dari perkiraan." ;;
  *)   die "rclone keluar dengan status ${_rc}. Alasannya ada di output verbose di atas —
  baris terakhir sebelum keluar biasanya menyebutkan penyebabnya." ;;
esac
