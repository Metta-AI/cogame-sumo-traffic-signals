## The sprite compositor: the install-time bakes. Forked from the starter's
## `src/ctf/rig_art.nim` — same idea (composite every chip ONCE at load so a
## frame is nothing but blits), retargeted from cog rigs to a baked city bed,
## signal-head chips and car chips.
##
## REAL ART, from the starter's shipped assets plus install-time bakes. The
## road surface is `data/arena_floor.png`, tiled and darkened, the block
## interiors are textured from `data/walls/wall_h.jpg` and `wall_v.jpg`, and
## the palette comes from `data/pallete.png` — exactly the way the starter
## bakes its endzone paint. Lane markings, stop lines, zebra crossings, turn
## arrows, gate arrows and the intersection labels are baked onto the same bed.
##
## Every sprite this module returns is STRAIGHT (non-premultiplied) RGBA, four
## bytes per pixel, which is what `broadcast_core.js`'s `putSpritePixel`
## composites.

import
  std/[os],
  pixie,
  sim_types, city

const
  CellPx* = 16                 ## board pixels per city cell.
  BoardPxWide* = BoardCellsWide * CellPx     ## 544
  BoardPxHigh* = BoardCellsHigh * CellPx     ## 416
  BedTiles* = 4                ## the bed ships as four quadrant sprites, so no
                               ## single sprite message approaches the hosted
                               ## 1 MiB websocket frame ceiling.
  CarPx* = 12
  SignalPx* = 8
  HeatLevels* = 8
  CarColours* = 5

type
  Rgba* = object
    r*, g*, b*, a*: uint8

  Chip* = object
    width*, height*: int
    pixels*: seq[uint8]        ## straight RGBA.

proc rgba*(r, g, b: int, a = 255): Rgba =
  Rgba(r: uint8(clamp(r, 0, 255)), g: uint8(clamp(g, 0, 255)),
       b: uint8(clamp(b, 0, 255)), a: uint8(clamp(a, 0, 255)))

proc newChip*(width, height: int): Chip =
  Chip(width: width, height: height, pixels: newSeq[uint8](width * height * 4))

proc put*(chip: var Chip, x, y: int, colour: Rgba) =
  if x < 0 or y < 0 or x >= chip.width or y >= chip.height:
    return
  let offset = (y * chip.width + x) * 4
  chip.pixels[offset] = colour.r
  chip.pixels[offset + 1] = colour.g
  chip.pixels[offset + 2] = colour.b
  chip.pixels[offset + 3] = colour.a

proc blend*(chip: var Chip, x, y: int, colour: Rgba) =
  ## Source-over onto the chip, kept integer so a bake is byte-identical on
  ## every host.
  if x < 0 or y < 0 or x >= chip.width or y >= chip.height:
    return
  let
    offset = (y * chip.width + x) * 4
    srcA = int(colour.a)
    dstA = int(chip.pixels[offset + 3])
    outA = srcA + dstA * (255 - srcA) div 255
  if outA == 0:
    chip.pixels[offset + 3] = 0
    return
  for i in 0 .. 2:
    let
      src = int([colour.r, colour.g, colour.b][i])
      dst = int(chip.pixels[offset + i])
    chip.pixels[offset + i] = uint8(
      (src * srcA + dst * dstA * (255 - srcA) div 255) div outA)
  chip.pixels[offset + 3] = uint8(outA)

proc fillRect*(chip: var Chip, x0, y0, w, h: int, colour: Rgba) =
  for y in y0 ..< y0 + h:
    for x in x0 ..< x0 + w:
      chip.put(x, y, colour)

proc blendRect*(chip: var Chip, x0, y0, w, h: int, colour: Rgba) =
  for y in y0 ..< y0 + h:
    for x in x0 ..< x0 + w:
      chip.blend(x, y, colour)

# ---------------------------------------------------------------------------
#  Assets
# ---------------------------------------------------------------------------

var
  palette: array[16, Rgba]
  paletteLoaded = false

proc dataPath*(name: string): string =
  ## The sim runs from the repo root natively and from the emscripten preload
  ## (`--preload-file data@data`) in the browser, so both roots are tried.
  for candidate in ["data/" & name, "/data/" & name, "./data/" & name]:
    if fileExists(candidate):
      return candidate
  "data/" & name

proc loadPalette*() =
  ## The 16-entry board palette from `data/pallete.png`, exactly as the
  ## starter reads it. A missing asset degrades to a legible grey ramp rather
  ## than killing the viewer.
  if paletteLoaded:
    return
  paletteLoaded = true
  for i in 0 ..< 16:
    let v = 16 + i * 15
    palette[i] = rgba(v, v, v)
  try:
    let image = readImage(dataPath("pallete.png"))
    if image.width >= 16 and image.height >= 1:
      for x in 0 ..< 16:
        let pixel = image[x, 0]
        palette[x] = rgba(int(pixel.r), int(pixel.g), int(pixel.b), 255)
  except CatchableError:
    discard

proc paletteColour*(index: int): Rgba =
  loadPalette()
  palette[clamp(index, 0, 15)]

proc seatColourRgba*(slot: int): Rgba =
  ## The four quadrant colours, matched to the chrome's `--red` / `--blue` /
  ## `--green` / `--yellow` utility classes so the board and the scorebug
  ## agree.
  case slot
  of 0: rgba(224, 82, 58)
  of 1: rgba(63, 124, 196)
  of 2: rgba(69, 168, 94)
  else: rgba(221, 197, 49)

proc carColourRgba*(index: int): Rgba =
  ## Five body colours drawn from the board palette's brighter end, so a
  ## stream of cars is legible against dark asphalt at 7.8 px per cell.
  case index
  of 0: rgba(236, 232, 220)
  of 1: rgba(198, 122, 64)
  of 2: rgba(96, 156, 200)
  of 3: rgba(168, 176, 184)
  else: rgba(122, 96, 148)

# ---------------------------------------------------------------------------
#  A 3x5 pixel font — just the eight glyphs the board actually needs
# ---------------------------------------------------------------------------

const Glyphs: array[8, array[5, uint8]] = [
  [0b010'u8, 0b101, 0b111, 0b101, 0b101],   # A
  [0b110'u8, 0b101, 0b110, 0b101, 0b110],   # B
  [0b011'u8, 0b100, 0b100, 0b100, 0b011],   # C
  [0b110'u8, 0b101, 0b101, 0b101, 0b110],   # D
  [0b010'u8, 0b110, 0b010, 0b010, 0b111],   # 1
  [0b110'u8, 0b001, 0b010, 0b100, 0b111],   # 2
  [0b111'u8, 0b001, 0b011, 0b001, 0b111],   # 3
  [0b101'u8, 0b101, 0b111, 0b001, 0b001]    # 4
]

proc glyphIndex(ch: char): int =
  case ch
  of 'A': 0
  of 'B': 1
  of 'C': 2
  of 'D': 3
  of '1': 4
  of '2': 5
  of '3': 6
  of '4': 7
  else: -1

proc drawGlyph*(chip: var Chip, ch: char, x0, y0, scale: int, colour: Rgba) =
  let index = glyphIndex(ch)
  if index < 0:
    return
  for row in 0 ..< 5:
    let bits = Glyphs[index][row]
    for col in 0 ..< 3:
      if (int(bits) and (1 shl (2 - col))) == 0:
        continue
      chip.fillRect(x0 + col * scale, y0 + row * scale, scale, scale, colour)

proc drawLabel*(chip: var Chip, text: string, x0, y0, scale: int, colour: Rgba) =
  var x = x0
  for ch in text:
    chip.drawGlyph(ch, x, y0, scale, colour)
    x += 4 * scale

# ---------------------------------------------------------------------------
#  The baked city bed
# ---------------------------------------------------------------------------

proc isRoadColumn(x: int): bool =
  for col in 0 ..< Cols:
    if x == boxX(col) or x == boxX(col) + 1:
      return true
  false

proc isRoadRow(y: int): bool =
  for row in 0 ..< Rows:
    if y == boxY(row) or y == boxY(row) + 1:
      return true
  false

proc isRoadCell*(x, y: int): bool = isRoadColumn(x) or isRoadRow(y)

proc isBoxCell*(x, y: int): bool = isRoadColumn(x) and isRoadRow(y)

proc sampleTiled(image: Image, x, y: int, darkenPct: int): Rgba =
  let pixel = image[x mod image.width, y mod image.height]
  rgba(
    int(pixel.r) * (100 - darkenPct) div 100,
    int(pixel.g) * (100 - darkenPct) div 100,
    int(pixel.b) * (100 - darkenPct) div 100)

proc bakeCityBed*(city: City, config: GameConfig): Chip =
  ## ONE static bake, so the per-frame cost is cars, signal lamps and overlays
  ## only. The asphalt is `arena_floor.png` tiled and darkened 30 %; the block
  ## interiors are the wall textures, darkened further and kerbed; the lane
  ## markings, stop lines, zebra crossings, turn arrows, gate arrows,
  ## intersection labels and faint quadrant tints are baked on top.
  loadPalette()
  result = newChip(BoardPxWide, BoardPxHigh)
  var
    floorImage: Image
    wallH: Image
    wallV: Image
    haveFloor = false
    haveWalls = false
  try:
    floorImage = readImage(dataPath("arena_floor.png"))
    haveFloor = floorImage.width > 0 and floorImage.height > 0
  except CatchableError:
    haveFloor = false
  try:
    wallH = readImage(dataPath("walls/wall_h.jpg"))
    wallV = readImage(dataPath("walls/wall_v.jpg"))
    haveWalls = wallH.width > 0 and wallV.width > 0
  except CatchableError:
    haveWalls = false

  for cy in 0 ..< BoardCellsHigh:
    for cx in 0 ..< BoardCellsWide:
      let road = isRoadCell(cx, cy)
      for py in 0 ..< CellPx:
        for px in 0 ..< CellPx:
          let
            x = cx * CellPx + px
            y = cy * CellPx + py
          var colour: Rgba
          if road:
            colour =
              if haveFloor: sampleTiled(floorImage, x, y, 8)
              else: rgba(58, 58, 64)
          else:
            colour =
              if haveWalls:
                if ((cx div 3) + (cy div 3)) mod 2 == 0:
                  sampleTiled(wallH, x, y, 42)
                else:
                  sampleTiled(wallV, x, y, 42)
              else:
                rgba(52, 46, 38)
          result.put(x, y, colour)

  # Kerbs: a pale edge everywhere a block interior meets a road cell.
  let kerb = rgba(214, 208, 192, 210)
  for cy in 0 ..< BoardCellsHigh:
    for cx in 0 ..< BoardCellsWide:
      if isRoadCell(cx, cy):
        continue
      let x0 = cx * CellPx
      let y0 = cy * CellPx
      if cy > 0 and isRoadCell(cx, cy - 1):
        result.blendRect(x0, y0, CellPx, 2, kerb)
      if cy + 1 < BoardCellsHigh and isRoadCell(cx, cy + 1):
        result.blendRect(x0, y0 + CellPx - 2, CellPx, 2, kerb)
      if cx > 0 and isRoadCell(cx - 1, cy):
        result.blendRect(x0, y0, 2, CellPx, kerb)
      if cx + 1 < BoardCellsWide and isRoadCell(cx + 1, cy):
        result.blendRect(x0 + CellPx - 2, y0, 2, CellPx, kerb)

  # Lane markings: a dashed centre line between the two directions of every
  # street, skipped inside the intersection boxes.
  let dash = rgba(226, 214, 170, 120)
  for col in 0 ..< Cols:
    let x = boxX(col) * CellPx + CellPx
    for y in countup(0, BoardPxHigh - 1, 8):
      let cy = y div CellPx
      if isRoadRow(cy):
        continue
      result.blendRect(x - 1, y, 2, 4, dash)
  for row in 0 ..< Rows:
    let y = boxY(row) * CellPx + CellPx
    for x in countup(0, BoardPxWide - 1, 8):
      let cx = x div CellPx
      if isRoadColumn(cx):
        continue
      result.blendRect(x, y - 1, 4, 2, dash)

  # Stop lines and zebra crossings on all 64 approaches, plus the quadrant
  # tint and the intersection label inside each box.
  let
    stopLine = rgba(238, 234, 222, 210)
    zebra = rgba(226, 224, 216, 90)
  for at in 0 ..< Intersections:
    let
      row = at div Cols
      col = at mod Cols
      bx = boxX(col) * CellPx
      by = boxY(row) * CellPx
      owner = ownerOf(at)
      tint = seatColourRgba(owner)
    result.blendRect(bx, by, CellPx * 2, CellPx * 2,
      rgba(int(tint.r), int(tint.g), int(tint.b), 46))
    # zebra crossings just outside the box on each side
    for i in countup(0, CellPx * 2 - 1, 4):
      result.blendRect(bx + i, by - 4, 2, 4, zebra)
      result.blendRect(bx + i, by + CellPx * 2, 2, 4, zebra)
      result.blendRect(bx - 4, by + i, 4, 2, zebra)
      result.blendRect(bx + CellPx * 2, by + i, 4, 2, zebra)
    # stop lines: one per approach, on the lane the approach arrives in
    result.blendRect(bx, by - 6, CellPx, 2, stopLine)              ## from N
    result.blendRect(bx + CellPx, by + CellPx * 2 + 4, CellPx, 2, stopLine) ## from S
    result.blendRect(bx - 6, by + CellPx, 2, CellPx, stopLine)     ## from W
    result.blendRect(bx + CellPx * 2 + 4, by, 2, CellPx, stopLine) ## from E
    # the intersection label, baked in the bed's palette
    result.drawLabel(intersectionName(at), bx + 3, by + 3, 2,
      rgba(240, 236, 224, 200))

  # Gate arrows: a chevron pointing INTO the city on every entry lane.
  let arrow = rgba(240, 200, 90, 190)
  for g in 0 ..< Gates:
    let
      link = city.gates[g].entryLink
      base = city.cellBase[link]
      cx = city.cellX[base]
      cy = city.cellY[base]
      x0 = cx * CellPx
      y0 = cy * CellPx
    for i in 0 ..< 5:
      case city.links[link].dir
      of apS:
        result.blendRect(x0 + 5 - i, y0 + 2 + i, 2 + i * 2, 2, arrow)
      of apN:
        result.blendRect(x0 + 5 - i, y0 + CellPx - 4 - i, 2 + i * 2, 2, arrow)
      of apE:
        result.blendRect(x0 + 2 + i, y0 + 5 - i, 2, 2 + i * 2, arrow)
      of apW:
        result.blendRect(x0 + CellPx - 4 - i, y0 + 5 - i, 2, 2 + i * 2, arrow)

  # The controller's alias at its quadrant's outer corner.
  for slot in 0 ..< MaxSeats:
    let
      tint = seatColourRgba(slot)
      corner = quadrantIntersections(slot)
      firstAt = corner[0]
      row = firstAt div Cols
      col = firstAt mod Cols
    var
      lx = boxX(col) * CellPx - 30
      ly = boxY(row) * CellPx - 30
    if slot == 1: lx = boxX(col + 1) * CellPx + 18
    if slot == 2: ly = boxY(row + 1) * CellPx + 18
    if slot == 3:
      lx = boxX(col + 1) * CellPx + 18
      ly = boxY(row + 1) * CellPx + 18
    result.drawLabel($intersectionName(firstAt)[0], max(2, lx), max(2, ly), 3,
      rgba(int(tint.r), int(tint.g), int(tint.b), 210))

proc bedTile*(bed: Chip, index: int): Chip =
  ## One quadrant of the baked bed, so no sprite message approaches the hosted
  ## 1 MiB websocket frame ceiling.
  let
    halfW = bed.width div 2
    halfH = bed.height div 2
    ox = (index mod 2) * halfW
    oy = (index div 2) * halfH
  result = newChip(halfW, halfH)
  for y in 0 ..< halfH:
    for x in 0 ..< halfW:
      let offset = ((y + oy) * bed.width + (x + ox)) * 4
      let target = (y * halfW + x) * 4
      for i in 0 .. 3:
        result.pixels[target + i] = bed.pixels[offset + i]

proc bedTileOrigin*(bed: Chip, index: int): tuple[x, y: int] =
  ((index mod 2) * (bed.width div 2), (index div 2) * (bed.height div 2))

# ---------------------------------------------------------------------------
#  Car chips
# ---------------------------------------------------------------------------

proc bakeCarChip*(dir: Dir, colourIndex: int, chevron: bool): Chip =
  ## A car chip: a body in one of five colours with a darker roof, a pale
  ## windscreen at the front, and (for a through-runner) a chevron on the
  ## roof. Four facings, so a car always points where it is going.
  result = newChip(CarPx, CarPx)
  let
    body = carColourRgba(colourIndex)
    roof = rgba(int(body.r) * 68 div 100, int(body.g) * 68 div 100,
                int(body.b) * 68 div 100)
    glass = rgba(210, 232, 244)
    tyre = rgba(24, 24, 28)
  let vertical = dir == apN or dir == apS
  if vertical:
    result.fillRect(2, 1, CarPx - 4, CarPx - 2, body)
    result.fillRect(3, 3, CarPx - 6, CarPx - 6, roof)
    if dir == apN:
      result.fillRect(3, 1, CarPx - 6, 2, glass)
    else:
      result.fillRect(3, CarPx - 3, CarPx - 6, 2, glass)
    result.fillRect(1, 3, 1, 2, tyre)
    result.fillRect(CarPx - 2, 3, 1, 2, tyre)
    result.fillRect(1, CarPx - 5, 1, 2, tyre)
    result.fillRect(CarPx - 2, CarPx - 5, 1, 2, tyre)
  else:
    result.fillRect(1, 2, CarPx - 2, CarPx - 4, body)
    result.fillRect(3, 3, CarPx - 6, CarPx - 6, roof)
    if dir == apE:
      result.fillRect(CarPx - 3, 3, 2, CarPx - 6, glass)
    else:
      result.fillRect(1, 3, 2, CarPx - 6, glass)
    result.fillRect(3, 1, 2, 1, tyre)
    result.fillRect(3, CarPx - 2, 2, 1, tyre)
    result.fillRect(CarPx - 5, 1, 2, 1, tyre)
    result.fillRect(CarPx - 5, CarPx - 2, 2, 1, tyre)
  if chevron:
    let mark = rgba(250, 244, 200)
    for i in 0 ..< 3:
      case dir
      of apN:
        result.put(CarPx div 2 - i, 4 + i, mark)
        result.put(CarPx div 2 + i, 4 + i, mark)
      of apS:
        result.put(CarPx div 2 - i, CarPx - 5 - i, mark)
        result.put(CarPx div 2 + i, CarPx - 5 - i, mark)
      of apE:
        result.put(CarPx - 5 - i, CarPx div 2 - i, mark)
        result.put(CarPx - 5 - i, CarPx div 2 + i, mark)
      of apW:
        result.put(4 + i, CarPx div 2 - i, mark)
        result.put(4 + i, CarPx div 2 + i, mark)

proc bakeCarDash*(dir: Dir, colourIndex: int): Chip =
  ## The `.tiny` readout: under 620 px the car chips drop their chevrons and
  ## render as 4 px dashes, so the queue heatmap becomes the primary readout.
  result = newChip(CarPx, CarPx)
  let body = carColourRgba(colourIndex)
  if dir == apN or dir == apS:
    result.fillRect(CarPx div 2 - 2, CarPx div 2 - 3, 4, 6, body)
  else:
    result.fillRect(CarPx div 2 - 3, CarPx div 2 - 2, 6, 4, body)

# ---------------------------------------------------------------------------
#  Signal heads
# ---------------------------------------------------------------------------

proc bakeSignalHead*(dir: Dir, state: int): Chip =
  ## A three-lamp housing with a visor: red / amber (clearance) / green, as
  ## the phase machine dictates. `dir` is the direction the head faces.
  result = newChip(SignalPx, SignalPx)
  let
    housing = rgba(28, 30, 34)
    visor = rgba(52, 56, 62)
    dark = rgba(46, 42, 40)
    red = rgba(232, 66, 52)
    amber = rgba(240, 176, 48)
    green = rgba(72, 208, 104)
  result.fillRect(1, 0, SignalPx - 2, SignalPx, housing)
  let vertical = dir == apN or dir == apS
  if vertical:
    result.fillRect(0, (if dir == apN: 0 else: SignalPx - 1), SignalPx, 1, visor)
  else:
    result.fillRect((if dir == apW: 0 else: SignalPx - 1), 0, 1, SignalPx, visor)
  for lamp in 0 ..< 3:
    let lit = lamp == state
    let colour =
      if not lit: dark
      elif lamp == 0: red
      elif lamp == 1: amber
      else: green
    result.fillRect(3, 1 + lamp * 2, 2, 2, colour)

# ---------------------------------------------------------------------------
#  Overlays
# ---------------------------------------------------------------------------

proc bakeHeatChip*(level: int): Chip =
  ## The queue-length heatmap, the readout that carries the whole story at
  ## small sizes: a translucent band along the lane whose colour ramps green
  ## -> amber -> red with `queueLen / capacity`.
  result = newChip(CellPx, CellPx)
  let
    t = clamp(level, 0, HeatLevels - 1)
    r = 60 + t * 26
    g = 190 - t * 22
    b = 70 - t * 8
  result.fillRect(0, 0, CellPx, CellPx, rgba(r, g, b, 44 + t * 10))

proc bakeFullChip*(): Chip =
  ## A full link's band: a hard red edge, so a block that cannot accept
  ## another car reads instantly.
  result = newChip(CellPx, CellPx)
  result.fillRect(0, 0, CellPx, CellPx, rgba(216, 48, 40, 120))
  result.fillRect(0, 0, CellPx, 2, rgba(255, 96, 80, 200))

proc bakeRingChip*(): Chip =
  ## A gridlock ring link: outlined in red with a cross on the blocked stop
  ## line.
  result = newChip(CellPx, CellPx)
  let edge = rgba(255, 64, 48, 230)
  result.fillRect(0, 0, CellPx, 2, edge)
  result.fillRect(0, CellPx - 2, CellPx, 2, edge)
  result.fillRect(0, 0, 2, CellPx, edge)
  result.fillRect(CellPx - 2, 0, 2, CellPx, edge)
  for i in 0 ..< CellPx:
    result.put(i, i, edge)
    result.put(CellPx - 1 - i, i, edge)

proc bakeWaveChip*(): Chip =
  ## The green-wave sweep: a bright band that runs the corridor's lane in the
  ## direction of travel at the platoon's speed.
  result = newChip(CellPx, CellPx)
  result.fillRect(0, 0, CellPx, CellPx, rgba(120, 255, 170, 96))

proc bakeGatePip*(): Chip =
  ## One queued car outside a gate. A gate queue that reaches capacity is the
  ## `gatejam` the feed calls out.
  result = newChip(4, 4)
  result.fillRect(0, 0, 4, 4, rgba(240, 210, 120, 220))

proc lampState*(phaseIsClearance, green: bool): int =
  ## 0 = red, 1 = amber (clearance), 2 = green.
  if phaseIsClearance: 1
  elif green: 2
  else: 0
