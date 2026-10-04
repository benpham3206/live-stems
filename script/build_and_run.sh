#!/bin/bash
set -euo pipefail

stem_package="$(cd "$(dirname "$0")/.." && pwd -P)"
stem_workspace="$(cd "$stem_package/../.." && pwd -P)"
stem_identifier='com.benpham.livestems'
stem_executable='LiveStems'
stem_pidfile="$HOME/Library/Application Support/Live Stems/app.pid"
stem_identityfile="$stem_workspace/work/live-stems-signing-identity.txt"
stem_python="$stem_workspace/work/stems-venv/bin/python"
stem_icon="$stem_package/Resources/LiveStems.icns"
stem_identity="${LIVE_STEMS_SIGNING_IDENTITY:-}"

if [[ -z "$stem_identity" && -f "$stem_identityfile" ]]; then
  read -r stem_identity < "$stem_identityfile"
fi
if [[ ! "$stem_identity" =~ ^[[:xdigit:]]{40}$ ]]; then
  echo 'A stable signing certificate is required. See README.md: One-time signing setup.' >&2
  echo 'The installed app was not stopped or replaced.' >&2
  exit 3
fi
if [[ ! -x "$stem_python" ]]; then
  echo "The local Python environment is missing: $stem_python" >&2
  echo 'The installed app was not stopped or replaced.' >&2
  exit 3
fi
if [[ ! -s "$stem_icon" ]]; then
  echo "The staged icon is missing or empty: $stem_icon" >&2
  echo 'The installed app was not stopped or replaced.' >&2
  exit 4
fi

"$stem_python" - "$stem_icon" <<'PY'
import struct
import sys
from pathlib import Path

raw = Path(sys.argv[1]).read_bytes()
if len(raw) < 8 or raw[:4] != b"icns":
    raise SystemExit("LiveStems.icns has no icns header")
declared = struct.unpack(">I", raw[4:8])[0]
if declared != len(raw):
    raise SystemExit("LiveStems.icns length does not match its header")
PY

stem_bundle_matches_workspace() {
  local candidate="$1"
  local info="$candidate/Contents/Info.plist"
  local settings="$candidate/Contents/Resources/local.json"
  local bundle_id executable

  [[ -d "$candidate" && ! -L "$candidate" ]] || return 1
  [[ -f "$info" && -f "$settings" ]] || return 1
  bundle_id="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$info" 2>/dev/null)" || return 1
  executable="$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$info" 2>/dev/null)" || return 1
  local package_type
  package_type="$(/usr/bin/plutil -extract CFBundlePackageType raw -o - "$info" 2>/dev/null)" || return 1
  [[ "$bundle_id" == "$stem_identifier" && "$executable" == "$stem_executable" && "$package_type" == 'APPL' ]] || return 1
  "$stem_python" - "$settings" "$stem_workspace" <<'PY'
import json
import os
import sys
from pathlib import Path

try:
    settings = json.loads(Path(sys.argv[1]).read_text())
    root = settings.get("root")
    expected = sys.argv[2]
    if not isinstance(root, str) or not root:
        raise ValueError("local.json root is missing")
    if os.path.realpath(root) != os.path.realpath(expected):
        raise ValueError("local.json root does not match this workspace")
except (OSError, ValueError, json.JSONDecodeError, TypeError):
    raise SystemExit(1)
PY
}

# Prefer the existing correctly identified installed bundle. The workspace
# path is retained only as a legacy fallback for an older local installation.
stem_app=''
stem_invalid_candidate=''
for candidate in \
  "/Applications/Live Stems.app" \
  "$HOME/Applications/Live Stems.app" \
  "$stem_workspace/outputs/Live Stems.app"; do
  if [[ -e "$candidate" || -L "$candidate" ]]; then
    if stem_bundle_matches_workspace "$candidate"; then
      stem_app="$candidate"
      break
    fi
    if [[ -z "$stem_invalid_candidate" ]]; then
      stem_invalid_candidate="$candidate"
    fi
  fi
done

if [[ -z "$stem_app" ]]; then
  if [[ -n "$stem_invalid_candidate" ]]; then
    echo "An existing Live Stems bundle failed identity or workspace checks: $stem_invalid_candidate" >&2
    echo 'The installed app was not stopped or replaced.' >&2
    exit 6
  fi
  if [[ -d /Applications && -w /Applications ]]; then
    stem_app='/Applications/Live Stems.app'
  elif [[ -d "$HOME/Applications" && -w "$HOME/Applications" ]]; then
    stem_app="$HOME/Applications/Live Stems.app"
  elif [[ -w "$HOME" ]]; then
    stem_app="$HOME/Applications/Live Stems.app"
  else
    echo 'No writable Applications directory is available. Do not use sudo; grant the user write access or choose a writable user Applications directory.' >&2
    echo 'The installed app was not stopped or replaced.' >&2
    exit 6
  fi
fi

stem_app_parent="$(dirname "$stem_app")"
if [[ -d "$stem_app_parent" && ! -w "$stem_app_parent" ]]; then
  echo "The selected app directory is not writable: $stem_app_parent" >&2
  echo 'Do not use sudo. Grant the current user write access, then retry.' >&2
  echo 'The installed app was not stopped or replaced.' >&2
  exit 6
fi

swift build --configuration release --package-path "$stem_package" --scratch-path "$stem_workspace/work/live-stems-build"
stem_bin="$(swift build --configuration release --package-path "$stem_package" --scratch-path "$stem_workspace/work/live-stems-build" --show-bin-path)"
stem_stage="$(mktemp -d "$stem_workspace/work/live-stems-package.XXXXXX")"
stem_staged_app="$stem_stage/Live Stems.app"
mkdir -p "$stem_staged_app/Contents/MacOS" "$stem_staged_app/Contents/Resources"
cp "$stem_bin/LiveStems" "$stem_staged_app/Contents/MacOS/LiveStems"
cp "$stem_package/Resources/Info.plist" "$stem_staged_app/Contents/Info.plist"
cp "$stem_icon" "$stem_staged_app/Contents/Resources/LiveStems.icns"
"$stem_python" - "$stem_staged_app/Contents/Resources/local.json" "$stem_workspace" <<'PY'
import json
import sys
from pathlib import Path

Path(sys.argv[1]).write_text(json.dumps({"root": sys.argv[2]}) + "\n")
PY

codesign --sign "$stem_identity" --identifier "$stem_identifier" "$stem_staged_app"
codesign --verify --strict "$stem_staged_app"
codesign -d -r- "$stem_staged_app" > "$stem_stage/designated-requirement.txt" 2>&1
if ! /usr/bin/grep -q 'identifier "com.benpham.livestems"' "$stem_stage/designated-requirement.txt" || /usr/bin/grep -q 'cdhash' "$stem_stage/designated-requirement.txt"; then
  echo 'The signature has no stable app identity. The installed app was not stopped or replaced.' >&2
  exit 4
fi

echo "Selected install target: $stem_app"
if [[ -f "$stem_pidfile" ]]; then
  stem_pid="$(tr -d '[:space:]' < "$stem_pidfile")"
  if [[ ! "$stem_pid" =~ ^[0-9]+$ ]]; then
    echo "The Live Stems pid file is malformed: $stem_pidfile" >&2
    echo 'The installed app was not stopped or replaced.' >&2
    exit 5
  fi
  stem_process="$(ps -p "$stem_pid" -o comm= || true)"
  if [[ -n "$stem_process" ]]; then
    stem_owned_executable="$stem_app/Contents/MacOS/$stem_executable"
    if [[ "$stem_process" != "$stem_owned_executable" ]]; then
      echo "PID $stem_pid is not the selected Live Stems executable: $stem_process" >&2
      echo 'The installed app was not stopped or replaced.' >&2
      exit 5
    fi
    if ! kill -TERM "$stem_pid"; then
      echo "Could not stop the selected Live Stems process: $stem_pid" >&2
      echo 'The installed app was not stopped or replaced.' >&2
      exit 5
    fi
    for stem_attempt in {1..30}; do
      if ! kill -0 "$stem_pid" 2>/dev/null; then
        break
      fi
      sleep 0.1
    done
    if kill -0 "$stem_pid" 2>/dev/null; then
      echo 'Close Live Stems before replacing it. The staged bundle is ready.' >&2
      exit 5
    fi
  fi
fi

if [[ -d "$stem_app" ]]; then
  if ! stem_bundle_matches_workspace "$stem_app"; then
    echo "The selected bundle changed before replacement: $stem_app" >&2
    echo 'The staged bundle is ready and the installed app was not replaced.' >&2
    exit 6
  fi
  mv "$stem_app" "$stem_stage/Previous.app"
fi
if [[ ! -d "$stem_app_parent" ]]; then
  mkdir -p "$stem_app_parent"
fi
mv "$stem_staged_app" "$stem_app"
mkdir -p "$stem_workspace/outputs/live-stems-acceptance"
cp "$stem_stage/designated-requirement.txt" "$stem_workspace/outputs/live-stems-acceptance/designated-requirement.txt"

case "${1:-run}" in
  --build-only) ;;
  --debug) lldb -- "$stem_app/Contents/MacOS/LiveStems" ;;
  --logs|--telemetry) /usr/bin/open -g "$stem_app"; /usr/bin/log stream --info --predicate 'process == "LiveStems"' ;;
  --verify) /usr/bin/open -g "$stem_app"; /usr/bin/pgrep -x LiveStems ;;
  run) /usr/bin/open -g "$stem_app" ;;
  *) exit 2 ;;
esac
