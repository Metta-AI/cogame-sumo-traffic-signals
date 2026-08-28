## Cars: the fixed car pool, the gate queues, and the arrival hash of tick
## step 7. New in this fork (the starter has no vehicles) but written in its
## idiom: fixed-size pools, integer arithmetic, explicit index order.
##
## DEMAND IS UNSTEERABLE. Whether gate `g` produces a car at tick `t`, whether
## that car is a through-runner and which gate it is bound for are all read
## out of the single pure hash `mix64(seed, g, t)`, evaluated independently
## for every `(g, t)`. It is NOT a consumed stream, so no ordering of
## decisions by any seat can shift, reorder or consume another seat's arrivals
## — the strongest form of the idea's "demand seeded" integrity note.

import
  sim_types, city, sim_config, sim_state, events

type
  Arrival* = object
    generated*: bool
    throughRunner*: bool
    destGate*: int

proc arrivalAt*(config: GameConfig, gate, tick: int): Arrival =
  ## The pure hash. Callers MUST be able to evaluate this for any `(gate,
  ## tick)` without touching sim state — `tests/test_signals_demand.nim`
  ## builds the whole table twice under different seat behaviour and compares.
  if tick < 0 or tick >= config.demandEndTick:
    return Arrival(generated: false, throughRunner: false, destGate: -1)
  let h = mix64(config.seed, gate, tick)
  if int(h mod 1000'u64) >= config.permilleAt(tick):
    return Arrival(generated: false, throughRunner: false, destGate: -1)
  let runner = int((h shr 10) mod 1000'u64) < config.throughRunnerPermille
  var dest =
    if runner: oppositeGate(gate)
    else: int((h shr 24) mod uint64(Gates))
  if dest == gate:
    dest = oppositeGate(gate)
  Arrival(generated: true, throughRunner: runner, destGate: dest)

proc gateQueueOwner*(sim: SimServer, gate: int): int =
  ## The seat charged for a car waiting outside a gate: the owner of the
  ## intersection that gate feeds.
  ownerOf(sim.city.gates[gate].intersection)

proc spawnDemand*(sim: var SimServer) =
  ## Tick step 7. Ascending gate index; a car whose gate queue is full is
  ## REJECTED — permanently lost demand, counted, never scored — and the hash
  ## is not disturbed by the rejection.
  if sim.tickCount >= sim.config.demandEndTick:
    return
  for gate in 0 ..< Gates:
    let arrival = sim.config.arrivalAt(gate, sim.tickCount)
    if not arrival.generated:
      continue
    inc sim.demandGenerated
    if sim.gateQueues[gate].len >= sim.config.gateQueueCap:
      inc sim.rejected
      sim.emitEvent(initSimEvent(
        seReject, sim.tickCount, slot = sim.gateQueueOwner(gate),
        at = sim.city.gates[gate].intersection, gate = gate))
      continue
    let car = sim.allocCar()
    if car < 0:
      inc sim.rejected                ## the fixed pool is full: same outcome.
      continue
    sim.cars[car].spawnTick = sim.tickCount
    sim.cars[car].originGate = gate
    sim.cars[car].destGate = arrival.destGate
    sim.cars[car].queueGate = gate
    sim.cars[car].link = -1
    ## The tick a car is CREATED is not a tick it spent waiting: without this
    ## every car entered the city already carrying one wait tick, so its first
    ## crossing could never be clean and `cleanCrossings` never reached
    ## `waveCrossings` — no green wave was physically possible.
    sim.cars[car].movedThisTick = true
    sim.gateQueues[gate].add(car)
    sim.emitEvent(initSimEvent(
      seSpawn, sim.tickCount, slot = sim.gateQueueOwner(gate),
      at = sim.city.gates[gate].intersection, gate = gate,
      a = arrival.destGate, b = (if arrival.throughRunner: 1 else: 0)))
    if sim.gateQueues[gate].len >= sim.config.gateQueueCap and
        not sim.gateJammed[gate]:
      sim.gateJammed[gate] = true
      sim.gateJamTick[gate] = sim.tickCount

proc admitGateQueues*(sim: var SimServer) =
  ## Tick step 6. Ascending gate index: the head car enters cell 0 of the
  ## entry link when that cell is free.
  for gate in 0 ..< Gates:
    if sim.gateQueues[gate].len == 0:
      continue
    let link = sim.city.gates[gate].entryLink
    if sim.occupantAt(link, 0) >= 0:
      continue
    let car = sim.gateQueues[gate][0]
    sim.gateQueues[gate].delete(0)
    sim.cars[car].queueGate = -1
    sim.cars[car].link = link
    sim.cars[car].cell = 0
    sim.cars[car].movedThisTick = true
    sim.setOccupant(link, 0, car)
    inc sim.liveCars
    sim.emitEvent(initSimEvent(
      seEnter, sim.tickCount, slot = sim.gateQueueOwner(gate),
      at = sim.city.gates[gate].intersection, link = link, gate = gate))
    if sim.gateJammed[gate] and
        sim.gateQueues[gate].len < sim.config.gateQueueCap:
      sim.gateJammed[gate] = false

proc nextLinkFor*(sim: SimServer, car: int): int =
  ## The link this car takes out of the intersection at the head of its
  ## current link, straight out of the precomputed all-pairs table.
  let link = sim.cars[car].link
  if link < 0:
    return -1
  let head = sim.city.links[link].toNode
  if head >= Intersections:
    return -1                          ## already at its exit gate.
  sim.city.routeNextLink(head, sim.cars[car].destGate)

proc movementOf*(sim: SimServer, car: int): Movement =
  ## The car's movement class at the intersection ahead of it.
  let link = sim.cars[car].link
  if link < 0:
    return mvNone
  let nextLink = sim.nextLinkFor(car)
  if nextLink < 0:
    return mvNone
  movementBetween(sim.city.links[link].dir, sim.city.links[nextLink].dir)

proc advanceLinks*(sim: var SimServer) =
  ## Tick step 4. Ascending link index, and DOWNSTREAM-FIRST within a link
  ## (`i` from `L-2` down to `0`), which gives free-flow speed of exactly one
  ## cell per tick and lets a whole queue step forward in the tick its head
  ## discharged. No start-up lost time — a documented simplification.
  for link in sim.city.links:
    for i in countdown(link.cells - 2, 0):
      let car = sim.occupantAt(link.index, i)
      if car < 0:
        continue
      if sim.cars[car].movedThisTick:
        continue                          ## one cell per tick, never two: a
                                          ## car that just crossed a stop line
                                          ## has spent its tick.
      if sim.occupantAt(link.index, i + 1) >= 0:
        continue
      sim.setOccupant(link.index, i, -1)
      sim.setOccupant(link.index, i + 1, car)
      sim.cars[car].cell = i + 1
      sim.cars[car].movedThisTick = true

proc drainExits*(sim: var SimServer) =
  ## Tick step 5. Because this runs EVERY tick, an exit link's last cell is
  ## always vacated, so exit links never spill back and a sink is never the
  ## bottleneck.
  for link in sim.city.links:
    if not link.isExit:
      continue
    let
      last = link.cells - 1
      car = sim.occupantAt(link.index, last)
    if car < 0:
      continue
    sim.setOccupant(link.index, last, -1)
    let
      owner = (if link.upstream >= 0: ownerOf(link.upstream) else: 0)
      travel = sim.tickCount - sim.cars[car].spawnTick
    inc sim.throughput
    inc sim.served[owner]
    sim.travelTicksTotal += travel
    sim.stopsTotal += sim.cars[car].stops
    dec sim.liveCars
    sim.lastExitTick = sim.tickCount
    sim.emitEvent(initSimEvent(
      seExit, sim.tickCount, slot = owner, at = link.upstream,
      link = link.index, gate = link.toNode - Intersections,
      a = travel, b = sim.cars[car].stops))
    sim.freeCar(car)

proc accountWaits*(sim: var SimServer) =
  ## Tick step 8. Every car still on the network — link cell or gate queue —
  ## that did not change cell takes exactly one wait tick, charged to the
  ## signal that is keeping it waiting: the intersection at the DOWNSTREAM end
  ## of its link, or the intersection its gate queue feeds. That is what makes
  ## `sum(seatWaitTicks) == networkWaitTicks` an identity.
  for link in sim.city.links:
    var charged = link.downstream
    if charged < 0:
      charged = link.upstream           ## an exit link never blocks anyway.
    let owner = ownerOf(charged)
    for i in 0 ..< link.cells:
      let car = sim.occupantAt(link.index, i)
      if car < 0:
        continue
      if sim.cars[car].movedThisTick:
        continue
      inc sim.cars[car].waitTicks
      inc sim.cars[car].waitSinceLastCrossing
      inc sim.networkWaitTicks
      inc sim.seatWaitTicks[owner]
      if sim.cars[car].movedLastTick:
        inc sim.cars[car].stops
  for gate in 0 ..< Gates:
    let owner = sim.gateQueueOwner(gate)
    for car in sim.gateQueues[gate]:
      if sim.cars[car].movedThisTick:
        continue
      inc sim.cars[car].waitTicks
      inc sim.cars[car].waitSinceLastCrossing
      inc sim.networkWaitTicks
      inc sim.seatWaitTicks[owner]

proc rollMovedFlags*(sim: var SimServer) =
  ## Carries `movedThisTick` into `movedLastTick` and clears it, so tick step
  ## 8's stop count sees the previous tick honestly.
  for i in 0 ..< sim.cars.len:
    if sim.cars[i].active:
      sim.cars[i].movedLastTick = sim.cars[i].movedThisTick
      sim.cars[i].movedThisTick = false
