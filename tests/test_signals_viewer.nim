## The viewer: chrome provenance, the appended-block discipline, the removed
## ids, the beat CSS, the transport and density rules, and the label manifest.
## Tests 35-39 and 41 of the design note's list.

import std/[algorithm, os, strutils, unittest]
import crunchy
import helpers
import signals/[labels, global, rig_art, wire_constants]

const
  ChromeCommonSha256 =
    "7ace7287e0d19bf0fddb2362c55e4d76dfb44adcd4fbc8d1743b0557ced72f7c"
  ChromeCommonBytes = 40_022
  SpliceBanner =
    "sumo-traffic-signals additions to the inherited coworld-ctf chrome"

proc sha256Hex(data: string): string =
  ## The pin is the point: a REFORMATTED chrome_common.js is a fork, and this
  ## literal is what catches it. crunchy is already a pinned dependency, so no
  ## external tool is needed and the check runs identically everywhere.
  for byte0 in sha256(data):
    result.add(toHex(byte0, 2).toLowerAscii())

suite "chrome provenance":
  test "35. chrome_common.js is byte-identical to the starter's":
    let text = repoFile("client/chrome_common.js")
    check text.len == ChromeCommonBytes
    let digest = sha256Hex(text)
    checkpoint("sha256 " & digest)
    check digest == ChromeCommonSha256
    ## It is the STARTER'S file, unedited: it still reads window.CTF_WIRE, and
    ## wire_constants.nim publishes that alias precisely so the byte pin holds.
    check "window.CTF_WIRE" in text
    check "window.ChromeCommon" in text
    check "markBeat" in text
    check "renderBeatMarkers" in text
    check "ingestBeats" in text
    check "renderClock" in text
    check "renderTransport" in text
    check "ingestLullSpans" in text
    check "renderMomentum" in text

  test "35. the wire constants publish SIGNALS_WIRE and alias CTF_WIRE":
    check WireConstantsJs.startsWith("window.SIGNALS_WIRE={")
    check "window.CTF_WIRE=window.SIGNALS_WIRE;" in WireConstantsJs
    check "chromeSpriteId:" & $BroadcastChromeSpriteId in WireConstantsJs
    check "cellPx:" & $CellPx in WireConstantsJs

  test "36. the page is the starter's page PLUS an appended game block":
    let page = repoFile("client/replay_broadcast.html")
    let banner = page.find(SpliceBanner)
    check banner > 0
    ## Every landmark of the inherited region survives, in the inherited
    ## region, ahead of the banner.
    for landmark in ["function relayout()", "--hudscale", "--topband",
                     "--band", "PB_CTX = {", "window.SignalsChrome.install(",
                     "id=\"transport\"", "id=\"scrub\"", "id=\"endcard\"",
                     "id=\"killfeed\"", "id=\"bannerlane\"", "id=\"mmwarn\"",
                     "id=\"lockerroom\"", "function pushFeed(row)",
                     "function banner(text, cls)", "?embed=1"]:
      checkpoint("landmark " & landmark)
      let at = page.find(landmark)
      check at > 0
      check at < banner
    ## And the game block is entirely AFTER it.
    check page.find("window.SignalsChrome = {") > banner
    check page.find("function cityBeat(") > banner
    check page.find("rail.id = 'sigrail'") > banner

  test "36. broadcast_core.js keeps the starter's procs, pushFeed's signature included":
    let core = repoFile("client/broadcast_core.js")
    let starter = repoFile("client/chrome_common.js")
    check starter.len > 0
    ## The generic draw layer is the starter's: only the wire-constants name
    ## changed. Its retained-mode sprite path, its interpolation, its
    ## letterboxing and its chrome-sprite seam are all still there.
    for proc0 in ["function BroadcastCore(config)", "function ensureLayer(",
                  "function setViewport(", "function putSpritePixel(",
                  "function decodeSpritePixelsSnappy(", "CHROME_SPRITE_ID",
                  "function websocketAddress(", "attachMinimap"]:
      checkpoint("broadcast_core proc " & proc0)
      check proc0 in core
    check "window.SIGNALS_WIRE" in core
    check "window.CTF_WIRE" notin core

  test "37. no identifier in the game block shadows a chrome alias":
    ## replay_broadcast.html:1635's alias block declares `var markBeat =
    ## C.markBeat` and friends; a same-named function in the appended block is
    ## HOISTED over it (the tandem 2026-08-23 trap).
    let page = repoFile("client/replay_broadcast.html")
    let banner = page.find(SpliceBanner)
    let block0 = page[banner .. ^1]
    var aliases: seq[string]
    for line in page[0 ..< banner].splitLines():
      let text = line.strip()
      if not text.startsWith("var ") or " = C." notin text:
        continue
      for part in text[4 .. ^1].split(','):
        let pair = part.split('=')
        if pair.len == 2 and "C." in pair[1]:
          let name = pair[0].strip()
          ## One-character helpers (`$`) are re-declared in the block's own
          ## scope on purpose and cannot collide: the block is its own IIFE,
          ## which the structural check below pins.
          if name.len >= 2:
            aliases.add(name)
    check aliases.len >= 8
    for alias in aliases:
      checkpoint("chrome alias " & alias)
      check ("function " & alias & "(") notin block0
      check ("var " & alias & " ") notin block0
      check ("var " & alias & "=") notin block0
    ## The beat builder is cityBeat, never the chrome's own beat-marker name.
    check "function cityBeat(" in block0
    check "function markBeat(" notin block0
    check "markBeat(" notin block0
    ## And the whole block is ONE IIFE, so no declaration in it is hoisted into
    ## the page's scope at all — the structural guarantee behind the rule.
    check "(function () {" in block0
    check "})();" in block0
    check block0.find("(function () {") < block0.find("window.SignalsChrome = {")

  test "38. the beat CSS is exactly the kinds this game emits":
    let page = repoFile("client/replay_broadcast.html")
    var kinds: seq[string]
    var index = 0
    while true:
      let at = page.find(".beat-marker.", index)
      if at < 0:
        break
      index = at + 13
      var kind = ""
      for i in index ..< page.len:
        if page[i] in {'a' .. 'z'}:
          kind.add(page[i])
        else:
          break
      if kind.len > 0 and kind notin kinds:
        kinds.add(kind)
    kinds.sort()
    var wanted = @["end", "fallback", "gridlock", "spillback", "wave"]
    wanted.sort()
    checkpoint("beat kinds in the page: " & kinds.join(","))
    check kinds == wanted

  test "39. the transport, the endcard and the density rules":
    let page = repoFile("client/replay_broadcast.html")
    ## relayout() sets the three custom properties on :root, unchanged.
    check "root.style.setProperty('--hudscale'" in page
    check "root.style.setProperty('--topband'" in page
    check "root.style.setProperty('--band'" in page
    ## The endcard stops at the transport band and every seek dismisses it.
    check "#endcard {" in page
    check "bottom: var(--band, 0px)" in page
    check "$('endcard').classList.remove('on');" in page
    ## No game-block element is positioned inside the transport band: the rail
    ## rides INSIDE the measured #scorebug, which is the top band.
    check "#scorebug { flex-wrap: wrap; }" in page
    check "bug.appendChild(rail)" in page
    ## The plate-name rule, and the five .tiny rules.
    check ".plate-name {" in page
    check "flex: 1 1 auto;" in page
    check "min-width: 3.2em;" in page
    var tinyRules = 0
    for line in page.splitLines():
      if line.strip().startsWith("#stage.tiny "):
        inc tinyRules
    checkpoint("#stage.tiny rules: " & $tinyRules)
    check tinyRules >= 5
    ## The board's aspect is legible at 360 px: height binds, the whole city is
    ## in frame, so the zoom bar and the board inset are dropped.
    check BoardCellsWide * 1000 div BoardCellsHigh == 1307
    check BoardPxWide == BoardCellsWide * CellPx
    check BoardPxHigh == BoardCellsHigh * CellPx

  test "39. the removed ids appear NOWHERE in the page":
    let page = repoFile("client/replay_broadcast.html")
    for removed in ["viewpanel", "minimap", "minimap-canvas", "zoombar",
                    "zoom-in", "zoom-out", "zoom-slider", "zoom-read",
                    "povBadge", "fpv", "fpv-canvas", "fpv-hud", "fpv-name",
                    "fpv-hp", "fpv-gear", "fpv-map", "fpv-map-canvas",
                    "fpv-cap", "fpv-grip"]:
      for pattern in ["id=\"" & removed & "\"", "$('" & removed & "')",
                      "#" & removed & " ", "#" & removed & "{",
                      "#" & removed & ".", "#" & removed & ","]:
        checkpoint("removed id pattern " & pattern)
        check pattern notin page

  test "39. the static bundle's four viewer files come from ONE starter":
    ## Splicing one starter's shell onto another's emscripten link flags
    ## deadlocks the viewer silently (cogame-lantern 2026-08-23).
    let
      configNims = repoFile("replay-viewer/config.nims")
      worker = repoFile("replay-viewer/static_replay_worker.js")
      shell = repoFile("replay-viewer/static_replay.js")
    ## paintbot lineage: NON-modularized module, the Worker waits on
    ## Module.onRuntimeInitialized.
    check "MODULARIZE" notin configNims
    check "EXPORT_NAME" notin configNims
    check "Module.onRuntimeInitialized" in worker
    check "importScripts('./wire_constants.js', './broadcast_core.js', " &
      "'./signals_replay.js')" in worker
    check "signals_replay.js" in configNims
    check "-s ABORTING_MALLOC=1" in configNims
    check "-s ALLOW_MEMORY_GROWTH" in configNims
    check "-s FILESYSTEM=1" in configNims
    check "-s ENVIRONMENT=web,worker,node" in configNims
    check "-s EXPORTED_RUNTIME_METHODS=HEAPU8" in configNims
    check "--preload-file" in configNims
    for exported in ["_signals_load_replay", "_signals_frame", "_signals_input",
                     "_signals_packet_ptr", "_signals_packet_len",
                     "_signals_mismatch_tick", "_signals_error_ptr",
                     "_signals_error_len", "_signals_stage_ptr",
                     "_signals_stage_len"]:
      checkpoint("exported " & exported)
      check exported in configNims
    ## The load and error signals are the starter's own, kept.
    check "data-replay-loaded" in shell
    check "data-replay-error" in shell
    check "window.SignalsStaticReplay" in shell

suite "the label manifest":
  test "41. the emitted board-label vocabulary equals tests/label_manifest.txt":
    let
      emitted = labelManifestText()
      recorded = repoFile("tests/label_manifest.txt")
    if emitted != recorded:
      checkpoint("regenerate tests/label_manifest.txt in the same commit as " &
        "the label change")
      checkpoint("emitted " & $emitted.splitLines().len & " lines, recorded " &
        $recorded.splitLines().len)
    check emitted == recorded

  test "41. every label is non-empty and carries a known kind":
    var kinds: seq[string]
    for kind in BoardLabelKinds:
      kinds.add(kind)
    for label in labelVocabulary():
      check label.len > 0
      let kind = label.split('/')[0]
      checkpoint("label " & label)
      check kind in kinds

  test "41. no label leaks a real player name":
    ## The two-name-space rule: a board label is an intersection id, a link id,
    ## a gate id, a phase id or a controller ALIAS — never a player name.
    for label in labelVocabulary():
      check "daveey" notin label
      check "Baseline" notin label
