## The sim's shared vocabulary: the core constants (including GameVersion and
## its prepend-only changelog), the gameplay/wire types, and the pure helpers
## every leaf module needs — split out of `sim.nim` the way the starter
## (`src/ctf/sim_types.nim`) splits it, so `city`, `vehicles`, `phases`,
## `flow`, `sim_config`, `sim_state` and `roster` can share them without
## importing gameplay.
##
## FORKED FROM coworld-ctf. Field/declaration ORDER in the wire types below is
## the wire format: the replay's config JSON and the per-tick `gameHash` are
## both derived positionally from these, so nothing is reordered without a
## GameVersion bump.

import
  std/[strutils, unicode]

const
  GameName* = "sumo-traffic-signals"
  PlayerProtocolId* = "signals.player.v2"
  GameVersion* = "1"  ## GV1 (first rule set): SIXTEEN SIGNALISED INTERSECTIONS
    ## on a 4x4 city grid, four controllers with a quadrant each. Cars enter
    ## from sixteen edge gates, drive fixed shortest routes over single-lane
    ## approaches made of cells, and are discharged at stop lines by a
    ## four-phase NEMA-style signal plan (NSG/NSL/EWG/EWL) with a flat all-red
    ## clearance, a minimum green and a maximum red. A green into a FULL block
    ## moves nobody, which is the whole game: your green is your neighbour's
    ## queue. Everyone is scored on one number — how many cars got out of the
    ## city — with network waiting as the tie-break and own-quadrant waiting
    ## as the tie-break after that.
    ##
    ## The starter's version chain restarts here: the rules, the board, the
    ## hash mix and the replay magic (`COWLDSIG`) are all new, so no
    ## coworld-ctf replay is loadable and none should be.

  TargetFps* = 24
    ## Presentation frames per second. The SIM's tick is one simulated SECOND
    ## (see `maxTicks`), but the replay timeline, the transport keymap and the
    ## viewer's pacing all derive from this one number, exactly as in the
    ## starter.
  ReplayFps* = TargetFps
  PlaybackSpeeds* = [1, 2, 4, 8, 16]
    ## Replay playback speed steps. Lives here (not in `replays`) so every
    ## layer that must agree — the transport keymap, the JS clients' wire
    ## constants — derives from ONE table.

  MaxSeats* = 4                ## controllers, always four (design §Seats).
  Rows* = 4
  Cols* = 4
  Intersections* = Rows * Cols ## 16, indexed rowIndex * 4 + colIndex.
  Gates* = 16                  ## edge gates, each a source AND a sink.
  Approaches* = 4              ## N, E, S, W at every intersection.
  MaxLinks* = 80               ## directed, one-way, single-lane links.
  MaxVehicles* = 1024          ## fixed car slots; a slot frees on exit.
  MaxCells* = 512              ## ceiling on total link cells (352 shipped).

  # --- rune caps (RE-PINNED in this fork; see design §Reply schema) ---
  MaxSayRunes* = 120           ## the control-room radio call.
  MaxNoteRunes* = 240          ## the seat's private note, echoed back.
  MaxPolicyLabelRunes* = 64    ## `register.policy` cap, in RUNES.
  MaxFallbackDetailRunes* = 200 ## `fallback.detail` cap, in RUNES.
  MaxDirectiveRunes* = 4000    ## whole serialized `directive` record cap.
  MaxPromptRunes* = 4000       ## PLAYER_PROMPT transport cap (truncate, never
                               ## reject); never written to the replay.
  MaxStopDetailRunes* = 200    ## `results.stopDetail` cap, in RUNES.
  MaxReplyBytes* = 4096        ## bytes read from the provider before parsing.
  MaxOrdersPerReply* = 4       ## one per owned intersection.
  MaxRadioLines* = 3           ## radio lines carried into an observation.

  # --- timing defaults (design §Decisions, the budget table) ---
  DefaultTurnTicks* = 8
  DefaultMaxTicks* = 256
  DefaultTurnBudgetMs* = 14_000
  DefaultWallClockBudgetSeconds* = 660

  # --- city defaults (design §The city) ---
  DefaultEwLinkCells* = 6
  DefaultNsLinkCells* = 4
  DefaultEwGateCells* = 4
  DefaultNsGateCells* = 3
  DefaultGateQueueCap* = 12
  DefaultMinGreenTicks* = 4
  DefaultClearTicks* = 2
  DefaultMaxRedTicks* = 60
  DefaultDemandWarmPermille* = 60
  DefaultDemandPeakStart* = 32
  DefaultDemandPeakPermille* = 180
  DefaultDemandPeakEnd* = 144
  DefaultDemandDeclinePermille* = 80
  DefaultDemandEndTick* = 208
  DefaultThroughRunnerPermille* = 450
  DefaultParThroughput* = 260
  DefaultRingTicks* = 20
  DefaultGridlockStallTicks* = 40
  DefaultWaveVehicles* = 4
  DefaultWaveWindow* = 16
  DefaultWaveCrossings* = 3
  DefaultSwitchMargin* = 2
  DefaultGreenCap* = 6
  DefaultLobbyJoinTimeoutTicks* = 2400
  DefaultGameOverTicks* = 48

  # --- scoring (design §Scoring formula and sign) ---
  ThroughputWeight* = 1_000_000
  NetWaitWeight* = 1_000
  SeatWaitWeight* = 10
  NetWaitDivisor* = 200
  NetWaitCap* = 999
  SeatWaitDivisor* = 800
  SeatWaitCap* = 99

  BoardCellsWide* = 34         ## design §The city, board size in cells.
  BoardCellsHigh* = 26

type
  SignalsError* = object of CatchableError
    ## Every raise inside the sim/server is this or a descendant, so the
    ## episode-settling `except` in the server loop can never miss one.

  PhaseId* = enum
    ## The four selectable phases plus the non-selectable all-red clearance.
    ## Index order is the wire order and the tie-break order.
    phNSG = "NSG"              ## N + S: through, right
    phNSL = "NSL"              ## N + S: left
    phEWG = "EWG"              ## E + W: through, right
    phEWL = "EWL"              ## E + W: left
    phCLR = "CLR"              ## all-red clearance; never selectable

  Movement* = enum
    mvNone = "none"
    mvThrough = "through"
    mvLeft = "left"
    mvRight = "right"

  Approach* = enum
    ## Named by the direction traffic arrives FROM. Fixed order N, E, S, W is
    ## every "lowest approach index" tie-break in the design note.
    apN = "N"
    apE = "E"
    apS = "S"
    apW = "W"

  OrderVerb* = enum
    ovHold = "hold"
    ovPhase = "phase"
    ovWave = "wave"
    ovAuto = "auto"

  BlockCause* = enum
    bcNone = "none"
    bcPhase = "phase"
    bcSpillback = "spillback"

  OrderResult* = enum
    orUnknown = "unknown"
    orRan = "ran"
    orDeferred = "deferred"
    orOverridden = "overridden"
    orRepaired = "repaired"

  GamePhase* = enum
    Lobby
    Playing
    GameOver

  EndRule* = enum
    erNone = "none"
    erCleared = "cleared"
    erGridlock = "gridlock"
    erFullPeriod = "fullPeriod"
    erWallClock = "wallClock"
    erFault = "fault"

  EndReason* = enum
    ## `results.reason` is a CLOSED enum of exactly three values.
    rsNone = "none"
    rsComplete = "complete"
    rsDeadline = "deadline"
    rsFault = "fault"

  SignalOrder* = object
    ## One intersection's standing order. A signal keeps its order until the
    ## owning seat changes it; turn 1's default is `auto`.
    verb*: OrderVerb
    phase*: PhaseId            ## meaningful for ovPhase / ovWave.
    delay*: int                ## meaningful for ovWave, 0 .. turnTicks-2.
    turn*: int                 ## the turn this order was installed on.
    outcome*: OrderResult      ## the driver's honest report, fed back next turn.

  PlayerSlot* = object
    ## One seat, as the roster sees it. `name` is the REAL policy/player name
    ## and appears only spectator-side; `alias` is the in-game name.
    name*: string
    alias*: string
    quadrant*: string
    token*: string
    slot*: int
    joined*: bool
    left*: bool
    registered*: bool
    policy*: string
    kind*: string              ## "llm" | "scripted"
    baseline*: string

  GameConfig* = object
    ## The resolved episode config. Every field is echoed into the replay's
    ## config JSON, so the wasm viewer reconstructs the identical city and
    ## re-simulates every car from bytes it already has.
    seed*: int
    variant*: string
    numAgents*: int
    minPlayers*: int
    players*: seq[string]
    slots*: seq[int]
    tokens*: seq[string]
    turnTicks*: int
    maxTicks*: int
    ewLinkCells*: int
    nsLinkCells*: int
    ewGateCells*: int
    nsGateCells*: int
    gateQueueCap*: int
    minGreenTicks*: int
    clearTicks*: int
    maxRedTicks*: int
    demandWarmPermille*: int
    demandPeakStart*: int
    demandPeakPermille*: int
    demandPeakEnd*: int
    demandDeclinePermille*: int
    demandEndTick*: int
    throughRunnerPermille*: int
    parThroughput*: int
    ringTicks*: int
    gridlockStallTicks*: int
    waveVehicles*: int
    waveWindow*: int
    waveCrossings*: int
    switchMargin*: int
    greenCap*: int
    turnBudgetMs*: int
    wallClockBudgetSeconds*: int
    lobbyJoinTimeoutTicks*: int
    gameOverTicks*: int
    fastMode*: bool
    showPlayerLabels*: bool
    speed*: int

const
  ApproachOrder* = [apN, apE, apS, apW]
  SelectablePhases* = [phNSG, phNSL, phEWG, phEWL]
  RowNames* = ["A", "B", "C", "D"]
  ColNames* = ["1", "2", "3", "4"]
  QuadrantNames*: array[MaxSeats, string] = ["NW", "NE", "SW", "SE"]
  SeatColours*: array[MaxSeats, string] = ["red", "blue", "green", "yellow"]
  IdentityNames*: array[MaxSeats, string] = ["alpha", "beta", "gamma", "delta"]
    ## The starter's `roster.nim:64` identity table, unchanged. `seatAlias`
    ## title-cases them for display: Alpha, Beta, Gamma, Delta.

proc truncateRunes*(text: string, limit: int): string =
  ## Cuts `text` to at most `limit` RUNES, on a rune boundary. The single
  ## place any recorded string is shortened — never a byte slice, because a
  ## byte-truncated codepoint renders in a browser and then fails a strict
  ## UTF-8 parser.
  if limit <= 0:
    return ""
  if text.runeLen <= limit:
    return text
  text.runeSubStr(0, limit)

proc truncateBytes*(text: string, maxBytes: int): string =
  ## Cuts `text` to at most `maxBytes` BYTES, still on a rune boundary. The
  ## byte caps (the provider read) need this: `truncateRunes(4096)` bounds
  ## runes, so a 4-byte-per-rune reply survived at ~16 KB and the "bounded
  ## read" was not bounded in the unit it is written in.
  if maxBytes <= 0:
    return ""
  if text.len <= maxBytes:
    return text
  var bytes = 0
  for rune in text.runes:
    let size = rune.size
    if bytes + size > maxBytes:
      break
    result.add(rune)
    bytes += size

proc seatAlias*(slot: int): string =
  ## The seat's in-game name. The ONLY name that may appear in an
  ## observation, a prompt, an order, a `say`, a radio line or a board label.
  if slot < 0 or slot >= MaxSeats:
    return "Seat"
  let raw = IdentityNames[slot]
  raw[0].toUpperAscii() & raw[1 .. ^1]

proc seatQuadrant*(slot: int): string =
  ## NW / NE / SW / SE, fixed by slot so a replay is readable.
  if slot < 0 or slot >= MaxSeats: "" else: QuadrantNames[slot]

proc seatColour*(slot: int): string =
  if slot < 0 or slot >= MaxSeats: "" else: SeatColours[slot]

proc intersectionName*(index: int): string =
  ## `A1` .. `D4` for index 0 .. 15.
  if index < 0 or index >= Intersections:
    return ""
  RowNames[index div Cols] & ColNames[index mod Cols]

proc intersectionIndex*(name: string): int =
  ## The index of an intersection id, or -1. Upper-cased before matching.
  let key = name.strip().toUpperAscii()
  if key.len != 2:
    return -1
  for row in 0 ..< Rows:
    for col in 0 ..< Cols:
      if RowNames[row] == $key[0] and ColNames[col] == $key[1]:
        return row * Cols + col
  -1

proc ownerOf*(intersection: int): int =
  ## Which seat owns an intersection. Quadrants, by slot, never randomised:
  ## Alpha NW (A1 A2 B1 B2), Beta NE, Gamma SW, Delta SE.
  if intersection < 0 or intersection >= Intersections:
    return -1
  let
    row = intersection div Cols
    col = intersection mod Cols
    north = row < Rows div 2
    west = col < Cols div 2
  if north and west: 0
  elif north: 1
  elif west: 2
  else: 3

proc quadrantIntersections*(slot: int): array[4, int] =
  ## The four intersections a seat owns, ascending by index.
  var found = 0
  for i in 0 ..< Intersections:
    if ownerOf(i) == slot:
      result[found] = i
      inc found

proc phaseGreens*(phase: PhaseId): array[2, Approach] =
  ## The two approaches a phase greens. `phCLR` greens nothing; callers must
  ## check for clearance before asking.
  case phase
  of phNSG, phNSL: [apN, apS]
  of phEWG, phEWL: [apE, apW]
  of phCLR: [apN, apS]

proc phasePermits*(phase: PhaseId, approach: Approach, movement: Movement): bool =
  ## The permitted-movement table of design §Signal phases. Clearance permits
  ## nothing at all.
  if phase == phCLR or movement == mvNone:
    return false
  let greens = phaseGreens(phase)
  if approach != greens[0] and approach != greens[1]:
    return false
  case phase
  of phNSG, phEWG: movement == mvThrough or movement == mvRight
  of phNSL, phEWL: movement == mvLeft
  of phCLR: false

proc phaseServing*(approach: Approach, movement: Movement): PhaseId =
  ## The phase that permits one movement on one approach. Total over the
  ## legal (approach, movement) pairs, which is what makes the starvation
  ## override of tick step 2e always have an answer.
  let northSouth = approach == apN or approach == apS
  case movement
  of mvLeft:
    if northSouth: phNSL else: phEWL
  else:
    if northSouth: phNSG else: phEWG

proc mix64*(a, b, c: int): uint64 =
  ## splitmix64 over three integer coordinates. The sim's ONE seeded source,
  ## and it is a HASH, not a stream: whether gate `g` produces a car at tick
  ## `t` is `mix64(seed, g, t)`, evaluated independently for every pair, so no
  ## ordering of decisions by any seat can shift, reorder or consume another
  ## seat's arrivals.
  var x = uint64(a) xor (uint64(b) * 1000003'u64) xor
    (uint64(c) * 6364136223846793005'u64)
  x = x + 0x9E3779B97F4A7C15'u64
  var z = x
  z = (z xor (z shr 30)) * 0xBF58476D1CE4E5B9'u64
  z = (z xor (z shr 27)) * 0x94D049BB133111EB'u64
  z xor (z shr 31)

proc mixHash*(hash: var uint64, value: int) =
  ## Folds one integer into the running per-tick `gameHash`. Order-sensitive
  ## by construction — the mix order in `sim.nim` is the wire format.
  hash = hash xor uint64(value) * 0x100000001B3'u64
  hash = (hash shl 13) or (hash shr 51)
  hash = hash * 0x9E3779B97F4A7C15'u64

proc scoreFor*(throughput, netWaitK, seatWaitK: int): int =
  ## The whole scoring formula, in one place, so the sim, the tests and the
  ## endcard cannot drift. Higher is better; both waiting terms only ever
  ## subtract.
  ThroughputWeight * throughput - NetWaitWeight * netWaitK -
    SeatWaitWeight * seatWaitK

proc netWaitKOf*(networkWaitTicks: int): int =
  min(NetWaitCap, networkWaitTicks div NetWaitDivisor)

proc seatWaitKOf*(seatWaitTicks: int): int =
  min(SeatWaitCap, seatWaitTicks div SeatWaitDivisor)
