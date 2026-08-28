## Shared test helpers: one place to build a config, run a headless episode and
## reach into the sim, so no test file re-derives the setup.

import
  std/[json, os, strutils],
  signals/[sim, roster, replays, baselines]

export sim, roster, replays, baselines, json, strutils

proc testConfig*(
  variant = "grid4x4", seed = 42, maxTicks = 256
): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.variant = variant
  result.maxTicks = maxTicks
  result.turnSpacingMs = 0
  if variant == "rushhour":
    result.demandWarmPermille = 80
    result.demandPeakStart = 24
    result.demandPeakPermille = 240
    result.demandPeakEnd = 160
    result.demandDeclinePermille = 120
    result.throughRunnerPermille = 650
    result.parThroughput = 380
  result.update("{}")

proc emptyConfig*(): GameConfig =
  ## A city with NO demand at all, so a test can place its own cars and know
  ## nothing else moves.
  result = testConfig()
  result.demandWarmPermille = 0
  result.demandPeakPermille = 0
  result.demandDeclinePermille = 0
  result.update("{}")

proc newSim*(config: GameConfig): SimServer =
  result = initSimServer(config)
  result.phase = Playing

proc placeCar*(
  sim: var SimServer, link, cell, originGate, destGate: int
): int =
  ## Puts one car on a link cell with a chosen route. Returns its id.
  result = sim.allocCar()
  doAssert result >= 0
  sim.cars[result].spawnTick = sim.tickCount
  sim.cars[result].originGate = originGate
  sim.cars[result].destGate = destGate
  sim.cars[result].link = link
  sim.cars[result].cell = cell
  sim.cars[result].queueGate = -1
  sim.setOccupant(link, cell, result)
  inc sim.liveCars

proc setOrder*(
  sim: var SimServer, at: int, verb: OrderVerb, phase = phNSG, delay = 0
) =
  sim.signals[at].order = SignalOrder(
    verb: verb, phase: phase, delay: delay, turn: sim.turn, outcome: orUnknown)

proc forcePhase*(sim: var SimServer, at: int, phase: PhaseId) =
  ## Puts an intersection in a phase immediately, past minGreen and clearance,
  ## so a test can start from a known signal state.
  sim.signals[at].phase = phase
  sim.signals[at].requested = phase
  sim.signals[at].clearLeft = 0
  sim.signals[at].ticksInPhase = sim.config.minGreenTicks

proc runScripted*(
  config: GameConfig, kinds: openArray[Baseline]
): SimServer =
  ## A whole episode with no server and no sockets, one baseline per seat.
  result = newSim(config)
  for turnIndex in 1 .. result.turnsPerEpisode():
    if result.settled:
      break
    result.turn = turnIndex
    for slot in 0 ..< MaxSeats:
      let kind = kinds[slot mod kinds.len]
      result.applyReply(slot, result.scriptedReply(slot, kind))
      result.policyKinds[slot] = "scripted"
      result.players[slot].joined = true
      result.players[slot].registered = true
    for k in 0 ..< config.turnTicks:
      if result.settled:
        break
      result.stepTick(k)
    result.turnsPlayed = turnIndex
  if not result.settled:
    result.applyStop(erFullPeriod, "")

proc manifestJson*(): JsonNode =
  ## The manifest template, from the repo root, whichever directory the test
  ## binary was started in.
  for candidate in ["coworld_manifest_template.json",
                    "../coworld_manifest_template.json"]:
    if fileExists(candidate):
      return parseJson(readFile(candidate))
  raise newException(IOError, "coworld_manifest_template.json not found")

proc repoFile*(path: string): string =
  for prefix in ["", "../"]:
    if fileExists(prefix & path):
      return readFile(prefix & path)
  raise newException(IOError, path & " not found")

proc repoPath*(path: string): string =
  for prefix in ["", "../"]:
    if fileExists(prefix & path) or dirExists(prefix & path):
      return prefix & path
  path
