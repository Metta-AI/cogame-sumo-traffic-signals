## Claude-backed signal control. A policy is just a prompt: the game server
## composes the seat's detector view plus that seat's PLAYER_PROMPT and asks
## Claude what its four signals do for the next eight simulated seconds.
##
## Forked from the starter's `src/ctf/llm.nim` with NO behaviour change — the
## credential ladder, the Bedrock model rotation, the fence-tolerant JSON
## extraction and the rune-boundary truncation are all scar tissue from real
## hosted failures and none of it is re-derived here.
##
## This is a SIMULTANEOUS-decision game, so all four seats' calls go out as
## ONE parallel batch per turn (`curly.makeRequests`). Seats are never queried
## sequentially: that is what keeps 32 turns inside the wall-clock budget.
##
## Credentials, in order of preference:
##   Bedrock sidecar (AWS_ENDPOINT_URL_BEDROCK_RUNTIME + AWS_BEARER_TOKEN_BEDROCK)
##   ANTHROPIC_API_KEY
##   ANTHROPIC_API_KEY_URI
## With none of them the client disables itself and every turn falls back to
## the scripted layer INSTANTLY, with no network wait — which is what lets
## offline certification finish in seconds.

import
  std/[json, os, strutils],
  bitworld/runtime,
  curly,
  sim_types

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"

type
  LlmTransport* = enum
    ltNone, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl*: Curly
    transport*: LlmTransport
    apiKey: string
    bedrockEndpoint: string
    bedrockModels: seq[string]
    bedrockModel: int
    bedrockToken: string
    model*: string
    maxOutputTokens*: int
    disabled*: bool
    throttled*: bool
      ## The provider answered 429 and there is no other candidate model to
      ## rotate to. Set per turn, cleared by the turn loop: retrying inside
      ## the same turn cannot succeed, so the seat fails fast to the scripted
      ## fallback instead of spending the turn budget on a refused call.

  LlmError* = object of ValueError

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "signals llm: failed to fetch ANTHROPIC_API_KEY_URI: ", error.msg
    result = ""

proc bedrockModelIds(): seq[string] =
  ## Bedrock inference-profile candidates, tried in order; `BEDROCK_MODEL`
  ## pins one. `us.anthropic.claude-sonnet-4-6` is deliberately NOT a
  ## candidate: it times out on every sidecar call (cogame-raid round 2,
  ## 2026-08-23).
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  @["us.anthropic.claude-haiku-4-5-20251001-v1:0",
    "us.anthropic.claude-sonnet-4-5-20250929-v1:0"]

proc tryNextBedrockModel(client: LlmClient, why: string): bool =
  if client.transport != ltBedrock or
      client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  client.bedrockModel.inc
  echo "signals llm: ", client.bedrockModels[client.bedrockModel - 1],
    " unusable (", why, "); falling back to ",
    client.bedrockModels[client.bedrockModel]
  true

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: (if config.model.len > 0: config.model
            else: "claude-haiku-4-5-20251001"),
    maxOutputTokens: max(1, config.maxOutputTokens)
  )
  let
    bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
    bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION", getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "signals llm: bedrock transport, model ",
      result.bedrockModels[result.bedrockModel]
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "signals llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    ## The exact phrase phase 60 greps the GAME log for, alongside "falling
    ## back": "LLM provider is unavailable".
    echo "signals llm: no credentials — the LLM provider is unavailable; ",
      "every turn is falling back to the scripted layer"

proc requestFor*(
  client: LlmClient, system, user: string
): tuple[url: string, headers: HttpHeaders, body: string] =
  ## One Messages-API request, shaped for whichever transport is live.
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  else:
    body["model"] = %client.model
    ## Only the Claude 5 / Opus tiers accept an effort setting; Haiku 4.5
    ## rejects the whole request with a 400 if it is present.
    if "haiku" notin client.model and "4-5" notin client.model:
      body["output_config"] = %*{"effort": "low"}
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc textOf*(
  client: LlmClient, response: Response, error, url: string
): string =
  ## The text of one batched reply, or an LlmError describing why there is
  ## none. Auth failure disables the client for the rest of the episode;
  ## model-access denial and throttling rotate the Bedrock model for the next
  ## batch instead.
  if error.len > 0:
    raise newException(LlmError, "llm transport: " & error)
  if response.code == 401 or response.code == 403:
    ## RUNE-safe: this text becomes `fallback.detail` in the replay, and a
    ## provider body is arbitrary bytes. A byte slice can cut a codepoint in
    ## half, and truncateRunes downstream only SHORTENS — it cannot repair a
    ## broken one.
    let detail = response.body.truncateRunes(MaxFallbackDetailRunes)
    if "Model access is denied" in response.body and
        client.tryNextBedrockModel("no model access"):
      raise newException(LlmError, "bedrock model access denied: " & detail)
    client.disabled = true
    raise newException(
      LlmError,
      "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    let detail = response.body.truncateRunes(MaxFallbackDetailRunes)
    if not client.tryNextBedrockModel("throttled"):
      client.throttled = true
    raise newException(LlmError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(LlmError, "anthropic error " & $response.code & ": " &
      response.body.truncateRunes(MaxFallbackDetailRunes))
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(LlmError, "anthropic refusal")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  ## Bounded read: at most MaxReplyBytes BYTES are parsed, cut on a rune
  ## boundary. The cap is written in bytes, so it is enforced in bytes — a
  ## rune cap at the same number let a 4-byte-per-rune reply through at ~16 KB.
  if result.len > MaxReplyBytes:
    result = result.truncateBytes(MaxReplyBytes)
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(LlmError, "reply cut off at max_tokens before any " &
      "JSON: " & result.truncateRunes(160).replace("\n", " "))

const SystemPrompt* = """
You are the traffic-signal controller for FOUR intersections in one quadrant of a
4x4 city grid. Three other controllers run the other three quadrants. You do not
control their signals and you cannot see their plans. Every 8 simulated seconds you
issue orders and a deterministic actuator runs your signals until you change them.

THE CITY
- Intersections are named row+column: rows A (north) to D (south), columns 1 (west)
  to 4 (east). Cars enter from 16 gates on the edges and drive a fixed shortest
  route to their exit gate.
- Every approach is ONE LANE. A car that wants to turn left blocks every car behind
  it until you give it a left phase.
- Four phases: NSG (north+south, straight and right), NSL (north+south, left only),
  EWG (east+west, straight and right), EWL (east+west, left only). Every change costs
  2 ticks of all-red, and a phase must run 4 ticks before it can change.
- LINKS ARE SHORT AND THEY FILL UP. An east-west block holds 6 cars, a north-south
  block holds 4. When the block ahead is FULL, the car at your stop line CANNOT MOVE
  EVEN ON GREEN. Your green then buys nothing and costs you the cross street.
- If a stop-line car is blocked by the phase for 60 ticks the city forces the phase
  that serves it and your order is overridden.

WHAT SCORES
Only how many cars get all the way OUT of the city. Everyone gets the same number.
Total waiting across the whole city is the tie-break, and waiting at YOUR OWN four
intersections is a much smaller tie-break after that. Emptying your own queues into
somebody else's full block lowers the number everybody is scored on, including you.

YOUR ORDERS (one per intersection per turn; a signal keeps its order until you change it)
- {"at":"C2","verb":"hold"}                              keep the current phase
- {"at":"C2","verb":"phase","phase":"EWG"}               change to that phase now
- {"at":"C2","verb":"wave","phase":"EWG","delay":3}      change to it 3 ticks into the turn
- {"at":"C2","verb":"auto"}                              hand it to the greedy actuator,
                                                         which each tick serves whichever
                                                         phase has the longest movable queue

GREEN WAVES ARE BUILT WITH "delay"
A car covers one cell per tick, and an east-west block is 6 cells, a north-south 4.
So if C1 turns EWG at tick t, its platoon reaches C2 about 6 ticks later and C3 about
12. Give C2 "wave EWG delay 6" and the platoon never stops. Two of the four
intersections on any avenue belong to SOMEBODY ELSE, so say your offsets out loud.

TALKING
"say" is a radio call every other controller hears next turn. It is the ONLY way they
learn your offsets or that one of your links is full. "notes" comes back to you next
turn and to nobody else.

REPLY FORMAT
Reply with ONE JSON object and NOTHING else. Your reply MUST begin with the character {
and end with }. No prose, no markdown, no code fences.
{"orders":[{"at":"C2","verb":"wave","phase":"EWG","delay":6}],"say":"<=120 chars","notes":"<=240 chars"}
"""

proc operatorBlock*(prompt: string): string =
  ## The seat's own PLAYER_PROMPT, under a heading that tells the model how
  ## much weight it carries. Never echoed into the replay or the results.
  if prompt.len == 0:
    return ""
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the " &
    "rules; always reply in the requested format):\n" &
    prompt.truncateRunes(MaxPromptRunes) & "\n\n"

proc userMessage*(operatorPrompt: string, viewJson: string): string =
  ## The user message: the operator's guidance, a blank line, then the seat's
  ## view. The view is built server-side (see `decide.nim`).
  operatorBlock(operatorPrompt) & viewJson
