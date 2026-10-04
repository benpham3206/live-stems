# Packaging failure criteria

These criteria are recorded before changing the installer or packaging check.

- A present `Live Stems.app` candidate with a missing or malformed
  `Contents/Info.plist` fails target selection.
- A candidate whose bundle identifier is not `com.benpham.livestems` fails
  target selection. The installer must not stop or replace it.
- A candidate whose executable is not `LiveStems` fails target selection.
- A candidate whose package type is not `APPL` fails target selection.
- A candidate whose `Contents/Resources/local.json` is missing, malformed, or
  names a root other than the current workspace fails target selection. This
  prevents an unrelated app with the same display name from being replaced.
- If more than one candidate is valid, selection follows the documented
  preference order. An invalid candidate is never silently selected as a
  fallback.
- A destination whose parent cannot be written fails before the old process is
  stopped. The installer must not use `sudo` or change system permissions.
- A staged bundle that fails strict `codesign` verification, has no stable
  designated requirement, or changes the bundle identifier fails before the
  old process is stopped.
- A staged bundle without a non-empty, structurally valid `LiveStems.icns`
  resource fails the package check. Source text alone does not pass this
  check.
- A live PID from the app pid file is stopped only when `ps` reports the exact
  executable path for the selected bundle. A live PID for another path, a
  malformed pid file, or a failed graceful stop fails before replacement.
- The existing bundle is moved to the installer work backup before the new
  bundle is moved into place. A failed replacement leaves the old bundle
  available in that backup.
- The packaging E2E emits a JSON artifact with the inspected app path, bundle
  identity, workspace root, icon byte size and header, strict signature result,
  and designated requirement. It fails on any missing field or mismatch.

The check is read-only for the inspected app. It does not claim audio, GPU,
capture, worker, or physical acceptance.
