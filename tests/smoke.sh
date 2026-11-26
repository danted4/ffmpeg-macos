#!/usr/bin/env bash
# Smoke-test a built zip: the features ytd relies on, and every path a ytd
# download can take (merge to mp4, mp3, webm, trim re-encode, AV1 decode).
#
#   tests/smoke.sh dist/ffmpeg-aarch64-apple-darwin.zip [runner]
#
# runner is an optional prefix such as "arch -x86_64" (Rosetta).
set -euo pipefail

ZIP=${1:?usage: smoke.sh <zip> [runner]}
RUNNER=${2:-}
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

unzip -q "$ZIP" -d "$T/bin"
FF="$RUNNER $T/bin/ffmpeg -hide_banner -loglevel error"
FP="$RUNNER $T/bin/ffprobe -v error"
ok() { printf 'ok   %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }

# Capture first: `| head -1` can end with SIGPIPE (141) under pipefail.
version=$($RUNNER "$T/bin/ffmpeg" -hide_banner -version)
echo "${version%%$'\n'*}"
version=$($RUNNER "$T/bin/ffprobe" -hide_banner -version)
echo "${version%%$'\n'*}"
# yt-dlp parses this: it must be a release number, not a bare git hash.
grep -qE '^ffprobe version n?[0-9]+\.[0-9]+' <<<"$version" || fail "version is not a release number"
ok "version: ${version%% Copyright*}"

for exe in ffmpeg ffprobe; do
  if otool -L "$T/bin/$exe" | tail -n +2 | grep -vE '^\s+(/usr/lib/|/System/Library/)'; then
    fail "$exe links a library outside the system"
  fi
  codesign --verify "$T/bin/$exe" || fail "$exe signature"
done
ok "only system libraries, signed"

encoders=$($RUNNER "$T/bin/ffmpeg" -hide_banner -encoders)
for enc in libx264 libmp3lame libvpx-vp9 libopus aac; do
  grep -qE "^ [A-Z.]{6} $enc " <<<"$encoders" || fail "encoder $enc"
done
ok "encoders: libx264 libmp3lame libvpx-vp9 libopus aac"

grep -qE "^ [A-Z.]{6} libdav1d " <<<"$($RUNNER "$T/bin/ffmpeg" -hide_banner -decoders)" || fail "decoder libdav1d"
ok "decoder: libdav1d"

grep -qx '  https' <<<"$($RUNNER "$T/bin/ffmpeg" -hide_banner -protocols)" || fail "protocol https"
ok "protocol: https"

# merged mp4 (what yt-dlp's merge + --force-keyframes-at-cuts produce)
$FF -f lavfi -i testsrc2=size=320x180:rate=25:duration=2 -f lavfi -i sine=frequency=440:duration=2 \
  -c:v libx264 -c:a aac -shortest "$T/merged.mp4"
[ "$($FP -select_streams v -show_entries stream=codec_name -of csv=p=0 "$T/merged.mp4")" = h264 ] || fail "mp4 video"
ok "mp4: h264 + aac"

# mp3 (ytd's AUDIO kind)
$FF -f lavfi -i sine=frequency=440:duration=2 -c:a libmp3lame -q:a 0 "$T/audio.mp3"
[ "$($FP -show_entries stream=codec_name -of csv=p=0 "$T/audio.mp3")" = mp3 ] || fail "mp3"
ok "mp3: libmp3lame"

# webm (VIDEO/FILE kinds keep the source container; a trim re-encodes)
$FF -f lavfi -i testsrc2=size=320x180:rate=25:duration=2 -f lavfi -i sine=frequency=440:duration=2 \
  -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -c:a libopus -shortest "$T/clip.webm"
[ "$($FP -select_streams a -show_entries stream=codec_name -of csv=p=0 "$T/clip.webm")" = opus ] || fail "webm audio"
ok "webm: vp9 + opus"

# trim of an AV1 source into mp4 (needs the libdav1d decoder)
$FF -ss 0.2 -i "$HERE/av1-sample.mp4" -t 0.5 -c:v libx264 "$T/av1-trim.mp4"
[ "$($FP -select_streams v -show_entries stream=codec_name -of csv=p=0 "$T/av1-trim.mp4")" = h264 ] || fail "av1 trim"
ok "av1 -> h264 trim"

echo "smoke test passed: $ZIP"
