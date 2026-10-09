#!/bin/bash
# Builds the app and runs the stages that need no GPU, signing, audio permission or private audio.
# Exit 0 means the build and every stage passed. Live stages are in docs/internals.md.
set -euo pipefail

package="$(cd "$(dirname "$0")/.." && pwd -P)"
out="$(mktemp -d)"
swift build -c release --package-path "$package"
for stage in transitions flutter rest menu fader-redraw; do
  "$package/.build/release/LiveStems" --e2e "$stage" --output "$out/$stage"
done
echo "verify: ok ($out)"
