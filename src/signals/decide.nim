## The decision layer: the per-turn loop that asks all four controllers what
## their signals do next, and always has an answer. Forked from the starter's
## `src/ctf/decide.nim`.
##
## Cadence: one turn every `turnTicks` (8 ticks = 8 simulated seconds), 32
## turns per episode. At each turn the server builds ALL FOUR seats' request
## bodies and issues them as ONE PARALLEL BATCH — this is a
## simultaneous-decision game, so querying seats one after another would
## quadruple the wall clock for nothing.
##
## DEGRADE, NEVER HANG. Every wait here is bounded: attempt 1 gets
## `attempt1Ms`, the single retry gets `retryMs`, the whole turn is wrapped in
## a monotonic `turnBudgetMs` deadline, a rolling 60 s request counter keeps
## the episode under the sidecar's 30 req/min cap, and the budget guard drops
## every seat to scripted play the moment two more full turns would not fit
## inside the engine's own wall-clock stop. On a second failure the seat plays
## the `greedy` scripted orders — the SAME proc the `greedy` baseline uses,
## imported and never duplicated — and a `fallback` record names the cause.

import
  std/[json, monotimes, os, strutils, times],
  curly,
  sim, llm

type
  SeatPolicy* = object
    ## What one seat registered as. A seat that registers with neither field —
    ## or never registers at all — is `greedy`.
    isLlm*: bool
    prompt*: string
    baseline*: Baseline
    label*: string
    registered*: bool

  DecisionEngine* = object
    client*: LlmClient
    seats*: seq[SeatPolicy]
    replies*: seq[ControllerReply]
    haveReply*: seq[bool]
    lastBatchStart*: MonoTime
    batchStarted*: bool
    llmOff*: bool              ## the budget guard fired; scripted from here on
    requestStamps*: seq[MonoTime]  ## the rolling 60 s rate guard.

proc initDecisionEngine*(sim: SimServer): DecisionEngine =
  result.client = newLlmClient(sim.config)
  result.seats = newSeq[SeatPolicy](MaxSeats)
  result.replies = newSeq[ControllerReply](MaxSeats)
  result.haveReply = newSeq[bool](MaxSeats)
  result.requestStamps = @[]
  for i in 0 ..< result.seats.len:
    result.seats[i].baseline = blGreedy
    result.seats[i].label = "greedy"

proc policyKind*(engine: DecisionEngine, seat: int): string =
  if seat >= 0 and seat < engine.seats.len and engine.seats[seat].isLlm:
    "llm"
  else:
    "scripted"

# ---------------------------------------------------------------------------
#  Records
# ---------------------------------------------------------------------------

proc fallbackRecord(turn, slot, attempt: int, cause, detail: string): string =
  $(%*{
    "k": "fallback",
    "turn": turn,
    "slot": slot,
    "attempt": attempt,
    "cause": cause,
    "detail": detail.truncateRunes(MaxFallbackDetailRunes)
  })

proc registerRecord*(
  slot: int, policy, kind, baseline: string
): string =
  ## The REDACTED registration record: the policy label, the kind, and which
  ## baseline a scripted seat picked. NEVER the prompt.
  $(%*{
    "k": "register",
    "slot": slot,
    "alias": seatAlias(slot),
    "quadrant": seatQuadrant(slot),
    "policy": policy.truncateRunes(MaxPolicyLabelRunes),
    "kind": kind,
    "baseline": baseline
  })

proc budgetGuardRecord(turn, remainingSeconds: int): string =
  $(%*{"k": "budget_guard", "turn": turn, "remaining_s": remainingSeconds})

proc stopRecord*(tick: int, endRule: string): string =
  ## The load-bearing wall-clock / fault stop, applied by `sim.applyStop` on
  ## record AND on playback.
  $(%*{"k": "stop", "tick": tick, "endRule": endRule})

proc resultRecord*(sim: SimServer, resultsJson: string): string =
  ## The `result` control record — the episode's whole results document,
  ## written once into the replay chat stream at episode end. It is what makes
  ## the replay SELF-SUFFICIENT. The document is already valid JSON, so it is
  ## embedded verbatim rather than re-parsed: nothing on the path to the
  ## artifact writes may raise.
  "{\"k\":\"result\",\"results\":" & resultsJson & "}"

proc ordersRecord*(
  sim: SimServer, turn: int
): string =
  ## THIS GAME'S ENTIRE INPUT LOG: per turn, per seat, per intersection, the
  ## accepted order. Applied by the same proc on record and on playback, so a
  ## replay re-simulates from bytes alone.
  var entries = newJArray()
  for at in 0 ..< Intersections:
    let order = sim.signals[at].order
    entries.add(%*{
      "at": intersectionName(at),
      "slot": ownerOf(at),
      "verb": $order.verb,
      "phase": $order.phase,
      "delay": order.delay
    })
  var says = newJArray()
  for slot in 0 ..< MaxSeats:
    says.add(%sim.radio[slot])
  $(%*{"k": "orders", "turn": turn, "tick": sim.tickCount,
       "orders": entries, "say": says})

# ---------------------------------------------------------------------------
#  The turn
# ---------------------------------------------------------------------------

proc pruneRateWindow(engine: var DecisionEngine, now: MonoTime) =
  var kept: seq[MonoTime]
  for stamp in engine.requestStamps:
    if (now - stamp).inSeconds.int < RateGuardWindowSeconds:
      kept.add(stamp)
  engine.requestStamps = kept

proc installScripted(
  engine: var DecisionEngine, sim: var SimServer, slot: int,
  kind: Baseline, source: DirectiveSource
) =
  var reply = sim.scriptedReply(slot, kind)
  reply.source = source
  engine.replies[slot] = reply
  engine.haveReply[slot] = true
  sim.applyReply(slot, reply)

proc turn*(
  engine: var DecisionEngine,
  sim: var SimServer,
  turnIndex: int,
  elapsedSeconds: int
): seq[string] =
  ## Runs ONE decision turn and installs every seat's orders. Returns the
  ## replay chat records this turn produced. NEVER raises: every failure path
  ## ends in a legal order set.
  let budget = initDuration(milliseconds = max(1, sim.config.turnBudgetMs))
  ## Throttle state is PER TURN: a 429 on turn k says nothing about turn k+1.
  engine.client.throttled = false

  # --- budget guard: settle EARLY rather than overrun ----------------------
  if not engine.llmOff:
    let turnSeconds = (sim.config.turnBudgetMs + 999) div 1000
    if elapsedSeconds + 2 * turnSeconds > sim.config.wallClockBudgetSeconds:
      engine.llmOff = true
      result.add(budgetGuardRecord(
        turnIndex, max(0, sim.config.wallClockBudgetSeconds - elapsedSeconds)))
      echo "signals: budget guard fired at turn ", turnIndex,
        "; remaining turns play scripted"

  # --- which seats need a call? -------------------------------------------
  var open: seq[int]
  for slot in 0 ..< MaxSeats:
    if engine.seats[slot].isLlm and not engine.llmOff and
        not engine.client.disabled:
      open.add(slot)
    elif engine.seats[slot].isLlm:
      # An LLM seat that CANNOT call the LLM this turn is a FALLBACK, not a
      # scripted policy, and the design's `fallback.cause` enum names both
      # reasons it happens. Recording it is what makes the two countable.
      engine.installScripted(sim, slot, blGreedy, dsFallback)
      inc sim.fallbackTurns[slot]
      let cause = if engine.llmOff: "budget_guard" else: "no_credentials"
      result.add(fallbackRecord(turnIndex, slot, 1, cause,
        "the LLM is unavailable for this turn; playing greedy"))
      echo "signals llm: seat ", slot, " falling back to greedy (", cause,
        ") on turn ", turnIndex
    else:
      engine.installScripted(sim, slot, engine.seats[slot].baseline, dsScripted)

  # --- the rolling 60 s rate guard ----------------------------------------
  # `turnSpacingMs` pins the steady state at 20 req/min, but a turn in which
  # every seat retries issues 8 requests. If issuing the next batch would push
  # the trailing-60 s count above RateGuardMaxRequests, the seats that would
  # exceed it skip the call and take the `greedy` orders. Bounded, logged,
  # never a sleep on the episode's critical path.
  if open.len > 0:
    engine.pruneRateWindow(getMonoTime())
    let room = max(0, RateGuardMaxRequests - engine.requestStamps.len)
    if open.len > room:
      var allowed: seq[int]
      for i, slot in open:
        if i < room:
          allowed.add(slot)
        else:
          engine.installScripted(sim, slot, blGreedy, dsFallback)
          inc sim.fallbackTurns[slot]
          result.add(fallbackRecord(turnIndex, slot, 1, "rate_guard",
            "trailing-60s request budget reached; playing greedy"))
          echo "signals llm: seat ", slot,
            " falling back to greedy (rate_guard) on turn ", turnIndex
      open = allowed

  # --- the wall-clock floor between batch STARTS ---------------------------
  if open.len > 0 and engine.batchStarted and sim.config.turnSpacingMs > 0:
    let since = (getMonoTime() - engine.lastBatchStart).inMilliseconds.int
    if since < sim.config.turnSpacingMs:
      sleep(min(sim.config.turnSpacingMs, sim.config.turnSpacingMs - since))
  if open.len > 0:
    engine.lastBatchStart = getMonoTime()
    engine.batchStarted = true

  ## The per-turn budget bounds the CALLS, so its clock starts HERE, after the
  ## spacing sleep. Started at the top of the turn instead, a turn that waited
  ## ~9 s for spacing and then spent attempt 1's 9 s would be over budget
  ## before the retry batch could be issued, and the retry the checklist
  ## requires would be silently skipped. The turn is still bounded — spacing
  ## (<= turnSpacingMs) then calls (<= turnBudgetMs) — and the note's
  ## `32 turns x max(spacing, budget)` holds, because the spacing sleep is a
  ## floor between batch STARTS and shrinks by exactly what the calls took.
  let callsStart = getMonoTime()

  # --- up to two PARALLEL batches -----------------------------------------
  var attempt = 0
  while open.len > 0 and attempt < 2:
    if engine.client.disabled:
      break
    if getMonoTime() - callsStart >= budget:
      for slot in open:
        result.add(fallbackRecord(
          turnIndex, slot, attempt + 1, "timeout",
          "per-turn budget exhausted before attempt " & $(attempt + 1)))
      break
    let deadlineMs =
      if attempt == 0: sim.config.attempt1Ms else: sim.config.retryMs
    var batch: RequestBatch
    for slot in open:
      var user = $sim.observationJson(slot, turnIndex)
      if attempt > 0:
        user.add("\n\nYour previous reply was not usable. Reply with ONLY " &
          "the JSON object described above, starting with '{'.")
      let request = engine.client.requestFor(
        SystemPrompt, userMessage(engine.seats[slot].prompt, user))
      batch.post(request.url, request.headers, request.body, $slot)
    let started = getMonoTime()
    for i in 0 ..< open.len:
      engine.requestStamps.add(started)
    ## curly hands the deadline to CURLOPT_TIMEOUT, whose granularity is WHOLE
    ## SECONDS, so this conversion FLOORS — and `sim_config` rejects a
    ## sub-second value, so the floor below is an identity: 9000 -> 9 s,
    ## 4000 -> 4 s, worst case 13 s inside the 14 s turnBudgetMs cap.
    let responses = engine.client.curl.makeRequests(
      batch, max(1, deadlineMs div 1000))
    let latency = (getMonoTime() - started).inMilliseconds.int
    var stillOpen: seq[int]
    for position, slot in open:
      var cause = "parse_error"
      try:
        let text = engine.client.textOf(
          responses[position].response, responses[position].error,
          batch[position].url)
        var owned: seq[int]
        for at in quadrantIntersections(slot):
          owned.add(at)
        var reply = parseControllerReply(
          extractJsonObject(text), owned, sim.previousOrders(slot),
          turnIndex, sim.config.turnTicks)
        reply.source = dsLlm
        reply.latencyMs = latency
        engine.replies[slot] = reply
        engine.haveReply[slot] = true
        sim.applyReply(slot, reply)
        inc sim.llmTurns[slot]
        result.add(boundedDirectiveRecord(
          reply, turnIndex, slot, sim.observationForReplay(slot, turnIndex)))
      except CatchableError as error:
        if responses[position].error.len > 0:
          cause = (if "timeout" in responses[position].error.toLowerAscii():
                     "timeout" else: "transport_error")
        elif error.msg.startsWith("llm throttled"):
          cause = "throttled"
        result.add(fallbackRecord(
          turnIndex, slot, attempt + 1, cause, error.msg))
        ## Attempt 1 says "will retry" — only a genuine SECOND failure may log
        ## "falling back" (the pommerman 0.1.1 phase-60 grep scar).
        echo "signals llm: seat ", slot, " attempt ", attempt + 1,
          " failed, will retry: ", error.msg
        stillOpen.add(slot)
    open = stillOpen
    inc attempt
    if engine.client.throttled and open.len > 0:
      # FAIL FAST. The only model left answered 429, so the retry batch would
      # be refused the same way.
      echo "signals llm: provider throttled with no other candidate; ",
        open.len, " seat(s) fall back for turn ", turnIndex
      break

  # --- anything still open plays greedy for this turn ----------------------
  for slot in open:
    engine.installScripted(sim, slot, blGreedy, dsFallback)
    inc sim.fallbackTurns[slot]
    let cause =
      if engine.client.disabled or engine.client.transport == ltNone:
        "no_credentials"
      elif engine.llmOff: "budget_guard"
      elif engine.client.throttled: "throttled"
      else: "parse_error"
    result.add(fallbackRecord(turnIndex, slot, 2, cause,
      "seat fell back to the greedy orders"))
    ## "falling back" is the phrase phase 60 greps the GAME log for.
    echo "signals llm: seat ", slot, " falling back to greedy (", cause,
      ") on turn ", turnIndex

  # --- the scripted seats' directive records ------------------------------
  for slot in 0 ..< MaxSeats:
    if engine.haveReply[slot] and engine.replies[slot].source != dsLlm:
      result.add(boundedDirectiveRecord(
        engine.replies[slot], turnIndex, slot, nil))
