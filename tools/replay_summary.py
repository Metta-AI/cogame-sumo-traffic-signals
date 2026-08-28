#!/usr/bin/env python3
"""Summarise a sumo-traffic-signals `.replay` as one strict-UTF-8 JSON object.

Python 3 standard library only: no Nim, no Docker, no emsdk. This is the JSON
view of the binary `COWLDSIG` replay the static wasm viewer parses, and it is
what phase 60's definition-of-done check reads instead of `jq .` on the raw
bytes:

    curl -sSL "$replay_url" -o /tmp/ep.replay
    python3 tools/replay_summary.py /tmp/ep.replay > /tmp/ep.json
    jq -e . /tmp/ep.json >/dev/null                  # strict UTF-8 JSON: ok
    jq -r '.protocol, .results.reason, .results.throughput, .results.greenWaves' /tmp/ep.json
    jq -r '[.orders[]|select(.source=="llm")]|length, .fallbacks, (.radio|length)' /tmp/ep.json

The replay stays binary on purpose: a JSON replay would mean rewriting
replays.nim, replay_runtime.nim, static_replay_worker.js and
wasm_replay_smoke.cjs — the machinery this fork exists to reuse.

How it reads the file WITHOUT a decoder for the whole record stream:

* the header is ASCII up to the config JSON, so the config is recovered by
  BRACE-MATCHING from the first `{` (the technique the starter's AGENTS.md
  documents for prod forensics);
* the CONTROL records — `register`, `directive`, `orders`, `fallback`,
  `budget_guard`, `stop`, `result` — are UTF-8 JSON objects embedded verbatim
  in the chat records, so they are recovered the same way, by scanning the
  remaining bytes for balanced `{"k":...}` objects.

Nothing here needs the record framing, so it cannot drift when the framing
changes; it only needs the two things that are text.
"""

from __future__ import annotations

import json
import sys


def brace_match(data: bytes, start: int) -> tuple[dict | None, int]:
    """Decode one balanced ``{...}`` starting at ``start``.

    Returns ``(obj, end)`` where ``end`` is the index just past the object, or
    ``(None, start + 1)`` when the bytes there are not a decodable object.
    """
    depth = 0
    in_string = False
    escaped = False
    for i in range(start, len(data)):
        ch = data[i]
        if in_string:
            if escaped:
                escaped = False
            elif ch == 0x5C:      # backslash
                escaped = True
            elif ch == 0x22:      # quote
                in_string = False
            continue
        if ch == 0x22:
            in_string = True
        elif ch == 0x7B:          # {
            depth += 1
        elif ch == 0x7D:          # }
            depth -= 1
            if depth == 0:
                chunk = data[start:i + 1]
                try:
                    return json.loads(chunk.decode("utf-8")), i + 1
                except (UnicodeDecodeError, json.JSONDecodeError):
                    return None, start + 1
        elif depth == 0:
            # A stray byte before any brace: not the start of an object.
            return None, start + 1
    return None, len(data)


def summarise(path: str) -> dict:
    data = open(path, "rb").read()
    protocol = "signals/v1"
    game_version = ""
    game_name = ""
    # The header is length-prefixed, so it is READ, not scanned: magic(8) +
    # formatVersion(u16) + gameName + gameVersion, each string a u16 length
    # followed by its bytes. An earlier version of this scanned the bytes after
    # the game name for a run of ASCII digits and picked up the low byte of the
    # timestamp that follows, reporting gameVersion "18" for GV1.
    try:
        cursor = 8                                       # past the magic
        cursor += 2                                      # past formatVersion
        for _ in range(2):
            length = int.from_bytes(data[cursor:cursor + 2], "little")
            cursor += 2
            value = data[cursor:cursor + length].decode("utf-8")
            cursor += length
            if not game_name:
                game_name = value
            else:
                game_version = value
    except Exception:                                   # noqa: BLE001
        pass

    first = data.find(b"{")
    config: dict = {}
    cursor = 0
    if first >= 0:
        config, cursor = brace_match(data, first)
        config = config or {}

    directives: list[dict] = []
    orders: list[dict] = []
    radio: list[str] = []
    fallbacks = 0
    registers: list[dict] = []
    budget_guards = 0
    stop: dict = {}
    results: dict = {}
    i = cursor
    while True:
        i = data.find(b'{"k":', i)
        if i < 0:
            break
        obj, nxt = brace_match(data, i)
        i = nxt
        if not isinstance(obj, dict):
            continue
        kind = obj.get("k")
        if kind == "directive":
            directives.append(obj)
            source = obj.get("source", "")
            for order in obj.get("orders") or []:
                entry = dict(order)
                entry["source"] = source
                entry["turn"] = obj.get("turn")
                entry["slot"] = obj.get("slot")
                orders.append(entry)
            if obj.get("say"):
                radio.append(obj["say"])
        elif kind == "orders":
            for order in obj.get("orders") or []:
                entry = dict(order)
                entry["source"] = "applied"
                entry["turn"] = obj.get("turn")
                orders.append(entry)
        elif kind == "stop":
            stop = obj
        elif kind == "fallback":
            fallbacks += 1
        elif kind == "register":
            registers.append(obj)
        elif kind == "budget_guard":
            budget_guards += 1
        elif kind == "result":
            results = obj.get("results", obj)

    raw_players = config.get("players") or []
    names = [
        p.get("name", "") if isinstance(p, dict) else str(p) for p in raw_players
    ]
    aliases = ["Alpha", "Beta", "Gamma", "Delta"]

    return {
        "protocol": protocol,
        "gameName": game_name,
        "gameVersion": game_version,
        "seed": config.get("seed"),
        "variant": config.get("variant"),
        "names": names,
        "aliases": aliases,
        "policyKinds": [r.get("kind", "") for r in registers],
        "tickCount": max(
            [int(results.get("finalTick") or 0), int(stop.get("tick") or 0)]
        ),
        "orders": orders,
        "radio": radio,
        "directives": directives,
        "fallbacks": fallbacks,
        "budgetGuards": budget_guards,
        "stop": stop,
        "results": results,
    }


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: replay_summary.py <path.replay>", file=sys.stderr)
        return 2
    out = summarise(argv[1])
    # ensure_ascii=False keeps a non-ASCII policy label or note as real UTF-8,
    # which is exactly what the strict-parse check downstream is testing.
    sys.stdout.write(json.dumps(out, ensure_ascii=False) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
