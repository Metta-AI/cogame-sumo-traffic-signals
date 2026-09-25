## The simulation: the step loop of design §Turn and tick structure exactly as
## numbered, `gameHash`, the end evaluation, and the per-seat observation
## builder. Imports and re-exports the sim modules the way the starter's
## `src/ctf/sim.nim` does, so `import signals/sim` sees everything.
##
## ALL SIM ARITHMETIC IS INTEGER. There is no floating point in this module,
## `city`, `vehicles`, `phases`, `flow`, `driver` or `baselines`, and
## `tests/test_signals_sim.nim` greps for it. Means (travel time, stops per
## car) are not computed here at all: `results` carries the integer totals and
## the viewer divides. That is what makes the native <-> wasm hash chain exact
## by construction.

import
  std/[algorithm, json, strutils]

import
  sim_types, city, sim_config, sim_state, vehicles, phases, flow, driver,
  baselines, directives, events

export
  sim_types, city, sim_config, sim_state, vehicles, phases, flow, driver,
  baselines, directives, events

# ---------------------------------------------------------------------------
#  The integrity chain
# ---------------------------------------------------------------------------

proc mixTick*(sim: var SimServer) =
  ## Tick step 12. The mix ORDER below is the wire format: one divergent bit
  ## between the native game and the wasm viewer is caught at the tick it
  ## happens and surfaced as `mismatchTick` in `#mmwarn`.
  var hash = sim.hashValue
  for at in 0 ..< Intersections:
    let signal = sim.signals[at]
    hash.mixHash(ord(signal.phase))
    hash.mixHash(signal.clearLeft)
    hash.mixHash(signal.ticksInPhase)
    hash.mixHash(ord(signal.requested))
    hash.mixHash(ord(signal.order.verb))
    hash.mixHash(ord(signal.order.phase))
    hash.mixHash(signal.order.delay)
  for link in sim.city.links:
    var mask = 0
    for i in 0 ..< link.cells:
      if sim.occupantAt(link.index, i) >= 0:
        mask = mask or (1 shl i)
    hash.mixHash(mask)
    hash.mixHash(sim.linkQueueLen[link.index])
  for id in 0 ..< sim.cars.len:
    if not sim.cars[id].active:
      continue
    hash.mixHash(sim.cars[id].link + 1)
    hash.mixHash(sim.cars[id].cell)
    hash.mixHash(sim.cars[id].waitTicks)
    hash.mixHash(sim.cars[id].cleanCrossings)
    hash.mixHash(sim.cars[id].blockedByPhaseTicks)
  hash.mixHash(sim.throughput)
  hash.mixHash(sim.rejected)
  hash.mixHash(sim.demandGenerated)
  hash.mixHash(sim.networkWaitTicks)
  for slot in 0 ..< MaxSeats:
    hash.mixHash(sim.seatWaitTicks[slot])
  hash.mixHash(sim.greenWaves)
  var spill = sim.activeSpillback
  spill.sort()
  for link in spill:
    hash.mixHash(link)
  var ring = sim.activeGridlock
  ring.sort()
  for link in ring:
    hash.mixHash(link)
  hash.mixHash(sim.tickCount)
  sim.hashValue = hash

# ---------------------------------------------------------------------------
#  Scoring and settling
# ---------------------------------------------------------------------------

proc netWaitK*(sim: SimServer): int = netWaitKOf(sim.networkWaitTicks)

proc seatWaitK*(sim: SimServer, slot: int): int =
  seatWaitKOf(sim.seatWaitTicks[slot])

proc scoreOf*(sim: SimServer, slot: int): int =
  ## `1_000_000 * throughput - 1_000 * netWaitK - 10 * seatWaitK[s]`. The
  ## ordering is strictly lexicographic: one extra car through is worth more
  ## than the largest possible total penalty.
  scoreFor(sim.throughput, sim.netWaitK(), sim.seatWaitK(slot))

proc winFor*(sim: SimServer): bool =
  ## The same boolean for all four seats: a "did the city work" flag, not a
  ## duel.
  sim.throughput >= sim.config.parThroughput

proc applyStop*(sim: var SimServer, endRule: EndRule, detail: string) =
  ## THE load-bearing stop record. A wall-clock or fault fact cannot be
  ## re-derived from sim state, so the stop is written as ONE record applied
  ## by THIS proc both on record and on playback (the particle-worlds
  ## 2026-08-26 scar: otherwise every deadline-ended replay hash-mismatches at
  ## the stop tick).
  if sim.settled:
    return
  sim.settled = true
  sim.phase = GameOver
  sim.endRule = endRule
  sim.finalTick = sim.tickCount
  sim.turnsPlayed = sim.turn
  sim.stopDetail = detail.truncateRunes(MaxStopDetailRunes)
  sim.endReason =
    case endRule
    of erWallClock: rsDeadline
    of erFault: rsFault
    else: rsComplete
  sim.gameOverHold = sim.config.gameOverTicks

proc evaluateEnd*(sim: var SimServer): bool =
  ## Tick step 13. The episode ends at the FIRST of: cleared, gridlock stall,
  ## or the tick cap. (The wall-clock stop is the server's, through
  ## `applyStop`.) Returns true when the episode settled on this tick.
  if sim.settled:
    return false
  if sim.tickCount >= sim.config.demandEndTick and sim.cityEmpty():
    sim.applyStop(erCleared, "")
    return true
  if sim.stallTicks >= sim.config.gridlockStallTicks:
    sim.applyStop(erGridlock, "")
    return true
  if sim.tickCount >= sim.config.maxTicks:
    sim.applyStop(erFullPeriod, "")
    return true
  false

# ---------------------------------------------------------------------------
#  The tick
# ---------------------------------------------------------------------------

proc stepTick*(sim: var SimServer, tickInTurn: int) =
  ## The whole physics of the game, in the design note's numbered order.
  ## NOTHING ELSE mutates the world during play.
  if sim.settled:
    return
  inc sim.tickCount                                            # 1
  sim.rollMovedFlags()
  let canDischarge = sim.stepSignals(tickInTurn)               # 2
  sim.dischargeStopLines(canDischarge)                         # 3
  sim.advanceLinks()                                           # 4
  let exitsBefore = sim.throughput
  sim.drainExits()                                             # 5
  sim.admitGateQueues()                                        # 6
  sim.spawnDemand()                                            # 7
  sim.accountWaits()                                           # 8
  sim.measureFlow()                                            # 9
  sim.detectGridlock()                                         # 10
  # 11 (green waves) is credited inside step 3, at the crossing that earns it.
  var moved = false
  for id in 0 ..< sim.cars.len:
    if sim.cars[id].active and sim.cars[id].movedThisTick:
      moved = true
      break
  if sim.throughput == exitsBefore and not moved:
    inc sim.stallTicks
  else:
    sim.stallTicks = 0
  sim.mixTick()                                                # 12
  discard sim.evaluateEnd()                                    # 13

proc stepTurnTicks*(sim: var SimServer): int =
  ## Runs one command turn's worth of ticks. Returns how many ran — fewer than
  ## `turnTicks` when the episode settled inside the turn.
  for k in 0 ..< sim.config.turnTicks:
    if sim.settled:
      break
    sim.stepTick(k)
    inc result

# ---------------------------------------------------------------------------
#  Orders
# ---------------------------------------------------------------------------

proc previousOrders*(sim: SimServer, slot: int): seq[SignalOrder] =
  for at in quadrantIntersections(slot):
    result.add(sim.signals[at].order)

proc applyReply*(sim: var SimServer, slot: int, reply: ControllerReply) =
  ## Design step 5. Orders are applied in ascending slot, then in ascending
  ## intersection index within a slot. An intersection named in the reply takes
  ## the new order; an intersection NOT named keeps the order it had; an order
  ## whose fields do not validate was already repaired to that intersection's
  ## previous order by the validator — never dropped into "no order".
  sim.ordersRejected[slot] += reply.rejected
  for at in quadrantIntersections(slot):
    var found = -1
    for i, order in reply.orders:
      if order.at == at:
        found = i
        break
    if found < 0:
      inc sim.orderAgeTurns[at]
      continue
    sim.signals[at].order = reply.orders[found].toSignalOrder(sim.turn)
    sim.orderAgeTurns[at] = 0
    if reply.orders[found].repaired:
      sim.lastResult[at] = orRepaired
    else:
      sim.lastResult[at] = orUnknown
  sim.radio[slot] = reply.say
  sim.notes[slot] = reply.notes

# ---------------------------------------------------------------------------
#  The per-seat observation
# ---------------------------------------------------------------------------

proc cityBlockJson*(sim: SimServer): JsonNode =
  ## The static city, sent once at registration and referred to by id
  ## afterwards.
  var rows = newJArray()
  for name in RowNames:
    rows.add(%name)
  var cols = newJArray()
  for name in ColNames:
    cols.add(%parseInt(name))
  var quadrants = newJObject()
  for slot in 0 ..< MaxSeats:
    var ids = newJArray()
    for at in quadrantIntersections(slot):
      ids.add(%intersectionName(at))
    quadrants[seatAlias(slot)] = ids
  %*{
    "rows": rows,
    "cols": cols,
    "quadrants": quadrants,
    "link_cells": {
      "ew": sim.config.ewLinkCells,
      "ns": sim.config.nsLinkCells,
      "ew_gate": sim.config.ewGateCells,
      "ns_gate": sim.config.nsGateCells
    },
    "gate_queue_cap": sim.config.gateQueueCap,
    "phases": {
      "NSG": "N,S through+right",
      "NSL": "N,S left",
      "EWG": "E,W through+right",
      "EWL": "E,W left"
    },
    "min_green": sim.config.minGreenTicks,
    "clearance": sim.config.clearTicks,
    "max_red": sim.config.maxRedTicks,
    "turn_ticks": sim.config.turnTicks,
    "max_ticks": sim.config.maxTicks,
    "demand_ends_tick": sim.config.demandEndTick,
    "par": sim.config.parThroughput
  }

proc blockCauseOf(sim: SimServer, at: int, approach: Approach): BlockCause =
  let link = sim.city.inbound[at][ord(approach)]
  if link < 0:
    return bcNone
  let car = sim.stopLineCar(link)
  if car < 0:
    return bcNone
  if sim.cars[car].blockedByPhaseTicks > 0:
    return bcPhase
  if sim.cars[car].spillbackBlockedTicks > 0:
    return bcSpillback
  bcNone

proc blockedTicksOf(sim: SimServer, at: int, approach: Approach): int =
  let link = sim.city.inbound[at][ord(approach)]
  if link < 0:
    return 0
  let car = sim.stopLineCar(link)
  if car < 0:
    return 0
  max(sim.cars[car].blockedByPhaseTicks, sim.cars[car].spillbackBlockedTicks)

proc inboundPlatoonJson(sim: SimServer, at: int): JsonNode =
  ## Per approach, how many cars are on the link and how many ticks until the
  ## nearest reaches the stop line.
  result = newJArray()
  for approach in ApproachOrder:
    let link = sim.city.inbound[at][ord(approach)]
    if link < 0:
      continue
    let cells = sim.city.links[link].cells
    var
      cars = 0
      nearest = -1
    for i in 0 ..< cells:
      let car = sim.occupantAt(link, i)
      if car < 0:
        continue
      inc cars
      let ticks = cells - 1 - i
      if nearest < 0 or ticks < nearest:
        nearest = ticks
    if cars == 0:
      continue
    result.add(%*{
      "from": $approach, "cars": cars, "nearest_ticks": max(0, nearest)})

proc observationJson*(sim: SimServer, slot, turn: int): JsonNode =
  ## Everything this seat may legitimately know. DETECTORS ARE PUBLIC; PLANS
  ## ARE PRIVATE — a real traffic-management centre sees every loop detector
  ## and every signal's current state, and does not see another operator's
  ## intended offsets. No other seat's orders, notes, statistics or REAL
  ## PLAYER NAME is ever in here.
  var controllers = newJArray()
  for s in 0 ..< MaxSeats:
    controllers.add(%seatAlias(s))

  var yourSignals = newJArray()
  for at in quadrantIntersections(slot):
    var approaches = newJArray()
    for approach in ApproachOrder:
      let link = sim.city.inbound[at][ord(approach)]
      let movement = sim.stopLineMovement(at, approach)
      let cause = sim.blockCauseOf(at, approach)
      approaches.add(%*{
        "from": $approach,
        "queue": (if link < 0: 0 else: sim.linkQueueLen[link]),
        "link_full": (if link < 0: false else: sim.linkFull[link]),
        "stop_line": (if movement == mvNone: newJNull() else: %($movement)),
        "blocked_ticks": sim.blockedTicksOf(at, approach),
        "cause": (if cause == bcNone: newJNull() else: %($cause))
      })
    var exits = newJArray()
    for dir in ApproachOrder:
      let link = sim.city.outbound[at][ord(dir)]
      if link < 0:
        continue
      let
        head = sim.city.links[link].toNode
        capacity = sim.city.links[link].cells
      exits.add(%*{
        "to": nodeName(head),
        "owner": (if head < Intersections: %seatAlias(ownerOf(head))
                  else: newJNull()),
        "occupancy": sim.linkOccupancy(link),
        "capacity": capacity,
        "full": sim.linkFull[link]
      })
    yourSignals.add(%*{
      "at": intersectionName(at),
      "phase": sim.phaseText(at),
      "current_phase": $sim.signals[at].phase,
      "ticks_in_phase": sim.signals[at].ticksInPhase,
      "order": orderText(sim.signals[at].order),
      "order_age_turns": sim.orderAgeTurns[at],
      "last_order_result": $sim.lastResult[at],
      "approaches": approaches,
      "exits": exits,
      "inbound": sim.inboundPlatoonJson(at)
    })

  var detectors = newJArray()
  for at in 0 ..< Intersections:
    var queues = newJObject()
    for approach in ApproachOrder:
      queues[$approach] = %sim.approachQueue(at, approach)
    detectors.add(%*{
      "at": intersectionName(at),
      "by": seatAlias(ownerOf(at)),
      "phase": sim.phaseText(at),
      "ticks_in_phase": sim.signals[at].ticksInPhase,
      "q": queues
    })

  var radio = newJArray()
  for s in 0 ..< MaxSeats:
    if radio.len >= MaxRadioLines:
      break
    if s == slot or sim.radio[s].len == 0:
      continue
    radio.add(%*{"from": seatAlias(s), "text": sim.radio[s]})

  var spillback = newJArray()
  for name in sim.activeSpillbackNames(6):
    spillback.add(%name)
  var gridlock = newJArray()
  for name in sim.activeGridlockNames():
    gridlock.add(%name)

  result = %*{
    "slot": slot,
    "you": seatAlias(slot),
    "controllers": controllers,
    "your_quadrant": seatQuadrant(slot),
    "turn": turn,
    "of": sim.turnsPerEpisode(),
    "tick": sim.tickCount,
    "turn_ticks": sim.config.turnTicks,
    "green_cap": sim.config.greenCap,
    "switch_margin": sim.config.switchMargin,
    "ticks_left": max(0, sim.config.maxTicks - sim.tickCount),
    "city": sim.cityBlockJson(),
    "your_signals": yourSignals,
    "detectors": detectors,
    "radio": radio,
    "network_status": {
      "throughput": sim.throughput,
      "demand": sim.demandGenerated,
      "rejected": sim.rejected,
      "wait_ticks": sim.networkWaitTicks,
      "your_wait_ticks": sim.seatWaitTicks[slot],
      "spillback": spillback,
      "gridlock": gridlock,
      "waves": sim.greenWaves
    }
  }
  result["your_notes"] =
    if sim.notes[slot].len > 0: %sim.notes[slot] else: newJNull()

proc observationForReplay*(sim: SimServer, slot, turn: int): JsonNode =
  ## The observation MINUS `your_notes`, mirrored into the replay's
  ## `directive` record so the replay explains every decision.
  result = sim.observationJson(slot, turn)
  if result.hasKey("your_notes"):
    result.delete("your_notes")

# ---------------------------------------------------------------------------
#  Diagnostics the server and the tests share
# ---------------------------------------------------------------------------

proc identitiesText*(sim: SimServer): string =
  var parts: seq[string]
  for slot in 0 ..< MaxSeats:
    parts.add(seatAlias(slot) & "=" & sim.players[slot].name)
  parts.join(" ")
