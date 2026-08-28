## The board compositor: the sprite/object pools and the incremental sprite
## protocol emission. Forked from the starter's `src/ctf/global.nim` with the
## three named edits of design §The three named edits to `global.nim`:
##
##   1. **The board is a cell grid, not a pixel arena.** Placements are
##      cell-space coordinates scaled by `CellPx`; the fov cache and
##      shadowcasting are DELETED — spectators see the whole city, and so do
##      the controllers (detectors are public by design).
##   2. **Car, signal and link pools.** `CarSpriteBase`, `SignalHeadBase` and
##      `LinkBandBase`, sized to `MaxVehicles`, `16 x 4` heads and 80 links,
##      filled in id/index order and emitted incrementally.
##   3. **Baked city bed.** `arena_floor.png` is tiled and darkened at install
##      with pixie, exactly the way the starter bakes endzone paint, and every
##      static marking is baked onto it once — so the per-frame cost is cars,
##      signal lamps and overlays only.

import
  std/[strutils],
  bitworld/spriteprotocol,
  sim, labels, rig_art

const
  BroadcastChromeSpriteId* = 4090
  MapLayerId* = 0
  MapLayerType* = SpriteLayerMap
  ZoomableLayerFlag* = SpriteLayerZoomableFlag

  # --- sprite id pools (all well inside the u16 wire ceiling) ---
  BedSpriteBase* = 10
  HeatSpriteBase* = 20
  FullSpriteId* = 28
  RingSpriteId* = 29
  WaveSpriteId* = 30
  GatePipSpriteId* = 31
  CarSpriteBase* = 100         ## 4 facings x 5 colours x {plain, chevron}
  CarDashBase* = 180           ## 4 facings x 5 colours
  SignalHeadBase* = 200        ## 4 facings x 3 lamp states

  # --- object id pools ---
  BedObjectBase* = 1
  HeatObjectBase* = 1000       ## + flat cell index (352)
  CarObjectBase* = 2000        ## + car id (1024)
  SignalObjectBase* = 4200     ## + intersection * 4 + approach (64)
  RingObjectBase* = 5000       ## + flat cell index (352)
  WaveObjectBase* = 6000       ## + flat cell index (352)
  GatePipObjectBase* = 7000    ## + gate * cap

  # --- z ordering ---
  BedZ* = -1000
  HeatZ* = -500
  RingZ* = 400
  WaveZ* = -400
  CarZ* = 0
  SignalZ* = 500
  PipZ* = 300

  # --- the green-wave sweep ---
  WaveFlashTicks* = 8
    ## How long the sweep runs the corridor after a `wave` fires.
  WaveBandCells* = 6
    ## The band's length along the lane, one block of an east-west street.

type
  GlobalViewerState* = object
    ## Per-viewer emission state. The protocol is RETAINED-MODE — a client
    ## keeps a placement until it is replaced or deleted — so a sprite ships
    ## once and an object that has not moved need not be re-sent.
    initialized*: bool
    spritesSent*: seq[bool]
    objectsPresent*: seq[bool]
    momentumSent*: bool         ## the whole-episode lead series already sent.
    selectedJoinOrder*: int
    replaySeekTick*: int
    replayCommands*: seq[char]
    scrubbingReplay*: bool
    tiny*: bool                 ## the page's `.tiny` density, relayed by the
                                ## `t:` command: under 620 px the car chips
                                ## drop their chevrons and render as 4 px
                                ## dashes so the queue heatmap becomes the
                                ## primary readout.

const
  MaxSpriteId = 4096
  MaxObjectId = 8192

var
  bakedBed: array[BedTiles, Chip]
  bakedCars: array[4 * CarColours * 2, Chip]
  bakedDashes: array[4 * CarColours, Chip]
  bakedSignals: array[4 * 3, Chip]
  bakedHeat: array[HeatLevels, Chip]
  bakedFull: Chip
  bakedRing: Chip
  bakedWave: Chip
  bakedPip: Chip
  bakesReady = false
  bedOrigins: array[BedTiles, tuple[x, y: int]]

proc carSpriteIndex*(dir: Dir, colour: int, chevron: bool): int =
  (ord(dir) * CarColours + colour) * 2 + (if chevron: 1 else: 0)

proc dashSpriteIndex*(dir: Dir, colour: int): int =
  ord(dir) * CarColours + colour

proc signalSpriteIndex*(dir: Dir, state: int): int = ord(dir) * 3 + state

proc ensureBakes*(sim: SimServer) =
  ## Every chip is composited ONCE, at first frame, so drawing 500 cars is
  ## 500 blits.
  if bakesReady:
    return
  let bed = bakeCityBed(sim.city, sim.config)
  for i in 0 ..< BedTiles:
    bakedBed[i] = bedTile(bed, i)
    bedOrigins[i] = bedTileOrigin(bed, i)
  for dir in ApproachOrder:
    for colour in 0 ..< CarColours:
      bakedCars[carSpriteIndex(dir, colour, false)] =
        bakeCarChip(dir, colour, false)
      bakedCars[carSpriteIndex(dir, colour, true)] =
        bakeCarChip(dir, colour, true)
      bakedDashes[dashSpriteIndex(dir, colour)] = bakeCarDash(dir, colour)
    for state in 0 ..< 3:
      bakedSignals[signalSpriteIndex(dir, state)] = bakeSignalHead(dir, state)
  for level in 0 ..< HeatLevels:
    bakedHeat[level] = bakeHeatChip(level)
  bakedFull = bakeFullChip()
  bakedRing = bakeRingChip()
  bakedWave = bakeWaveChip()
  bakedPip = bakeGatePip()
  bakesReady = true

proc initGlobalViewerState*(): GlobalViewerState =
  result.spritesSent = newSeq[bool](MaxSpriteId)
  result.objectsPresent = newSeq[bool](MaxObjectId)
  result.selectedJoinOrder = -1
  result.replaySeekTick = -1
  result.replayCommands = @[]

proc applyGlobalViewerMessage*(
  state: var GlobalViewerState, message: string
) =
  ## Applies one or more global protocol client messages. Whole-string
  ## commands are intercepted BEFORE the legacy char-by-char transport path,
  ## so a multi-digit tick is never mangled into speed keystrokes.
  for item in message.parseSpriteClientMessages():
    case item.kind
    of SpriteClientChatMessage:
      if item.text.startsWith("s:"):
        let tick = try: parseInt(item.text[2 .. ^1]) except ValueError: -1
        if tick >= 0:
          state.replaySeekTick = tick
      elif item.text.startsWith("t:"):
        state.tiny = item.text.len > 2 and item.text[2] == '1'
      elif item.text.startsWith("v:"):
        let slot = try: parseInt(item.text[2 .. ^1]) except ValueError: -2
        if slot >= -1:
          state.selectedJoinOrder = slot
      else:
        for ch in item.text:
          state.replayCommands.add(ch)
    of SpriteClientMouseMoveMessage, SpriteClientMouseButtonMessage,
        SpriteClientInputMessage, SpriteClientReadyMessage,
        SpriteClientDebugSpriteMessage:
      discard

proc addChip(
  packet: var seq[uint8],
  state: var GlobalViewerState,
  spriteId: int,
  chip: Chip,
  label: string
) =
  ## Ships one sprite definition, once per viewer. Every sprite MUST carry a
  ## non-empty label — the inspector and the label manifest both key off it,
  ## and an empty label silently re-sends forever.
  if spriteId < 0 or spriteId >= MaxSpriteId:
    return
  if state.spritesSent[spriteId]:
    return
  if label.len == 0:
    return
  state.spritesSent[spriteId] = true
  packet.addSprite(spriteId, chip.width, chip.height, chip.pixels, label)

proc place(
  packet: var seq[uint8],
  present: var seq[bool],
  objectId, x, y, z, spriteId: int
) =
  if objectId < 0 or objectId >= MaxObjectId:
    return
  present[objectId] = true
  packet.addObject(objectId, x, y, z, MapLayerId, spriteId)

proc lampFor(sim: SimServer, at: int, approach: Approach): int =
  ## The lamp a spectator sees on one approach's head: amber during the
  ## all-red clearance, green when the current phase permits that approach's
  ## stop-line movement (or the approach itself when the stop line is empty),
  ## red otherwise.
  if sim.signals[at].clearLeft > 0:
    return 1
  let phase = sim.signals[at].phase
  let greens = phaseGreens(phase)
  if approach != greens[0] and approach != greens[1]:
    return 0
  let movement = sim.stopLineMovement(at, approach)
  if movement == mvNone:
    return 2
  if phasePermits(phase, approach, movement): 2 else: 0

proc corridorLinkPath*(sim: SimServer, bucket: int): seq[int] =
  ## One arterial's lane, in the direction of travel: the entry link from its
  ## gate, the three blocks between its four intersections, and the exit link
  ## out the far side.
  let
    ats = corridorIntersections(bucket)
    dir = corridorDir(bucket)
  if ats.len == 0:
    return @[]
  let entry = sim.city.inbound[ats[0]][ord(opposite(dir))]
  if entry >= 0:
    result.add(entry)
  for at in ats:
    let leaving = sim.city.outbound[at][ord(dir)]
    if leaving >= 0:
      result.add(leaving)

proc waveSweepCells*(sim: SimServer, bucket: int): seq[int] =
  ## The flat board cells one corridor's green-wave band covers on THIS tick.
  ## The band enters at the corridor's gate on the tick the `wave` fires and
  ## runs the whole lane in the direction of travel over `WaveFlashTicks`,
  ## then stops — the design note's "a bright band sweeps the corridor's lane
  ## in the direction of travel". Empty when that corridor has no live wave,
  ## which is every corridor on almost every tick.
  let fired = sim.waveFlashTick[bucket]
  if fired <= 0:
    return @[]
  let since = sim.tickCount - fired
  if since < 0 or since >= WaveFlashTicks:
    return @[]
  let path = sim.corridorLinkPath(bucket)
  var total = 0
  for link in path:
    total += sim.city.links[link].cells
  let head = ((since + 1) * total) div WaveFlashTicks
  var walked = 0
  for link in path:
    for i in 0 ..< sim.city.links[link].cells:
      let position = walked + i
      if position < head and position >= head - WaveBandCells:
        result.add(sim.city.flatCell(link, i))
    walked += sim.city.links[link].cells

proc buildBoardPacket*(
  sim: var SimServer,
  state: GlobalViewerState,
  nextState: var GlobalViewerState
): seq[uint8] =
  ## The board half of one viewer frame: the layer/viewport announcement and
  ## the bed on the first frame, then the cars, the signal lamps, the queue
  ## heatmap, the gridlock outline, the wave sweep and the gate pips.
  ensureBakes(sim)
  nextState = state
  nextState.replayCommands.setLen(0)
  nextState.replaySeekTick = -1
  result = @[]
  var previous = state.objectsPresent
  for i in 0 ..< nextState.objectsPresent.len:
    nextState.objectsPresent[i] = false

  if not nextState.initialized:
    nextState.initialized = true
    result.addLayer(MapLayerId, MapLayerType, ZoomableLayerFlag)
    result.addViewport(MapLayerId, BoardPxWide, BoardPxHigh)

  for i in 0 ..< BedTiles:
    result.addChip(nextState, BedSpriteBase + i, bakedBed[i], bedLabel(i))
    result.place(nextState.objectsPresent, BedObjectBase + i,
      bedOrigins[i].x, bedOrigins[i].y, BedZ, BedSpriteBase + i)

  # The queue-length heatmap, drawn from the same queueLen the seats see.
  for link in sim.city.links:
    let
      queue = sim.linkQueueLen[link.index]
      full = sim.linkFull[link.index]
    if queue == 0 and not full:
      continue
    let level = min(HeatLevels - 1, queue * HeatLevels div max(1, link.cells))
    for i in 0 ..< link.cells:
      let flat = sim.city.flatCell(link.index, i)
      let onQueue = i >= link.cells - queue
      if not onQueue and not full:
        continue
      let
        spriteId = (if full: FullSpriteId else: HeatSpriteBase + level)
        label = (if full: fullLabel() else: heatLabel(level))
        chip = (if full: bakedFull else: bakedHeat[level])
      result.addChip(nextState, spriteId, chip, label)
      result.place(nextState.objectsPresent, HeatObjectBase + flat,
        sim.city.cellX[flat] * CellPx, sim.city.cellY[flat] * CellPx,
        HeatZ, spriteId)

  # The gridlock ring: every ring link outlined in red.
  for link in sim.activeGridlock:
    for i in 0 ..< sim.city.links[link].cells:
      let flat = sim.city.flatCell(link, i)
      result.addChip(nextState, RingSpriteId, bakedRing, ringLabel())
      result.place(nextState.objectsPresent, RingObjectBase + flat,
        sim.city.cellX[flat] * CellPx, sim.city.cellY[flat] * CellPx,
        RingZ, RingSpriteId)

  # The green-wave sweep: the corridor a `wave` just fired on carries a bright
  # band down its lane, in the direction of travel, for WaveFlashTicks.
  for bucket in 0 ..< sim.waveFlashTick.len:
    for flat in sim.waveSweepCells(bucket):
      result.addChip(nextState, WaveSpriteId, bakedWave, waveLabel())
      result.place(nextState.objectsPresent, WaveObjectBase + flat,
        sim.city.cellX[flat] * CellPx, sim.city.cellY[flat] * CellPx,
        WaveZ, WaveSpriteId)

  # Cars.
  for id in 0 ..< sim.cars.len:
    if not sim.cars[id].active or sim.cars[id].link < 0:
      continue
    let
      link = sim.cars[id].link
      flat = sim.city.flatCell(link, sim.cars[id].cell)
      dir = sim.city.links[link].dir
      colour = id mod CarColours
      chevron = sim.cars[id].destGate == oppositeGate(sim.cars[id].originGate)
      tiny = nextState.tiny
      index =
        if tiny: dashSpriteIndex(dir, colour)
        else: carSpriteIndex(dir, colour, chevron)
      spriteId = (if tiny: CarDashBase else: CarSpriteBase) + index
    result.addChip(nextState, spriteId,
      (if tiny: bakedDashes[index] else: bakedCars[index]),
      (if tiny: dashLabel(dir, colour) else: carLabel(dir, colour, chevron)))
    result.place(nextState.objectsPresent, CarObjectBase + id,
      sim.city.cellX[flat] * CellPx + (CellPx - CarPx) div 2,
      sim.city.cellY[flat] * CellPx + (CellPx - CarPx) div 2,
      CarZ, spriteId)

  # Signal heads: all 64 approaches, three lamps each.
  for at in 0 ..< Intersections:
    let
      row = at div Cols
      col = at mod Cols
      bx = boxX(col) * CellPx
      by = boxY(row) * CellPx
    for approach in ApproachOrder:
      let
        state0 = sim.lampFor(at, approach)
        index = signalSpriteIndex(approach, state0)
        spriteId = SignalHeadBase + index
      result.addChip(nextState, spriteId, bakedSignals[index],
        signalLabel(approach, state0))
      var
        x = bx
        y = by
      case approach
      of apN:
        x = bx + 1
        y = by - SignalPx - 1
      of apS:
        x = bx + CellPx + 1
        y = by + CellPx * 2 + 1
      of apW:
        x = bx - SignalPx - 1
        y = by + CellPx + 1
      of apE:
        x = bx + CellPx * 2 + 1
        y = by + 1
      result.place(nextState.objectsPresent,
        SignalObjectBase + at * Approaches + ord(approach),
        x, y, SignalZ, spriteId)

  # Gate queues: one pip per waiting car, just outside the board edge.
  for g in 0 ..< Gates:
    let
      link = sim.city.gates[g].entryLink
      base = sim.city.cellBase[link]
      dir = sim.city.links[link].dir
    for i in 0 ..< min(sim.gateQueues[g].len, sim.config.gateQueueCap):
      result.addChip(nextState, GatePipSpriteId, bakedPip, gatePipLabel())
      var
        x = sim.city.cellX[base] * CellPx + 6
        y = sim.city.cellY[base] * CellPx + 6
      case dir
      of apS: y = y - 5 - i * 5
      of apN: y = y + 5 + i * 5
      of apE: x = x - 5 - i * 5
      of apW: x = x + 5 + i * 5
      result.place(nextState.objectsPresent,
        GatePipObjectBase + g * 16 + i,
        max(0, x), max(0, y), PipZ, GatePipSpriteId)

  # Retained-mode cleanup: anything this viewer holds that is no longer on the
  # board is deleted explicitly, so a departed car cannot linger.
  for objectId in 0 ..< previous.len:
    if previous[objectId] and not nextState.objectsPresent[objectId]:
      result.addDeleteObject(objectId)

proc addChromeSprite*(
  packet: var seq[uint8], stateJson: string
) =
  ## The chrome carrier: a 1x1 sprite whose LABEL is the whole broadcast
  ## chrome JSON. `broadcast_core.js` reads the label off sprite id 4090 and
  ## hands the text to the page.
  packet.addSprite(
    BroadcastChromeSpriteId, 1, 1, [0'u8, 0, 0, 0], stateJson)
