## The game server: the mummy HTTP/websocket server implementing the Coworld
## contract, and the episode loop. Forked from the starter's
## `src/ctf/server.nim` with the three named edits of design §The three named
## edits to `server.nim`:
##
##   1. **Turn boundary** — unchanged in shape, with `turnTicks = 8` and FOUR
##      seats in the batch.
##   2. **Registration interception** — a player's Sprite v1 chat message
##      (`0x81`) whose text parses as a registration object is consumed as
##      REGISTRATION, not applied as a shout and not written to the replay chat
##      stream; the server writes a redacted `register` record instead. An
##      unappliable registration is HELD and re-read when the slot lands, and
##      the server logs loudly and refuses to start the game when a joined seat
##      has no register record (the grf-football 2026-08-27 silent-default
##      scar). Any other chat text from a seat is dropped — controllers speak
##      through `say`.
##   3. **Wall-clock stop** — checked at the top of every loop iteration,
##      forcing `reason = deadline`, `endRule = wallClock`, and written as the
##      load-bearing stop RECORD so the replay re-derives it rather than
##      inferring it.
##
## The certifier's browser probes are served for real and registered BEFORE any
## catch-all asset route: `GET /client/player?slot=&token=` (token-checked, and
## it must NOT open the player socket), `GET /client/global`, the `/global`
## websocket's first message, and `/healthz` — all kept answering for the
## `gameOverTicks` grace after the artifacts are written (the lantern 0.1.1 and
## 0.1.3 scars).

import
  std/[json, locks, monotimes, os, strutils, tables, times],
  bitworld/[runtime, spriteprotocol],
  mummy,
  sim, roster, replays, broadcast, global, replay_runtime, decide, events,
  wire_constants

const
  HealthPath = "/healthz"
  PlayerWsPath = "/player"
  GlobalWsPath = "/global"
  ClientPlayerPath = "/client/player"
  ClientGlobalPath = "/client/global"
  ClientReplayPath = "/client/replay"
  ClientLeaguePath = "/client/league"
  ReplayDataPath = "/replay-data"
  FontPath = "/client/font.ttf"
  MaxWsFrameBytes* = 900_000
    ## Hosted replay closes any websocket frame larger than 1 MiB; outbound
    ## packets stay under a margin below that.

  EmbeddedBroadcastPage = staticRead("../../client/replay_broadcast.html")
    .replace(
      "<!-- CHROME_COMMON -->",
      "<script>" & staticRead("../../client/chrome_common.js") & "</script>")
    .replace(
      "<!-- BROADCAST_CORE -->",
      "<script>" & staticRead("../../client/broadcast_core.js") & "</script>")
    .spliceWireConstants()
  BroadcastFont = staticRead("../../data/font.ttf")
  LockerRoomAssets = [
    ("/client/art/lockerroom/bg.jpg",
      staticRead("../../client/art/lockerroom/bg.jpg")),
    ("/client/art/lockerroom/red_1.webp",
      staticRead("../../client/art/lockerroom/red_1.webp")),
    ("/client/art/lockerroom/blue_1.webp",
      staticRead("../../client/art/lockerroom/blue_1.webp")),
    ("/client/art/lockerroom/green_1.webp",
      staticRead("../../client/art/lockerroom/green_1.webp")),
    ("/client/art/lockerroom/yellow_1.webp",
      staticRead("../../client/art/lockerroom/yellow_1.webp"))
  ]
  WallAssets = [
    ("/client/art/walls/wall_h.jpg",
      staticRead("../../client/art/walls/wall_h.jpg")),
    ("/client/art/walls/wall_v.jpg",
      staticRead("../../client/art/walls/wall_v.jpg"))
  ]

type
  AppState = object
    lock: Lock
    playerSlots: Table[WebSocket, int]
    playerTokens: Table[WebSocket, string]
    pendingRegistration: Table[WebSocket, string]
    globalViewers: Table[WebSocket, GlobalViewerState]
    closedSockets: seq[WebSocket]
    replayUri: string
    tokens: seq[string]
    seats: int

  ServerThreadArgs = object
    server: ptr Server
    address: string
    port: int

var appState: AppState
initLock(appState.lock)

proc isWebSocketUpgrade(request: Request): bool =
  request.headers["Sec-WebSocket-Key"].len > 0

proc textHeaders(contentType: string): HttpHeaders =
  result["Content-Type"] = contentType
  result["Cache-Control"] = "no-cache"

proc slotTokenOk(slot: int, token: string): bool =
  {.gcsafe.}:
    withLock appState.lock:
      if slot < 0 or slot >= appState.seats:
        return false
      if slot >= appState.tokens.len or appState.tokens[slot].len == 0:
        return true
      return appState.tokens[slot] == token

proc httpHandler(request: Request) =
  let path = request.path
  if path == HealthPath and request.httpMethod == "GET":
    request.respond(200, textHeaders("text/plain; charset=utf-8"), "healthy")
  elif path == PlayerWsPath and request.httpMethod == "GET" and
      request.isWebSocketUpgrade():
    let
      slotText = request.queryParams["slot"]
      token = request.queryParams["token"]
      slot = try: parseInt(slotText) except ValueError: -1
    ## The player websocket handler CLOSES unless the token matches the seat —
    ## the certifier probes with a wrong token (cogame-flatland 0.1.1).
    if not slotTokenOk(slot, token):
      request.respond(403, textHeaders("text/plain"), "bad player token\n")
      return
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.playerSlots[websocket] = slot
        appState.playerTokens[websocket] = token
    echo "player connected: slot ", slot
  elif path == GlobalWsPath and request.httpMethod == "GET" and
      request.isWebSocketUpgrade():
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.globalViewers[websocket] = initGlobalViewerState()
  elif path == ClientPlayerPath and request.httpMethod == "GET":
    ## Served for real, token-checked, and it must NOT open the player socket.
    let
      slotText = request.queryParams["slot"]
      token = request.queryParams["token"]
      slot = try: parseInt(slotText) except ValueError: 0
    if slotText.len > 0 and not slotTokenOk(slot, token):
      request.respond(403, textHeaders("text/plain"), "bad player token\n")
      return
    request.respond(200, textHeaders("text/html; charset=utf-8"),
      EmbeddedBroadcastPage)
  elif (path == ClientGlobalPath or path == ClientReplayPath or
      path == ClientLeaguePath) and request.httpMethod == "GET":
    request.respond(200, textHeaders("text/html; charset=utf-8"),
      EmbeddedBroadcastPage)
  elif path == FontPath and request.httpMethod == "GET":
    request.respond(200, textHeaders("font/ttf"), BroadcastFont)
  elif path == ReplayDataPath and request.httpMethod == "GET":
    var uri = ""
    {.gcsafe.}:
      withLock appState.lock:
        uri = appState.replayUri
    if uri.len == 0:
      request.respond(404, textHeaders("text/plain"), "no replay loaded\n")
    else:
      request.respond(200, textHeaders("application/json"),
        $(%*{"uri": uri}))
  else:
    var served = false
    for entry in LockerRoomAssets:
      if path == entry[0]:
        request.respond(200, textHeaders(
          if path.endsWith(".jpg"): "image/jpeg" else: "image/webp"), entry[1])
        served = true
        break
    if not served:
      for entry in WallAssets:
        if path == entry[0]:
          request.respond(200, textHeaders("image/jpeg"), entry[1])
          served = true
          break
    if not served:
      if path == "/" and request.httpMethod == "GET":
        request.respond(200, textHeaders("text/html; charset=utf-8"),
          EmbeddedBroadcastPage)
      else:
        request.respond(404, textHeaders("text/plain"), "not found\n")

proc websocketHandler(
  websocket: WebSocket, event: WebSocketEvent, message: Message
) =
  case event
  of OpenEvent:
    discard
  of MessageEvent:
    if message.kind == Ping:
      ## Restore the Ping -> Pong branch and guard NOTHING else: a
      ## `kind != TextMessage` guard would drop the player's BINARY
      ## registration frames (lux-ai 0.1.0, snake-royale 0.1.0).
      websocket.send(message.data, Pong)
    elif message.kind == BinaryMessage or message.kind == TextMessage:
      {.gcsafe.}:
        withLock appState.lock:
          if websocket in appState.globalViewers:
            appState.globalViewers[websocket].applyGlobalViewerMessage(
              message.data)
          elif websocket in appState.playerSlots:
            let text = message.data.readSpriteInputText()
            if text.len > 0 and text[0] == '{':
              appState.pendingRegistration[websocket] = text
  of ErrorEvent, CloseEvent:
    {.gcsafe.}:
      withLock appState.lock:
        appState.closedSockets.add(websocket)

proc serverThreadProc(args: ServerThreadArgs) {.thread.} =
  args.server[].serve(Port(args.port), args.address)

# ---------------------------------------------------------------------------
#  Broadcasting
# ---------------------------------------------------------------------------

proc broadcastFrame(sim: var SimServer, stateJson: string) =
  ## Global broadcasts are FIRE AND FORGET, so a slow viewer can never stall
  ## the episode.
  var
    sockets: seq[WebSocket] = @[]
    states: seq[GlobalViewerState] = @[]
  {.gcsafe.}:
    withLock appState.lock:
      for socket, state in appState.globalViewers:
        sockets.add(socket)
        states.add(state)
  for i, socket in sockets:
    var next: GlobalViewerState
    var packet = sim.buildBoardPacket(states[i], next)
    packet.addChromeSprite(stateJson)
    if packet.len <= MaxWsFrameBytes:
      socket.send(blobFromBytes(packet), BinaryMessage)
    {.gcsafe.}:
      withLock appState.lock:
        if socket in appState.globalViewers:
          appState.globalViewers[socket] = next

proc broadcastPlayerKeepalive(stateJson: string) =
  ## The seats send NO per-tick inputs (the server computes every phase), so
  ## the player stream is a heartbeat only: it keeps the socket warm and lets
  ## the thin registrar count frames.
  var sockets: seq[WebSocket] = @[]
  {.gcsafe.}:
    withLock appState.lock:
      for socket, slot in appState.playerSlots:
        sockets.add(socket)
  if sockets.len == 0:
    return
  var packet: seq[uint8] = @[]
  packet.addChromeSprite(stateJson)
  let blob = blobFromBytes(packet)
  for socket in sockets:
    socket.send(blob, BinaryMessage)

proc drainClosedSockets(sim: var SimServer) =
  var closed: seq[WebSocket] = @[]
  {.gcsafe.}:
    withLock appState.lock:
      closed = appState.closedSockets
      appState.closedSockets = @[]
      for socket in closed:
        if socket in appState.playerSlots:
          let slot = appState.playerSlots[socket]
          if slot >= 0 and slot < MaxSeats:
            sim.players[slot].left = true
          appState.playerSlots.del(socket)
          appState.playerTokens.del(socket)
          appState.pendingRegistration.del(socket)
        appState.globalViewers.del(socket)

proc drainRegistrations(
  sim: var SimServer, engine: var DecisionEngine
): seq[string] =
  ## Registration interception. A registration that arrives before the seat's
  ## slot has landed is HELD and re-read on the next pass, which is the
  ## paintball 2026-08-25 slot-sequential-join scar; registering twice is
  ## harmless because the server just re-reads the same fields.
  var pending: seq[tuple[slot: int, text: string]] = @[]
  {.gcsafe.}:
    withLock appState.lock:
      for socket, text in appState.pendingRegistration:
        let slot = appState.playerSlots.getOrDefault(socket, -1)
        if slot >= 0:
          pending.add((slot: slot, text: text))
      for entry in pending:
        for socket, slot in appState.playerSlots:
          if slot == entry.slot:
            appState.pendingRegistration.del(socket)
  for entry in pending:
    if entry.slot < 0 or entry.slot >= MaxSeats:
      continue
    var node: JsonNode
    try:
      node = parseJson(entry.text)
    except CatchableError:
      continue
    if node.kind != JObject:
      continue
    let
      prompt = node{"prompt"}.getStr().truncateRunes(MaxPromptRunes)
      scripted = node{"scripted"}.getStr()
      label = node{"policy"}.getStr().truncateRunes(MaxPolicyLabelRunes)
      isLlm = prompt.len > 0
      baseline = parseBaseline(scripted)
    engine.seats[entry.slot].isLlm = isLlm
    engine.seats[entry.slot].prompt = prompt
    engine.seats[entry.slot].baseline = baseline
    engine.seats[entry.slot].label =
      if label.len > 0: label
      elif isLlm: "prompt"
      else: $baseline
    engine.seats[entry.slot].registered = true
    discard sim.joinSeat(entry.slot, engine.seats[entry.slot].label)
    sim.players[entry.slot].joined = true
    sim.registerSeat(
      entry.slot, engine.seats[entry.slot].label,
      (if isLlm: "llm" else: "scripted"), $baseline)
    result.add(registerRecord(
      entry.slot, engine.seats[entry.slot].label,
      (if isLlm: "llm" else: "scripted"), $baseline))
    echo "signals: seat ", entry.slot, " (", seatAlias(entry.slot),
      ", ", seatQuadrant(entry.slot), ") registered as ",
      engine.seats[entry.slot].label,
      " kind=", (if isLlm: "llm" else: "scripted")

proc connectedSeats(): int =
  {.gcsafe.}:
    withLock appState.lock:
      var seen: array[MaxSeats, bool]
      for socket, slot in appState.playerSlots:
        if slot >= 0 and slot < MaxSeats:
          seen[slot] = true
      for slot in 0 ..< MaxSeats:
        if seen[slot]:
          inc result

proc declarePlayerFailure(slot: int, message: string) =
  ## The platform's CLOSED payload — exactly `{"message",
  ## "failed_policy_index"}`, nothing else.
  let uri = getEnv("COGAME_PLAYER_FAILURE_URI")
  if uri.len == 0:
    return
  try:
    writeCogameUri(
      uri,
      $(%*{"message": message.truncateRunes(MaxStopDetailRunes),
           "failed_policy_index": slot}),
      "application/json",
      "COGAME_PLAYER_FAILURE_URI")
  except CatchableError as error:
    echo "signals: could not report the player failure: ", error.msg

# ---------------------------------------------------------------------------
#  The episode
# ---------------------------------------------------------------------------

proc liveStateJson(sim: SimServer, events: JsonNode): string =
  sim.buildStateJson(
    events,
    playing = true,
    speed = 1.0,
    maxTick = sim.config.maxTicks,
    looping = false,
    transportEnabled = false,
    mismatchTick = -1)

proc writeArtifacts(
  sim: var SimServer,
  runtimeConfig: RuntimeConfig,
  replayPath: string
) =
  ## The artifact-write block. Nothing here may raise: an artifact that fails
  ## to upload must not take the exit code with it.
  let resultsJson = sim.cityResultsJson()
  try:
    runtimeConfig.writeResults(resultsJson)
  except CatchableError as error:
    echo "signals: results write failed: ", error.msg
  if replayPath.len > 0 and fileExists(replayPath):
    try:
      runtimeConfig.writeReplay(readFile(replayPath))
    except CatchableError as error:
      echo "signals: replay write failed: ", error.msg
  if getEnv("COGAME_EVENTS_URI").len > 0:
    try:
      writeCogameEnv(
        "COGAME_EVENTS_URI",
        eventsJsonl(sim.events, sim.finalTick),
        "application/x-ndjson")
    except CatchableError as error:
      echo "signals: events write failed: ", error.msg
  echo "signals results: ", resultsJson

proc runReplayLoop(
  host: string, port: int, replayBytes: string, mismatchQuit: bool
) =
  ## Local replay mode for developers: the game serves `/client/replay` and
  ## plays the loaded bytes back. The HOSTED replay experience is the static
  ## wasm bundle and nothing else — no `/client/replay` live-server viewer is
  ## ever declared to the platform.
  var initialized = initReplayRuntime(parseReplayBytes(replayBytes), mismatchQuit)
  var
    sim = move(initialized.sim)
    player = move(initialized.player)
    tracker = move(initialized.tracker)
  let httpServer = newServer(httpHandler, websocketHandler, workerThreads = 2)
  var
    serverThread: Thread[ServerThreadArgs]
    serverPtr = cast[ptr Server](unsafeAddr httpServer)
  createThread(serverThread, serverThreadProc,
    ServerThreadArgs(server: serverPtr, address: host, port: port))
  httpServer.waitUntilReady()
  echo "signals replay server on ", host, ":", port
  while true:
    var
      commands: seq[char] = @[]
      seeks: seq[int] = @[]
    {.gcsafe.}:
      withLock appState.lock:
        for socket, state in appState.globalViewers:
          for command in state.replayCommands:
            commands.add(command)
          if state.replaySeekTick >= 0:
            seeks.add(state.replaySeekTick)
    let frameEvents = player.advanceReplayFrame(sim, tracker, seeks, commands)
    var lead: seq[seq[int]] = @[]
    if player.scanComplete():
      lead = leadSeriesFrom(player.exitSeries, player.rejectSeries, 4)
    sim.broadcastFrame(sim.buildStateJson(
      frameEvents, player.playing, player.replayDisplaySpeed(),
      player.replayMaxTick(), player.looping, true, player.hashMismatchTick,
      player.replayStartTick(), player.endHoldSecondsLeft(), player.skipLulls,
      false, player.lullSpans, cityBeatsJson(player.beats), lead))
    sim.drainClosedSockets()
    sleep(1000 div TargetFps)

proc runServerLoop*(
  host: string,
  port: int,
  config: GameConfig,
  replayPath: string,
  loadReplayBytes: string,
  runtimeConfig: RuntimeConfig
) =
  ## The whole episode: lobby, 32 command turns, settle, artifacts, a bounded
  ## shutdown grace, exit 0.
  if loadReplayBytes.len > 0:
    runReplayLoop(host, port, loadReplayBytes, runtimeConfig.mismatchQuit)
    return

  var sim = initSimServer(config)
  {.gcsafe.}:
    withLock appState.lock:
      appState.tokens = config.tokens
      appState.seats = MaxSeats
  echo describeCity(sim.city)
  echo "quadrants: ", quadrantMapText()

  var engine = initDecisionEngine(sim)
  var tracker = initBroadcastTracker()
  var writer = openReplayWriter(replayPath, config.configJson())
  for slot in 0 ..< MaxSeats:
    writer.writeJoin(tickTime(0), slot, sim.players[slot].name, slot,
      (if slot < config.tokens.len: config.tokens[slot] else: ""))

  let httpServer = newServer(httpHandler, websocketHandler, workerThreads = 4)
  var
    serverThread: Thread[ServerThreadArgs]
    serverPtr = cast[ptr Server](unsafeAddr httpServer)
  createThread(serverThread, serverThreadProc,
    ServerThreadArgs(server: serverPtr, address: host, port: port))
  httpServer.waitUntilReady()
  echo "signals: listening on ", host, ":", port

  let episodeStart = getMonoTime()
  var records: seq[string] = @[]

  # --- the lobby -----------------------------------------------------------
  while sim.lobbyTicks < config.lobbyJoinTimeoutTicks:
    sim.drainClosedSockets()
    for record in sim.drainRegistrations(engine):
      records.add(record)
    if connectedSeats() >= config.minPlayers and sim.allSeatsRegistered() and
        connectedSeats() >= MaxSeats:
      break
    inc sim.lobbyTicks
    let frameEvents = newJArray()
    sim.stepEvents(tracker, frameEvents)
    let stateJson = sim.liveStateJson(frameEvents)
    sim.broadcastFrame(stateJson)
    broadcastPlayerKeepalive(stateJson)
    sleep(1000 div TargetFps)

  sim.drainClosedSockets()
  for record in sim.drainRegistrations(engine):
    records.add(record)

  ## The server LOGS LOUDLY and REFUSES TO START when a joined seat has no
  ## register record (design edit 2): a seat that silently plays the default
  ## script for a whole episode is the grf-football scar, and an episode whose
  ## roster is a lie is worse than no episode. A seat that never connected at
  ## all is a different case — that one plays greedy and the episode runs, as
  ## design §Degrade requires.
  let missing = sim.unregisteredSeats()
  if missing.len > 0:
    for slot in missing:
      echo "signals: SEAT ", slot, " (", seatAlias(slot),
        ") JOINED WITHOUT A REGISTER RECORD — refusing to treat it as a ",
        "policy; the game will not start"
      sim.deadSeats[slot] = true
      declarePlayerFailure(slot, "seat joined without a registration record")
  for slot in 0 ..< MaxSeats:
    if not sim.players[slot].joined:
      echo "signals: seat ", slot, " (", seatAlias(slot),
        ") never connected; its four signals are driven by greedy"
      sim.deadSeats[slot] = true
      declarePlayerFailure(slot, "seat never connected")
    sim.policyKinds[slot] = engine.policyKind(slot)

  for record in records:
    writer.writeChat(tickTime(0), 255, record)
  records = @[]

  ## Refusing to start is a settled episode, not a crash: the stop is
  ## recorded, results.json and the replay are still written so the failure is
  ## reported and attributable, and the process still exits 0 (the smoke
  ## fails the build on `fault`, which is what makes it visible).
  if missing.len > 0:
    let detail = sim.refuseToStartDetail()
    sim.applyStop(erFault, detail)
    echo "signals: REFUSING TO START — ", sim.stopDetail
    writer.writeChat(tickTime(sim.tickCount), 255,
      stopRecord(sim.tickCount, $erFault))

  # --- play ---------------------------------------------------------------
  if not sim.settled:
    sim.phase = Playing
  let turns = sim.turnsPerEpisode()
  var deadlineHit = false
  try:
    for turnIndex in 1 .. turns:
      if sim.settled:
        break
      ## The engine's own hard stop, checked before the turn: 660 s is inside
      ## 60 % of the assumed 1200 s episodeTimeoutSeconds, so the episode always
      ## settles and scores itself rather than being silently discarded.
      let elapsed = (getMonoTime() - episodeStart).inSeconds.int
      if elapsed >= config.wallClockBudgetSeconds:
        deadlineHit = true
        echo "signals: wall-clock budget of ", config.wallClockBudgetSeconds,
          "s reached; settling the episode from the real throughput at this tick"
        break
      sim.turn = turnIndex
      sim.drainClosedSockets()
      for record in sim.drainRegistrations(engine):
        writer.writeChat(tickTime(sim.tickCount), 255, record)
      let turnRecords = engine.turn(sim, turnIndex, elapsed)
      writer.writeChat(tickTime(sim.tickCount), 255,
        ordersRecord(sim, turnIndex))
      for record in turnRecords:
        writer.writeChat(tickTime(sim.tickCount), 255, record)
        tracker.pending.add(record)
      let turnStart = sim.tickCount
      for k in 0 ..< config.turnTicks:
        if sim.settled:
          break
        sim.stepTick(k)
        writer.writeHash(uint32(sim.tickCount), sim.gameHash())
      sim.turnsPlayed = turnIndex
      let frameEvents = newJArray()
      sim.stepEvents(tracker, frameEvents)
      let stateJson = sim.liveStateJson(frameEvents)
      sim.broadcastFrame(stateJson)
      broadcastPlayerKeepalive(stateJson)
      if turnStart == sim.tickCount:
        break                              ## nothing advanced: never spin.
  except CatchableError as error:
    ## `fault`: an unexpected exception in the sim or the loop is CAUGHT, the
    ## episode is settled from the last completed tick, the stop is recorded
    ## and the artifacts below are still written — a defect is reported and
    ## rankable rather than lost with the process. The exit code stays 0;
    ## tools/ci/docker_smoke.sh is what fails the build on it.
    echo "signals: FAULT — ", error.msg
    sim.applyStop(erFault,
      "unexpected exception in the episode loop: " & error.msg)
    writer.writeChat(tickTime(sim.tickCount), 255,
      stopRecord(sim.tickCount, $erFault))

  if deadlineHit and not sim.settled:
    sim.applyStop(erWallClock, "wall-clock budget reached")
    writer.writeChat(tickTime(sim.tickCount), 255,
      stopRecord(sim.tickCount, $erWallClock))
  if not sim.settled:
    sim.applyStop(erFullPeriod, "")
  echo "signals: episode settled — ", describeState(sim),
    " reason=", $sim.endReason, " endRule=", $sim.endRule

  writer.writeChat(tickTime(sim.finalTick), 255,
    resultRecord(sim, sim.cityResultsJson()))
  writer.closeReplayWriter()
  sim.writeArtifacts(runtimeConfig, replayPath)

  # --- the shutdown grace -------------------------------------------------
  ## `/healthz` and `/global` keep answering for a bounded grace after the
  ## artifacts are written (the lantern 0.1.3 `/global` ping scar), then the
  ## process exits; the runner waits on process exit either way.
  for i in 0 ..< max(1, config.gameOverTicks):
    let frameEvents = newJArray()
    sim.stepEvents(tracker, frameEvents)
    let stateJson = sim.liveStateJson(frameEvents)
    sim.broadcastFrame(stateJson)
    broadcastPlayerKeepalive(stateJson)
    sim.drainClosedSockets()
    sleep(1000 div TargetFps)
  echo "signals: shutting down"

proc runEpisode*(
  config: GameConfig, runtimeConfig: RuntimeConfig, replayPath: string
): SimServer =
  ## The whole episode with NO server and NO sockets: every seat plays its
  ## scripted baseline. Used by `tests/test_signals_engine.nim` and by
  ## `tools/record_fixture.sh`.
  result = initSimServer(config)
  var engine = initDecisionEngine(result)
  var writer = openReplayWriter(replayPath, config.configJson())
  for slot in 0 ..< MaxSeats:
    result.players[slot].joined = true
    result.players[slot].registered = true
    engine.seats[slot].registered = true
    engine.seats[slot].isLlm = false
    engine.seats[slot].baseline =
      if slot mod 2 == 0: blGreedy else: blFixedCycle
    engine.seats[slot].label = $engine.seats[slot].baseline
    result.registerSeat(slot, engine.seats[slot].label, "scripted",
      $engine.seats[slot].baseline)
    writer.writeJoin(tickTime(0), slot, result.players[slot].name, slot, "")
    writer.writeChat(tickTime(0), 255, registerRecord(
      slot, engine.seats[slot].label, "scripted",
      $engine.seats[slot].baseline))
  result.phase = Playing
  for turnIndex in 1 .. result.turnsPerEpisode():
    if result.settled:
      break
    result.turn = turnIndex
    let turnRecords = engine.turn(result, turnIndex, 0)
    writer.writeChat(tickTime(result.tickCount), 255,
      ordersRecord(result, turnIndex))
    for record in turnRecords:
      writer.writeChat(tickTime(result.tickCount), 255, record)
    for k in 0 ..< config.turnTicks:
      if result.settled:
        break
      result.stepTick(k)
      writer.writeHash(uint32(result.tickCount), result.gameHash())
    result.turnsPlayed = turnIndex
  if not result.settled:
    result.applyStop(erFullPeriod, "")
  writer.writeChat(tickTime(result.finalTick), 255,
    resultRecord(result, result.cityResultsJson()))
  writer.closeReplayWriter()
  if runtimeConfig.resultsUri.len > 0 or runtimeConfig.replayUri.len > 0:
    result.writeArtifacts(runtimeConfig, replayPath)
