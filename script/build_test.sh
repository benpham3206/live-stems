#!/bin/bash
# Build a separate test app. Never quit, replace, or open the installed app.
set -euo pipefail
stem_package="$(cd "$(dirname "$0")/.." && pwd -P)"
stem_workspace="$(cd "$stem_package/../.." && pwd -P)"
stem_output="${1:-$stem_workspace/outputs/live-stems-pitch-seek-test}"
stem_identity="${LIVE_STEMS_SIGNING_IDENTITY:-}"
if [[ -z "$stem_identity" && -f "$stem_workspace/work/live-stems-signing-identity.txt" ]]; then
  read -r stem_identity < "$stem_workspace/work/live-stems-signing-identity.txt"
fi
if [[ ! "$stem_identity" =~ ^[[:xdigit:]]{40}$ ]]; then
  echo 'A stable signing identity is required. See README.md: Make a signing certificate.' >&2
  exit 1
fi
if [[ -e "$stem_output" ]]; then
  echo 'The output folder already exists. Choose a fresh folder to preserve that build.' >&2
  exit 1
fi
if [[ ! -x "$stem_workspace/work/stems-venv/bin/python" ]]; then
  echo 'The existing Live Stems Python environment is missing. See README.md: Install by hand.' >&2
  exit 1
fi
swift build -c release --package-path "$stem_package"
stem_bin="$(swift build -c release --package-path "$stem_package" --show-bin-path)/LiveStems"
stem_app="$stem_output/Live Stems Test.app"
mkdir -p "$stem_app/Contents/MacOS" "$stem_app/Contents/Resources"
cp "$stem_package/Resources/LiveStems.icns" "$stem_app/Contents/Resources/"
vtool -set-build-version macos 14.2 "$(xcrun --show-sdk-version)" -replace \
  -output "$stem_app/Contents/MacOS/LiveStems" "$stem_bin"
python3 - "$stem_package" "$stem_workspace" "$stem_app" <<'PY'
import json
import plistlib
import sys
from pathlib import Path
source, root, app = map(Path, sys.argv[1:])
info = plistlib.loads((source / 'Resources/Info.plist').read_bytes())
info.update(CFBundleIdentifier='com.benpham.livestems.test', CFBundleName='Live Stems Test',
            CFBundleDisplayName='Live Stems Test', CFBundleVersion='2')
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
(app / 'Contents/Resources/local.json').write_text(json.dumps({'root': str(root), 'source': str(source)}) + '\n')
PY
codesign --sign "$stem_identity" --identifier com.benpham.livestems.test "$stem_app"
codesign --verify --strict "$stem_app"
swiftc "$stem_package/script/switch_build.swift" -o "$stem_output/switch-build"
cat > "$stem_output/Launch Test.command" <<'SH'
#!/bin/zsh
set -e
stem_folder=${0:A:h}
"$stem_folder/switch-build" "$stem_folder/Live Stems Test.app"
SH
cat > "$stem_output/Return to Installed.command" <<'SH'
#!/bin/zsh
set -e
stem_folder=${0:A:h}
"$stem_folder/switch-build" '/Applications/Live Stems.app'
SH
chmod +x "$stem_output/Launch Test.command" "$stem_output/Return to Installed.command"
echo "Test build ready: $stem_output"
echo 'No app was stopped or launched. Use Launch Test.command when ready.'
