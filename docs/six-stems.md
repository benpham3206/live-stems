# Optional six stems

Select Six stems (experimental) in the model menu. The worker must load
htdemucs_6s before Guitar and Piano controls appear. Automatic retains its
four-stem model selection. The six-stem model files must exist in the model
cache; `install.sh --six-stems` opts into upstream source conversion (requires PyTorch and Demucs). The public models-v1 release API returned HTTP 404 during validation; no six-source asset URL is assumed. `script/package_release.py --six-stems` includes the cached configuration and weights after SHA-256 validation. The default package retains two four-source models.

The canonical order is vocals, drums, bass, other, guitar, piano. Swift
validates the ready message and each response count and exact payload size.
The output frame contains stereo stems, stereo Original, and blend weight.
The native counted APIs receive the loaded source count. Model changes clear
processor caches before interpreting a new stride. Four-stem controls mask
inactive mute and solo bits. Cmd+1–4 retain their cycles; Cmd+5 opens spectrum.

Six-stem separation is experimental. Piano separation can be weaker.
No new pitch engine is used.

## Local validation, 2026-10-28

Run `bash script/verify.sh`. The six-source stage checks production worker
packet decoding, canonical pipeline routing, takeover fading, and control
normalization. The menu stage checks Guitar/Piano volume, mute, solo,
visibility, same-model retention, and return to four stems. If the optional
six-source weights exist, verification also runs the actual model through
Swift WorkerClient. Native meters and mixed four/six frames are checked by
`sh script/test_native_counts.sh` under ASan/UBSan. Run worker ordering tests
with `../../work/stems-venv/bin/python script/test_worker_sources.py`.

The refreshed local preview is in
`../../outputs/live-stems-six-source-dmg-tagline-20261028/Live Stems.dmg`.
It includes all three models and uses “Hear every layer.” Signing uses Apple
Development for local preview, not public distribution. The package audit
checks embedded minimum targets against macOS 14.2; it cannot prove runtime
compatibility on that system.

Live capture, audible separation quality, source-switch recovery on real
players, macOS 14.2 runtime behavior, and upstream model conversion remain
separate acceptance checks. Offline fixture checks do not establish them.
