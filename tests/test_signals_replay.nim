## The replay: record then re-derive for EVERY end reason, self-sufficiency,
## the strict-UTF-8 summary, determinism from the bytes alone, and the
## GameVersion sweep. Tests 28-32 of the design note's list.

import std/[json, os, osproc, strutils, unicode, unittest]
import helpers
import bitworld/runtime
import signals/[replay_runtime, decide]

proc tempDir(name: string): string =
  result = getTempDir() / (name & "-" & $getCurrentProcessId())
  createDir(result)

proc recordEpisode(
  config: GameConfig, path: string, forced: EndRule, detail = ""
): SimServer =
  ## Records one scripted episode, optionally forcing the wall-clock or fault
  ## stop. The stop is written as ONE load-bearing record applied by the SAME
  ## proc on record and on playback (the particle-worlds 2026-08-26 scar).
  result = initSimServer(config)
  var writer = openReplayWriter(path, config.configJson())
  for slot in 0 ..< MaxSeats:
    result.players[slot].joined = true
    result.players[slot].registered = true
    let kind = (if slot mod 2 == 0: "greedy" else: "fixedcycle")
    result.registerSeat(slot, kind, "scripted", kind)
    writer.writeJoin(tickTime(0), slot, result.players[slot].name, slot, "")
    writer.writeChat(tickTime(0), 255,
      registerRecord(slot, kind, "scripted", kind))
  result.phase = Playing
  let stopTurn = (if forced == erNone: 0 else: 6)
  for turnIndex in 1 .. result.turnsPerEpisode():
    if result.settled:
      break
    result.turn = turnIndex
    for slot in 0 ..< MaxSeats:
      let baseline = (if slot mod 2 == 0: blGreedy else: blFixedCycle)
      result.applyReply(slot, result.scriptedReply(slot, baseline))
    writer.writeChat(tickTime(result.tickCount), 255,
      ordersRecord(result, turnIndex))
    for k in 0 ..< config.turnTicks:
      if result.settled:
        break
      result.stepTick(k)
      writer.writeHash(uint32(result.tickCount), result.gameHash())
    result.turnsPlayed = turnIndex
    if stopTurn > 0 and turnIndex == stopTurn:
      result.applyStop(forced, detail)
      writer.writeChat(tickTime(result.tickCount), 255,
        stopRecord(result.tickCount, $forced))
      break
  if not result.settled:
    result.applyStop(erFullPeriod, "")
  writer.writeChat(tickTime(result.finalTick), 255,
    resultRecord(result, result.cityResultsJson()))
  writer.closeReplayWriter()

proc rederive(path: string): tuple[player: ReplayPlayer, sim: SimServer] =
  var initialized = initReplayRuntime(parseReplayBytes(readFile(path)),
                                      mismatchQuit = false)
  (player: initialized.player, sim: initialized.sim)

suite "record then re-derive, every end reason":
  test "28. cleared / gridlock / fullPeriod / wallClock / fault all re-derive":
    let work = tempDir("signals-replay")
    var cases: seq[tuple[name: string, config: GameConfig, forced: EndRule]]

    ## `cleared`: no demand at all and a short demand window, so the city is
    ## empty the moment the peak is over.
    var clearedConfig = testConfig()
    clearedConfig.demandWarmPermille = 0
    clearedConfig.demandPeakPermille = 0
    clearedConfig.demandDeclinePermille = 0
    clearedConfig.demandEndTick = 8
    clearedConfig.gridlockStallTicks = 500
    clearedConfig.update("{}")
    cases.add(("cleared", clearedConfig, erNone))

    ## `gridlock`: an empty city with a short stall window and a demand window
    ## that outlasts it, so the stall fires before `cleared` can.
    var gridlockConfig = testConfig()
    gridlockConfig.demandWarmPermille = 0
    gridlockConfig.demandPeakPermille = 0
    gridlockConfig.demandDeclinePermille = 0
    gridlockConfig.demandEndTick = 200
    gridlockConfig.gridlockStallTicks = 4
    gridlockConfig.update("{}")
    cases.add(("gridlock", gridlockConfig, erNone))

    ## `fullPeriod`: real demand and a short clock, so cars are still on the
    ## network when the tick cap lands.
    var fullConfig = testConfig("rushhour")
    fullConfig.maxTicks = 64
    fullConfig.gridlockStallTicks = 500
    fullConfig.update("{}")
    cases.add(("fullPeriod", fullConfig, erNone))

    cases.add(("wallClock", testConfig(), erWallClock))
    cases.add(("fault", testConfig(), erFault))

    for entry in cases:
      let path = work / (entry.name & ".replay")
      let recorded = recordEpisode(
        entry.config, path, entry.forced,
        (if entry.forced == erFault: "forced fault for the re-derive test"
         else: "forced stop for the re-derive test"))
      checkpoint(entry.name & ": " & describeState(recorded) &
        " endRule=" & $recorded.endRule)
      if entry.forced == erNone:
        check $recorded.endRule == entry.name
      else:
        check recorded.endRule == entry.forced
      let derived = rederive(path)
      ## Identical hashes at EVERY tick, INCLUDING the stop tick.
      check derived.player.hashMismatchTick == -1
      check derived.player.hashValidationFailed == false
      var replayed = derived
      replayed.player.seekReplay(replayed.sim, replayed.player.maxTick)
      check replayed.player.hashMismatchTick == -1
      check replayed.sim.tickCount == recorded.finalTick
      check replayed.sim.throughput == recorded.throughput
      check replayed.sim.networkWaitTicks == recorded.networkWaitTicks
      check replayed.sim.endRule == recorded.endRule
      check replayed.sim.endReason == recorded.endReason
    removeDir(work)

suite "the replay is self-sufficient":
  test "29. the bytes alone yield names, kinds, the config and the result":
    let
      work = tempDir("signals-selfsuff")
      path = work / "episode.replay"
    let recorded = recordEpisode(testConfig(), path, erNone)
    let data = parseReplayBytes(readFile(path))
    check data.gameName == GameName
    check data.gameVersion == GameVersion
    let config = parseJson(data.configJson)
    for key in ["seed", "variant", "num_agents", "turnTicks", "maxTicks",
                "ewLinkCells", "nsLinkCells", "ewGateCells", "nsGateCells",
                "gateQueueCap", "minGreenTicks", "clearTicks", "maxRedTicks",
                "demandWarmPermille", "demandPeakStart", "demandPeakPermille",
                "demandPeakEnd", "demandDeclinePermille", "demandEndTick",
                "throughRunnerPermille", "parThroughput", "ringTicks",
                "gridlockStallTicks", "waveVehicles", "waveWindow",
                "waveCrossings", "switchMargin", "greenCap", "players",
                "slots", "fastMode"]:
      checkpoint("config key " & key)
      check config.hasKey(key)
    ## Tokens are runner-injected credentials and are NEVER in the bytes.
    check not config.hasKey("tokens")
    check data.joins.len == MaxSeats
    let player = initReplayPlayer(data)
    check player.orders.len > 0
    check player.resultsJson.len > 0
    let results = parseJson(player.resultsJson)
    check results{"throughput"}.getInt() == recorded.throughput
    check results{"aliases"}.len == MaxSeats
    check results{"policyKinds"}.len == MaxSeats
    var registers = 0
    for record in player.feed:
      if "\"k\":\"register\"" in record.record:
        inc registers
    check registers == MaxSeats
    removeDir(work)

suite "replay_summary is strict UTF-8 JSON":
  test "30. every capped field filled with 4-byte emoji still parses":
    let
      work = tempDir("signals-summary")
      path = work / "episode.replay"
    var config = testConfig()
    ## Record an episode, then append a directive record whose every capped
    ## field is filled to EXACTLY its cap with a 4-byte emoji.
    discard recordEpisode(config, path, erNone)
    var say = ""
    for _ in 0 ..< MaxSayRunes:
      say.add("\u{1F6A6}")
    var notes = ""
    for _ in 0 ..< MaxNoteRunes:
      notes.add("\u{1F6A6}")
    var reply = ControllerReply(source: dsLlm, latencyMs: 4200)
    reply.orders.add(ControllerOrder(
      at: intersectionIndex("C2"), verb: ovWave, phase: phEWG, delay: 6,
      fromReply: true))
    reply.say = sanitizeSay(say)
    reply.notes = sanitizeNote(notes)
    check reply.say.runeLen == 0 or reply.say.runeLen <= MaxSayRunes
    ## Append the record: the codec is append-only and enforces
    ## non-decreasing chat timestamps, so the record rides a tick past the end
    ## of the episode, exactly as a late control record would.
    let record = boundedDirectiveRecord(reply, 7, 2, nil)
    check record.validateUtf8() == -1
    var handle = open(path, fmAppend)
    handle.write(char(0x05))
    for shift in countup(0, 24, 8):
      handle.write(char((uint32(tickTime(10_000)) shr shift) and 0xff'u32))
    handle.write(char(255))
    handle.write(char(record.len and 0xff))
    handle.write(char((record.len shr 8) and 0xff))
    handle.write(record)
    handle.close()

    let summary = execCmdEx("python3 " & repoPath("tools/replay_summary.py") &
      " " & path)
    checkpoint(summary.output[0 ..< min(400, summary.output.len)])
    check summary.exitCode == 0
    check summary.output.validateUtf8() == -1
    let document = parseJson(summary.output)
    check document{"protocol"}.getStr() == "signals/v1"
    check document{"gameVersion"}.getStr() == GameVersion
    check document{"results"}{"reason"}.getStr().len > 0
    check document{"orders"}.len > 0
    ## No lone surrogates: a strict UTF-8 parse of the emitted text.
    check ($document).validateUtf8() == -1
    removeDir(work)

suite "determinism from the replay alone":
  test "31. a fresh sim re-simulates the identical episode":
    let
      work = tempDir("signals-determinism")
      path = work / "episode.replay"
    let recorded = recordEpisode(testConfig("rushhour"), path, erNone)
    let data = parseReplayBytes(readFile(path))
    var
      config = defaultGameConfig()
      player = initReplayPlayer(data)
    config.update(data.configJson)
    var sim = initSimServer(config)
    player.resetReplay(sim)
    var hashes: seq[uint64]
    while not sim.settled and sim.tickCount < player.maxTick:
      player.stepReplay(sim)
      hashes.add(sim.gameHash())
    check player.hashMismatchTick == -1
    check sim.tickCount == recorded.finalTick
    check sim.throughput == recorded.throughput
    check sim.networkWaitTicks == recorded.networkWaitTicks
    check sim.greenWaves == recorded.greenWaves
    check hashes.len == data.hashes.len
    for i in 0 ..< hashes.len:
      check hashes[i] == data.hashes[i].hash
    removeDir(work)

suite "the GameVersion sweep":
  test "32. every committed fixture carries the current GameVersion":
    ## A fixture recorded against an older rule set must FAIL to load, not
    ## load and re-simulate wrong. The codec enforces it; this sweep is what
    ## makes an unversioned rule change fail the build.
    let dir = repoPath("tests/fixtures")
    var swept = 0
    if dirExists(dir):
      for kind, path in walkDir(dir):
        if kind != pcFile or not path.endsWith(".replay"):
          continue
        inc swept
        let data = parseReplayBytes(readFile(path))
        check data.gameVersion == GameVersion
        check data.gameName == GameName
    ## Plus a freshly recorded one, so the sweep is never vacuous.
    let
      work = tempDir("signals-sweep")
      path = work / "fresh.replay"
    discard recordEpisode(testConfig(), path, erNone)
    let fresh = parseReplayBytes(readFile(path))
    check fresh.gameVersion == GameVersion
    inc swept
    check swept >= 1
    ## A replay whose version does not match must be REFUSED.
    var bytes = readFile(path)
    let marker = bytes.find(GameVersion, 8)
    check marker > 0
    bytes[marker] = '9'
    expect ReplayError:
      discard parseReplayBytes(bytes)
    removeDir(work)
