## The JS wire-constants block: the handful of engine constants the browser
## chromes must agree with. Forked from the starter's
## `src/ctf/wire_constants.nim`: this module renders them ONCE, from the same
## Nim consts the engine runs on; `server.nim` splices the block into every
## served client page and `tools/gen_wire_constants.nim` emits it for the
## static wasm bundle.
##
## The block publishes `window.SIGNALS_WIRE` and then aliases
## `window.CTF_WIRE` to the same object. The alias is NOT laziness: this fork
## copies `client/chrome_common.js` BYTE-FOR-BYTE (its sha256 is pinned by
## `tests/test_signals_viewer.nim`), and the starter's file reads
## `window.CTF_WIRE`. Editing it to read the new name would break the byte
## pin, so the constants are published under both names and the forked
## `broadcast_core.js` reads the new one.

import std/strutils
import sim_types, rig_art, global

proc jsIntArray(values: openArray[int]): string =
  result = "["
  for i, v in values:
    if i > 0: result.add ","
    result.add $v
  result.add "]"

const WireConstantsJs* =
  "window.SIGNALS_WIRE={speeds:" & jsIntArray(PlaybackSpeeds) &
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
