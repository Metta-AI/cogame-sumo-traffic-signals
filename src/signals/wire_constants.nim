## The JS wire-constants block: the handful of engine constants the browser
## chromes must agree with. Forked from the starter's
## `src/ctf/wire_constants.nim`: this module renders them ONCE, from the same
## Nim consts the engine runs on; `server.nim` splices the block into every
## served client page and `tools/gen_wire_constants.nim` emits it for the
## static wasm bundle.
##
## The block publishes `window.SIGNALS_WIRE` and then aliases
## `window.CTF_WIRE` to the same object. The alias is NOT laziness: this fork
## copies `client/chrome_common.js` from the starter apart from the fleet-wide
## replay-transport patch (its sha256 is pinned by
## `tests/test_signals_viewer.nim`), and that file still reads
## `window.CTF_WIRE`. Renaming the lookup would be a second, gratuitous edit
## to a pinned file, so the constants are published under both names and the
## forked `broadcast_core.js` reads the new one.

import std/strutils
import sim_types, rig_art, global

proc jsIntArray(values: openArray[int]): string =
  result = "["
  for i, v in values:
    if i > 0: result.add ","
    result.add $v
  result.add "]"

const WireConstantsJs* =
  # 0.5 is the replay-only 1/2x crawl (`ReplayHalfSpeedIndex`, command '5');
  # it rides ahead of the engine's integer `PlaybackSpeeds`.
  "window.SIGNALS_WIRE={speeds:[0.5," & jsIntArray(PlaybackSpeeds)[1 .. ^1] &
  ",fps:" & $TargetFps &
  ",chromeSpriteId:" & $BroadcastChromeSpriteId &
  ",cellPx:" & $CellPx &
  ",boardCellsW:" & $BoardCellsWide &
  ",boardCellsH:" & $BoardCellsHigh &
  ",framesPerTick:2" &
  ",seats:" & $MaxSeats &
  ",maxSayRunes:" & $MaxSayRunes &
  "};window.CTF_WIRE=window.SIGNALS_WIRE;"

const WireConstantsMarker* = "<!-- WIRE_CONSTANTS -->"
  ## The placeholder both client HTML files carry where the block belongs
  ## (before any script that reads the constants).

proc spliceWireConstants*(page: string): string =
  ## Replaces the marker with the inline constants script. A page without the
  ## marker passes through unchanged.
  page.replace(WireConstantsMarker,
    "<script>" & WireConstantsJs & "</script>")
