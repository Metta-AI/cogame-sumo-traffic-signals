## Game-owned turn exchange: private observations, ordinary action validation,
## fallback, results, and replay. Player containers own every policy decision.

import std/json
import sim

type
  SeatPolicy* = object
    isLlm*: bool
    baseline*: Baseline
    label*: string
    registered*: bool

  ActionExchange* = proc(
    turn: int, views: array[MaxSeats, JsonNode], deadlineMs: int
  ): array[MaxSeats, JsonNode]

  DecisionEngine* = object
    seats*: array[MaxSeats, SeatPolicy]
    replies*: array[MaxSeats, ControllerReply]
    haveReply*: array[MaxSeats, bool]
    budgetGuardFired*: bool

proc initDecisionEngine*(): DecisionEngine =
  for slot in 0 ..< MaxSeats:
    result.seats[slot].baseline = blGreedy
    result.seats[slot].label = "greedy"

proc policyKind*(engine: DecisionEngine, slot: int): string =
  if engine.seats[slot].isLlm: "llm" else: "scripted"

proc fallbackRecord*(turn, slot, attempt: int, cause, detail: string): string =
  $(%*{
    "k": "fallback", "turn": turn, "slot": slot,
    "attempt": attempt, "cause": cause,
    "detail": detail.truncateRunes(MaxFallbackDetailRunes)
  })

proc registerRecord*(slot: int, policy, kind, baseline: string): string =
  $(%*{
    "k": "register", "slot": slot, "alias": seatAlias(slot),
    "quadrant": seatQuadrant(slot),
    "policy": policy.truncateRunes(MaxPolicyLabelRunes),
    "kind": kind, "baseline": baseline
  })

proc stopRecord*(tick: int, endRule: string): string =
  $(%*{"k": "stop", "tick": tick, "endRule": endRule})

proc resultRecord*(sim: SimServer, resultsJson: string): string =
  "{\"k\":\"result\",\"results\":" & resultsJson & "}"

proc ordersRecord*(sim: SimServer, turn: int): string =
  var entries = newJArray()
  for at in 0 ..< Intersections:
    let order = sim.signals[at].order
    entries.add(%*{
      "at": intersectionName(at), "slot": ownerOf(at),
      "verb": $order.verb, "phase": $order.phase, "delay": order.delay
    })
  var says = newJArray()
  for slot in 0 ..< MaxSeats:
    says.add(%sim.radio[slot])
  $(%*{"k": "orders", "turn": turn, "tick": sim.tickCount,
       "orders": entries, "say": says})

proc turn*(
  engine: var DecisionEngine, sim: var SimServer,
  turnIndex, elapsedSeconds: int, exchange: ActionExchange = nil
): seq[string] =
  ## Build every private view before applying any reply. All player decisions
  ## share one bounded deadline, so a seat cannot see another's current order.
  engine.haveReply = default(array[MaxSeats, bool])
  let turnSeconds = (sim.config.turnBudgetMs + 999) div 1000
  if elapsedSeconds + 2 * turnSeconds > sim.config.wallClockBudgetSeconds:
    if not engine.budgetGuardFired:
      result.add($( %*{"k": "budget_guard", "turn": turnIndex,
        "remaining_s": max(0, sim.config.wallClockBudgetSeconds - elapsedSeconds)}))
      engine.budgetGuardFired = true

  var views, replayViews: array[MaxSeats, JsonNode]
  for slot in 0 ..< MaxSeats:
    views[slot] = sim.observationJson(slot, turnIndex)
    replayViews[slot] = sim.observationForReplay(slot, turnIndex)

  var responses: array[MaxSeats, JsonNode]
  if exchange != nil and not engine.budgetGuardFired:
    responses = exchange(turnIndex, views, sim.config.turnBudgetMs)

  for slot in 0 ..< MaxSeats:
    if exchange == nil:
      let reply = sim.scriptedReply(slot, engine.seats[slot].baseline)
      engine.replies[slot] = reply
      engine.haveReply[slot] = true
      sim.applyReply(slot, reply)
      result.add(boundedDirectiveRecord(reply, turnIndex, slot, nil))
      continue

    let response = responses[slot]
    if response.isNil or response.kind != JObject or
        response{"action"}.isNil or response{"action"}.kind != JObject:
      var reply = sim.greedyReply(slot)
      reply.source = dsFallback
      engine.replies[slot] = reply
      engine.haveReply[slot] = true
      sim.applyReply(slot, reply)
      inc sim.fallbackTurns[slot]
      let cause =
        if not sim.players[slot].joined: "disconnected"
        elif engine.budgetGuardFired: "budget_guard"
        elif response.isNil: "timeout"
        else: "parse_error"
      result.add(fallbackRecord(turnIndex, slot, 1, cause,
        "seat did not return a valid action before the turn deadline"))
      result.add(boundedDirectiveRecord(reply, turnIndex, slot, nil))
      continue

    var owned: seq[int]
    for at in quadrantIntersections(slot):
      owned.add(at)
    var reply = parseControllerReply(response["action"], owned,
      sim.previousOrders(slot), turnIndex, sim.config.turnTicks)
    reply.source =
      if response{"source"}.getStr() == "fallback": dsFallback
      elif engine.seats[slot].isLlm: dsLlm
      else: dsScripted
    reply.latencyMs = max(0, response{"latency_ms"}.getInt())
    engine.replies[slot] = reply
    engine.haveReply[slot] = true
    sim.applyReply(slot, reply)
    case reply.source
    of dsLlm: inc sim.llmTurns[slot]
    of dsFallback:
      inc sim.fallbackTurns[slot]
      result.add(fallbackRecord(turnIndex, slot, 1,
        response{"cause"}.getStr("player_fallback"),
        "player used its policy fallback"))
    of dsScripted: discard
    result.add(boundedDirectiveRecord(reply, turnIndex, slot,
      if reply.source == dsLlm: replayViews[slot] else: nil))
