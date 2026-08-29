## The deterministic replay runtime shared by the native replay server and the
## WASM viewer. Forked from the starter's `src/ctf/replay_runtime.nim`.
##
## `initReplayRuntime` parses the bytes, rebuilds the sim from the RECORDED
## config, runs the load-time pre-scan and lands playback on frame 0;
## `advanceReplayFrame` applies viewer controls and advances one presentation
## frame; `buildReplayViewerPacket` builds the board packet plus the chrome
## carrier for one viewer. The SAME sim module runs natively and in wasm, which
## is the whole reason this game lives in the starter's language.

import
  std/json,
  sim, replays, broadcast, global

type
  InitializedReplay* = object
    config*: GameConfig
    sim*: SimServer
    player*: ReplayPlayer
    tracker*: BroadcastTracker

proc cityBeatsJson*(beats: openArray[Beat]): JsonNode =
  ## The scrubber beats, as the appended game block's `cityBeat(tick, kind,
  ## slot, label)` reads them: labelled, clickable buttons, one per beat.
  result = newJArray()
  for beat in beats:
    result.add(%*{
      "t": beat.tick, "k": $beat.kind, "slot": beat.slot,
      "label": beat.label
    })

proc initReplayRuntime*(
  data: ReplayData,
  mismatchQuit: bool,
  gameEventLoggingEnabled = true
): InitializedReplay =
  ## Constructs and starts replay playback from the recorded game config.
  result.config = defaultGameConfig()
  result.config.update(data.configJson)
  result.sim = initSimServer(result.config)
  result.sim.gameEventLoggingEnabled = gameEventLoggingEnabled
  result.player = initReplayPlayer(data)
  result.player.mismatchQuit = mismatchQuit
  ## The whole-episode pre-scan: 256 ticks over at most a few hundred cars of
  ## integer work, single-digit milliseconds even in wasm. It is what lets the
  ## throughput sparkline and the scrubber beats draw at FULL WIDTH on the
  ## first frame instead of growing in.
  result.player.prescan(result.sim)
  result.player.playing = true
  result.tracker = initBroadcastTracker()
  result.tracker.resync(result.sim)

proc advanceReplayFrame*(
  player: var ReplayPlayer,
  sim: var SimServer,
  tracker: var BroadcastTracker,
  seekTicks: openArray[int],
  commands: openArray[char]
): JsonNode =
  ## Applies viewer controls and advances one public presentation frame. One
  ## tick per `FramesPerTick` frames at speed 1, so a 256-tick episode plays
  ## for ~21 s and `viewer_smoke.mjs --soak 10` observes real advancement.
  ## The parity flips FIRST, before any early return, so 1/2x keeps spending a
  ## tick every other frame no matter what else this frame does.
  player.halfPhase = not player.halfPhase
  var didSeek = false
  for seekTick in seekTicks:
    player.applyReplaySeek(sim, seekTick)
    didSeek = true
  for command in commands:
    let before = sim.tickCount
    player.applyReplayCommand(sim, command)
    if sim.tickCount != before:
      didSeek = true
  if didSeek:
    tracker.resync(sim)
    player.cancelEndHold()

  result = newJArray()
  if player.playing and not sim.settled:
    var boost = player.replaySpeed()
    if player.skipLulls and player.isLullTick(sim.tickCount):
      boost = boost * LullSpeedBoost
    elif player.speedIndex == ReplayHalfSpeedIndex:
      ## 1/2x: one frame's worth of budget every OTHER frame, so a tick lands
      ## every `2 * FramesPerTick` frames. The lull boost still wins —
      ## skip-lulls is how a viewer gets PAST the dead stretches, at any speed.
      boost = (if player.halfPhase: 1 else: 0)
    player.subFrames += boost
    var steps = player.subFrames div FramesPerTick
    player.subFrames = player.subFrames mod FramesPerTick
    steps = min(steps, 64)
    for i in 0 ..< steps:
      if sim.settled:
        break
      player.stepReplay(sim)
  elif player.playing and sim.settled:
    if player.looping:
      if player.endHoldFrames <= 0:
        player.endHoldFrames = ReplayEndHoldSeconds * TargetFps
      dec player.endHoldFrames
      if player.endHoldFrames <= 0:
        player.seekReplay(sim, 0)
        tracker.resync(sim)
  sim.stepEvents(tracker, result)

proc buildReplayViewerPacket*(
  sim: var SimServer,
  player: ReplayPlayer,
  state: GlobalViewerState,
  nextState: var GlobalViewerState,
  events: JsonNode
): seq[uint8] =
  ## The shared replay board and chrome packet for one viewer.
  result = sim.buildBoardPacket(state, nextState)
  let sendLead = not state.momentumSent and player.scanComplete()
  result.addChromeSprite(sim.buildStateJson(
    events,
    player.playing,
    player.replayDisplaySpeed(),
    player.replayMaxTick(),
    player.looping,
    true,
    player.hashMismatchTick,
    player.replayStartTick(),
    player.endHoldSecondsLeft(),
    player.skipLulls,
    player.skipLulls and player.playing and
      player.isLullTick(sim.tickCount),
    (if sendLead: player.lullSpans else: @[]),
    (if sendLead: cityBeatsJson(player.beats) else: nil),
    (if sendLead: leadSeriesFrom(player.exitSeries, player.rejectSeries, 4)
     else: @[])
  ))
  if sendLead:
    nextState.momentumSent = true
