## The derived broadcast events are a CLOSED enum, and the tier-2 stream keeps
## its mandatory trailing summary row. Test 42 of the design note's list.

import std/[json, strutils, unittest]
import helpers
import signals/[broadcast, events]

suite "events are the closed enum":
  test "42. the broadcast enum is exactly the fifteen kinds":
    var wanted = @["turn", "order", "say", "fallback", "phasechange", "starve",
                   "spillback", "spillclear", "gridlock", "gridlockclear",
                   "wave", "exit", "gatejam", "gateclear", "end"]
    var declared: seq[string]
    for kind in BroadcastEventKinds:
      declared.add(kind)
    check declared.len == 15
    for kind in wanted:
      check kind in declared
    for kind in declared:
      check kind in wanted

  test "42. the beats are exactly the five scrubber kinds":
    var beats: seq[string]
    for kind in BeatEventKinds:
      beats.add(kind)
    check beats == @["wave", "spillback", "gridlock", "fallback", "end"]
    for kind in beats:
      check kind in BroadcastEventKinds

  test "42. every kind the appended game block handles is in the enum":
    let page = repoFile("client/replay_broadcast.html")
    let banner = page.find(
      "sumo-traffic-signals additions to the inherited coworld-ctf chrome")
    check banner > 0
    let block0 = page[banner .. ^1]
    var handled: seq[string]
    for line in block0.splitLines():
      let text = line.strip()
      if not text.startsWith("case '"):
        continue
      let close = text.find('\'', 6)
      if close > 6:
        handled.add(text[6 ..< close])
    checkpoint("handled: " & handled.join(","))
    check handled.len >= 10
    for kind in handled:
      checkpoint("game block handles " & kind)
      check kind in BroadcastEventKinds

  test "42. a real episode emits only kinds from the enum":
    ## Derive the whole episode's events from the state deltas, exactly as the
    ## viewer does during playback.
    var replay = newSim(testConfig("rushhour"))
    var derived = initBroadcastTracker()
    derived.resync(replay)
    let events = newJArray()
    for turnIndex in 1 .. replay.turnsPerEpisode():
      if replay.settled:
        break
      replay.turn = turnIndex
      for slot in 0 ..< MaxSeats:
        let baseline = (if slot mod 2 == 0: blGreedy else: blFixedCycle)
        replay.applyReply(slot, replay.scriptedReply(slot, baseline))
      for k in 0 ..< replay.config.turnTicks:
        if replay.settled:
          break
        replay.stepTick(k)
      replay.stepEvents(derived, events)
    check events.len > 0
    var seen: seq[string]
    for event in events:
      let kind = event{"k"}.getStr()
      if kind notin seen:
        seen.add(kind)
      checkpoint("emitted kind " & kind)
      check kind in BroadcastEventKinds
    checkpoint("emitted: " & seen.join(","))
    ## A real episode must produce the story kinds, not just `turn`.
    check "order" in seen
    check "phasechange" in seen
    check "exit" in seen

  test "42. the tier-2 stream keeps its mandatory trailing summary row":
    let sim = runScripted(testConfig(), [blGreedy])
    let stream = eventsJsonl(sim.events, sim.finalTick)
    let lines = stream.strip().splitLines()
    check lines.len >= 2
    let summary = parseJson(lines[^1])
    check summary{"type"}.getStr() == "summary"
    check summary{"ticks"}.getInt() == sim.finalTick
    check summary{"events"}.getInt() == sim.events.len
    check summary{"gameVersion"}.getStr() == GameVersion
    ## Every row parses and names a kind from the tier-2 vocabulary.
    var vocabulary: seq[string]
    for kind in allEventKinds():
      vocabulary.add(kind)
    for i in 0 ..< lines.len - 1:
      let row = parseJson(lines[i])
      check row{"type"}.getStr() in vocabulary
      check row.hasKey("tick")

  test "42. the tier-2 vocabulary is the design note's reduced set":
    var wanted = @["spawn", "enter", "reject", "cross", "exit", "phasechange",
                   "starve", "spillback", "spillclear", "gridlock",
                   "gridlockclear", "wave", "turnstart", "directive",
                   "fallback", "phasechangedeferred"]
    let declared = allEventKinds()
    check declared.len == wanted.len
    for kind in wanted:
      check kind in declared
