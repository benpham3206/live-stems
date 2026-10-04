# Spotify skip and state failure contract

The state reader must not delay a Spotify skip. A native notification is the
first source for a new track or playback state. The AppleScript reader fills
gaps and checks state in the background.

## Failure cases

| Case | Trigger | Failure in the old design | Required result |
| --- | --- | --- | --- |
| F1. Delayed skip | A reader call blocks for 0.8 seconds, then a notice reports a new track. | The notice waits behind the reader on the one state queue. Old-track metadata stays live during the skip. | The new track snapshot reaches the callback before the reader returns. |
| F2. Stale poll success | The blocked reader returns the old track after the new-track notice. | The old result can publish after the skip and move the pipeline back to the old track. | The old result is discarded because a newer accepted notice changed the metadata version. |
| F3. Stale poll failure | The blocked reader fails after a valid pause or track notice. | The old error can replace a usable state and trigger an unnecessary fallback. | The old error is discarded with the same version guard. |
| F4. Rapid changes | Several track notices arrive while one reader is in flight. | A serialized reader can collapse or reorder the visible state. | Every valid notice is published in arrival order. |
| F5. Pause and resume | A pause and a resume arrive before the reader returns. | The reader result can restore the previous playing state. | Both accepted notices publish promptly. The stale reader result cannot undo either state. |
| F6. Bad notice data | A notice omits the track ID, has an unknown player state, or has a non-finite position. | Unchecked user-info data can create a false snapshot or crash parsing. | The notice is ignored. The normal poll remains available to recover state. |
| F7. Unknown duration units | A direct notice includes a `Duration` value, but the saved notice artifact records only its numeric type. | Treating an unverified value as seconds or milliseconds can invent a false natural track boundary. | Keep the previous duration for the same track. Use zero for a new track until a reader supplies a known duration. |
| F8. Stop and restart | A read from the previous lifecycle completes after `stop()` and a new `start()`. | The old callback can publish into the restarted session. A synchronous stop can also wait for the blocked reader. | `stop()` returns without waiting for the reader. The old result is rejected by lifecycle and read identity. The restarted reader can publish. |

## Acceptance evidence

`SpotifyStateE2E.run(_:)` drives these cases through the real
`SpotifyState.handleNotification(_:)` handler. It writes
`skip-state.json` under the supplied acceptance directory. The report records
the observed track sequence, callback timing, stale-result suppression, and
stop/restart timing so the run can be repeated without CUA, AppleScript GUI
automation, Spotify, or an audio session.

The recorded notice file at
`outputs/live-stems-acceptance/short-stream/spotify-notices.jsonl` contains
`Track ID` as a string, `Player State` as a string, `Playback Position` as a
number, and `Name` as a string. Its `Duration` entry contains only the class
`__NSCFNumber`, not a value. The direct notice path therefore does not infer a
duration unit.
