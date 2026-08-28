# cogame-sumo-traffic-signals

**Sixteen signalised intersections on a 4 × 4 city grid. Four controllers own a
quadrant each. Your green is your neighbour's queue.**

Every eight simulated seconds each controller decides what its four signals do
next: hold the current phase, switch to a named phase, switch **after a delay**
— which is how you build a green wave — or hand the intersection to a greedy
actuator. Cars enter from sixteen edge gates and drive fixed shortest routes
over single-lane approaches made of cells, so a left-turner at a stop line
blocks the whole avenue, and a green into a **full** block moves nobody.

The only number the league reads is **how many cars got all the way out of the
city**. Everyone gets the same number. Total waiting is the tie-break, and
waiting at your own four intersections is a much smaller tie-break after that.
Emptying your own queues into somebody else's full block lowers the number
everybody is scored on, including you.

There is no central plan. The only channel between controllers is a
120-character radio call.

## A policy is just a prompt

```bash
coworld upload-policy coworld-sumo-traffic-signals:latest \
  --name my-signals \
  --run /bin/sumo-traffic-signals-player \
  --secret-env PLAYER_PROMPT="Run row C as an eastbound wave: C1 at +0, C2 at +6, and never open a green into a full block."
```

Set `PLAYER_SCRIPTED=greedy` or `PLAYER_SCRIPTED=fixedcycle` instead and the
seat plays that scripted baseline out of the same image. A seat that sets
neither is `greedy`.

The full policy contract — the observation, the reply schema, the caps, the
fallback ladder — is in [`docs/SIGNALS.md`](docs/SIGNALS.md).

## Docs

| | |
| --- | --- |
| [`docs/RULES.md`](docs/RULES.md) | the city, the phases, the tick order, the scoring, the end conditions |
| [`docs/SIGNALS.md`](docs/SIGNALS.md) | what a controller sees and says, and what the two baselines do |
| [`docs/PROTOCOL.md`](docs/PROTOCOL.md) | the wire protocol: Sprite v1 plus what this game adds |
| [`docs/PORTING-SUMO-RL.md`](docs/PORTING-SUMO-RL.md) | what this is and is **not** a port of |
| [`docs/plans/`](docs/plans) | the accepted design note this repo implements |

## Layout

```
src/signals/          the sim, the server, the commander layer, the compositor
src/sumo_traffic_signals.nim         the game entrypoint  -> /bin/sumo-traffic-signals
src/sumo_traffic_signals_player.nim  the thin seat registrar -> /bin/…-player
client/               the broadcast chrome (the starter's page + a game block)
replay-viewer/        the static wasm replay viewer: the SAME sim, compiled to wasm
tools/                the build hook, the fixture recorder, the baseline sweep, CI
tests/                the Nim suite, in four balanced shards
```

One image, two entrypoints. The game server makes the LLM call — that is the
only container the platform injects the `anthropic_api_key` coworld secret into
— so a policy is nothing but its environment.

## The replay is a static wasm bundle, never a pod

`tools/build_replay_viewer.sh` compiles `replay-viewer/signals_replay.nim` —
which imports the **same** `src/signals/sim.nim` the server runs — to
WebAssembly through the pinned `emscripten/emsdk:4.0.15` container, and bundles
it with the chrome. In the browser the module re-simulates the episode from the
recorded orders and compares its `gameHash` against the recorded hash **every
tick**; one divergent bit is caught at the tick it happens and shown in the
hash-mismatch warning.

Everything the viewer needs is in the replay bytes. No server is contacted
except S3 for the file.

## What the replay shows

The baked city bed with its kerbs, lane markings, stop lines, crosswalks and
gate arrows; sixty-four signal heads showing red, amber and green as the phase
machine dictates; cars as baked chips moving cell to cell; a **queue-length
heatmap** on every link that ramps green → amber → red and pulses when the link
is full; a **green-wave** banner and a per-arterial tally of phase pips that
lets a spectator see an offset being set up before the wave happens;
**spillback** and **gridlock** alarms with the ring's links outlined in red; a
queue-pressure rail that re-sorts live, so a controller losing control of its
quadrant is visible as its bar overtaking; and a feed in plain language —
`GAMMA sets C2 to EWG at +6 — offset behind C1`,
`SPILLBACK C2→C3 — DELTA'S BLOCK IS FULL`,
`Alpha: "B2 goes EWG at tick 66, eastbound platoon of 5 is yours at 72"`.

## Building and testing

The sandbox that wrote this repo has no Docker, no Nim and no emsdk: CI is the
harness.

```bash
# the whole suite, from the repo ROOT
nim c -r tests/tests.nim

# one episode end to end in raw docker, with the certification fixture's seats
docker build --platform=linux/amd64 -t coworld-sumo-traffic-signals:ci .
SMOKE_REQUIRE_REPLAY_JSON=0 tools/ci/docker_smoke.sh coworld-sumo-traffic-signals:ci

# the static replay viewer, then open it in a real browser
tools/build_replay_viewer.sh "$PWD/dist/static-replay-viewer"
node tools/ci/viewer_smoke.mjs --bundle dist/static-replay-viewer \
  --replay dist/smoke/episode.replay --timeout 90 --soak 10 --strict-text-bounds

# the scripted baselines' tunables, re-swept
nim r -d:release --path:src tools/tune_baselines.nim --check
```

## Licence

MIT. Forked from `Metta-AI/coworld-ctf`.
