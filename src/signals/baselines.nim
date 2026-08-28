## The scripted baselines. Both are shipped as league fillers and `greedy` is
## also the server-side fallback. Forked from the starter's
## `src/ctf/baselines.nim`, retargeted.
##
## Both emit the SAME order objects an LLM does, through the SAME validator,
## which is what makes the bounded-orders test meaningful. Neither ever emits
## `say` or `notes` — they are the controllers who will not talk to you, which
## is precisely the "coordination emerges" problem the idea names.

import
  std/[strutils],
  sim_types, sim_state, driver, directives

type
  Baseline* = enum
    blGreedy = "greedy"
    blFixedCycle = "fixedcycle"

proc parseBaseline*(text: string): Baseline =
  ## Anything unrecognised is the published default — the starter's rule.
  let key = text.strip().toLowerAscii()
  for baseline in Baseline:
    if $baseline == key:
      return baseline
  blGreedy

proc scriptedReply*(
  sim: SimServer, slot: int, kind: Baseline
): ControllerReply =
  ## One seat's whole scripted order set for this turn: one order per owned
  ## intersection, in ASCENDING intersection index.
  result.source = dsScripted
  result.say = ""
  result.notes = ""
  result.orders = @[]
  for at in quadrantIntersections(slot):
    let order =
      case kind
      of blGreedy: sim.greedyOrderFor(at)
      of blFixedCycle: sim.fixedCycleOrderFor(at)
    result.orders.add(ControllerOrder(
      at: at,
      verb: order.verb,
      phase: order.phase,
      delay: order.delay,
      fromReply: true,
      repaired: false
    ))

proc greedyReply*(sim: SimServer, slot: int): ControllerReply =
  ## THE fallback. The decision engine and the `greedy` baseline resolve to
  ## this one proc, so they cannot drift.
  sim.scriptedReply(slot, blGreedy)
