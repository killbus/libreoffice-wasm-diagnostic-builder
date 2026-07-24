#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$PROJECT_DIR/build.env"

BUILD_JOBS_REQUESTED="${BUILD_JOBS:-4}"
if [[ ! "$BUILD_JOBS_REQUESTED" =~ ^[1-9][0-9]*$ ]]; then
  echo "BUILD_JOBS must be a positive integer: $BUILD_JOBS_REQUESTED" >&2
  exit 2
fi
WORK_ROOT="${WORK_ROOT:-${RUNNER_TEMP:-$PROJECT_DIR/.work}/libreoffice-wasm-diagnostic}"
CACHE_ROOT="${CACHE_ROOT:-$PROJECT_DIR/.cache}"
OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_DIR/output}"
LOG_DIR="${LOG_DIR:-$PROJECT_DIR/logs}"
LO_DIR="$WORK_ROOT/libreoffice"
EMSDK_DIR="$CACHE_ROOT/emsdk"
TARBALLS_DIR="$CACHE_ROOT/tarballs"
CCACHE_DIR="$CACHE_ROOT/ccache"
EM_CACHE="$CACHE_ROOT/emscripten-cache"
BUILD_LOG="$LOG_DIR/build.log"
AUTOTEXT_HELPER_PID=""

mkdir -p "$WORK_ROOT" "$CACHE_ROOT" "$OUTPUT_DIR" "$LOG_DIR" \
  "$TARBALLS_DIR" "$CCACHE_DIR" "$EM_CACHE"
: > "$BUILD_LOG"
exec > >(tee -a "$BUILD_LOG") 2>&1

log() { printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"; }

copy_diagnostics() {
  set +e
  if [ -f "$LO_DIR/config.log" ]; then cp "$LO_DIR/config.log" "$LOG_DIR/config.log"; fi
  if [ -f "$LO_DIR/config_host.mk" ]; then cp "$LO_DIR/config_host.mk" "$LOG_DIR/config_host.mk"; fi
  git -C "$LO_DIR" status --short > "$LOG_DIR/libreoffice-status.txt" 2>/dev/null || true
  ccache --show-stats > "$LOG_DIR/ccache-stats.txt" 2>&1 || true
  df -h > "$LOG_DIR/disk-usage.txt" 2>&1 || true
}

cleanup() {
  if [ -n "$AUTOTEXT_HELPER_PID" ]; then
    kill "$AUTOTEXT_HELPER_PID" 2>/dev/null || true
    wait "$AUTOTEXT_HELPER_PID" 2>/dev/null || true
  fi
  copy_diagnostics
}
trap cleanup EXIT

verify_sha256() {
  local file="$1"
  local expected="${2,,}"
  local actual
  actual="$(sha256sum "$file" | awk '{print $1}')"
  if [ "$actual" != "$expected" ]; then
    printf 'SHA-256 mismatch: %s\nexpected: %s\nactual:   %s\n' "$file" "$expected" "$actual" >&2
    exit 1
  fi
}

select_build_jobs() {
  local cpu_jobs memory_kib memory_jobs selected
  cpu_jobs="$(nproc)"
  memory_kib="$(awk '/MemAvailable:/ { print $2 }' /proc/meminfo)"
  memory_jobs=$((memory_kib / 3145728))
  if [ "$memory_jobs" -lt 1 ]; then memory_jobs=1; fi
  selected="$BUILD_JOBS_REQUESTED"
  if [ "$selected" -gt "$cpu_jobs" ]; then selected="$cpu_jobs"; fi
  if [ "$selected" -gt "$memory_jobs" ]; then selected="$memory_jobs"; fi
  printf '%s' "$selected"
}

BUILD_JOBS_EFFECTIVE="$(select_build_jobs)"
export CCACHE_DIR EM_CACHE

log "project=$PROJECT_DIR"
log "work_root=$WORK_ROOT"
log "libreoffice_commit=$LIBREOFFICE_COMMIT"
log "emsdk_version=$EMSDK_VERSION"
log "build_jobs=requested:$BUILD_JOBS_REQUESTED effective:$BUILD_JOBS_EFFECTIVE"
free -h || true
df -h "$PROJECT_DIR" "$WORK_ROOT" || true

verify_sha256 "$PROJECT_DIR/autogen.input" "$AUTOGEN_INPUT_SHA256"
verify_sha256 "$PROJECT_DIR/patches/wasm-build-fixes.patch" "$WASM_BUILD_FIXES_SHA256"
verify_sha256 "$PROJECT_DIR/patches/libreoffice-24-8-saveas-native-markers.patch" "$NATIVE_MARKERS_SHA256"
log "verified pinned build inputs"

if [ ! -d "$EMSDK_DIR/.git" ]; then
  log "cloning emsdk"
  git clone --depth 1 https://github.com/emscripten-core/emsdk.git "$EMSDK_DIR"
fi
pushd "$EMSDK_DIR" >/dev/null
./emsdk install "$EMSDK_VERSION"
./emsdk activate "$EMSDK_VERSION"
# shellcheck disable=SC1091
source ./emsdk_env.sh >/dev/null
popd >/dev/null
log "$(emcc --version | sed -n '1p')"
embuilder build sysroot libc libc++ libc++abi

if [ ! -d "$LO_DIR/.git" ]; then
  log "initializing LibreOffice source"
  mkdir -p "$LO_DIR"
  git -C "$LO_DIR" init
  git -C "$LO_DIR" remote add origin https://github.com/LibreOffice/core.git
else
  git -C "$LO_DIR" remote set-url origin https://github.com/LibreOffice/core.git
fi
log "fetching pinned LibreOffice commit"
git -C "$LO_DIR" fetch --depth 1 origin "$LIBREOFFICE_COMMIT"
git -C "$LO_DIR" checkout --detach FETCH_HEAD
git -C "$LO_DIR" reset --hard "$LIBREOFFICE_COMMIT"
git -C "$LO_DIR" clean -ffd

actual_commit="$(git -C "$LO_DIR" rev-parse HEAD)"
if [ "$actual_commit" != "$LIBREOFFICE_COMMIT" ]; then
  echo "LibreOffice revision mismatch: $actual_commit" >&2
  exit 1
fi
printf '%s\n' "$actual_commit" > "$LOG_DIR/source-revision.txt"

pushd "$LO_DIR" >/dev/null
log "applying WASM build fixes"
patch --batch --forward -p1 < "$PROJECT_DIR/patches/wasm-build-fixes.patch"
log "applying native save/export markers"
patch --batch --forward -p1 < "$PROJECT_DIR/patches/libreoffice-24-8-saveas-native-markers.patch"
if ! grep -q 'LOK_SAVEAS_TRACE' include/vcl/lokwasmsaveasdiagnostic.hxx; then
  echo "Native marker verification failed" >&2
  exit 1
fi

cp "$PROJECT_DIR/autogen.input" autogen.input
mkdir -p external
if [ -e external/tarballs ] || [ -L external/tarballs ]; then
  rm -rf -- external/tarballs
fi
ln -s "$TARBALLS_DIR" external/tarballs
ccache --max-size=4G
ccache --zero-stats
log "configuring LibreOffice"
./autogen.sh
cp config.log "$LOG_DIR/config.log"
cp config_host.mk "$LOG_DIR/config_host.mk"

create_autotext_files() {
  local target="$LO_DIR/workdir/CustomTarget/extras/source/autotext/user/mytexts"
  if [ -d "$target" ] && [ ! -f "$target/BlockList.xml" ]; then
    mkdir -p "$target/META-INF"
    if [ -f "$LO_DIR/extras/source/autotext/mytexts/BlockList.xml" ]; then
      cp "$LO_DIR/extras/source/autotext/mytexts/BlockList.xml" "$target/"
    else
      printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<block-list:block-list xmlns:block-list="http://openoffice.org/2001/block-list"/>' > "$target/BlockList.xml"
    fi
    if [ -f "$LO_DIR/extras/source/autotext/mytexts/META-INF/manifest.xml" ]; then
      cp "$LO_DIR/extras/source/autotext/mytexts/META-INF/manifest.xml" "$target/META-INF/"
    else
      printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0">' ' <manifest:file-entry manifest:media-type="application/vnd.sun.star.autotext" manifest:full-path="/"/>' ' <manifest:file-entry manifest:media-type="text/xml" manifest:full-path="BlockList.xml"/>' '</manifest:manifest>' > "$target/META-INF/manifest.xml"
    fi
    : > "$target/mimetype"
    log "created missing autotext files"
  fi
}

(
  sleep 30
  while true; do
    create_autotext_files
    sleep 10
  done
) &
AUTOTEXT_HELPER_PID="$!"

log "building LibreOffice WASM"
make -j"$BUILD_JOBS_EFFECTIVE"
log "LibreOffice build completed"

rm -f -- "$OUTPUT_DIR"/soffice.wasm "$OUTPUT_DIR"/soffice.data "$OUTPUT_DIR"/soffice.js "$OUTPUT_DIR"/soffice.cjs "$OUTPUT_DIR"/soffice.worker.js "$OUTPUT_DIR"/soffice.worker.cjs "$OUTPUT_DIR"/SHA256SUMS "$OUTPUT_DIR"/BUILD-METADATA.txt
mkdir -p "$OUTPUT_DIR"
PROGRAM_DIR="$LO_DIR/instdir/program"
for required in soffice.wasm soffice.data soffice.js; do
  if [ ! -s "$PROGRAM_DIR/$required" ]; then
    echo "Missing build output: $PROGRAM_DIR/$required" >&2
    exit 1
  fi
done

cp "$PROGRAM_DIR/soffice.wasm" "$OUTPUT_DIR/soffice.wasm"
cp "$PROGRAM_DIR/soffice.data" "$OUTPUT_DIR/soffice.data"
cp "$PROGRAM_DIR/soffice.js" "$OUTPUT_DIR/soffice.cjs"
if [ -s "$PROGRAM_DIR/soffice.worker.js" ]; then
  cp "$PROGRAM_DIR/soffice.worker.js" "$OUTPUT_DIR/soffice.worker.cjs"
fi

pushd "$OUTPUT_DIR" >/dev/null
if ! head -c 80 soffice.cjs | grep -q 'global.Module'; then
  sed -i '1s/^/if(typeof global!=="undefined"){var Module=global.Module=global.Module||{}}\n/' soffice.cjs
fi
sed -i 's|PACKAGE_NAME="[^"]*emscripten_fs_image/soffice\.data"|PACKAGE_NAME="soffice.data"|g' soffice.cjs
sed -i "s|PACKAGE_NAME='[^']*emscripten_fs_image/soffice\.data'|PACKAGE_NAME='soffice.data'|g" soffice.cjs
sed -i 's|datafile_[^"]*emscripten_fs_image/soffice\.data|datafile_soffice.data|g' soffice.cjs
cp soffice.cjs soffice.js
if [ -f soffice.worker.cjs ]; then cp soffice.worker.cjs soffice.worker.js; fi

if ! grep -a -q 'LOK_SAVEAS_TRACE' soffice.wasm; then
  echo "Built WASM does not contain LOK_SAVEAS_TRACE" >&2
  exit 1
fi
sha256sum soffice.* > SHA256SUMS
{
  printf 'libreoffice_commit=%s\n' "$LIBREOFFICE_COMMIT"
  printf 'emsdk_version=%s\n' "$EMSDK_VERSION"
  printf 'build_jobs=%s\n' "$BUILD_JOBS_EFFECTIVE"
  printf 'built_at=%s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
} > BUILD-METADATA.txt
popd >/dev/null
popd >/dev/null

log "diagnostic artifacts ready"
ls -lh "$OUTPUT_DIR"