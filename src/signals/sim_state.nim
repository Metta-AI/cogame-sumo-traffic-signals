## The simulation's state container plus the pieces every leaf shares:
## `gameHash` / `mixHash`, `emitEvent`, the lobby countdown and
## `resetToLobby`. Forked from the starter's `src/ctf/sim_state.nim`.
##
## The whole world lives in `SimServer`. It is the only mutable thing the tick
## loop touches, and `sim.nim`'s numbered step order is the only code that
## mutates it during play — which is what makes the native <-> wasm hash chain
## exact by construction.

import
  std/[strutils],
  sim_types, city, sim_config, events

type
  Car* = object
    active*: bool
    spawnTick*: int
    originGate*: int
    destGate*: int
    link*: int                 ## -1 while queued at a gate.
    cell*: int
    queueGate*: int            ## >= 0 while queued at a gate, else -1.
    waitTicks*: int
    waitSinceLastCrossing*: int
    stops*: int
    crossings*: int
    cleanCrossings*: int
    blockedByPhaseTicks*: int
    spillbackBlockedTicks*: int
    progressed*: bool          ## already credited to its corridor.
    movedThisTick*: bool
    movedLastTick*: bool

  SignalState* = object
    phase*: PhaseId            ## the CURRENT phase; never `phCLR` except in
                               ## clearance, where `clearLeft > 0`.
    requested*: PhaseId
    clearLeft*: int
    ticksInPhase*: int
    order*: SignalOrder
    overrideLeft*: int         ## starvation override latch, in ticks.
    overridePhase*: PhaseId

  RadioLine* = object
    slot*: int
    text*: string

  SimServer* = object
    config*: GameConfig
    city*: City
    phase*: GamePhase
    tickCount*: int
    turn*: int
    turnsPlayed*: int
    finalTick*: int

    occupant*: seq[int]        ## flat cell -> car id, or -1.
    cars*: seq[Car]
    freeSlots*: seq[int]
    liveCars*: int
    gateQueues*: array[Gates, seq[int]]
    gateJammed*: array[Gates, bool]
    gateJamTick*: array[Gates, int]
    signals*: array[Intersections, SignalState]

    linkQueueLen*: seq[int]
    linkFull*: seq[bool]
    linkFullTicks*: seq[int]
    activeSpillback*: seq[int]
    activeGridlock*: seq[int]
    gridlockRun*: int
    longestGridlockTicks*: int
    stallTicks*: int
    waveTicks*: array[16, seq[int]]  ## (corridor, dir) -> credit ticks.
    waveFlashTick*: array[16, int]   ## (corridor, dir) -> the tick its last
                                     ## wave fired, 0 for never. Presentation
                                     ## only: the board's sweep reads it and
                                     ## the game hash does not.
    waveCounts*: array[16, int]      ## (corridor, dir) -> waves so far. The
                                     ## corridor tally's bars count THESE:
                                     ## `waveTicks` is the in-window credit
                                     ## list and is cleared the moment a wave
                                     ## fires.

    throughput*: int
    rejected*: int
    demandGenerated*: int
    crossings*: int
    networkWaitTicks*: int
    seatWaitTicks*: array[MaxSeats, int]
    served*: array[MaxSeats, int]
    travelTicksTotal*: int
    stopsTotal*: int
    greenWaves*: int
    spillbacks*: int
    spillbackTicks*: int
    gridlocks*: int
    gridlockTicks*: int
    starvations*: int
    deferredSwitches*: int
    phaseChanges*: array[MaxSeats, int]

    players*: array[MaxSeats, PlayerSlot]
    radio*: array[MaxSeats, string]
    notes*: array[MaxSeats, string]
    lastResult*: array[Intersections, OrderResult]
    orderAgeTurns*: array[Intersections, int]
    ordersRejected*: array[MaxSeats, int]
    fallbackTurns*: array[MaxSeats, int]
    llmTurns*: array[MaxSeats, int]
    deadSeats*: array[MaxSeats, bool]
    policyKinds*: array[MaxSeats, string]

    endRule*: EndRule
    endReason*: EndReason
    stopDetail*: string
    settled*: bool

    events*: seq[SimEvent]
    gameEventLoggingEnabled*: bool
    feedDirectives*: seq[string]
    hashValue*: uint64
    lobbyTicks*: int
    gameOverHold*: int
    lastExitTick*: int

proc emitEvent*(sim: var SimServer, event: SimEvent) =
  ## Records one tier-2 event. Bounded: an episode of 256 ticks over <= 544
  ## cars cannot produce more than a few thousand, and the cap keeps a
  ## pathological run from growing without limit.
  if not sim.gameEventLoggingEnabled:
    return
  if sim.events.len >= 65536:
    return
  sim.events.add(event)

proc gameHash*(sim: SimServer): uint64 =
  sim.hashValue

proc seatOf*(sim: SimServer, intersection: int): int =
  ownerOf(intersection)

proc initSimServer*(config: GameConfig): SimServer =
  ## Builds the world: the code-authored city, every signal at `NSG` with
  ## `ticksInPhase = 0`, every gate queue empty, every car slot free.
  result.config = config
  result.city = buildCity(config)
  result.phase = Lobby
  result.tickCount = 0
  result.turn = 0
  result.finalTick = 0
  result.occupant = newSeq[int](result.city.totalCells)
  for i in 0 ..< result.occupant.len:
    result.occupant[i] = -1
  result.cars = newSeq[Car](MaxVehicles)
  result.freeSlots = @[]
  for i in countdown(MaxVehicles - 1, 0):
    result.freeSlots.add(i)
  result.linkQueueLen = newSeq[int](result.city.links.len)
  result.linkFull = newSeq[bool](result.city.links.len)
  result.linkFullTicks = newSeq[int](result.city.links.len)
  result.gameEventLoggingEnabled = true
  result.hashValue = 0xCBF29CE484222325'u64
  result.lastExitTick = 0
  for i in 0 ..< Intersections:
    result.signals[i] = SignalState(
      phase: phNSG,
      requested: phNSG,
      clearLeft: 0,
      ticksInPhase: 0,
      order: SignalOrder(verb: ovAuto, phase: phNSG, delay: 0, turn: 0,
                         outcome: orUnknown),
      overrideLeft: 0,
      overridePhase: phNSG
    )
    result.lastResult[i] = orUnknown
    result.orderAgeTurns[i] = 0
  for slot in 0 ..< MaxSeats:
    result.players[slot] = PlayerSlot(
      name: (if slot < config.players.len: config.players[slot]
             else: seatAlias(slot)),
      alias: seatAlias(slot),
      quadrant: seatQuadrant(slot),
      token: (if slot < config.tokens.len: config.tokens[slot] else: ""),
      slot: slot,
      joined: false,
      left: false,
      registered: false,
      policy: "",
      kind: "scripted",
      baseline: "greedy"
    )
    result.policyKinds[slot] = "scripted"
    result.radio[slot] = ""
    result.notes[slot] = ""
  for g in 0 ..< Gates:
    result.gateQueues[g] = @[]
  for i in 0 ..< result.waveTicks.len:
    result.waveTicks[i] = @[]

proc resetToLobby*(sim: var SimServer) =
  ## Returns the world to its pre-game state, keeping the roster. The replay
  ## server uses this on a rewind-to-zero, and the live server on a restart.
  let
    config = sim.config
    players = sim.players
  var fresh = initSimServer(config)
  fresh.players = players
  fresh.gameEventLoggingEnabled = sim.gameEventLoggingEnabled
  sim = fresh

proc effectiveMaxTicks*(sim: SimServer): int =
  sim.config.maxTicks

proc lobbyStartSecondsRemaining*(sim: SimServer): int =
  ## Whole seconds until the lobby gives up waiting for the missing seats.
  if sim.phase != Lobby:
    return 0
  let left = sim.config.lobbyJoinTimeoutTicks - sim.lobbyTicks
  if left <= 0: 0 else: (left + TargetFps - 1) div TargetFps

proc joinedSeats*(sim: SimServer): int =
  for slot in 0 ..< MaxSeats:
    if sim.players[slot].joined and not sim.players[slot].left:
      inc result

proc seatCount*(sim: SimServer): int = MaxSeats

proc turnsPerEpisode*(sim: SimServer): int = sim.config.turnsPerEpisode()

proc carsOnNetwork*(sim: SimServer): int = sim.liveCars

proc queuedCars*(sim: SimServer): int =
  for g in 0 ..< Gates:
    result += sim.gateQueues[g].len

proc cityEmpty*(sim: SimServer): bool =
  sim.liveCars == 0 and sim.queuedCars() == 0

proc linkOf*(sim: SimServer, flatCell: int): int =
  ## The link a flat cell belongs to. Linear over 80 links; only used by
  ## diagnostics, never inside the tick loop.
  for link in sim.city.links:
    let base = sim.city.cellBase[link.index]
    if flatCell >= base and flatCell < base + link.cells:
      return link.index
  -1

proc occupantAt*(sim: SimServer, link, cell: int): int =
  sim.occupant[sim.city.cellBase[link] + cell]

proc setOccupant*(sim: var SimServer, link, cell, car: int) =
  sim.occupant[sim.city.cellBase[link] + cell] = car

proc stopLineCar*(sim: SimServer, link: int): int =
  ## The car at a link's stop line — its last cell.
  sim.occupantAt(link, sim.city.links[link].cells - 1)

proc phaseText*(sim: SimServer, intersection: int): string =
  ## What a seat and the board both see: `CLR` while in clearance, else the
  ## current phase id.
  if sim.signals[intersection].clearLeft > 0: $phCLR
  else: $sim.signals[intersection].phase

proc allocCar*(sim: var SimServer): int =
  ## Takes a free car slot, or -1 when the fixed pool is exhausted.
  if sim.freeSlots.len == 0:
    return -1
  result = sim.freeSlots.pop()
  sim.cars[result] = Car(
    active: true, link: -1, cell: 0, queueGate: -1, cleanCrossings: 0)

proc freeCar*(sim: var SimServer, car: int) =
  sim.cars[car].active = false
  sim.cars[car].link = -1
  sim.cars[car].queueGate = -1
  sim.freeSlots.add(car)

proc describeState*(sim: SimServer): string =
  "tick " & $sim.tickCount & "/" & $sim.config.maxTicks &
    " turn " & $sim.turn & "/" & $sim.turnsPerEpisode() &
    " through " & $sim.throughput & " demand " & $sim.demandGenerated &
    " on-net " & $sim.liveCars & " queued " & $sim.queuedCars() &
    " wait " & $sim.networkWaitTicks &
    " spillback " & $sim.activeSpillback.len &
    " gridlock " & $sim.activeGridlock.len &
    " waves " & $sim.greenWaves

proc corridorIndex*(dir: Dir, row, col: int): int =
  ## `(corridor, direction)` bucket for the green-wave window: rows A..D carry
  ## the east-west corridors, columns 1..4 the north-south ones.
  case dir
  of apE: row * 2
  of apW: row * 2 + 1
  of apS: 8 + col * 2
  of apN: 8 + col * 2 + 1

proc corridorLabel*(bucket: int): string =
  if bucket < 8: RowNames[bucket div 2] else: ColNames[(bucket - 8) div 2]

proc corridorDirText*(bucket: int): string =
  if bucket < 8:
    if bucket mod 2 == 0: "eastbound" else: "westbound"
  else:
    if bucket mod 2 == 0: "southbound" else: "northbound"

proc corridorDir*(bucket: int): Dir =
  ## The direction of travel of one arterial bucket.
  if bucket < 8:
    if bucket mod 2 == 0: apE else: apW
  else:
    if bucket mod 2 == 0: apS else: apN

proc corridorIntersections*(bucket: int): seq[int] =
  ## The four intersections on one arterial, in the direction of travel.
  if bucket < 8:
    let row = bucket div 2
    if bucket mod 2 == 0:
      for col in 0 ..< Cols: result.add(row * Cols + col)
    else:
      for col in countdown(Cols - 1, 0): result.add(row * Cols + col)
  else:
    let col = (bucket - 8) div 2
    if bucket mod 2 == 0:
      for row in 0 ..< Rows: result.add(row * Cols + col)
    else:
      for row in countdown(Rows - 1, 0): result.add(row * Cols + col)

proc corridorNames*(bucket: int): string =
  var names: seq[string]
  for i in corridorIntersections(bucket):
    names.add(intersectionName(i))
  names.join(" ")
