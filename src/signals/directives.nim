## The reply schema: what a controller (LLM or scripted) may say, how a reply
## is parsed TOLERANTLY, and how an illegal order is REPAIRED instead of
## rejected. Forked from the starter's `src/ctf/directives.nim`.
##
## Both policy kinds emit the SAME object through this one validator, which is
## what makes the bounded-orders test in `tests/test_signals_driver.nim`
## meaningful.
##
## RUNE DISCIPLINE. Every cap here is measured in RUNES and every truncation
## lands on a rune boundary (`runeLen` / `runeSubStr`, via `truncateRunes` in
## `sim_types`). Slicing a recorded string by BYTE index is forbidden: a
## byte-truncated multi-byte character renders fine in a browser and then
## fails a strict UTF-8 parser, which is exactly the class of bug that makes a
## replay unreadable to everything except the one viewer that was lenient.

import
  std/[json, strutils, unicode],
  sim_types

type
  ControllerOrder* = object
    ## One order for one of the seat's four intersections.
    at*: int                   ## intersection index.
    verb*: OrderVerb
    phase*: PhaseId
    delay*: int
    fromReply*: bool           ## a reply entry really named this intersection.
    repaired*: bool            ## the entry was invalid and was repaired to
                               ## the intersection's previous order.

  DirectiveSource* = enum
    dsLlm = "llm"
    dsScripted = "scripted"
    dsFallback = "fallback"

  ControllerReply* = object
    ## One seat's whole order set for one turn.
    orders*: seq[ControllerOrder]
    say*: string               ## <= MaxSayRunes; the control-room radio.
    notes*: string             ## <= MaxNoteRunes; private, echoed back.
    source*: DirectiveSource
    latencyMs*: int
    rejected*: int             ## entries dropped or repaired, counted.

  DirectiveError* = object of ValueError

proc sanitizeLine*(text: string, limit: int): string =
  ## One recorded free-text line: newlines collapse to spaces so a record
  ## stays one line, control characters are dropped, and the cut lands on a
  ## RUNE boundary. Braces are excluded deliberately — the replay chat stream
  ## carries the control records as JSON objects and tells them apart from a
  ## controller's radio line by a leading '{'.
  var cleaned = ""
  for rune in text.replace("\n", " ").replace("\r", " ").runes:
    let value = int(rune)
    if value < 32:
      continue
    if value == ord('{') or value == ord('}'):
      continue
    cleaned.add($rune)
  cleaned.strip().truncateRunes(limit)

proc sanitizeSay*(text: string): string = sanitizeLine(text, MaxSayRunes)
proc sanitizeNote*(text: string): string = sanitizeLine(text, MaxNoteRunes)

proc parseVerb*(text: string): tuple[ok: bool, verb: OrderVerb] =
  ## Tolerant: lower-cased, trimmed. Anything unknown reports `ok = false` so
  ## the caller REPAIRS to the intersection's previous order rather than
  ## inventing one.
  let key = text.strip().toLowerAscii().truncateRunes(6)
  for verb in OrderVerb:
    if $verb == key:
      return (true, verb)
  (false, ovHold)

proc parsePhase*(text: string): tuple[ok: bool, phase: PhaseId] =
  ## Upper-cased before matching. `CLR` is not selectable and is rejected.
  let key = text.strip().toUpperAscii().truncateRunes(3)
  for phase in SelectablePhases:
    if $phase == key:
      return (true, phase)
  (false, phNSG)

proc extractJsonObject*(text: string): JsonNode =
  ## The outermost balanced `{...}` in a model reply, tolerating markdown
  ## fences and any prose the model prefixed or suffixed. Falls back to
  ## first-brace..last-brace when the scan finds no balanced pair, which is
  ## what recovers a reply whose braces sit inside a quoted string.
  var
    depth = 0
    start = -1
    inString = false
    escaped = false
  for i, ch in text:
    if inString:
      if escaped: escaped = false
      elif ch == '\\': escaped = true
      elif ch == '"': inString = false
      continue
    case ch
    of '"': inString = true
    of '{':
      if depth == 0: start = i
      inc depth
    of '}':
      if depth > 0:
        dec depth
        if depth == 0 and start >= 0:
          try:
            return parseJson(text[start .. i])
          except CatchableError:
            start = -1
    else: discard
  let
    first = text.find('{')
    last = text.rfind('}')
  if first < 0 or last <= first:
    var head = text.strip()
    if head.runeLen > 160:
      head = head.truncateRunes(160) & "..."
    raise newException(
      DirectiveError, "no JSON object in reply: " & head.replace("\n", " "))
  parseJson(text[first .. last])

proc readIntField(node: JsonNode): tuple[ok: bool, value: int] =
  ## One integer field: an int, a float, or a numeric string. Anything
  ## non-finite or unparseable reports `ok = false`.
  if node.isNil:
    return (false, 0)
  case node.kind
  of JInt: (true, int(node.getBiggestInt()))
  of JFloat:
    let f = node.getFloat()
    if f != f or f > 1.0e9 or f < -1.0e9: (false, 0) else: (true, int(f))
  of JString:
    try: (true, int(parseFloat(node.getStr().strip())))
    except CatchableError: (false, 0)
  else: (false, 0)

proc orderEntries(payload: JsonNode): seq[JsonNode] =
  ## The reply's `orders` collection, accepted as an ARRAY of objects or as an
  ## OBJECT keyed by intersection id — both shapes are things models emit.
  let node = payload{"orders"}
  if node.isNil:
    return @[]
  if node.kind == JArray:
    for item in node:
      if item.kind == JObject:
        result.add(item)
  elif node.kind == JObject:
    for key, item in node:
      if item.kind != JObject:
        continue
      var entry = copy(item)
      if entry{"at"}.isNil:
        entry["at"] = %key
      result.add(entry)

proc parseControllerReply*(
  payload: JsonNode,
  owned: openArray[int],
  previous: openArray[SignalOrder],
  turn, turnTicks: int
): ControllerReply =
  ## Turns one parsed reply into a legal order set, REPAIRING every field the
  ## schema bounds rather than rejecting the reply:
  ##
  ## * `orders`          at most four entries; extras dropped and counted;
  ## * `orders[].at`     one of THIS seat's four ids, upper-cased, at most
  ##                     once (a repeat is dropped and counted);
  ## * `orders[].verb`   hold | phase | wave | auto, lower-cased;
  ## * `orders[].phase`  required iff verb in {phase, wave}; CLR rejected;
  ## * `orders[].delay`  required iff verb == wave; clamped to 0 .. turnTicks-2;
  ## * `say` / `notes`   truncated on RUNE boundaries at 120 / 240;
  ## * an entry whose required argument is missing or unknown is REPAIRED to
  ##   that intersection's previous order and counted in `ordersRejected`.
  ##
  ## A reply with a valid `say` but no `orders` is USABLE: every signal keeps
  ## its order and the radio line is delivered. Only a reply that is not a
  ## JSON object is a parse failure.
  if payload.isNil or payload.kind != JObject:
    raise newException(DirectiveError, "reply is not a JSON object")
  result.source = dsLlm
  result.say = sanitizeSay(payload{"say"}.getStr())
  result.notes = sanitizeNote(payload{"notes"}.getStr())
  result.orders = @[]
  let maxDelay = max(0, turnTicks - 2)
  var claimed: seq[int] = @[]
  for entry in orderEntries(payload):
    if result.orders.len >= MaxOrdersPerReply:
      inc result.rejected                ## entries past the cap are dropped.
      continue
    let at = intersectionIndex(entry{"at"}.getStr().truncateRunes(2))
    if at < 0 or not owned.contains(at):
      inc result.rejected                ## not one of this seat's four.
      continue
    if claimed.contains(at):
      inc result.rejected                ## a repeat is dropped.
      continue
    claimed.add(at)
    var order = ControllerOrder(
      at: at, verb: ovHold, phase: phNSG, delay: 0, fromReply: true)
    let verb = parseVerb(entry{"verb"}.getStr())
    if not verb.ok:
      inc result.rejected
      order.repaired = true
      var slot = 0
      for i, owner in owned:
        if owner == at: slot = i
      if slot < previous.len:
        order.verb = previous[slot].verb
        order.phase = previous[slot].phase
        order.delay = previous[slot].delay
      result.orders.add(order)
      continue
    order.verb = verb.verb
    if order.verb == ovPhase or order.verb == ovWave:
      let phase = parsePhase(entry{"phase"}.getStr())
      if not phase.ok:
        inc result.rejected
        order.repaired = true
        var slot = 0
        for i, owner in owned:
          if owner == at: slot = i
        if slot < previous.len:
          order.verb = previous[slot].verb
          order.phase = previous[slot].phase
          order.delay = previous[slot].delay
        result.orders.add(order)
        continue
      order.phase = phase.phase
    if order.verb == ovWave:
      let delay = readIntField(entry{"delay"})
      if not delay.ok:
        inc result.rejected                ## repaired to 0, never dropped.
        order.delay = 0
      else:
        order.delay = clamp(delay.value, 0, maxDelay)
    result.orders.add(order)

proc toSignalOrder*(order: ControllerOrder, turn: int): SignalOrder =
  SignalOrder(
    verb: order.verb,
    phase: order.phase,
    delay: order.delay,
    turn: turn,
    outcome: (if order.repaired: orRepaired else: orUnknown)
  )

proc orderText*(order: SignalOrder): string =
  ## The compact, human-readable form the observation and the feed both show:
  ## `hold`, `phase EWG`, `wave EWG +3`, `auto`.
  case order.verb
  of ovHold: "hold"
  of ovAuto: "auto"
  of ovPhase: "phase " & $order.phase
  of ovWave: "wave " & $order.phase & " +" & $order.delay

proc orderJson*(order: ControllerOrder): JsonNode =
  result = %*{"at": intersectionName(order.at), "verb": $order.verb}
  if order.verb == ovPhase or order.verb == ovWave:
    result["phase"] = %($order.phase)
  if order.verb == ovWave:
    result["delay"] = %order.delay

proc directiveRecord*(
  reply: ControllerReply,
  turn, slot: int,
  view: JsonNode
): JsonNode =
  ## The replay chat record for one turn's decision. Re-applied at playback
  ## into NON-HASHED fields only: it drives the broadcast feed and
  ## `tools/replay_summary.py` and can never affect the simulation.
  var orders = newJArray()
  for order in reply.orders:
    orders.add(orderJson(order))
  result = %*{
    "k": "directive",
    "turn": turn,
    "slot": slot,
    "alias": seatAlias(slot),
    "source": $reply.source,
    "latency_ms": reply.latencyMs,
    "orders": orders,
    "say": reply.say.truncateRunes(MaxSayRunes)
  }
  if not view.isNil:
    result["view"] = view

proc boundedDirectiveRecord*(
  reply: ControllerReply,
  turn, slot: int,
  view: JsonNode
): string =
  ## The serialized directive record, guaranteed <= MaxDirectiveRunes. The
  ## view is the only unbounded-in-practice field, so it is the one that goes;
  ## the `say` cut still lands on a rune boundary. NEVER cut the SERIALIZED
  ## string — that would emit broken JSON, which is the exact failure the rune
  ## rule exists to prevent.
  result = $reply.directiveRecord(turn, slot, view)
  if result.runeLen <= MaxDirectiveRunes:
    return
  result = $reply.directiveRecord(turn, slot, nil)
  var
    trimmed = reply
    guard = 0
  while result.runeLen > MaxDirectiveRunes and guard < 12:
    inc guard
    trimmed.say = trimmed.say.truncateRunes(
      max(0, trimmed.say.runeLen - max(4, trimmed.say.runeLen div 2)))
    result = $trimmed.directiveRecord(turn, slot, nil)
