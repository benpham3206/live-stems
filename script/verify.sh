#!/bin/bash
# Checks the model file packing, builds the app and runs the stages that need no GPU, signing, audio permission or private audio.
# Exit 0 means the build and every stage passed. Live stages are in docs/internals.md.
set -euo pipefail

package="$(cd "$(dirname "$0")/.." && pwd -P)"
out="$(mktemp -d)"
"$package/../../work/stems-venv/bin/python" -I "$package/script/test_models.py"
swift build -c release --package-path "$package"
for stage in transitions flutter rest menu fader-redraw spectrum; do
  "$package/.build/release/LiveStems" --e2e "$stage" --output "$out/$stage"
done
echo "verify: ok ($out)"
