## The roster: join/auth, the two name spaces, and the results document.
## Forked from the starter's `src/ctf/roster.nim` with the two named edits of
## design §The two named edits to `roster.nim`:
##
##   1. `seatAlias(slot)` returns `IdentityNames[slot]` title-cased — Alpha,
##      Beta, Gamma, Delta. The `IdentityNames` array itself is unchanged and
##      lives in `sim_types`. Board labels inherit the two-name-space rule
##      with no further change, and `showPlayerLabels` is false.
##   2. `squadResultsJson` -> `cityResultsJson`: one entry per seat, four
##      entries in every seat-indexed array, keys exactly as design §Server
##      lists them.
##
## TWO NAME SPACES. `alias` is the in-game name and the only one that may
## appear in an observation, a prompt, an order, a `say`, a radio line or a
## board label. `name` is the REAL policy/player name and appears only in
## `results.names`, in the replay's join records, and spectator-side in the
## viewer's scorebug plates, pressure rail and endcard.

import
  std/[json, strutils],
  sim

proc seatForToken*(sim: SimServer, slot: int, token: string): bool =
  ## The player websocket handler CLOSES unless the token matches the seat —
  ## the certifier probes with a bad token (cogame-flatland 0.1.1).
  if slot < 0 or slot >= MaxSeats:
    return false
  let expected = sim.players[slot].token
  if expected.len == 0:
    return true                        ## no tokens configured: local dev.
  expected == token

proc nextOpenSlot*(sim: SimServer): int =
  ## Joins are slot-sequential, as in the starter, so a seat whose slot is not
  ## the next open one is not admitted until the lower slots have joined.
  for slot in 0 ..< MaxSeats:
    if not sim.players[slot].joined:
      return slot
  -1

proc joinSeat*(
  sim: var SimServer, slot: int, name: string
): bool =
  if slot < 0 or slot >= MaxSeats or sim.players[slot].joined:
    return false
  sim.players[slot].joined = true
  sim.players[slot].left = false
  if name.len > 0:
    sim.players[slot].name = name.truncateRunes(MaxPolicyLabelRunes)
  true

proc leaveSeat*(sim: var SimServer, slot: int) =
  if slot >= 0 and slot < MaxSeats:
    sim.players[slot].left = true

proc registerSeat*(
  sim: var SimServer, slot: int, policy, kind, baseline: string
) =
  ## The REDACTED registration. The seat's prompt is NEVER stored here: only
  ## the policy label, the kind, and which baseline a scripted seat picked.
  if slot < 0 or slot >= MaxSeats:
    return
  sim.players[slot].registered = true
  sim.players[slot].policy = policy.truncateRunes(MaxPolicyLabelRunes)
  sim.players[slot].kind = kind
  sim.players[slot].baseline = baseline
  sim.policyKinds[slot] = kind

proc allSeatsRegistered*(sim: SimServer): bool =
  ## The server LOGS LOUDLY and refuses to start the game when a joined seat
  ## has no register record (the grf-football 2026-08-27 silent-default scar).
  for slot in 0 ..< MaxSeats:
    if sim.players[slot].joined and not sim.players[slot].registered:
      return false
  true

proc unregisteredSeats*(sim: SimServer): seq[int] =
  for slot in 0 ..< MaxSeats:
    if sim.players[slot].joined and not sim.players[slot].registered:
      result.add(slot)

proc rosterJson*(sim: SimServer): JsonNode =
  ## The spectator roster. `name` is the real policy name and rides the
  ## SPECTATOR stream only; nothing drawn on the board uses it, because
  ## `showPlayerLabels` is false.
  result = newJArray()
  for slot in 0 ..< MaxSeats:
    var ids = newJArray()
    for at in quadrantIntersections(slot):
      ids.add(%intersectionName(at))
    result.add(%*{
      "s": slot,
      "name": sim.players[slot].name,
      "alias": sim.players[slot].alias,
      "team": seatColour(slot),
      "quad": sim.players[slot].quadrant,
      "pol": sim.players[slot].policy,
      "kind": sim.players[slot].kind,
      "signals": ids,
      "served": sim.served[slot],
      "wait": sim.seatWaitTicks[slot],
      "changes": sim.phaseChanges[slot],
      "fb": sim.fallbackTurns[slot],
      "dead": sim.deadSeats[slot]
    })

proc cityResultsJson*(sim: SimServer): string =
  ## The CLOSED results document. Adding a key means updating this proc, the
  ## manifest's `results_schema` and `tools/ci/docker_smoke.sh`'s expected-key
  ## set in the same commit — Coworld schemas are closed and undeclared keys
  ## are dropped.
  ##
  ## Two identities hold in every document and are asserted by
  ## `tests/test_signals_engine.nim`: `sum(seatWaitTicks) == networkWaitTicks`,
  ## and `throughput + rejected == demandGenerated` whenever
  ## `endRule == "cleared"`.
  var
    names = newJArray()
    aliases = newJArray()
    quadrants = newJArray()
    scores = newJArray()
    win = newJArray()
    seatWait = newJArray()
    seatWaitKs = newJArray()
    served = newJArray()
    phaseChanges = newJArray()
    kinds = newJArray()
    llmTurns = newJArray()
    fallbackTurns = newJArray()
    ordersRejected = newJArray()
    deadSeats = newJArray()
  var
    hasLlm = false
    hasScripted = false
  for slot in 0 ..< MaxSeats:
    names.add(%sim.players[slot].name)
    aliases.add(%sim.players[slot].alias)
    quadrants.add(%sim.players[slot].quadrant)
    scores.add(%sim.scoreOf(slot))
    win.add(%sim.winFor())
    seatWait.add(%sim.seatWaitTicks[slot])
    seatWaitKs.add(%sim.seatWaitK(slot))
    served.add(%sim.served[slot])
    phaseChanges.add(%sim.phaseChanges[slot])
    kinds.add(%sim.policyKinds[slot])
    llmTurns.add(%sim.llmTurns[slot])
    fallbackTurns.add(%sim.fallbackTurns[slot])
    ordersRejected.add(%sim.ordersRejected[slot])
    deadSeats.add(%sim.deadSeats[slot])
    if sim.policyKinds[slot] == "llm": hasLlm = true
    else: hasScripted = true
  $(%*{
    "names": names,
    "aliases": aliases,
    "quadrants": quadrants,
    "scores": scores,
    "win": win,
    "winner": newJNull(),
    "reason": $sim.endReason,
    "endRule": $sim.endRule,
    "throughput": sim.throughput,
    "parThroughput": sim.config.parThroughput,
    "demandGenerated": sim.demandGenerated,
    "rejected": sim.rejected,
    "networkWaitTicks": sim.networkWaitTicks,
    "seatWaitTicks": seatWait,
    "netWaitK": sim.netWaitK(),
    "seatWaitK": seatWaitKs,
    "served": served,
    "travelTicksTotal": sim.travelTicksTotal,
    "stopsTotal": sim.stopsTotal,
    "greenWaves": sim.greenWaves,
    "spillbacks": sim.spillbacks,
    "spillbackTicks": sim.spillbackTicks,
    "gridlocks": sim.gridlocks,
    "gridlockTicks": sim.gridlockTicks,
    "longestGridlockTicks": sim.longestGridlockTicks,
    "starvations": sim.starvations,
    "deferredSwitches": sim.deferredSwitches,
    "phaseChanges": phaseChanges,
    "finalTick": sim.finalTick,
    "turnsPlayed": sim.turnsPlayed,
    "seed": sim.config.seed,
    "variant": sim.config.variant,
    "policyKinds": kinds,
    "crossPlay": hasLlm and hasScripted,
    "llmTurns": llmTurns,
    "fallbackTurns": fallbackTurns,
    "ordersRejected": ordersRejected,
    "deadSeats": deadSeats,
    "stopDetail": sim.stopDetail.truncateRunes(MaxStopDetailRunes)
  })

const ResultsKeys*: array[38, string] = [
  "names", "aliases", "quadrants", "scores", "win", "winner", "reason",
  "endRule", "throughput", "parThroughput", "demandGenerated", "rejected",
  "networkWaitTicks", "seatWaitTicks", "netWaitK", "seatWaitK", "served",
  "travelTicksTotal", "stopsTotal", "greenWaves", "spillbacks",
  "spillbackTicks", "gridlocks", "gridlockTicks", "longestGridlockTicks",
  "starvations", "deferredSwitches", "phaseChanges", "finalTick",
  "turnsPlayed", "seed", "variant", "policyKinds", "crossPlay", "llmTurns",
  "fallbackTurns", "ordersRejected", "deadSeats"
]
  ## The closed key set, in document order. `tests/test_signals_engine.nim`
  ## asserts the emitted document's key set equals the manifest's
  ## `results_schema` key set EXACTLY; `stopDetail` closes the list below.

const ResultsKeyCount* = ResultsKeys.len + 1  ## + stopDetail

proc resultsKeySet*(): seq[string] =
  for key in ResultsKeys:
    result.add(key)
  result.add("stopDetail")

proc identityLine*(sim: SimServer): string =
  ## The startup log line that makes the two name spaces auditable.
  var parts: seq[string]
  for slot in 0 ..< MaxSeats:
    parts.add(seatAlias(slot) & " (" & seatQuadrant(slot) & ") = " &
      sim.players[slot].name & " [" & sim.players[slot].kind & "]")
  parts.join(", ")
