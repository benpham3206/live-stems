# Live Stems

**Split whatever Spotify is playing into vocals, drums, bass and everything else, live, on your Mac.**
Mute the vocals for karaoke, solo the bass to learn a line, or turn the drums down, on any song,
while it plays. No downloads, no prepared tracks: the separation happens as the music plays.

Live Stems sits in your menu bar. Its panel has one row per stem, like a Logic Pro track header:

- a **volume slider**,
- **M** (mute, blue) and **S** (solo, yellow) buttons,
- a small **waveform** that shows what that stem is doing right now.

The **All stems** row has an **M** that mutes everything and an **S** that lights up while anything
is soloed; click it to clear every solo at once, like Logic. **Reset** puts every control back to normal and restarts the stem splitter if it stopped.

It uses [Demucs](https://github.com/facebookresearch/demucs), Meta's music separation model, running
on your Mac's GPU through [demucs-mlx](https://github.com/ssmall256/demucs-mlx). Nothing is uploaded.
Audio never leaves your Mac and is never saved to disk.

## What you need

- A Mac with **Apple Silicon** running **macOS 26 or newer**. Built and tested on an **M3 Max**. The model
  must finish each job in under 0.1 s; on slower chips, stems may drop out to the plain song more often.
- The **Spotify** desktop app.
- **Python 3.12** (for example `brew install python@3.12`).
- Apple's **Command Line Tools**, to build the app (`xcode-select --install` if you don't have them).
- About **2 GB of disk space** for the model and its Python packages (the model download is about 1 GB), and **1–2 GB of memory** while it runs.

## Install

Live Stems is built on your Mac from this source. Most of the time goes to downloads.
All commands go in **Terminal** (press ⌘-Space and type "Terminal").

### 1. Get the code

The app expects this folder layout, so clone it exactly like this:

```sh
mkdir -p ~/LiveStems/outputs ~/LiveStems/work
git clone https://github.com/benpham3206/live-stems.git ~/LiveStems/outputs/live-stems-source
cd ~/LiveStems
```

Every command below runs from `~/LiveStems`.

### 2. Set up Python and the model

```sh
python3.12 -m venv work/stems-venv
work/stems-venv/bin/pip install "demucs-mlx[convert]==1.5.3"
work/stems-venv/bin/python -m demucs_mlx.mlx_convert htdemucs_ft --output-dir work/model-cache
```

The last command downloads Meta's `htdemucs_ft` model (four fine-tuned models, one per stem) and
converts it for your GPU.

### 3. Make a signing certificate (one time)

macOS asks for permission to capture Spotify's audio. It only remembers your answer if every build
of the app has the same signature, so the app is signed with a certificate of your own:

1. Open **Keychain Access** and choose **Keychain Access > Certificate Assistant > Create a Certificate…**
2. Name it `Live Stems Local`, set **Certificate Type** to **Code Signing**, and click **Create**.
3. Save its ID for the build script:

```sh
security find-identity -p codesigning | grep -m1 "Live Stems Local" | awk '{print $2}' > work/live-stems-signing-identity.txt
```

The file must hold one 40-character ID. If the build later says *"A stable signing certificate is
required"*, check this file. If you already have an **Apple Development** certificate from Xcode, you
can use its ID instead (`security find-identity -p codesigning` lists them).

### 4. Build and open it

```sh
bash outputs/live-stems-source/script/build_and_run.sh
```

This builds the app, signs it, puts it in `/Applications/Live Stems.app` and opens it. When macOS asks
whether `codesign` may use your certificate, enter your Mac password and click **Always Allow**.
Run the same command again to update after `git pull`. The previous version is kept in `work/`.

## First launch

1. Play something in Spotify.
2. Click **Stems** in the menu bar to show the panel, then click **Enable live stems**.
3. macOS asks two questions. Allow both:
   - **Record system audio**, so Live Stems can hear Spotify.
   - **Control Spotify**, so it can read what is playing and notice skips and pauses.

The first second plays the normal song while the model gets ready. After that, every control works.

## Using it

- **Move a slider, press M or S:** the stems fade in within a second.
- **Waveforms** show each stem's level before its slider. A muted stem still shows its waveform, dimmed.
  They are flat while the model sleeps.
- **The model sleeps when it isn't needed**, so your GPU and battery rest:
  - all four stems at the same volume (untouched, all muted, or all at the same level),
  - Spotify paused.

  The status line tells you which: *Live stems*, *Original · model asleep*, *All stems muted · model asleep*.
- **Reset** returns every control to normal and brings the stem splitter back, for example after you
  reopen the app during a Quit. With nothing changed, the model then sleeps.
- **Skip, seek and pause** in Spotify as usual. Live Stems follows along and rebuilds the stems for the new spot.
- **Quit Live Stems** resets the mix and fades back to the plain song. If you reopen it, it starts
  from the original song with the model asleep. The app waits until Spotify pauses before it lets go,
  so your music never cuts out.

Everything you hear is about a third of a second behind Spotify. The delay never changes, so you
won't notice it unless you watch Spotify's lyrics or progress bar.

## How it works

Spotify's audio is tapped before it reaches your speakers and held for 260 ms. Ten times a second,
the newest second of audio goes to the model, which returns four stems. The app keeps only the newest
tenth of a second of each answer and blends the answers together. Your sliders then remix the stems as
they play. If an answer is ever late, that moment plays the parts of your mix that don't need stems
instead of glitching. The song never rewinds or drifts.

The details, numbers and test plan are in [docs/internals.md](docs/internals.md).

## Something wrong?

| Problem | Try this |
|---|---|
| Build says *"A stable signing certificate is required"* | Redo [step 3](#3-make-a-signing-certificate-one-time). The ID file must hold one 40-character ID. |
| Build says *"The local Python environment is missing"* | Redo [step 2](#2-set-up-python-and-the-model). The folder layout from step 1 must match exactly. |
| macOS asks for audio permission after every update | The app's signature changed. Check that `work/live-stems-signing-identity.txt` still names your certificate. |
| Status says *"Spotify capture silent · live Spotify restored"* | Spotify was silent for 10 seconds after you enabled stems. Play something, then enable again. |
| Status says *"Output changed · live Spotify restored"* | You switched speakers or headphones. Click **Enable live stems** again. |
| Stems drop out for a moment now and then | The GPU is busy with something else (games, video, editing apps). Live Stems plays the plain song for that moment rather than glitching. |
| The screen flickers and Live Stems stops | macOS restarted the GPU. Save the files named `gpuEvent-*` in `/Library/Logs/DiagnosticReports` and open an issue. |

Live Stems keeps small timing logs, never audio or song titles, in
`~/Library/Application Support/Live Stems/`. Each log is capped at 2 MB.

## Uninstall

1. Choose **Quit Live Stems** in the panel.
2. Move `/Applications/Live Stems.app`, `~/Library/Application Support/Live Stems` and `~/LiveStems` to the Trash.
3. Optional: delete the `Live Stems Local` certificate in **Keychain Access**, and remove Live Stems under
   **System Settings > Privacy & Security** (Screen & System Audio Recording, and Automation).

## Credits and disclaimer

Live Stems is an unofficial personal project by Ben Pham. It isn't affiliated with, endorsed by, or
sponsored by Spotify or Meta. Spotify is a trademark of Spotify AB.

Separation uses [Demucs](https://github.com/facebookresearch/demucs) by Meta AI Research and its
MLX port [demucs-mlx](https://github.com/ssmall256/demucs-mlx). The model weights are downloaded from
their official source during install. They are not part of this repository.

Live Stems captures Spotify through a macOS audio tap and reads Spotify's state with Apple Events. A
Spotify or macOS update could break it. It is meant for personal listening and practice: don't use
it to copy or share music.
