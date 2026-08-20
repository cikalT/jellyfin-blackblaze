#!/usr/bin/env bash
# Memvalidasi konfigurasi dan host SEBELUM bootstrap mengubah apa pun.
# Tidak pernah menulis apa pun ke sistem.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "$HERE/lib/common.sh"

CONFIG_ONLY=0
B2_ONLY=0
ENV_FILE="$(repo_root)/.env"

usage() {
  cat <<'USAGE'
Pemakaian: preflight.sh [opsi]

  --config-only      Hanya validasi .env. Lewati semua cek host dan jaringan.
                     Berguna di laptop; bootstrap memanggil tanpa flag ini.
  --b2-only          Validasi .env + kredensial B2, lewati cek host.
                     Berguna saat B2 mendadak menolak dan kamu ingin tahu
                     apakah masalahnya di kunci.
  --env-file PATH    File env yang divalidasi (default: <root repo>/.env)
  -h, --help         Tampilkan bantuan ini
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config-only) CONFIG_ONLY=1 ;;
    --b2-only)     B2_ONLY=1 ;;
    --env-file)    ENV_FILE="${2:-}"; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             die "argumen tidak dikenal: $1" ;;
  esac
  shift
done

# ── Validasi konfigurasi ─────────────────────────────────────────────────────

check_config() {
  log "Memeriksa konfigurasi ($ENV_FILE)"
  load_env "$ENV_FILE"

  require_env B2_KEY_ID B2_APPLICATION_KEY B2_BUCKET \
              MEDIA_MOUNT VFS_CACHE_DIR VFS_CACHE_MAX_SIZE DIR_CACHE_TIME \
              RCLONE_RC_ADDR JELLYFIN_IMAGE JELLYFIN_BIND JELLYFIN_PORT \
              JELLYFIN_MEM_LIMIT JELLYFIN_UID JELLYFIN_GID JELLYFIN_DATA \
              TZ MONTHLY_QUOTA_GB QUOTA_WARN_PERCENT NET_INTERFACE \
              WG_INTERFACE WG_PORT WG_SUBNET WG_SERVER_IP WG_ENDPOINT WG_CLIENT_DIR

  # Jellyfin hanya boleh mendengar di interface WireGuard. Satu-satunya
  # pintu masuk adalah tunnel; tidak ada reverse proxy, rate limiting, atau
  # fail2ban yang melindunginya kalau bind-nya salah.
  [[ "$JELLYFIN_BIND" == "$WG_SERVER_IP" ]] || die \
    "JELLYFIN_BIND ('$JELLYFIN_BIND') tidak sama dengan WG_SERVER_IP ('$WG_SERVER_IP').
    Keduanya harus identik. Kalau berbeda, container gagal start (alamatnya
    belum ada) atau Jellyfin mendengar di tempat yang bisa dijangkau dari
    luar tunnel."

  [[ "$WG_SERVER_IP" =~ ^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.) ]] || die \
    "WG_SERVER_IP ('$WG_SERVER_IP') bukan alamat privat RFC1918.
    Gunakan sesuatu di 10.x.x.x, 172.16-31.x.x, atau 192.168.x.x."

  # Endpoint dipakai di setiap config client sebagai alamat tujuan dial.
  # Salah isi berarti config-nya terlihat benar tapi tidak pernah connect.
  [[ "$WG_ENDPOINT" =~ ^[0-9a-zA-Z.:-]+$ ]] || die \
    "WG_ENDPOINT ('$WG_ENDPOINT') tidak terlihat seperti IP atau hostname.
    Isi dengan IP publik VPS — cek dengan: curl -s ifconfig.me"

  # Tag mengambang berarti upgrade diam-diam saat container di-recreate —
  # di server 2 GB, upgrade tak terduga adalah cara yang bagus untuk kehilangan
  # akhir pekan.
  [[ "$JELLYFIN_IMAGE" =~ :[0-9]+\.[0-9]+\.[0-9]+$ ]] || die \
    "JELLYFIN_IMAGE harus di-pin ke versi persis (mis. jellyfin/jellyfin:10.11.11),
    bukan '$JELLYFIN_IMAGE'."

  [[ "$DIR_CACHE_TIME" == "1h" ]] || warn \
    "DIR_CACHE_TIME adalah '$DIR_CACHE_TIME', bukan 1h. File yang baru diupload
    akan butuh waktu lebih lama untuk muncul."

  info "konfigurasi valid"
}

# ── Cek host ─────────────────────────────────────────────────────────────────

check_host() {
  log "Memeriksa host"

  [[ "$(id -u)" -eq 0 ]] || die "harus dijalankan sebagai root (pakai sudo)"
  require_cmd apt-get systemctl
  [[ -e /dev/fuse ]] || die "/dev/fuse tidak ada — kernel tidak mendukung FUSE, rclone mount mustahil"

  local ram_mb; ram_mb=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 ))
  (( ram_mb >= 1800 )) || die "RAM $ram_mb MB terlalu kecil; butuh minimal ~2 GB"
  info "RAM: ${ram_mb} MB"

  local free_gb; free_gb=$(( $(df --output=avail -k / | tail -1) / 1024 / 1024 ))
  (( free_gb >= 20 )) || die "hanya ${free_gb} GB kosong di /; butuh minimal 20 GB"
  info "disk kosong: ${free_gb} GB"

  # Batas cache tidak boleh melebihi disk yang tersedia.
  local cache_gb="${VFS_CACHE_MAX_SIZE%G}"
  if [[ "$cache_gb" =~ ^[0-9]+$ ]] && (( cache_gb + 10 > free_gb )); then
    die "VFS_CACHE_MAX_SIZE=${VFS_CACHE_MAX_SIZE} terlalu besar untuk ${free_gb} GB yang tersisa"
  fi
}

# ── Cek WireGuard ────────────────────────────────────────────────────────────

check_wireguard() {
  log "Memeriksa WireGuard"

  # Kernel Debian 12 sudah membawa WireGuard, tapi VPS dengan kernel
  # kustom kadang tidak. Lebih baik ketahuan sekarang.
  if ! modprobe wireguard 2>/dev/null && [[ ! -d /sys/module/wireguard ]]; then
    warn "modul kernel wireguard tidak bisa dimuat. wg-quick mungkin gagal.
    Cek dengan: modinfo wireguard"
  else
    info "modul kernel wireguard tersedia"
  fi

  # Typo di WG_ENDPOINT menghasilkan config client yang terlihat benar tapi
  # tidak pernah connect — gejala yang sangat sulit didiagnosis dari sisi HP.
  local detected
  detected="$(curl -fsS --max-time 10 https://ifconfig.me 2>/dev/null || true)"
  if [[ -n "$detected" && "$detected" != "$WG_ENDPOINT" ]]; then
    warn "WG_ENDPOINT diisi '$WG_ENDPOINT' tapi IP publik server terdeteksi '$detected'.
    Kalau server ini di belakang NAT, itu wajar. Kalau tidak, config client
    akan dibuat dengan alamat tujuan yang salah dan tidak akan pernah connect."
  else
    info "endpoint cocok dengan IP publik: ${WG_ENDPOINT}"
  fi
}

# ── Cek B2 ───────────────────────────────────────────────────────────────────

check_b2() {
  log "Memeriksa kredensial Backblaze B2"
  # curl, bukan rclone. rclone baru dipasang oleh bootstrap, sehingga
  # memakainya di sini membuat preflight mustahil lolos di server bersih.
  command -v curl >/dev/null 2>&1 || die \
    "curl belum terpasang. Jalankan dulu:  apt-get update && apt-get install -y curl"

  local resp http body
  resp="$(curl -sS -m 20 -w $'\n%{http_code}' \
    -u "${B2_KEY_ID}:${B2_APPLICATION_KEY}" \
    https://api.backblazeb2.com/b2api/v4/b2_authorize_account 2>/dev/null || true)"
  http="$(printf '%s' "$resp" | tail -n1)"
  body="$(printf '%s' "$resp" | sed '$d' | tr -d ' \n\t')"

  case "$http" in
    200) : ;;
    401) die "B2 menolak kredensial (HTTP 401).

    Penyebab paling umum: B2_KEY_ID diisi *master Account ID* dari halaman
    akun, bukan applicationKeyId. Keduanya nilai yang berbeda.
    applicationKeyId adalah string yang muncul BERSAMA kunci saat kamu
    menekan 'Create New Key' di halaman Application Keys." ;;
    "")  die "tidak ada respons dari B2. Server ini bisa menjangkau internet?" ;;
    *)   die "B2 membalas HTTP $http (diharapkan 200). Cek koneksi jaringan server." ;;
  esac
  info "kredensial diterima B2"

  # Kapabilitas dibaca langsung dari respons — tidak perlu lagi membuktikan
  # sifat read-only dengan mencoba menulis ke bucket pengguna.
  local caps missing_caps=""
  caps="$(printf '%s' "$body" | grep -o '"capabilities":\[[^]]*\]' || true)"
  [[ -n "$caps" ]] || die "respons B2 tidak memuat daftar kapabilitas — bentuk API berubah?"

  local need
  for need in listBuckets listFiles readFiles; do
    printf '%s' "$caps" | grep -q "\"${need}\"" || missing_caps="$missing_caps $need"
  done
  [[ -z "$missing_caps" ]] || die \
    "application key tidak punya kapabilitas:${missing_caps}
    Buat ulang kunci dengan Type of Access = Read Only."

  local bad
  for bad in writeFiles deleteFiles deleteBuckets writeBuckets; do
    if printf '%s' "$caps" | grep -q "\"${bad}\""; then
      warn "application key BISA MENULIS ke bucket (punya '${bad}').
    Server ini tidak pernah perlu menulis. Buat ulang kunci dengan
    Type of Access = Read Only, supaya VPS yang dibobol tidak bisa
    menghapus library-mu."
      break
    fi
  done

  # Cakupan bucket. Kunci yang dibatasi ke satu bucket akan menyebut
  # namanya di sini — sekaligus membuktikan bucket itu memang ada.
  if printf '%s' "$body" | grep -q "\"name\":\"${B2_BUCKET}\""; then
    info "kunci dibatasi ke bucket '${B2_BUCKET}' (benar)"
  elif printf '%s' "$body" | grep -qE '"buckets":(\[\]|null)' || ! printf '%s' "$body" | grep -q '"buckets"'; then
    warn "application key tidak dibatasi ke bucket mana pun.
    Buat ulang kunci dengan 'Allow access to Bucket(s)' diarahkan ke
    '${B2_BUCKET}' saja."
  else
    die "application key tidak punya akses ke bucket '${B2_BUCKET}'.
    Kunci ini dibatasi ke bucket lain. Cek B2_BUCKET di .env, atau buat
    kunci baru yang diarahkan ke bucket yang benar."
  fi
}

# ── Main ─────────────────────────────────────────────────────────────────────

check_config
if (( B2_ONLY )); then
  check_b2
elif (( CONFIG_ONLY == 0 )); then
  check_host
  check_wireguard
  check_b2
fi
log "Preflight lolos."
