# Video

An independently versioned built-in video capability for foofoil. The host controls inclusion at build time; users do not install or enable it.

Run `./scripts/build-ffmpeg`, `swift test`, then `./build-plugin /tmp/video-bundles - release`.
The host's `./run` and `./package-dmg` accept `--with-video` (default) and `--without-video`.

Supports local MKV/AVI with H.264, HEVC, MPEG-4 ASP/Xvid; AAC, AC3, EAC3, DTS/DTS-HD MA, TrueHD and MP3.
Audio uses system-default output, mixed to stereo PCM at 48 kHz. No compressed audio passthrough or Atmos object output.
Embedded SRT/ASS use plain text styling; PGS uses bitmap subtitles. ASS styling/animation, font attachments and external subtitles are not implemented.
Uses bounded buffering without a full-file conversion cache. C ABI and JSON cross the module boundary; IOSurface IDs carry frames.

`video-inspect <files...>` checks first-frame decoding, seeking, track selection, muted playback and pause timing.

Module source is MIT; FFmpeg is LGPL-2.1-or-later. See ThirdParty/NOTICE.md and the bundled license.
