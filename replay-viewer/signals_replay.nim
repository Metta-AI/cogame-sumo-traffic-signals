import
  std/json,
  signals/[broadcast, global, replay_runtime, replays, sim]

var
  runtimeLoaded = false
  replay: ReplayPlayer
  game: SimServer
  viewer: GlobalViewerState
  tracker: BroadcastTracker
  packet: seq[uint8]
  lastError: string

## --- Progress stage note ---
## wasm32 has no memory protection: when emscripten's malloc fails, a write
## through the nil pointer lands at address 0 and silently corrupts the
## module's own globals instead of trapping. The bundle is therefore linked
## with `-s ABORTING_MALLOC=1` — allocation failure aborts the runtime loudly
## — and this FIXED buffer, stamped BEFORE each risky phase, stays readable
## from JS after the abort (aborting kills the call stack, not the linear
## memory), so the page can still report what the runtime was doing.
var
  stageNote: array[192, char]
  stageNoteLen: int
  currentStage: string
  frameStage: string           ## prebuilt once per load; re-stamped every frame

proc stampStage(stage: string) =
  currentStage = stage
  stageNoteLen = min(stage.len, stageNote.len)
  if stageNoteLen > 0:
    copyMem(stageNote[0].addr, stage[0].unsafeAddr, stageNoteLen)

proc bytesFromPointer(data: ptr uint8, length: int): string =
  result = newString(length)
  if length > 0:
    copyMem(result[0].addr, data, length)

proc renderCurrent(events: JsonNode) =
  var nextViewer: GlobalViewerState
  packet = game.buildReplayViewerPacket(replay, viewer, nextViewer, events)
  viewer = nextViewer

proc signalsLoadReplay(data: ptr uint8, length: cint): cint
    {.exportc: "signals_load_replay", cdecl.} =
  try:
    lastError = ""
    stampStage("parse replay")
    let replayData = parseReplayBytes(data.bytesFromPointer(int(length)))
    stampStage("initialize replay runtime")
    ## Match the native replay server default: keep a historical replay usable
    ## after the first integrity mismatch and surface the warning in the shared
    ## replay chrome.
    var initialized = initReplayRuntime(
      replayData,
      mismatchQuit = false,
      gameEventLoggingEnabled = true
    )
    game = move(initialized.sim)
    replay = move(initialized.player)
    tracker = move(initialized.tracker)
    viewer = initGlobalViewerState()
    runtimeLoaded = true
    frameStage = "advance replay"
    stampStage("bake the city bed and render the first frame")
    renderCurrent(newJArray())
    return 1
  except Exception as error:
    runtimeLoaded = false
    lastError = currentStage & ": " & error.msg & "\n" & error.getStackTrace()
    return 0

proc signalsInput(data: ptr uint8, length: cint)
    {.exportc: "signals_input", cdecl.} =
  if runtimeLoaded:
    viewer.applyGlobalViewerMessage(data.bytesFromPointer(int(length)))

proc signalsFrame(): cint {.exportc: "signals_frame", cdecl.} =
  if not runtimeLoaded:
    return 0
  stampStage(frameStage)
  try:
    let seekTicks =
      if viewer.replaySeekTick >= 0: @[viewer.replaySeekTick]
      else: newSeq[int]()
    let events = replay.advanceReplayFrame(
      game, tracker, seekTicks, viewer.replayCommands)
    renderCurrent(events)
    return 1
  except Exception as error:
    lastError = "advance replay: " & error.msg & "\n" & error.getStackTrace()
    return -1

proc signalsPacketPointer(): ptr uint8
    {.exportc: "signals_packet_ptr", cdecl.} =
  if packet.len == 0: nil else: packet[0].addr

proc signalsPacketLength(): cint {.exportc: "signals_packet_len", cdecl.} =
  cint(packet.len)

proc signalsMismatchTick(): cint {.exportc: "signals_mismatch_tick", cdecl.} =
  if runtimeLoaded: cint(replay.hashMismatchTick) else: -1

proc signalsErrorPointer(): ptr uint8 {.exportc: "signals_error_ptr", cdecl.} =
  if lastError.len == 0: nil else: cast[ptr uint8](lastError[0].addr)

proc signalsErrorLength(): cint {.exportc: "signals_error_len", cdecl.} =
  cint(lastError.len)

proc signalsStagePointer(): ptr uint8 {.exportc: "signals_stage_ptr", cdecl.} =
  ## The progress note. Unlike `signals_error_*`, this stays valid after an
  ## allocation-failure abort, so JS can report what the runtime was doing.
  if stageNoteLen == 0: nil else: cast[ptr uint8](stageNote[0].addr)

proc signalsStageLength(): cint {.exportc: "signals_stage_len", cdecl.} =
  cint(stageNoteLen)

when defined(emscripten):
  proc emscriptenExitWithLiveRuntime() {.
    importc: "emscripten_exit_with_live_runtime", cdecl.}

when isMainModule and defined(emscripten):
  # Nim's generated main runs every module-global destructor when it returns,
  # freeing the baked bed, the car chips, the fonts — everything — while the
  # wasm module stays alive and JS keeps calling signals_load_replay /
  # signals_frame. The whole session then runs on freed globals. Unwinding main
  # through emscripten's live-runtime exit skips the destructor epilogue
  # entirely, so globals stay valid for the life of the page.
  emscriptenExitWithLiveRuntime()
