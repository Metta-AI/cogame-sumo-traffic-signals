## The scoring formula and its sign. Test 14 of the design note's list.
##
## Everything here is integer, so the lexicographic ordering the design claims
## is a property that can be checked exactly rather than nearly.

import std/[random, unittest]
import helpers

suite "scoring":
  test "14. scores[s] == 1e6*throughput - 1e3*netWaitK - 10*seatWaitK[s]":
    var rng = initRand(20260828)
    for _ in 0 ..< 500:
      let
        throughput = rng.rand(0 .. 600)
        networkWaitTicks = rng.rand(0 .. 139_264)
      var seatWait: array[MaxSeats, int]
      for slot in 0 ..< MaxSeats:
        seatWait[slot] = rng.rand(0 .. 57_344)
      let netK = netWaitKOf(networkWaitTicks)
      for slot in 0 ..< MaxSeats:
        let seatK = seatWaitKOf(seatWait[slot])
        check scoreFor(throughput, netK, seatK) ==
          1_000_000 * throughput - 1_000 * netK - 10 * seatK

  test "14. the analytic bounds hold: netWaitK <= 696 < 999":
    ## networkWaitTicks <= (352 link cells + 16 x 12 gate-queue slots) x 256.
    let maxWait = (352 + Gates * DefaultGateQueueCap) * DefaultMaxTicks
    check maxWait == 139_264
    check netWaitKOf(maxWait) == 696
    check netWaitKOf(maxWait) < NetWaitCap

  test "14. the analytic bounds hold: seatWaitK <= 71 < 99":
    ## A seat's charged cells are at most 224: its four intersections' inbound
    ## links plus the gate queues they feed.
    let maxSeatWait = 224 * DefaultMaxTicks
    check maxSeatWait == 57_344
    check seatWaitKOf(maxSeatWait) == 71
    check seatWaitKOf(maxSeatWait) < SeatWaitCap

  test "14. the ordering is strictly lexicographic":
    ## One extra car through beats ANY penalty difference.
    check 1_000_000 > 1_000 * NetWaitCap + 10 * SeatWaitCap
    ## One unit of network waiting beats ANY seat penalty.
    check 1_000 > 10 * SeatWaitCap
    var rng = initRand(20260829)
    for _ in 0 ..< 500:
      let
        throughput = rng.rand(0 .. 500)
        netA = rng.rand(0 .. NetWaitCap)
        netB = rng.rand(0 .. NetWaitCap)
        seatA = rng.rand(0 .. SeatWaitCap)
        seatB = rng.rand(0 .. SeatWaitCap)
      ## Throughput dominates.
      check scoreFor(throughput + 1, netA, seatA) >
        scoreFor(throughput, netB, seatB)
      ## At equal throughput, network waiting dominates.
      if netA < netB:
        check scoreFor(throughput, netA, seatA) >
          scoreFor(throughput, netB, seatB)
      ## At equal throughput and network waiting, own-quadrant waiting decides.
      if seatA < seatB:
        check scoreFor(throughput, netA, seatA) >
          scoreFor(throughput, netA, seatB)

  test "14. scores are negative only when throughput is zero":
    for throughput in 1 .. 20:
      check scoreFor(throughput, NetWaitCap, SeatWaitCap) > 0
    check scoreFor(0, 1, 0) < 0

  test "14. the first two terms are identical for all four seats":
    let sim = runScripted(testConfig(), [blGreedy, blFixedCycle])
    var seen: seq[int]
    for slot in 0 ..< MaxSeats:
      let score = sim.scoreOf(slot)
      check score == scoreFor(sim.throughput, sim.netWaitK(),
                              sim.seatWaitK(slot))
      if score notin seen:
        seen.add(score)
    ## Only the epsilon third term may differ, so every score is within the
    ## seat-penalty band of every other.
    for a in seen:
      for b in seen:
        check abs(a - b) <= 10 * SeatWaitCap

  test "14. all four win flags are equal and winner is null":
    let sim = runScripted(testConfig(), [blGreedy])
    let document = parseJson(sim.cityResultsJson())
    check document{"winner"}.kind == JNull
    let wins = document{"win"}
    check wins.len == MaxSeats
    for i in 1 ..< wins.len:
      check wins[i].getBool() == wins[0].getBool()
    check wins[0].getBool() == (sim.throughput >= sim.config.parThroughput)

  test "14. a real episode's totals respect the caps":
    for variant in ["grid4x4", "rushhour"]:
      let sim = runScripted(testConfig(variant), [blGreedy, blFixedCycle])
      check sim.netWaitK() < NetWaitCap
      for slot in 0 ..< MaxSeats:
        check sim.seatWaitK(slot) < SeatWaitCap
