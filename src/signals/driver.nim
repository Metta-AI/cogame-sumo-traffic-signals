## The driver: the deterministic per-tick actuator. Forked from the starter's
## `src/ctf/control.nim` (directive -> per-tick actuation), retargeted from
## pixel steering to a REQUESTED PHASE per intersection per tick.
##
## It is the ONLY producer of phase requests and it contains no randomness.
## `minGreenTicks`, `clearTicks` and the starvation override are enforced by
## the signal machine in `phases.nim`, never here: no order can produce an
## illegal signal state.

import
  sim_types, city, sim_state, vehicles, flow

proc stopLineMovement*(sim: SimServer, intersection: int, approach: Approach): Movement =
  ## The movement class of the car at one approach's stop line, or `mvNone`
  ## when there is no car there.
  let link = sim.city.inbound[intersection][ord(approach)]
  if link < 0:
    return mvNone
  let car = sim.stopLineCar(link)
  if car < 0:
    return mvNone
  sim.movementOf(car)

proc served*(sim: SimServer, intersection: int, phase: PhaseId): int =
  ## `served(P)` — used by `auto` and by the `greedy` baseline, ONE
  ## implementation, imported by both, so they cannot drift.
  ##
  ## It counts the whole queue behind a MOVABLE head car, because that is the
  ## queue the green will actually discharge, and counts ZERO behind a head
  ## car the phase cannot move — which is what makes a blocked left-turner
  ## visible to the actuator instead of invisible.
  if phase == phCLR:
    return 0
  for approach in phaseGreens(phase):
    let movement = sim.stopLineMovement(intersection, approach)
    if movement == mvNone:
      continue
    if not phasePermits(phase, approach, movement):
      continue
    result += min(
      sim.approachQueue(intersection, approach), sim.config.greenCap)

proc bestPhase*(sim: SimServer, intersection: int): PhaseId =
  ## `argmax_P served(P)`, ties broken by the lowest phase index.
  result = phNSG
  var best = -1
  for phase in SelectablePhases:
    let value = sim.served(intersection, phase)
    if value > best:
      best = value
      result = phase

proc autoPhase*(sim: SimServer, intersection: int): PhaseId =
  ## The `auto` verb, recomputed every tick: switch only if the best phase
  ## beats the current one by `switchMargin`, ties broken by KEEPING the
  ## current phase, then by the lowest phase index.
  let
    current = sim.signals[intersection].phase
    best = sim.bestPhase(intersection)
  if best == current:
    return current
  if sim.served(intersection, best) >=
      sim.served(intersection, current) + sim.config.switchMargin:
    best
  else:
    current

proc requestedPhase*(sim: SimServer, intersection, tickInTurn: int): PhaseId =
  ## Tick step 2a: this tick's requested phase, from the intersection's
  ## current standing order.
  ##
  ##   hold        the current phase
  ##   phase P     P, from k = 0
  ##   wave P d    the current phase for k < d, then P
  ##   auto        argmax_P served(P), recomputed every tick
  let
    signal = sim.signals[intersection]
    order = signal.order
  case order.verb
  of ovHold:
    signal.phase
  of ovPhase:
    order.phase
  of ovWave:
    if tickInTurn < order.delay: signal.phase else: order.phase
  of ovAuto:
    sim.autoPhase(intersection)

proc greedyOrderFor*(sim: SimServer, intersection: int): SignalOrder =
  ## The `greedy` order for one intersection — the standard longest-queue
  ## actuated controller, and the SERVER-SIDE FALLBACK. First matching rule
  ## wins:
  ##   1. `served(current) >= max_P served(P) - switchMargin` -> hold
  ##   2. else -> phase argmax_P served(P)
  ## It never looks at an exit link's occupancy, so it discharges into full
  ## links and exports congestion downstream — the behaviour the idea says
  ## local greed produces, shipped as the thing to beat. It never uses `wave`,
  ## so it can never build an offset.
  ## ONE implementation, shared with `auto`: `autoPhase` already encodes the
  ## switch rule (change only when the best phase beats the current one by
  ## `switchMargin`, ties broken by keeping the current phase), so `greedy` is
  ## that decision expressed as an order. `tests/test_signals_driver.nim`
  ## asserts the two can never drift.
  let
    current = sim.signals[intersection].phase
    wanted = sim.autoPhase(intersection)
  if wanted == current:
    SignalOrder(verb: ovHold, phase: current, delay: 0,
                turn: sim.turn, outcome: orUnknown)
  else:
    SignalOrder(verb: ovPhase, phase: wanted, delay: 0,
                turn: sim.turn, outcome: orUnknown)

proc fixedCycleOrderFor*(sim: SimServer, intersection: int): SignalOrder =
  ## The `fixedcycle` order: the classic fixed-time plan, no sensing, no
  ## coordination. One phase per turn from `[NSG, EWG, NSL, EWL]`, identical
  ## at all four of the seat's intersections and therefore with ZERO offset
  ## between them.
  const PhaseCycle = [phNSG, phEWG, phNSL, phEWL]
  SignalOrder(
    verb: ovPhase,
    phase: PhaseCycle[max(0, sim.turn - 1) mod PhaseCycle.len],
    delay: 0,
    turn: sim.turn,
    outcome: orUnknown
  )
