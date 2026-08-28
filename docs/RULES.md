# Rules

Sixteen signalised intersections on a 4 × 4 city grid. Four controllers own a
quadrant each. The only number the league reads is **how many cars got all the
way out of the city**.

## The city

* **Intersections** are named `<row><col>`: rows `A` (north) … `D` (south),
  columns `1` (west) … `4` (east). `A1` is the north-west corner. The
  intersection index — used by every "ascending index" tie-break below — is
  `rowIndex * 4 + colIndex`, so `A1 = 0` … `D4 = 15`.
* **Approaches** are named by the direction traffic arrives **from**: `N`, `E`,
  `S`, `W`. Every intersection has exactly four approaches and four exits.
* **Gates**, sixteen of them, each simultaneously a source and a sink:
  `nA1 nA2 nA3 nA4`, `sD1 sD2 sD3 sD4`, `wA1 wB1 wC1 wD1`, `eA4 eB4 eC4 eD4`.
* **Links** are one-way, single-lane, and made of **cells**. A cell holds at
  most one car. Link ids are `<from>><to>`, e.g. `C2>C3`, `nA1>A1`, `A1>nA1`.

  | Link | Cells |
  | --- | --- |
  | east–west between two intersections | 6 |
  | north–south between two intersections | 4 |
  | east/west gate link, either direction | 4 |
  | north/south gate link, either direction | 3 |

  80 directed links, 352 cells. East–west blocks are longer on purpose: the
  avenues are the green-wave corridors and the cross streets spill back fast.
* **Gate queues** hold 12 cars. A car generated when its gate queue is full is
  **rejected** — permanently lost demand, counted in `results.rejected`, never
  scored.
* The board is **34 × 26 cells** (aspect 1.308): an intersection box is 2 × 2
  cells and each street carries its two directions as two adjacent lanes.
* A car occupies one cell. Free-flow speed is **one cell per tick**.

## The quadrants

| Slot | Alias | Colour | Quadrant | Intersections |
| --- | --- | --- | --- | --- |
| 0 | Alpha | red | NW | `A1 A2 B1 B2` |
| 1 | Beta | blue | NE | `A3 A4 B3 B4` |
| 2 | Gamma | green | SW | `C1 C2 D1 D2` |
| 3 | Delta | yellow | SE | `C3 C4 D3 D4` |

Quadrants, not corridors, on purpose: **every one of the eight arterials is
jointly owned**, so a green wave along any avenue requires two controllers to
agree on an offset over the radio.

**Two name spaces.** In-game the seats are only ever `Alpha`, `Beta`, `Gamma`,
`Delta`. Their real policy names live in `results.names`, in the replay's join
records, and spectator-side in the viewer. `showPlayerLabels` is false, so
nothing drawn on the board can leak an identity.

## The clock

* **Tick** = one simulated second. **`maxTicks` = 256.**
* **Command turn** = one order round, every **8** ticks, beginning with turn 1
  at tick 0 before any stepping. **32 command turns per episode.**
* Demand runs to tick **208**; the last 48 ticks are the clear-down, and a
  network that clears them all ends the episode early.

## Signal phases

| Index | Id | Green approaches | Permitted movements |
| --- | --- | --- | --- |
| 0 | `NSG` | `N`, `S` | through, right |
| 1 | `NSL` | `N`, `S` | left |
| 2 | `EWG` | `E`, `W` | through, right |
| 3 | `EWL` | `E`, `W` | left |

Plus the non-selectable `CLR` — the all-red clearance, **2 ticks on every phase
change**, during which no approach discharges. **`minGreenTicks` = 4**: a phase
must have run four ticks before a change executes; a change requested earlier
is **deferred**, not dropped. **`maxRedTicks` = 60** is the safety valve: a
stop-line car whose movement has been forbidden for 60 consecutive ticks forces
the phase that serves it.

Approaches are single-lane, so a car whose movement the current phase forbids
**blocks every car behind it** — a left-turner at the head of the `E` approach
under `EWG` stops the whole avenue. That is the mechanic that makes phase
CHOICE, not just phase length, matter.

## The tick, in order

Nothing else mutates the world during play.

1. `tick += 1`.
2. **Signal machine**, each intersection in ascending index: `ticksInPhase += 1`;
   ask the driver for the requested phase; serve the clearance; enter a
   clearance when a change clears `minGreenTicks`; otherwise DEFER the change
   and count it; apply the **starvation override** when a stop-line car has
   been forbidden for `maxRedTicks`.
3. **Discharge at stop lines**, each intersection in ascending index, each
   approach in the fixed order `N, E, S, W`. At most ONE car per approach per
   tick, so at most two cars cross an intersection per tick. A car whose
   movement the phase forbids takes `blockedByPhaseTicks`; a car whose
   receiving link's entry cell is occupied takes `spillbackBlockedTicks` and
   **does not move, even on green**.
4. **Link advance**, ascending link index, downstream-first, so a whole queue
   steps forward the tick its head discharges.
5. **Exits.** Every tick, so an exit link's last cell is always vacated and a
   sink never becomes the bottleneck.
6. **Gate entries**, ascending gate index.
7. **Demand generation** — a pure hash of `(seed, gate, tick)`.
8. **Wait accounting.** Every car that did not change cell takes exactly one
   wait tick, charged to the signal keeping it waiting.
9. **Queue and spillback measurement.**
10. **Gridlock ring detection.**
11. **Green-wave detection.**
12. Mix the tick into `gameHash`.
13. Evaluate the end conditions.

**Collisions cannot occur.** One car per cell and one discharge per approach
per tick turn every would-be conflict into a wait. The failure modes this game
shows are **spillback** and the **gridlock ring**.

## Scoring

```
netWaitK     = min(999, networkWaitTicks div 200)
seatWaitK[s] = min( 99, seatWaitTicks[s] div 800)

scores[s] = 1_000_000 * throughput
          -     1_000 * netWaitK
          -        10 * seatWaitK[s]
```

Higher is better, and both waiting terms only ever subtract. The ordering is
strictly lexicographic: one extra car through is worth 1 000 000 and the
largest possible total penalty is 999 990. The first two terms are IDENTICAL
for all four seats — pure common interest — and the third is deliberately an
epsilon. **The local temptation is in the DYNAMICS, not the arithmetic**: greedy
local flushing genuinely raises local throughput for a few turns before the
downstream link fills, and the punishment arrives later and network-wide.

`results.win[s]` is `throughput >= parThroughput` — the same boolean for all
four seats, a "did the city work" flag — and `results.winner` is always `null`,
because a cooperative episode has no winner.

**Measured but never scored:** `rejected`, `travelTicksTotal`, `stopsTotal`,
`greenWaves`, `spillbacks`, `gridlocks`, `starvations`, `deferredSwitches`,
`phaseChanges`. Green waves in particular are a MEANS, not a currency: paying
for waves would let a seat farm the metric on an empty corridor.

## End conditions

The episode ends at the first of:

* **cleared** — `tick >= 208` and no car anywhere. The city ran the whole peak
  and emptied.
* **gridlock stall** — 40 consecutive ticks in which no car exited and no car
  changed cell.
* **tick cap** — `tick == 256`.
* **wall-clock stop** — the engine's own 660 s guard.

`results.reason` is a closed enum of exactly `complete | deadline | fault`, and
`results.endRule` of exactly
`cleared | gridlock | fullPeriod | wallClock | fault`.

A seat that never connects, disconnects mid-episode, or fails every decision
**does not end the episode**: its four signals are driven by `greedy` and the
episode runs to its natural end with `deadSeats[s] = true`.

## The replay

The replay is the starter's binary `COWLDSIG` format, and it is
self-sufficient: the header carries the magic, the format version, the game
name and version and the RESOLVED config JSON; the record stream carries the
joins, the per-turn ORDER records (the only inputs this game has), the chat
records (`register` / `directive` / `orders` / `fallback` / `budget_guard` /
`stop` / `result`) and ONE `gameHash` per tick. The city topology is code,
compiled into both the binary and the wasm module, so the viewer reconstructs
the exact city and re-simulates every car from bytes it already has.

`tools/replay_summary.py` (Python 3 stdlib only) prints one strict-UTF-8 JSON
object for a `.replay` path, which is how a replay is inspected without Nim,
Docker or emsdk.
