#!/usr/bin/env bash
# Build static ffmpeg + ffprobe for one macOS architecture.
#
#   ./build.sh arm64     -> dist/ffmpeg-aarch64-apple-darwin.zip
#   ./build.sh x86_64    -> dist/ffmpeg-x86_64-apple-darwin.zip (cross-built on Apple silicon)
#
# Needs Xcode command line tools plus nasm, meson, ninja and pkg-config.
# Only what ytd uses is enabled: libx264, libvpx, libopus, libmp3lame,
# libdav1d, zlib and Secure Transport (HTTPS input for trimmed downloads).
set -euo pipefail
# macOS bash 3.2 treats an empty array as unbound under -u: expand arrays as
# ${arr[@]+"${arr[@]}"}.

ARCH=${1:?usage: build.sh arm64|x86_64}
case "$ARCH" in
  arm64) TRIPLE=aarch64-apple-darwin; FF_ARCH=aarch64; VPX_TARGET=arm64-darwin20-gcc ;;
  x86_64) TRIPLE=x86_64-apple-darwin; FF_ARCH=x86_64; VPX_TARGET=x86_64-darwin20-gcc ;;
  *) echo "unknown arch: $ARCH" >&2; exit 2 ;;
esac

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=versions.env
source "$HERE/versions.env"

WORK=${WORK:-$HERE/work/$ARCH}
SRC=$WORK/src
PREFIX=$WORK/prefix
DIST=${DIST:-$HERE/dist}
JOBS=$(sysctl -n hw.ncpu)
CROSS=0
[ "$(uname -m)" != "$ARCH" ] && CROSS=1
# Only Apple silicon hosts are supported (CI uses them): an x86_64 build is
# cross-compiled there. arm64 on an Intel host would need other tool flags.
if [ "$(uname -m)" = x86_64 ] && [ "$ARCH" = arm64 ]; then
  echo "build.sh: building arm64 on an Intel Mac is not supported; use Apple silicon" >&2
  exit 2
fi

export MACOSX_DEPLOYMENT_TARGET=11.0
# Only our own prefix: never pick up Homebrew's libraries.
export PKG_CONFIG_LIBDIR=$PREFIX/lib/pkgconfig
export PKG_CONFIG_PATH=
ARCHCC="clang -arch $ARCH"

rm -rf "$WORK"
mkdir -p "$SRC" "$PREFIX" "$DIST"

log() { printf '\n==> %s\n' "$*"; }

# git source pinned to a commit: fetch that commit itself (not the tag or
# branch tip, which can move), then check HEAD. `ref` is for the log only.
fetch_git() {
  local name=$1 url=$2 ref=$3 commit=$4
  log "fetch $name $ref ($commit)"
  git init --quiet "$SRC/$name"
  git -C "$SRC/$name" fetch --quiet --depth 1 "$url" "$commit"
  git -C "$SRC/$name" checkout --quiet FETCH_HEAD
  local head
  head=$(git -C "$SRC/$name" rev-parse HEAD)
  if [ "$head" != "$commit" ]; then
    echo "$name: fetched $head, expected $commit" >&2
    exit 1
  fi
}

# tarball pinned to a SHA-256.
fetch_tar() {
  local name=$1 url=$2 sha=$3 file
  file=$SRC/$(basename "$url")
  log "fetch $name"
  curl -fsSL --retry 3 -o "$file" "$url"
  echo "$sha  $file" | shasum -a 256 -c -
  mkdir -p "$SRC/$name"
  tar -xf "$file" -C "$SRC/$name" --strip-components 1
}

host_flag() {
  if [ "$CROSS" = 1 ]; then echo "--host=$TRIPLE"; fi
}

fetch_git ffmpeg https://github.com/FFmpeg/FFmpeg.git "$FFMPEG_TAG" "$FFMPEG_COMMIT"
# Fetched by commit there is no tag, so FFmpeg would call itself by the bare
# hash; yt-dlp reads that version. Its version script (ffbuild/version.sh)
# takes the release number from FF_VERSION.
echo "$FFMPEG_TAG" >"$SRC/ffmpeg/FF_VERSION"
fetch_git x264 https://code.videolan.org/videolan/x264.git "$X264_BRANCH" "$X264_COMMIT"
fetch_git libvpx https://github.com/webmproject/libvpx.git "$LIBVPX_TAG" "$LIBVPX_COMMIT"
fetch_git dav1d https://code.videolan.org/videolan/dav1d.git "$DAV1D_TAG" "$DAV1D_COMMIT"
fetch_tar opus "https://downloads.xiph.org/releases/opus/opus-$OPUS_VERSION.tar.gz" "$OPUS_SHA256"
fetch_tar lame "https://downloads.sourceforge.net/project/lame/lame/$LAME_VERSION/lame-$LAME_VERSION.tar.gz" "$LAME_SHA256"

log "x264"
(
  cd "$SRC/x264"
  CC=clang ./configure --prefix="$PREFIX" --enable-static --disable-cli --enable-pic \
    --extra-cflags="-arch $ARCH" --extra-ldflags="-arch $ARCH" $(host_flag)
  make -j"$JOBS"
  make install
)

log "lame"
(
  cd "$SRC/lame"
  CC="$ARCHCC" ./configure --prefix="$PREFIX" --disable-shared --enable-static \
    --disable-frontend --disable-dependency-tracking $(host_flag)
  make -j"$JOBS"
  make install
)

log "opus"
(
  cd "$SRC/opus"
  CC="$ARCHCC" ./configure --prefix="$PREFIX" --disable-shared --enable-static \
    --disable-doc --disable-extra-programs --disable-dependency-tracking $(host_flag)
  make -j"$JOBS"
  make install
)

log "libvpx"
(
  cd "$SRC/libvpx"
  as_flag=()
  if [ "$ARCH" = x86_64 ]; then as_flag=(--as=nasm); fi
  CC=clang CXX=clang++ ./configure --prefix="$PREFIX" --target="$VPX_TARGET" \
    --disable-shared --enable-static --enable-pic --disable-examples --disable-tools \
    --disable-docs --disable-unit-tests ${as_flag[@]+"${as_flag[@]}"}
  make -j"$JOBS"
  make install
)

log "dav1d"
(
  cd "$SRC/dav1d"
  cross=()
  if [ "$CROSS" = 1 ]; then
    cat >cross.ini <<EOF
[binaries]
c = ['clang', '-arch', '$ARCH']
ar = 'ar'
strip = 'strip'
nasm = 'nasm'

[host_machine]
system = 'darwin'
cpu_family = '$ARCH'
cpu = '$ARCH'
endian = 'little'
EOF
    cross=(--cross-file cross.ini)
  fi
  meson setup build --prefix="$PREFIX" --libdir=lib --buildtype=release \
    --default-library=static -Denable_tools=false -Denable_tests=false ${cross[@]+"${cross[@]}"}
  ninja -C build
  ninja -C build install
)

log "ffmpeg $FFMPEG_VERSION"
(
  cd "$SRC/ffmpeg"
  cross=()
  if [ "$CROSS" = 1 ]; then cross=(--enable-cross-compile --target-os=darwin); fi
  ./configure --prefix="$PREFIX" --arch="$FF_ARCH" --cc="$ARCHCC" --cxx="clang++ -arch $ARCH" \
    ${cross[@]+"${cross[@]}"} --x86asmexe=nasm \
    --pkg-config=pkg-config --pkg-config-flags=--static \
    --extra-cflags="-I$PREFIX/include" --extra-ldflags="-L$PREFIX/lib" \
    --enable-gpl --enable-static --disable-shared --disable-autodetect \
    --enable-zlib --enable-securetransport \
    --enable-libx264 --enable-libvpx --enable-libopus --enable-libmp3lame --enable-libdav1d \
    --disable-ffplay --disable-doc --disable-debug
  make -j"$JOBS"
)

log "package"
STAGE=$WORK/stage
mkdir -p "$STAGE"
for exe in ffmpeg ffprobe; do
  cp "$SRC/ffmpeg/$exe" "$STAGE/$exe"
  strip "$STAGE/$exe"
  # Apple silicon refuses unsigned code; an ad-hoc signature is enough.
  codesign --force -s - "$STAGE/$exe"
done
ZIP=$DIST/ffmpeg-$TRIPLE.zip
rm -f "$ZIP"
(cd "$STAGE" && zip -9 -q "$ZIP" ffmpeg ffprobe)

cat >"$DIST/ffmpeg-LICENSE-and-SOURCE.txt" <<EOF
ffmpeg and ffprobe in this release are built from the sources below and are
distributed under the GNU General Public License version 2 or later, because
they include libx264. The build script is build.sh in
https://github.com/danted4/ffmpeg-macos at the commit this release was made from.

FFmpeg  $FFMPEG_TAG  https://github.com/FFmpeg/FFmpeg  commit $FFMPEG_COMMIT
x264    $X264_BRANCH  https://code.videolan.org/videolan/x264  commit $X264_COMMIT
libvpx  $LIBVPX_TAG  https://github.com/webmproject/libvpx  commit $LIBVPX_COMMIT
dav1d   $DAV1D_TAG  https://code.videolan.org/videolan/dav1d  commit $DAV1D_COMMIT
opus    $OPUS_VERSION  https://downloads.xiph.org/releases/opus/opus-$OPUS_VERSION.tar.gz  sha256 $OPUS_SHA256
lame    $LAME_VERSION  https://downloads.sourceforge.net/project/lame/lame/$LAME_VERSION/lame-$LAME_VERSION.tar.gz  sha256 $LAME_SHA256

FFmpeg's licence: https://ffmpeg.org/legal.html
GPL version 2: https://www.gnu.org/licenses/old-licenses/gpl-2.0.html
EOF

ls -la "$ZIP"
