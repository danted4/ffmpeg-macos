#!/usr/bin/env bash
# Rewrite versions.env with the newest upstream releases.
# Prints "changed" when anything moved, "unchanged" otherwise.
#
# FFmpeg follows its newest release (tags nX.Y or nX.Y.Z). Libraries follow
# their newest release tags; x264 follows its stable branch. lame is left
# alone (3.100 has been its last release since 2017).
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
FILE=$HERE/versions.env
# shellcheck source=../versions.env
source "$FILE"

latest_tag() { # url regex
  git ls-remote --tags "$1" | awk '{print $2}' | grep -v '\^{}$' | sed 's#refs/tags/##' \
    | grep -E "$2" | sort -V | tail -1
}
commit_of() { # url ref
  local c
  c=$(git ls-remote "$1" "refs/tags/$2^{}" | awk '{print $1}')
  [ -n "$c" ] || c=$(git ls-remote "$1" "refs/tags/$2" "refs/heads/$2" | awk '{print $1}' | head -1)
  [ -n "$c" ] || { echo "no commit for $1 $2" >&2; exit 1; }
  echo "$c"
}
tar_sha() { curl -fsSL --retry 3 "$1" | shasum -a 256 | awk '{print $1}'; }

FF_URL=https://github.com/FFmpeg/FFmpeg.git
new_ff_tag=$(latest_tag "$FF_URL" '^n[0-9]+\.[0-9]+(\.[0-9]+)?$')
new_ff_commit=$(commit_of "$FF_URL" "$new_ff_tag")
new_ff_version=${new_ff_tag#n}

new_x264_commit=$(commit_of https://code.videolan.org/videolan/x264.git "$X264_BRANCH")

VPX_URL=https://github.com/webmproject/libvpx.git
new_vpx_tag=$(latest_tag "$VPX_URL" '^v[0-9]+\.[0-9]+\.[0-9]+$')
new_vpx_commit=$(commit_of "$VPX_URL" "$new_vpx_tag")

DAV1D_URL=https://code.videolan.org/videolan/dav1d.git
new_dav1d_tag=$(latest_tag "$DAV1D_URL" '^[0-9]+\.[0-9]+\.[0-9]+$')
new_dav1d_commit=$(commit_of "$DAV1D_URL" "$new_dav1d_tag")

new_opus_tag=$(latest_tag https://github.com/xiph/opus.git '^v[0-9]+\.[0-9]+(\.[0-9]+)?$')
new_opus_version=${new_opus_tag#v}
new_opus_sha=$OPUS_SHA256
if [ "$new_opus_version" != "$OPUS_VERSION" ]; then
  new_opus_sha=$(tar_sha "https://downloads.xiph.org/releases/opus/opus-$new_opus_version.tar.gz")
fi

if [ "$new_ff_version" != "$FFMPEG_VERSION" ]; then
  new_build=1
elif [ "$new_ff_commit$new_x264_commit$new_vpx_commit$new_dav1d_commit$new_opus_sha" != \
       "$FFMPEG_COMMIT$X264_COMMIT$LIBVPX_COMMIT$DAV1D_COMMIT$OPUS_SHA256" ]; then
  new_build=$((BUILD + 1))
else
  echo unchanged
  exit 0
fi

set_var() { # name value
  sed -i.bak -E "s|^$1=.*|$1=$2|" "$FILE" && rm -f "$FILE.bak"
}
set_var FFMPEG_VERSION "$new_ff_version"
set_var FFMPEG_TAG "$new_ff_tag"
set_var FFMPEG_COMMIT "$new_ff_commit"
set_var X264_COMMIT "$new_x264_commit"
set_var LIBVPX_TAG "$new_vpx_tag"
set_var LIBVPX_COMMIT "$new_vpx_commit"
set_var DAV1D_TAG "$new_dav1d_tag"
set_var DAV1D_COMMIT "$new_dav1d_commit"
set_var OPUS_VERSION "$new_opus_version"
set_var OPUS_SHA256 "$new_opus_sha"
set_var BUILD "$new_build"
echo changed
