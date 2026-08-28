## The signal machine: the phase enum's permitted-movement table lives in
## `sim_types`, and this module is tick step 2 — `ticksInPhase`, `clearLeft`,
## requested versus current, the deferral, and the starvation override.
##
## No order can produce an illegal signal state, because `minGreenTicks`, the
## all-red clearance and the override are enforced HERE and nowhere else.

import
  sim_types, city, sim_state, vehicles, flow, driver, events

proc starvedApproach*(sim: SimServer, intersection: int): Approach =
  ## The lowest-index approach (fixed order N, E, S, W) whose stop-line car
  ## has been forbidden by the phase for `maxRedTicks` consecutive ticks, or
  ## `apN` with `false` from the caller's `found` check. A car blocked by
  ## SPILLBACK never triggers this: only `blockedByPhaseTicks` counts.
  result = apN
  for approach in ApproachOrder:
    let link = sim.city.inbound[intersection][ord(approach)]
    if link < 0:
      continue
    let car = sim.stopLineCar(link)
    if car < 0:
      continue
    if sim.cars[car].blockedByPhaseTicks >= sim.config.maxRedTicks:
      return approach
  result = apN

proc hasStarvedApproach*(sim: SimServer, intersection: int): bool =
  for approach in ApproachOrder:
    let link = sim.city.inbound[intersection][ord(approach)]
    if link < 0:
      continue
    let car = sim.stopLineCar(link)
    if car < 0:
      continue
    if sim.cars[car].blockedByPhaseTicks >= sim.config.maxRedTicks:
      return true
  false

proc stepSignals*(
  sim: var SimServer, tickInTurn: int
): array[Intersections, bool] =
  ## Tick step 2, for each intersection in ASCENDING index. Returns, per
  ## intersection, whether its approaches may discharge this tick — false
  ## during clearance and on the tick a change is entered.
  for at in 0 ..< Intersections:
    inc sim.signals[at].ticksInPhase
    var requested = sim.requestedPhase(at, tickInTurn)

    # Step 2e, evaluated on the REQUEST: a stop-line car the phase has
    # forbidden for maxRedTicks forces the phase that serves it. The override
    # is physics, not a penalty; the seat sees it next turn as "overridden".
    if sim.signals[at].overrideLeft > 0:
      dec sim.signals[at].overrideLeft
      requested = sim.signals[at].overridePhase
      sim.lastResult[at] = orOverridden
    elif sim.hasStarvedApproach(at):
      let
        approach = sim.starvedApproach(at)
        link = sim.city.inbound[at][ord(approach)]
        car = (if link >= 0: sim.stopLineCar(link) else: -1)
        movement = (if car >= 0: sim.movementOf(car) else: mvThrough)
      requested = phaseServing(approach, movement)
      sim.signals[at].overridePhase = requested
      sim.signals[at].overrideLeft = sim.config.minGreenTicks
      sim.lastResult[at] = orOverridden
      inc sim.starvations
      sim.emitEvent(initSimEvent(
        seStarve, sim.tickCount, slot = ownerOf(at), at = at,
        a = ord(approach), text = $requested))

    sim.signals[at].requested = requested

    # Step 2c: a change that clears minGreenTicks ENTERS clearance now, and
    # the clearance is then served by the block below on this same tick, so a
    # change costs exactly `clearTicks` of all-red with no discharge.
    if sim.signals[at].clearLeft == 0 and
        requested != sim.signals[at].phase and
        sim.signals[at].ticksInPhase >= sim.config.minGreenTicks:
      if sim.config.clearTicks == 0:
        let from0 = sim.signals[at].phase
        sim.signals[at].phase = requested
        sim.signals[at].ticksInPhase = 0
        inc sim.phaseChanges[ownerOf(at)]
        sim.emitEvent(initSimEvent(
          sePhaseChange, sim.tickCount, slot = ownerOf(at), at = at,
          a = ord(from0), b = ord(requested)))
        result[at] = false
        continue
      sim.signals[at].clearLeft = sim.config.clearTicks

    if sim.signals[at].clearLeft > 0:
      # Step 2b: in clearance. No approach discharges this tick; the phase
      # commits on the tick the counter reaches zero.
      dec sim.signals[at].clearLeft
      if sim.signals[at].clearLeft == 0:
        let from0 = sim.signals[at].phase
        sim.signals[at].phase = requested
        sim.signals[at].ticksInPhase = 0
        inc sim.phaseChanges[ownerOf(at)]
        sim.emitEvent(initSimEvent(
          sePhaseChange, sim.tickCount, slot = ownerOf(at), at = at,
          a = ord(from0), b = ord(requested)))
      result[at] = false
    elif requested != sim.signals[at].phase:
      # Step 2d: the request is DEFERRED — kept and retried next tick, never
      # dropped.
      inc sim.deferredSwitches
      if sim.lastResult[at] != orOverridden:
        sim.lastResult[at] = orDeferred
      sim.emitEvent(initSimEvent(
        sePhaseChangeDeferred, sim.tickCount, slot = ownerOf(at), at = at,
        a = ord(requested)))
      result[at] = true
    else:
      if sim.lastResult[at] != orOverridden and
          sim.lastResult[at] != orRepaired:
        sim.lastResult[at] = orRan
      result[at] = true

proc dischargeStopLines*(
  sim: var SimServer, canDischarge: array[Intersections, bool]
) =
  ## Tick step 3. For each intersection in ascending index, for each approach
  ## in the fixed order N, E, S, W: at most ONE car per approach per tick
  ## (single lane, saturation flow 1 car/s/lane), and since a phase greens two
  ## approaches, at most TWO cars cross an intersection per tick.
  for at in 0 ..< Intersections:
    if not canDischarge[at]:
      continue
    let phase = sim.signals[at].phase
    for approach in ApproachOrder:
      let link = sim.city.inbound[at][ord(approach)]
      if link < 0:
        continue
      let car = sim.stopLineCar(link)
      if car < 0:
        continue
      let movement = sim.movementOf(car)
      if not phasePermits(phase, approach, movement):
        inc sim.cars[car].blockedByPhaseTicks
        continue
      let nextLink = sim.nextLinkFor(car)
      if nextLink < 0:
        continue
      if sim.occupantAt(nextLink, 0) >= 0:
        # The move is REFUSED: the block ahead is full, so the car at the stop
        # line cannot move even on green. This is the whole game.
        inc sim.cars[car].spillbackBlockedTicks
        continue
      sim.setOccupant(link, sim.city.links[link].cells - 1, -1)
      sim.setOccupant(nextLink, 0, car)
      sim.cars[car].link = nextLink
      sim.cars[car].cell = 0
      sim.cars[car].movedThisTick = true
      sim.cars[car].blockedByPhaseTicks = 0
      inc sim.cars[car].crossings
      inc sim.crossings
      if sim.cars[car].waitSinceLastCrossing == 0:
        inc sim.cars[car].cleanCrossings
      else:
        sim.cars[car].cleanCrossings = 1
      sim.cars[car].waitSinceLastCrossing = 0
      if not sim.cars[car].progressed and
          sim.cars[car].cleanCrossings >= sim.config.waveCrossings:
        # Tick step 11: the car is credited as PROGRESSED for its corridor,
        # once and once only.
        sim.cars[car].progressed = true
        sim.creditCorridor(car, nextLink)
      sim.emitEvent(initSimEvent(
        seCross, sim.tickCount, slot = ownerOf(at), at = at, link = nextLink,
        a = ord(movement)))
