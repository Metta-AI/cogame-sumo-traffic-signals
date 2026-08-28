## The replay codec and the replay player. Forked from the starter's
## `src/ctf/replays.nim`: the magic and the game name change
## (`COWLDCTF` -> **`COWLDSIG`**), and the input stream is this game's ORDER
## RECORDS rather than paintbot's per-tick button masks.
##
## The bytes are SELF-SUFFICIENT. The header carries the magic, the format
## version, the game name and version and the RESOLVED config JSON; the record
## stream carries the joins, the per-turn order records (the only inputs this
## game has), the chat records (`register` / `directive` / `fallback` /
## `budget_guard` / `stop` / `result`) and ONE `gameHash` per tick. The city
## topology is code, compiled into both the binary and the wasm module, so the
## viewer reconstructs the exact city and re-simulates every car from bytes it
## already has, with no fetch.
##
## SEEKS RE-SIMULATE FROM ZERO rather than from a keyframe. A whole 256-tick
## episode over at most a few hundred cars of integer work is single-digit
## milliseconds even in wasm, so there is no keyframe cache to get wrong — and
## no flatty snapshot whose field order could drift from the wire types.

import
  std/[json, strutils],
  bitworld/replays as replayCodec,
  sim

export replayCodec

const
  SignalsReplayMagic* = "COWLDSIG"
  SignalsReplayFormatVersion* = 1'u16
  ReplayEndHoldSeconds* = 10
    ## How long a looping replay holds on its final frame before restarting.
  LullQuietTicks* = 40
    ## A lull is this many consecutive ticks with no wave / spillback /
    ## gridlock / starve / gatejam event and fewer than two exits.
  LullSpeedBoost* = 8
  FramesPerTick* = 2
    ## One tick per two presentation frames: a 256-tick episode plays for
    ## ~21 s, which is what lets `viewer_smoke.mjs --soak 10` observe real
    ## advancement instead of a legitimately-finished replay.

# A `const`, NOT a module-level `let`. Emscripten fires
# `Module.onRuntimeInitialized` BEFORE `callMain()`, so a host that loads a
# replay from that callback synchronously — `tools/wasm_replay_smoke.cjs` does;
# the Worker does not, because it awaits a `fetch` first — would run
# `parseReplayBytes` before Nim's `main` had initialised a module-level `let`.
# The spec's `formatVersion` then read 0 and every replay was rejected with
# "Unsupported replay format version" in node while loading fine in the
# browser. A const has no runtime initialiser to miss.
const SignalsReplaySpec* = ReplaySpec(
  magic: SignalsReplayMagic,
  formatVersion: SignalsReplayFormatVersion,
  gameName: GameName,
  gameVersion: GameVersion,
  joinKind: rjkNameSlotToken,
  allowChat: true,
  allowCompressed: true,
  hashOrder: rhoStop
)

type
  OrderRecordEntry* = object
    at*: int
    verb*: OrderVerb
    phase*: PhaseId
    delay*: int

  OrdersRecord* = object
    turn*: int
    tick*: int
    entries*: seq[OrderRecordEntry]
    says*: array[MaxSeats, string]

  BeatKind* = enum
    bkWave = "wave"
    bkSpillback = "spillback"
    bkGridlock = "gridlock"
    bkFallback = "fallback"
    bkEnd = "end"

  Beat* = object
    tick*: int
    kind*: BeatKind
    slot*: int
    label*: string

  ReplayPlayer* = object
    data*: ReplayData
    orders*: seq[OrdersRecord]
    orderCursor*: int
    stopTick*: int
    stopRule*: string
    resultsJson*: string
    feed*: seq[tuple[tick: int, record: string]]
    feedCursor*: int
    hashIndex*: int
    hashMismatchTick*: int
    hashValidationFailed*: bool
    mismatchQuit*: bool
    playing*: bool
    looping*: bool
    skipLulls*: bool
    speedIndex*: int
    subFrames*: int
    turnStart*: int
    startTick*: int
    endHoldFrames*: int
    # --- the load-time pre-scan (design §Viewer) ---
    scanned*: bool
    maxTick*: int
    exitSeries*: seq[int]
    rejectSeries*: seq[int]
    waitSeries*: seq[int]
    spillbackSeries*: seq[int]
    gridlockSeries*: seq[int]
    lullSpans*: seq[array[2, int]]
    beats*: seq[Beat]

proc tickTime*(tick: int): uint32 =
  replayCodec.tickTime(tick, ReplayFps)

proc openReplayWriter*(path, configJson: string): ReplayWriter =
  replayCodec.openReplayWriter(path, configJson, SignalsReplaySpec)

proc parseReplayBytes*(bytes: string): ReplayData =
  replayCodec.parseReplayBytes(bytes, SignalsReplaySpec)

proc loadReplay*(path: string): ReplayData =
  replayCodec.loadReplay(path, SignalsReplaySpec)

# ---------------------------------------------------------------------------
#  Order records — the whole input log
# ---------------------------------------------------------------------------

proc parseOrdersRecord*(node: JsonNode): OrdersRecord =
  result.turn = node{"turn"}.getInt()
  result.tick = node{"tick"}.getInt()
  result.entries = @[]
  let entries = node{"orders"}
  if not entries.isNil and entries.kind == JArray:
    for item in entries:
      let at = intersectionIndex(item{"at"}.getStr())
      if at < 0:
        continue
      let
        verb = parseVerb(item{"verb"}.getStr())
        phase = parsePhase(item{"phase"}.getStr())
      result.entries.add(OrderRecordEntry(
        at: at,
        verb: (if verb.ok: verb.verb else: ovAuto),
        phase: (if phase.ok: phase.phase else: phNSG),
        delay: item{"delay"}.getInt()
      ))
  let says = node{"say"}
  if not says.isNil and says.kind == JArray:
    for slot in 0 ..< min(MaxSeats, says.len):
      result.says[slot] = says[slot].getStr()

proc applyOrdersRecord*(sim: var SimServer, record: OrdersRecord) =
  ## THE one proc that installs a turn's orders, used on record and on
  ## playback, so the two can never drift.
  sim.turn = record.turn
  for entry in record.entries:
    if entry.at < 0 or entry.at >= Intersections:
      continue
    sim.signals[entry.at].order = SignalOrder(
      verb: entry.verb,
      phase: entry.phase,
      delay: entry.delay,
      turn: record.turn,
      outcome: orUnknown
    )
  for slot in 0 ..< MaxSeats:
    sim.radio[slot] = record.says[slot]

# ---------------------------------------------------------------------------
#  The player
# ---------------------------------------------------------------------------

proc replaySpeed*(player: ReplayPlayer): int =
  PlaybackSpeeds[clamp(player.speedIndex, 0, PlaybackSpeeds.len - 1)]

proc replayMaxTick*(player: ReplayPlayer): int =
  player.maxTick

proc replayStartTick*(player: ReplayPlayer): int =
  max(0, player.startTick)

proc scanComplete*(player: ReplayPlayer): bool = player.scanned

proc endHoldSecondsLeft*(player: ReplayPlayer): int =
  if player.endHoldFrames <= 0: 0
  else: (player.endHoldFrames + TargetFps - 1) div TargetFps

proc cancelEndHold*(player: var ReplayPlayer) =
  player.endHoldFrames = 0

proc initReplayPlayer*(data: ReplayData): ReplayPlayer =
  ## Splits the chat stream into the order records (inputs), the stop record
  ## (load-bearing), the results document, and the feed records the broadcast
  ## chrome replays.
  result.data = data
  result.orders = @[]
  result.feed = @[]
  result.stopTick = -1
  result.stopRule = ""
  result.hashMismatchTick = -1
  result.playing = true
  result.speedIndex = 1
  result.startTick = 0
  result.maxTick = 0
  for chat in data.chats:
    if chat.message.len == 0 or chat.message[0] != '{':
      continue
    var node: JsonNode
    try:
      node = parseJson(chat.message)
    except CatchableError:
      continue
    if node.kind != JObject:
      continue
    let kind = node{"k"}.getStr()
    case kind
    of "orders":
      result.orders.add(parseOrdersRecord(node))
    of "stop":
      result.stopTick = node{"tick"}.getInt()
      result.stopRule = node{"endRule"}.getStr()
    of "result":
      result.resultsJson = $node{"results"}
    else:
      result.feed.add((tick: int(chat.time) * ReplayFps div 1000,
                       record: chat.message))
  for hash in data.hashes:
    if int(hash.tick) > result.maxTick:
      result.maxTick = int(hash.tick)

proc parseEndRule(text: string): EndRule =
  for rule in EndRule:
    if $rule == text:
      return rule
  erFullPeriod

proc checkReplayHash*(player: var ReplayPlayer, sim: SimServer) =
  ## Compares the re-simulated `gameHash` against the recorded one EVERY tick.
  ## One divergent bit is caught at the tick it happens.
  while player.hashIndex < player.data.hashes.len and
      int(player.data.hashes[player.hashIndex].tick) < sim.tickCount:
    inc player.hashIndex
  if player.hashIndex >= player.data.hashes.len:
    return
  let recorded = player.data.hashes[player.hashIndex]
  if int(recorded.tick) != sim.tickCount:
    return
  inc player.hashIndex
  if recorded.hash == sim.gameHash():
    return
  if player.hashMismatchTick < 0:
    player.hashMismatchTick = sim.tickCount
  player.hashValidationFailed = true
  if player.mismatchQuit:
    raise newException(
      SignalsError,
      "replay hash mismatch at tick " & $sim.tickCount)

proc stepReplay*(player: var ReplayPlayer, sim: var SimServer) =
  ## One re-simulated tick: apply any order record that lands on this tick,
  ## step, apply the stop record if it lands here, then check the hash.
  if sim.settled:
    return
  while player.orderCursor < player.orders.len and
      player.orders[player.orderCursor].tick <= sim.tickCount:
    sim.applyOrdersRecord(player.orders[player.orderCursor])
    player.turnStart = sim.tickCount
    inc player.orderCursor
  if sim.phase == Lobby:
    sim.phase = Playing
  sim.stepTick(sim.tickCount - player.turnStart)
  if player.stopTick >= 0 and sim.tickCount >= player.stopTick and
      not sim.settled:
    sim.applyStop(parseEndRule(player.stopRule), "")
  player.checkReplayHash(sim)

proc resetReplay*(player: var ReplayPlayer, sim: var SimServer) =
  ## Rewinds to tick 0. A seek is a rewind plus a re-walk, which is cheap
  ## enough here that there are no keyframes at all.
  var config = defaultGameConfig()
  config.update(player.data.configJson)
  let logging = sim.gameEventLoggingEnabled
  var fresh = initSimServer(config)
  fresh.gameEventLoggingEnabled = logging
  for join in player.data.joins:
    if join.slot >= 0 and join.slot < MaxSeats:
      fresh.players[join.slot].name = join.name
      fresh.players[join.slot].joined = true
  for record in player.feed:
    if record.record.len == 0 or record.record[0] != '{':
      continue
    try:
      let node = parseJson(record.record)
      if node{"k"}.getStr() != "register":
        continue
      let slot = node{"slot"}.getInt()
      if slot >= 0 and slot < MaxSeats:
        fresh.players[slot].policy = node{"policy"}.getStr()
        fresh.players[slot].kind = node{"kind"}.getStr()
        fresh.players[slot].baseline = node{"baseline"}.getStr()
        fresh.players[slot].registered = true
        fresh.policyKinds[slot] = node{"kind"}.getStr()
    except CatchableError:
      discard
  sim = fresh
  player.orderCursor = 0
  player.turnStart = 0
  player.hashIndex = 0
  player.feedCursor = 0
  player.endHoldFrames = 0

proc seekReplay*(player: var ReplayPlayer, sim: var SimServer, tick: int) =
  ## Lands playback exactly on `tick` by re-simulating from zero.
  let target = clamp(tick, 0, player.maxTick)
  player.resetReplay(sim)
  var guard = 0
  while sim.tickCount < target and not sim.settled and guard <= player.maxTick:
    inc guard
    player.stepReplay(sim)
  player.subFrames = 0

proc applySpeedCommand*(speedIndex: var int, command: char) =
  case command
  of '1': speedIndex = 0
  of '2': speedIndex = min(1, PlaybackSpeeds.len - 1)
  of '3': speedIndex = min(2, PlaybackSpeeds.len - 1)
  of '4': speedIndex = min(3, PlaybackSpeeds.len - 1)
  of '5': speedIndex = PlaybackSpeeds.len - 1
  of '+': speedIndex = min(speedIndex + 1, PlaybackSpeeds.len - 1)
  of '-': speedIndex = max(speedIndex - 1, 0)
  else: discard

proc applyReplayCommand*(
  player: var ReplayPlayer, sim: var SimServer, command: char
) =
  ## The starter's transport vocabulary, kept: space = play/pause, `,`/`.` =
  ## step, `[`/`]` = jump, `r` = restart, `e` = end, `l` = loop, `k` = skip
  ## lulls, digits = speed.
  case command
  of ' ', 'p':
    player.playing = not player.playing
    player.cancelEndHold()
  of ',':
    player.seekReplay(sim, max(0, sim.tickCount - 1))
    player.playing = false
  of '.':
    if not sim.settled:
      player.stepReplay(sim)
    player.playing = false
  of '[':
    player.seekReplay(sim, max(0, sim.tickCount - 5 * ReplayFps div FramesPerTick))
  of ']':
    player.seekReplay(sim, sim.tickCount + 5 * ReplayFps div FramesPerTick)
  of 'r':
    player.seekReplay(sim, 0)
    player.playing = true
  of 'e':
    player.seekReplay(sim, player.maxTick)
  of 'l':
    player.looping = not player.looping
  of 'k':
    player.skipLulls = not player.skipLulls
  of '1', '2', '3', '4', '5', '+', '-':
    applySpeedCommand(player.speedIndex, command)
  else:
    discard

proc applyReplaySeek*(
  player: var ReplayPlayer, sim: var SimServer, tick: int
) =
  player.seekReplay(sim, tick)
  player.cancelEndHold()

proc isLullTick*(player: ReplayPlayer, tick: int): bool =
  for span in player.lullSpans:
    if tick >= span[0] and tick <= span[1]:
      return true
  false

# ---------------------------------------------------------------------------
#  The load-time pre-scan
# ---------------------------------------------------------------------------

proc prescan*(player: var ReplayPlayer, sim: var SimServer) =
  ## Re-simulates the whole episode once, headlessly, and records the per-tick
  ## cumulative series, the spillback and gridlock spans, the lull spans and
  ## the beat ticks. That is what lets the throughput sparkline and the
  ## scrubber beats draw at FULL WIDTH on the first frame instead of growing
  ## in.
  player.exitSeries = @[]
  player.rejectSeries = @[]
  player.waitSeries = @[]
  player.spillbackSeries = @[]
  player.gridlockSeries = @[]
  player.beats = @[]
  player.lullSpans = @[]
  var
    lastWaves = 0
    lastSpills = 0
    lastGridlocks = 0
    lastExits = 0
    quietFrom = 0
    quiet = 0
  player.resetReplay(sim)
  player.exitSeries.add(0)
  player.rejectSeries.add(0)
  player.waitSeries.add(0)
  player.spillbackSeries.add(0)
  player.gridlockSeries.add(0)
  var guard = 0
  while not sim.settled and guard <= player.maxTick + 1:
    inc guard
    player.stepReplay(sim)
    player.exitSeries.add(sim.throughput)
    player.rejectSeries.add(sim.rejected)
    player.waitSeries.add(sim.networkWaitTicks)
    player.spillbackSeries.add(sim.activeSpillback.len)
    player.gridlockSeries.add(sim.activeGridlock.len)
    var loud = false
    if sim.greenWaves > lastWaves:
      player.beats.add(Beat(
        tick: sim.tickCount, kind: bkWave, slot: -1,
        label: "green wave — click to jump here"))
      lastWaves = sim.greenWaves
      loud = true
    if sim.spillbacks > lastSpills:
      player.beats.add(Beat(
        tick: sim.tickCount, kind: bkSpillback, slot: -1,
        label: "a block filled up — click to jump here"))
      lastSpills = sim.spillbacks
      loud = true
    if sim.gridlocks > lastGridlocks:
      player.beats.add(Beat(
        tick: sim.tickCount, kind: bkGridlock, slot: -1,
        label: "gridlock ring — click to jump here"))
      lastGridlocks = sim.gridlocks
      loud = true
    if sim.throughput - lastExits >= 2:
      loud = true
    lastExits = sim.throughput
    if loud:
      if quiet >= LullQuietTicks:
        player.lullSpans.add([quietFrom, sim.tickCount - 1])
      quiet = 0
      quietFrom = sim.tickCount + 1
    else:
      inc quiet
  if quiet >= LullQuietTicks and sim.tickCount > quietFrom:
    player.lullSpans.add([quietFrom, sim.tickCount])
  player.beats.add(Beat(
    tick: max(0, sim.tickCount), kind: bkEnd, slot: -1,
    label: "the city settles — click to jump here"))
  for record in player.feed:
    if "\"k\":\"fallback\"" in record.record:
      player.beats.add(Beat(
        tick: record.tick, kind: bkFallback, slot: -1,
        label: "a controller missed the call — click to jump here"))
  if sim.tickCount > player.maxTick:
    player.maxTick = sim.tickCount
  player.scanned = true
  player.resetReplay(sim)
