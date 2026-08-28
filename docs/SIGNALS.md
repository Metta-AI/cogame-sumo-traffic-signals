# Controlling the signals

A policy is just a prompt. Set `PLAYER_PROMPT` on this image and your text
becomes the operator guidance a controller weighs when it decides what its four
signals do next.

```bash
coworld upload-policy coworld-sumo-traffic-signals:latest \
  --name my-signals \
  --run /bin/sumo-traffic-signals-player \
  --secret-env PLAYER_PROMPT="Run row C as an eastbound wave and never open a green into a full block."
```

Set `PLAYER_SCRIPTED=greedy` or `PLAYER_SCRIPTED=fixedcycle` instead and the
seat plays that scripted baseline. A seat that sets neither is `greedy`.

## What you see

Every eight simulated seconds your seat gets one JSON observation. The guiding
line is **detectors are public; plans are private** — a real traffic-management
centre sees every loop detector in the city and every signal's current state,
and does not see another operator's intended offsets.

```json
{
  "you": "Gamma",
  "controllers": ["Alpha", "Beta", "Gamma", "Delta"],
  "your_quadrant": "SW",
  "turn": 9, "of": 32, "tick": 64, "turn_ticks": 8, "ticks_left": 192,
  "city": {"rows": ["A","B","C","D"], "cols": [1,2,3,4],
           "quadrants": {"Alpha": ["A1","A2","B1","B2"], "...": []},
           "link_cells": {"ew": 6, "ns": 4, "ew_gate": 4, "ns_gate": 3},
           "phases": {"NSG": "N,S through+right", "NSL": "N,S left",
                      "EWG": "E,W through+right", "EWL": "E,W left"},
           "min_green": 4, "clearance": 2, "max_red": 60,
           "demand_ends_tick": 208, "par": 260},
  "your_signals": [
    {"at": "C2", "phase": "EWG", "ticks_in_phase": 6,
     "order": "wave EWG +3", "order_age_turns": 2, "last_order_result": "ran",
     "approaches": [
       {"from": "E", "queue": 6, "link_full": true, "stop_line": "left",
        "blocked_ticks": 14, "cause": "phase"}],
     "exits": [
       {"to": "C3", "owner": "Delta", "occupancy": 6, "capacity": 6, "full": true}],
     "inbound": [{"from": "W", "cars": 3, "nearest_ticks": 2}]}
  ],
  "detectors": [
    {"at": "A1", "by": "Alpha", "phase": "NSG", "ticks_in_phase": 3,
     "q": {"N": 2, "E": 0, "S": 5, "W": 1}}
  ],
  "radio": [{"from": "Alpha", "text": "B2 goes EWG at tick 66"}],
  "network_status": {"throughput": 96, "demand": 141, "rejected": 2,
                     "wait_ticks": 3120, "your_wait_ticks": 861,
                     "spillback": ["C2>C3"], "gridlock": [], "waves": 3},
  "your_notes": "C1 offset +2 behind C2 for the eastbound wave"
}
```

`detectors` is always 16 entries and `your_signals` always 4, both ascending by
intersection index, so the array shape never changes. `phase` is one of
`NSG|NSL|EWG|EWL|CLR`; `stop_line` one of `through|left|right|null`; `cause` one
of `phase|spillback|null`; `last_order_result` one of
`ran|deferred|overridden|repaired|unknown` — the driver's honest report of what
actually happened to your previous order, which is what lets you notice that
your offsets are being eaten by `minGreenTicks` or by a starvation override.

**Hidden:** every other seat's orders, offsets, notes and intentions; every
other seat's real player name, policy name and kind; future demand; other
seats' fallback statistics; and any other seat's `seatWaitTicks`.

## What you say

```json
{"orders": [{"at": "C2", "verb": "wave", "phase": "EWG", "delay": 3},
            {"at": "C1", "verb": "phase", "phase": "EWG"},
            {"at": "D1", "verb": "hold"},
            {"at": "D2", "verb": "auto"}],
 "say": "eastbound wave on row C: C1 at +0, C2 at +3, Delta take C3 at +6",
 "notes": "if C2>C3 is still full next turn, gate C1 with hold"}
```

| Field | Cap / domain |
| --- | --- |
| `orders` | ≤ 4 entries. Absent or empty = "every signal keeps its order", and the reply is still USABLE |
| `orders[].at` | one of YOUR four intersection ids, upper-cased before matching, at most once |
| `orders[].verb` | `hold` \| `phase` \| `wave` \| `auto`, lower-cased before matching |
| `orders[].phase` | required iff verb ∈ {phase, wave}; `NSG` \| `NSL` \| `EWG` \| `EWL`. `CLR` is not selectable |
| `orders[].delay` | required iff verb == `wave`; clamped to 0 … 6 |
| `say` | ≤ 120 runes — the control-room radio, heard by EVERY seat next turn |
| `notes` | ≤ 240 runes — private, echoed back to you only |
| whole reply | ≤ 4096 bytes read from the provider before parsing |

An order whose required argument is missing or unknown is **repaired to that
intersection's previous order**, counted in `results.ordersRejected`, and
reported back next turn as `last_order_result: "repaired"`. Orders naming an
intersection you do not own are dropped and counted. Every string that lands in
the replay is truncated on **RUNE** boundaries.

## What the orders do

| Order | Requested phase, per tick `k` of the turn | Finishes with |
| --- | --- | --- |
| `hold` | the current phase | `ran` |
| `phase P` | `P`, from `k = 0` | `ran`, or `deferred` while `minGreenTicks` blocks it |
| `wave P d` | the current phase for `k < d`, then `P` | `ran` |
| `auto` | `argmax_P served(P)`, recomputed every tick | `ran` |

```
served(P) = sum over approaches a greened by P of
              (if a's stop-line car exists and P permits its movement:
                 min(queueLen(a), greenCap = 6)
               else 0)
```

`served` counts the whole queue behind a MOVABLE head car, because that is the
queue the green will actually discharge, and counts ZERO behind a head car the
phase cannot move — which is what makes a blocked left-turner visible to the
actuator instead of invisible. `auto` switches only when the best phase beats
the current one by `switchMargin = 2`, ties broken by keeping the current phase.

`minGreenTicks`, the clearance and the starvation override are enforced by the
signal machine, never by the driver: **no order can produce an illegal signal
state.**

## Green waves are built with `delay`

A car covers one cell per tick, an east-west block is 6 cells and a north-south
block 4. So if `C1` turns `EWG` at tick `t`, its platoon reaches `C2` about six
ticks later and `C3` about twelve. Give `C2` `wave EWG delay 6` and the platoon
never stops. **Two of the four intersections on any avenue belong to somebody
else**, so say your offsets out loud: `say` is the only channel between
controllers.

## The cadence, and what happens when a call is missed

One turn every 8 ticks, 32 turns per episode. All four seats' calls go out as
ONE parallel batch per turn — attempt 1 gets 9 s, a single retry gets 4 s, and
the whole turn is wrapped in a 14 s monotonic deadline. Consecutive batch
STARTS are held 12 s apart, and a rolling 60 s request counter keeps the episode
under the sidecar's 30 req/min cap.

On a second failure the seat plays the **`greedy`** orders — the same proc the
`greedy` baseline uses — and a `fallback` record names the cause
(`timeout`, `parse_error`, `transport_error`, `no_credentials`, `rate_guard`,
`budget_guard`, `throttled`, `disconnected`). Attempt 1 logs *will retry*; only
a genuine second failure logs *falling back*.

No failure mode leaves a signal without a phase: the driver always has an order
— this turn's, else last turn's, else `greedy`'s — and absent everything the
signal holds its current phase, which is a legal state.

## The two baselines

**`greedy`** is the standard longest-queue actuated controller, and the
server-side fallback: hold when the current phase is within `switchMargin` of
the best, else switch to the best. It **never** looks at an exit link's
occupancy, so it discharges into full links and exports congestion downstream —
the behaviour local greed produces, shipped as the thing to beat.

**`fixedcycle`** is the classic fixed-time plan: one phase per turn from
`[NSG, EWG, NSL, EWL]`, identical at all four of its intersections and
therefore with **zero** offset between them. It is the control that answers
"did the LLM actually coordinate?".

Neither ever emits `say` or `notes` — they are the controllers who will not talk
to you, which is precisely the coordination problem this game is about.
