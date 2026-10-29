# Live Stems

Native macOS live audio capture, stem separation, and practice controls.

- Preserve the capture-frame clock, bounded buffers, stale-result rejection, source-audio recovery, and single-instance lock.
- Pitch changes the final mix at rate 1. Pitch alone must request output without waking stem separation.
- Seeking is Spotify-only. Validate offsets and metadata, check the expected track before writing, confirm readback, and cancel stale requests.
- Run `bash script/verify.sh`. This builds release and runs offline/native checks. Explicit E2E app settings use a temporary suite; AppKit can write its own preferences. Traces stay under `--output`.
- Live audio, permissions, output-device changes, and source transport need separate live acceptance. See [docs/internals.md](docs/internals.md).
- Use `bash script/build_test.sh` for a separate signed test bundle. It never replaces or launches the installed app. See [README.md](README.md#test-pitch-and-seek-controls).
- `AudioSession` owns capture/output; `PitchShift` owns transpose DSP; `StemPipeline` owns the frame timeline; `SessionController` orders session mutations; `SpotifyState` serializes source transport; `MenuController` wires `ControlsPanel`.
- Test and installed apps use separate settings/runtime paths but one instance lock. Never run both capture paths at once.

- Follow requires fresh finite audio activity above -80 dBFS and the selection hold. An open output stream or app focus alone never proves playback. Failed probes do not qualify; manual source selection remains available.

- `script/package_release.py` builds a self-contained drag-install DMG without installing or launching the app. Runtime wheels are hash-pinned for macOS 14; audit every embedded Mach-O before claiming 14.2 support. See [packaging](packaging/README.md).
- Packaged Python and models live in bundle Resources. Run the worker with `-I -B`; keep the model directory read-only to prevent digest stamps from changing the signed bundle.

- Six-source models use canonical vocals/drums/bass/other/guitar/piano order. Counted native APIs accept 4 or 6; external frames contain stereo stems, stereo Original, then weight. Preserve active controls across same-model attachment and clear inactive controls on model changes. See [six-stem checks](docs/six-stems.md).
