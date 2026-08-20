# Jellyfin + Backblaze B2 Implementation Plan

> **Untuk pekerja agentic:** REQUIRED SUB-SKILL: gunakan superpowers:subagent-driven-development (disarankan) atau superpowers:executing-plans untuk mengeksekusi plan ini task demi task. Langkah memakai sintaks checkbox (`- [ ]`) untuk pelacakan.

**Goal:** Menghasilkan repository berisi konfigurasi dan skrip yang, dijalankan di VPS Tencent Debian 12 kosong, menghasilkan Jellyfin yang menstream media dari Backblaze B2 dan hanya bisa diakses lewat Tailscale.

**Architecture:** rclone me-mount bucket B2 secara read-only ke `/srv/media` sebagai unit systemd di host. Jellyfin berjalan di Docker, membaca mount itu lewat bind read-only dengan propagasi `rslave`, dan hanya mendengar di `127.0.0.1`. Tailscale memaparkannya ke tailnet lewat `tailscale serve`. Tidak ada port yang terbuka ke internet.

**Tech Stack:** Debian 12, bash, Docker Compose v2, rclone (FUSE), systemd, Tailscale, Jellyfin 10.11.11, vnstat.

**Spec:** `docs/superpowers/specs/2026-08-20-jellyfin-b2-design.md`

## Global Constraints

Nilai berikut disalin verbatim dari spec dan berlaku untuk **semua** task.

- **Target OS:** Debian 12 (bookworm). Skrip memakai `apt-get` dan systemd.
- **Image Jellyfin di-pin:** `jellyfin/jellyfin:10.11.11`. Jangan pernah pakai `:latest`.
- **Mount bersifat read-only.** Tidak ada jalur kode yang boleh menulis ke B2.
- **Bind port:** Jellyfin HANYA mendengar di `127.0.0.1:8096`. Tidak boleh ada `0.0.0.0`.
- **Batas cache VFS:** `10G`, keras. Disk total hanya 40 GB.
- **`--dir-cache-time`:** `1h`. Bukan 24h — deteksi file baru bawaan Jellyfin bergantung pada ini.
- **Tidak ada rahasia di dalam repo.** Kredensial hanya lewat `.env` yang di-gitignore.
- **Semua skrip:** `#!/usr/bin/env bash` + `set -euo pipefail`, dan harus lolos `shellcheck`.
- **Semua skrip provisioning idempoten.** Aman dijalankan berkali-kali.
- **Bahasa:** pesan ke pengguna dan dokumentasi dalam Bahasa Indonesia; nama variabel dan fungsi dalam Bahasa Inggris.

### Catatan pengujian

Ini proyek infrastruktur, bukan aplikasi. "Test" berarti tiga hal berbeda, dan
plan ini memakai ketiganya secara eksplisit:

1. **Unit test** (`tests/`) — menjalankan fungsi bash sungguhan dengan stub di `PATH`. Berjalan di laptop mana pun, tanpa server.
2. **Validasi statis** — `shellcheck`, `docker compose config`, assertion berbasis grep terhadap file konfigurasi.
3. **Verifikasi di server** — 8 kriteria keberhasilan dari spec, dijalankan sekali setelah deploy (Task 9).

Task 1–8 sepenuhnya bisa diuji di laptop. Hanya Task 9 yang butuh VPS.

## File Structure

| File | Tanggung jawab |
|---|---|
| `scripts/lib/common.sh` | Logging, validasi, pemuatan env. Di-source oleh semua skrip lain. Tidak pernah dieksekusi langsung. |
| `scripts/preflight.sh` | Memvalidasi host dan kredensial. Tidak mengubah apa pun. |
| `scripts/bootstrap.sh` | Satu-satunya skrip yang mengubah sistem. Idempoten. |
| `scripts/refresh-library.sh` | Memaksa rclone melihat file baru, lalu memicu scan Jellyfin. |
| `scripts/healthcheck.sh` | Melaporkan sehat/tidaknya mount, container, disk. |
| `scripts/quota-check.sh` | Melaporkan pemakaian bandwidth bulanan terhadap kuota 512 GB. |
| `docker-compose.yml` | Definisi container Jellyfin. Murni template, semua nilai dari `.env`. |
| `systemd/rclone-b2.service` | Unit mount. Murni template. |
| `systemd/docker-after-mount.conf` | Drop-in yang menunda Docker sampai mount siap. |
| `.env.example` | Satu-satunya sumber kebenaran untuk seluruh parameter. |
| `tests/assert.sh` | Primitif assertion minimal. |
| `tests/run.sh` | Test runner. |
| `tests/test_*.sh` | Satu file per unit yang diuji. |
| `docs/*.md` | Dokumentasi operasional untuk manusia. |

**Batasan:** `common.sh` tidak boleh memuat pengetahuan khusus B2, Jellyfin, atau
Tailscale — hanya primitif generik. Ini yang membuatnya bisa diuji terpisah dan
mencegahnya berubah jadi tempat sampah.

---

### Task 1: Fondasi — pustaka bersama & harness tes

Task pertama harus menghasilkan sesuatu yang bisa diuji, jadi harness tes dan
pustaka bersama dibangun bersamaan. Semua task berikutnya bergantung pada ini.

**Files:**
- Create: `tests/assert.sh`
- Create: `tests/run.sh`
- Create: `tests/test_common.sh`
- Create: `scripts/lib/common.sh`

**Interfaces:**
- Consumes: tidak ada.
- Produces: `scripts/lib/common.sh` mengekspor fungsi shell —
  `log(msg)`, `info(msg)`, `warn(msg)` (ke stderr), `die(msg)` (stderr, exit 1),
  `require_cmd(cmd...)` (exit 1 jika ada yang hilang, menyebut nama yang hilang),
  `require_env(varname...)` (exit 1 jika ada yang kosong/tidak diset),
  `load_env(path)` (exit 1 jika file tidak ada; selain itu meng-export semua isinya),
  `repo_root()` (mencetak path absolut root repo).
  `tests/assert.sh` mengekspor `assert_ok`, `assert_fail`, `assert_contains`, `assert_eq`
  dan variabel `TESTS_RUN`, `TESTS_FAILED`.

- [ ] **Step 1: Tulis primitif assertion**

Buat `tests/assert.sh`:

```bash
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
```

- [ ] **Step 2: Tulis test runner**

Buat `tests/run.sh`:

```bash
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
```

- [ ] **Step 3: Tulis tes yang gagal untuk common.sh**

Buat `tests/test_common.sh`:

```bash
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
```

- [ ] **Step 4: Jalankan tes untuk memastikan GAGAL**

```bash
bash tests/run.sh
```

Harapan: GAGAL. Assertion pertama ("common.sh ada") gagal karena filenya belum
dibuat, dan seluruh assertion sesudahnya ikut gagal.

- [ ] **Step 5: Implementasikan common.sh**

Buat `scripts/lib/common.sh`:

```bash
#!/usr/bin/env bash
# Primitif bersama. DI-SOURCE, bukan dieksekusi.
# Sengaja tidak tahu apa-apa soal B2, Jellyfin, atau Tailscale — hanya
# primitif generik, supaya bisa diuji tanpa server dan tidak berubah jadi
# tempat sampah.

set -euo pipefail

if [[ -t 1 ]]; then
  C_RED=$'\033[0;31m'; C_YLW=$'\033[0;33m'; C_GRN=$'\033[0;32m'
  C_DIM=$'\033[2m';    C_RST=$'\033[0m'
else
  C_RED=''; C_YLW=''; C_GRN=''; C_DIM=''; C_RST=''
fi

log()  { printf '%s==>%s %s\n'  "$C_GRN" "$C_RST" "$*"; }
info() { printf '%s    %s%s\n'  "$C_DIM" "$*" "$C_RST"; }
warn() { printf '%sPERINGATAN:%s %s\n' "$C_YLW" "$C_RST" "$*" >&2; }
die()  { printf '%sGAGAL:%s %s\n'      "$C_RED" "$C_RST" "$*" >&2; exit 1; }

# require_cmd <cmd>... — gagal kalau ada yang tidak ada di PATH.
require_cmd() {
  local missing=() c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  (( ${#missing[@]} == 0 )) || die "perintah tidak ditemukan: ${missing[*]}"
}

# require_env <VARNAME>... — gagal kalau ada yang tidak diset atau kosong.
require_env() {
  local missing=() v
  for v in "$@"; do
    [[ -n "${!v:-}" ]] || missing+=("$v")
  done
  (( ${#missing[@]} == 0 )) || die "variabel .env kosong atau belum diisi: ${missing[*]}"
}

# load_env <path> — meng-export semua isi file env.
load_env() {
  local f="${1:-}"
  [[ -f "$f" ]] || die "file env tidak ditemukan: $f (salin .env.example jadi .env dulu)"
  set -a
  # shellcheck disable=SC1090
  . "$f"
  set +a
}

# repo_root — path absolut root repo, diturunkan dari lokasi file ini.
repo_root() {
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd
}
```

- [ ] **Step 6: Jalankan tes untuk memastikan LULUS**

```bash
bash tests/run.sh
```

Harapan: LULUS. `0 gagal`.

- [ ] **Step 7: Commit**

```bash
chmod +x tests/run.sh
git add tests/ scripts/lib/common.sh
git commit -m "feat: pustaka shell bersama + harness tes"
```

---

### Task 2: `.env.example` dan tes kelengkapannya

`.env.example` adalah satu-satunya sumber kebenaran untuk konfigurasi. Bahaya
terbesarnya adalah drift: sebuah template merujuk `${FOO}` yang tidak pernah
didokumentasikan, lalu bootstrap gagal di server dengan pesan membingungkan.
Task ini membuat drift itu mustahil dengan menjadikannya kegagalan tes.

**Files:**
- Create: `.env.example`
- Create: `tests/test_env_example.sh`

**Interfaces:**
- Consumes: `tests/assert.sh` dari Task 1.
- Produces: nama variabel yang dipakai Task 3 (`docker-compose.yml`), Task 4
  (unit systemd), dan Task 5–8 (skrip). Daftar lengkap ada di Step 1.

- [ ] **Step 1: Tulis tes yang gagal**

Buat `tests/test_env_example.sh`:

```bash
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
```

- [ ] **Step 2: Jalankan tes untuk memastikan GAGAL**

```bash
bash tests/run.sh
```

Harapan: GAGAL pada ".env.example ada".

- [ ] **Step 3: Tulis .env.example**

Buat `.env.example`:

```bash
# Salin file ini jadi `.env` lalu isi. `.env` tidak pernah di-commit.
#   cp .env.example .env && nano .env

# ─── Backblaze B2 ────────────────────────────────────────────────────────────
# Buat application key yang DIBATASI ke satu bucket, dengan kapabilitas
# listBuckets, listFiles, readFiles saja. Server tidak pernah menulis ke B2.
B2_ACCOUNT_ID=
B2_APPLICATION_KEY=
B2_BUCKET=

# ─── Mount rclone ────────────────────────────────────────────────────────────
MEDIA_MOUNT=/srv/media
VFS_CACHE_DIR=/var/cache/rclone
# Batas keras. Disk hanya 40 GB — jangan dinaikkan tanpa menghitung ulang
# anggaran disk di bagian 9 spec.
VFS_CACHE_MAX_SIZE=10G
# 1 jam. Inilah yang membuat deteksi file baru bawaan Jellyfin berfungsi.
# Menaikkannya berarti file baru tidak akan muncul otomatis.
DIR_CACHE_TIME=1h
RCLONE_RC_ADDR=127.0.0.1:5572

# ─── Jellyfin ────────────────────────────────────────────────────────────────
JELLYFIN_IMAGE=jellyfin/jellyfin:10.11.11
# HARUS 127.0.0.1. Paparan ke tailnet dilakukan `tailscale serve`, bukan
# dengan membuka port. Mengubah ini mengekspos Jellyfin ke internet.
JELLYFIN_BIND=127.0.0.1
JELLYFIN_PORT=8096
JELLYFIN_MEM_LIMIT=1200m
JELLYFIN_UID=1000
JELLYFIN_GID=1000
JELLYFIN_DATA=/opt/jellyfin
TZ=Asia/Jakarta

# Diisi SETELAH wizard awal Jellyfin selesai:
# Dashboard -> Advanced -> API Keys -> New API Key.
# Dipakai refresh-library.sh dan healthcheck.sh. Boleh kosong sampai saat itu.
JELLYFIN_API_KEY=

# URL yang diumumkan ke client. Isi setelah `tailscale serve` aktif, mis.
# https://jellyfin.contoh-tailnet.ts.net
JELLYFIN_PUBLISHED_URL=

# ─── Tailscale ───────────────────────────────────────────────────────────────
TS_HOSTNAME=jellyfin

# ─── Kuota bandwidth ─────────────────────────────────────────────────────────
MONTHLY_QUOTA_GB=512
QUOTA_WARN_PERCENT=80
# Interface yang dipantau vnstat. Cek dengan: ip -o -4 route show to default
NET_INTERFACE=eth0
```

- [ ] **Step 4: Jalankan tes untuk memastikan LULUS**

```bash
bash tests/run.sh
```

Harapan: LULUS. Cek `${VAR}` masih kosong karena `docker-compose.yml` dan unit
systemd belum ada — cek itu akan aktif sendiri di Task 3 dan 4.

- [ ] **Step 5: Commit**

```bash
git add .env.example tests/test_env_example.sh
git commit -m "feat: .env.example sebagai sumber kebenaran konfigurasi tunggal"
```

---

### Task 3: Definisi container Jellyfin

**Files:**
- Create: `docker-compose.yml`
- Create: `tests/test_compose.sh`

**Interfaces:**
- Consumes: variabel dari `.env.example` (Task 2) — `JELLYFIN_IMAGE`, `JELLYFIN_UID`,
  `JELLYFIN_GID`, `JELLYFIN_MEM_LIMIT`, `TZ`, `JELLYFIN_PUBLISHED_URL`, `JELLYFIN_BIND`,
  `JELLYFIN_PORT`, `JELLYFIN_DATA`, `MEDIA_MOUNT`.
- Produces: service Docker bernama `jellyfin` di project `jellyfin-b2`.
  Task 6 memanggilnya lewat `docker compose up -d`; Task 8 lewat `docker inspect jellyfin`.

- [ ] **Step 1: Tulis tes yang gagal**

Buat `tests/test_compose.sh`:

```bash
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
  assert_contains "bind media read-only"        "$_c" "read_only: true"
  assert_contains "bind memakai propagasi rslave" "$_c" "propagation: rslave"

  # Port TIDAK BOLEH terikat ke semua interface.
  assert_ok "port terikat ke \${JELLYFIN_BIND}" \
    "grep -qE '\"\\\$\{JELLYFIN_BIND\}:\\\$\{JELLYFIN_PORT\}:8096\"' '$COMPOSE'"
  assert_fail "tidak ada bind 0.0.0.0" "grep -q '0\.0\.0\.0' '$COMPOSE'"

  # Image harus dari variabel (yang sudah dipastikan ter-pin oleh Task 2),
  # tidak pernah ':latest' langsung di sini.
  assert_fail "tidak ada tag :latest" "grep -q ':latest' '$COMPOSE'"

  # Batas memori wajib: 2 GB RAM tanpa batas berarti OOM killer bisa
  # membunuh sshd dan mengunci kita dari server.
  assert_contains "batas memori diset" "$_c" "mem_limit:"

  # Rotasi log wajib: disk hanya 40 GB.
  assert_contains "rotasi log dikonfigurasi" "$_c" "max-size:"
fi

# Validasi skema penuh, kalau docker tersedia di mesin ini.
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  _fixture="$(mktemp -d)"
  cp "$ROOT/.env.example" "$_fixture/.env"
  # Isi placeholder supaya interpolasi menghasilkan compose yang valid.
  {
    echo "B2_ACCOUNT_ID=005test"
    echo "B2_APPLICATION_KEY=Ktest"
    echo "B2_BUCKET=test-bucket"
    echo "JELLYFIN_PUBLISHED_URL=https://jellyfin.example.ts.net"
  } >> "$_fixture/.env"
  cp "$COMPOSE" "$_fixture/docker-compose.yml"
  assert_ok "docker compose config tervalidasi" \
    "docker compose --project-directory '$_fixture' config"
  rm -rf "$_fixture"
else
  printf '  \033[2mlewat\033[0m docker compose config (docker tidak tersedia di sini)\n'
fi
```

- [ ] **Step 2: Jalankan tes untuk memastikan GAGAL**

```bash
bash tests/run.sh
```

Harapan: GAGAL pada "docker-compose.yml ada".

- [ ] **Step 3: Tulis docker-compose.yml**

Buat `docker-compose.yml`:

```yaml
name: jellyfin-b2

services:
  jellyfin:
    image: ${JELLYFIN_IMAGE}
    container_name: jellyfin
    user: "${JELLYFIN_UID}:${JELLYFIN_GID}"
    restart: unless-stopped

    # 2 GB RAM total. Tanpa batas ini, scan library yang boros bisa memicu
    # OOM killer dan korbannya sering sshd — yang berarti kita terkunci
    # dari server.
    mem_limit: ${JELLYFIN_MEM_LIMIT}

    environment:
      TZ: ${TZ}
      JELLYFIN_PublishedServerUrl: ${JELLYFIN_PUBLISHED_URL}
      # Membatasi berapa banyak byte yang dibaca ffprobe per file saat scan.
      # Default Jellyfin jauh lebih besar; di atas mount B2 itu berarti
      # menarik ratusan MB per judul hanya untuk mendeteksi codec.
      JELLYFIN_FFmpeg__probesize: 10M
      JELLYFIN_FFmpeg__analyzeduration: 5M

    # HANYA localhost. Paparan ke tailnet dilakukan `tailscale serve`.
    # Mengubah ini jadi 0.0.0.0 mengekspos Jellyfin ke internet publik.
    ports:
      - "${JELLYFIN_BIND}:${JELLYFIN_PORT}:8096"

    volumes:
      - ${JELLYFIN_DATA}/config:/config
      - ${JELLYFIN_DATA}/cache:/cache
      - type: bind
        source: ${MEDIA_MOUNT}
        target: /media
        read_only: true
        bind:
          # Wajib. Mount FUSE dipasang di host SESUDAH namespace container
          # dibuat; tanpa rslave, container melihat direktori kosong
          # selamanya dan Jellyfin mengira seluruh library terhapus.
          propagation: rslave

    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
```

- [ ] **Step 4: Jalankan tes untuk memastikan LULUS**

```bash
bash tests/run.sh
```

Harapan: LULUS, termasuk cek `${VAR}` di `test_env_example.sh` yang sekarang
punya template untuk dipindai.

- [ ] **Step 5: Commit**

```bash
git add docker-compose.yml tests/test_compose.sh
git commit -m "feat: container Jellyfin, terikat localhost, media read-only"
```

---

### Task 4: Unit mount systemd

Ini file paling padat konsekuensi di repo. Setiap flag ada karena satu alasan
spesifik; tesnya mengunci alasan-alasan itu supaya tidak hilang saat seseorang
"merapikan" file ini nanti.

**Files:**
- Create: `systemd/rclone-b2.service`
- Create: `systemd/docker-after-mount.conf`
- Create: `tests/test_systemd.sh`

**Interfaces:**
- Consumes: `/etc/jellyfin-b2/env` (ditulis oleh Task 6) yang menyediakan
  `B2_BUCKET`, `MEDIA_MOUNT`, `VFS_CACHE_DIR`, `VFS_CACHE_MAX_SIZE`,
  `DIR_CACHE_TIME`, `RCLONE_RC_ADDR`, `JELLYFIN_UID`, `JELLYFIN_GID`.
  Juga `/etc/rclone/rclone.conf` dengan remote bernama `b2` (ditulis Task 6).
- Produces: unit systemd `rclone-b2.service` dan mount aktif di `${MEDIA_MOUNT}`.
  Task 6 melakukan `systemctl enable --now rclone-b2`; Task 7 memakai endpoint
  RC-nya; Task 8 memeriksa statusnya.

- [ ] **Step 1: Tulis tes yang gagal**

Buat `tests/test_systemd.sh`:

```bash
# shellcheck shell=bash
# Diuji: systemd/rclone-b2.service dan drop-in Docker.

ROOT="$(cd .. && pwd)"
UNIT="$ROOT/systemd/rclone-b2.service"
DROPIN="$ROOT/systemd/docker-after-mount.conf"

assert_ok "unit rclone ada"  "[[ -f '$UNIT' ]]"
assert_ok "drop-in docker ada" "[[ -f '$DROPIN' ]]"

if [[ -f "$UNIT" ]]; then
  _u="$(cat "$UNIT")"

  # Type=notify berarti systemd menganggap unit ini "started" hanya setelah
  # mount benar-benar siap. Semua pengurutan boot bergantung pada ini.
  assert_contains "Type=notify"                 "$_u" "Type=notify"

  # Read-only bukan preferensi — ini yang mencegah Jellyfin menulis artwork
  # ke B2 dan mencegah penghapusan tak sengaja.
  assert_contains "mount read-only"             "$_u" "--read-only"

  # Batas keras terhadap disk 40 GB.
  assert_contains "batas ukuran cache VFS"      "$_u" "--vfs-cache-max-size"
  assert_contains "mode cache VFS full"         "$_u" "--vfs-cache-mode full"

  # Endpoint RC dipakai refresh-library.sh.
  assert_contains "RC diaktifkan"               "$_u" "--rc"

  # B2 tidak mendukung change-notify; polling harus dimatikan eksplisit.
  assert_contains "polling dimatikan"           "$_u" "--poll-interval 0"

  # Pemulihan otomatis kalau rclone mati.
  assert_contains "restart on-failure"          "$_u" "Restart=on-failure"

  # Unmount saat berhenti, kalau tidak mount jadi basi dan I/O menggantung.
  assert_contains "unmount saat stop"           "$_u" "fusermount"

  # rclone tidak boleh ikut menghabiskan RAM 2 GB.
  assert_contains "batas memori rclone"         "$_u" "MemoryMax="

  # Rahasia hanya boleh datang dari file, tidak pernah tertulis di unit.
  assert_fail "tidak ada kunci B2 di unit"      "grep -qiE 'K00[0-9A-Za-z]{20,}' '$UNIT'"
  assert_contains "kredensial dari EnvironmentFile" "$_u" "EnvironmentFile="
fi

if [[ -f "$DROPIN" ]]; then
  _d="$(cat "$DROPIN")"
  # Docker harus menunggu mount. Kalau tidak, container yang auto-start saat
  # boot melihat /srv/media kosong.
  assert_contains "docker menunggu mount" "$_d" "rclone-b2.service"
  assert_contains "docker butuh mount"    "$_d" "Requires="
fi

# Validasi sintaks penuh kalau systemd tersedia (Linux saja).
if command -v systemd-analyze >/dev/null 2>&1; then
  assert_ok "unit lolos systemd-analyze verify" \
    "systemd-analyze verify '$UNIT' 2>&1 | grep -viE 'command .* is not executable|Assert' | grep -q . && false || true"
else
  printf '  \033[2mlewat\033[0m systemd-analyze (bukan Linux)\n'
fi
```

- [ ] **Step 2: Jalankan tes untuk memastikan GAGAL**

```bash
bash tests/run.sh
```

Harapan: GAGAL pada "unit rclone ada".

- [ ] **Step 3: Tulis unit systemd**

Buat `systemd/rclone-b2.service`:

```ini
[Unit]
Description=rclone: mount Backblaze B2 read-only untuk Jellyfin
Documentation=https://rclone.org/commands/rclone_mount/
After=network-online.target
Wants=network-online.target

[Service]
# notify = systemd baru menganggap unit ini "started" setelah mount SIAP.
# Seluruh pengurutan boot (terutama docker-after-mount.conf) bergantung
# pada ini.
Type=notify
EnvironmentFile=/etc/jellyfin-b2/env

ExecStart=/usr/bin/rclone mount b2:${B2_BUCKET} ${MEDIA_MOUNT} \
  --config /etc/rclone/rclone.conf \
  --cache-dir ${VFS_CACHE_DIR} \
  --allow-other \
  --read-only \
  --uid ${JELLYFIN_UID} \
  --gid ${JELLYFIN_GID} \
  --umask 022 \
  --dir-cache-time ${DIR_CACHE_TIME} \
  --poll-interval 0 \
  --vfs-cache-mode full \
  --vfs-cache-max-size ${VFS_CACHE_MAX_SIZE} \
  --vfs-cache-max-age 72h \
  --vfs-read-chunk-size 16M \
  --vfs-read-chunk-size-limit 128M \
  --vfs-read-ahead 128M \
  --vfs-fast-fingerprint \
  --buffer-size 16M \
  --transfers 4 \
  --checkers 8 \
  --timeout 1h \
  --rc \
  --rc-addr ${RCLONE_RC_ADDR} \
  --rc-no-auth \
  --syslog \
  --log-level INFO

ExecStop=/bin/fusermount -uz ${MEDIA_MOUNT}

Restart=on-failure
RestartSec=10

# Server hanya punya RAM 2 GB. Tanpa batas ini, rclone dan Jellyfin bisa
# saling mendorong ke OOM killer.
MemoryMax=512M

[Install]
WantedBy=multi-user.target
```

Kenapa flag-flag ini, ringkas:

| Flag | Alasan |
|---|---|
| `--vfs-cache-mode full` | Tanpa ini, seek/scrub sangat lambat. rclone modern menyimpan cache secara sparse — hanya potongan yang dibaca. |
| `--vfs-read-chunk-size 16M` naik ke `128M` | Mulai kecil supaya pemutaran cepat dimulai, membesar untuk pemutaran berkelanjutan. |
| `--buffer-size 16M` | Per file terbuka. 3 stream = 48 MB RAM. Aman di 2 GB. |
| `--vfs-fast-fingerprint` | Menghindari hashing file besar hanya untuk mendeteksi perubahan. |
| `--timeout 1h` | B2 kadang lambat merespons; timeout pendek akan memutus stream panjang. |
| `--dir-cache-time` dari env | Dikunci ke 1h oleh `.env.example`; lihat Task 2. |

- [ ] **Step 4: Tulis drop-in Docker**

Buat `systemd/docker-after-mount.conf`:

```ini
# Dipasang ke /etc/systemd/system/docker.service.d/10-after-mount.conf
#
# Docker me-restart sendiri container ber-policy `unless-stopped` saat daemon
# start. Saat boot, itu terjadi SEBELUM rclone sempat memasang mount, sehingga
# Jellyfin melihat /srv/media kosong dan mengira seluruh library terhapus.
#
# Menunda daemon Docker sampai mount siap menghilangkan seluruh balapan itu.
# Efek samping yang disengaja: kalau mount gagal, Docker tidak start — kita
# lebih memilih tidak ada Jellyfin daripada Jellyfin dengan library kosong.
[Unit]
After=rclone-b2.service
Requires=rclone-b2.service
```

- [ ] **Step 5: Jalankan tes untuk memastikan LULUS**

```bash
bash tests/run.sh
```

Harapan: LULUS.

- [ ] **Step 6: Commit**

```bash
git add systemd/ tests/test_systemd.sh
git commit -m "feat: unit mount rclone + pengurutan boot Docker"
```

---

### Task 5: `preflight.sh` — validasi sebelum menyentuh apa pun

Skrip ini tidak mengubah apa pun. Tujuannya: mengubah kegagalan yang
membingungkan di tengah provisioning menjadi pesan jelas sebelum apa pun
terjadi.

**Files:**
- Create: `scripts/preflight.sh`
- Create: `tests/test_preflight.sh`

**Interfaces:**
- Consumes: `scripts/lib/common.sh` (Task 1), skema `.env` (Task 2).
- Produces: `scripts/preflight.sh` dengan kontrak CLI —
  `preflight.sh [--config-only] [--env-file PATH]`.
  Exit 0 jika semua lolos, exit 1 pada kegagalan pertama yang fatal.
  `--config-only` melewati semua cek host dan jaringan, sehingga bisa
  dijalankan di laptop mana pun. Task 6 memanggilnya tanpa flag.

- [ ] **Step 1: Tulis tes yang gagal**

Buat `tests/test_preflight.sh`:

```bash
# shellcheck shell=bash
# Diuji: scripts/preflight.sh (mode --config-only)

ROOT="$(cd .. && pwd)"
PF="$ROOT/scripts/preflight.sh"

assert_ok "preflight.sh ada"        "[[ -f '$PF' ]]"
assert_ok "preflight.sh executable" "[[ -x '$PF' ]]"

# Fixture: .env yang benar-benar valid.
_mkenv() {
  local f; f="$(mktemp)"
  cat > "$f" <<'FIXTURE'
B2_ACCOUNT_ID=005abcdef
B2_APPLICATION_KEY=K005abcdefghij
B2_BUCKET=media-bucket
MEDIA_MOUNT=/srv/media
VFS_CACHE_DIR=/var/cache/rclone
VFS_CACHE_MAX_SIZE=10G
DIR_CACHE_TIME=1h
RCLONE_RC_ADDR=127.0.0.1:5572
JELLYFIN_IMAGE=jellyfin/jellyfin:10.11.11
JELLYFIN_BIND=127.0.0.1
JELLYFIN_PORT=8096
JELLYFIN_MEM_LIMIT=1200m
JELLYFIN_UID=1000
JELLYFIN_GID=1000
JELLYFIN_DATA=/opt/jellyfin
TZ=Asia/Jakarta
JELLYFIN_API_KEY=
JELLYFIN_PUBLISHED_URL=
TS_HOSTNAME=jellyfin
MONTHLY_QUOTA_GB=512
QUOTA_WARN_PERCENT=80
NET_INTERFACE=eth0
FIXTURE
  printf '%s' "$f"
}

if [[ -x "$PF" ]]; then
  _good="$(_mkenv)"
  assert_ok "env valid lolos" "'$PF' --config-only --env-file '$_good'"

  # Kredensial B2 kosong harus ditolak, dan pesannya harus menyebut variabelnya.
  _nokey="$(_mkenv)"; sed -i.bak 's/^B2_BUCKET=.*/B2_BUCKET=/' "$_nokey"
  assert_fail "B2_BUCKET kosong ditolak" "'$PF' --config-only --env-file '$_nokey'"
  _msg="$( '$PF' --config-only --env-file "$_nokey" 2>&1 || true )"
  assert_contains "pesan menyebut B2_BUCKET" "$_msg" "B2_BUCKET"

  # Cek keamanan: bind non-localhost berarti terekspos ke internet.
  # Ini harus ditolak keras, bukan sekadar peringatan.
  _public="$(_mkenv)"; sed -i.bak 's/^JELLYFIN_BIND=.*/JELLYFIN_BIND=0.0.0.0/' "$_public"
  assert_fail "bind 0.0.0.0 ditolak" "'$PF' --config-only --env-file '$_public'"
  _msg2="$( '$PF' --config-only --env-file "$_public" 2>&1 || true )"
  assert_contains "pesan menjelaskan risiko bind" "$_msg2" "127.0.0.1"

  # Image tidak ter-pin harus ditolak.
  _latest="$(_mkenv)"; sed -i.bak 's|^JELLYFIN_IMAGE=.*|JELLYFIN_IMAGE=jellyfin/jellyfin:latest|' "$_latest"
  assert_fail "image :latest ditolak" "'$PF' --config-only --env-file '$_latest'"

  # File env yang tidak ada harus gagal dengan jelas, bukan crash.
  assert_fail "env file hilang ditolak" "'$PF' --config-only --env-file /nope/.env"

  rm -f "$_good" "$_nokey" "$_public" "$_latest" ./*.bak "$_nokey.bak" "$_public.bak" "$_latest.bak" 2>/dev/null || true
fi
```

- [ ] **Step 2: Jalankan tes untuk memastikan GAGAL**

```bash
bash tests/run.sh
```

Harapan: GAGAL pada "preflight.sh ada".

- [ ] **Step 3: Implementasikan preflight.sh**

Buat `scripts/preflight.sh`:

```bash
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

  require_env B2_ACCOUNT_ID B2_APPLICATION_KEY B2_BUCKET \
              MEDIA_MOUNT VFS_CACHE_DIR VFS_CACHE_MAX_SIZE DIR_CACHE_TIME \
              RCLONE_RC_ADDR JELLYFIN_IMAGE JELLYFIN_BIND JELLYFIN_PORT \
              JELLYFIN_MEM_LIMIT JELLYFIN_UID JELLYFIN_GID JELLYFIN_DATA \
              TZ TS_HOSTNAME MONTHLY_QUOTA_GB QUOTA_WARN_PERCENT NET_INTERFACE

  # Setup ini dirancang tanpa apa pun yang menghadap internet. Bind selain
  # localhost membuang seluruh model keamanannya, jadi kita menolak keras
  # alih-alih memperingatkan.
  [[ "$JELLYFIN_BIND" == "127.0.0.1" ]] || die \
    "JELLYFIN_BIND adalah '$JELLYFIN_BIND', harus 127.0.0.1.
    Desain ini memaparkan Jellyfin lewat 'tailscale serve', bukan dengan
    membuka port. Nilai lain mengekspos Jellyfin ke internet tanpa reverse
    proxy, tanpa rate limiting, dan tanpa fail2ban."

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
account = ${B2_ACCOUNT_ID}
key = ${B2_APPLICATION_KEY}
CFG

  rclone --config "$tmpcfg" lsd "b2:${B2_BUCKET}" >/dev/null 2>&1 \
    || die "tidak bisa membaca bucket '${B2_BUCKET}'. Cek B2_ACCOUNT_ID, B2_APPLICATION_KEY,
    nama bucket, dan pastikan application key punya akses ke bucket ini."
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
  check_b2
fi
log "Preflight lolos."
```

- [ ] **Step 4: Jalankan tes untuk memastikan LULUS**

```bash
chmod +x scripts/preflight.sh
bash tests/run.sh
```

Harapan: LULUS.

- [ ] **Step 5: Jalankan shellcheck**

```bash
shellcheck scripts/preflight.sh scripts/lib/common.sh
```

Harapan: tidak ada output (bersih). Kalau `shellcheck` belum ada:
`brew install shellcheck` atau `apt-get install shellcheck`.

- [ ] **Step 6: Commit**

```bash
git add scripts/preflight.sh tests/test_preflight.sh
git commit -m "feat: preflight — validasi konfigurasi, host, dan kredensial B2"
```

---

### Task 6: `bootstrap.sh` — satu-satunya skrip yang mengubah sistem

**Files:**
- Create: `scripts/bootstrap.sh`
- Create: `tests/test_bootstrap.sh`

**Interfaces:**
- Consumes: `common.sh` (Task 1), `.env` (Task 2), `docker-compose.yml` (Task 3),
  `systemd/*` (Task 4), `preflight.sh` (Task 5).
- Produces: `scripts/bootstrap.sh` dengan kontrak CLI —
  `bootstrap.sh [--dry-run] [--env-file PATH]`. Dengan `--dry-run`, mencetak
  setiap aksi dengan awalan `[dry-run]` dan tidak mengubah apa pun; exit 0.
  Menulis `/etc/jellyfin-b2/env` (0600) dan `/etc/rclone/rclone.conf` (0600),
  yang dikonsumsi unit systemd dari Task 4.

- [ ] **Step 1: Tulis tes yang gagal**

Buat `tests/test_bootstrap.sh`:

```bash
# shellcheck shell=bash
# Diuji: scripts/bootstrap.sh

ROOT="$(cd .. && pwd)"
BS="$ROOT/scripts/bootstrap.sh"

assert_ok "bootstrap.sh ada"        "[[ -f '$BS' ]]"
assert_ok "bootstrap.sh executable" "[[ -x '$BS' ]]"

if [[ -f "$BS" ]]; then
  _b="$(cat "$BS")"

  # Idempotensi: setiap langkah destruktif atau instalasi harus dijaga
  # pemeriksaan. Menjalankan bootstrap dua kali harus aman.
  assert_contains "swapfile dijaga pemeriksaan"  "$_b" "swapon --show"
  assert_contains "instalasi docker dijaga"      "$_b" "command -v docker"
  assert_contains "instalasi rclone dijaga"      "$_b" "command -v rclone"
  assert_contains "instalasi tailscale dijaga"   "$_b" "command -v tailscale"

  # Rahasia yang ditulis ke disk harus dikunci.
  assert_contains "chmod 600 untuk file rahasia" "$_b" "chmod 600"

  # Bootstrap harus menolak berjalan kalau preflight gagal.
  assert_contains "memanggil preflight"          "$_b" "preflight.sh"

  # tailscale up butuh autentikasi interaktif — bootstrap harus memandu,
  # bukan mencoba dan gagal secara membingungkan.
  assert_contains "memandu tailscale up"         "$_b" "tailscale up"
fi

# --dry-run tidak boleh mengubah apa pun dan harus keluar dengan status 0,
# bahkan sebagai user biasa di laptop.
if [[ -x "$BS" ]]; then
  _env="$(mktemp)"
  cp "$ROOT/.env.example" "$_env"
  sed -i.bak -e 's/^B2_ACCOUNT_ID=.*/B2_ACCOUNT_ID=005test/' \
             -e 's/^B2_APPLICATION_KEY=.*/B2_APPLICATION_KEY=Ktest/' \
             -e 's/^B2_BUCKET=.*/B2_BUCKET=test-bucket/' "$_env"

  _out="$( '$BS' --dry-run --env-file "$_env" 2>&1 || true )"
  assert_contains "dry-run menandai aksinya" "$_out" "[dry-run]"
  assert_ok "dry-run keluar bersih" "'$BS' --dry-run --env-file '$_env'"
  assert_fail "dry-run tidak membuat /etc/jellyfin-b2" "[[ -e /etc/jellyfin-b2 ]]"

  rm -f "$_env" "$_env.bak"
fi
```

- [ ] **Step 2: Jalankan tes untuk memastikan GAGAL**

```bash
bash tests/run.sh
```

Harapan: GAGAL pada "bootstrap.sh ada".

- [ ] **Step 3: Implementasikan bootstrap.sh**

Buat `scripts/bootstrap.sh`:

```bash
#!/usr/bin/env bash
# Memprovision VPS Debian 12 kosong menjadi server Jellyfin yang menstream
# dari Backblaze B2. Idempoten: aman dijalankan berkali-kali.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "$HERE/lib/common.sh"
ROOT="$(repo_root)"

DRY_RUN=0
ENV_FILE="$ROOT/.env"

usage() {
  cat <<'USAGE'
Pemakaian: sudo bootstrap.sh [opsi]

  --dry-run          Cetak setiap aksi tanpa mengubah apa pun.
  --env-file PATH    File env yang dipakai (default: <root repo>/.env)
  -h, --help         Tampilkan bantuan ini
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)  DRY_RUN=1 ;;
    --env-file) ENV_FILE="${2:-}"; shift ;;
    -h|--help)  usage; exit 0 ;;
    *)          die "argumen tidak dikenal: $1" ;;
  esac
  shift
done

# run — mengeksekusi, atau mencetak saja saat --dry-run.
run() {
  if (( DRY_RUN )); then
    printf '  [dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

# write_file <path> <mode> — menulis stdin ke path dengan mode tertentu.
write_file() {
  local path="$1" mode="$2" content; content="$(cat)"
  if (( DRY_RUN )); then
    printf '  [dry-run] tulis %s (mode %s, %d byte)\n' "$path" "$mode" "${#content}"
    return
  fi
  install -d -m 755 "$(dirname "$path")"
  printf '%s' "$content" > "$path"
  chmod "$mode" "$path"
}

load_env "$ENV_FILE"

# ── 1. Preflight ─────────────────────────────────────────────────────────────
log "1/9  Preflight"
if (( DRY_RUN )); then
  run "$HERE/preflight.sh" --config-only --env-file "$ENV_FILE"
  "$HERE/preflight.sh" --config-only --env-file "$ENV_FILE"
else
  "$HERE/preflight.sh" --env-file "$ENV_FILE"
fi

# ── 2. Paket dasar ───────────────────────────────────────────────────────────
log "2/9  Paket dasar"
run apt-get update -qq
run apt-get install -y -qq curl ca-certificates fuse3 vnstat jq gnupg

# ── 3. Swap ──────────────────────────────────────────────────────────────────
# RAM 2 GB terlalu mepet untuk scan library Jellyfin. Tanpa swap, OOM killer
# memilih korban dan sering kali korbannya sshd.
log "3/9  Swap"
if swapon --show | grep -q '/swapfile'; then
  info "swapfile sudah aktif"
else
  run fallocate -l 2G /swapfile
  run chmod 600 /swapfile
  run mkswap /swapfile
  run swapon /swapfile
  if ! grep -q '^/swapfile' /etc/fstab 2>/dev/null; then
    run bash -c 'echo "/swapfile none swap sw 0 0" >> /etc/fstab'
  fi
fi
run sysctl -qw vm.swappiness=10
write_file /etc/sysctl.d/99-jellyfin.conf 644 <<'SYSCTL'
vm.swappiness=10
SYSCTL

# ── 4. Batas log ─────────────────────────────────────────────────────────────
# Disk 40 GB. journald tanpa batas akan memakannya pelan-pelan.
log "4/9  Batas log"
write_file /etc/systemd/journald.conf.d/99-limits.conf 644 <<'JOURNAL'
[Journal]
SystemMaxUse=200M
SystemMaxFileSize=50M
JOURNAL
run systemctl restart systemd-journald

# ── 5. Docker, rclone, Tailscale ─────────────────────────────────────────────
log "5/9  Runtime"
if command -v docker >/dev/null 2>&1; then
  info "docker sudah ada"
else
  run bash -c 'curl -fsSL https://get.docker.com | sh'
fi

if command -v rclone >/dev/null 2>&1; then
  info "rclone sudah ada ($(rclone version 2>/dev/null | head -1))"
else
  run bash -c 'curl -fsSL https://rclone.org/install.sh | bash'
fi

if command -v tailscale >/dev/null 2>&1; then
  info "tailscale sudah ada"
else
  run bash -c 'curl -fsSL https://tailscale.com/install.sh | sh'
fi

# --allow-other butuh flag ini untuk mount yang dipakai lintas namespace.
if ! grep -q '^user_allow_other' /etc/fuse.conf 2>/dev/null; then
  run bash -c 'echo user_allow_other >> /etc/fuse.conf'
fi

# ── 6. Direktori ─────────────────────────────────────────────────────────────
log "6/9  Direktori"
run install -d -m 755 "$MEDIA_MOUNT"
run install -d -m 755 -o "$JELLYFIN_UID" -g "$JELLYFIN_GID" "$VFS_CACHE_DIR"
run install -d -m 755 -o "$JELLYFIN_UID" -g "$JELLYFIN_GID" "$JELLYFIN_DATA/config" "$JELLYFIN_DATA/cache"

# ── 7. Rahasia ───────────────────────────────────────────────────────────────
# Kredensial tinggal di /etc, bukan di dalam checkout repo. Mode 600 karena
# file ini memberikan akses baca ke seluruh library.
log "7/9  Kredensial"
write_file /etc/rclone/rclone.conf 600 <<CFG
[b2]
type = b2
account = ${B2_ACCOUNT_ID}
key = ${B2_APPLICATION_KEY}
hard_delete = false
CFG

write_file /etc/jellyfin-b2/env 600 <<ENVF
B2_BUCKET=${B2_BUCKET}
MEDIA_MOUNT=${MEDIA_MOUNT}
VFS_CACHE_DIR=${VFS_CACHE_DIR}
VFS_CACHE_MAX_SIZE=${VFS_CACHE_MAX_SIZE}
DIR_CACHE_TIME=${DIR_CACHE_TIME}
RCLONE_RC_ADDR=${RCLONE_RC_ADDR}
JELLYFIN_UID=${JELLYFIN_UID}
JELLYFIN_GID=${JELLYFIN_GID}
ENVF

# ── 8. Unit systemd ──────────────────────────────────────────────────────────
log "8/9  systemd"
run install -m 644 "$ROOT/systemd/rclone-b2.service" /etc/systemd/system/rclone-b2.service
run install -d -m 755 /etc/systemd/system/docker.service.d
run install -m 644 "$ROOT/systemd/docker-after-mount.conf" \
    /etc/systemd/system/docker.service.d/10-after-mount.conf
run systemctl daemon-reload
run systemctl enable --now rclone-b2.service

if (( DRY_RUN == 0 )); then
  # Type=notify berarti systemd sudah menunggu mount siap, tapi kita tetap
  # verifikasi sebelum menyerahkan kendali ke Docker.
  for _ in $(seq 1 30); do
    mountpoint -q "$MEDIA_MOUNT" && break
    sleep 1
  done
  mountpoint -q "$MEDIA_MOUNT" \
    || die "mount tidak muncul di $MEDIA_MOUNT — cek: journalctl -u rclone-b2 -n 50"
  info "mount aktif: $(ls -1 "$MEDIA_MOUNT" | head -5 | tr '\n' ' ')"
fi

# ── 9. Jellyfin ──────────────────────────────────────────────────────────────
log "9/9  Jellyfin"
run systemctl restart docker
run docker compose --project-directory "$ROOT" --env-file "$ENV_FILE" up -d

cat <<'NEXT'

Bootstrap selesai. Tiga langkah yang harus dilakukan manual:

  1. Sambungkan ke Tailscale (butuh login di browser):
       sudo tailscale up --hostname="$TS_HOSTNAME"

  2. Paparkan Jellyfin ke tailnet dengan TLS asli:
       sudo tailscale serve --bg 8096
       tailscale serve status        # catat URL https://...ts.net

  3. Buka URL itu, selesaikan wizard Jellyfin, lalu KERJAKAN CHECKLIST di
     docs/jellyfin-settings.md. Checklist itu bukan opsional — melewatinya
     bisa menghabiskan kuota sebulan hanya untuk sekali scan library.

  Setelah itu, isi JELLYFIN_API_KEY dan JELLYFIN_PUBLISHED_URL di .env,
  lalu jalankan ulang:  docker compose up -d

NEXT
```

- [ ] **Step 4: Jalankan tes untuk memastikan LULUS**

```bash
chmod +x scripts/bootstrap.sh
bash tests/run.sh
```

Harapan: LULUS.

- [ ] **Step 5: Shellcheck**

```bash
shellcheck scripts/bootstrap.sh
```

Harapan: bersih.

- [ ] **Step 6: Commit**

```bash
git add scripts/bootstrap.sh tests/test_bootstrap.sh
git commit -m "feat: bootstrap idempoten dengan mode dry-run"
```

---

### Task 7: `refresh-library.sh` — membuat file baru muncul seketika

Rantainya dua lapis dan urutannya penting: rclone harus melihat file dulu,
baru Jellyfin diminta memindai. Terbalik, scan berjalan di atas listing basi
dan tidak menemukan apa-apa.

**Files:**
- Create: `scripts/refresh-library.sh`
- Create: `tests/test_refresh.sh`

**Interfaces:**
- Consumes: `common.sh` (Task 1); `RCLONE_RC_ADDR`, `JELLYFIN_BIND`,
  `JELLYFIN_PORT`, `JELLYFIN_API_KEY` dari `.env`; endpoint RC rclone dari Task 4.
- Produces: `scripts/refresh-library.sh [--env-file PATH]`. Exit 0 jika
  refresh rclone berhasil. Melewati langkah Jellyfin dengan peringatan
  (bukan error) kalau `JELLYFIN_API_KEY` kosong.

- [ ] **Step 1: Tulis tes yang gagal**

Buat `tests/test_refresh.sh`:

```bash
# shellcheck shell=bash
# Diuji: scripts/refresh-library.sh, dengan rclone dan curl palsu di PATH.

ROOT="$(cd .. && pwd)"
RL="$ROOT/scripts/refresh-library.sh"

assert_ok "refresh-library.sh ada"        "[[ -f '$RL' ]]"
assert_ok "refresh-library.sh executable" "[[ -x '$RL' ]]"

# Membangun bin palsu yang mencatat argumennya ke $LOG, lalu sukses.
_stubdir() {
  local d; d="$(mktemp -d)"
  for c in rclone curl; do
    cat > "$d/$c" <<STUB
#!/usr/bin/env bash
printf '%s %s\n' "$c" "\$*" >> "\$STUB_LOG"
exit 0
STUB
    chmod +x "$d/$c"
  done
  printf '%s' "$d"
}

_mkenv() {
  local f key="$1"; f="$(mktemp)"
  cat > "$f" <<ENVF
RCLONE_RC_ADDR=127.0.0.1:5572
JELLYFIN_BIND=127.0.0.1
JELLYFIN_PORT=8096
JELLYFIN_API_KEY=$key
ENVF
  printf '%s' "$f"
}

if [[ -x "$RL" ]]; then
  # --- Dengan API key: kedua langkah harus jalan, rclone lebih dulu ---
  _d="$(_stubdir)"; _log="$(mktemp)"; _env="$(_mkenv secretkey123)"
  ( export STUB_LOG="$_log" PATH="$_d:$PATH"; "$RL" --env-file "$_env" ) >/dev/null 2>&1 || true
  _got="$(cat "$_log")"

  assert_contains "memanggil vfs/refresh rclone"   "$_got" "vfs/refresh"
  assert_contains "refresh bersifat rekursif"      "$_got" "recursive=true"
  assert_contains "menargetkan alamat RC"          "$_got" "127.0.0.1:5572"
  assert_contains "memicu scan Jellyfin"           "$_got" "/Library/Refresh"
  assert_contains "mengirim token API"             "$_got" "secretkey123"

  # Urutan penting: listing rclone harus di-refresh SEBELUM Jellyfin memindai.
  assert_eq "rclone berjalan sebelum curl" "$(head -1 "$_log" | awk '{print $1}')" "rclone"
  rm -rf "$_d" "$_log" "$_env"

  # --- Tanpa API key: refresh rclone tetap jalan, langkah Jellyfin dilewati ---
  _d2="$(_stubdir)"; _log2="$(mktemp)"; _env2="$(_mkenv "")"
  ( export STUB_LOG="$_log2" PATH="$_d2:$PATH"; "$RL" --env-file "$_env2" ) >/dev/null 2>&1 || true
  _got2="$(cat "$_log2")"

  assert_contains "tanpa key: rclone tetap di-refresh" "$_got2" "vfs/refresh"
  assert_fail     "tanpa key: Jellyfin dilewati"       "printf '%s' '$_got2' | grep -q 'Library/Refresh'"
  assert_ok       "tanpa key: tetap exit 0" \
    "( export STUB_LOG='$_log2' PATH='$_d2:\$PATH'; '$RL' --env-file '$_env2' )"
  rm -rf "$_d2" "$_log2" "$_env2"
fi
```

- [ ] **Step 2: Jalankan tes untuk memastikan GAGAL**

```bash
bash tests/run.sh
```

Harapan: GAGAL pada "refresh-library.sh ada".

- [ ] **Step 3: Implementasikan refresh-library.sh**

Buat `scripts/refresh-library.sh`:

```bash
#!/usr/bin/env bash
# Membuat file yang baru diupload langsung muncul, tanpa menunggu cache
# direktori kedaluwarsa.
#
# Urutan itu penting: rclone menyimpan listing direktori selama
# --dir-cache-time. Menyuruh Jellyfin memindai lebih dulu hanya akan memindai
# listing basi dan tidak menemukan apa-apa.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "$HERE/lib/common.sh"

ENV_FILE="$(repo_root)/.env"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file) ENV_FILE="${2:-}"; shift ;;
    -h|--help)  echo "Pemakaian: refresh-library.sh [--env-file PATH]"; exit 0 ;;
    *)          die "argumen tidak dikenal: $1" ;;
  esac
  shift
done

load_env "$ENV_FILE"
require_env RCLONE_RC_ADDR JELLYFIN_BIND JELLYFIN_PORT

# 1. Buang cache direktori rclone supaya file baru terlihat oleh kernel.
log "Me-refresh listing direktori rclone"
rclone rc --url "http://${RCLONE_RC_ADDR}/" vfs/refresh recursive=true \
  || die "vfs/refresh gagal. Apakah mount berjalan? Cek: systemctl status rclone-b2"

# 2. Sekarang suruh Jellyfin memindai listing yang sudah segar.
if [[ -z "${JELLYFIN_API_KEY:-}" ]]; then
  warn "JELLYFIN_API_KEY kosong — scan Jellyfin dilewati.
  Buat key di Dashboard -> Advanced -> API Keys, lalu isi di .env.
  Sampai saat itu, scan terjadwal akan menemukannya sendiri dalam beberapa jam."
  exit 0
fi

log "Memicu scan library Jellyfin"
curl -fsS -X POST \
  "http://${JELLYFIN_BIND}:${JELLYFIN_PORT}/Library/Refresh" \
  -H "Authorization: MediaBrowser Token=\"${JELLYFIN_API_KEY}\"" \
  -H "Content-Length: 0" \
  || die "gagal memicu scan. Apakah container Jellyfin berjalan? Cek: docker ps"

log "Selesai. Scan berjalan di latar belakang — pantau di Dashboard."
```

- [ ] **Step 4: Jalankan tes untuk memastikan LULUS**

```bash
chmod +x scripts/refresh-library.sh
bash tests/run.sh
```

Harapan: LULUS, termasuk assertion urutan.

- [ ] **Step 5: Commit**

```bash
git add scripts/refresh-library.sh tests/test_refresh.sh
git commit -m "feat: refresh library — vfs/refresh lalu scan Jellyfin"
```

---

### Task 8: `healthcheck.sh` dan `quota-check.sh`

Digabung dalam satu task karena keduanya read-only, sama-sama diuji dengan
stub, dan seorang reviewer akan menerima atau menolak keduanya sekaligus.

**Files:**
- Create: `scripts/healthcheck.sh`
- Create: `scripts/quota-check.sh`
- Create: `tests/test_health_quota.sh`

**Interfaces:**
- Consumes: `common.sh` (Task 1); `.env` (Task 2); `MEDIA_MOUNT`, `VFS_CACHE_DIR`,
  `JELLYFIN_BIND`, `JELLYFIN_PORT`, `NET_INTERFACE`, `MONTHLY_QUOTA_GB`,
  `QUOTA_WARN_PERCENT`.
- Produces: `healthcheck.sh [--env-file PATH]` — exit 0 jika sehat, 1 jika ada
  cek kritis yang gagal. `quota-check.sh [--env-file PATH]` — exit 0 di bawah
  ambang peringatan, 1 di atasnya.

- [ ] **Step 1: Tulis tes yang gagal**

Buat `tests/test_health_quota.sh`:

```bash
# shellcheck shell=bash
# Diuji: scripts/healthcheck.sh dan scripts/quota-check.sh

ROOT="$(cd .. && pwd)"
HC="$ROOT/scripts/healthcheck.sh"
QC="$ROOT/scripts/quota-check.sh"

for f in "$HC" "$QC"; do
  assert_ok "$(basename "$f") ada"        "[[ -f '$f' ]]"
  assert_ok "$(basename "$f") executable" "[[ -x '$f' ]]"
done

# --- quota-check dengan vnstat palsu ---------------------------------------
# vnstat melaporkan byte. 256 GB terpakai dari kuota 512 GB = 50%, di bawah
# ambang 80% -> exit 0. 480 GB = 93,75% -> exit 1.
_vnstat_stub() {
  local d bytes="$1"; d="$(mktemp -d)"
  cat > "$d/vnstat" <<STUB
#!/usr/bin/env bash
cat <<'JSON'
{"interfaces":[{"name":"eth0","traffic":{"month":[{"date":{"year":2026,"month":8},"rx":1,"tx":BYTES}]}}]}
JSON
STUB
  sed -i.bak "s/BYTES/$bytes/" "$d/vnstat" && rm -f "$d/vnstat.bak"
  chmod +x "$d/vnstat"
  printf '%s' "$d"
}

_qenv() {
  local f; f="$(mktemp)"
  cat > "$f" <<'ENVF'
NET_INTERFACE=eth0
MONTHLY_QUOTA_GB=512
QUOTA_WARN_PERCENT=80
ENVF
  printf '%s' "$f"
}

if [[ -x "$QC" ]]; then
  _env="$(_qenv)"

  # 256 GB = 274877906944 byte -> 50%, aman
  _d="$(_vnstat_stub 274877906944)"
  assert_ok "kuota 50% keluar dengan status 0" \
    "( PATH='$_d:\$PATH'; '$QC' --env-file '$_env' )"
  _out="$( PATH="$_d:$PATH" "$QC" --env-file "$_env" 2>&1 || true )"
  assert_contains "melaporkan persentase" "$_out" "50"
  rm -rf "$_d"

  # 480 GB = 515396075520 byte -> 93%, melewati ambang
  _d2="$(_vnstat_stub 515396075520)"
  assert_fail "kuota 93% keluar dengan status bukan 0" \
    "( PATH='$_d2:\$PATH'; '$QC' --env-file '$_env' )"
  rm -rf "$_d2"

  rm -f "$_env"
fi

# --- healthcheck harus gagal bersih kalau mount tidak ada -------------------
if [[ -x "$HC" ]]; then
  _henv="$(mktemp)"
  cat > "$_henv" <<'ENVF'
MEDIA_MOUNT=/nonexistent/mount/point
VFS_CACHE_DIR=/tmp
JELLYFIN_BIND=127.0.0.1
JELLYFIN_PORT=59999
ENVF
  assert_fail "healthcheck gagal saat mount hilang" "'$HC' --env-file '$_henv'"
  _hout="$( "$HC" --env-file "$_henv" 2>&1 || true )"
  assert_contains "healthcheck menyebut mount" "$_hout" "/nonexistent/mount/point"
  rm -f "$_henv"
fi
```

- [ ] **Step 2: Jalankan tes untuk memastikan GAGAL**

```bash
bash tests/run.sh
```

Harapan: GAGAL pada "healthcheck.sh ada".

- [ ] **Step 3: Implementasikan healthcheck.sh**

Buat `scripts/healthcheck.sh`:

```bash
#!/usr/bin/env bash
# Melaporkan kesehatan mount, container, dan disk. Read-only.
set -uo pipefail   # bukan -e: kita ingin SEMUA cek jalan, lalu melaporkan.

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "$HERE/lib/common.sh"
set +e

ENV_FILE="$(repo_root)/.env"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file) ENV_FILE="${2:-}"; shift ;;
    -h|--help)  echo "Pemakaian: healthcheck.sh [--env-file PATH]"; exit 0 ;;
    *)          printf 'argumen tidak dikenal: %s\n' "$1" >&2; exit 1 ;;
  esac
  shift
done

[[ -f "$ENV_FILE" ]] || { printf 'GAGAL: env tidak ditemukan: %s\n' "$ENV_FILE" >&2; exit 1; }
set -a; . "$ENV_FILE"; set +a

FAILED=0
ok()   { printf '  \033[0;32mok\033[0m    %s\n' "$*"; }
bad()  { printf '  \033[0;31mGAGAL\033[0m %s\n' "$*"; FAILED=1; }
note() { printf '  \033[0;33mcatatan\033[0m %s\n' "$*"; }

log "Mount"
if mountpoint -q "${MEDIA_MOUNT:-}" 2>/dev/null; then
  ok "$MEDIA_MOUNT ter-mount"
  if [[ -n "$(ls -A "$MEDIA_MOUNT" 2>/dev/null)" ]]; then
    ok "mount berisi $(find "$MEDIA_MOUNT" -maxdepth 1 -mindepth 1 | wc -l | tr -d ' ') entri teratas"
  else
    bad "$MEDIA_MOUNT ter-mount tapi kosong — cek nama bucket dan izin kunci"
  fi
else
  bad "$MEDIA_MOUNT tidak ter-mount"
fi

if command -v systemctl >/dev/null 2>&1; then
  if systemctl is-active --quiet rclone-b2.service; then
    ok "rclone-b2.service aktif"
  else
    bad "rclone-b2.service tidak aktif — journalctl -u rclone-b2 -n 50"
  fi
fi

log "Jellyfin"
if curl -fsS --max-time 10 "http://${JELLYFIN_BIND}:${JELLYFIN_PORT}/health" >/dev/null 2>&1; then
  ok "Jellyfin merespons di ${JELLYFIN_BIND}:${JELLYFIN_PORT}"
else
  bad "Jellyfin tidak merespons di ${JELLYFIN_BIND}:${JELLYFIN_PORT} — docker ps"
fi

log "Disk"
_pct="$(df --output=pcent / 2>/dev/null | tail -1 | tr -dc '0-9')"
if [[ -n "$_pct" ]]; then
  if (( _pct >= 90 )); then bad "/ terpakai ${_pct}%"
  elif (( _pct >= 80 )); then note "/ terpakai ${_pct}%"
  else ok "/ terpakai ${_pct}%"; fi
fi
if [[ -d "${VFS_CACHE_DIR:-}" ]]; then
  ok "cache VFS: $(du -sh "$VFS_CACHE_DIR" 2>/dev/null | cut -f1) (batas ${VFS_CACHE_MAX_SIZE:-?})"
fi

exit "$FAILED"
```

- [ ] **Step 4: Implementasikan quota-check.sh**

Buat `scripts/quota-check.sh`:

```bash
#!/usr/bin/env bash
# Melaporkan pemakaian bandwidth keluar bulan ini terhadap kuota VPS.
# Traffic keluar-lah yang dihitung Tencent, dan itulah yang habis saat menonton.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "$HERE/lib/common.sh"

ENV_FILE="$(repo_root)/.env"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file) ENV_FILE="${2:-}"; shift ;;
    -h|--help)  echo "Pemakaian: quota-check.sh [--env-file PATH]"; exit 0 ;;
    *)          die "argumen tidak dikenal: $1" ;;
  esac
  shift
done

load_env "$ENV_FILE"
require_env NET_INTERFACE MONTHLY_QUOTA_GB QUOTA_WARN_PERCENT
require_cmd vnstat

# vnstat 2.x melaporkan byte. Entri bulan terakhir adalah bulan berjalan.
tx_bytes="$(vnstat --json m -i "$NET_INTERFACE" 2>/dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["interfaces"][0]["traffic"]["month"][-1]["tx"])')"

[[ "$tx_bytes" =~ ^[0-9]+$ ]] || die "tidak bisa membaca data vnstat untuk $NET_INTERFACE"

used_gb=$(( tx_bytes / 1024 / 1024 / 1024 ))
pct=$(( used_gb * 100 / MONTHLY_QUOTA_GB ))
remaining_gb=$(( MONTHLY_QUOTA_GB - used_gb ))

log "Kuota bandwidth bulan ini"
info "terpakai    : ${used_gb} GB dari ${MONTHLY_QUOTA_GB} GB (${pct}%)"
info "sisa        : ${remaining_gb} GB"
info "kira-kira   : ~$(( remaining_gb / 5 )) film lagi @ 5 GB"

if (( pct >= QUOTA_WARN_PERCENT )); then
  warn "pemakaian ${pct}% sudah melewati ambang ${QUOTA_WARN_PERCENT}%.
  Kalau kuota habis, Tencent biasanya menurunkan kecepatan drastis sampai
  bulan berikutnya."
  exit 1
fi
exit 0
```

- [ ] **Step 5: Jalankan tes untuk memastikan LULUS**

```bash
chmod +x scripts/healthcheck.sh scripts/quota-check.sh
bash tests/run.sh
```

Harapan: LULUS.

- [ ] **Step 6: Shellcheck seluruh skrip**

```bash
shellcheck scripts/*.sh scripts/lib/*.sh
```

Harapan: bersih.

- [ ] **Step 7: Commit**

```bash
git add scripts/healthcheck.sh scripts/quota-check.sh tests/test_health_quota.sh
git commit -m "feat: healthcheck dan pemantauan kuota bandwidth"
```

---

### Task 9: Dokumentasi operasional

Dokumen-dokumen ini bukan pelengkap — `jellyfin-settings.md` adalah satu-satunya
hal yang berdiri antara setup ini dan menghabiskan kuota sebulan dalam satu scan
library. Karena itu isinya diuji, bukan sekadar ditulis.

**Files:**
- Create: `README.md`
- Create: `docs/jellyfin-settings.md`
- Create: `docs/media-guidelines.md`
- Create: `docs/upload-windows.md`
- Create: `docs/client-setup.md`
- Create: `docs/operations.md`
- Create: `tests/test_docs.sh`

**Interfaces:**
- Consumes: perilaku semua skrip dari Task 1–8.
- Produces: dokumentasi untuk manusia. Tidak ada kode yang bergantung padanya.

- [ ] **Step 1: Tulis tes yang gagal**

Buat `tests/test_docs.sh`:

```bash
# shellcheck shell=bash
# Diuji: dokumen wajib ada dan memuat fakta yang paling mudah dilupakan.

ROOT="$(cd .. && pwd)"

for f in README.md docs/jellyfin-settings.md docs/media-guidelines.md \
         docs/upload-windows.md docs/client-setup.md docs/operations.md; do
  assert_ok "$f ada" "[[ -f '$ROOT/$f' ]]"
done

# Checklist setting adalah dokumen paling penting di repo. Setiap item yang
# dimatikan ada karena satu alasan mahal; kalau salah satunya hilang dari
# checklist, orang berikutnya tidak akan tahu harus mematikannya.
if [[ -f "$ROOT/docs/jellyfin-settings.md" ]]; then
  _s="$(cat "$ROOT/docs/jellyfin-settings.md")"
  for term in Trickplay "chapter" "real time monitoring" "transcoding" "DLNA" "8 Mbps"; do
    assert_contains "checklist setting menyebut '$term'" "$_s" "$term"
  done
fi

# Panduan upload harus menyebutkan batas 500 MB — inilah alasan seluruh
# rencana upload awal diganti, dan tanpa itu orang akan mencoba web UI lagi.
if [[ -f "$ROOT/docs/upload-windows.md" ]]; then
  _u="$(cat "$ROOT/docs/upload-windows.md")"
  assert_contains "panduan upload menjelaskan batas 500 MB" "$_u" "500 MB"
  assert_contains "panduan upload menyebut Cyberduck"       "$_u" "Cyberduck"
fi

# Aturan format media adalah kontrak dengan pengguna; harus eksplisit.
if [[ -f "$ROOT/docs/media-guidelines.md" ]]; then
  _m="$(cat "$ROOT/docs/media-guidelines.md")"
  for term in "H.264" "AAC" "SRT" "HEVC"; do
    assert_contains "panduan media menyebut '$term'" "$_m" "$term"
  done
fi

# Panduan client harus menjawab pertanyaan pertama setiap orang: alamat apa
# yang saya masukkan? Jawabannya nama MagicDNS, bukan IP.
if [[ -f "$ROOT/docs/client-setup.md" ]]; then
  _c="$(cat "$ROOT/docs/client-setup.md")"
  assert_contains "panduan client menyebut MagicDNS" "$_c" "MagicDNS"
  assert_contains "panduan client memberi contoh URL ts.net" "$_c" ".ts.net"
  assert_contains "panduan client menyebut batasan smart TV" "$_c" "webOS"
fi

# Setiap file yang ditautkan README harus benar-benar ada.
if [[ -f "$ROOT/README.md" ]]; then
  _missing=""
  while IFS= read -r link; do
    [[ -e "$ROOT/$link" ]] || _missing="$_missing $link"
  done < <(grep -oE '\]\((docs/[^)]+|scripts/[^)]+|\.env\.example)\)' "$ROOT/README.md" \
           | tr -d '](' | tr -d ')')
  assert_eq "tautan README semuanya valid" "$_missing" ""
fi
```

- [ ] **Step 2: Jalankan tes untuk memastikan GAGAL**

```bash
bash tests/run.sh
```

Harapan: GAGAL pada "README.md ada".

- [ ] **Step 3: Tulis `docs/jellyfin-settings.md`**

Ini checklist yang dikerjakan sekali, setelah wizard awal. Isinya:

```markdown
# Checklist Setting Jellyfin

Kerjakan sekali, setelah wizard awal selesai. **Jangan dilewati.** Beberapa
setting bawaan Jellyfin dirancang untuk media di disk lokal; di atas mount B2,
setting yang sama membaca seluruh file dan bisa menghabiskan kuota sebulan
dalam satu malam.

## 1. Sebelum menambahkan library apa pun

Matikan dulu, baru tambahkan library. Kalau library ditambahkan lebih dulu,
scan pertama sudah terlanjur berjalan dengan setting bawaan.

**Dashboard → Playback → Transcoding**
- [ ] Hardware acceleration: **None**
- [ ] Transcode thread count: **1**

**Dashboard → Scheduled Tasks**
- [ ] *Extract Chapter Images* → nonaktifkan (Triggers: hapus semua)
- [ ] *Trickplay Image Extraction* → nonaktifkan (Triggers: hapus semua)
- [ ] *Scan Media Library* → set trigger: setiap **6 jam**

**Dashboard → Networking**
- [ ] Enable automatic port mapping (UPnP): **mati**
- [ ] Published Server URL: `https://<host>.<tailnet>.ts.net`

**Dashboard → Plugins → Catalog**, atau **Dashboard → General**
- [ ] DLNA: **mati** (berbasis broadcast, tidak berguna di tailnet, buang RAM)

## 2. Saat menambahkan tiap library

Tambahkan dua library, keduanya menunjuk ke dalam mount:

| Library | Tipe konten | Folder |
|---|---|---|
| Film | Movies | `/media/Movies` |
| Serial | TV Shows | `/media/Shows` |

Untuk **masing-masing**, di layar penambahan library:

- [ ] Enable real time monitoring: **mati**
      *FUSE tidak punya inotify yang benar; ini memicu rescan berulang.*
- [ ] Enable trickplay image extraction: **mati**
      *Membaca seluruh file setiap judul. Ini item termahal di halaman ini.*
- [ ] Extract chapter images: **mati**
- [ ] Save artwork into media folders: **mati**
      *Mount read-only — akan gagal terus dan mengotori log.*
- [ ] Enable subtitle extraction on the fly: **mati**

## 3. Setting per-user

**Dashboard → Users → [user] → Playback**

- [ ] Allow video playback that requires transcoding: **mati**
- [ ] Allow video playback that requires conversion (remux): **mati**
- [ ] Allow audio playback that requires transcoding: **aktif**
      *Remux audio murah secara CPU dan menyelamatkan banyak file. Hanya
      video yang dilarang.*
- [ ] Internet streaming bitrate limit: **8 Mbps**
      *Link hanya 20 Mbps. Tanpa batas ini, client meminta lebih dari yang
      bisa dilayani dan hasilnya buffering, bukan penurunan kualitas.*
- [ ] Maximum simultaneous streams: **2**

## 4. Setelah semuanya jalan

**Dashboard → Advanced → API Keys → New API Key** (nama: `scripts`)

Salin key-nya ke `.env` sebagai `JELLYFIN_API_KEY`, lalu:

    docker compose up -d

## 5. Verifikasi

Putar satu film, lalu buka **Dashboard → Activity**. Sesi harus tertulis
**Direct Play**. Kalau tertulis *Transcode* atau *Remux*, file itu melanggar
aturan di `media-guidelines.md` — perbaiki filenya, jangan setting-nya.
```

- [ ] **Step 4: Tulis `docs/media-guidelines.md`**

```markdown
# Aturan Format Media

Transcoding dimatikan karena 2 vCPU tidak sanggup melakukannya. Konsekuensinya:
file yang tidak memenuhi aturan di bawah **tidak akan diputar**. Ini disengaja
— gagal terang-terangan lebih baik daripada buffering yang misterius.

## Yang wajib

| Aspek | Aman | Akan gagal |
|---|---|---|
| Container | MKV, MP4 | AVI, WMV, ISO, VIDEO_TS |
| Video | H.264 (AVC), 8-bit, High@L4.1 | HEVC/H.265, 10-bit, AV1, VC-1 |
| Audio (track pertama) | AAC stereo | DTS, DTS-HD, TrueHD, FLAC multichannel |
| Subtitle | SRT (eksternal atau embedded) | ASS/SSA, PGS, VOBSUB |
| Bitrate video | <= 8 Mbps | Remux Blu-ray 20-40 Mbps |

**Kenapa AAC stereo di track pertama:** browser dan Chromecast tidak bisa
direct-play AC3/EAC3. Track surround boleh disimpan sebagai track kedua.

**Kenapa SRT, bukan ASS:** subtitle ASS harus di-render ke gambar dan
dibakar ke video — itu transcode penuh. SRT dikirim apa adanya ke client.

**Kenapa bukan HEVC:** meski banyak client bisa memutarnya, yang tidak bisa
akan memaksa transcode dan server akan tersedak.

## Mengubah file yang tidak memenuhi syarat

Di PC Windows, dengan HandBrake atau ffmpeg:

    ffmpeg -i masukan.mkv \
      -c:v libx264 -preset slow -crf 20 -maxrate 8M -bufsize 16M \
      -pix_fmt yuv420p \
      -c:a aac -b:a 192k -ac 2 \
      -c:s srt \
      keluaran.mkv

`-pix_fmt yuv420p` memaksa 8-bit. `-ac 2` memaksa stereo.

## Struktur folder di B2

Jellyfin mengenali judul dari nama folder dan file. Tahun dalam kurung wajib.

    Movies/
      Interstellar (2014)/
        Interstellar (2014).mkv
        Interstellar (2014).id.srt

    Shows/
      Severance (2022)/
        Season 01/
          Severance (2022) S01E01.mkv
          Severance (2022) S01E02.mkv

Nama file subtitle harus sama persis dengan file videonya, ditambah kode
bahasa: `.id.srt` untuk Indonesia, `.en.srt` untuk Inggris.
```

- [ ] **Step 5: Tulis `docs/upload-windows.md`**

```markdown
# Upload Media dari Windows

## Kenapa bukan web UI Backblaze

Web UI B2 dibatasi **500 MB per file** dan tidak mendukung upload folder.
Film 1080p biasanya 2-8 GB, jadi lewat browser secara harfiah tidak mungkin.
Ini batasan resmi Backblaze, bukan bug.

## Kenapa ini tidak memakan kuota VPS

    Upload:  PC Windows ──────────────▶ B2         VPS tidak terlibat
    Stream:  B2 ──▶ VPS ──▶ penonton               ini yang pakai kuota

Cyberduck bicara langsung ke Backblaze. VPS tidak berada di jalur upload,
jadi kuota 512 GB/bulan sama sekali tidak tersentuh. Backblaze juga tidak
menagih biaya upload.

## Setup Cyberduck (sekali saja)

1. Unduh dari https://cyberduck.io — gratis, ada versi Windows.
2. **Open Connection** → pilih **Backblaze B2** dari dropdown.
3. Isi:
   - Account ID / Application Key ID: `B2_ACCOUNT_ID` milikmu
   - Application Key: `B2_APPLICATION_KEY` milikmu
   
   Gunakan key yang **bisa menulis** di sini — key read-only di server
   sengaja dibuat terpisah dan tidak bisa dipakai upload.
4. **Connect**, lalu simpan sebagai bookmark supaya tidak perlu diisi lagi.

## Alur upload

1. Rapikan file di PC sesuai `media-guidelines.md` — struktur folder harus
   sudah benar **sebelum** diupload, karena merapikan di B2 jauh lebih repot.
2. Drag folder `Interstellar (2014)` ke dalam `Movies/` di Cyberduck.
3. Tunggu selesai. Cyberduck bisa melanjutkan upload yang terputus.
4. Di VPS, buat file langsung terlihat:

       ssh <vps> 'cd /opt/jellyfin-b2 && ./scripts/refresh-library.sh'

   Kalau tidak buru-buru, lewati langkah ini — file akan muncul sendiri
   dalam beberapa jam lewat scan terjadwal.

## Kalau upload lambat

Yang membatasi adalah kecepatan **upload** internet rumahmu, bukan Backblaze.
Cek di speedtest: angka upload-lah yang menentukan. 10 Mbps upload berarti
sekitar 1 jam per film 4 GB.
```

- [ ] **Step 6: Tulis `docs/operations.md`**

```markdown
# Runbook Operasional

## Perintah harian

    ./scripts/healthcheck.sh        # mount, container, disk
    ./scripts/quota-check.sh        # pemakaian bandwidth bulan ini
    ./scripts/refresh-library.sh    # setelah upload file baru

## Mount hilang atau library terlihat kosong

    systemctl status rclone-b2
    journalctl -u rclone-b2 -n 50 --no-pager

Penyebab paling umum, berurutan:

1. **Kredensial B2 kedaluwarsa atau dicabut.** Log akan menampilkan 401.
   Buat application key baru, perbarui `/etc/rclone/rclone.conf`,
   lalu `systemctl restart rclone-b2`.
2. **Mount ada tapi container melihat kosong.** Ini kegagalan propagasi.
   Pastikan `propagation: rslave` masih ada di `docker-compose.yml`, lalu
   `docker compose up -d --force-recreate`.
3. **rclone dimatikan OOM killer.** `journalctl -k | grep -i oom`.
   Turunkan `--buffer-size` di unit systemd.

## Disk penuh

    df -h /
    du -sh /var/cache/rclone /opt/jellyfin/*

Cache VFS punya batas keras dan membersihkan dirinya sendiri. Kalau disk
tetap penuh, tersangkanya biasanya metadata Jellyfin — periksa apakah
trickplay atau chapter image ternyata aktif (`docs/jellyfin-settings.md`),
lalu hapus isinya:

    docker compose down
    rm -rf /opt/jellyfin/cache/*
    docker compose up -d

## Kuota bandwidth hampir habis

    ./scripts/quota-check.sh

Tidak ada throttling otomatis — keputusan ada padamu. Pilihan:
turunkan *Internet streaming bitrate limit* per user, atau berhenti menonton
sampai bulan berikutnya. Kalau kuota habis, Tencent biasanya menurunkan
kecepatan drastis, bukan memutus koneksi.

## Pemutaran buffering

Buka **Dashboard → Activity** saat sedang memutar.

- Tertulis **Transcode** atau **Remux** → filenya melanggar
  `media-guidelines.md`. Perbaiki filenya.
- Tertulis **Direct Play** tapi tetap buffering → bitrate file melebihi
  20 Mbps yang tersedia, atau ada stream kedua yang berjalan.

## Upgrade Jellyfin

    # 1. Snapshot dulu lewat panel Tencent.
    # 2. Ubah JELLYFIN_IMAGE di .env ke versi baru.
    docker compose pull && docker compose up -d
    ./scripts/healthcheck.sh

Rollback: kembalikan `JELLYFIN_IMAGE` ke versi lama, `docker compose up -d`.
Jangan pernah memakai tag `:latest` — itu membuat rollback mustahil.

## Setelah reboot VPS

Seharusnya tidak perlu apa-apa. Docker sengaja diurutkan setelah mount,
jadi keduanya hidup dengan urutan yang benar. Verifikasi:

    ./scripts/healthcheck.sh

Kalau Docker tidak start, biasanya karena mount gagal — itu perilaku yang
disengaja. Perbaiki mount-nya dulu, Docker akan menyusul.
```

- [ ] **Step 7: Tulis `docs/client-setup.md`**

```markdown
# Menghubungkan Device ke Jellyfin

Tidak ada IP yang perlu diingat, tidak ada port forwarding, tidak ada DDNS.
Tailscale memberi server ini nama tetap yang berfungsi dari mana saja —
rumah, kantor, data seluler, Wi-Fi hotel.

## Sekali per device

1. Install Tailscale:
   - Android: Play Store
   - iOS / iPadOS: App Store
   - Windows / macOS / Linux: https://tailscale.com/download
2. Login dengan akun yang **sama** dengan yang dipakai di VPS.
3. Aktifkan. Device dapat alamat `100.x.x.x` dan langsung bisa melihat server.

## Sekali per app Jellyfin

Buka app Jellyfin, pilih **Add Server**, isi alamatnya:

    https://jellyfin.<nama-tailnet>.ts.net

Nama persisnya bisa dilihat di VPS dengan `tailscale serve status`, atau di
admin console Tailscale. Alamat ini tidak pernah berubah — tidak perlu
diperbarui saat kamu pindah jaringan atau saat IP VPS berganti.

Login dengan user Jellyfin, lalu selesai. App akan mengingat servernya.

## Kenapa tidak pakai IP

MagicDNS memetakan `jellyfin.<tailnet>.ts.net` ke alamat tailnet server
secara otomatis. Memakai IP `100.x.x.x` mentah juga bisa, tapi sertifikat
TLS diterbitkan untuk nama DNS-nya — pakai IP dan kamu akan dapat peringatan
sertifikat. Selalu pakai nama.

## Jika tidak bisa terhubung

| Gejala | Penyebab biasanya |
|---|---|
| Tailscale menyala tapi server tidak terlihat | Device login ke akun/tailnet berbeda |
| Nama tidak me-resolve | MagicDNS mati di admin console Tailscale |
| Peringatan sertifikat | Memakai IP, bukan nama `.ts.net` |
| Terhubung tapi pemutaran lambat | Tailscale jatuh ke relay DERP, bukan koneksi langsung. Cek `tailscale status` — kalau tertulis "relay", buka UDP 41641 di security group Tencent |

Baris terakhir itu penting: koneksi lewat relay DERP jauh lebih lambat dan
akan merusak pemutaran. Pastikan **UDP 41641** diizinkan masuk di firewall
Tencent supaya Tailscale bisa membangun koneksi langsung.

## Batasan device

| Device | Status |
|---|---|
| Windows, macOS, Linux, iOS, Android | App resmi |
| Apple TV (tvOS 17+) | App resmi |
| Android TV, Fire TV, Nvidia Shield | Pakai app Android |
| Smart TV Samsung (Tizen) dan LG (webOS) | **Tidak didukung** — tidak ada client Tailscale untuk platform ini |

Kalau nanti butuh menonton di TV Samsung/LG, jalan termudah adalah menambah
streaming box (Apple TV atau Fire TV) daripada mengekspos Jellyfin ke
internet.
```

- [ ] **Step 8: Tulis `README.md`**

```markdown
# Jellyfin + Backblaze B2

Server media Jellyfin di VPS kecil, dengan seluruh file tersimpan di
Backblaze B2. VPS tidak menyimpan media dan tidak terlibat dalam upload —
perannya murni menstream.

Akses hanya lewat Tailscale. Tidak ada port yang terbuka ke internet.

## Kendala yang membentuk desain ini

| | |
|---|---|
| 2 vCPU | Transcoding dimatikan total. Direct play saja. |
| 2 GB RAM | Buffer dibatasi, swap 2 GB, DLNA dimatikan. |
| 40 GB disk | Cache VFS dibatasi keras 10 GB. |
| 20 Mbps | Sekitar 1 stream 1080p pada satu waktu. |
| 512 GB/bulan | Sekitar 100 film atau 250 jam 1080p. |

## Instalasi

Di VPS Debian 12 yang masih bersih:

    git clone <repo> /opt/jellyfin-b2
    cd /opt/jellyfin-b2
    cp .env.example .env
    nano .env                       # isi kredensial B2
    sudo ./scripts/bootstrap.sh

Lalu ikuti tiga langkah manual yang dicetak bootstrap: `tailscale up`,
`tailscale serve`, dan checklist di [docs/jellyfin-settings.md](docs/jellyfin-settings.md).

## Dokumentasi

- [Checklist setting Jellyfin](docs/jellyfin-settings.md) — **kerjakan ini**, bukan opsional
- [Aturan format media](docs/media-guidelines.md) — apa yang bisa dan tidak bisa diputar
- [Upload dari Windows](docs/upload-windows.md) — setup Cyberduck
- [Menghubungkan device](docs/client-setup.md) — alamat apa yang dimasukkan di app Jellyfin
- [Runbook operasional](docs/operations.md) — saat ada yang rusak

## Skrip

| Skrip | Fungsi |
|---|---|
| [scripts/bootstrap.sh](scripts/bootstrap.sh) | Provisioning satu perintah. Idempoten. `--dry-run` untuk mengintip. |
| [scripts/preflight.sh](scripts/preflight.sh) | Validasi tanpa mengubah apa pun. |
| [scripts/refresh-library.sh](scripts/refresh-library.sh) | Membuat file yang baru diupload langsung muncul. |
| [scripts/healthcheck.sh](scripts/healthcheck.sh) | Mount, container, disk. |
| [scripts/quota-check.sh](scripts/quota-check.sh) | Pemakaian bandwidth bulan ini. |

## Pengembangan

    bash tests/run.sh
    shellcheck scripts/*.sh scripts/lib/*.sh

Seluruh suite berjalan di laptop tanpa server.

## Desain

- [Design spec](docs/superpowers/specs/2026-08-20-jellyfin-b2-design.md) — keputusan dan alasannya
- [Implementation plan](docs/superpowers/plans/2026-08-20-jellyfin-b2-setup.md) — langkah demi langkah
```

- [ ] **Step 9: Jalankan tes untuk memastikan LULUS**

```bash
bash tests/run.sh
```

Harapan: LULUS, seluruh suite.

- [ ] **Step 10: Commit**

```bash
git add README.md docs/ tests/test_docs.sh
git commit -m "docs: checklist setting, aturan media, panduan upload, runbook"
```

---

### Task 10: Verifikasi di server

Satu-satunya task yang butuh VPS. Tidak ada kode yang ditulis — ini menjalankan
8 kriteria keberhasilan dari bagian 12 spec dan mencatat hasilnya.

**Files:**
- Modify: `docs/operations.md` (tambahkan catatan hasil verifikasi di akhir)

**Interfaces:**
- Consumes: seluruh isi repo dari Task 1–9.
- Produces: konfirmasi bahwa setup berjalan, atau daftar cacat konkret.

- [ ] **Step 1: Deploy**

```bash
# Di VPS Debian 12 yang bersih:
git clone <repo> /opt/jellyfin-b2 && cd /opt/jellyfin-b2
cp .env.example .env && nano .env
sudo ./scripts/bootstrap.sh --dry-run     # tinjau dulu apa yang akan dilakukan
sudo ./scripts/bootstrap.sh
```

- [ ] **Step 2: Sambungkan Tailscale dan paparkan Jellyfin**

```bash
sudo tailscale up --hostname=jellyfin
sudo tailscale serve --bg 8096
tailscale serve status
```

Salin URL `https://...ts.net` ke `JELLYFIN_PUBLISHED_URL` di `.env`.

- [ ] **Step 3: Selesaikan wizard dan kerjakan checklist setting**

Buka URL tailnet, selesaikan wizard awal, lalu kerjakan
`docs/jellyfin-settings.md` dari atas ke bawah **sebelum** menambahkan library.

- [ ] **Step 4: Verifikasi kriteria 1-3 (infrastruktur)**

```bash
systemctl is-active rclone-b2 && ls /srv/media
ss -tlnp | grep -v '127.0.0.1' | grep -v '::1'
```

Harapan: `active`, isi bucket terdaftar, dan **tidak ada** listener di IP
publik selain sshd. Kalau port 8096 muncul di `0.0.0.0`, hentikan dan
perbaiki — Jellyfin sedang terekspos ke internet.

- [ ] **Step 5: Verifikasi kriteria 4-5 (pemutaran)**

Putar satu film 1080p dari device lain di tailnet, dari awal sampai akhir.
Saat memutar, buka **Dashboard → Activity**.

Harapan: tertulis **Direct Play**. Seek ke tengah film harus merespons dalam
<5 detik. Kalau tertulis Transcode, filenya melanggar `media-guidelines.md`.

- [ ] **Step 6: Verifikasi kriteria 6-7 (perkakas)**

```bash
./scripts/healthcheck.sh
./scripts/quota-check.sh
# Upload satu file dari Windows lewat Cyberduck, lalu:
./scripts/refresh-library.sh
```

Harapan: healthcheck seluruhnya hijau; quota-check melaporkan angka masuk
akal; file yang baru diupload muncul di Jellyfin dalam beberapa menit.

- [ ] **Step 7: Verifikasi kriteria 8 (bertahan reboot)**

```bash
sudo reboot
# tunggu, lalu:
./scripts/healthcheck.sh
```

Harapan: semua hijau tanpa intervensi manual. Ini yang membuktikan
pengurutan Docker-setelah-mount bekerja.

- [ ] **Step 8: Catat hasilnya dan commit**

Tambahkan bagian di akhir `docs/operations.md`:

```markdown
## Hasil verifikasi

Diverifikasi pada <tanggal> di <spesifikasi VPS>. Semua 8 kriteria dari
bagian 12 spec lolos, kecuali yang dicatat di bawah.

| # | Kriteria | Hasil |
|---|---|---|
| 1 | Mount aktif, bucket terbaca | |
| 2 | Bisa diakses di URL tailnet | |
| 3 | Tidak ada listener publik | |
| 4 | Film 1080p Direct Play sampai habis | |
| 5 | Seek merespons <5 detik | |
| 6 | quota-check melaporkan dengan benar | |
| 7 | File baru muncul setelah refresh | |
| 8 | Bertahan setelah reboot | |
```

```bash
git add docs/operations.md
git commit -m "docs: catat hasil verifikasi di server"
```

---

## Self-Review

**1. Cakupan spec.** Setiap bagian spec dipetakan ke task:

| Bagian spec | Task |
|---|---|
| 3 Arsitektur | 3, 4 (compose + systemd) |
| 4.1 Mount rclone | 4 |
| 4.2 Jellyfin | 3 |
| 4.3 Tailscale | 6 (instalasi), 10 (`tailscale up`/`serve`) |
| 5 Setting Jellyfin wajib | 9 (`jellyfin-settings.md`), diuji di `test_docs.sh` |
| 6 Aturan media | 9 (`media-guidelines.md`) |
| 7 Alur upload | 9 (`upload-windows.md`), 7 (`refresh-library.sh`) |
| 4.3 Akses client | 9 (`client-setup.md`) |
| 8 Konfigurasi B2 | 5 (preflight memverifikasi read-only), 9 |
| 9 Anggaran disk | 2 (batas cache), 5 (cek disk), 6 (batas journald/docker) |
| 10 Isi repository | seluruh task |
| 11 Penanganan kegagalan | 4 (restart), 6 (pengurutan), 8 (healthcheck), 9 (runbook) |
| 12 Kriteria keberhasilan | 10 |

Tidak ada bagian spec yang tidak tercakup.

**2. Pemindaian placeholder.** Tidak ada "TBD", "TODO", atau "implementasikan
nanti". Setiap langkah kode berisi kode sungguhan. Satu-satunya bagian yang
sengaja dikosongkan adalah kolom hasil di tabel verifikasi Task 10, yang
memang diisi saat dijalankan.

**3. Konsistensi tipe.** Nama fungsi diperiksa lintas task:
`log`/`info`/`warn`/`die`/`require_cmd`/`require_env`/`load_env`/`repo_root`
didefinisikan di Task 1 dan dipakai dengan ejaan sama di Task 5, 6, 7, 8.
Nama variabel `.env` konsisten antara Task 2, 3, 4, 5, 6, 7, 8 — dan
`test_env_example.sh` menegakkannya secara mekanis. Kontrak CLI
(`--env-file`, `--dry-run`, `--config-only`) seragam di semua skrip.

**Satu inkonsistensi yang ditemukan dan diperbaiki saat review:** Task 8
awalnya memakai `set -euo pipefail` seperti skrip lain, padahal healthcheck
harus menjalankan SEMUA cek lalu melaporkan, bukan berhenti di kegagalan
pertama. Skrip itu kini memakai `set -uo pipefail` diikuti `set +e`, dengan
komentar yang menjelaskan alasannya.

---

## Catatan Eksekusi

Dieksekusi 2026-08-20. Task 1-9 selesai; 111 tes hijau, `shellcheck -x`
bersih di seluruh skrip. Task 10 menunggu VPS.

Plan ini adalah artefak historis — **repo yang menjadi kebenaran**. Enam
penyimpangan ditemukan saat eksekusi. Semuanya dicatat di sini alih-alih
menulis ulang plan diam-diam, karena selisihnya justru informasi yang
berguna.

### 1. Bug quoting: `'$PF'` di dalam `$( )`

Plan menulis `_msg="$( '$PF' --config-only ... )"`. Di dalam substitusi
perintah, kutip tunggal membuat `$PF` menjadi literal, sehingga shell mencari
perintah bernama `$PF`. Yang benar `"$PF"`. Sama untuk `'$BS'` di
`test_bootstrap.sh`.

Aturannya: di dalam string yang akan di-`eval` oleh `assert_ok`, variabel
harus diekspansi saat string dibangun; di dalam `$( )` biasa, pakai kutip
ganda seperti biasa.

### 2. Bug quoting: `\$PATH` di dalam string assertion

`PATH='$_d2:\$PATH'` membuat `PATH` berisi literal `$PATH`, sehingga
`dirname` tidak ditemukan dan skrip mati sebelum sempat diuji. Backslash-nya
dihapus supaya `$PATH` diekspansi saat string dibangun.

Bug ini menyamar sebagai kegagalan skrip, padahal skripnya benar — persis
jenis kesalahan yang membuat orang "memperbaiki" kode yang tidak rusak.

### 3. Tes `0.0.0.0` ikut mencocokkan komentar

`assert_fail "tidak ada bind 0.0.0.0"` gagal karena `docker-compose.yml`
memuat komentar yang memperingatkan bahaya `0.0.0.0`. Assertion diperbaiki
agar melewati baris komentar: yang dilarang adalah konfigurasinya, bukan
peringatan tentangnya. Assertion `:latest` diperbaiki dengan cara sama.

### 4. `ls` diganti `find` di bootstrap

shellcheck SC2012. Bukan sekadar formalitas di sini — nama folder film penuh
spasi dan tanda kurung (`Interstellar (2014)`), persis kasus yang membuat
`ls` salah.

### 5. `cd` tanpa penjaga di `tests/run.sh`

shellcheck SC2164. Ditambahkan `|| exit 1`.

### 6. Heredoc penutup bootstrap harus tidak dikutip

Plan memakai `<<'NEXT'`, yang membuat instruksi tercetak sebagai
`--hostname="$TS_HOSTNAME"` secara literal — operator akan menyalin nama
variabel mentah ke terminal. Diubah ke `<<NEXT` supaya nilainya diekspansi.
Sebuah assertion ditambahkan untuk mengunci perilaku ini.

### Penambahan di luar plan

- **Konvensi `shellcheck -x`** dipakai, bukan `shellcheck` polos, supaya
  direktif `# shellcheck source=` diikuti dan SC1091 tidak muncul.
- **`docs/client-setup.md` diperluas** dengan bagian key expiry Tailscale,
  setelah pertanyaan pengguna saat eksekusi. Kunci device kedaluwarsa tiap
  180 hari secara default; kalau itu terjadi di VPS, Jellyfin lenyap dari
  tailnet tanpa peringatan. Dua assertion ditambahkan agar peringatan ini
  tidak bisa hilang dari dokumentasi.

### 7. `B2_ACCOUNT_ID` diganti `B2_KEY_ID` (pasca-eksekusi)

Ditemukan lewat pertanyaan pengguna: "di env pakainya bucket id atau bucket
name?"

Dokumentasi rclone menyatakan field `account` harus diisi **applicationKeyId**,
bukan master Account ID — B2 membalas **401** kalau salah. Nama variabel
`B2_ACCOUNT_ID` yang saya pilih justru menyuruh operator mengisi nilai yang
salah, dan gejalanya (401) tidak menunjuk ke penyebabnya sama sekali.

Diganti jadi `B2_KEY_ID` di seluruh file aktif. `.env.example` sekarang
menyatakan eksplisit "BUKAN master Account ID", dan pesan error `preflight.sh`
mengurutkan tiga penyebab 401 yang paling mungkin. Empat assertion mengunci
penjelasan itu di dokumentasi.

Jawaban pertanyaan aslinya: `B2_BUCKET` diisi **nama bucket**, bukan bucket ID.
Ini juga sekarang tertulis di `.env.example`.

Nama lama sengaja dibiarkan di bagian atas plan dan di spec — keduanya
artefak historis; repo yang menjadi kebenaran.

---

## Perubahan Arsitektur Pasca-Eksekusi: Tailscale → WireGuard

**2026-08-20, setelah Task 1–9 selesai dan ter-push.**

Pengguna melaporkan Tailscale terlalu merepotkan — login sulit. Mula-mula
mengusulkan "Cloudflare WireGuard", lalu mengklarifikasi maksudnya WireGuard
murni.

**Kenapa Cloudflare ditolak.** Padanan Tailscale dari Cloudflare adalah Zero
Trust + WARP, dan itu tetap menuntut enrolment per device — jadi tidak
menyelesaikan keluhan aslinya sama sekali, sekaligus mengembalikan persoalan
ToS video Cloudflare yang sudah kami hindari di keputusan #3 spec. Lebih
banyak bagian bergerak untuk masalah yang tetap tidak terpecahkan.

**Kenapa WireGuard murni menyelesaikannya.** Tidak ada konsep akun sama
sekali. Satu config per device, dibuat sekali, berlaku selamanya. Tidak ada
SSO, tidak ada admin console, tidak ada key expiry 180 hari yang justru baru
kami dokumentasikan sebagai jebakan.

### Yang berubah

| Berkas | Perubahan |
|---|---|
| `.env.example` | `TS_HOSTNAME` dihapus; enam variabel `WG_*` ditambahkan; `JELLYFIN_BIND` 127.0.0.1 → 10.8.0.1; `JELLYFIN_PUBLISHED_URL` kini punya default karena alamatnya tetap |
| `preflight.sh` | Cek bind berubah dari "harus 127.0.0.1" jadi "harus sama dengan `WG_SERVER_IP`" + wajib RFC1918; `check_wireguard()` baru memverifikasi modul kernel dan mencocokkan `WG_ENDPOINT` dengan IP publik sungguhan |
| `bootstrap.sh` | Instalasi Tailscale → WireGuard; langkah 8 baru membuat kunci server dan `wg0.conf`; `write_once()` baru |
| `systemd/docker-after-mount.conf` | Diganti nama jadi `docker-after-deps.conf`; kini menunggu `wg-quick@wg0` juga |
| `scripts/add-client.sh` | **Baru.** Alokasi IP, pembuatan kunci, penerapan tanpa putus, QR code |
| `docs/client-setup.md` | Ditulis ulang total |
| `docs/operations.md` | Bagian key expiry Tailscale → diagnosis `wg show` |

### `write_once()` — kenapa perlu helper baru

`write_file()` selalu menimpa, dan itu benar untuk file yang murni turunan
dari `.env`. Tapi `wg0.conf` **menumpuk state**: `add-client.sh` menambahkan
blok `[Peer]` ke situ. Menimpanya saat bootstrap dijalankan ulang akan
menghapus setiap device yang pernah didaftarkan, diam-diam. Hal yang sama
berlaku untuk kunci privat server — meregenerasinya memutus semua client
sekaligus.

Keduanya kini dijaga, dan dua assertion mengunci penjagaan itu.

### Dua bug yang ditemukan tes selama migrasi

1. **Assertion mencocokkan komentar sendiri.** `assert_fail "tidak ada
   MASQUERADE"` gagal karena komentar di `bootstrap.sh` menjelaskan *kenapa*
   MASQUERADE tidak ada. Kelas bug yang sama persis dengan kasus `0.0.0.0`
   di Task 3 — diperbaiki dengan cara sama: kecualikan baris komentar.

2. **Assertion prosa terlalu kaku soal kapitalisasi.** `assert_contains`
   bersifat case-sensitive, sehingga "Tanpa login" di awal kalimat tidak
   cocok dengan pola `tanpa login`. Alih-alih menulis ulang dokumen supaya
   sesuai tes, ditambahkan helper `assert_contains_i` — untuk assertion
   terhadap prosa, kapitalisasi memang tidak seharusnya jadi penentu.

### Hasil

150 tes hijau, `shellcheck -x` bersih di 8 skrip, `host_ip` hasil resolusi
Docker terverifikasi `10.8.0.1`. Task 10 tetap menunggu VPS, dengan kriteria
2 dan 3 diperbarui mengikuti arsitektur baru.
