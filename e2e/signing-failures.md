# Persistent permission checks

These failures are recorded before changing the build script.

- No configured certificate: fail before stopping or replacing the installed app.
- An invalid certificate ID: reject it before signing.
- A certificate that cannot sign: fail in the staged bundle. Keep the installed bundle intact.
- An ad hoc result: reject the binary-hash designated requirement.
- The app identifier changes: reject the staged bundle.
- A rebuild: verify the staged app with strict codesign verification before replacement.
- Two different builds with the same certificate: their designated requirements must agree.
- Launch, enable capture, stop, and relaunch: the human must confirm that macOS does not repeat its permission request.
- Startup diagnostics must not block the main event loop on file access.
- The packaged reference must load from app resources without a broad Documents-folder grant.
- An existing Applications candidate with a missing or malformed `Info.plist`,
  the wrong bundle identifier, the wrong executable or package type, or a
  `local.json.root` outside this workspace must fail target selection. The
  signing E2E must not inspect or mutate an unrelated bundle.

A stable signature supports saved permission. It cannot remove the first macOS approval or promise that macOS will never ask again after revocation or a policy change.
