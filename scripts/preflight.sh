#!/usr/bin/env bash
# Memvalidasi konfigurasi dan host SEBELUM bootstrap mengubah apa pun.
# Tidak pernah menulis apa pun ke sistem.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "$HERE/lib/common.sh"

CONFIG_ONLY=0
ENV_FILE="$(repo_root)/.env"

usage() {
  cat <<'USAGE'
Pemakaian: preflight.sh [opsi]

  --config-only      Hanya validasi .env. Lewati semua cek host dan jaringan.
                     Berguna di laptop; bootstrap memanggil tanpa flag ini.
  --env-file PATH    File env yang divalidasi (default: <root repo>/.env)
  -h, --help         Tampilkan bantuan ini
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config-only) CONFIG_ONLY=1 ;;
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
  require_cmd rclone

  local tmpcfg; tmpcfg="$(mktemp)"
  chmod 600 "$tmpcfg"
  # shellcheck disable=SC2064
  trap "rm -f '$tmpcfg'" RETURN
  cat > "$tmpcfg" <<CFG
[b2]
type = b2
account = ${B2_KEY_ID}
key = ${B2_APPLICATION_KEY}
CFG

  rclone --config "$tmpcfg" lsd "b2:${B2_BUCKET}" >/dev/null 2>&1 \
    || die "tidak bisa membaca bucket '${B2_BUCKET}'.

    Penyebab paling umum, berurutan:
      1. B2_KEY_ID diisi master Account ID, bukan applicationKeyId.
         B2 membalas 401 untuk ini. applicationKeyId adalah string yang
         muncul bersama key saat kamu membuatnya.
      2. B2_BUCKET diisi bucket ID (heksadesimal), bukan nama bucket.
      3. Application key tidak punya akses ke bucket ini."
  info "bucket '${B2_BUCKET}' bisa dibaca"

  # Kunci HARUS read-only. Kalau tulis berhasil, VPS yang dibobol bisa
  # menghapus seluruh library — jadi ini peringatan keras, bukan catatan kaki.
  if rclone --config "$tmpcfg" mkdir "b2:${B2_BUCKET}/.preflight-write-test" >/dev/null 2>&1; then
    rclone --config "$tmpcfg" rmdir "b2:${B2_BUCKET}/.preflight-write-test" >/dev/null 2>&1 || true
    warn "application key BISA MENULIS ke bucket. Buat ulang key dengan kapabilitas
    listBuckets, listFiles, readFiles saja — server ini tidak pernah perlu menulis."
  else
    info "application key bersifat read-only (benar)"
  fi

  local top; top="$(rclone --config "$tmpcfg" lsd "b2:${B2_BUCKET}" 2>/dev/null | awk '{print $NF}' | tr '\n' ' ')"
  if [[ -z "$top" ]]; then
    warn "bucket kosong. Upload media dulu — lihat docs/upload-windows.md"
  else
    info "folder teratas: $top"
  fi
}

# ── Main ─────────────────────────────────────────────────────────────────────

check_config
if (( CONFIG_ONLY == 0 )); then
  check_host
  check_wireguard
  check_b2
fi
log "Preflight lolos."
