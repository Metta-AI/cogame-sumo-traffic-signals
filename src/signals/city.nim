## The city: the code-authored topology. Built once at load, identical in
## every episode, never generated and never loaded from a file — which is
## exactly what lets the wasm viewer reconstruct the whole city from the
## replay's config JSON with no fetch.
##
## Everything here is INTEGER. There is no floating point in this module and a
## test greps for it.
##
## Node numbering (used by the all-pairs route table):
##   0 .. 15   intersections, `rowIndex * 4 + colIndex` (A1 = 0 .. D4 = 15)
##   16 .. 31  gates, `16 + gateIndex`
##
## Gate order is the design note's: `nA1 nA2 nA3 nA4` (0-3), `sD1 sD2 sD3 sD4`
## (4-7), `wA1 wB1 wC1 wD1` (8-11), `eA4 eB4 eC4 eD4` (12-15).

import
  std/[strutils],
  sim_types

type
  Dir* = Approach               ## the four compass directions, reused as
                               ## travel directions (`apN` = northbound).

  GateSide* = enum
    gsNorth, gsSouth, gsWest, gsEast

  Gate* = object
    index*: int
    side*: GateSide
    intersection*: int          ## the intersection this gate is attached to.
    name*: string               ## `nA1`, `sD3`, `wB1`, `eC4`.
    entryLink*: int             ## gate -> intersection.
    exitLink*: int              ## intersection -> gate.

  Link* = object
    index*: int
    fromNode*: int
    toNode*: int
    cells*: int
    dir*: Dir                   ## direction of travel.
    isEntry*: bool              ## tail is a gate.
    isExit*: bool               ## head is a gate.
    upstream*: int              ## intersection at the tail, or -1.
    downstream*: int            ## intersection at the head, or -1.
    approach*: Approach         ## which approach of `downstream` it feeds
                               ## (meaningless when `isExit`).
    name*: string               ## `C2>C3`, `nA1>A1`, `A1>nA1`.

  City* = object
    links*: seq[Link]
    gates*: array[Gates, Gate]
    inbound*: array[Intersections, array[Approaches, int]]
      ## intersection -> approach -> the link that feeds it.
    outbound*: array[Intersections, array[Approaches, int]]
      ## intersection -> direction of travel -> the link that leaves it.
    nextHop*: array[32, array[32, int]]
      ## all-pairs next-hop table, computed once at load by the
      ## label-correcting search below.
    totalCells*: int
    cellX*: seq[int]            ## flat (link, cell) -> board cell x.
    cellY*: seq[int]            ## flat (link, cell) -> board cell y.
    cellBase*: seq[int]         ## link -> first flat cell index.

const
  DirVecX*: array[Approach, int] = [0, 1, 0, -1]
  DirVecY*: array[Approach, int] = [-1, 0, 1, 0]

proc opposite*(dir: Dir): Dir =
  case dir
  of apN: apS
  of apS: apN
  of apE: apW
  of apW: apE

proc leftOf*(dir: Dir): Dir =
  ## The driver's left, on a right-hand-drive board with north up: facing
  ## south your left hand points east.
  case dir
  of apN: apW
  of apW: apS
  of apS: apE
  of apE: apN

proc rightOf*(dir: Dir): Dir =
  case dir
  of apN: apE
  of apE: apS
  of apS: apW
  of apW: apN

proc movementBetween*(arrive, depart: Dir): Movement =
  ## A car's movement class at an intersection: the next link's direction
  ## versus the direction it was already travelling. U-turns do not exist and
  ## the route builder asserts no route ever requires one.
  if depart == arrive: mvThrough
  elif depart == leftOf(arrive): mvLeft
  elif depart == rightOf(arrive): mvRight
  else: mvNone

proc boxX*(col: int): int =
  ## Board cell x of an intersection box's north-west corner. The box is
  ## 2 x 2 cells and each street carries its two directions as two adjacent
  ## lanes (design §The city, board size in cells).
  4 + col * 8

proc boxY*(row: int): int =
  3 + row * 6

proc gateSideOf(index: int): GateSide =
  if index < 4: gsNorth
  elif index < 8: gsSouth
  elif index < 12: gsWest
  else: gsEast

proc gateIntersection(index: int): int =
  case gateSideOf(index)
  of gsNorth: index mod 4                    ## A1 .. A4
  of gsSouth: 3 * Cols + (index mod 4)       ## D1 .. D4
  of gsWest: (index mod 4) * Cols            ## A1, B1, C1, D1
  of gsEast: (index mod 4) * Cols + 3        ## A4, B4, C4, D4

proc gateName*(index: int): string =
  let at = intersectionName(gateIntersection(index))
  case gateSideOf(index)
  of gsNorth: "n" & at
  of gsSouth: "s" & at
  of gsWest: "w" & at
  of gsEast: "e" & at

proc gateIndex*(name: string): int =
  for g in 0 ..< Gates:
    if gateName(g) == name:
      return g
  -1

proc oppositeGate*(index: int): int =
  ## The gate directly across the city: `nA1` <-> `sD1`, `wB1` <-> `eB4`.
  case gateSideOf(index)
  of gsNorth: index + 4
  of gsSouth: index - 4
  of gsWest: index + 4
  of gsEast: index - 4

proc gateEntryDir(index: int): Dir =
  ## The direction a car travels as it enters the city through this gate.
  case gateSideOf(index)
  of gsNorth: apS
  of gsSouth: apN
  of gsWest: apE
  of gsEast: apW

proc nodeName*(node: int): string =
  if node < Intersections: intersectionName(node)
  else: gateName(node - Intersections)

proc gateNode*(index: int): int = Intersections + index

proc isGateNode*(node: int): bool = node >= Intersections

# ---------------------------------------------------------------------------
#  Construction
# ---------------------------------------------------------------------------

proc addLink(
  city: var City, fromNode, toNode, cells: int, dir: Dir
): int =
  var link = Link(
    index: city.links.len,
    fromNode: fromNode,
    toNode: toNode,
    cells: cells,
    dir: dir,
    isEntry: isGateNode(fromNode),
    isExit: isGateNode(toNode),
    upstream: (if isGateNode(fromNode): -1 else: fromNode),
    downstream: (if isGateNode(toNode): -1 else: toNode),
    approach: opposite(dir),
    name: nodeName(fromNode) & ">" & nodeName(toNode)
  )
  city.links.add(link)
  if link.downstream >= 0:
    city.inbound[link.downstream][ord(link.approach)] = link.index
  if link.upstream >= 0:
    city.outbound[link.upstream][ord(dir)] = link.index
  link.index

proc betterLabel(
  costA, turnsA: int, pathA: seq[int],
  costB, turnsB: int, pathB: seq[int]
): bool =
  ## The route tie-break, total by construction: fewer cells, then fewer
  ## turns, then the lexicographically lowest node path (i.e. "lowest next
  ## node index" all the way down). A total order is what makes the route
  ## table byte-identical across two builds.
  if costA != costB:
    return costA < costB
  if turnsA != turnsB:
    return turnsA < turnsB
  let n = min(pathA.len, pathB.len)
  for i in 0 ..< n:
    if pathA[i] != pathB[i]:
      return pathA[i] < pathB[i]
  pathA.len < pathB.len

proc buildRoutes(city: var City) =
  ## Dijkstra-class label-correcting search from every node, edge cost = the
  ## link's cell count (i.e. free-flow travel ticks). Cycles cannot occur:
  ## every edge cost is positive, so a revisit strictly worsens the cost and
  ## can never win the comparison above.
  const Nodes = Intersections + Gates
  for source in 0 ..< Nodes:
    var
      cost = newSeq[int](Nodes)
      turns = newSeq[int](Nodes)
      arrive = newSeq[int](Nodes)     ## ord(Dir) of the link that reached it.
      path = newSeq[seq[int]](Nodes)
      seen = newSeq[bool](Nodes)
      queue: seq[int] = @[source]
    for i in 0 ..< Nodes:
      cost[i] = high(int) div 4
      arrive[i] = -1
    cost[source] = 0
    turns[source] = 0
    path[source] = @[source]
    seen[source] = true
    var guard = 0
    while queue.len > 0 and guard < Nodes * Nodes * 4:
      inc guard
      let u = queue[0]
      queue.delete(0)
      if not seen[u]:
        continue
      for link in city.links:
        if link.fromNode != u:
          continue
        let v = link.toNode
        var extraTurn = 0
        if arrive[u] >= 0:
          let arriveDir = Dir(arrive[u])
          if link.dir != arriveDir:
            extraTurn = 1
          if link.dir == opposite(arriveDir):
            continue                  ## a U-turn is never part of a route.
        let
          candCost = cost[u] + link.cells
          candTurns = turns[u] + extraTurn
        var candPath = path[u]
        candPath.add(v)
        if not seen[v] or betterLabel(
            candCost, candTurns, candPath, cost[v], turns[v], path[v]):
          cost[v] = candCost
          turns[v] = candTurns
          arrive[v] = ord(link.dir)
          path[v] = candPath
          seen[v] = true
          queue.add(v)
    for dest in 0 ..< Nodes:
      city.nextHop[source][dest] =
        if dest == source or not seen[dest] or path[dest].len < 2: -1
        else: path[dest][1]

proc buildCellGeometry(city: var City) =
  ## Board cell coordinates for every (link, cell). Lanes follow right-hand
  ## drive: eastbound rides the southern lane, southbound the western lane,
  ## which is what makes the two directions of one street legible side by
  ## side at 7.8 px per cell.
  city.cellBase = newSeq[int](city.links.len)
  city.cellX = @[]
  city.cellY = @[]
  for link in city.links:
    city.cellBase[link.index] = city.cellX.len
    for i in 0 ..< link.cells:
      var x, y: int
      let
        fromInt = link.fromNode
        toInt = link.toNode
      case link.dir
      of apE:
        y =
          if fromInt < Intersections: boxY(fromInt div Cols) + 1
          else: boxY(toInt div Cols) + 1
        if link.isEntry:
          x = i                                     ## west gate, 4 cells.
        elif link.isExit:
          x = BoardCellsWide - 4 + i                ## east gate, 4 cells.
        else:
          x = boxX(fromInt mod Cols) + 2 + i
      of apW:
        y =
          if fromInt < Intersections: boxY(fromInt div Cols)
          else: boxY(toInt div Cols)
        if link.isEntry:
          x = BoardCellsWide - 1 - i                ## east gate inbound.
        elif link.isExit:
          x = 3 - i                                 ## west gate outbound.
        else:
          x = boxX(fromInt mod Cols) - 1 - i
      of apS:
        x =
          if fromInt < Intersections: boxX(fromInt mod Cols)
          else: boxX(toInt mod Cols)
        if link.isEntry:
          y = i                                     ## north gate, 3 cells.
        elif link.isExit:
          y = BoardCellsHigh - 3 + i                ## south gate outbound.
        else:
          y = boxY(fromInt div Cols) + 2 + i
      of apN:
        x =
          if fromInt < Intersections: boxX(fromInt mod Cols) + 1
          else: boxX(toInt mod Cols) + 1
        if link.isEntry:
          y = BoardCellsHigh - 1 - i                ## south gate inbound.
        elif link.isExit:
          y = 2 - i                                 ## north gate outbound.
        else:
          y = boxY(fromInt div Cols) - 1 - i
      city.cellX.add(x)
      city.cellY.add(y)
  city.totalCells = city.cellX.len

proc buildCity*(config: GameConfig): City =
  ## The whole topology, in the fixed link order that every "ascending link
  ## index" tie-break in the design note refers to.
  result.links = @[]
  for i in 0 ..< Intersections:
    for a in 0 ..< Approaches:
      result.inbound[i][a] = -1
      result.outbound[i][a] = -1
  # 1. east-west interior links, row-major, eastbound then westbound.
  for row in 0 ..< Rows:
    for col in 0 ..< Cols - 1:
      let
        west = row * Cols + col
        east = row * Cols + col + 1
      discard result.addLink(west, east, config.ewLinkCells, apE)
      discard result.addLink(east, west, config.ewLinkCells, apW)
  # 2. north-south interior links, column-major, southbound then northbound.
  for col in 0 ..< Cols:
    for row in 0 ..< Rows - 1:
      let
        north = row * Cols + col
        south = (row + 1) * Cols + col
      discard result.addLink(north, south, config.nsLinkCells, apS)
      discard result.addLink(south, north, config.nsLinkCells, apN)
  # 3. gate links, ascending gate index, entry then exit.
  for g in 0 ..< Gates:
    let
      at = gateIntersection(g)
      node = gateNode(g)
      side = gateSideOf(g)
      cells =
        if side == gsNorth or side == gsSouth: config.nsGateCells
        else: config.ewGateCells
      inDir = gateEntryDir(g)
    result.gates[g] = Gate(
      index: g,
      side: side,
      intersection: at,
      name: gateName(g),
      entryLink: result.addLink(node, at, cells, inDir),
      exitLink: result.addLink(at, node, cells, opposite(inDir))
    )
  result.buildRoutes()
  result.buildCellGeometry()

proc linkIndex*(city: City, name: string): int =
  for link in city.links:
    if link.name == name:
      return link.index
  -1

proc flatCell*(city: City, link, cell: int): int =
  city.cellBase[link] + cell

proc routeNextLink*(city: City, atNode, destGate: int): int =
  ## The link a car at `atNode` takes next on its way to `destGate`, from the
  ## precomputed next-hop table. -1 when it is already there.
  let dest = gateNode(destGate)
  if atNode == dest:
    return -1
  let hop = city.nextHop[atNode][dest]
  if hop < 0:
    return -1
  if atNode >= Intersections:
    return city.gates[atNode - Intersections].entryLink
  for a in 0 ..< Approaches:
    let candidate = city.outbound[atNode][a]
    if candidate >= 0 and city.links[candidate].toNode == hop:
      return candidate
  -1

proc routeCells*(city: City, fromGate, destGate: int): int =
  ## Free-flow travel ticks from a gate to a gate: the sum of the route's
  ## links' cell counts. Used by the route tests.
  var
    node = gateNode(fromGate)
    total = 0
    guard = 0
  while node != gateNode(destGate) and guard < 64:
    inc guard
    let link = city.routeNextLink(node, destGate)
    if link < 0:
      return -1
    total += city.links[link].cells
    node = city.links[link].toNode
  if node == gateNode(destGate): total else: -1

proc routeHasUTurn*(city: City, fromGate, destGate: int): bool =
  ## True when the route would ever double back — which the builder forbids
  ## and `tests/test_signals_sim.nim` asserts never happens.
  var
    node = gateNode(fromGate)
    lastDir = -1
    guard = 0
  while node != gateNode(destGate) and guard < 64:
    inc guard
    let link = city.routeNextLink(node, destGate)
    if link < 0:
      return false
    if lastDir >= 0 and city.links[link].dir == opposite(Dir(lastDir)):
      return true
    lastDir = ord(city.links[link].dir)
    node = city.links[link].toNode
  false

proc describeCity*(city: City): string =
  ## A one-line summary for the startup log.
  "city: " & $Intersections & " intersections, " & $Gates & " gates, " &
    $city.links.len & " links, " & $city.totalCells & " cells, board " &
    $BoardCellsWide & "x" & $BoardCellsHigh & " cells"

proc quadrantMapText*(): string =
  ## `Alpha:A1 A2 B1 B2 | Beta:...` — the fixed quadrant map, for logs.
  var parts: seq[string]
  for slot in 0 ..< MaxSeats:
    var names: seq[string]
    for i in quadrantIntersections(slot):
      names.add(intersectionName(i))
    parts.add(seatAlias(slot) & ":" & names.join(" "))
  parts.join(" | ")
