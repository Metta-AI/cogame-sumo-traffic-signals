## Deterministic player policy over the ordinary seat observation and action.

import std/json
import sim_types, directives

proc served(signal: JsonNode, phase: PhaseId, greenCap: int): int =
  for approach in signal["approaches"]:
    var incoming = apN
    for candidate in Approach:
      if $candidate == approach["from"].getStr():
        incoming = candidate
    var movement = mvNone
    for candidate in Movement:
      if $candidate == approach{"stop_line"}.getStr():
        movement = candidate
    if phasePermits(phase, incoming, movement):
      result += min(approach["queue"].getInt(), greenCap)

proc scriptedAction*(view: JsonNode, baseline: string): JsonNode =
  var orders = newJArray()
  let turn = view["turn"].getInt()
  for signal in view["your_signals"]:
    let at = signal["at"].getStr()
    if baseline == "fixedcycle":
      const Cycle = [phNSG, phEWG, phNSL, phEWL]
      orders.add(%*{"at": at, "verb": "phase",
        "phase": $Cycle[max(0, turn - 1) mod Cycle.len]})
      continue
    let current = parsePhase(signal["current_phase"].getStr()).phase
    var best = phNSG
    var bestValue = -1
    for phase in SelectablePhases:
      let value = served(signal, phase, view["green_cap"].getInt())
      if value > bestValue:
        best = phase
        bestValue = value
    if best != current and bestValue >=
        served(signal, current, view["green_cap"].getInt()) +
        view["switch_margin"].getInt():
      orders.add(%*{"at": at, "verb": "phase", "phase": $best})
    else:
      orders.add(%*{"at": at, "verb": "hold"})
  %*{"orders": orders, "say": "", "notes": ""}
