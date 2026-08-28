## Demand is a pure hash, and it is unsteerable. The design note's integrity
## claim, tested by replaying one seed under different seat behaviour and
## comparing the full `(gate, tick) -> (generated, throughRunner, destination)`
## table.

import std/[unittest]
import helpers

proc demandTable(config: GameConfig): seq[(bool, bool, int)] =
  for gate in 0 ..< Gates:
    for tick in 0 ..< config.maxTicks:
      let arrival = config.arrivalAt(gate, tick)
      result.add((arrival.generated, arrival.throughRunner, arrival.destGate))

suite "demand is unsteerable":
  test "the table is identical under two completely different behaviours":
    let config = testConfig()
    let wanted = demandTable(config)
    ## Run the episode two ways. Nothing a controller does may shift, reorder
    ## or consume another gate's draws, because the draws are not a stream.
    let greedy = runScripted(config, [blGreedy])
    let cycle = runScripted(config, [blFixedCycle])
    check demandTable(config) == wanted
    check greedy.demandGenerated == cycle.demandGenerated
    ## And with a third behaviour: every signal frozen on one phase.
    var frozen = newSim(config)
    for at in 0 ..< Intersections:
      frozen.setOrder(at, ovPhase, phNSG)
    for turnIndex in 1 .. frozen.turnsPerEpisode():
      if frozen.settled:
        break
      frozen.turn = turnIndex
      for k in 0 ..< config.turnTicks:
        if frozen.settled:
          break
        frozen.stepTick(k)
    check demandTable(config) == wanted
    check frozen.demandGenerated == greedy.demandGenerated

  test "the hash is a function of (seed, gate, tick) and nothing else":
    let a = testConfig("grid4x4", 42)
    let b = testConfig("grid4x4", 42)
    check demandTable(a) == demandTable(b)
    let c = testConfig("grid4x4", 43)
    check demandTable(a) != demandTable(c)

  test "a full gate queue rejects and counts without disturbing the hash":
    var config = testConfig()
    config.gateQueueCap = 1
    config.update("{}")
    let wanted = demandTable(config)
    let sim = runScripted(config, [blGreedy])
    check sim.rejected > 0
    check demandTable(config) == wanted
    ## demandGenerated counts rejections, so the two agree with the table.
    var generated = 0
    for entry in wanted:
      if entry[0]:
        inc generated
    check sim.demandGenerated <= generated

  test "the demand schedule follows the four permille bands":
    let config = testConfig()
    check config.permilleAt(0) == config.demandWarmPermille
    check config.permilleAt(config.demandPeakStart - 1) ==
      config.demandWarmPermille
    check config.permilleAt(config.demandPeakStart) ==
      config.demandPeakPermille
    check config.permilleAt(config.demandPeakEnd - 1) ==
      config.demandPeakPermille
    check config.permilleAt(config.demandPeakEnd) ==
      config.demandDeclinePermille
    check config.permilleAt(config.demandEndTick) == 0
    check config.permilleAt(config.maxTicks) == 0

  test "demand stops at demandEndTick and the clear-down is quiet":
    let config = testConfig()
    for gate in 0 ..< Gates:
      for tick in config.demandEndTick ..< config.maxTicks:
        check not config.arrivalAt(gate, tick).generated

  test "the rushhour variant really is heavier":
    let
      calm = testConfig("grid4x4")
      rush = testConfig("rushhour")
    var calmCount, rushCount: int
    for entry in demandTable(calm):
      if entry[0]: inc calmCount
    for entry in demandTable(rush):
      if entry[0]: inc rushCount
    echo "demand: grid4x4 ", calmCount, " rushhour ", rushCount
    check rushCount > calmCount
