## Persistent numeric controller decisions over the native traffic simulator.

import std/[json, os]
import signals/[sim, llm]

const
  Variants = ["grid4x4", "rushhour"]
  ValueCount = 201

var
  game: SimServer
  variant: string
  cursor: int
  decisionId: int
  actions: array[MaxSeats, JsonNode]

proc seedOf(value: string): int =
  var hash = 2166136261'u32
  for ch in value:
    hash = (hash xor uint32(ord(ch))) * 16777619'u32
  int(hash and 0x7fffffff'u32)

proc options(width: int): JsonNode =
  result = newJArray()
  for value in 0 ..< width:
    result.add(%value)

proc heads(): JsonNode =
  result = newJArray()
  for i in 0 ..< 4:
    result.add(%*{"name": "verb_" & $i,
      "choices": ["hold", "phase", "wave", "auto"]})
    result.add(%*{"name": "phase_" & $i,
      "choices": ["NSG", "NSL", "EWG", "EWL"]})
    result.add(%*{"name": "delay_" & $i,
      "choices": options(game.config.turnTicks - 1)})

proc currentDecision(): JsonNode =
  let observation = game.observationJson(cursor, game.turn)
  var properties = newJObject()
  var required = newJArray()
  for head in heads():
    let name = head["name"].getStr()
    properties[name] = %*{"enum": head["choices"]}
    required.add(%name)
  %*{"kind": "decision", "game": "sumo-traffic-signals",
    "decision_id": decisionId, "seat": cursor, "engine_seat": cursor,
    "turn": game.turn, "semantic_view": observation,
    "inbox": [], "messages": [
      {"role": "system", "content": SystemPrompt},
      {"role": "user", "content": userMessage("", $observation)}],
    "speech_messages": [],
    "action_schema": {"type": "object", "properties": properties,
      "required": required}, "typed_question": newJNull()}

proc encoding(): JsonNode =
  let observation = game.observationJson(cursor, game.turn)
  var values = newJArray()
  for name in Variants: values.add(%(if variant == name: 1 else: 0))
  for seat in 0 ..< MaxSeats:
    values.add(%(if cursor == seat: 1 else: 0))
  values.add(%(float(game.tickCount) / float(game.config.maxTicks)))
  let status = observation["network_status"]
  values.add(%(float(status["throughput"].getInt()) /
    float(2 * game.config.parThroughput)))
  values.add(%(float(status["demand"].getInt()) / 1000.0))
  values.add(%(float(status["rejected"].getInt()) / 1000.0))
  values.add(%(float(status["wait_ticks"].getInt()) / 100000.0))
  values.add(%(float(status["waves"].getInt()) / 100.0))
  values.add(%(float(status["your_wait_ticks"].getInt()) / 50000.0))
  for detector in observation["detectors"]:
    let phase = detector["phase"].getStr()
    var phaseIndex = 0
    for index, name in ["NSG", "NSL", "EWG", "EWL", "CLR"]:
      if phase == name: phaseIndex = index
    values.add(%(float(phaseIndex) / 4.0))
    values.add(%(float(detector["ticks_in_phase"].getInt()) / 60.0))
    for approach in ["N", "E", "S", "W"]:
      values.add(%(float(detector["q"][approach].getInt()) /
        float(game.config.gateQueueCap)))
  for signal in observation["your_signals"]:
    let phase = signal["phase"].getStr()
    var phaseIndex = 0
    for index, name in ["NSG", "NSL", "EWG", "EWL", "CLR"]:
      if phase == name: phaseIndex = index
    values.add(%(float(phaseIndex) / 4.0))
    values.add(%(float(signal["ticks_in_phase"].getInt()) / 60.0))
    values.add(%(float(signal["order_age_turns"].getInt()) / 32.0))
    for approach in signal["approaches"]:
      values.add(%(float(approach["queue"].getInt()) /
        float(game.config.gateQueueCap)))
      values.add(%(if approach["link_full"].getBool(): 1 else: 0))
      values.add(%(float(approach["blocked_ticks"].getInt()) /
        float(game.config.maxTicks)))
    for exitIndex in 0 ..< 4:
      if exitIndex < signal["exits"].len:
        let exit = signal["exits"][exitIndex]
        values.add(%(float(exit["occupancy"].getInt()) /
          float(exit["capacity"].getInt())))
        values.add(%(if exit["full"].getBool(): 1 else: 0))
      else:
        values.add(%0)
        values.add(%0)
  doAssert values.len == ValueCount
  %*{"decision_id": decisionId, "values": values,
    "action_heads": heads()}

proc reset(request: JsonNode, manifestPath: string): JsonNode =
  doAssert request["players"].getInt() == MaxSeats
  let manifest = parseFile(manifestPath)
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = copy(entry["game_config"])
  doAssert variantConfig.kind == JObject
  variantConfig["seed"] = %seedOf(request["seed"].getStr())
  var config = defaultGameConfig()
  config.update($variantConfig)
  game = initSimServer(config)
  game.phase = Playing
  game.turn = 1
  cursor = 0
  decisionId = 0
  currentDecision()

proc teacher(): JsonNode =
  let reply = game.scriptedReply(cursor, blGreedy)
  var action = newJObject()
  for i, order in reply.orders:
    action["verb_" & $i] = %($order.verb)
    action["phase_" & $i] = %($order.phase)
    action["delay_" & $i] = %order.delay
  %*{"response": $action}

proc step(request: JsonNode): JsonNode =
  doAssert request["decision_id"].getInt() == decisionId
  let action = parseJson(request["response"].getStr())
  for head in heads():
    let name = head["name"].getStr()
    doAssert action[name] in head["choices"], "action is masked: " & name
  actions[cursor] = action
  inc cursor
  inc decisionId
  if cursor == MaxSeats:
    for slot in 0 ..< MaxSeats:
      let owned = quadrantIntersections(slot)
      var orders = newJArray()
      for i, at in owned:
        orders.add(%*{
          "at": intersectionName(at),
          "verb": actions[slot]["verb_" & $i],
          "phase": actions[slot]["phase_" & $i],
          "delay": actions[slot]["delay_" & $i]
        })
      let reply = parseControllerReply(%*{"orders": orders}, owned,
        game.previousOrders(slot), game.turn, game.config.turnTicks)
      doAssert reply.rejected == 0
      game.applyReply(slot, reply)
    discard game.stepTurnTicks()
    if not game.settled: inc game.turn
    cursor = 0
  let observation = if game.settled:
    doAssert game.endReason == rsComplete, game.stopDetail
    var scores = newJObject()
    var utilities = newJObject()
    for slot in 0 ..< MaxSeats:
      let score = max(0.0, min(1.0,
        float(game.scoreOf(slot)) /
        float(2 * 1_000_000 * game.config.parThroughput)))
      scores[$slot] = %score
      utilities[$slot] = %(2.0 * score - 1.0)
    %*{"kind": "terminal", "scores": scores,
      "utilities": utilities}
  else: currentDecision()
  %*{"kind": "accepted", "action": action,
    "observation": observation}

when isMainModule:
  let args = commandLineParams()
  if args.len != 2:
    quit("usage: sumo-train-bridge MANIFEST VARIANT", 1)
  let manifestPath = absolutePath(args[0])
  variant = args[1]
  doAssert variant in Variants
  for line in stdin.lines:
    let request = parseJson(line)
    let response = case request["kind"].getStr()
      of "reset": reset(request, manifestPath)
      of "encode": encoding()
      of "teacher": teacher()
      of "step": step(request)
      else: raise newException(ValueError, "unknown command")
    stdout.writeLine($response)
    stdout.flushFile()
