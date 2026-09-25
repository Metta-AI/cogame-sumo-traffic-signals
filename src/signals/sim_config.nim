## The `GameConfig` lifecycle: the shipped defaults and `config.update`, which
## folds one runtime JSON config over them. Forked from the starter's
## `src/ctf/sim_config.nim`, retargeted to the traffic-signal knobs.
##
## Every key here is echoed back into the replay's config JSON, so a viewer
## holding the bytes rebuilds the identical city and re-simulates every car.

import
  std/[json, strutils],
  sim_types

proc defaultGameConfig*(): GameConfig =
  result = GameConfig(
    seed: 0xA6019,
    variant: "grid4x4",
    numAgents: MaxSeats,
    minPlayers: MaxSeats,
    players: @[],
    slots: @[],
    tokens: @[],
    turnTicks: DefaultTurnTicks,
    maxTicks: DefaultMaxTicks,
    ewLinkCells: DefaultEwLinkCells,
    nsLinkCells: DefaultNsLinkCells,
    ewGateCells: DefaultEwGateCells,
    nsGateCells: DefaultNsGateCells,
    gateQueueCap: DefaultGateQueueCap,
    minGreenTicks: DefaultMinGreenTicks,
    clearTicks: DefaultClearTicks,
    maxRedTicks: DefaultMaxRedTicks,
    demandWarmPermille: DefaultDemandWarmPermille,
    demandPeakStart: DefaultDemandPeakStart,
    demandPeakPermille: DefaultDemandPeakPermille,
    demandPeakEnd: DefaultDemandPeakEnd,
    demandDeclinePermille: DefaultDemandDeclinePermille,
    demandEndTick: DefaultDemandEndTick,
    throughRunnerPermille: DefaultThroughRunnerPermille,
    parThroughput: DefaultParThroughput,
    ringTicks: DefaultRingTicks,
    gridlockStallTicks: DefaultGridlockStallTicks,
    waveVehicles: DefaultWaveVehicles,
    waveWindow: DefaultWaveWindow,
    waveCrossings: DefaultWaveCrossings,
    switchMargin: DefaultSwitchMargin,
    greenCap: DefaultGreenCap,
    turnBudgetMs: DefaultTurnBudgetMs,
    wallClockBudgetSeconds: DefaultWallClockBudgetSeconds,
    lobbyJoinTimeoutTicks: DefaultLobbyJoinTimeoutTicks,
    gameOverTicks: DefaultGameOverTicks,
    fastMode: true,
    showPlayerLabels: false,
    speed: 1
  )
  for slot in 0 ..< MaxSeats:
    result.players.add(seatAlias(slot))

proc readInt(node: JsonNode, key: string, value: var int) =
  let item = node{key}
  if item.isNil:
    return
  case item.kind
  of JInt: value = int(item.getBiggestInt())
  of JFloat: value = int(item.getFloat())
  of JString:
    try: value = parseInt(item.getStr().strip())
    except ValueError: discard
  else: discard

proc readBool(node: JsonNode, key: string, value: var bool) =
  let item = node{key}
  if item.isNil:
    return
  case item.kind
  of JBool: value = item.getBool()
  of JInt: value = item.getBiggestInt() != 0
  of JString:
    let text = item.getStr().strip().toLowerAscii()
    if text in ["1", "true", "on", "yes"]: value = true
    elif text in ["0", "false", "off", "no"]: value = false
  else: discard

proc readStr(node: JsonNode, key: string, value: var string) =
  let item = node{key}
  if not item.isNil and item.kind == JString:
    value = item.getStr()

proc clampConfig(config: var GameConfig) =
  ## Bounds every knob the runner can set, so a hostile or fat-fingered
  ## variant cannot produce an illegal city or an unbounded wait.
  config.numAgents = MaxSeats
  config.minPlayers = clamp(config.minPlayers, 1, MaxSeats)
  config.turnTicks = clamp(config.turnTicks, 2, 64)
  config.maxTicks = clamp(config.maxTicks, config.turnTicks, 4096)
  config.ewLinkCells = clamp(config.ewLinkCells, 2, 16)
  config.nsLinkCells = clamp(config.nsLinkCells, 2, 16)
  config.ewGateCells = clamp(config.ewGateCells, 1, 16)
  config.nsGateCells = clamp(config.nsGateCells, 1, 16)
  config.gateQueueCap = clamp(config.gateQueueCap, 1, 64)
  config.minGreenTicks = clamp(config.minGreenTicks, 1, 32)
  config.clearTicks = clamp(config.clearTicks, 0, 16)
  config.maxRedTicks = clamp(config.maxRedTicks, config.minGreenTicks, 512)
  config.demandWarmPermille = clamp(config.demandWarmPermille, 0, 1000)
  config.demandPeakPermille = clamp(config.demandPeakPermille, 0, 1000)
  config.demandDeclinePermille = clamp(config.demandDeclinePermille, 0, 1000)
  config.demandPeakStart = clamp(config.demandPeakStart, 0, config.maxTicks)
  config.demandPeakEnd =
    clamp(config.demandPeakEnd, config.demandPeakStart, config.maxTicks)
  config.demandEndTick =
    clamp(config.demandEndTick, config.demandPeakEnd, config.maxTicks)
  config.throughRunnerPermille = clamp(config.throughRunnerPermille, 0, 1000)
  config.parThroughput = clamp(config.parThroughput, 0, 100_000)
  config.ringTicks = clamp(config.ringTicks, 1, 512)
  config.gridlockStallTicks = clamp(config.gridlockStallTicks, 4, 512)
  config.waveVehicles = clamp(config.waveVehicles, 2, 64)
  config.waveWindow = clamp(config.waveWindow, 2, 256)
  config.waveCrossings = clamp(config.waveCrossings, 2, 16)
  config.switchMargin = clamp(config.switchMargin, 0, 32)
  config.greenCap = clamp(config.greenCap, 1, 64)
  config.turnBudgetMs = clamp(config.turnBudgetMs, 1000, 240_000)
  ## 660 s is the engine's own stop, inside 60 % of the assumed 1200 s
  ## `episodeTimeoutSeconds`. A variant may lower it, never raise it.
  config.wallClockBudgetSeconds =
    clamp(config.wallClockBudgetSeconds, 30, DefaultWallClockBudgetSeconds)
  config.lobbyJoinTimeoutTicks = clamp(config.lobbyJoinTimeoutTicks, 1, 100_000)
  config.gameOverTicks = clamp(config.gameOverTicks, 0, 1000)
  config.speed = clamp(config.speed, 1, PlaybackSpeeds[^1])
  if config.players.len < MaxSeats:
    for slot in config.players.len ..< MaxSeats:
      config.players.add(seatAlias(slot))
  if config.players.len > MaxSeats:
    config.players.setLen(MaxSeats)
  if config.tokens.len > MaxSeats:
    config.tokens.setLen(MaxSeats)

proc update*(config: var GameConfig, configJson: string) =
  ## Folds one runtime JSON config over the defaults. Unknown keys are
  ## ignored; a malformed document raises, because a silently-defaulted
  ## episode is a worse outcome than a loud one.
  if configJson.len > 0:
    var node: JsonNode
    try:
      node = parseJson(configJson)
    except CatchableError as error:
      raise newException(
        SignalsError, "game config is not valid JSON: " & error.msg)
    if node.kind != JObject:
      raise newException(SignalsError, "game config must be a JSON object")

    node.readInt("seed", config.seed)
    node.readStr("variant", config.variant)
    node.readInt("num_agents", config.numAgents)
    node.readInt("numAgents", config.numAgents)
    node.readInt("minPlayers", config.minPlayers)
    node.readInt("turnTicks", config.turnTicks)
    node.readInt("maxTicks", config.maxTicks)
    node.readInt("ewLinkCells", config.ewLinkCells)
    node.readInt("nsLinkCells", config.nsLinkCells)
    node.readInt("ewGateCells", config.ewGateCells)
    node.readInt("nsGateCells", config.nsGateCells)
    node.readInt("gateQueueCap", config.gateQueueCap)
    node.readInt("minGreenTicks", config.minGreenTicks)
    node.readInt("clearTicks", config.clearTicks)
    node.readInt("maxRedTicks", config.maxRedTicks)
    node.readInt("demandWarmPermille", config.demandWarmPermille)
    node.readInt("demandPeakStart", config.demandPeakStart)
    node.readInt("demandPeakPermille", config.demandPeakPermille)
    node.readInt("demandPeakEnd", config.demandPeakEnd)
    node.readInt("demandDeclinePermille", config.demandDeclinePermille)
    node.readInt("demandEndTick", config.demandEndTick)
    node.readInt("throughRunnerPermille", config.throughRunnerPermille)
    node.readInt("parThroughput", config.parThroughput)
    node.readInt("ringTicks", config.ringTicks)
    node.readInt("gridlockStallTicks", config.gridlockStallTicks)
    node.readInt("waveVehicles", config.waveVehicles)
    node.readInt("waveWindow", config.waveWindow)
    node.readInt("waveCrossings", config.waveCrossings)
    node.readInt("switchMargin", config.switchMargin)
    node.readInt("greenCap", config.greenCap)
    node.readInt("turnBudgetMs", config.turnBudgetMs)
    node.readInt("wallClockBudgetSeconds", config.wallClockBudgetSeconds)
    node.readInt("lobbyJoinTimeoutTicks", config.lobbyJoinTimeoutTicks)
    node.readInt("gameOverTicks", config.gameOverTicks)
    node.readBool("fastMode", config.fastMode)
    node.readBool("showPlayerLabels", config.showPlayerLabels)
    node.readInt("speed", config.speed)

    let players = node{"players"}
    if not players.isNil and players.kind == JArray:
      config.players = @[]
      for item in players:
        if item.kind == JString:
          config.players.add(item.getStr())
        elif item.kind == JObject:
          config.players.add(item{"name"}.getStr())
    let slots = node{"slots"}
    if not slots.isNil and slots.kind == JArray:
      config.slots = @[]
      for item in slots:
        if item.kind == JInt:
          config.slots.add(int(item.getBiggestInt()))
    let tokens = node{"tokens"}
    if not tokens.isNil and tokens.kind == JArray:
      config.tokens = @[]
      for item in tokens:
        if item.kind == JString:
          config.tokens.add(item.getStr())
  config.clampConfig()

proc configJson*(config: GameConfig): string =
  ## The RESOLVED config, written into the replay header. Tokens are NEVER
  ## written: they are runner-injected credentials, not game rules.
  var players = newJArray()
  for name in config.players:
    players.add(%name)
  var slots = newJArray()
  for slot in config.slots:
    slots.add(%slot)
  $(%*{
    "seed": config.seed,
    "variant": config.variant,
    "num_agents": config.numAgents,
    "minPlayers": config.minPlayers,
    "players": players,
    "slots": slots,
    "turnTicks": config.turnTicks,
    "maxTicks": config.maxTicks,
    "ewLinkCells": config.ewLinkCells,
    "nsLinkCells": config.nsLinkCells,
    "ewGateCells": config.ewGateCells,
    "nsGateCells": config.nsGateCells,
    "gateQueueCap": config.gateQueueCap,
    "minGreenTicks": config.minGreenTicks,
    "clearTicks": config.clearTicks,
    "maxRedTicks": config.maxRedTicks,
    "demandWarmPermille": config.demandWarmPermille,
    "demandPeakStart": config.demandPeakStart,
    "demandPeakPermille": config.demandPeakPermille,
    "demandPeakEnd": config.demandPeakEnd,
    "demandDeclinePermille": config.demandDeclinePermille,
    "demandEndTick": config.demandEndTick,
    "throughRunnerPermille": config.throughRunnerPermille,
    "parThroughput": config.parThroughput,
    "ringTicks": config.ringTicks,
    "gridlockStallTicks": config.gridlockStallTicks,
    "waveVehicles": config.waveVehicles,
    "waveWindow": config.waveWindow,
    "waveCrossings": config.waveCrossings,
    "switchMargin": config.switchMargin,
    "greenCap": config.greenCap,
    "wallClockBudgetSeconds": config.wallClockBudgetSeconds,
    "lobbyJoinTimeoutTicks": config.lobbyJoinTimeoutTicks,
    "gameOverTicks": config.gameOverTicks,
    "fastMode": config.fastMode,
    "showPlayerLabels": config.showPlayerLabels
  })

proc turnsPerEpisode*(config: GameConfig): int =
  ## 32 command turns for the shipped 256-tick / 8-tick-turn schedule.
  if config.turnTicks <= 0: 0 else: config.maxTicks div config.turnTicks

proc permilleAt*(config: GameConfig, tick: int): int =
  ## The demand rate schedule of tick step 7 — warm, peak, decline, then off.
  if tick >= config.demandEndTick: 0
  elif tick < config.demandPeakStart: config.demandWarmPermille
  elif tick < config.demandPeakEnd: config.demandPeakPermille
  else: config.demandDeclinePermille
