## Bounded orders and legality on the scripted baselines, the driver, and the
## reply validator. Tests 18-21 and 23 of the design note's list.

import std/[json, random, unittest, unicode]
import helpers
import signals/[directives, driver, player_policy]

proc randomWorld(rng: var Rand, variant: string): SimServer =
  ## A pseudo-random world state: a demand phase, a scatter of cars on random
  ## links, a scatter of phases, and some links deliberately filled.
  var config = testConfig(variant, rng.rand(1 .. 1_000_000))
  result = newSim(config)
  result.tickCount = rng.rand(0 ..< config.maxTicks)
  result.turn = 1 + result.tickCount div config.turnTicks
  for at in 0 ..< Intersections:
    result.signals[at].phase = SelectablePhases[rng.rand(0 .. 3)]
    result.signals[at].ticksInPhase = rng.rand(0 .. 12)
    result.signals[at].clearLeft =
      (if rng.rand(0 .. 5) == 0: rng.rand(1 .. config.clearTicks) else: 0)
  for _ in 0 ..< rng.rand(0 .. 200):
    let
      link = rng.rand(0 ..< result.city.links.len)
      cell = rng.rand(0 ..< result.city.links[link].cells)
    if result.occupantAt(link, cell) >= 0:
      continue
    discard result.placeCar(link, cell, rng.rand(0 ..< Gates),
                            rng.rand(0 ..< Gates))
  ## Fill a few links outright so spillback and ring states appear.
  for _ in 0 ..< rng.rand(0 .. 6):
    let link = rng.rand(0 ..< result.city.links.len)
    for cell in 0 ..< result.city.links[link].cells:
      if result.occupantAt(link, cell) >= 0:
        continue
      discard result.placeCar(link, cell, rng.rand(0 ..< Gates),
                              rng.rand(0 ..< Gates))
  result.measureFlow()
  result.detectGridlock()

suite "baselines are bounded":
  test "player baselines reproduce game baselines from private observations":
    var rng = initRand(20260925)
    for _ in 0 ..< 40:
      let sim = randomWorld(rng, "grid4x4")
      for slot in 0 ..< MaxSeats:
        let view = sim.observationJson(slot, sim.turn)
        for kind in [blGreedy, blFixedCycle]:
          let action = scriptedAction(view, $kind)
          let parsed = parseControllerReply(action,
            quadrantIntersections(slot), sim.previousOrders(slot),
            sim.turn, sim.config.turnTicks)
          let expected = sim.scriptedReply(slot, kind)
          check parsed.rejected == 0
          check parsed.orders.len == expected.orders.len
          for index in 0 ..< expected.orders.len:
            check parsed.orders[index].at == expected.orders[index].at
            check parsed.orders[index].verb == expected.orders[index].verb
            if parsed.orders[index].verb in [ovPhase, ovWave]:
              check parsed.orders[index].phase == expected.orders[index].phase

  test "18. 200 random worlds x both baselines x every slot stay legal":
    var rng = initRand(20260828)
    for i in 0 ..< 200:
      let variant = (if i mod 2 == 0: "grid4x4" else: "rushhour")
      var sim = randomWorld(rng, variant)
      for kind in [blGreedy, blFixedCycle]:
        for slot in 0 ..< MaxSeats:
          let
            owned = quadrantIntersections(slot)
            reply = sim.scriptedReply(slot, kind)
          check reply.orders.len <= MaxOrdersPerReply
          check reply.say.len == 0
          check reply.notes.len == 0
          var seen: seq[int]
          for order in reply.orders:
            check order.at in owned
            check order.at notin seen
            seen.add(order.at)
            check order.verb in [ovHold, ovPhase, ovWave, ovAuto]
            check order.phase != phCLR
            check order.phase in SelectablePhases
            check order.delay >= 0
            check order.delay <= sim.config.turnTicks - 2
          var orders = newJArray()
          for order in reply.orders:
            orders.add(orderJson(order))
          check ($orders).len <= 1024

suite "the driver never requests an illegal state":
  test "19. every requested phase is one of the four, in every world":
    var rng = initRand(20260829)
    for i in 0 ..< 60:
      var sim = randomWorld(rng, "grid4x4")
      for slot in 0 ..< MaxSeats:
        sim.applyReply(slot, sim.scriptedReply(slot, blGreedy))
      for verb in [ovHold, ovPhase, ovWave, ovAuto]:
        for at in 0 ..< Intersections:
          sim.setOrder(at, verb, SelectablePhases[at mod 4], at mod 7)
        for k in 0 ..< sim.config.turnTicks:
          for at in 0 ..< Intersections:
            let requested = sim.requestedPhase(at, k)
            check requested in SelectablePhases
            check requested != phCLR

  test "19. no order can discharge during clearance or leave a signal phaseless":
    var sim = newSim(emptyConfig())
    for at in 0 ..< Intersections:
      sim.forcePhase(at, phNSG)
      sim.setOrder(at, ovPhase, phEWG)
    let link = sim.city.linkIndex("nA1>A1")
    discard sim.placeCar(link, sim.city.links[link].cells - 1,
                         gateIndex("nA1"), gateIndex("sD1"))
    for k in 0 ..< sim.config.turnTicks:
      let before = sim.crossings
      sim.stepTick(k)
      if sim.signals[0].clearLeft > 0:
        check sim.crossings == before
      check sim.signals[0].phase in SelectablePhases

suite "the fallback is the greedy proc":
  test "20. greedyReply and the greedy baseline are the same orders":
    var rng = initRand(20260830)
    for _ in 0 ..< 40:
      var sim = randomWorld(rng, "grid4x4")
      for slot in 0 ..< MaxSeats:
        let
          fallback = sim.greedyReply(slot)
          baseline = sim.scriptedReply(slot, blGreedy)
        check fallback.orders.len == baseline.orders.len
        for i in 0 ..< fallback.orders.len:
          check fallback.orders[i].at == baseline.orders[i].at
          check fallback.orders[i].verb == baseline.orders[i].verb
          check fallback.orders[i].phase == baseline.orders[i].phase

  test "20. auto and greedy share one served() implementation":
    var rng = initRand(20260831)
    for _ in 0 ..< 40:
      var sim = randomWorld(rng, "grid4x4")
      for at in 0 ..< Intersections:
        ## `auto` asks for the best phase only when it clears switchMargin,
        ## which is exactly the rule greedy's hold/phase choice applies.
        sim.setOrder(at, ovAuto)
        let
          auto = sim.requestedPhase(at, 0)
          greedy = sim.greedyOrderFor(at)
          wanted =
            if greedy.verb == ovHold: sim.signals[at].phase else: greedy.phase
        check auto == wanted

suite "reply validation":
  let owned = @[intersectionIndex("C1"), intersectionIndex("C2"),
                intersectionIndex("D1"), intersectionIndex("D2")]
  var previous: seq[SignalOrder]
  for i in 0 ..< 4:
    previous.add(SignalOrder(verb: ovWave, phase: phNSL, delay: 5, turn: 1,
                             outcome: orRan))

  test "21. it accepts the schema":
    let reply = parseControllerReply(parseJson("""
      {"orders":[{"at":"C2","verb":"wave","phase":"EWG","delay":3},
                 {"at":"C1","verb":"phase","phase":"EWG"},
                 {"at":"D1","verb":"hold"},
                 {"at":"D2","verb":"auto"}],
       "say":"eastbound wave on row C","notes":"gate C1 with hold"}"""),
      owned, previous, 9, 8)
    check reply.orders.len == 4
    check reply.rejected == 0
    check reply.say == "eastbound wave on row C"
    check reply.notes == "gate C1 with hold"
    check reply.orders[0].verb == ovWave
    check reply.orders[0].phase == phEWG
    check reply.orders[0].delay == 3

  test "21. an invalid order is REPAIRED to that intersection's previous order":
    let reply = parseControllerReply(parseJson("""
      {"orders":[{"at":"C2","verb":"teleport"},
                 {"at":"C1","verb":"phase","phase":"CLR"}]}"""),
      owned, previous, 9, 8)
    check reply.orders.len == 2
    check reply.rejected == 2
    for order in reply.orders:
      check order.repaired
      check order.verb == ovWave
      check order.phase == phNSL
      check order.delay == 5

  test "21. it drops orders for intersections the seat does not own":
    let reply = parseControllerReply(parseJson("""
      {"orders":[{"at":"A1","verb":"hold"},{"at":"C2","verb":"hold"}]}"""),
      owned, previous, 9, 8)
    check reply.orders.len == 1
    check reply.orders[0].at == intersectionIndex("C2")
    check reply.rejected == 1

  test "21. it drops a duplicate `at`":
    let reply = parseControllerReply(parseJson("""
      {"orders":[{"at":"C2","verb":"hold"},{"at":"c2","verb":"auto"}]}"""),
      owned, previous, 9, 8)
    check reply.orders.len == 1
    check reply.rejected == 1

  test "21. it clamps delay to 0 .. turnTicks-2 and repairs a non-integer":
    let high = parseControllerReply(parseJson("""
      {"orders":[{"at":"C2","verb":"wave","phase":"EWG","delay":99}]}"""),
      owned, previous, 9, 8)
    check high.orders[0].delay == 6
    let negative = parseControllerReply(parseJson("""
      {"orders":[{"at":"C2","verb":"wave","phase":"EWG","delay":-4}]}"""),
      owned, previous, 9, 8)
    check negative.orders[0].delay == 0
    let bad = parseControllerReply(parseJson("""
      {"orders":[{"at":"C2","verb":"wave","phase":"EWG","delay":"soon"}]}"""),
      owned, previous, 9, 8)
    check bad.orders[0].delay == 0
    check bad.rejected == 1

  test "21. it caps orders at four":
    let reply = parseControllerReply(parseJson("""
      {"orders":[{"at":"C1","verb":"hold"},{"at":"C2","verb":"hold"},
                 {"at":"D1","verb":"hold"},{"at":"D2","verb":"hold"},
                 {"at":"C1","verb":"auto"}]}"""),
      owned, previous, 9, 8)
    check reply.orders.len == 4
    check reply.rejected == 1

  test "21. a say-only reply is USABLE":
    let reply = parseControllerReply(parseJson("""
      {"say":"C2>C3 is full, do not send me anything east"}"""),
      owned, previous, 9, 8)
    check reply.orders.len == 0
    check reply.say.len > 0

  test "21. a non-object is a parse failure":
    expect DirectiveError:
      discard parseControllerReply(parseJson("[1,2,3]"), owned, previous, 9, 8)

  test "21. say and notes truncate on RUNE boundaries with 4-byte emoji":
    ## A 4-byte emoji sitting exactly on the cap: a BYTE cut would leave half a
    ## codepoint, which renders in a browser and then fails a strict UTF-8
    ## parser. This is the test that would catch it.
    var say = ""
    for _ in 0 ..< 200:
      say.add("\u{1F6A6}")
    var notes = ""
    for _ in 0 ..< 400:
      notes.add("\u{1F6A6}")
    let node = %*{"orders": newJArray(), "say": say, "notes": notes}
    let reply = parseControllerReply(node, owned, previous, 9, 8)
    check reply.say.runeLen == MaxSayRunes
    check reply.notes.runeLen == MaxNoteRunes
    check reply.say.validateUtf8() == -1
    check reply.notes.validateUtf8() == -1
    check reply.say.len == MaxSayRunes * 4
    check reply.notes.len == MaxNoteRunes * 4

  test "21. the reply read is capped at 4096 bytes":
    check MaxReplyBytes == 4096
    var huge = "{\"say\":\""
    for _ in 0 ..< 8000:
      huge.add("x")
    huge.add("\"}")
    ## The cap is applied to the provider text before parsing; the validator
    ## still bounds the field itself.
    let text = huge.truncateBytes(MaxReplyBytes)
    check text.len <= MaxReplyBytes
    check text.len == MaxReplyBytes
    ## And it is a BYTE cap even when every rune is four bytes long: a rune
    ## cap at the same number let a 16 KB reply through.
    var emoji = ""
    for _ in 0 ..< 8000:
      emoji.add("\u{1F6A6}")
    let cut = emoji.truncateBytes(MaxReplyBytes)
    check cut.len <= MaxReplyBytes
    check cut.len == MaxReplyBytes
    check cut.runeLen == MaxReplyBytes div 4
    check cut.validateUtf8() == -1

  test "21. it never leaves a signal without an order":
    var sim = newSim(emptyConfig())
    for at in 0 ..< Intersections:
      sim.setOrder(at, ovWave, phNSL, 5)
    let reply = parseControllerReply(parseJson("""
      {"orders":[{"at":"C2","verb":"hold"}]}"""),
      owned, sim.previousOrders(2), 9, 8)
    sim.applyReply(2, reply)
    ## The intersection the reply named takes the new order; the three it did
    ## not name KEEP the order they had — never "no order".
    for at in quadrantIntersections(2):
      if at == intersectionIndex("C2"):
        check sim.signals[at].order.verb == ovHold
      else:
        check sim.signals[at].order.verb == ovWave
        check sim.signals[at].order.phase == phNSL
        check sim.signals[at].order.delay == 5

  test "21. extractJsonObject tolerates fences and trailing prose":
    let node = extractJsonObject(
      "Sure! ```json\n{\"orders\":[{\"at\":\"C2\",\"verb\":\"hold\"}]}\n```\nDone.")
    check node.kind == JObject
    check node{"orders"}.len == 1

suite "greedy exports congestion":
  test "23. greedy spills back on rushhour and fixedcycle waits more":
    let config = testConfig("rushhour")
    let
      greedy = runScripted(config, [blGreedy])
      cycle = runScripted(config, [blFixedCycle])
    echo "greedy:     ", describeState(greedy)
    echo "fixedcycle: ", describeState(cycle)
    ## Local greed discharges into full links, which is the behaviour the idea
    ## says it produces — shipped as the thing to beat.
    check greedy.spillbacks >= 1
    ## And the two controls really are two different controllers.
    check greedy.throughput != cycle.throughput or
      greedy.networkWaitTicks != cycle.networkWaitTicks
    let seed42 = testConfig("grid4x4", 42)
    let
      greedy42 = runScripted(seed42, [blGreedy])
      cycle42 = runScripted(seed42, [blFixedCycle])
    echo "seed 42 greedy wait     ", greedy42.networkWaitTicks,
      " through ", greedy42.throughput
    echo "seed 42 fixedcycle wait ", cycle42.networkWaitTicks,
      " through ", cycle42.throughput
    check cycle42.networkWaitTicks > greedy42.networkWaitTicks
