# ffmpeg-macos

Static ffmpeg and ffprobe builds for macOS (Apple silicon and Intel), made for [ytd](https://github.com/danted4/ytd). ytd installs them on a Mac that has no ffmpeg yet.

Each release carries:

- `ffmpeg-aarch64-apple-darwin.zip` and `ffmpeg-x86_64-apple-darwin.zip`, each holding `ffmpeg` and `ffprobe`;
- `SHA256SUMS`, which ytd checks before installing;
- `ffmpeg-LICENSE-and-SOURCE.txt`, naming the exact source versions.

## Licence

The build scripts in this repository are under the ISC licence ([LICENSE](LICENSE)).

The ffmpeg and ffprobe binaries are built with libx264, so they are distributed under the **GNU GPL version 2 or later**. The sources are the upstream releases pinned (with SHA-256) in `versions.env`, and `build.sh` is the complete build script.
