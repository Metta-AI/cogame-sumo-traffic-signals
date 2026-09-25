## Jev ranks the four ordinary signal orders and optional radio and notes.

import std/[json, monotimes, os, strutils, times]
import curly
import model_pacing

proc jevConfigured*(): bool =
  getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip().len > 0 or
    (getEnv("METTA_CAPTURE_URL").strip().len > 0 and
      getEnv("METTA_CAPTURE_KEY").strip().len > 0) or
    getEnv("TYPESAFE_API_KEY").strip().len > 0

proc bestChoice(answer, criteria: JsonNode): string =
  if answer["type"].getStr() != "choice":
    raise newException(ValueError, "Jev returned a non-choice answer")
  let probabilities = answer["probabilities"]
  if probabilities.len != criteria.len:
    raise newException(ValueError, "Jev returned the wrong choice set")
  var best = -1.0
  var total = 0.0
  for choice, probability in probabilities.pairs:
    if not criteria.hasKey(choice):
      raise newException(ValueError, "Jev returned an unknown choice")
    let value = probability.getFloat()
    if value < 0 or value > 1:
      raise newException(ValueError, "Jev probability outside [0, 1]")
    total += value
    if value > best:
      best = value
      result = choice
  if abs(total - 1) > probabilities.len.float * 0.005 + 1e-6:
    raise newException(ValueError, "Jev probabilities do not sum to one")

proc chooseJevAction*(
  view: JsonNode, pacer: var ModelPacer, budgetMs: int
): JsonNode =
  let started = getMonoTime()
  var questions = newJObject()
  var choices: array[4, JsonNode]
  for index in 0 ..< view["your_signals"].len:
    let signal = view["your_signals"][index]
    let at = signal["at"].getStr()
    var plans = %*{
      "hold": {"at": at, "verb": "hold"},
      "auto": {"at": at, "verb": "auto"}
    }
    for phase in ["NSG", "NSL", "EWG", "EWL"]:
      plans["phase_" & phase] = %*{
        "at": at, "verb": "phase", "phase": phase}
      for delay in 0 .. max(0, view["turn_ticks"].getInt() - 2):
        plans["wave_" & phase & "_" & $delay] = %*{
          "at": at, "verb": "wave", "phase": phase, "delay": delay}
    choices[index] = plans
    var criteria = newJObject()
    for name, plan in plans.pairs:
      criteria[name] = %($plan)
    questions["signal_" & $index] = %*{
      "type": "choice",
      "instructions": "Choose the best order for your intersection " & at &
        ". A green into a full outbound link serves no cars; coordinate " &
        "wave delays with neighboring signals.",
      "criteria": criteria}

  let says = %*{
    "silent": "",
    "east_wave": "I am coordinating an eastbound green wave.",
    "west_wave": "I am coordinating a westbound green wave.",
    "spillback": "A downstream link is full; avoid feeding it.",
    "clear": "My quadrant is clearing queues."
  }
  let notes = %*{
    "clear": "",
    "keep": view{"your_notes"}.getStr(),
    "watch": "Watch downstream occupancy before opening the next green.",
    "wave": "Revisit signal offsets next turn."
  }
  var sayCriteria = newJObject()
  var noteCriteria = newJObject()
  for name, choice in says.pairs:
    sayCriteria[name] = %choice.getStr()
  for name, choice in notes.pairs:
    noteCriteria[name] = %choice.getStr()
  questions["say"] = %*{"type": "choice",
    "instructions": "Choose an optional public radio call.",
    "criteria": sayCriteria}
  questions["notes"] = %*{"type": "choice",
    "instructions": "Choose private notes for your next turn.",
    "criteria": noteCriteria}

  let sidecar = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let capture = getEnv("METTA_CAPTURE_URL").strip()
  let endpoint =
    if sidecar.len > 0: sidecar
    elif capture.len > 0: capture
    else: getEnv("TYPESAFE_BASE_URL", "https://api.typesafe.ai")
  let model =
    if sidecar.len > 0: "typesafe/jev-1.13"
    elif capture.len > 0: getEnv("METTA_CAPTURE_MODEL", "jev-latest")
    else: getEnv("TYPESAFE_DEFAULT_MODEL", "jev-latest")
  let key =
    if sidecar.len > 0: ""
    elif capture.len > 0: getEnv("METTA_CAPTURE_KEY").strip()
    else: getEnv("TYPESAFE_API_KEY").strip()
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if key.len > 0:
    headers["authorization"] = "Bearer " & key
  else:
    headers["x-coworld-player-slot"] = $view["slot"].getInt()
  let body = %*{
    "model": model,
    "state": "You control four traffic signals in one quadrant. " &
      "Choose each ordinary order, public radio, and private notes " &
      "independently. The game owns signal legality and scores. " &
      "Here is this seat's observation:\n" & $view,
    "questions": questions
  }
  pacer.acquire(budgetMs - (getMonoTime() - started).inMilliseconds.int)
  let remaining = budgetMs - (getMonoTime() - started).inMilliseconds.int
  let response = newCurly().post(endpoint.strip(chars = {'/'},
    leading = false) & "/v1/systemone", headers, $body,
    max(1, (remaining - 500) div 1000))
  if response.code < 200 or response.code >= 300:
    raise newException(ValueError, "Jev HTTP " & $response.code)
  let payload = parseJson(response.body)
  let answers = payload["answers"]
  var orders = newJArray()
  for index in 0 ..< view["your_signals"].len:
    let name = "signal_" & $index
    let chosen = bestChoice(answers[name], questions[name]["criteria"])
    orders.add(choices[index][chosen])
  let say = bestChoice(answers["say"], sayCriteria)
  let note = bestChoice(answers["notes"], noteCriteria)
  echo "signals Jev player: model ", payload{"model"}.getStr(),
    " input_tokens ", payload["usage"]{"input_tokens"}.getInt(),
    " output_tokens ", payload["usage"]{"output_tokens"}.getInt()
  %*{"orders": orders, "say": says[say], "notes": notes[note]}
