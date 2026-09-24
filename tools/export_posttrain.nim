## Export complete native traffic-signal games as hosted controller decisions.

import std/[json, os, osproc, strutils]
import signals/[sim, roster, llm]

when isMainModule:
  let args = commandLineParams()
  if args.len != 3:
    quit("usage: signals-posttrain OUTPUT EPISODES VARIANT", 1)
  let output = args[0]
  let episodes = parseInt(args[1])
  let variant = args[2]
  if episodes < 10: quit("at least ten games are required", 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = copy(entry["game_config"])
  doAssert variantConfig.kind == JObject
  createDir(output)
  let revision = execProcess("git rev-parse HEAD").strip()
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
  for seed in 1 .. episodes:
    variantConfig["seed"] = %seed
    var config = defaultGameConfig()
    config.update($variantConfig)
    var game = initSimServer(config)
    game.phase = Playing
    var rows: seq[string]
    for turnIndex in 1 .. game.turnsPerEpisode():
      if game.settled: break
      game.turn = turnIndex
      var replies: array[MaxSeats, ControllerReply]
      for slot in 0 ..< MaxSeats:
        let observation = game.observationJson(slot, turnIndex)
        let baseline = if (slot + seed) mod 2 == 0:
          blGreedy else: blFixedCycle
        let reply = game.scriptedReply(slot, baseline)
        var orders = newJArray()
        for order in reply.orders:
          orders.add(orderJson(order))
        let completion = %*{"orders": orders, "say": reply.say,
          "notes": reply.notes}
        let accepted = parseControllerReply(completion,
          quadrantIntersections(slot), game.previousOrders(slot),
          turnIndex, config.turnTicks)
        doAssert accepted.rejected == 0
        replies[slot] = accepted
        rows.add($(%*{
          "episode_id": "sumo-traffic-signals-" & variant & "-" & $seed,
          "seed": "sumo-traffic-signals-" & variant & "-" & $seed,
          "decision_id": rows.len,
          "prompt": [
            {"role": "system", "content": SystemPrompt},
            {"role": "user", "content": userMessage("", $observation)}
          ],
          "completion": [{"role": "assistant", "content": $completion}],
          "game": "sumo-traffic-signals",
          "action_schema_revision": "sumo-signals-reply-v1"
        }))
      for slot in 0 ..< MaxSeats:
        game.applyReply(slot, replies[slot])
      discard game.stepTurnTicks()
    doAssert game.settled and game.endReason == rsComplete,
      "seed " & $seed & " ended " & $game.endReason & "/" & $game.endRule
    if seed mod 5 == 0: validationRows.add(rows)
    else: trainRows.add(rows)
    let results = parseJson(game.cityResultsJson())
    runs.add(%*{"seed": seed, "ticks": game.tickCount,
      "decisions": rows.len, "scores": results["scores"],
      "reason": results["reason"]})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1, "game": "sumo-traffic-signals", "variant": variant,
    "source_revision": revision, "teacher": "greedy-and-fixedcycle",
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len, "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
