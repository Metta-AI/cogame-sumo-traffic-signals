## The broadcast layer: `stepEvents` (the derived event stream), the chrome
## `buildStateJson`, and the roster/beat/lull plumbing. Forked from the
## starter's `src/ctf/broadcast.nim` — retargeted fields, same structure, so
## the inherited page's `renderClock` / `renderTransport` / `renderMomentum` /
## `ingestBeats` / `ingestLullSpans` keep working untouched.
##
## The derived events cost NO replay bytes and are identical live and in
## replay: they come from state deltas plus the sim's own tier-2 event list.
## A closed enum of FOURTEEN kinds plus `end`, and
## `tests/test_signals_events.nim` asserts the emitted set equals exactly
## that list.

import
  std/[json, strutils],
  sim, roster, rig_art

const
  BroadcastEventKinds*: array[15, string] = [
    "turn", "order", "say", "fallback", "phasechange", "starve",
    "spillback", "spillclear", "gridlock", "gridlockclear", "wave",
    "exit", "gatejam", "gateclear", "end"
  ]
    ## The CLOSED enum. Beats — the scrubber markers — are the five kinds
    ## `wave`, `spillback`, `gridlock`, `fallback` and `end`; the rest drive
    ## the feed, not the scrubber.
  BeatEventKinds*: array[5, string] = [
    "wave", "spillback", "gridlock", "fallback", "end"
  ]

type
  BroadcastTracker* = object
    eventCursor*: int
    lastTurn*: int
    lastOrders*: array[Intersections, string]
    lastRadio*: array[MaxSeats, string]
    lastGateJam*: array[Gates, bool]
    gateJamTick*: array[Gates, int]
    endSent*: bool
    pending*: seq[string]      ## records the caller injects this frame
                               ## (`fallback` / `budget_guard`): not derivable
                               ## from sim state.

proc initBroadcastTracker*(): BroadcastTracker =
  result.eventCursor = 0
  result.lastTurn = 0
  result.pending = @[]

proc resync*(tracker: var BroadcastTracker, sim: SimServer) =
  ## After a seek the tracker re-bases on the current state, so nothing
  ## phantoms and no stale delta is reported.
  tracker.eventCursor = sim.events.len
  tracker.lastTurn = sim.turn
  tracker.endSent = sim.phase == GameOver
  for at in 0 ..< Intersections:
    tracker.lastOrders[at] = orderText(sim.signals[at].order)
  for slot in 0 ..< MaxSeats:
    tracker.lastRadio[slot] = sim.radio[slot]
  for g in 0 ..< Gates:
    tracker.lastGateJam[g] = sim.gateJammed[g]
  tracker.pending = @[]

proc stepEvents*(
  sim: SimServer, tracker: var BroadcastTracker, events: JsonNode
) =
  ## Appends this frame's derived broadcast events.
  if events.isNil:
    return
  if sim.turn != tracker.lastTurn:
    tracker.lastTurn = sim.turn
    events.add(%*{"k": "turn", "n": sim.turn})
  for at in 0 ..< Intersections:
    let text = orderText(sim.signals[at].order)
    if text == tracker.lastOrders[at]:
      continue
    tracker.lastOrders[at] = text
    let order = sim.signals[at].order
    events.add(%*{
      "k": "order", "slot": ownerOf(at), "at": intersectionName(at),
      "verb": $order.verb, "phase": $order.phase, "delay": order.delay,
      "t": sim.tickCount})
  for slot in 0 ..< MaxSeats:
    if sim.radio[slot] == tracker.lastRadio[slot]:
      continue
    tracker.lastRadio[slot] = sim.radio[slot]
    if sim.radio[slot].len == 0:
      continue
    events.add(%*{
      "k": "say", "slot": slot, "text": sim.radio[slot], "t": sim.tickCount})
  for g in 0 ..< Gates:
    if sim.gateJammed[g] == tracker.lastGateJam[g]:
      continue
    tracker.lastGateJam[g] = sim.gateJammed[g]
    if sim.gateJammed[g]:
      tracker.gateJamTick[g] = sim.tickCount
      events.add(%*{
        "k": "gatejam", "gate": sim.city.gates[g].name,
        "at": intersectionName(sim.city.gates[g].intersection),
        "slot": ownerOf(sim.city.gates[g].intersection), "t": sim.tickCount})
    else:
      events.add(%*{
        "k": "gateclear", "gate": sim.city.gates[g].name,
        "ticks": max(0, sim.tickCount - tracker.gateJamTick[g]),
        "t": sim.tickCount})
  while tracker.eventCursor < sim.events.len:
    let event = sim.events[tracker.eventCursor]
    inc tracker.eventCursor
    case event.kind
    of sePhaseChange:
      events.add(%*{
        "k": "phasechange", "at": intersectionName(event.at),
        "slot": event.slot, "from": $PhaseId(event.a), "to": $PhaseId(event.b),
        "t": event.tick})
    of seStarve:
      events.add(%*{
        "k": "starve", "at": intersectionName(event.at), "slot": event.slot,
        "approach": $Approach(event.a), "t": event.tick})
    of seSpillback:
      events.add(%*{
        "k": "spillback", "link": sim.city.links[event.link].name,
        "at": intersectionName(max(0, event.at)), "slot": event.slot,
        "t": event.tick})
    of seSpillClear:
      events.add(%*{
        "k": "spillclear", "link": sim.city.links[event.link].name,
        "ticks": event.a, "t": event.tick})
    of seGridlock:
      var links = newJArray()
      var ats = newJArray()
      for link in sim.activeGridlock:
        links.add(%sim.city.links[link].name)
        if sim.city.links[link].downstream >= 0:
          ats.add(%intersectionName(sim.city.links[link].downstream))
      events.add(%*{
        "k": "gridlock", "links": links, "ats": ats, "t": event.tick})
    of seGridlockClear:
      var links = newJArray()
      links.add(%sim.city.links[event.link].name)
      events.add(%*{
        "k": "gridlockclear", "links": links, "ticks": event.a,
        "t": event.tick})
    of seWave:
      var ats = newJArray()
      for at in corridorIntersections(event.a):
        ats.add(%intersectionName(at))
      events.add(%*{
        "k": "wave", "corridor": corridorLabel(event.a),
        "dir": corridorDirText(event.a), "ats": ats, "vehicles": event.b,
        "t": event.tick})
    of seExit:
      events.add(%*{
        "k": "exit", "gate": sim.city.gates[max(0, event.gate)].name,
        "travel": event.a, "stops": event.b, "total": sim.throughput,
        "t": event.tick})
    else:
      discard
  for record in tracker.pending:
    if record.len == 0 or record[0] != '{':
      continue
    try:
      let node = parseJson(record)
      if node{"k"}.getStr() != "fallback":
        continue
      events.add(%*{
        "k": "fallback", "slot": node{"slot"}.getInt(),
        "cause": node{"cause"}.getStr(), "t": sim.tickCount})
    except CatchableError:
      discard
  tracker.pending = @[]
  if sim.phase == GameOver and not tracker.endSent:
    tracker.endSent = true
    events.add(%*{
      "k": "end", "reason": $sim.endReason, "endRule": $sim.endRule,
      "throughput": sim.throughput, "par": sim.config.parThroughput,
      "demand": sim.demandGenerated})

# ---------------------------------------------------------------------------
#  The chrome frame
# ---------------------------------------------------------------------------

proc seatStateJson(sim: SimServer, slot: int): JsonNode =
  var policies = newJArray()
  policies.add(%sim.players[slot].name)
  %*{
    "lives": sim.served[slot],       # the classic chrome's big numeral slot
    "policies": policies,
    "alias": sim.players[slot].alias,
    "quad": sim.players[slot].quadrant,
    "served": sim.served[slot],
    "wait": sim.seatWaitTicks[slot],
    "changes": sim.phaseChanges[slot],
    "fb": sim.fallbackTurns[slot],
    "llm": sim.llmTurns[slot],
    "kind": sim.policyKinds[slot],
    "dead": sim.deadSeats[slot]
  }

proc corridorTallyJson(sim: SimServer): JsonNode =
  ## Eight tiny bars, one per arterial, labelled A B C D 1 2 3 4, each showing
  ## the corridor's current phase pattern as four coloured pips — a miniature
  ## time-space diagram, so a spectator can see an offset being set up before
  ## the wave happens.
  result = newJArray()
  for bucket in countup(0, 14, 2):
    var pips = newJArray()
    for at in corridorIntersections(bucket):
      pips.add(%sim.phaseText(at))
    result.add(%*{
      "label": corridorLabel(bucket),
      "axis": (if bucket < 8: "row" else: "col"),
      "pips": pips,
      ## The corridor's waves SO FAR, both directions. It used to read
      ## `waveTicks`, the in-window credit list, which `creditCorridor`
      ## clears the moment a wave fires — so the bar dropped to zero at
      ## exactly the moment the note says it increments.
      "waves": sim.waveCounts[bucket] + sim.waveCounts[bucket + 1]
    })

proc buildStateJson*(
  sim: SimServer,
  events: JsonNode,
  playing: bool,
  speed: int,
  maxTick: int,
  looping: bool,
  transportEnabled: bool,
  mismatchTick: int,
  startTick: int = 0,
  endHoldSeconds: int = 0,
  skipLulls: bool = false,
  fastForwarding: bool = false,
  lullSpans: seq[array[2, int]] = @[],
  cityBeats: JsonNode = nil,
  leadSeries: seq[seq[int]] = @[]
): string =
  ## Assembles the broadcast chrome frame. Board-derived STATE (roster, seat
  ## figures, phases, queues) is ALWAYS present, so a frame reached by a seek
  ## still hydrates the scorebug and the endcard with no events.
  var teams = newJObject()
  for slot in 0 ..< MaxSeats:
    teams[seatColour(slot)] = sim.seatStateJson(slot)

  var state = %*{
    "t": sim.tickCount,
    "mt": sim.effectiveMaxTicks(),
    "ph": ($sim.phase).toLowerAscii,
    "lob": sim.lobbyStartSecondsRemaining(),
    "pl": playing,
    "sp": speed,
    "mx": maxTick,
    "st": startTick,
    "lp": looping,
    "sk": skipLulls,
    "ff": fastForwarding,
    "en": transportEnabled,
    "mm": mismatchTick,
    "bs": 1,
    "pov": -1,
    "teams": teams,
    "roster": sim.rosterJson(),
    "events": (if events.isNil: newJArray() else: events),
    # `city` is the field the appended game block latches SIG_MODE on: a
    # classic paintbot frame never carries it.
    "city": {
      "rows": Rows, "cols": Cols, "cell": CellPx,
      "w": BoardCellsWide, "h": BoardCellsHigh
    },
    "turn": sim.turn,
    "turns": sim.turnsPerEpisode(),
    "turnTicks": sim.config.turnTicks,
    "through": sim.throughput,
    "par": sim.config.parThroughput,
    "demand": sim.demandGenerated,
    "rejected": sim.rejected,
    "waiting": sim.networkWaitTicks,
    "waves": sim.greenWaves,
    "spills": sim.spillbacks,
    "gridlocks": sim.gridlocks,
    "gridlockTicks": sim.gridlockTicks,
    "starves": sim.starvations,
    "deferred": sim.deferredSwitches,
    "travel": sim.travelTicksTotal,
    "stops": sim.stopsTotal,
    "spill": sim.activeSpillbackNames(3),
    "ring": sim.activeGridlockNames(),
    "ringTicks": sim.gridlockRun,
    "tally": sim.corridorTallyJson()
  }

  if lullSpans.len > 0:
    var spans = newJArray()
    for span in lullSpans:
      spans.add(%*[span[0], span[1]])
    state["lulls"] = spans
  if not cityBeats.isNil and cityBeats.len > 0:
    state["citybeats"] = cityBeats
  if leadSeries.len > 0:
    ## The whole-episode series, shipped ONCE per viewer, so the throughput
    ## sparkline draws at full width on the first frame instead of growing in.
    var teamNames = newJArray()
    for slot in 0 ..< MaxSeats:
      teamNames.add(%seatColour(slot))
    var pts = newJArray()
    for point in leadSeries:
      var row = newJArray()
      for value in point:
        row.add(%value)
      pts.add(row)
    state["lead"] = %*{"teams": teamNames, "pts": pts}

  if sim.phase == GameOver:
    var overTeams = newJObject()
    for slot in 0 ..< MaxSeats:
      overTeams[seatColour(slot)] = %*{
        "lives": sim.served[slot],
        "served": sim.served[slot],
        "wait": sim.seatWaitTicks[slot],
        "changes": sim.phaseChanges[slot],
        "score": sim.scoreOf(slot)
      }
    state["over"] = %*{
      "winner": "",
      "draw": false,
      "timeLimit": sim.endRule == erFullPeriod,
      "teams": overTeams,
      "reason": $sim.endReason,
      "endRule": $sim.endRule,
      "through": sim.throughput,
      "par": sim.config.parThroughput,
      "demand": sim.demandGenerated,
      "rejected": sim.rejected,
      "waiting": sim.networkWaitTicks,
      "waves": sim.greenWaves,
      "spills": sim.spillbacks,
      "gridlocks": sim.gridlocks,
      "score": sim.scoreOf(0),
      "met": sim.winFor()
    }
    if endHoldSeconds > 0:
      state["hold"] = %endHoldSeconds
  $state

proc leadSeriesFrom*(
  exits, rejects: openArray[int], stride: int
): seq[seq[int]] =
  ## Cumulative cars-out and cars-rejected, sampled every `stride` ticks, in
  ## the shape the inherited momentum renderer expects: `[tick, v0, v1, ...]`.
  var tick = 0
  while tick < exits.len:
    let out0 = exits[tick]
    let rej = (if tick < rejects.len: rejects[tick] else: 0)
    result.add(@[tick, out0, rej, out0, rej])
    tick += max(1, stride)
  if exits.len > 0 and (result.len == 0 or result[^1][0] != exits.len - 1):
    let last = exits.len - 1
    result.add(@[last, exits[last],
                 (if last < rejects.len: rejects[last] else: 0),
                 exits[last], (if last < rejects.len: rejects[last] else: 0)])
