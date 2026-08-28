# sumo-traffic-signals wire protocol — Sprite v1, plus what this game adds

Both the player endpoints (`/player`) and the global/spectator endpoint speak
[Sprite v1](https://github.com/Metta-AI/bitworld/blob/master/docs/sprite_v1.md).
This document lists everything this coworld adds or changes relative to that
base document; anything not mentioned here matches Sprite v1 exactly. Game
semantics — the rules, the phases, the scoring — live in [`RULES.md`](RULES.md),
and the policy contract lives in [`SIGNALS.md`](SIGNALS.md).

Forked from coworld-ctf's `docs/PROTOCOL.md`, retargeted: this game's seats
send no per-tick inputs at all, so most of the starter's input section is
replaced by a much shorter contract.

## The seat sends ONE message: its registration

A seat is a **registrar**, not a controller. It connects to
`/player?slot=<i>&token=<t>`, sends ONE Sprite v1 chat message (`0x81`) whose
text is a JSON object, and then only receives:

```json
{"type": "register",
 "prompt": "<PLAYER_PROMPT, or empty>",
 "policy": "<a free label for the replay's register record>",
 "scripted": "greedy" | "fixedcycle" | null}
```

* `prompt` is rune-truncated at **4000 runes**; `policy` at **64 runes**.
* `scripted` is JSON `null` when the seat is an LLM seat, so the server can
  tell "no baseline named" from "greedy named explicitly".
* A seat that sets neither field is `greedy`.

**Registration is RE-SENT, not sent once.** Joins are slot-sequential, so the
first registration can land while the seat has no index yet; the server HOLDS
an unappliable registration and re-reads it when the slot lands, and the
reference registrar keeps re-sending for the first ~10 s of received frames.
Registering twice is harmless — the server re-reads the same fields.

**Any other chat text from a seat is DROPPED.** Controllers speak through the
reply's `say` field, not through the wire's chat channel, and a registration
message is consumed as registration and never written to the replay chat
stream: the server writes a redacted `register` record instead, carrying the
policy label and kind but never the prompt.

## Every decision happens in the GAME server

`PLAYER_PROMPT` reaches the game through the registration message above, and
the game server makes the LLM call. That is not a stylistic choice: the
`anthropic_api_key` coworld secret is injected into the **game** pod
(`game.runnable.env.ANTHROPIC_API_KEY_URI`), and keeping the control layer
server-side is what makes the recorded order log reproducible with no network
in the loop. No `USE_BEDROCK` flag is needed on a policy, because the player
pod makes no LLM call.

The reply schema, the caps and the fallback ladder are in
[`SIGNALS.md`](SIGNALS.md).

## Player Ready (`0x85`) is supported and is safe here

The server understands the Sprite v1 Player Ready packet (`0x85`). Sending it
is legitimate for THIS game in a way it is not for an ordinary player client:
a seat sends **no inputs at all** (the server computes every phase), so the
dead-reckoning hazard the starter's protocol document warns about cannot arise.
Every shipped variant runs `fastMode: true`.

## Player input bits are unused

This game assigns no meaning to any player-input bit. A seat that sends a
`0x84` Player Input packet is ignored; nothing it can send changes the
simulation. The whole input log of an episode is the per-turn ORDER records
(see `RULES.md` § The replay).

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
