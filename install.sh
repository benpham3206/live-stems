#!/bin/zsh
# Installs Live Stems, or updates it. Run it again any time; finished steps are skipped.
#
#   One-liner:        curl -fsSL https://raw.githubusercontent.com/benpham3206/live-stems/main/install.sh | zsh
#   From a checkout:  zsh install.sh
#   Preview only:     zsh install.sh --dry-run   (or: ... | zsh -s -- --dry-run)
#
# Everything lives in ~/LiveStems: the source, a Python environment, the model, and the signing
# identity. The app is built on this Mac and copied to /Applications.
set -euo pipefail

REPO=https://github.com/benpham3206/live-stems.git
ROOT=$HOME/LiveStems
SOURCE=$ROOT/outputs/live-stems-source        # the app looks for its worker here
VENV=$ROOT/work/stems-venv
MODEL=$ROOT/work/model-cache
IDENTITY=$ROOT/work/live-stems-signing-identity.txt
CERT="Live Stems Local"
DRY=0
[[ ${1:-} == --dry-run ]] && DRY=1

say()  { print "==> $*"; }
fail() { print "error: $*" >&2; exit 1; }
run()  { if (( DRY )); then print "    would run: $*"; else "$@"; fi }

# 1. This Mac
[[ $(uname -m) == arm64 ]] || fail "Live Stems needs an Apple Silicon Mac."
(( ${$(sw_vers -productVersion)%%.*} >= 26 )) || fail "Live Stems needs macOS 26 or newer."
xcode-select -p >/dev/null 2>&1 || fail "Install Apple's Command Line Tools first: xcode-select --install"

# 2. Python 3.12: from PATH, from uv, or installed with Homebrew
PYTHON=$(command -v python3.12 || { command -v uv >/dev/null && uv python find 3.12 2>/dev/null; } || true)
if [[ -z $PYTHON ]]; then
  command -v brew >/dev/null || fail "Install Python 3.12 (https://www.python.org/downloads/) or Homebrew, then run this again."
  say "Installing Python 3.12 with Homebrew"
  run brew install python@3.12
  PYTHON=$(brew --prefix)/bin/python3.12
fi

# 3. The source
if [[ -d $SOURCE/.git ]]; then
  say "Updating the source in $SOURCE"
  run git -C "$SOURCE" pull --ff-only
else
  say "Downloading the source to $SOURCE"
  run mkdir -p "$ROOT/outputs" "$ROOT/work"
  run git clone "$REPO" "$SOURCE"
fi

# 4. Python packages and the model (about 1.5 GB to download, once)
if [[ ! -x $VENV/bin/python ]]; then
  say "Creating the Python environment"
  run "$PYTHON" -m venv "$VENV"
fi
if ! (( DRY )) && ! "$VENV/bin/python" -c "import demucs_mlx" 2>/dev/null; then
  say "Installing the separation library"
  run "$VENV/bin/pip" install --quiet "demucs-mlx[convert]==1.5.3"
fi
if [[ ! -f $MODEL/htdemucs_ft.safetensors ]]; then
  say "Downloading and converting the model (a few minutes)"
  run "$VENV/bin/python" -m demucs_mlx.mlx_convert htdemucs_ft --output-dir "$MODEL"
fi

# 5. A signing certificate, so macOS remembers the audio permission across updates
if ! security find-certificate -c "$CERT" >/dev/null 2>&1; then
  say "Creating the \"$CERT\" signing certificate in your login keychain"
  if ! (( DRY )); then
    tmp=$(mktemp -d)
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$CERT" \
      -keyout "$tmp/key.pem" -out "$tmp/cert.pem" \
      -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" \
      -addext "basicConstraints=critical,CA:false" 2>/dev/null
    pass=$(/usr/bin/openssl rand -hex 16)
    /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$CERT" \
      -out "$tmp/id.p12" -passout "pass:$pass"
    # -T: codesign may use the key without asking on every build.
    security import "$tmp/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$pass" -T /usr/bin/codesign >/dev/null
    /usr/bin/trash "$tmp"   # the key now lives only in the keychain
  fi
fi
if (( ! DRY )); then
  security find-certificate -c "$CERT" -Z | awk '/SHA-1/ {print $NF}' > "$IDENTITY"
  [[ $(wc -c < "$IDENTITY") -ge 40 ]] || fail "Could not read the \"$CERT\" certificate ID."
fi

# 6. Build, sign, install, open
say "Building Live Stems and installing it in /Applications"
run bash "$SOURCE/script/build_and_run.sh"
say "Done. Click Stems in the menu bar, pick an app in the source menu, and press M or S."
