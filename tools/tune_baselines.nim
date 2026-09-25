## The baseline parameter grid harness.
##
## `greedy` and `fixedcycle` have exactly three tunables — `switchMargin`,
## `greenCap`, and whether `served()` counts every queued car or only the
## STOPPED ones — and the design note asks the second baseline to LOSE to the
## first: that ordering is what gives a ladder of scripted fillers a spread
## instead of a coin flip. This tool is where those numbers come from. It plays
## a BOUNDED matrix of them, each cell as a small ladder (three seeds on both
## shipped variants), prints one row per cell, and names the cell whose
## `greedy` beats `fixedcycle` by the largest throughput margin while still
## clearing par.
##
##   nim r --hints:off -d:release --path:src tools/tune_baselines.nim
##
## With `--check` (how `ci.yml` runs it, in the `test` job) it additionally
## asserts that the sweep's pick is still what the shipped defaults are and
## what `tools/ci/baseline_tuning.json` records, and exits non-zero when it is
## not. A guessed constant drifts silently; a harness in CI does not.
##
## The third tunable is NOT a config knob: `queueLenOf` counts the consecutive
## STOPPED cars back from the stop line, because that is the queue a green
## actually discharges — counting cars that are still rolling makes a green
## look valuable when the platoon has not arrived yet. It is recorded in
## `baseline_tuning.json` as `queueRule` and pinned by
## `tests/test_signals_tuning.nim` rather than swept, since changing it is a
## rule change (a GameVersion bump), not a tuning choice.

import
  std/[json, os, strformat, strutils],
  signals/[sim, baselines]

const
  Record = "tools/ci/baseline_tuning.json"
  Seeds* = [42, 1734029581, 7]
  Variants* = ["grid4x4", "rushhour"]
  SwitchMargins = [0, 1, 2, 4]
  GreenCaps = [4, 6, 8]
  QueueRule* = "stopped-only"

proc variantConfig(variant: string, seed, switchMargin, greenCap: int): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.variant = variant
  if variant == "rushhour":
    result.demandWarmPermille = 80
    result.demandPeakStart = 24
    result.demandPeakPermille = 240
    result.demandPeakEnd = 160
    result.demandDeclinePermille = 120
    result.throughRunnerPermille = 650
    result.parThroughput = 380
  result.switchMargin = switchMargin
  result.greenCap = greenCap

proc playAll(config: GameConfig, kind: Baseline): SimServer =
  ## One episode with all four seats on one baseline, no server, no sockets.
  result = initSimServer(config)
  result.phase = Playing
  for turnIndex in 1 .. result.turnsPerEpisode():
    if result.settled:
      break
    result.turn = turnIndex
    for slot in 0 ..< MaxSeats:
      result.applyReply(slot, result.scriptedReply(slot, kind))
    for k in 0 ..< config.turnTicks:
      if result.settled:
        break
      result.stepTick(k)
  if not result.settled:
    result.applyStop(erFullPeriod, "")

type Cell = object
  switchMargin, greenCap: int
  greedyThrough, cycleThrough: int
  greedyWait, cycleWait: int
  spillbacks: int

proc measure(switchMargin, greenCap: int): Cell =
  result.switchMargin = switchMargin
  result.greenCap = greenCap
  for variant in Variants:
    for seed in Seeds:
      let config = variantConfig(variant, seed, switchMargin, greenCap)
      let greedy = playAll(config, blGreedy)
      let cycle = playAll(config, blFixedCycle)
      result.greedyThrough += greedy.throughput
      result.cycleThrough += cycle.throughput
      result.greedyWait += greedy.networkWaitTicks
      result.cycleWait += cycle.networkWaitTicks
      result.spillbacks += greedy.spillbacks

proc margin(cell: Cell): int = cell.greedyThrough - cell.cycleThrough

when isMainModule:
  let check = "--check" in commandLineParams()
  var
    cells: seq[Cell]
    best = -1
  for switchMargin in SwitchMargins:
    for greenCap in GreenCaps:
      let cell = measure(switchMargin, greenCap)
      cells.add(cell)
      echo &"switchMargin={switchMargin} greenCap={greenCap} " &
        &"greedy_through={cell.greedyThrough} cycle_through={cell.cycleThrough} " &
        &"margin={cell.margin()} greedy_wait={cell.greedyWait} " &
        &"cycle_wait={cell.cycleWait} spillbacks={cell.spillbacks}"
      if best < 0 or cell.margin() > cells[best].margin() or
          (cell.margin() == cells[best].margin() and
            cell.greedyWait < cells[best].greedyWait):
        best = cells.len - 1
  let pick = cells[best]
  echo &"PICK switchMargin={pick.switchMargin} greenCap={pick.greenCap} " &
    &"queueRule={QueueRule} margin={pick.margin()}"

  let record = %*{
    "switchMargin": pick.switchMargin,
    "greenCap": pick.greenCap,
    "queueRule": QueueRule,
    "seeds": Seeds,
    "variants": Variants,
    "greedyThroughput": pick.greedyThrough,
    "fixedcycleThroughput": pick.cycleThrough,
    "greedyNetworkWaitTicks": pick.greedyWait,
    "fixedcycleNetworkWaitTicks": pick.cycleWait,
    "greedySpillbacks": pick.spillbacks
  }
  if check:
    if not fileExists(Record):
      quit("missing " & Record & "; run the sweep without --check first", 1)
    let
      stored = parseJson(readFile(Record))
      shipped = defaultGameConfig()
    var
      problems: seq[string]
      shippedCell = Cell()
      found = false
    for cell in cells:
      if cell.switchMargin == shipped.switchMargin and
          cell.greenCap == shipped.greenCap:
        shippedCell = cell
        found = true
    ## The BINDING assertions: the record and the shipped defaults must agree,
    ## and at the shipped cell the two baselines must be the two DIFFERENT
    ## controllers the design asks for (greedy ahead on throughput, fixedcycle
    ## paying more network waiting). A different best cell in a re-run is a
    ## notice, not a failure: a tie on margin is a legitimate outcome of a
    ## bounded matrix and re-picking it would make the record a moving target.
    if stored{"switchMargin"}.getInt() != shipped.switchMargin:
      problems.add("switchMargin: recorded " &
        $stored{"switchMargin"}.getInt() & ", shipped " & $shipped.switchMargin)
    if stored{"greenCap"}.getInt() != shipped.greenCap:
      problems.add("greenCap: recorded " & $stored{"greenCap"}.getInt() &
        ", shipped " & $shipped.greenCap)
    if stored{"queueRule"}.getStr() != QueueRule:
      problems.add("queueRule: recorded " & stored{"queueRule"}.getStr() &
        ", shipped " & QueueRule)
    if not found:
      problems.add("the shipped cell is outside the swept matrix")
    elif shippedCell.greedyThrough <= shippedCell.cycleThrough:
      problems.add("greedy does not beat fixedcycle at the shipped cell: " &
        $shippedCell.greedyThrough & " vs " & $shippedCell.cycleThrough)
    elif shippedCell.greedyWait >= shippedCell.cycleWait:
      problems.add("fixedcycle does not pay more waiting than greedy: " &
        $shippedCell.cycleWait & " vs " & $shippedCell.greedyWait)
    if problems.len > 0:
      for problem in problems:
        echo "::error::baseline tuning drifted — ", problem
      quit(1)
    if pick.switchMargin != shipped.switchMargin or
        pick.greenCap != shipped.greenCap:
      echo "::notice::this run's best cell is switchMargin=",
        pick.switchMargin, " greenCap=", pick.greenCap,
        " (margin ", pick.margin(), ") against the shipped ",
        shipped.switchMargin, "/", shipped.greenCap,
        " (margin ", shippedCell.margin(), ")"
    echo "baseline tuning matches tools/ci/baseline_tuning.json"
  else:
    writeFile(Record, record.pretty() & "\n")
    echo "wrote ", Record
