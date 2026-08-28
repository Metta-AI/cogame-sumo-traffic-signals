## The label vocabulary contract. Forked from the starter's
## `src/ctf/labels.nim`: every sprite the compositor emits carries a NON-EMPTY
## label, the inspector and any bot reader key off those labels, and
## `tests/label_manifest.txt` pins the whole vocabulary so a rename cannot
## land without regenerating the manifest in the same commit.
##
## The two-name-space rule is inherited with no further change: a board label
## is an intersection id, a link id, a gate id, a phase id or a controller
## ALIAS — never a real player name. `showPlayerLabels` is false.

import
  std/[algorithm, strutils],
  sim_types

const
  BoardLabelKinds*: array[10, string] = [
    "bed",        # one quadrant of the baked city bed
    "car",        # a car chip: facing, colour, chevron
    "dash",       # the .tiny car readout
    "signal",     # a signal head: facing, lamp state
    "heat",       # the queue-length heatmap band
    "full",       # a full link's hard-edged band
    "ring",       # a gridlock ring link outline
    "wave",       # the green-wave sweep band
    "gatepip",    # one car queued outside a gate
    "chrome"      # the broadcast chrome JSON carrier
  ]

proc bedLabel*(index: int): string = "bed/" & $index

proc carLabel*(dir: Approach, colour: int, chevron: bool): string =
  "car/" & $dir & "/" & $colour & (if chevron: "/chevron" else: "")

proc dashLabel*(dir: Approach, colour: int): string =
  "dash/" & $dir & "/" & $colour

proc signalLabel*(dir: Approach, state: int): string =
  "signal/" & $dir & "/" &
    (case state
     of 0: "red"
     of 1: "amber"
     else: "green")

proc heatLabel*(level: int): string = "heat/" & $level
proc fullLabel*(): string = "full"
proc ringLabel*(): string = "ring"
proc waveLabel*(): string = "wave"
proc gatePipLabel*(): string = "gatepip"
proc chromeLabel*(): string = "chrome"

proc labelVocabulary*(): seq[string] =
  ## Every label the compositor can emit, sorted, one per line in
  ## `tests/label_manifest.txt`.
  for index in 0 ..< 4:
    result.add(bedLabel(index))
  for dir in ApproachOrder:
    for colour in 0 ..< 5:
      result.add(carLabel(dir, colour, false))
      result.add(carLabel(dir, colour, true))
      result.add(dashLabel(dir, colour))
    for state in 0 ..< 3:
      result.add(signalLabel(dir, state))
  for level in 0 ..< 8:
    result.add(heatLabel(level))
  result.add(fullLabel())
  result.add(ringLabel())
  result.add(waveLabel())
  result.add(gatePipLabel())
  result.add(chromeLabel())
  result.sort()

proc labelManifestText*(): string =
  labelVocabulary().join("\n") & "\n"
