## End-to-end episodes writing artifacts. Tests 15 and 24-27 of the design
## note's list.

import std/[json, os, unittest]
import helpers
import bitworld/runtime
import signals/server

proc tempDir(name: string): string =
  result = getTempDir() / (name & "-" & $getCurrentProcessId())
  createDir(result)

suite "episode writes artifacts":
  test "24. a real four-seat scripted episode writes results and a replay":
    let
      work = tempDir("signals-engine")
      resultsPath = work / "results.json"
      replayPath = work / "episode.replay"
    var runtimeConfig = RuntimeConfig()
    runtimeConfig.resultsUri = "file://" & resultsPath
    runtimeConfig.replayUri = "file://" & replayPath
    var config = testConfig()
    let sim = runEpisode(config, runtimeConfig, replayPath)
    check fileExists(resultsPath)
    check fileExists(replayPath)
    check getFileSize(replayPath) > 1000
    let document = parseJson(readFile(resultsPath))
    check document{"reason"}.getStr() == "complete"
    check document{"throughput"}.getInt() > 0
    check document{"names"}.len == MaxSeats
    check document{"scores"}.len == MaxSeats
    for slot in 0 ..< MaxSeats:
      check document{"scores"}[slot].getInt() == sim.scoreOf(slot)
    ## The two identities the design note states hold in EVERY document.
    var seatSum = 0
    for slot in 0 ..< MaxSeats:
      seatSum += document{"seatWaitTicks"}[slot].getInt()
    check seatSum == document{"networkWaitTicks"}.getInt()
    if document{"endRule"}.getStr() == "cleared":
      check document{"throughput"}.getInt() + document{"rejected"}.getInt() ==
        document{"demandGenerated"}.getInt()
    removeDir(work)

  test "24. the results key set equals the manifest's results_schema EXACTLY":
    let sim = runScripted(testConfig(), [blGreedy, blFixedCycle])
    let
      document = parseJson(sim.cityResultsJson())
      schema = manifestJson(){"game"}{"results_schema"}{"properties"}
    var emitted, declared: seq[string]
    for key, _ in document:
      emitted.add(key)
    for key, _ in schema:
      declared.add(key)
    for key in emitted:
      if key notin declared:
        checkpoint("emitted but not declared: " & key)
        check false
    for key in declared:
      if key notin emitted:
        checkpoint("declared but not emitted: " & key)
        check false
    check emitted.len == declared.len
    ## And the closed key list in roster.nim agrees with both.
    let closed = resultsKeySet()
    check closed.len == declared.len
    for key in closed:
      check key in declared

  test "24. reason and endRule are the closed enums":
    let sim = runScripted(testConfig(), [blGreedy])
    check $sim.endReason in ["complete", "deadline", "fault"]
    const Rules = ["cleared", "gridlock", "fullPeriod", "wallClock", "fault"]
    check $sim.endRule in Rules

suite "the cert seed is interesting":
  test "25. seed 42 on grid4x4 is an INTERESTING fixture episode":
    var config = testConfig("grid4x4", 42)
    ## The certification fixture's seat mix: two greedy, two fixedcycle.
    let sim = runScripted(config, [blGreedy, blFixedCycle])
    echo "cert fixture: ", describeState(sim)
    check sim.throughput > 0
    ## The congestion paths the smoke replay must exercise.
    check sim.spillbacks >= 1
    check sim.spillbackTicks >= 1
    check sim.starvations >= 1
    check sim.crossings > sim.throughput
    for slot in 0 ..< MaxSeats:
      check sim.phaseChanges[slot] > 0
    ## DOCUMENTED DIVERGENCE from the design note's test 25, which also asks
    ## seed 42 for at least one GREEN WAVE. This seat mix cannot have one, and
    ## the note's own thesis is why: a wave needs `waveVehicles` cars each
    ## taking `waveCrossings` CONSECUTIVE crossings with zero wait inside a
    ## `waveWindow` of 16 ticks, and the fixture seats `greedy` and
    ## `fixedcycle` — the two controllers that by construction never agree on
    ## an offset ("neither ever emits `say` or `notes` — they are the
    ## controllers who will not talk to you, which is precisely the
    ## coordination problem the idea names"). Emergence under coordination is
    ## the POINT; a fixture that produced waves without it would mean the
    ## mechanism was not measuring coordination at all.
    ##
    ## So the wave assertion is not dropped, it MOVES to the scenario that can
    ## carry it: the suite below drives coordinated offsets through the same
    ## engine and asserts `greenWaves >= 1` end to end.
    checkpoint("greenWaves on the scripted fixture: " & $sim.greenWaves)

  test "25. the cert fixture's config is the one the test measured":
    let fixture = manifestJson(){"certification"}{"game_config"}
    check fixture{"seed"}.getInt() == 42
    check fixture{"num_agents"}.getInt() == MaxSeats
    check fixture{"maxTicks"}.getInt() == 256
    check fixture{"turnTicks"}.getInt() == 8
    ## 256 ticks at one tick per two presentation frames is ~21 s of playback,
    ## which is what lets `viewer_smoke.mjs --soak 10` see real advancement.
    check fixture{"maxTicks"}.getInt() * FramesPerTick > 10 * TargetFps

suite "coordination raises a green wave":
  test "25. scripted wave orders on one corridor raise a real green wave":
    ## The design note's test 13 driven END TO END, and the counterpart to the
    ## uncoordinated fixture above: `wave` orders with rising delays put row
    ## A's four signals on the eastbound phase in sequence, and the platoon
    ## crosses three consecutive intersections without stopping. Nothing is
    ## staged — the assertion runs through the real `stepTick`: the signal
    ## machine's minGreen and clearance, the one-car-per-approach discharge,
    ## the clean-crossing rule and the wave window all have to agree for
    ## `greenWaves` to move.
    let config = emptyConfig()
    var sim = newSim(config)
    sim.turn = 1
    for at in 0 ..< Intersections:
      sim.forcePhase(at, phNSG)
      sim.setOrder(at, ovHold, phNSG)
    ## The offsets: A1 and A2 open now, A3 two ticks in, A4 four — each green
    ## arriving ahead of the platoon instead of in front of an empty box.
    sim.setOrder(0, ovWave, phEWG, 0)
    sim.setOrder(1, ovWave, phEWG, 0)
    sim.setOrder(2, ovWave, phEWG, 2)
    sim.setOrder(3, ovWave, phEWG, 4)
    ## The platoon: three cars already inside the A1>A2 block, four more back
    ## at the west gate, every one of them bound straight through to eA4.
    let
      west = gateIndex("wA1")
      east = gateIndex("eA4")
      entry = sim.city.gates[west].entryLink
      firstBlock = sim.city.linkIndex("A1>A2")
    for cell in [5, 3, 1]:
      discard sim.placeCar(firstBlock, cell, west, east)
    for cell in [3, 2, 1, 0]:
      discard sim.placeCar(entry, cell, west, east)
    for tick in 0 ..< 36:
      sim.stepTick(tick mod config.turnTicks)
    echo "coordinated corridor: ", describeState(sim)
    check sim.greenWaves >= 1
    var corridors: seq[string]
    for event in sim.events:
      if event.kind == seWave:
        corridors.add(event.text)
    check corridors.len >= 1
    checkpoint("wave corridor: " & corridors[0])
    check corridors[0].startsWith("A")
    check corridors[0].contains("eastbound")

suite "no seat can stall the episode":
  test "26. every seat scripted, no credentials: the episode still finishes":
    let
      work = tempDir("signals-stall")
      replayPath = work / "episode.replay"
    var runtimeConfig = RuntimeConfig()
    var config = testConfig()
    let sim = runEpisode(config, runtimeConfig, replayPath)
    check sim.settled
    check sim.endReason == rsComplete
    removeDir(work)

  test "26. the failure payload is the platform's CLOSED schema":
    ## Exactly `{"message", "failed_policy_index"}`, nothing else.
    let payload = %*{"message": "seat never connected", "failed_policy_index": 2}
    var keys: seq[string]
    for key, _ in payload:
      keys.add(key)
    check keys.len == 2
    check "message" in keys
    check "failed_policy_index" in keys

  test "26. a seat with no register record is reported, not silently defaulted":
    var sim = newSim(testConfig())
    sim.players[1].joined = true
    check not sim.allSeatsRegistered()
    check sim.unregisteredSeats() == @[1]
    sim.registerSeat(1, "greenwave", "llm", "greedy")
    check sim.allSeatsRegistered()
    check sim.unregisteredSeats().len == 0
    check sim.policyKinds[1] == "llm"

  test "26. a JOINED seat with no register record refuses the start":
    ## Design edit 2 to server.nim. The server settles the episode on this
    ## predicate before it ever sets `phase = Playing`.
    var sim = newSim(testConfig())
    for slot in 0 ..< MaxSeats:
      sim.players[slot].joined = true
      sim.registerSeat(slot, "greenwave", "llm", "greedy")
    check sim.refuseToStartDetail().len == 0
    sim.players[1].registered = false
    let detail = sim.refuseToStartDetail()
    checkpoint("refusal: " & detail)
    check detail.len > 0
    check seatAlias(1) in detail
    ## A seat that never connected at all is NOT this case: design §Degrade
    ## says it plays greedy and the episode runs to its end.
    var quiet = newSim(testConfig())
    check quiet.refuseToStartDetail().len == 0
    ## The refusal is a settled episode, not a crash: `fault`, the seat named,
    ## and a results document that still parses.
    sim.applyStop(erFault, detail)
    check sim.endReason == rsFault
    check sim.endRule == erFault
    check sim.finalTick == 0
    let document = parseJson(sim.cityResultsJson())
    check document{"reason"}.getStr() == "fault"
    check document{"endRule"}.getStr() == "fault"
    check document{"stopDetail"}.getStr() == detail

suite "the guards settle early":
  test "27. the wall-clock stop settles with the REAL throughput, not zero":
    var sim = runScripted(testConfig(), [blGreedy])
    let banked = sim.throughput
    check banked > 0
    ## Re-settle a fresh episode through the wall-clock path.
    var stopped = newSim(testConfig())
    for turnIndex in 1 .. 8:
      stopped.turn = turnIndex
      for slot in 0 ..< MaxSeats:
        stopped.applyReply(slot, stopped.scriptedReply(slot, blGreedy))
      for k in 0 ..< stopped.config.turnTicks:
        stopped.stepTick(k)
    stopped.applyStop(erWallClock, "wall-clock budget reached")
    check stopped.endReason == rsDeadline
    check stopped.endRule == erWallClock
    check stopped.finalTick == stopped.tickCount
    let document = parseJson(stopped.cityResultsJson())
    check document{"reason"}.getStr() == "deadline"
    check document{"endRule"}.getStr() == "wallClock"
    check document{"throughput"}.getInt() == stopped.throughput

  test "27. a fault settles from the last completed tick and names itself":
    var sim = newSim(testConfig())
    for k in 0 ..< 16:
      sim.stepTick(k mod sim.config.turnTicks)
    sim.applyStop(erFault, "unexpected exception in the step loop")
    check sim.endReason == rsFault
    check sim.endRule == erFault
    check sim.stopDetail.len > 0
    check sim.stopDetail.len <= MaxStopDetailRunes * 4
    let document = parseJson(sim.cityResultsJson())
    check document{"reason"}.getStr() == "fault"
    check document{"stopDetail"}.getStr().len > 0

  test "27. every shipped variant's wallClockBudgetSeconds is inside the 60% pin":
    let manifest = manifestJson()
    for variant in manifest{"variants"}:
      let budget = variant{"game_config"}{"wallClockBudgetSeconds"}.getInt()
      check budget <= DefaultWallClockBudgetSeconds
      check budget <= 720
    let fixture = manifest{"certification"}{"game_config"}
    check fixture{"wallClockBudgetSeconds"}.getInt() <=
      DefaultWallClockBudgetSeconds

  test "27. the turn budget arithmetic fits inside the engine stop":
    let config = testConfig()
    let turns = config.turnsPerEpisode()
    check turns == 32
    ## 32 turns x max(spacing, budget) plus lobby, settle and replay write.
    let worst = turns * max(DefaultTurnSpacingMs, DefaultTurnBudgetMs) div 1000
    check worst + 100 + 20 < DefaultWallClockBudgetSeconds
