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
