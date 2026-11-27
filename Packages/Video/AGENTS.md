# Video module

Video is an internal built-in capability, not a user-installed plugin. Keep FFmpeg and all decoding dependencies here; the host must not link them. Communicate through extension-kit C ABI and JSON value contracts. Do not pass Swift, AppKit or Objective-C objects across the boundary. Shared video frames use IOSurface IDs valid only during the owning session.

Keep decode buffers bounded; do not generate full-movie conversion caches. Use system video hardware decoding where possible. Keep dependency builds pinned and reproducible and preserve third-party licenses and source/relink instructions.

Run `./scripts/build-ffmpeg` and `swift test`. `video-inspect` validates real samples without audible playback. Build products belong in ignored directories. Do not commit users' movie files, local paths or generated bundles. Document any codec, subtitle or output limitations in both README languages.
