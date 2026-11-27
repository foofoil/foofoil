# Video

A built-in video capability bundled with foofoil. The host controls inclusion at build time; users do not install or enable it. The module lives at `Packages/Video` in the foofoil repository.

Run `./scripts/build-ffmpeg`, `swift test`, then `./build-plugin /tmp/video-bundles - release` from this directory.
The host's `./run` and `./package-dmg` accept `--with-video` (default) and `--without-video`.

Supports local MKV/AVI with H.264, HEVC, MPEG-4 ASP/Xvid; AAC, AC3, EAC3, DTS/DTS-HD MA, TrueHD and MP3.
Audio uses system-default output, mixed to stereo PCM at 48 kHz. No compressed audio passthrough or Atmos object output.
Embedded subtitle cues are separate from video frames. The host applies global text styles; PGS uses a separate transparent bitmap surface. ASS animation and font attachments are not implemented. The host supports external subtitle files.
Uses bounded buffering without a full-file conversion cache. C ABI and JSON cross the module boundary; IOSurface IDs carry frames.

`video-inspect <files...>` checks first-frame decoding, seeking, track selection, muted playback and pause timing.

Module source is MIT; FFmpeg is LGPL-2.1-or-later. See ThirdParty/NOTICE.md and the bundled license.

Video history thumbnails use the midpoint of the video through an independent decoder, without changing playback position. Temporary thumbnail images are removed when the session closes.
