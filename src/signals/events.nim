## The tier-2 analysis stream: the `SimEventKind` vocabulary and the
## `eventsJsonl` summary-row contract, forked from the starter's
## `src/ctf/events.nim`. Only the event kinds are new.
##
## `COGAME_EVENTS_URI` receives one JSON object per line, then ONE mandatory
## trailing summary row — that trailing row is the contract, and the analysis
## side treats a stream without it as truncated.

import
  std/[json, strutils],
  sim_types

type
  SimEventKind* = enum
    seSpawn = "spawn"
    seEnter = "enter"
    seReject = "reject"
    seCross = "cross"
    seExit = "exit"
    sePhaseChange = "phasechange"
    seStarve = "starve"
    seSpillback = "spillback"
    seSpillClear = "spillclear"
    seGridlock = "gridlock"
    seGridlockClear = "gridlockclear"
    seWave = "wave"
    seTurnStart = "turnstart"
    seDirective = "directive"
    seFallback = "fallback"
    sePhaseChangeDeferred = "phasechangedeferred"

  SimEvent* = object
    kind*: SimEventKind
    tick*: int
    slot*: int                 ## the owning seat, or -1.
    at*: int                   ## intersection index, or -1.
    link*: int                 ## link index, or -1.
    gate*: int                 ## gate index, or -1.
    a*: int                    ## kind-specific integer payload.
    b*: int
    text*: string              ## kind-specific short text (already rune-capped).

proc initSimEvent*(
  kind: SimEventKind,
  tick: int,
  slot = -1,
  at = -1,
  link = -1,
  gate = -1,
  a = 0,
  b = 0,
  text = ""
): SimEvent =
  SimEvent(
    kind: kind, tick: tick, slot: slot, at: at, link: link, gate: gate,
    a: a, b: b, text: text.truncateRunes(MaxSayRunes)
  )

proc eventJson*(event: SimEvent): JsonNode =
  ## One tier-2 row. Every optional id is omitted when absent, so a consumer
  ## can key on presence rather than on a sentinel.
  result = %*{"type": $event.kind, "tick": event.tick}
  if event.slot >= 0:
    result["slot"] = %event.slot
    result["alias"] = %seatAlias(event.slot)
  if event.at >= 0:
    result["at"] = %intersectionName(event.at)
  if event.link >= 0:
    result["link"] = %event.link
  if event.gate >= 0:
    result["gate"] = %event.gate
  if event.a != 0:
    result["a"] = %event.a
  if event.b != 0:
    result["b"] = %event.b
  if event.text.len > 0:
    result["text"] = %event.text

proc eventsJsonl*(
  events: openArray[SimEvent], ticks: int
): string =
  ## The whole tier-2 stream plus the MANDATORY trailing summary row.
  var lines: seq[string]
  for event in events:
    lines.add($eventJson(event))
  lines.add($(%*{
    "type": "summary",
    "ticks": ticks,
    "events": events.len,
    "gameVersion": GameVersion
  }))
  lines.join("\n") & "\n"

proc allEventKinds*(): seq[string] =
  ## The closed vocabulary, for the events test.
  for kind in SimEventKind:
    result.add($kind)
