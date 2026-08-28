# What this is and is not a port of

This coworld implements the **control problem** the SUMO-RL (Alegre) / CityFlow
/ RESCO benchmarks pose. It does not port them, and it does not claim
comparability with them. Every divergence is named here.

## 1. No SUMO, no CityFlow, no port

Decided as a scoping rail before design. SUMO is a C++ desktop simulator with
XML networks, its own RNG and its own car-following model; embedding it would
mean a pod-side simulator that cannot compile to WebAssembly, so the static
replay viewer — a non-optional platform pin — would be impossible.

**No upstream code is vendored, no upstream numbers are cited as reproduced,
and no benchmark score from this coworld is comparable to any published
result.** What is reproduced is the SHAPE of the problem: per-seat intersection
signal control, queue and waiting-time pressure, cooperative network-throughput
scoring, and green waves as an emergent phenomenon.

## 2. Vehicles are cellular, not car-following

One car per cell, one cell per tick, no acceleration, no headway model, no lane
changing, one lane per approach. This is the CityFlow-style discrete idiom
rather than SUMO's continuous Krauss model, and it is what makes the native ↔
wasm hash chain exact: the sim is integer-only end to end, so the game server
and the browser viewer re-derive the identical tick.

## 3. No start-up lost time and no yellow-interval discharge

Clearance is a flat 2 ticks of all-red. A queue steps forward the same tick its
head discharges, because the link advance iterates downstream-first. A real
signal loses one to two seconds of saturation flow at the start of every green;
this one does not.

## 4. The reward shape is a league score, not a per-intersection reward

SUMO-RL's per-intersection reward is `−queue` or `−waiting`. The league needs
ONE rankable per-seat integer, so:

* network **throughput** is the dominant term (1 000 000 a car),
* network **waiting** is second (1 000 per 200 wait-ticks),
* the seat's **own** waiting is third and deliberately an epsilon
  (10 per 800 wait-ticks).

All three underlying quantities are recorded in `results`
(`throughput`, `networkWaitTicks`, `seatWaitTicks`), so the SUMO-RL-style local
signal is still readable per seat.

## 5. One network: the 4 × 4 grid

Cologne, Ingolstadt and Manhattan are out of scope. They are OSM imports whose
geometry cannot be re-derived in the viewer from a variant name, whose
intersections have five and six approaches that the reply schema does not
express, and none of which is legible in a 360 px featured-match iframe.

## 6. Who chooses the phase changed, not what the phases are

Per-tick RL policies are replaced by four turn-level ORDERS under a
deterministic per-tick actuator — the source idea's own "phase choice every
5–10 s … suits LLM policies well". The four-phase NEMA-style plan, the minimum
green, the all-red clearance, the maximum red and the single-lane approaches are
the benchmark idiom, unchanged.

## 7. One game per episode

The starter's multi-game episode is not used: a cooperative game has no side to
swap.

## 8. Seat count and intersection count are fixed

`num_agents` is 4 in every variant and in the certification fixture, and the
city has 16 intersections. The source idea's "4–48 intersections" is answered at
16, inside the range. More seats is a wall-clock and sidecar-rate problem, not a
design one: four calls a turn at a 12 s batch floor is 20 requests a minute
against a 30/minute per-episode cap, and sixteen seats would be 80.

## Source

* <https://github.com/LucasAlegre/sumo-rl>
* CityFlow
* the RESCO benchmark
