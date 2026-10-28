# Pinned audio dependencies

- Rubber Band 4.0.0: https://breakfastquay.com/files/releases/rubberband-4.0.0.tar.bz2
  SHA-256: `af050313ee63bc18b35b2e064e5dce05b276aaf6d1aa2b8a82ced1fe2f8028e9`.
  GPL-2.0-or-later. See `rubberband-4.0.0/COPYING`.
- libsamplerate 0.2.2: https://github.com/libsndfile/libsamplerate/releases/download/0.2.2/libsamplerate-0.2.2.tar.xz
  SHA-256: `3258da280511d24b49d6b08615bbe824d0cacc9842b0e4caf11c52cf2b043893`.
  BSD-2-Clause. See `libsamplerate-0.2.2/COPYING`.

Source files and notices are retained from these archives. Unused build tools,
examples, tests, and documentation are omitted. The only upstream addition is
`libsamplerate-0.2.2/src/config.h`, which selects macOS little-endian arm64/x86_64
and all three sinc converters. Package.swift compiles the four resampler C
files and RubberBand.cpp uses the upstream single-unit build with Accelerate,
libsamplerate, and no worker threads. No Homebrew runtime is required.

Live processing uses the R3 finer engine, realtime mode, high-quality pitch,
stereo channels together, and shifted formants. This matches the options in
the listening-approved command-line experiment. PitchCore owns bounded output
storage, primes and trims startup as required by upstream, and performs zero
pitch as an exact bypass. The render thread owns DSP state. The control thread
publishes pitch via an atomic; explicit reset requires a paused engine.
