## Endcard and chrome label re-mapping. Test 40 of the design note's list.
##
## Nothing in the starter's tests, in `viewer_smoke.mjs` or in the label
## manifest covers spectator chrome STRINGS — `labels.nim` deliberately scopes
## itself to the policy contract — so a forked ctf endcard silently ships
## paintbot's vocabulary. This file is the gate.

import std/[strutils, unittest]
import helpers

const
  ## Words that belong to the starter's game and to no part of this one.
  ## Checked outside comment blocks, because the fork's own comments name what
  ## they replaced and that history is worth keeping.
  Forbidden = [
    "Lives", "LIVES", "Clstr", "Cap<", "flag", "heart", "paint", "hopper",
    "hill", "POV", "spray", "grenade", "med kit", "kill"
  ]
  ## Ids the inherited page keeps by name (design SS-Viewer, "Kept"), so the
  ## forbidden-word scan must not trip over them.
  KeptIdentifiers = [
    "killfeed", "lightpool", "flagstone",
    # Sprite-protocol identifiers, not paintbot vocabulary: the LAYER flags are
    # part of the wire format `broadcast_core.js` decodes.
    "ZoomableFlag", "UiFlag", "flags", "MapLayerType"
  ]
  Replacements = [
    "<span>Controller</span><span>Served</span>",
    "<span>Waiting</span><span>Waves</span><span>Spillbacks</span></div>",
    "Booting the signal controllers&hellip;",
    "Signals dark",
    "<span class=\"momentum-label\">THROUGHPUT</span>",
    "Spoilers: green waves / spillbacks / gridlock on the timeline ahead of " &
      "the playhead (o)",
    "Replay hash mismatch at tick "
  ]

proc strippedOfComments(text: string): seq[tuple[line: int, code: string]] =
  ## Drops HTML comments, whole-line JS comments and CSS comment blocks, so the
  ## scan sees only what the page SHOWS.
  var
    inHtmlComment = false
    inCssComment = false
    number = 0
  for raw in text.splitLines():
    inc number
    var line = raw
    if inHtmlComment:
      let close = line.find("-->")
      if close < 0:
        continue
      inHtmlComment = false
      line = line[close + 3 .. ^1]
    if inCssComment:
      let close = line.find("*/")
      if close < 0:
        continue
      inCssComment = false
      line = line[close + 2 .. ^1]
    while true:
      let open = line.find("<!--")
      if open < 0:
        break
      let close = line.find("-->", open)
      if close < 0:
        line = line[0 ..< open]
        inHtmlComment = true
        break
      line = line[0 ..< open] & line[close + 3 .. ^1]
    while true:
      let open = line.find("/*")
      if open < 0:
        break
      let close = line.find("*/", open)
      if close < 0:
        line = line[0 ..< open]
        inCssComment = true
        break
      line = line[0 ..< open] & line[close + 2 .. ^1]
    let trimmed = line.strip()
    if trimmed.startsWith("//") or trimmed.startsWith("##"):
      continue
    let slashes = line.find("//")
    if slashes >= 0 and "://" notin line:
      line = line[0 ..< slashes]
    if line.strip().len == 0:
      continue
    result.add((line: number, code: line))

proc maskKept(code: string): string =
  result = code
  for kept in KeptIdentifiers:
    result = result.replace(kept, "-")

suite "endcard labels":
  test "40. zero paintbot vocabulary outside comments":
    for path in ["client/replay_broadcast.html", "client/broadcast_core.js"]:
      let source = repoFile(path)
      for entry in strippedOfComments(source):
        let code = maskKept(entry.code)
        for word in Forbidden:
          if word in code:
            checkpoint(path & ":" & $entry.line & ": " & word & " in " &
              code.strip())
            check false

  test "40. every re-mapped string is present exactly once":
    let page = repoFile("client/replay_broadcast.html")
    for wanted in Replacements:
      checkpoint("replacement " & wanted[0 ..< min(48, wanted.len)])
      check page.count(wanted) == 1

  test "40. the endcard header is this game's five columns":
    let page = repoFile("client/replay_broadcast.html")
    check "<span>Controller</span>" in page
    check "<span>Served</span>" in page
    check "<span>Waiting</span>" in page
    check "<span>Waves</span>" in page
    check "<span>Spillbacks</span>" in page
    check "CITY SCORE " in page
    check "CARS THROUGH \u2014 PAR " in page
    check "green waves, " in page
    check "car-seconds lost, " in page

  test "40. the endcard rule names are this game's closed enum":
    let page = repoFile("client/replay_broadcast.html")
    check "'CITY CLEARED'" in page
    check "'GRIDLOCK STALL'" in page
    check "'WALL-CLOCK STOP'" in page
    check "'FAULT \u2014 NO RESULT'" in page
    check "'FULL PERIOD'" in page

  test "40. the plate is this game's, not the starter's":
    let page = repoFile("client/replay_broadcast.html")
    check "class=\"served-label\"" in page
    check "id=\"served-" in page
    check "class=\"quad-tag\"" in page
    check "class=\"plate-av\"" in page
