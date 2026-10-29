#!/bin/bash
# Checks the model file packing, builds the app and runs offline/native checks without signing or private audio capture. AppKit checks show windows and spectrum checks can use Metal.
# Exit 0 means the build and every stage passed. Live stages are in docs/internals.md.
set -euo pipefail

package="$(cd "$(dirname "$0")/.." && pwd -P)"
out="$(mktemp -d)"
"$package/../../work/stems-venv/bin/python" -I "$package/script/test_models.py"
swift build -c release --package-path "$package"
# SwiftPM records the deployment target (14.2) as the SDK, so AppKit draws the pre-macOS 26 controls.
# Record the real SDK, as the installed app does.
vtool -set-build-version macos 14.2 "$(xcrun --show-sdk-version)" -replace -output "$package/.build/release/LiveStems" "$package/.build/release/LiveStems"
for stage in transitions flutter rest menu fader-redraw spectrum follow skip-state seek pitch six-source; do
  "$package/.build/release/LiveStems" --e2e "$stage" --output "$out/$stage"
done
if [ -f "$package/../../work/model-cache/htdemucs_6s.safetensors" ]; then
  "$package/.build/release/LiveStems" --e2e six-worker --output "$out/six-worker"
fi
echo "verify: ok ($out)"
