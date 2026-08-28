## The sumo-traffic-signals player container: a policy is just a prompt.
##
## This process is DELIBERATELY thin. It connects to its seat, sends ONE
## Sprite v1 chat message carrying its registration, and then only receives.
## Every decision happens inside the GAME server, because that is the only
## container the platform injects the `anthropic_api_key` coworld secret into,
## and because keeping the control layer server-side is what makes the recorded
## order log reproducible with no network in the loop.
##
##   PLAYER_PROMPT        a strategy in plain English -> this seat is an LLM seat
##   PLAYER_SCRIPTED      greedy | fixedcycle         -> this seat is scripted
##   PLAYER_POLICY_LABEL  a free label for the replay's `register` record
##
## A seat that sets neither is `greedy`. To field your own policy, reuse this
## image and set PLAYER_PROMPT:
##
##   coworld upload-policy <image> --name my-signals \
##     --run /bin/sumo-traffic-signals-player \
##     --secret-env PLAYER_PROMPT="<your strategy>"

import
  std/[json, options, os, strutils, unicode],
  bitworld/spriteprotocol,
  whisky

const
  ConnectAttempts = 240      ## 240 x 500 ms = 2 minutes of dialling.
  ConnectRetryMs = 500
  RegistrationResends = 10   ## re-sends after the first, ~1 s apart.
  ResendEveryFrames = 24     ## ~1 s of frames at 24 Hz.
  ReconnectAttempts = 6      ## 6 x 500 ms of re-dialling after a live socket
                             ## dies, before accepting the game is gone.
  MaxPromptRunes = 4000      ## the transport cap; truncate, never reject.
  MaxLabelRunes = 64

proc truncateRunes(text: string, limit: int): string =
  ## RUNE boundaries, never bytes: a byte-truncated codepoint renders in a
  ## browser and then fails a strict UTF-8 parser.
  if limit <= 0:
    return ""
  if text.runeLen <= limit:
    return text
  text.runeSubStr(0, limit)

proc registrationBlob(prompt, scripted, policy: string): string =
  ## The one registration message. `scripted` is JSON null when the seat is an
  ## LLM seat, so the server can tell "no baseline named" from "greedy named
  ## explicitly".
  var node = %*{
    "type": "register",
    "prompt": prompt.truncateRunes(MaxPromptRunes),
    "policy": policy.truncateRunes(MaxLabelRunes)
  }
  if scripted.len > 0:
    node["scripted"] = %scripted
  else:
    node["scripted"] = newJNull()
  blobFromSpriteChat($node)

proc readyBlob(): string =
  ## The Sprite v1 player-ready packet (0x85). Legitimate here in a way it is
  ## not for an ordinary player client: this seat sends NO inputs at all (the
  ## server computes every phase), so the dead-reckoning hazard cannot arise.
  result = newString(1)
  result[0] = char(0x85)

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL", getEnv("COGAMES_ENGINE_WS_URL"))
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  let
    prompt = getEnv("PLAYER_PROMPT").strip()
    scripted = getEnv("PLAYER_SCRIPTED").strip()
    label = block:
      let explicit = getEnv("PLAYER_POLICY_LABEL").strip()
      if explicit.len > 0: explicit
      elif prompt.len > 0: "prompt"
      elif scripted.len > 0: scripted
      else: "greedy"
  echo "signals player: kind=",
    (if prompt.len > 0: "llm" else: "scripted"),
    " baseline=", (if scripted.len > 0: scripted else: "greedy"),
    " label=", label

  proc dial(attempts: int): WebSocket =
    ## Bounded dialling. The game bakes its city bed BEFORE it opens the
    ## listener, and the episode runner starts the players at the same instant
    ## as the game, so the first dial always lands on a closed port.
    for attempt in 0 ..< attempts:
      try:
        return newWebSocket(url)
      except CatchableError as error:
        if attempt == 0:
          echo "signals player: game not listening yet (", error.msg,
            "); retrying"
        sleep(ConnectRetryMs)
    nil

  var socket = dial(ConnectAttempts)
  if socket == nil:
    quit("signals player: game never accepted a connection", 1)
  echo "signals player: connected"

  # Each session is wrapped: whisky's receiveMessage RAISES on a close frame or
  # a truncated read (only a timeout returns none), and mummy's send only
  # QUEUES — so the game's own quit(0) can outrun the flushed frame. A naive
  # player exits 1 on that race and fails certification intermittently
  # (cogame-raid 0.1.3). Exiting 0 on a dead socket is the fix.
  #
  # REGISTRATION IS RE-SENT, NOT SENT ONCE. Joins are slot-sequential, so the
  # first registration can land while the seat has no index yet; the server
  # holds an unappliable registration and this end keeps re-sending it for the
  # first ~10 s of frames (the paintball 2026-08-25 scar).
  var reconnects = 0
  while true:
    var sessionFrames = 0
    try:
      socket.send(registrationBlob(prompt, scripted, label), BinaryMessage)
      var resends = 0
      while true:
        let received = socket.receiveMessage()
        if received.isNone:
          continue                    ## a read timeout, not a closed socket
        inc sessionFrames
        if resends < RegistrationResends and
            sessionFrames mod ResendEveryFrames == 1:
          inc resends
          socket.send(registrationBlob(prompt, scripted, label), BinaryMessage)
        socket.send(readyBlob(), BinaryMessage)
    except CatchableError as error:
      echo "signals player: socket closed (", error.msg, ")"
    # NEVER exit while the game is still serving. Bounded on both counts — a
    # session that never received a frame means the game is winding down (its
    # shutdown grace still answers the route), and the re-dial is capped — so
    # this can never outlive the game or spin.
    if sessionFrames == 0 or reconnects >= ReconnectAttempts:
      break
    inc reconnects
    echo "signals player: re-dialling the seat (attempt ", reconnects, ")"
    socket = dial(ReconnectAttempts)
    if socket == nil:
      echo "signals player: game is no longer listening, exiting cleanly"
      break
    echo "signals player: reconnected, re-registering"
  quit(0)
