## The scripted baselines' tunables are the SWEEP'S pick, not a guess. Test 22
## of the design note's list; `ci.yml` re-runs the sweep itself with --check.

import std/[json, unittest]
import helpers

suite "baseline tuning is the swept pick":
  let record = parseJson(repoFile("tools/ci/baseline_tuning.json"))

  test "22. the shipped defaults equal tools/ci/baseline_tuning.json":
    let shipped = defaultGameConfig()
    check record{"switchMargin"}.getInt() == shipped.switchMargin
    check record{"greenCap"}.getInt() == shipped.greenCap
    check shipped.switchMargin == DefaultSwitchMargin
    check shipped.greenCap == DefaultGreenCap

  test "22. the queue-counting rule is the recorded one":
    ## `queueLenOf` counts the consecutive STOPPED cars back from the stop
    ## line, because that is the queue a green actually discharges. Changing it
    ## is a RULE change (a GameVersion bump), which is why it is recorded
    ## rather than swept.
    check record{"queueRule"}.getStr() == "stopped-only"
    var sim = newSim(emptyConfig())
    let link = sim.city.linkIndex("nA1>A1")
    for cell in 0 ..< sim.city.links[link].cells:
      discard sim.placeCar(link, cell, gateIndex("nA1"), gateIndex("sD1"))
    ## Every car is stopped, so the whole link is the queue.
    check sim.queueLenOf(link) == sim.city.links[link].cells
    ## Mark the stop-line car as having moved this tick: it is no longer
    ## queued, and neither is anything behind it.
    let head = sim.stopLineCar(link)
    sim.cars[head].movedThisTick = true
    check sim.queueLenOf(link) == 0

  test "22. the record names the seeds and variants the sweep used":
    check record{"seeds"}.len >= 3
    check record{"variants"}.len == 2
    check record{"note"}.getStr().len > 80

  test "22. every variant ships the recorded tunables":
    let manifest = manifestJson()
    for variant in manifest{"variants"}:
      check variant{"game_config"}{"switchMargin"}.getInt() ==
        record{"switchMargin"}.getInt()
      check variant{"game_config"}{"greenCap"}.getInt() ==
        record{"greenCap"}.getInt()
    let cert = manifest{"certification"}{"game_config"}
    check cert{"switchMargin"}.getInt() == record{"switchMargin"}.getInt()
    check cert{"greenCap"}.getInt() == record{"greenCap"}.getInt()

  test "22. served() never values a queue longer than the block that receives it":
    ## greenCap is the longest east-west block, so a green is never scored for
    ## more cars than the receiving link could hold.
    let config = defaultGameConfig()
    check config.greenCap == config.ewLinkCells
    check config.greenCap >= config.nsLinkCells
