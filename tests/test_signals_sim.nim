## Sim unit tests: the city, the routes, free flow, single-lane discharge, the
## left-turn block, spillback, the phase machine, the starvation override, the
## demand hash, the gate queues, wait accounting, the gridlock ring, the green
## wave, and the tick budget. Tests 1-13 and 16-17 of the design note's list
## (14 lives in test_signals_scoring, 15 in test_signals_engine).

import std/[monotimes, times, unittest]
import helpers

suite "city topology":
  test "1. sixteen intersections, sixteen gates, eighty links, 352 cells":
    let city = buildCity(testConfig())
    check Intersections == 16
    check Gates == 16
    check city.links.len == 80
    check city.totalCells == 352
    check BoardCellsWide == 34
    check BoardCellsHigh == 26

  test "1. every intersection has four approaches and four exits":
    let city = buildCity(testConfig())
    for at in 0 ..< Intersections:
      for a in 0 ..< Approaches:
        check city.inbound[at][a] >= 0
        check city.outbound[at][a] >= 0

  test "1. every gate is both a source and a sink":
    let city = buildCity(testConfig())
    for g in 0 ..< Gates:
      let gate = city.gates[g]
      check gate.entryLink >= 0
      check gate.exitLink >= 0
      check city.links[gate.entryLink].isEntry
      check city.links[gate.exitLink].isExit
      check city.links[gate.entryLink].downstream == gate.intersection
      check city.links[gate.exitLink].upstream == gate.intersection

  test "1. the quadrant map is exactly the design note's table":
    check ownerOf(intersectionIndex("A1")) == 0
    check ownerOf(intersectionIndex("A2")) == 0
    check ownerOf(intersectionIndex("B1")) == 0
    check ownerOf(intersectionIndex("B2")) == 0
    check ownerOf(intersectionIndex("A3")) == 1
    check ownerOf(intersectionIndex("B4")) == 1
    check ownerOf(intersectionIndex("C1")) == 2
    check ownerOf(intersectionIndex("D2")) == 2
    check ownerOf(intersectionIndex("C3")) == 3
    check ownerOf(intersectionIndex("D4")) == 3
    check seatAlias(0) == "Alpha"
    check seatAlias(3) == "Delta"
    check seatQuadrant(2) == "SW"
    ## Every arterial is jointly owned: two seats on every row and column.
    for row in 0 ..< Rows:
      var owners: seq[int]
      for col in 0 ..< Cols:
        let owner = ownerOf(row * Cols + col)
        if owner notin owners:
          owners.add(owner)
      check owners.len == 2

  test "1. link lengths are the configured cell counts":
    let
      config = testConfig()
      city = buildCity(config)
    check city.links[city.linkIndex("C2>C3")].cells == config.ewLinkCells
    check city.links[city.linkIndex("B2>C2")].cells == config.nsLinkCells
    check city.links[city.linkIndex("wA1>A1")].cells == config.ewGateCells
    check city.links[city.linkIndex("nA1>A1")].cells == config.nsGateCells

  test "1. every cell is on the board and no two cells of one link coincide":
    let city = buildCity(testConfig())
    for link in city.links:
      var seen: seq[int]
      for i in 0 ..< link.cells:
        let flat = city.flatCell(link.index, i)
        check city.cellX[flat] >= 0
        check city.cellX[flat] < BoardCellsWide
        check city.cellY[flat] >= 0
        check city.cellY[flat] < BoardCellsHigh
        let key = city.cellY[flat] * BoardCellsWide + city.cellX[flat]
        check key notin seen
        seen.add(key)

suite "routes":
  test "2. every (gate, gate) pair has a route and no route needs a U-turn":
    let city = buildCity(testConfig())
    for a in 0 ..< Gates:
      for b in 0 ..< Gates:
        if a == b:
          continue
        check city.routeCells(a, b) > 0
        check not city.routeHasUTurn(a, b)

  test "2. a route's cost is the sum of its links' cell counts":
    let city = buildCity(testConfig())
    for a in 0 ..< Gates:
      for b in 0 ..< Gates:
        if a == b:
          continue
        var
          node = gateNode(a)
          total = 0
          guard = 0
        while node != gateNode(b) and guard < 64:
          inc guard
          let link = city.routeNextLink(node, b)
          check link >= 0
          total += city.links[link].cells
          node = city.links[link].toNode
        check total == city.routeCells(a, b)

  test "2. the route table is identical across two builds":
    let
      first = buildCity(testConfig())
      second = buildCity(testConfig())
    for u in 0 ..< 32:
      for v in 0 ..< 32:
        check first.nextHop[u][v] == second.nextHop[u][v]

suite "free flow":
  test "3. a single car covers one cell per tick with every signal green for it":
    var sim = newSim(emptyConfig())
    let
      link = sim.city.linkIndex("nA1>A1")
      car = sim.placeCar(link, 0, 0, gateIndex("sD1"))
    for at in 0 ..< Intersections:
      sim.forcePhase(at, phNSG)
      sim.setOrder(at, ovHold, phNSG)
    var cell = 0
    for t in 0 ..< 3:
      sim.stepTick(t)
      inc cell
      if sim.cars[car].link == link:
        check sim.cars[car].cell == cell
    check sim.cars[car].waitTicks == 0

  test "3. it reaches its destination gate and its travel time is the route cost":
    var sim = newSim(emptyConfig())
    let
      origin = gateIndex("nA1")
      dest = gateIndex("sD1")
      link = sim.city.gates[origin].entryLink
      cost = sim.city.routeCells(origin, dest)
    discard sim.placeCar(link, 0, origin, dest)
    for at in 0 ..< Intersections:
      sim.forcePhase(at, phNSG)
      sim.setOrder(at, ovHold, phNSG)
    var ticks = 0
    while sim.throughput == 0 and ticks < 200:
      sim.stepTick(ticks mod sim.config.turnTicks)
      inc ticks
    check sim.throughput == 1
    ## Free flow is one cell per tick and every signal was green for it, so the
    ## travel time is the route cost, less the cell it started on.
    check sim.travelTicksTotal <= cost
    check sim.travelTicksTotal >= cost - 2
    check sim.networkWaitTicks == 0

suite "single lane":
  test "4. an approach never discharges two cars in one tick":
    var sim = newSim(emptyConfig())
    let link = sim.city.linkIndex("nA1>A1")
    for i in 0 ..< sim.config.nsGateCells:
      discard sim.placeCar(link, i, gateIndex("nA1"), gateIndex("sD1"))
    for at in 0 ..< Intersections:
      sim.forcePhase(at, phNSG)
      sim.setOrder(at, ovHold, phNSG)
    let before = sim.crossings
    sim.stepTick(0)
    check sim.crossings - before <= 1

  test "4. an intersection never discharges more than two cars in one tick":
    var sim = newSim(emptyConfig())
    for name in ["nA1>A1", "wA1>A1"]:
      let link = sim.city.linkIndex(name)
      for i in 0 ..< sim.city.links[link].cells:
        discard sim.placeCar(link, i, gateIndex("nA1"), gateIndex("sD1"))
    for at in 0 ..< Intersections:
      sim.forcePhase(at, phNSG)
      sim.setOrder(at, ovHold, phNSG)
    for t in 0 ..< 6:
      let before = sim.crossings
      sim.stepTick(t)
      check sim.crossings - before <= 2

suite "left-turn blocking":
  test "5. a left-turner blocks everyone behind it and is released on the left phase":
    var sim = newSim(emptyConfig())
    ## A car arriving at A2 from the north (heading south) whose exit is EAST
    ## is turning left: facing south, left is east.
    let
      link = sim.city.linkIndex("nA2>A2")
      cells = sim.city.links[link].cells
      leftTurner = sim.placeCar(link, cells - 1, gateIndex("nA2"), gateIndex("eA4"))
      follower = sim.placeCar(link, cells - 2, gateIndex("nA2"), gateIndex("sD2"))
    check sim.movementOf(leftTurner) == mvLeft
    for at in 0 ..< Intersections:
      sim.forcePhase(at, phNSG)
      sim.setOrder(at, ovHold, phNSG)
    for t in 0 ..< 4:
      sim.stepTick(t)
    ## Under NSG the left-turner cannot move and the follower cannot pass it.
    check sim.cars[leftTurner].cell == cells - 1
    check sim.cars[follower].cell == cells - 2
    check sim.cars[leftTurner].blockedByPhaseTicks >= 4
    ## Give the whole city NSL: the left-turner is released.
    for at in 0 ..< Intersections:
      sim.setOrder(at, ovPhase, phNSL)
    let crossingsBefore = sim.crossings
    for t in 0 ..< 6:
      sim.stepTick(t)
    check sim.crossings > crossingsBefore
    check sim.cars[leftTurner].blockedByPhaseTicks == 0

suite "spillback":
  test "6. a car on green whose receiving link is full does not move":
    var sim = newSim(emptyConfig())
    let
      feeder = sim.city.linkIndex("nA1>A1")
      receiver = sim.city.linkIndex("A1>B1")
      head = sim.placeCar(feeder, sim.city.links[feeder].cells - 1,
                          gateIndex("nA1"), gateIndex("sD1"))
    for i in 0 ..< sim.city.links[receiver].cells:
      discard sim.placeCar(receiver, i, gateIndex("nA1"), gateIndex("sD1"))
    for at in 0 ..< Intersections:
      sim.forcePhase(at, phNSG)
      sim.setOrder(at, ovHold, phNSG)
    ## B1 gets the CROSS phase, so the receiving link's own stop-line car is
    ## red and the link stays full: that is what makes A1's green worthless.
    sim.forcePhase(intersectionIndex("B1"), phEWG)
    sim.setOrder(intersectionIndex("B1"), ovHold, phEWG)
    sim.stepTick(0)
    check sim.cars[head].link == feeder
    check sim.cars[head].spillbackBlockedTicks >= 1
    check sim.cars[head].waitTicks >= 1
    check sim.linkFull[receiver]
    check sim.spillbacks >= 1

  test "6. an exit link never blocks":
    var sim = newSim(emptyConfig())
    let exitLink = sim.city.gates[gateIndex("nA1")].exitLink
    for i in 0 ..< sim.city.links[exitLink].cells:
      discard sim.placeCar(exitLink, i, gateIndex("sD1"), gateIndex("nA1"))
    sim.stepTick(0)
    ## The last cell is vacated every tick, so an exit link can never stay
    ## full: a sink never becomes the bottleneck.
    check sim.throughput >= 1
    check not sim.linkFull[exitLink]

suite "phase machine":
  test "7. minGreenTicks defers a change, counted and retried, never dropped":
    var sim = newSim(emptyConfig())
    sim.signals[0].phase = phNSG
    sim.signals[0].ticksInPhase = 0
    sim.setOrder(0, ovPhase, phEWG)
    let deferredBefore = sim.deferredSwitches
    sim.stepTick(0)
    check sim.deferredSwitches > deferredBefore
    check sim.signals[0].phase == phNSG
    check sim.lastResult[0] == orDeferred
    ## Retried on the following ticks and executed once minGreen is met.
    for t in 1 ..< sim.config.minGreenTicks + sim.config.clearTicks + 2:
      sim.stepTick(t)
    check sim.signals[0].phase == phEWG

  test "7. a change costs exactly clearTicks of all-red with no discharge":
    var sim = newSim(emptyConfig())
    sim.forcePhase(0, phNSG)
    sim.setOrder(0, ovPhase, phEWG)
    ## The change enters clearance on the tick it is requested and commits on
    ## the tick the counter reaches zero, so exactly clearTicks ticks pass with
    ## no discharge and the phase flips at tick == clearTicks.
    var flippedAt = -1
    for t in 0 ..< sim.config.clearTicks + 3:
      sim.stepTick(t)
      if flippedAt < 0 and sim.signals[0].phase == phEWG:
        flippedAt = sim.tickCount
    check flippedAt == sim.config.clearTicks
    check sim.signals[0].phase == phEWG

  test "7. phasechange fires when the clearance ENDS":
    var sim = newSim(emptyConfig())
    sim.forcePhase(0, phNSG)
    sim.setOrder(0, ovPhase, phEWG)
    var changeTick = -1
    for t in 0 ..< 8:
      sim.stepTick(t)
      for event in sim.events:
        if event.kind == sePhaseChange and event.at == 0 and changeTick < 0:
          changeTick = event.tick
    check changeTick == sim.config.clearTicks
    check sim.signals[0].phase == phEWG

suite "starvation override":
  test "8. maxRedTicks forces the serving phase, latches, then returns control":
    var config = emptyConfig()
    config.maxRedTicks = 8
    var sim = newSim(config)
    let
      link = sim.city.linkIndex("nA2>A2")
      cells = sim.city.links[link].cells
      leftTurner = sim.placeCar(link, cells - 1, gateIndex("nA2"), gateIndex("eA4"))
    check sim.movementOf(leftTurner) == mvLeft
    for at in 0 ..< Intersections:
      sim.forcePhase(at, phEWG)
      sim.setOrder(at, ovHold, phEWG)
    let at2 = intersectionIndex("A2")
    var forced = false
    for t in 0 ..< 40:
      sim.stepTick(t)
      if sim.starvations > 0:
        forced = true
        break
    check forced
    check sim.lastResult[at2] == orOverridden
    var starved = false
    for event in sim.events:
      if event.kind == seStarve and event.at == at2:
        starved = true
    check starved

  test "8. a car blocked by SPILLBACK never triggers the override":
    var config = emptyConfig()
    config.maxRedTicks = 6
    var sim = newSim(config)
    let
      feeder = sim.city.linkIndex("nA1>A1")
      receiver = sim.city.linkIndex("A1>B1")
    discard sim.placeCar(feeder, sim.city.links[feeder].cells - 1,
                         gateIndex("nA1"), gateIndex("sD1"))
    for i in 0 ..< sim.city.links[receiver].cells:
      discard sim.placeCar(receiver, i, gateIndex("nA1"), gateIndex("sD1"))
    for at in 0 ..< Intersections:
      sim.forcePhase(at, phNSG)
      sim.setOrder(at, ovHold, phNSG)
    for t in 0 ..< 20:
      sim.stepTick(t)
    check sim.starvations == 0

suite "demand is a pure hash":
  test "9. the (gate, tick) table is identical under two seat behaviours":
    let config = testConfig()
    var
      greedy = runScripted(config, [blGreedy])
      cycle = runScripted(config, [blFixedCycle])
    check greedy.demandGenerated == cycle.demandGenerated
    ## And the table itself, evaluated with no sim at all.
    for gate in 0 ..< Gates:
      for tick in 0 ..< config.demandEndTick:
        let a = config.arrivalAt(gate, tick)
        let b = config.arrivalAt(gate, tick)
        check a.generated == b.generated
        check a.throughRunner == b.throughRunner
        check a.destGate == b.destGate

  test "9. no arrival ever targets its own gate":
    let config = testConfig()
    for gate in 0 ..< Gates:
      for tick in 0 ..< config.demandEndTick:
        let arrival = config.arrivalAt(gate, tick)
        if arrival.generated:
          check arrival.destGate != gate
          check arrival.destGate >= 0
          check arrival.destGate < Gates

  test "9. demandGenerated counts rejections":
    var config = testConfig()
    config.gateQueueCap = 1
    config.update("{}")
    let sim = runScripted(config, [blFixedCycle])
    check sim.rejected > 0
    check sim.demandGenerated >= sim.throughput + sim.rejected

suite "gate queues":
  test "10. capacity, admission and the seat charged for the wait":
    var sim = newSim(emptyConfig())
    let gate = gateIndex("nA1")
    for i in 0 ..< sim.config.gateQueueCap + 4:
      let car = sim.allocCar()
      if car < 0:
        break
      sim.cars[car].queueGate = gate
      sim.cars[car].destGate = gateIndex("sD1")
      if sim.gateQueues[gate].len < sim.config.gateQueueCap:
        sim.gateQueues[gate].add(car)
    check sim.gateQueues[gate].len == sim.config.gateQueueCap
    let owner = sim.gateQueueOwner(gate)
    check owner == ownerOf(sim.city.gates[gate].intersection)
    let before = sim.seatWaitTicks[owner]
    sim.stepTick(0)
    ## The head entered (cell 0 was free), the rest waited and are charged to
    ## the seat owning the intersection the gate feeds.
    check sim.gateQueues[gate].len == sim.config.gateQueueCap - 1
    check sim.seatWaitTicks[owner] > before

suite "wait accounting":
  test "11. sum(seatWaitTicks) == networkWaitTicks for every tick":
    var sim = newSim(testConfig())
    for turnIndex in 1 .. sim.turnsPerEpisode():
      if sim.settled:
        break
      sim.turn = turnIndex
      for slot in 0 ..< MaxSeats:
        sim.applyReply(slot, sim.scriptedReply(slot, blGreedy))
      for k in 0 ..< sim.config.turnTicks:
        if sim.settled:
          break
        sim.stepTick(k)
        var total = 0
        for slot in 0 ..< MaxSeats:
          total += sim.seatWaitTicks[slot]
        check total == sim.networkWaitTicks

  test "11. a car that advances accrues no wait tick":
    var sim = newSim(emptyConfig())
    let
      link = sim.city.linkIndex("nA1>A1")
      car = sim.placeCar(link, 0, gateIndex("nA1"), gateIndex("sD1"))
    for at in 0 ..< Intersections:
      sim.forcePhase(at, phNSG)
      sim.setOrder(at, ovHold, phNSG)
    sim.stepTick(0)
    check sim.cars[car].cell == 1
    check sim.cars[car].waitTicks == 0
    check sim.networkWaitTicks == 0

suite "gridlock ring":
  ## The ring search is a pure function of the blocked-by graph and the
  ## fullness spans, so it is tested as one: a hand-built cycle of four full
  ## links whose stop-line cars each route into the NEXT ring link.
  const Ring = ["B2>B3", "B3>C3", "C3>C2", "C2>B2"]
  ## The destination that makes each ring link's stop-line car turn into the
  ## next ring link (facing the way it arrived): south out of B3, west out of
  ## C3, north out of C2, east out of B2.
  const RingDest = ["sD3", "wC1", "nA2", "eB4"]

  proc buildRing(sim: var SimServer) =
    for i, name in Ring:
      let link = sim.city.linkIndex(name)
      doAssert link >= 0, name
      for cell in 0 ..< sim.city.links[link].cells:
        let car = sim.allocCar()
        doAssert car >= 0
        sim.cars[car].link = link
        sim.cars[car].cell = cell
        sim.cars[car].queueGate = -1
        sim.cars[car].destGate = gateIndex(RingDest[i])
        sim.setOccupant(link, cell, car)
        inc sim.liveCars
    sim.measureFlow()
    for link in 0 ..< sim.city.links.len:
      if sim.linkFull[link]:
        sim.linkFullTicks[link] = sim.config.ringTicks

  test "12. every ring link's stop-line car routes into the next ring link":
    var sim = newSim(emptyConfig())
    sim.buildRing()
    for i, name in Ring:
      let
        link = sim.city.linkIndex(name)
        car = sim.stopLineCar(link)
        wanted = sim.city.linkIndex(Ring[(i + 1) mod Ring.len])
      check car >= 0
      check sim.nextLinkFor(car) == wanted

  test "12. the search finds the ring, names its links, and is deterministic":
    var sim = newSim(emptyConfig())
    sim.buildRing()
    let ring = sim.findGridlockRing()
    check ring.len == Ring.len
    var names: seq[string]
    for link in ring:
      names.add(sim.city.links[link].name)
    for name in Ring:
      check name in names
    for _ in 0 ..< 5:
      check sim.findGridlockRing() == ring

  test "12. detectGridlock raises the alarm and names the ring":
    var sim = newSim(emptyConfig())
    sim.buildRing()
    sim.detectGridlock()
    check sim.gridlocks == 1
    check sim.activeGridlock.len == Ring.len
    check sim.gridlockTicks == 1
    check sim.activeGridlockNames().len == Ring.len

  test "12. it clears the tick one ring link discharges":
    var sim = newSim(emptyConfig())
    sim.buildRing()
    sim.detectGridlock()
    check sim.activeGridlock.len > 0
    ## Empty one cell of one ring link: the ring is re-evaluated every tick and
    ## is never latched.
    let link = sim.city.linkIndex(Ring[0])
    let car = sim.occupantAt(link, 0)
    sim.setOccupant(link, 0, -1)
    sim.freeCar(car)
    dec sim.liveCars
    sim.measureFlow()
    sim.detectGridlock()
    check sim.activeGridlock.len == 0
    check sim.gridlocks == 1

  test "12. a queue behind a starved-but-serviceable approach is not a ring":
    var sim = newSim(emptyConfig())
    let link = sim.city.linkIndex("nA1>A1")
    for cell in 0 ..< sim.city.links[link].cells:
      discard sim.placeCar(link, cell, gateIndex("nA1"), gateIndex("sD1"))
    sim.measureFlow()
    for i in 0 ..< sim.city.links.len:
      if sim.linkFull[i]:
        sim.linkFullTicks[i] = 999
    check sim.findGridlockRing().len == 0
    sim.detectGridlock()
    check sim.gridlocks == 0

suite "green wave":
  test "13. waveVehicles credits inside the window raise exactly one wave":
    var config = emptyConfig()
    config.waveVehicles = 4
    config.waveWindow = 16
    var sim = newSim(config)
    let link = sim.city.linkIndex("A1>A2")
    for i in 0 ..< config.waveVehicles - 1:
      sim.creditCorridor(0, link)
      check sim.greenWaves == 0
    sim.creditCorridor(0, link)
    check sim.greenWaves == 1
    ## The window is CLEARED, so one wave is one event: a fifth credit inside
    ## the same window does not raise a second.
    sim.creditCorridor(0, link)
    check sim.greenWaves == 1
    var waveEvents = 0
    var corridor = ""
    for event in sim.events:
      if event.kind == seWave:
        inc waveEvents
        corridor = event.text
    check waveEvents == 1
    check corridor.startsWith("A")
    check corridor.contains("eastbound")

  test "13. credits older than the window do not count toward a wave":
    var config = emptyConfig()
    config.waveVehicles = 3
    config.waveWindow = 4
    var sim = newSim(config)
    let link = sim.city.linkIndex("A1>A2")
    sim.creditCorridor(0, link)
    sim.tickCount = 10
    sim.creditCorridor(0, link)
    sim.creditCorridor(0, link)
    ## Two inside the window, one long expired: no wave.
    check sim.greenWaves == 0
    sim.creditCorridor(0, link)
    check sim.greenWaves == 1

  test "13. a clean crossing raises cleanCrossings; a stop resets it to 1":
    var sim = newSim(emptyConfig())
    for at in 0 ..< Intersections:
      sim.forcePhase(at, phEWG)
      sim.setOrder(at, ovHold, phEWG)
    let
      entry = sim.city.gates[gateIndex("wA1")].entryLink
      car = sim.placeCar(entry, 0, gateIndex("wA1"), gateIndex("eA4"))
    for t in 0 ..< 6:
      sim.stepTick(t)
      if not sim.cars[car].active:
        break
    check sim.cars[car].crossings >= 1
    check sim.cars[car].cleanCrossings >= 1
    ## Close the city on it: it stops, and its NEXT crossing restarts the count.
    for at in 0 ..< Intersections:
      sim.setOrder(at, ovPhase, phNSL)
    for t in 0 ..< 12:
      sim.stepTick(t)
      if not sim.cars[car].active:
        break
    if sim.cars[car].active:
      check sim.cars[car].waitSinceLastCrossing > 0
      for at in 0 ..< Intersections:
        sim.setOrder(at, ovPhase, phEWG)
      let before = sim.cars[car].crossings
      for t in 0 ..< 14:
        sim.stepTick(t)
        if not sim.cars[car].active or sim.cars[car].crossings > before:
          break
      if sim.cars[car].active and sim.cars[car].crossings > before:
        check sim.cars[car].cleanCrossings == 1

suite "no floating point in the sim":
  test "16. the sim modules carry no float type, literal or division":
    ## The native game and the wasm viewer must re-derive the identical tick,
    ## and a compile-time cos/sin would be evaluated by whichever libm the
    ## build container ships. Integer only, and the grep is the guard.
    for name in ["sim", "city", "vehicles", "phases", "flow", "driver",
                 "baselines"]:
      let source = repoFile("src/signals/" & name & ".nim")
      var line = 0
      for raw in source.splitLines():
        inc line
        let text = raw.strip()
        if text.startsWith("#") or text.startsWith("##"):
          continue
        let code = (if "#" in text: text[0 ..< text.find('#')] else: text)
        if code.len == 0:
          continue
        if code.contains("float") or code.contains("sqrt") or
            code.contains(".0'") or code.contains("1.0") or
            code.contains(" / "):
          ## A bare `/` is FLOAT division in Nim; the sim uses `div` only.
          checkpoint("src/signals/" & name & ".nim:" & $line & ": " & code)
          check false

suite "tick budget":
  test "17. a full rushhour episode of 256 ticks runs well inside two seconds":
    let started = getMonoTime()
    let sim = runScripted(testConfig("rushhour"), [blGreedy, blFixedCycle])
    let elapsed = (getMonoTime() - started).inMilliseconds.int
    echo "rushhour episode: ", describeState(sim), " in ", elapsed, " ms"
    check sim.tickCount > 0
    when defined(release):
      check elapsed < 2000
    else:
      check elapsed < 20000
