## Flow measurement: queue lengths, the full/spillback spans, the blocked-by
## graph and its gridlock-ring cycle search (tick step 10), and the
## green-wave window (tick step 11). Also the span tables the viewer's
## scrubber, sparkline and lull scan read.
##
## All integer. The ring search is a DFS from the lowest link index visiting
## successors in ascending link index and returning the FIRST cycle found —
## pinned that way for determinism, so the native game and the wasm viewer
## always report the same ring.

import
  std/[algorithm],
  sim_types, city, sim_state, vehicles, events

proc queueLenOf*(sim: SimServer, link: int): int =
  ## The number of consecutive STOPPED cars counted back from the stop line.
  ## This is the queue a green would actually discharge, and it is the same
  ## number the seats see in `detectors`.
  let cells = sim.city.links[link].cells
  var i = cells - 1
  while i >= 0:
    let car = sim.occupantAt(link, i)
    if car < 0:
      break
    if sim.cars[car].movedThisTick:
      break
    inc result
    dec i

proc linkOccupancy*(sim: SimServer, link: int): int =
  for i in 0 ..< sim.city.links[link].cells:
    if sim.occupantAt(link, i) >= 0:
      inc result

proc isFull*(sim: SimServer, link: int): bool =
  for i in 0 ..< sim.city.links[link].cells:
    if sim.occupantAt(link, i) < 0:
      return false
  true

proc approachQueue*(sim: SimServer, intersection: int, approach: Approach): int =
  let link = sim.city.inbound[intersection][ord(approach)]
  if link < 0: 0 else: sim.linkQueueLen[link]

proc measureFlow*(sim: var SimServer) =
  ## Tick step 9. Queue and spillback measurement, and the events that carry
  ## the story: a link that becomes full raises `spillback`, a full link that
  ## drops below full raises `spillclear`.
  var nowFull: seq[int]
  for link in sim.city.links:
    let
      i = link.index
      full = sim.isFull(i)
    sim.linkQueueLen[i] = sim.queueLenOf(i)
    if full:
      nowFull.add(i)
      if not sim.linkFull[i]:
        sim.linkFull[i] = true
        sim.linkFullTicks[i] = 1
        inc sim.spillbacks
        sim.emitEvent(initSimEvent(
          seSpillback, sim.tickCount,
          slot = (if link.downstream >= 0: ownerOf(link.downstream)
                  else: ownerOf(max(0, link.upstream))),
          at = (if link.downstream >= 0: link.downstream else: link.upstream),
          link = i))
      else:
        inc sim.linkFullTicks[i]
    else:
      if sim.linkFull[i]:
        sim.emitEvent(initSimEvent(
          seSpillClear, sim.tickCount,
          at = (if link.downstream >= 0: link.downstream else: link.upstream),
          link = i, a = sim.linkFullTicks[i]))
      sim.linkFull[i] = false
      sim.linkFullTicks[i] = 0
  sim.activeSpillback = nowFull
  if nowFull.len > 0:
    inc sim.spillbackTicks

proc blockedBySuccessor(sim: SimServer, link: int): int =
  ## The blocked-by edge of tick step 10: `L -> M` when `L`'s stop-line car's
  ## next link is `M` and `M`'s entry cell is occupied.
  let car = sim.stopLineCar(link)
  if car < 0:
    return -1
  let nextLink = sim.nextLinkFor(car)
  if nextLink < 0:
    return -1
  if sim.occupantAt(nextLink, 0) < 0:
    return -1
  nextLink

proc ringEligible(sim: SimServer, link: int): bool =
  sim.linkFull[link] and sim.linkFullTicks[link] >= sim.config.ringTicks

proc findGridlockRing*(sim: SimServer): seq[int] =
  ## The first directed cycle in the blocked-by graph in which every link is
  ## full and has been full for `ringTicks` consecutive ticks. DFS from the
  ## lowest link index, successors in ascending link index (each node has at
  ## most one successor here, so "ascending" is the start order), first cycle
  ## wins. Never latched: it breaks the moment one of its links discharges,
  ## which is exactly the skill the game rewards.
  for start in 0 ..< sim.city.links.len:
    if not sim.ringEligible(start):
      continue
    var
      path: seq[int] = @[]
      onPath = newSeq[bool](sim.city.links.len)
      node = start
      guard = 0
    while guard < sim.city.links.len + 1:
      inc guard
      if not sim.ringEligible(node):
        break
      if onPath[node]:
        var cycle: seq[int] = @[]
        var i = path.find(node)
        if i < 0:
          break
        while i < path.len:
          cycle.add(path[i])
          inc i
        if cycle.len >= 2:
          cycle.sort()
          return cycle
        break
      path.add(node)
      onPath[node] = true
      let nextLink = sim.blockedBySuccessor(node)
      if nextLink < 0:
        break
      node = nextLink
  @[]

proc detectGridlock*(sim: var SimServer) =
  ## Tick step 10. Entering a ring emits `gridlock`; leaving emits
  ## `gridlockclear`.
  let ring = sim.findGridlockRing()
  if ring.len > 0:
    if sim.activeGridlock.len == 0:
      inc sim.gridlocks
      sim.gridlockRun = 0
      var ats: seq[int]
      for link in ring:
        let at = sim.city.links[link].downstream
        if at >= 0 and not ats.contains(at):
          ats.add(at)
      sim.emitEvent(initSimEvent(
        seGridlock, sim.tickCount,
        at = (if ats.len > 0: ats[0] else: -1),
        link = ring[0], a = ring.len))
    inc sim.gridlockRun
    inc sim.gridlockTicks
    if sim.gridlockRun > sim.longestGridlockTicks:
      sim.longestGridlockTicks = sim.gridlockRun
    sim.activeGridlock = ring
  else:
    if sim.activeGridlock.len > 0:
      sim.emitEvent(initSimEvent(
        seGridlockClear, sim.tickCount,
        link = sim.activeGridlock[0], a = sim.gridlockRun))
    sim.activeGridlock = @[]
    sim.gridlockRun = 0

proc creditCorridor*(sim: var SimServer, car, link: int) =
  ## Tick step 11. A "progressed" credit is filed under the car's corridor —
  ## the row letter for an east/west-travelling car, the column digit for a
  ## north/south one — with the tick. When a corridor's credits inside the
  ## trailing `waveWindow` reach `waveVehicles`, a `wave` fires and the
  ## window is CLEARED, so one wave is one event.
  let
    dir = sim.city.links[link].dir
    at = (if sim.city.links[link].downstream >= 0:
            sim.city.links[link].downstream
          else: max(0, sim.city.links[link].upstream))
    bucket = corridorIndex(dir, at div Cols, at mod Cols)
  sim.waveTicks[bucket].add(sim.tickCount)
  var kept: seq[int]
  for tick in sim.waveTicks[bucket]:
    if sim.tickCount - tick < sim.config.waveWindow:
      kept.add(tick)
  sim.waveTicks[bucket] = kept
  if kept.len >= sim.config.waveVehicles:
    inc sim.greenWaves
    sim.waveTicks[bucket] = @[]
    sim.emitEvent(initSimEvent(
      seWave, sim.tickCount, at = at, a = bucket, b = kept.len,
      text = corridorLabel(bucket) & " " & corridorDirText(bucket)))

proc activeSpillbackNames*(sim: SimServer, limit: int): seq[string] =
  for link in sim.activeSpillback:
    if result.len >= limit:
      break
    result.add(sim.city.links[link].name)

proc activeGridlockNames*(sim: SimServer): seq[string] =
  for link in sim.activeGridlock:
    result.add(sim.city.links[link].name)
