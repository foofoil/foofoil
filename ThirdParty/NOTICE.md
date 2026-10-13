# FFmpeg

This module statically links a reduced FFmpeg 8.0.1 build under LGPL-2.1-or-later.
No GPL or nonfree components are enabled. The license is in FFmpeg/COPYING.LGPLv2.1.

Unmodified upstream source: https://ffmpeg.org/releases/ffmpeg-8.0.1.tar.xz
SHA-256: 05ee0b03119b45c0bdb4df654b96802e909e0a752f72e4fe3794f487229e5a41

scripts/build-ffmpeg records the complete configuration and rebuilds the static libraries.
Package.swift and build-plugin rebuild the shared VideoExtensionRuntime against modified
FFmpeg libraries. All module source is provided under MIT. Users may modify and rebuild
this module and relink it with modified LGPL components, including for debugging those
modifications. A locally rebuilt bundle can be ad-hoc signed using build-plugin's '-' identity.
The distribution must retain this notice, the license, and access to the matching module
source and build scripts. There are no bundled Homebrew libraries or runtime dependencies.
