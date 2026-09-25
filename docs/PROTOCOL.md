# sumo-traffic-signals wire protocol — Sprite v1, plus what this game adds

Both the player endpoints (`/player`) and the global/spectator endpoint speak
[Sprite v1](https://github.com/Metta-AI/bitworld/blob/master/docs/sprite_v1.md).
This document lists everything this coworld adds or changes relative to that
base document; anything not mentioned here matches Sprite v1 exactly. Game
semantics — the rules, the phases, the scoring — live in [`RULES.md`](RULES.md),
and the policy contract lives in [`SIGNALS.md`](SIGNALS.md).

Forked from coworld-ctf's `docs/PROTOCOL.md`, retargeted for a turn based
decision and action exchange.

## Registration

A seat connects to `/player?slot=<i>&token=<t>` and sends a Sprite v1 chat
message (`0x81`) whose text is a JSON object:

```json
{"type": "register",
 "protocol": "signals.player.v2",
 "kind": "scripted" | "prompt" | "jev",
 "policy": "<a free label for the replay's register record>",
 "scripted": "greedy" | "fixedcycle"}
```

`policy` is rune-truncated at **64 runes**. Prompts and model credentials stay
inside the player container. `scripted` names the player's baseline or fallback.

**Registration is RE-SENT, not sent once.** Joins are slot-sequential, so the
first registration can land while the seat has no index yet; the server HOLDS
an unappliable registration and re-reads it when the slot lands, and the
reference registrar keeps re-sending for the first ~10 s of received frames.
Registering twice is harmless — the server re-reads the same fields.

Registration is consumed without entering replay chat. The server records the
policy label and kind, never the prompt. Controllers speak through the action's
`say` field.

## Turn decisions

At each turn the game sends each seat one private websocket TextMessage:

```json
{"protocol":"signals.player.v2","type":"decision","turn":0,
 "deadline_ms":14000,"observation":{"slot":0}}
```

The player replies with a Sprite v1 chat message containing:

```json
{"protocol":"signals.player.v2","type":"action","turn":0,
 "action":{"orders":[],"say":"","notes":""},
 "source":"scripted","cause":"","latency_ms":0}
```

The game sends all four private views before applying any action. It validates
the replies, applies them together, and writes the resolved orders to replay.
`source` is `scripted`, `llm`, or `fallback`; model calls stay in the player.

The reply schema, the caps and the fallback ladder are in
[`SIGNALS.md`](SIGNALS.md).

## Player Ready (`0x85`)

The server understands the Sprite v1 Player Ready packet (`0x85`). Turns wait
for explicit actions; Ready only advances the ordinary sprite stream. Every
shipped variant runs `fastMode: true`.

## Player input bits are unused

This game assigns no meaning to `0x84` Player Input bits. Turn actions use the
chat message above. The replay stores per-turn ORDER records (see `RULES.md`).

## The routes

| Route | Method | Purpose |
| --- | --- | --- |
| `/healthz` | GET | liveness; answers for a bounded grace after the artifacts are written |
| `/player?slot=<i>&token=<t>` | WS | one seat. **Closes unless the token matches the seat.** |
| `/global` | WS | the spectator/replay board stream, Sprite v1 |
| `/client/player?slot=&token=` | GET | the certifier's browser probe. Served for real, token-checked, and it does NOT open the player socket. |
| `/client/global` | GET | the spectator page |
| `/client/replay` | GET | a LOCAL developer replay page. Never declared to the platform: the hosted replay is the static wasm bundle. |
| `/replay-data` | GET | the loaded replay's URI, in replay mode |

`Ping` is answered with `Pong` on every websocket, and nothing else is guarded:
a `kind != TextMessage` guard would drop the seat's BINARY registration frame.

Global broadcasts are fire-and-forget, so a slow viewer can never stall the
episode.

## The board stream

The spectator/replay stream is the sprite protocol's **map layer only**, at
`CellPx = 16` board pixels per city cell — a 34 × 26 cell city, so a
544 × 416 px board. Sprites are straight (non-premultiplied) RGBA, supersnappy
compressed, exactly as Sprite v1 specifies; the sim, the `gameHash` and every
number quoted in `RULES.md` stay in CELLS.

The broadcast chrome rides as the LABEL of sprite id **4090** (a 1 × 1 sprite
with no pixels), which `client/broadcast_core.js` hands to the page as text.
That is the starter's own seam and it is unchanged.

Viewer commands arrive as chat messages on `/global`:

| Command | Meaning |
| --- | --- |
| `s:<tick>` | seek to a tick |
| `t:0` / `t:1` | the page's `.tiny` density, so the board can drop car chevrons for 4 px dashes under 620 px |
| any other text | the starter's transport keymap, character by character (space, `,`, `.`, `[`, `]`, `r`, `e`, `l`, `k`, digits) |

## The Coworld contract

In: `COGAME_CONFIG_URI`, `HOST`/`PORT` (or `COGAME_HOST`/`COGAME_PORT`).
Out: `COGAME_RESULTS_URI`, `COGAME_SAVE_REPLAY_URI`,
`COGAME_PLAYER_FAILURE_URI`, `COGAME_EVENTS_URI`.
Replay mode: `COGAME_LOAD_REPLAY_URI` plus `/client/replay`.

`COGAME_PLAYER_FAILURE_URI` receives the platform's **closed** payload —
exactly `{"message", "failed_policy_index"}`, nothing else.
